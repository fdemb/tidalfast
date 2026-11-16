#+build windows
// The Direct3D 11 backend, for Windows. It draws what the Vulkan backend
// draws on Linux, with the shaders ported to HLSL in shaders/rect.hlsl.
// Direct3D 11 because its driver costs a fraction of Vulkan's memory: on
// an NVIDIA card a window clearing and presenting took 11 MB of private
// working set with Direct3D 11 against 69 MB with Vulkan (docs/windows.md).
//
// Direct3D 11 keeps a released object alive until the GPU is done with
// it, renames a buffer mapped with WRITE_DISCARD and orders texture writes
// with the draws around them, so this backend needs none of Vulkan's
// staging buffers, fences and barriers. A frame's instances are built in
// an array in ordinary memory, which the push procs and backdrop_hash read
// back, and end_frame copies them into one dynamic structured buffer. The
// buffer's mapping is write-combined, often uncached, and reading it back
// is slow. Both shaders index the buffer, and a constant buffer gives each
// draw its first instance, since SV_InstanceID starts at 0 for every draw.
//
// The swap chain uses the flip model, whose buffers can't be sRGB, so the
// render target view is: the buffers are BGRA8 and the view over them
// B8G8R8A8_UNORM_SRGB, and blending happens in linear space as on the
// other backends. The device's maximum frame latency is 1, and present
// blocks until the display takes the frame, which paces the app's
// animation.
//
// A driver update, a GPU reset or a GPU switch takes the device away. The
// renderer then releases everything, sets Renderer.device_lost and makes a
// new device at a later begin_frame, and Renderer.device_resets tells the
// textures' owners to make theirs again.
package render

import "base:runtime"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import d3d "vendor:directx/d3d11"
import "vendor:directx/dxgi"

import "../platform"

BACKDROPS :: true
TILT :: false // whether the shader has push_tilt's branch

VS_RECT :: #load("shaders/dxbc/vs_rect.dxbc")
PS_RECT :: #load("shaders/dxbc/ps_rect.dxbc")
VS_BLUR :: #load("shaders/dxbc/vs_blur.dxbc")
PS_BLUR_DOWN :: #load("shaders/dxbc/ps_blur_down.dxbc")
PS_BLUR_UP :: #load("shaders/dxbc/ps_blur_up.dxbc")

SWAP_BUFFERS :: 2

// Present's success code for a window that can't be seen.
DXGI_STATUS_OCCLUDED :: 0x087A0001
// D3D11CreateDevice's answer to the debug flag without the SDK layers,
// which come with Windows' optional Graphics Tools.
DXGI_ERROR_SDK_COMPONENT_MISSING :: 0x887A002D

// A lost device is made again at the next frame, then every RETRY_SECONDS
// while that fails. A device lost on a GPU is made on a GPU again: WARP,
// the CPU rasterizer, only stands in after WARP_AFTER tries, since a
// driver being installed can take a while.
RETRY_SECONDS :: 1
WARP_AFTER :: 10

// While the window is covered or the screen locked, frames aren't drawn.
// After one that wasn't, the app gets a frame in HIDDEN_POLL seconds to
// look again, then twice as long each time up to OCCLUDED_POLL_MAX, so
// what it missed is drawn soon after the window shows again.
OCCLUDED_POLL_MAX :: 1.0

// Frames whose GPU time can be waiting to be read.
TIMED_FRAMES :: 4

// Frame_Constants matches the Frame cbuffer in rect.hlsl.
Frame_Constants :: struct {
	target:     [4]f32,
	origin:     [4]f32,
	half_pixel: [2]f32,
	first:      u32,
	_:          u32,
}
#assert(size_of(Frame_Constants) == 48)

// A texture an offscreen pass draws into and later ones sample: the
// backdrop's scene or one of the blur's levels.
Blur_Image :: struct {
	texture: ^d3d.ITexture2D,
	rtv:     ^d3d.IRenderTargetView,
	srv:     ^d3d.IShaderResourceView,
	size:    int,
}

// Timestamps around each frame's drawing, for Renderer.gpu_ms. A frame's
// queries are read a frame or more later, without waiting for them.
Gpu_Timer :: struct {
	disjoint: [TIMED_FRAMES]^d3d.IQuery,
	start:    [TIMED_FRAMES]^d3d.IQuery,
	end:      [TIMED_FRAMES]^d3d.IQuery,
	issued:   [TIMED_FRAMES]bool,
	next:     int,
}

Gpu :: struct {
	// The shell's, kept through a lost device.
	surface:         ^platform.Win32_Surface,
	device:          ^d3d.IDevice,
	ctx:             ^d3d.IDeviceContext,
	window:          dxgi.HWND,
	swapchain:       ^dxgi.ISwapChain1,
	target:          ^d3d.IRenderTargetView, // the back buffer, sRGB
	extent:          [2]u32,
	vs_rect:         ^d3d.IVertexShader,
	ps_rect:         ^d3d.IPixelShader,
	vs_blur:         ^d3d.IVertexShader,
	ps_blur_down:    ^d3d.IPixelShader,
	ps_blur_up:      ^d3d.IPixelShader,
	blend:           ^d3d.IBlendState, // premultiplied over; the blur passes replace
	raster:          ^d3d.IRasterizerState,
	samplers:        [2]^d3d.ISamplerState, // linear with mips, nearest
	constants:       ^d3d.IBuffer,
	// The frame's instances, built here and copied to the buffer by
	// end_frame, which grows the buffer to the array's size when it's short.
	cpu_instances:   []Instance,
	instances:       ^d3d.IBuffer,
	instances_srv:   ^d3d.IShaderResourceView,
	instance_bytes:  int,
	// The backdrop, as on Vulkan: the scene at half the region's size in
	// the drawable's format, and the levels in RGBA16 float, made for the
	// region's size and kept until it changes.
	scene:           Blur_Image,
	levels:          [MAX_BLUR_LEVELS]Blur_Image,
	level_size:      [MAX_BLUR_LEVELS + 1][2]int,
	region_size:     [2]int,
	blurred_hash:    u64,
	timer:           Gpu_Timer,
	info:            ^d3d.IInfoQueue, // the debug layer's messages, with TIDALFAST_D3D11_DEBUG
	parked:          bool, // minimized: the buffers are a pixel and the backdrop is gone
	occluded:        bool, // present said nobody can see the window
	occluded_poll:   f32, // seconds until the next look, see OCCLUDED_POLL_MAX
	swapchain_error: bool, // logged; not again until a swap chain is made
	// Making a new device after a lost one. Kept through release.
	retry_at:        time.Tick,
	tries:           int,
	allocated:       int, // bytes of textures and buffers; atomic
}

Gpu_Texture :: struct {
	texture: ^d3d.ITexture2D,
	srv:     ^d3d.IShaderResourceView,
	size:    int,
}

// init draws to surface, a platform.Win32_Surface. If it fails, it tears
// down what it made, so g.device is nil and the renderer draws nothing.
init :: proc(r: ^Renderer, surface: rawptr) -> bool {
	ws := (^platform.Win32_Surface)(surface)
	if ws == nil || ws.window == nil {
		log.error("render: no window")
		return false
	}
	r.gpu.surface = ws
	return make_device(r, allow_warp = true)
}

// make_device makes the device and what lasts as long as it. The swap
// chain comes with the first frame. If it fails, it tears down what it
// made.
@(private)
make_device :: proc(r: ^Renderer, allow_warp: bool) -> (ok: bool) {
	g := &r.gpu
	defer if !ok {
		release(r)
	}
	g.window = dxgi.HWND(g.surface.window)

	// The shaders are shader model 5, which needs feature level 11_0. A
	// machine without such a GPU, or a VM or Wine without a GPU driver,
	// still draws through WARP, Direct3D's CPU rasterizer.
	level := d3d.FEATURE_LEVEL._11_0
	flags := d3d.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT, .SINGLETHREADED}
	debug := os.get_env("TIDALFAST_D3D11_DEBUG", context.temp_allocator) != ""
	if debug {
		flags += {.DEBUG}
	}
	hr := d3d.CreateDevice(nil, .HARDWARE, nil, flags, &level, 1, d3d.SDK_VERSION, &g.device, nil, &g.ctx)
	if debug && u32(hr) == DXGI_ERROR_SDK_COMPONENT_MISSING {
		log.warn("render: the Direct3D debug layer isn't installed (Settings, Optional features, Graphics Tools)")
		flags -= {.DEBUG}
		debug = false
		hr = d3d.CreateDevice(nil, .HARDWARE, nil, flags, &level, 1, d3d.SDK_VERSION, &g.device, nil, &g.ctx)
	}
	if hr < 0 && allow_warp {
		log.warnf("render: no hardware Direct3D 11 device (0x%x), trying WARP", u32(hr))
		hr = d3d.CreateDevice(nil, .WARP, nil, flags, &level, 1, d3d.SDK_VERSION, &g.device, nil, &g.ctx)
	}
	if hr < 0 {
		log.errorf("render: D3D11CreateDevice failed: 0x%x", u32(hr))
		g.device, g.ctx = nil, nil
		return false
	}
	log_adapter(g)
	if !r.device_lost {
		init_step(&r.init_steps, "render_device")
	}
	if debug && g.device->QueryInterface(d3d.IInfoQueue_UUID, (^rawptr)(&g.info)) < 0 {
		g.info = nil
	}

	if !make_shaders(g) || !make_states(g) {
		return false
	}
	constants := d3d.BUFFER_DESC {
		ByteWidth      = size_of(Frame_Constants),
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if g.device->CreateBuffer(&constants, nil, &g.constants) < 0 {
		log.error("render: can't make the constant buffer")
		return false
	}
	make_timer(g)

	// Slot 0 is the white texture behind the zero handle, so its
	// generation stays 0, also after a lost device.
	r.textures[0] = new_texture_slot(r, 1, 1, .RGBA8, false)
	if r.textures[0].width == 0 {
		log.error("render: can't make the white texture")
		return false
	}
	white := [4]u8{255, 255, 255, 255}
	texture_update(r, 0, white[:], 0, 0, 1, 1)
	log_debug_messages(g)
	return true
}

@(private)
log_adapter :: proc(g: ^Gpu) {
	dd: ^dxgi.IDevice
	if g.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dd)) < 0 {
		return
	}
	defer dd->Release()
	adapter: ^dxgi.IAdapter
	if dd->GetAdapter(&adapter) < 0 {
		return
	}
	defer adapter->Release()
	desc: dxgi.ADAPTER_DESC
	adapter->GetDesc(&desc)
	name, _ := win.utf16_to_utf8(desc.Description[:], context.temp_allocator)
	log.infof("render: Direct3D 11 on %s", cstring(raw_data(name)))
}

@(private)
make_shaders :: proc(g: ^Gpu) -> bool {
	ok := g.device->CreateVertexShader(raw_data(VS_RECT), len(VS_RECT), nil, &g.vs_rect) >= 0
	ok &&= g.device->CreatePixelShader(raw_data(PS_RECT), len(PS_RECT), nil, &g.ps_rect) >= 0
	ok &&= g.device->CreateVertexShader(raw_data(VS_BLUR), len(VS_BLUR), nil, &g.vs_blur) >= 0
	ok &&= g.device->CreatePixelShader(raw_data(PS_BLUR_DOWN), len(PS_BLUR_DOWN), nil, &g.ps_blur_down) >= 0
	ok &&= g.device->CreatePixelShader(raw_data(PS_BLUR_UP), len(PS_BLUR_UP), nil, &g.ps_blur_up) >= 0
	if !ok {
		log.error("render: can't make the shaders")
	}
	return ok
}

@(private)
make_states :: proc(g: ^Gpu) -> bool {
	blend: d3d.BLEND_DESC
	blend.RenderTarget[0] = {
		BlendEnable           = true,
		SrcBlend              = .ONE,
		DestBlend             = .INV_SRC_ALPHA,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .ONE,
		DestBlendAlpha        = .INV_SRC_ALPHA,
		BlendOpAlpha          = .ADD,
		RenderTargetWriteMask = 0xf,
	}
	raster := d3d.RASTERIZER_DESC {
		FillMode        = .SOLID,
		CullMode        = .NONE,
		DepthClipEnable = true,
	}
	linear := d3d.SAMPLER_DESC {
		Filter   = .MIN_MAG_MIP_LINEAR,
		AddressU = .CLAMP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		MaxLOD   = math.F32_MAX,
	}
	nearest := linear
	nearest.Filter = .MIN_MAG_MIP_POINT
	nearest.MaxLOD = 0
	ok := g.device->CreateBlendState(&blend, &g.blend) >= 0
	ok &&= g.device->CreateRasterizerState(&raster, &g.raster) >= 0
	ok &&= g.device->CreateSamplerState(&linear, &g.samplers[0]) >= 0
	ok &&= g.device->CreateSamplerState(&nearest, &g.samplers[1]) >= 0
	if !ok {
		log.error("render: can't make the pipeline states")
	}
	return ok
}

// make_timer makes the timestamp queries. Without them gpu_ms stays 0.
@(private)
make_timer :: proc(g: ^Gpu) {
	disjoint := d3d.QUERY_DESC {
		Query = .TIMESTAMP_DISJOINT,
	}
	stamp := d3d.QUERY_DESC {
		Query = .TIMESTAMP,
	}
	t := &g.timer
	for i in 0 ..< TIMED_FRAMES {
		ok := g.device->CreateQuery(&disjoint, &t.disjoint[i]) >= 0
		ok &&= g.device->CreateQuery(&stamp, &t.start[i]) >= 0
		ok &&= g.device->CreateQuery(&stamp, &t.end[i]) >= 0
		if !ok {
			free_timer(t)
			return
		}
	}
}

@(private)
free_timer :: proc(t: ^Gpu_Timer) {
	for i in 0 ..< TIMED_FRAMES {
		com_release(&t.disjoint[i])
		com_release(&t.start[i])
		com_release(&t.end[i])
	}
	t^ = {}
}

// timer_begin and timer_end bracket a frame's drawing with timestamps.
@(private)
timer_begin :: proc(g: ^Gpu) {
	t := &g.timer
	if t.disjoint[0] == nil {
		return
	}
	g.ctx->Begin((^d3d.IAsynchronous)(t.disjoint[t.next]))
	g.ctx->End((^d3d.IAsynchronous)(t.start[t.next]))
}

@(private)
timer_end :: proc(g: ^Gpu) {
	t := &g.timer
	if t.disjoint[0] == nil {
		return
	}
	g.ctx->End((^d3d.IAsynchronous)(t.end[t.next]))
	g.ctx->End((^d3d.IAsynchronous)(t.disjoint[t.next]))
	t.issued[t.next] = true
	t.next = (t.next + 1) % TIMED_FRAMES
}

// read_gpu_time sets gpu_ms from the newest frame whose timestamps are
// in, oldest first, and stops at the first that isn't, without waiting.
@(private)
read_gpu_time :: proc(r: ^Renderer) {
	g := &r.gpu
	t := &g.timer
	DONOTFLUSH :: u32(1)
	for k in 0 ..< TIMED_FRAMES {
		i := (t.next + k) % TIMED_FRAMES
		if !t.issued[i] {
			continue
		}
		disjoint: d3d.QUERY_DATA_TIMESTAMP_DISJOINT
		start, end: u64
		if g.ctx->GetData((^d3d.IAsynchronous)(t.disjoint[i]), &disjoint, size_of(disjoint), DONOTFLUSH) != 0 {
			return
		}
		if g.ctx->GetData((^d3d.IAsynchronous)(t.start[i]), &start, size_of(start), DONOTFLUSH) != 0 {
			return
		}
		if g.ctx->GetData((^d3d.IAsynchronous)(t.end[i]), &end, size_of(end), DONOTFLUSH) != 0 {
			return
		}
		t.issued[i] = false
		if !disjoint.Disjoint && disjoint.Frequency > 0 && end >= start {
			r.gpu_ms = f32(f64(end - start) * 1000 / f64(disjoint.Frequency))
		}
	}
}

// log_debug_messages logs what the debug layer said since last time.
@(private)
log_debug_messages :: proc(g: ^Gpu) {
	if g.info == nil {
		return
	}
	n := g.info->GetNumStoredMessages()
	for i in 0 ..< n {
		size: d3d.SIZE_T
		if g.info->GetMessage(i, nil, &size) < 0 || size < size_of(d3d.MESSAGE) {
			continue
		}
		buf, err := mem.alloc_bytes(int(size), align_of(d3d.MESSAGE), context.temp_allocator)
		if err != nil {
			break
		}
		m := (^d3d.MESSAGE)(raw_data(buf))
		if g.info->GetMessage(i, m, &size) < 0 {
			continue
		}
		switch m.Severity {
		case .CORRUPTION, .ERROR:
			log.errorf("render: d3d11: %s", m.pDescription)
		case .WARNING:
			log.warnf("render: d3d11: %s", m.pDescription)
		case .INFO, .MESSAGE:
			log.infof("render: d3d11: %s", m.pDescription)
		}
	}
	g.info->ClearStoredMessages()
}

destroy :: proc(r: ^Renderer) {
	release(r)
	r^ = {}
}

@(private)
com_release :: proc(p: ^$T) {
	if p^ != nil {
		(^dxgi.IUnknown)(p^)->Release()
		p^ = nil
	}
}

// release frees the GPU objects, so g.device is nil and the renderer draws
// nothing. It keeps the frame's counts, batches and clips, the capture
// path the shell set, the surface and how the device is being made again.
// Each slot's generation moves on, as in texture_destroy, so no old handle
// matches.
release :: proc(r: ^Renderer) {
	g := &r.gpu
	if g.ctx != nil {
		g.ctx->ClearState()
	}
	for &slot in r.textures {
		if slot.width != 0 {
			free_texture_now(g, slot.gpu)
		}
	}
	free_blur_image(&g.scene)
	for &l in g.levels {
		free_blur_image(&l)
	}
	free_timer(&g.timer)
	com_release(&g.info)
	com_release(&g.instances_srv)
	com_release(&g.instances)
	com_release(&g.constants)
	for &s in g.samplers {
		com_release(&s)
	}
	com_release(&g.raster)
	com_release(&g.blend)
	com_release(&g.vs_rect)
	com_release(&g.ps_rect)
	com_release(&g.vs_blur)
	com_release(&g.ps_blur_down)
	com_release(&g.ps_blur_up)
	com_release(&g.target)
	com_release(&g.swapchain)
	if g.ctx != nil {
		// Direct3D frees released objects only when the context flushes,
		// and a new swap chain for the same window fails while the old one
		// is still there.
		g.ctx->Flush()
	}
	com_release(&g.ctx)
	com_release(&g.device)
	if g.cpu_instances != nil {
		delete(g.cpu_instances, runtime.heap_allocator())
	}
	r.gpu = {
		surface  = g.surface,
		retry_at = g.retry_at,
		tries    = g.tries,
	}
	for &slot in r.textures {
		slot = {generation = slot.generation + 1}
	}
	r.instances = nil
	r.capacity = {}
}

// lose checks whether the device is gone, after a call that failed with
// hr. If it is, it releases everything and sets r.device_lost, and
// begin_frame makes a new device. False if the device is fine.
@(private)
lose :: proc(r: ^Renderer, hr: win.HRESULT) -> bool {
	g := &r.gpu
	if g.device == nil {
		return true
	}
	reason := g.device->GetDeviceRemovedReason()
	if reason >= 0 {
		return false
	}
	log.errorf("render: the GPU device was lost (0x%x, reason 0x%x), making a new one", u32(hr), u32(reason))
	release(r)
	r.device_lost = true
	r.hidden = true
	r.poll_after = 0.01
	g.retry_at = time.tick_now()
	g.tries = 0
	return true
}

// recover makes a new device after a lost one, if it's time to try.
@(private)
recover :: proc(r: ^Renderer) {
	g := &r.gpu
	if time.tick_diff(g.retry_at, time.tick_now()) < 0 {
		return
	}
	g.tries += 1
	if !make_device(r, allow_warp = g.tries > WARP_AFTER) {
		g.retry_at = time.tick_add(time.tick_now(), RETRY_SECONDS * time.Second)
		return
	}
	log.infof("render: made a new device after losing the last, in %d tries", g.tries)
	g.tries = 0
	r.device_lost = false
	r.device_resets += 1
}

// gpu_allocated is the memory the renderer's textures and buffers take, in
// bytes, as their sizes add up; Direct3D 11 doesn't say what the driver
// allocated. Safe from any thread.
gpu_allocated :: proc "contextless" (r: ^Renderer) -> int {
	return sync.atomic_load(&r.gpu.allocated)
}

// gpu_memory is what the renderer's own buffers take. The textures made
// with texture_create aren't in it, see texture_bytes. There are no upload
// buffers: Direct3D 11 copies texture writes itself.
gpu_memory :: proc(r: ^Renderer) -> Gpu_Memory {
	m: Gpu_Memory
	m.instances = r.gpu.instance_bytes
	m.backdrop = r.gpu.scene.size
	for l in r.gpu.levels {
		m.backdrop += l.size
	}
	return m
}

@(private)
gpu_texture_bytes :: proc(slot: ^Texture_Slot) -> int {
	return slot.gpu.size
}

// Textures

@(private)
dxgi_format :: proc(format: Texture_Format) -> dxgi.FORMAT {
	switch format {
	case .R8:
		return .R8_UNORM
	case .RGBA8:
		return .R8G8B8A8_UNORM_SRGB
	case .BGRA8:
		return .B8G8R8A8_UNORM_SRGB
	}
	return .UNKNOWN
}

// new_texture_slot returns a zero slot if Direct3D can't make the texture.
// A mipmapped texture can be a render target, which GenerateMips needs.
@(private)
new_texture_slot :: proc(r: ^Renderer, width, height: int, format: Texture_Format, mipmapped: bool) -> Texture_Slot {
	g := &r.gpu
	if g.device == nil {
		return {}
	}
	levels := u32(1)
	if mipmapped {
		levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1
	}
	desc := d3d.TEXTURE2D_DESC {
		Width      = u32(width),
		Height     = u32(height),
		MipLevels  = levels,
		ArraySize  = 1,
		Format     = dxgi_format(format),
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE},
	}
	if mipmapped {
		desc.BindFlags += {.RENDER_TARGET}
		desc.MiscFlags = {.GENERATE_MIPS}
	}
	t: Gpu_Texture
	if g.device->CreateTexture2D(&desc, nil, &t.texture) < 0 {
		return {}
	}
	if g.device->CreateShaderResourceView((^d3d.IResource)(t.texture), nil, &t.srv) < 0 {
		com_release(&t.texture)
		return {}
	}
	bpp := 1 if format == .R8 else 4
	t.size = width * height * bpp
	if mipmapped {
		t.size = t.size * 4 / 3
	}
	sync.atomic_add(&g.allocated, t.size)
	return {gpu = t, width = i32(width), height = i32(height), format = format, mipmapped = mipmapped}
}

// gpu_texture_free releases the texture. Direct3D keeps it until the
// frames that sample it are done.
@(private)
gpu_texture_free :: proc(r: ^Renderer, t: Gpu_Texture) {
	if r.gpu.device != nil {
		free_texture_now(&r.gpu, t)
	}
}

@(private)
free_texture_now :: proc(g: ^Gpu, t: Gpu_Texture) {
	t := t
	if t.texture != nil {
		sync.atomic_sub(&g.allocated, t.size)
	}
	com_release(&t.srv)
	com_release(&t.texture)
}

// gpu_texture_write copies the pixels into the texture, ordered with the
// draws before and after it, and makes the mips again if it has them.
@(private)
gpu_texture_write :: proc(r: ^Renderer, slot: ^Texture_Slot, pixels: []byte, x, y, w, h, bpp: int) {
	g := &r.gpu
	if g.device == nil {
		return
	}
	box := d3d.BOX{u32(x), u32(y), 0, u32(x + w), u32(y + h), 1}
	g.ctx->UpdateSubresource((^d3d.IResource)(slot.gpu.texture), 0, &box, raw_data(pixels), u32(w * bpp), 0)
	if slot.mipmapped {
		g.ctx->GenerateMips(slot.gpu.srv)
	}
}

@(private)
gpu_texture_copy :: proc(r: ^Renderer, from, to: ^Texture_Slot, w, h: int) {
	g := &r.gpu
	if g.device == nil {
		return
	}
	box := d3d.BOX{0, 0, 0, u32(w), u32(h), 1}
	g.ctx->CopySubresourceRegion((^d3d.IResource)(to.gpu.texture), 0, 0, 0, 0, (^d3d.IResource)(from.gpu.texture), 0, &box)
}

// Frame

// gpu_frame_begin returns the array the frame's instances go in, or nil if
// there is no device. After a lost device it first tries to make a new
// one.
@(private)
gpu_frame_begin :: proc(r: ^Renderer) -> [^]Instance {
	g := &r.gpu
	if r.device_lost && g.device == nil {
		recover(r)
	}
	if g.device == nil {
		return nil
	}
	r.slot_wait_ms = 0
	r.drawable_wait_ms = 0
	if g.cpu_instances == nil && !set_cpu_instances(r, INITIAL_INSTANCES) {
		return nil
	}
	return raw_data(g.cpu_instances)
}

// grow_instances doubles the frame's array, keeping what this frame has
// pushed so far. If there's no memory for it, the old array and capacity
// stay.
@(private)
grow_instances :: proc(r: ^Renderer) {
	set_cpu_instances(r, 2 * len(r.gpu.cpu_instances))
}

// set_cpu_instances makes the array capacity instances long, keeping the
// ones this frame has pushed. Every slot gets the capacity: there is one
// array.
@(private)
set_cpu_instances :: proc(r: ^Renderer, capacity: int) -> bool {
	g := &r.gpu
	next, err := make([]Instance, capacity, runtime.heap_allocator())
	if err != nil {
		log.error("render: out of memory for instances")
		return false
	}
	if g.cpu_instances != nil {
		copy(next, g.cpu_instances[:r.instance_count])
		delete(g.cpu_instances, runtime.heap_allocator())
	}
	g.cpu_instances = next
	r.instances = raw_data(next)
	for &c in r.capacity {
		c = capacity
	}
	return true
}

// upload_instances copies the frame's instances into the instance buffer,
// first making the buffer as long as the array if it's shorter than the
// frame. WRITE_DISCARD gives fresh memory while the GPU may still read the
// last frame's. False if there's no buffer to draw from.
@(private)
upload_instances :: proc(r: ^Renderer) -> bool {
	g := &r.gpu
	if r.instance_count == 0 {
		return true
	}
	if r.instance_count * size_of(Instance) > g.instance_bytes && !set_instance_buffer(g, len(g.cpu_instances)) {
		return false
	}
	m: d3d.MAPPED_SUBRESOURCE
	if hr := g.ctx->Map((^d3d.IResource)(g.instances), 0, .WRITE_DISCARD, {}, &m); hr < 0 {
		if !lose(r, hr) {
			log.errorf("render: can't map the instance buffer: 0x%x", u32(hr))
		}
		return false
	}
	mem.copy_non_overlapping(m.pData, raw_data(g.cpu_instances), r.instance_count * size_of(Instance))
	g.ctx->Unmap((^d3d.IResource)(g.instances), 0)
	return true
}

// set_instance_buffer replaces the instance buffer with one of capacity
// instances. If it can't, the old one stays.
@(private)
set_instance_buffer :: proc(g: ^Gpu, capacity: int) -> bool {
	desc := d3d.BUFFER_DESC {
		ByteWidth           = u32(capacity * size_of(Instance)),
		Usage               = .DYNAMIC,
		BindFlags           = {.SHADER_RESOURCE},
		CPUAccessFlags      = {.WRITE},
		MiscFlags           = {.BUFFER_STRUCTURED},
		StructureByteStride = size_of(Instance),
	}
	buffer: ^d3d.IBuffer
	if g.device->CreateBuffer(&desc, nil, &buffer) < 0 {
		log.error("render: out of memory for instances")
		return false
	}
	srv_desc := d3d.SHADER_RESOURCE_VIEW_DESC {
		Format        = .UNKNOWN,
		ViewDimension = .BUFFER,
	}
	srv_desc.Buffer.NumElements = u32(capacity)
	srv: ^d3d.IShaderResourceView
	if g.device->CreateShaderResourceView((^d3d.IResource)(buffer), &srv_desc, &srv) < 0 {
		com_release(&buffer)
		log.error("render: can't view the instance buffer")
		return false
	}
	sync.atomic_sub(&g.allocated, g.instance_bytes)
	com_release(&g.instances_srv)
	com_release(&g.instances)
	g.instances, g.instances_srv = buffer, srv
	g.instance_bytes = int(desc.ByteWidth)
	sync.atomic_add(&g.allocated, g.instance_bytes)
	return true
}

// swapchain_stale says whether the swap chain has to be made or resized
// for a window of want pixels.
swapchain_stale :: proc(g: ^Gpu, want: [2]u32) -> bool {
	return g.swapchain == nil || g.target == nil || g.extent != want
}

// make_swapchain makes the swap chain at want pixels, or resizes the one
// there is. The flip model with two buffers, presented on vsync, so a
// present waits when the display is behind and paces animation.
@(private)
make_swapchain :: proc(r: ^Renderer, want: [2]u32) -> (hr: win.HRESULT) {
	g := &r.gpu
	com_release(&g.target)
	g.extent = {}
	if g.swapchain == nil {
		dd: ^dxgi.IDevice1
		if hr = g.device->QueryInterface(dxgi.IDevice1_UUID, (^rawptr)(&dd)); hr < 0 {
			return
		}
		defer dd->Release()
		// One frame queued ahead of the display keeps input close to what's
		// on screen; the app draws only when something changed.
		dd->SetMaximumFrameLatency(1)
		adapter: ^dxgi.IAdapter
		if hr = dd->GetAdapter(&adapter); hr < 0 {
			return
		}
		defer adapter->Release()
		factory: ^dxgi.IFactory2
		if hr = adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory)); hr < 0 {
			return
		}
		defer factory->Release()
		desc := dxgi.SWAP_CHAIN_DESC1 {
			Width       = want.x,
			Height      = want.y,
			Format      = .B8G8R8A8_UNORM,
			SampleDesc  = {Count = 1},
			BufferUsage = {.RENDER_TARGET_OUTPUT},
			BufferCount = SWAP_BUFFERS,
			Scaling     = .NONE,
			SwapEffect  = .FLIP_DISCARD,
			AlphaMode   = .IGNORE,
		}
		// Windows before 10 has no FLIP_DISCARD.
		effects := [2]dxgi.SWAP_EFFECT{.FLIP_DISCARD, .FLIP_SEQUENTIAL}
		tries := 2
		// TIDALFAST_D3D_BLT=1 makes a blt-model swap chain instead: each
		// present is copied into the window's surface, which the compositor
		// always composes, so the display never scans a buffer out directly
		// (independent flip, overlay planes). It's for telling a fault in
		// that path from one in the frames. Its one buffer is sRGB itself,
		// since only a flip-model buffer takes an sRGB view over UNORM, and
		// it has no unscaled mode.
		blt := os.get_env("TIDALFAST_D3D_BLT", context.temp_allocator) != ""
		if blt {
			desc.Format = .B8G8R8A8_UNORM_SRGB
			desc.BufferCount = 1
			desc.Scaling = .STRETCH
			effects[0], tries = .DISCARD, 1
		}
		log.infof("render: %s swap chain", "blt-model" if blt else "flip-model")
		for effect in effects[:tries] {
			desc.SwapEffect = effect
			if hr = factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(g.device), g.window, &desc, nil, nil, &g.swapchain); hr >= 0 {
				break
			}
			g.swapchain = nil
		}
		if hr < 0 {
			return
		}
		// What shows where the buffers don't reach while the window grows,
		// before the next frame resizes them. The buffers aren't sRGB, so
		// it's the sRGB clear colour, not the linear one the sRGB view clears
		// with.
		background := dxgi.RGBA{r.clear.r, r.clear.g, r.clear.b, 1}
		g.swapchain->SetBackgroundColor(&background)
		// The shell owns the window and its keys; Alt-Enter isn't fullscreen.
		factory->MakeWindowAssociation(g.window, {.NO_ALT_ENTER})
	} else {
		g.ctx->OMSetRenderTargets(0, nil, nil)
		if hr = g.swapchain->ResizeBuffers(0, want.x, want.y, .UNKNOWN, {}); hr < 0 {
			return
		}
	}
	back: ^d3d.ITexture2D
	if hr = g.swapchain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&back)); hr < 0 {
		return
	}
	defer back->Release()
	rtv := d3d.RENDER_TARGET_VIEW_DESC {
		Format        = .B8G8R8A8_UNORM_SRGB,
		ViewDimension = .TEXTURE2D,
	}
	if hr = g.device->CreateRenderTargetView((^d3d.IResource)(back), &rtv, &g.target); hr < 0 {
		g.target = nil
		return
	}
	g.extent = want
	g.swapchain_error = false
	return 0
}

// park gives back what a minimized window doesn't need: the backdrop's
// textures, the swap chain's buffers, shrunk to a pixel, and what the
// driver keeps for the device's objects that are gone (IDXGIDevice3::Trim).
// The next frame that's seen makes them again. macOS shrinks its drawables
// the same way.
@(private)
park :: proc(r: ^Renderer) {
	g := &r.gpu
	if g.parked {
		return
	}
	g.parked = true
	free_blur_image(&g.scene, g)
	for &l in g.levels {
		free_blur_image(&l, g)
	}
	g.region_size = {}
	g.blurred_hash = 0
	if g.swapchain != nil {
		if hr := make_swapchain(r, {1, 1}); hr < 0 && lose(r, hr) {
			return
		}
	}
	g.ctx->ClearState()
	d3: ^dxgi.IDevice3
	if g.device->QueryInterface(dxgi.IDevice3_UUID, (^rawptr)(&d3)) >= 0 {
		d3->Trim()
		d3->Release()
	}
}

// end_frame draws the frame and presents it. A frame that can't be seen
// isn't drawn: r.hidden says so, and r.poll_after when to look again.
end_frame :: proc(r: ^Renderer) {
	g := &r.gpu
	defer r.frame_index += 1
	r.hidden, r.poll_after = true, 0
	if g.device == nil {
		if r.device_lost {
			r.poll_after = RETRY_SECONDS
		}
		return
	}
	defer log_debug_messages(g)
	want := [2]u32{u32(math.round(r.width * r.scale)), u32(math.round(r.height * r.scale))}
	if want.x == 0 || want.y == 0 {
		return
	}
	// The shell draws one frame as the window is minimized, then none
	// until it's restored. Captures keep drawing, as on macOS.
	if r.capture_path == "" && win.IsIconic(win.HWND(g.window)) {
		park(r)
		return
	}
	g.parked = false
	if g.occluded && r.capture_path == "" {
		hr := g.swapchain->Present(0, {.TEST})
		if u32(hr) == DXGI_STATUS_OCCLUDED {
			r.poll_after = g.occluded_poll
			g.occluded_poll = min(2 * g.occluded_poll, OCCLUDED_POLL_MAX)
			return
		}
		if hr < 0 && lose(r, hr) {
			return
		}
		g.occluded = false
	}
	if swapchain_stale(g, want) {
		if hr := make_swapchain(r, want); hr < 0 {
			if !lose(r, hr) && !g.swapchain_error {
				log.errorf("render: can't make or resize the swap chain: 0x%x", u32(hr))
				g.swapchain_error = true
			}
			return
		}
	}
	if !upload_instances(r) {
		return
	}

	timer_begin(g)
	draw_calls := 0
	blurred := r.textures[0].gpu.srv
	if r.backdrop.batch >= 0 {
		srv, calls := encode_backdrop(r)
		draw_calls += calls
		if srv != nil {
			blurred = srv
		}
	}
	g.ctx->OMSetRenderTargets(1, &g.target, nil)
	clear := clear_color(r)
	g.ctx->ClearRenderTargetView(g.target, &clear)
	whole := [4]f32{0, 0, f32(g.extent.x), f32(g.extent.y)}
	draw_calls += draw_batches(r, r.batches[:r.batch_count], g.extent, whole, {0, 0, 1, 1}, blurred)
	timer_end(g)

	if r.capture_path != "" {
		capture(r)
	}
	wait := time.tick_now()
	hr := g.swapchain->Present(1, {})
	r.drawable_wait_ms = f32(time.duration_milliseconds(time.tick_since(wait)))
	if hr < 0 {
		if !lose(r, hr) {
			log.errorf("render: present failed: 0x%x", u32(hr))
		}
		return
	}
	r.stats = {draw_calls, r.instance_count}
	read_gpu_time(r)
	if u32(hr) == DXGI_STATUS_OCCLUDED {
		if r.capture_path != "" {
			// A capture keeps drawing while nobody can see the window, and
			// present doesn't wait for vsync then, so this paces it.
			time.sleep(16 * time.Millisecond)
		} else {
			// This frame went up and shows when the window does. The next
			// one only checks, and polls if it can't be seen.
			g.occluded = true
			g.occluded_poll = HIDDEN_POLL
			return
		}
	}
	r.hidden = false
}


// clear_color is the frame's clear colour. The targets are sRGB, so it's
// given in linear.
@(private)
clear_color :: proc(r: ^Renderer) -> [4]f32 {
	return {linear_from_srgb(r.clear.r), linear_from_srgb(r.clear.g), linear_from_srgb(r.clear.b), r.clear.a}
}

@(private)
set_constants :: proc(g: ^Gpu, c: Frame_Constants) {
	m: d3d.MAPPED_SUBRESOURCE
	if g.ctx->Map((^d3d.IResource)(g.constants), 0, .WRITE_DISCARD, {}, &m) >= 0 {
		(^Frame_Constants)(m.pData)^ = c
		g.ctx->Unmap((^d3d.IResource)(g.constants), 0)
	}
}

// draw_batches draws batches into the bound render target, size pixels
// covering target (x, y, w, h) of the drawable's pixels. origin is the
// target's origin in the drawable and the drawable pixels per target
// pixel, and backdrop the blurred texture. Returns the draw calls.
@(private)
draw_batches :: proc(r: ^Renderer, batches: []Batch, size: [2]u32, target, origin: [4]f32, backdrop: ^d3d.IShaderResourceView) -> int {
	g := &r.gpu
	if r.instance_count == 0 {
		return 0
	}
	ctx := g.ctx
	viewport := d3d.VIEWPORT{0, 0, f32(size.x), f32(size.y), 0, 1}
	ctx->RSSetViewports(1, &viewport)
	ctx->RSSetState(g.raster)
	ctx->OMSetBlendState(g.blend, nil, 0xffffffff)
	ctx->IASetInputLayout(nil)
	ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	ctx->VSSetShader(g.vs_rect, nil, 0)
	ctx->PSSetShader(g.ps_rect, nil, 0)
	ctx->VSSetConstantBuffers(0, 1, &g.constants)
	ctx->PSSetConstantBuffers(0, 1, &g.constants)
	ctx->VSSetShaderResources(0, 1, &g.instances_srv)
	ctx->PSSetSamplers(0, 2, &g.samplers[0])
	white := r.textures[0].gpu.srv
	views := [4]^d3d.IShaderResourceView{g.instances_srv, white, white, backdrop}
	ctx->PSSetShaderResources(0, 4, &views[0])
	bound := [2]^d3d.IShaderResourceView{white, white}
	draw_calls := 0
	for b in batches {
		if b.count == 0 {
			continue
		}
		for t, index in b.textures {
			slot := texture_slot(r, t)
			srv := slot.gpu.srv if slot != nil else white
			if srv != bound[index] {
				ctx->PSSetShaderResources(u32(1 + index), 1, &srv)
				bound[index] = srv
			}
		}
		set_constants(g, {target = target, origin = origin, first = b.first})
		ctx->DrawInstanced(4, b.count, 0, 0)
		draw_calls += 1
	}
	return draw_calls
}

// encode_backdrop draws the batches before the backdrop into the scene
// texture at half size and the blur down its levels and back up, and
// returns the level the backdrop samples and the draw calls it took. When
// what the blur reads hasn't changed since it last ran, it returns that
// blur as it is. nil if there's no blur to sample.
@(private)
encode_backdrop :: proc(r: ^Renderer) -> (blurred: ^d3d.IShaderResourceView, draw_calls: int) {
	g := &r.gpu
	bd := r.backdrop
	w, h := int(bd.region.z - bd.region.x), int(bd.region.w - bd.region.y)
	if !backdrop_textures(r, w, h) {
		return nil, 0
	}
	if bd.hash == g.blurred_hash {
		return g.levels[0].srv, 0
	}
	scene := g.level_size[0]
	// The scene's view is unbound from the shaders before it's a target.
	none: [4]^d3d.IShaderResourceView
	g.ctx->PSSetShaderResources(0, 4, &none[0])
	g.ctx->OMSetRenderTargets(1, &g.scene.rtv, nil)
	clear := clear_color(r)
	g.ctx->ClearRenderTargetView(g.scene.rtv, &clear)
	scale := [2]f32{f32(w) / f32(scene.x), f32(h) / f32(scene.y)}
	target := [4]f32{bd.region.x, bd.region.y, f32(w), f32(h)}
	origin := [4]f32{bd.region.x, bd.region.y, scale.x, scale.y}
	draw_calls = draw_batches(r, r.batches[:bd.batch], {u32(scene.x), u32(scene.y)}, target, origin, r.textures[0].gpu.srv)

	// Drawing the scene at half size was the first halving.
	src := g.scene
	for i in 0 ..< bd.levels - 1 {
		blur_pass(g, g.ps_blur_down, src, g.levels[i], g.level_size[i], g.level_size[i + 1])
		src = g.levels[i]
	}
	for i := bd.levels - 2; i > 0; i -= 1 {
		blur_pass(g, g.ps_blur_up, g.levels[i], g.levels[i - 1], g.level_size[i + 1], g.level_size[i])
	}
	g.blurred_hash = bd.hash
	return g.levels[0].srv, draw_calls + 2 * bd.levels - 3
}

// blur_pass draws one pass of the dual filter from src, src_size texels,
// into dst, dst_size texels. The target goes first, which unbinds it from
// the shaders, then the source, which the last pass drew.
@(private)
blur_pass :: proc(g: ^Gpu, shader: ^d3d.IPixelShader, src, dst: Blur_Image, src_size, dst_size: [2]int) {
	ctx := g.ctx
	none: ^d3d.IShaderResourceView
	ctx->PSSetShaderResources(1, 1, &none)
	dst_rtv := dst.rtv
	ctx->OMSetRenderTargets(1, &dst_rtv, nil)
	viewport := d3d.VIEWPORT{0, 0, f32(dst_size.x), f32(dst_size.y), 0, 1}
	ctx->RSSetViewports(1, &viewport)
	ctx->OMSetBlendState(nil, nil, 0xffffffff)
	ctx->IASetPrimitiveTopology(.TRIANGLELIST)
	ctx->VSSetShader(g.vs_blur, nil, 0)
	ctx->PSSetShader(shader, nil, 0)
	set_constants(g, {half_pixel = {0.5 / f32(src_size.x), 0.5 / f32(src_size.y)}})
	ctx->PSSetConstantBuffers(0, 1, &g.constants)
	ctx->PSSetSamplers(0, 2, &g.samplers[0])
	src_srv := src.srv
	ctx->PSSetShaderResources(1, 1, &src_srv)
	ctx->Draw(3, 0)
}

// backdrop_textures makes the scene texture for a region w by h pixels and
// the levels under it, unless they're that size already.
@(private)
backdrop_textures :: proc(r: ^Renderer, w, h: int) -> bool {
	g := &r.gpu
	if g.scene.texture != nil && g.region_size == {w, h} {
		return true
	}
	free_blur_image(&g.scene, g)
	for &l in g.levels {
		free_blur_image(&l, g)
	}
	g.region_size = {}
	g.blurred_hash = 0
	g.level_size[0] = {max((w + 1) / 2, 1), max((h + 1) / 2, 1)}
	ok := make_blur_image(g, &g.scene, .B8G8R8A8_UNORM_SRGB, 4, g.level_size[0])
	for i in 0 ..< MAX_BLUR_LEVELS {
		size := g.level_size[i]
		g.level_size[i + 1] = {max((size.x + 1) / 2, 1), max((size.y + 1) / 2, 1)}
		ok &&= make_blur_image(g, &g.levels[i], .R16G16B16A16_FLOAT, 8, g.level_size[i + 1])
	}
	if ok {
		g.region_size = {w, h}
	} else {
		log.error("render: can't make the backdrop's textures")
	}
	return ok
}

@(private)
make_blur_image :: proc(g: ^Gpu, b: ^Blur_Image, format: dxgi.FORMAT, bpp: int, size: [2]int) -> bool {
	desc := d3d.TEXTURE2D_DESC {
		Width      = u32(size.x),
		Height     = u32(size.y),
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = format,
		SampleDesc = {Count = 1},
		Usage      = .DEFAULT,
		BindFlags  = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	if g.device->CreateTexture2D(&desc, nil, &b.texture) < 0 {
		b.texture = nil
		return false
	}
	b.size = size.x * size.y * bpp
	sync.atomic_add(&g.allocated, b.size)
	ok := g.device->CreateRenderTargetView((^d3d.IResource)(b.texture), nil, &b.rtv) >= 0
	ok &&= g.device->CreateShaderResourceView((^d3d.IResource)(b.texture), nil, &b.srv) >= 0
	return ok
}

@(private)
free_blur_image :: proc(b: ^Blur_Image, g: ^Gpu = nil) {
	if b.texture != nil && g != nil {
		sync.atomic_sub(&g.allocated, b.size)
	}
	com_release(&b.srv)
	com_release(&b.rtv)
	com_release(&b.texture)
	b^ = {}
}

// capture copies the drawn frame to a staging texture, waits for it and
// writes it to the capture path.
@(private)
capture :: proc(r: ^Renderer) {
	g := &r.gpu
	back: ^d3d.ITexture2D
	if g.swapchain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&back)) < 0 {
		return
	}
	defer back->Release()
	w, h := g.extent.x, g.extent.y
	desc := d3d.TEXTURE2D_DESC {
		Width          = w,
		Height         = h,
		MipLevels      = 1,
		ArraySize      = 1,
		Format         = .B8G8R8A8_UNORM,
		SampleDesc     = {Count = 1},
		Usage          = .STAGING,
		CPUAccessFlags = {.READ},
	}
	staging: ^d3d.ITexture2D
	if g.device->CreateTexture2D(&desc, nil, &staging) < 0 {
		return
	}
	defer staging->Release()
	g.ctx->CopyResource((^d3d.IResource)(staging), (^d3d.IResource)(back))
	m: d3d.MAPPED_SUBRESOURCE
	if g.ctx->Map((^d3d.IResource)(staging), 0, .READ, {}, &m) < 0 {
		return
	}
	pixels := make([]byte, int(w * h * 4), context.temp_allocator)
	for y in 0 ..< int(h) {
		row := ([^]byte)(m.pData)[y * int(m.RowPitch):]
		copy(pixels[y * int(w) * 4:][:int(w) * 4], row[:int(w) * 4])
	}
	g.ctx->Unmap((^d3d.IResource)(staging), 0)
	write_tga(r.capture_path, pixels, uint(w), uint(h))
}
