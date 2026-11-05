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
// staging buffers, fences and barriers. The instances go in one dynamic
// structured buffer, mapped by begin_frame and unmapped by end_frame;
// both shaders index it, and a constant buffer gives each draw its first
// instance, since SV_InstanceID starts at 0 for every draw.
//
// The swap chain uses the flip model, whose buffers can't be sRGB, so the
// render target view is: the buffers are BGRA8 and the view over them
// B8G8R8A8_UNORM_SRGB, and blending happens in linear space as on the
// other backends.
package render

import "core:log"
import "core:math"
import "core:mem"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import d3d "vendor:directx/d3d11"
import "vendor:directx/dxgi"

import "../platform"

BACKDROPS :: true

VS_RECT :: #load("shaders/dxbc/vs_rect.dxbc")
PS_RECT :: #load("shaders/dxbc/ps_rect.dxbc")
VS_BLUR :: #load("shaders/dxbc/vs_blur.dxbc")
PS_BLUR_DOWN :: #load("shaders/dxbc/ps_blur_down.dxbc")
PS_BLUR_UP :: #load("shaders/dxbc/ps_blur_up.dxbc")

SWAP_BUFFERS :: 2

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

Gpu :: struct {
	device:        ^d3d.IDevice,
	ctx:           ^d3d.IDeviceContext,
	window:        dxgi.HWND,
	swapchain:     ^dxgi.ISwapChain1,
	target:        ^d3d.IRenderTargetView, // the back buffer, sRGB
	extent:        [2]u32,
	vs_rect:       ^d3d.IVertexShader,
	ps_rect:       ^d3d.IPixelShader,
	vs_blur:       ^d3d.IVertexShader,
	ps_blur_down:  ^d3d.IPixelShader,
	ps_blur_up:    ^d3d.IPixelShader,
	blend:         ^d3d.IBlendState, // premultiplied over; the blur passes replace
	raster:        ^d3d.IRasterizerState,
	samplers:      [2]^d3d.ISamplerState, // linear with mips, nearest
	constants:     ^d3d.IBuffer,
	instances:     ^d3d.IBuffer,
	instances_srv: ^d3d.IShaderResourceView,
	instance_bytes: int,
	mapped:        bool, // instances is mapped, between begin_frame and end_frame
	// The backdrop, as on Vulkan: the scene at half the region's size in
	// the drawable's format, and the levels in RGBA16 float, made for the
	// region's size and kept until it changes.
	scene:         Blur_Image,
	levels:        [MAX_BLUR_LEVELS]Blur_Image,
	level_size:    [MAX_BLUR_LEVELS + 1][2]int,
	region_size:   [2]int,
	blurred_hash:  u64,
	allocated:     int, // bytes of textures and buffers; atomic
}

Gpu_Texture :: struct {
	texture: ^d3d.ITexture2D,
	srv:     ^d3d.IShaderResourceView,
	size:    int,
}

// init draws to surface, a platform.Win32_Surface. If it fails, it tears
// down what it made, so g.device is nil and the renderer draws nothing.
init :: proc(r: ^Renderer, surface: rawptr) -> (ok: bool) {
	g := &r.gpu
	defer if !ok {
		release(r)
	}
	ws := (^platform.Win32_Surface)(surface)
	if ws == nil || ws.window == nil {
		log.error("render: no window")
		return false
	}
	g.window = dxgi.HWND(ws.window)

	// A machine without a GPU driver, a VM or Wine without one, still draws
	// through WARP, Direct3D's CPU rasterizer.
	levels := [2]d3d.FEATURE_LEVEL{._11_0, ._10_0}
	flags := d3d.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT, .SINGLETHREADED}
	hr := d3d.CreateDevice(nil, .HARDWARE, nil, flags, &levels[0], len(levels), d3d.SDK_VERSION, &g.device, nil, &g.ctx)
	if hr < 0 {
		log.warnf("render: no hardware Direct3D 11 device (0x%x), trying WARP", u32(hr))
		hr = d3d.CreateDevice(nil, .WARP, nil, flags, &levels[0], len(levels), d3d.SDK_VERSION, &g.device, nil, &g.ctx)
	}
	if hr < 0 {
		log.errorf("render: D3D11CreateDevice failed: 0x%x", u32(hr))
		return false
	}
	log_adapter(g)
	init_step(&r.init_steps, "render_device")

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

	// Slot 0 is the white texture behind the zero handle.
	r.textures[0] = new_texture_slot(r, 1, 1, .RGBA8, false)
	if r.textures[0].width == 0 {
		log.error("render: can't make the white texture")
		return false
	}
	white := [4]u8{255, 255, 255, 255}
	texture_update(r, 0, white[:], 0, 0, 1, 1)
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
// nothing. It keeps the frame's counts, batches and clips, which a lost
// device can leave halfway, and the capture path the shell set. Each
// slot's generation moves on, as in texture_destroy, so no old handle
// matches.
release :: proc(r: ^Renderer) {
	g := &r.gpu
	if g.ctx != nil {
		if g.mapped {
			g.ctx->Unmap((^d3d.IResource)(g.instances), 0)
		}
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
	com_release(&g.ctx)
	com_release(&g.device)
	r.gpu = {}
	for &slot in r.textures {
		slot = {generation = slot.generation + 1}
	}
	r.instances = nil
	r.capacity = {}
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

// gpu_frame_begin maps the instance buffer for the frame and returns it,
// or nil if there is none. WRITE_DISCARD gives fresh memory while the GPU
// may still read the last frame's.
@(private)
gpu_frame_begin :: proc(r: ^Renderer) -> [^]Instance {
	g := &r.gpu
	if g.device == nil {
		return nil
	}
	r.slot_wait_ms = 0
	r.drawable_wait_ms = 0
	if g.instances == nil {
		set_instance_buffer(r, INITIAL_INSTANCES)
	}
	if g.mapped {
		g.ctx->Unmap((^d3d.IResource)(g.instances), 0)
		g.mapped = false
	}
	return map_instances(r)
}

@(private)
map_instances :: proc(r: ^Renderer) -> [^]Instance {
	g := &r.gpu
	if g.instances == nil {
		return nil
	}
	m: d3d.MAPPED_SUBRESOURCE
	if g.ctx->Map((^d3d.IResource)(g.instances), 0, .WRITE_DISCARD, {}, &m) < 0 {
		log.error("render: can't map the instance buffer")
		return nil
	}
	g.mapped = true
	return ([^]Instance)(m.pData)
}

// grow_instances replaces the buffer with one twice the size and copies
// over what this frame has pushed so far. If there's no memory for it, the
// old buffer and capacity stay.
@(private)
grow_instances :: proc(r: ^Renderer) {
	g := &r.gpu
	old, old_srv, old_bytes := g.instances, g.instances_srv, g.instance_bytes
	old_data := r.instances
	g.instances, g.instances_srv = nil, nil
	if !set_instance_buffer(r, r.capacity[r.slot] * 2) {
		g.instances, g.instances_srv, g.instance_bytes = old, old_srv, old_bytes
		return
	}
	next := map_instances(r)
	if next == nil {
		return
	}
	mem.copy(next, old_data, r.instance_count * size_of(Instance))
	g.ctx->Unmap((^d3d.IResource)(old), 0)
	sync.atomic_sub(&g.allocated, old_bytes)
	com_release(&old_srv)
	com_release(&old)
	r.instances = next
}

// set_instance_buffer makes the instance buffer, unmapped, for capacity
// instances. Every slot gets the capacity: there is one buffer.
@(private)
set_instance_buffer :: proc(r: ^Renderer, capacity: int) -> bool {
	g := &r.gpu
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
	g.instances, g.instances_srv = buffer, srv
	g.instance_bytes = int(desc.ByteWidth)
	g.mapped = false
	sync.atomic_add(&g.allocated, g.instance_bytes)
	for &c in r.capacity {
		c = capacity
	}
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
make_swapchain :: proc(g: ^Gpu, want: [2]u32) -> bool {
	com_release(&g.target)
	g.extent = {}
	if g.swapchain == nil {
		dd: ^dxgi.IDevice1
		if g.device->QueryInterface(dxgi.IDevice1_UUID, (^rawptr)(&dd)) < 0 {
			return false
		}
		defer dd->Release()
		// One frame queued ahead of the display keeps input close to what's
		// on screen; the app draws only when something changed.
		dd->SetMaximumFrameLatency(1)
		adapter: ^dxgi.IAdapter
		if dd->GetAdapter(&adapter) < 0 {
			return false
		}
		defer adapter->Release()
		factory: ^dxgi.IFactory2
		if adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory)) < 0 {
			return false
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
		if hr := factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(g.device), g.window, &desc, nil, nil, &g.swapchain); hr < 0 {
			// Windows before 10 has no FLIP_DISCARD.
			desc.SwapEffect = .FLIP_SEQUENTIAL
			if hr = factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(g.device), g.window, &desc, nil, nil, &g.swapchain); hr < 0 {
				log.errorf("render: CreateSwapChainForHwnd failed: 0x%x", u32(hr))
				g.swapchain = nil
				return false
			}
		}
		// The shell owns the window and its keys; Alt-Enter isn't fullscreen.
		factory->MakeWindowAssociation(g.window, {.NO_ALT_ENTER})
	} else {
		g.ctx->OMSetRenderTargets(0, nil, nil)
		if hr := g.swapchain->ResizeBuffers(0, want.x, want.y, .UNKNOWN, {}); hr < 0 {
			log.errorf("render: ResizeBuffers failed: 0x%x", u32(hr))
			return false
		}
	}
	back: ^d3d.ITexture2D
	if g.swapchain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&back)) < 0 {
		return false
	}
	defer back->Release()
	rtv := d3d.RENDER_TARGET_VIEW_DESC {
		Format        = .B8G8R8A8_UNORM_SRGB,
		ViewDimension = .TEXTURE2D,
	}
	if g.device->CreateRenderTargetView((^d3d.IResource)(back), &rtv, &g.target) < 0 {
		g.target = nil
		return false
	}
	g.extent = want
	return true
}

// end_frame draws the frame and presents it.
end_frame :: proc(r: ^Renderer) {
	g := &r.gpu
	defer r.frame_index += 1
	if g.device == nil {
		return
	}
	if g.mapped {
		g.ctx->Unmap((^d3d.IResource)(g.instances), 0)
		g.mapped = false
	}
	want := [2]u32{u32(math.round(r.width * r.scale)), u32(math.round(r.height * r.scale))}
	if want.x == 0 || want.y == 0 {
		return
	}
	if swapchain_stale(g, want) && !make_swapchain(g, want) {
		return
	}

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

	if r.capture_path != "" {
		capture(r)
	}
	wait := time.tick_now()
	hr := g.swapchain->Present(1, {})
	r.drawable_wait_ms = f32(time.duration_milliseconds(time.tick_since(wait)))
	if hr == dxgi.ERROR_DEVICE_REMOVED || hr == dxgi.ERROR_DEVICE_RESET {
		reason := g.device->GetDeviceRemovedReason()
		log.errorf("render: the GPU device was lost (0x%x), drawing nothing from now on", u32(reason))
		release(r)
		return
	}
	r.stats = {draw_calls, r.instance_count}
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
