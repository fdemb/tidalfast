// The Metal backend.
package render

import "core:log"
import "core:mem"
import CF "core:sys/darwin/CoreFoundation"
import NS "core:sys/darwin/Foundation"
import "core:time"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

BACKDROPS :: true

Gpu :: struct {
	device:    ^MTL.Device,
	layer:     ^CA.MetalLayer,
	queue:     ^MTL.CommandQueue,
	pipeline:  ^MTL.RenderPipelineState,
	blur_down: ^MTL.RenderPipelineState, // the dual filter's halving pass, into RGBA16Float
	blur_up:   ^MTL.RenderPipelineState, // and its doubling pass
	// The backdrop's region of the frame at half size, then the blur's
	// levels, each half the one before. Made for the region's size and kept
	// until it changes, with the blur in levels[0] kept for blurred_hash.
	scene:     ^MTL.Texture, // the drawable's format
	levels:    [MAX_BLUR_LEVELS]^MTL.Texture,
	level_size: [MAX_BLUR_LEVELS + 1][2]int, // the scene's, then the levels
	region_size: [2]int, // in the drawable's pixels
	blurred_hash: u64, // Backdrop_Pass.hash of what levels[0] holds, 0 for nothing
	// Triple buffering. Each frame writes into buffers[slot] while the GPU may
	// still read the other two. in_flight[slot] is the retained command buffer
	// that last read buffers[slot]; begin_frame waits for it before writing.
	buffers:   [FRAMES_IN_FLIGHT]^MTL.Buffer, // shared storage
	in_flight: [FRAMES_IN_FLIGHT]^MTL.CommandBuffer,
	in_flight_frame: [FRAMES_IN_FLIGHT]u64, // the frame_index each one drew
	timed_frame: u64, // the newest frame gpu_ms has come from, plus 1
}

Gpu_Texture :: struct {
	texture: ^MTL.Texture,
	// The retained command buffer that last regenerated the mips. It reads
	// the whole base level, so the next CPU write waits for it.
	mip_cmd: ^MTL.CommandBuffer,
}

// shaders/rect.metal, compiled by build.py when the Metal compiler is there.
// The library is checked in, so a build without Xcode still has it.
SHADER_LIBRARY :: #load("shaders/metallib/rect.metallib")

// init draws to surface, a CAMetalLayer, on the layer's device.
init :: proc(r: ^Renderer, surface: rawptr) -> bool {
	g := &r.gpu
	g.layer = (^CA.MetalLayer)(surface)
	g.device = g.layer->device()
	g.queue = g.device->newCommandQueue()
	if r.capture_path != "" {
		g.layer->setFramebufferOnly(false)
	}
	// Slot 0 is the white texture behind the zero handle.
	r.textures[0] = new_texture_slot(r, 1, 1, .RGBA8, false)
	white := [4]u8{255, 255, 255, 255}
	texture_update(r, 0, white[:], 0, 0, 1, 1)
	g.pipeline, g.blur_down, g.blur_up = build_pipelines(r)
	return g.pipeline != nil
}

destroy :: proc(r: ^Renderer) {
	g := &r.gpu
	for cmd in g.in_flight {
		if cmd != nil {
			cmd->waitUntilCompleted()
			release(cmd)
		}
	}
	for buf in g.buffers {
		release(buf)
	}
	for slot in r.textures {
		gpu_texture_free(r, slot.gpu)
	}
	release(g.scene)
	for t in g.levels {
		release(t)
	}
	release(g.pipeline)
	release(g.blur_down)
	release(g.blur_up)
	release(g.queue)
	r^ = {}
}

// gpu_allocated is the Metal device's currentAllocatedSize: every buffer and
// texture the app holds, in bytes. Safe from any thread.
gpu_allocated :: proc "contextless" (r: ^Renderer) -> int {
	if r.gpu.device == nil {
		return 0
	}
	return int(r.gpu.device->currentAllocatedSize())
}

// gpu_memory is what the renderer's own buffers and textures take, from
// each one's allocatedSize. The textures made with texture_create aren't
// in it, see texture_bytes.
gpu_memory :: proc(r: ^Renderer) -> Gpu_Memory {
	g := &r.gpu
	m: Gpu_Memory
	for buf in g.buffers {
		m.instances += resource_bytes(buf)
	}
	m.backdrop = resource_bytes(g.scene)
	for t in g.levels {
		m.backdrop += resource_bytes(t)
	}
	return m
}

@(private)
gpu_texture_bytes :: proc(slot: ^Texture_Slot) -> int {
	return resource_bytes(slot.gpu.texture)
}

@(private)
resource_bytes :: proc(resource: ^MTL.Resource) -> int {
	if resource == nil {
		return 0
	}
	return int(resource->allocatedSize())
}

// build_pipelines returns the rect pipeline and the blur's two, or nils
// after logging why they failed.
@(private)
build_pipelines :: proc(r: ^Renderer) -> (rect, down, up: ^MTL.RenderPipelineState) {
	err: ^NS.Error
	bytes := SHADER_LIBRARY
	// A nil destructor makes the data copy the bytes.
	data := CF.dispatch_data_create(raw_data(bytes), len(bytes), nil, nil)
	library := r.gpu.device->newLibraryWithData_error(data, &err)
	release(data)
	if library == nil {
		log.error("render: shader library failed to load:", error_string(err))
		return
	}
	defer release(library)
	init_step(&r.init_steps, "render_shaders")
	pixel_format := r.gpu.layer->pixelFormat()
	// The rect fragment shader outputs premultiplied colour.
	rect = build_pipeline(r, library, "rect_vertex", "rect_fragment", pixel_format, true)
	down = build_pipeline(r, library, "blur_vertex", "blur_down", .RGBA16Float, false)
	up = build_pipeline(r, library, "blur_vertex", "blur_up", .RGBA16Float, false)
	if rect == nil || down == nil || up == nil {
		release(rect)
		release(down)
		release(up)
		return nil, nil, nil
	}
	return
}

@(private)
build_pipeline :: proc(r: ^Renderer, library: ^MTL.Library, vertex, fragment: string, format: MTL.PixelFormat, blend: bool) -> ^MTL.RenderPipelineState {
	vs := new_function(library, vertex)
	fs := new_function(library, fragment)
	defer release(vs)
	defer release(fs)

	desc := MTL.new(MTL.RenderPipelineDescriptor)
	defer release(desc)
	desc->setVertexFunction(vs)
	desc->setFragmentFunction(fs)
	att := desc->colorAttachments()->objectAtIndexedSubscript(0)
	att->setPixelFormat(format)
	if blend {
		att->setBlendingEnabled(true)
		att->setSourceRGBBlendFactor(.One)
		att->setDestinationRGBBlendFactor(.OneMinusSourceAlpha)
		att->setSourceAlphaBlendFactor(.One)
		att->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
	}

	err: ^NS.Error
	pipeline := r.gpu.device->newRenderPipelineStateWithDescriptor_error(desc, &err)
	if pipeline == nil {
		log.errorf("render: pipeline %s failed: %s", fragment, error_string(err))
	}
	return pipeline
}

// Textures

// new_texture_slot returns a zero slot if Metal can't make the texture.
@(private)
new_texture_slot :: proc(r: ^Renderer, width, height: int, format: Texture_Format, mipmapped: bool) -> Texture_Slot {
	pixel_format: MTL.PixelFormat
	switch format {
	case .R8:
		pixel_format = .R8Unorm
	case .RGBA8:
		pixel_format = .RGBA8Unorm_sRGB
	case .BGRA8:
		pixel_format = .BGRA8Unorm_sRGB
	}
	desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(pixel_format, NS.UInteger(width), NS.UInteger(height), mipmapped)
	if format == .R8 {
		desc->setSwizzle({.Red, .Red, .Red, .Red})
	}
	texture := r.gpu.device->newTextureWithDescriptor_(desc)
	if texture == nil {
		return {}
	}
	return {gpu = {texture = texture}, width = i32(width), height = i32(height), format = format, mipmapped = mipmapped}
}

// Metal keeps a released texture alive until the command buffers that use
// it finish, so this is safe mid-flight.
@(private)
gpu_texture_free :: proc(r: ^Renderer, t: Gpu_Texture) {
	release(t.texture)
	release(t.mip_cmd)
}

@(private)
gpu_texture_write :: proc(r: ^Renderer, slot: ^Texture_Slot, pixels: []byte, x, y, w, h, bpp: int) {
	t := &slot.gpu
	if t.mip_cmd != nil {
		t.mip_cmd->waitUntilCompleted()
		release(t.mip_cmd)
		t.mip_cmd = nil
	}
	region := MTL.Region{{NS.UInteger(x), NS.UInteger(y), 0}, {NS.UInteger(w), NS.UInteger(h), 1}}
	t.texture->replaceRegion_mipmapLevel_withBytes_bytesPerRow(region, 0, raw_data(pixels), NS.UInteger(w * bpp))
	if slot.mipmapped {
		// Queued ahead of the next frame's command buffer, so the frame sees
		// the new mips.
		cmd := r.gpu.queue->commandBuffer()
		blit := cmd->blitCommandEncoder()
		blit->generateMipmapsForTexture(t.texture)
		blit->endEncoding()
		cmd->commit()
		t.mip_cmd = retain(cmd)
	}
}

@(private)
gpu_texture_copy :: proc(r: ^Renderer, from, to: ^Texture_Slot, w, h: int) {
	cmd := r.gpu.queue->commandBuffer()
	blit := cmd->blitCommandEncoder()
	blit->copyFromTexture_sourceSlice_sourceLevel_sourceOrigin_sourceSize_toTexture_destinationSlice_destinationLevel_destinationOrigin(from.gpu.texture, 0, 0, {}, {NS.UInteger(w), NS.UInteger(h), 1}, to.gpu.texture, 0, 0, {})
	blit->endEncoding()
	cmd->commit()
}

// Frame

// gpu_frame_begin waits until the GPU is done with this frame's slot and
// returns its instance buffer.
@(private)
gpu_frame_begin :: proc(r: ^Renderer) -> [^]Instance {
	g := &r.gpu
	read_gpu_time(r)
	// The GPU usually finished this slot two frames ago, so this rarely waits.
	r.slot_wait_ms = 0
	if cmd := g.in_flight[r.slot]; cmd != nil {
		wait := time.tick_now()
		cmd->waitUntilCompleted()
		r.slot_wait_ms = f32(time.duration_milliseconds(time.tick_since(wait)))
		release(cmd)
		g.in_flight[r.slot] = nil
	}
	if g.buffers[r.slot] == nil {
		g.buffers[r.slot] = new_instance_buffer(r, INITIAL_INSTANCES)
		r.capacity[r.slot] = INITIAL_INSTANCES
	}
	return ([^]Instance)(g.buffers[r.slot]->contents())
}

// read_gpu_time sets gpu_ms from the newest command buffer the GPU has
// finished that it hasn't read yet, without waiting for any.
@(private)
read_gpu_time :: proc(r: ^Renderer) {
	g := &r.gpu
	newest := -1
	for cmd, i in g.in_flight {
		if cmd == nil || g.in_flight_frame[i] < g.timed_frame {
			continue
		}
		if cmd->status() != .Completed {
			continue
		}
		if newest < 0 || g.in_flight_frame[i] > g.in_flight_frame[newest] {
			newest = i
		}
	}
	if newest < 0 {
		return
	}
	cmd := g.in_flight[newest]
	start := cmd->GPUStartTime()
	end := cmd->GPUEndTime()
	r.gpu_ms = f32((end - start) * 1000)
	g.timed_frame = g.in_flight_frame[newest] + 1
}

// grow_instances replaces the current slot's buffer with one twice the size
// and copies over what this frame has pushed so far. begin_frame waited for
// the slot's last command buffer and nothing has read this frame's buffer
// yet, so releasing the old one is safe. The bigger buffer stays with the
// slot for later frames.
@(private)
grow_instances :: proc(r: ^Renderer) {
	capacity := r.capacity[r.slot] * 2
	buf := new_instance_buffer(r, capacity)
	instances := ([^]Instance)(buf->contents())
	mem.copy(instances, r.instances, r.instance_count * size_of(Instance))
	release(r.gpu.buffers[r.slot])
	r.gpu.buffers[r.slot] = buf
	r.capacity[r.slot] = capacity
	r.instances = instances
}

@(private)
new_instance_buffer :: proc(r: ^Renderer, capacity: int) -> ^MTL.Buffer {
	// No options is shared storage with the default CPU cache mode.
	return r.gpu.device->newBufferWithLength_options(NS.UInteger(capacity * size_of(Instance)), {})
}

// end_frame encodes the frame and presents it. The caller must be inside an
// autorelease pool; the shell wraps every frame in one.
end_frame :: proc(r: ^Renderer) {
	g := &r.gpu
	// Counts frames that drew nothing too, so frame_index - FRAMES_IN_FLIGHT
	// is always a frame the GPU has finished once begin_frame returns.
	defer r.frame_index += 1
	if g.pipeline == nil || r.width <= 0 || r.height <= 0 {
		return
	}
	wait := time.tick_now()
	drawable := g.layer->nextDrawable()
	r.drawable_wait_ms = f32(time.duration_milliseconds(time.tick_since(wait)))
	if drawable == nil {
		return
	}
	texture := drawable->texture()
	tex_w := uint(texture->width())
	tex_h := uint(texture->height())

	cmd := g.queue->commandBuffer()
	draw_calls := 0
	blurred: ^MTL.Texture
	if r.backdrop.batch >= 0 {
		blurred, draw_calls = encode_backdrop(r, cmd)
	}

	enc := begin_pass(cmd, texture, r.clear)
	draw_calls += draw_batches(r, enc, r.batches[:r.batch_count], {0, 0, f32(tex_w), f32(tex_h)}, 1, blurred)
	enc->endEncoding()

	capture: ^MTL.Buffer
	if r.capture_path != "" {
		capture = encode_capture(r, cmd, texture, tex_w, tex_h)
	}

	cmd->presentDrawable_(drawable)
	cmd->commit()
	// commandBuffer returns an autoreleased object; keep it until begin_frame
	// comes back to this slot.
	g.in_flight[r.slot] = retain(cmd)
	g.in_flight_frame[r.slot] = r.frame_index
	r.stats = {draw_calls, r.instance_count}

	if capture != nil {
		cmd->waitUntilCompleted()
		write_tga(r.capture_path, ([^]byte)(capture->contents())[:tex_w * tex_h * 4], tex_w, tex_h)
		release(capture)
	}
}

// begin_pass starts a render pass on texture, cleared to clear.
@(private)
begin_pass :: proc(cmd: ^MTL.CommandBuffer, texture: ^MTL.Texture, clear: Color) -> ^MTL.RenderCommandEncoder {
	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	color := pass->colorAttachments()->objectAtIndexedSubscript(0)
	color->setTexture(texture)
	color->setLoadAction(.Clear)
	color->setStoreAction(.Store)
	// The targets are sRGB, so the clear colour is given in linear.
	color->setClearColor({f64(linear_from_srgb(clear.r)), f64(linear_from_srgb(clear.g)), f64(linear_from_srgb(clear.b)), f64(clear.a)})
	return cmd->renderCommandEncoderWithDescriptor(pass)
}

// draw_batches draws batches into a target covering target (x, y, w, h) of
// the drawable's pixels, with scale of them to a target pixel and blurred
// as the backdrop's texture, and returns the draw calls.
@(private)
draw_batches :: proc(r: ^Renderer, enc: ^MTL.RenderCommandEncoder, batches: []Batch, target: [4]f32, scale: [2]f32, blurred: ^MTL.Texture) -> int {
	g := &r.gpu
	if r.instance_count == 0 {
		return 0
	}
	target, origin := target, [4]f32{target.x, target.y, scale.x, scale.y}
	buf := g.buffers[r.slot]
	white := r.textures[0].gpu.texture
	enc->setRenderPipelineState(g.pipeline)
	enc->setVertexBuffer_offset_atIndex(buf, 0, 0)
	enc->setFragmentBuffer(buf, 0, 0)
	enc->setVertexBytes_length_atIndex(&target, size_of(target), 1)
	enc->setFragmentBytes_(&origin, size_of(origin), 1)
	enc->setFragmentTexture(blurred if blurred != nil else white, 2)
	draw_calls := 0
	for b in batches {
		if b.count == 0 {
			continue
		}
		for t, index in b.textures {
			slot := texture_slot(r, t)
			tex := slot.gpu.texture if slot != nil else white
			enc->setFragmentTexture(tex, NS.UInteger(index))
		}
		enc->drawPrimitives_vertexStart_vertexCount_instanceCount_baseInstance(.TriangleStrip, 0, 4, NS.UInteger(b.count), NS.UInteger(b.first))
		draw_calls += 1
	}
	return draw_calls
}

// encode_backdrop draws the batches before the backdrop into the scene
// texture at half size, blurs it down its levels and back up, and returns
// the level the backdrop samples and the draw calls it took. When what the
// blur reads hasn't changed since it last ran, it returns that blur as it
// is and draws nothing.
@(private)
encode_backdrop :: proc(r: ^Renderer, cmd: ^MTL.CommandBuffer) -> (blurred: ^MTL.Texture, draw_calls: int) {
	g := &r.gpu
	bd := r.backdrop
	w, h := int(bd.region.z - bd.region.x), int(bd.region.w - bd.region.y)
	if g.blur_down == nil || !backdrop_textures(r, w, h) {
		return nil, 0
	}
	if bd.hash == g.blurred_hash {
		return g.levels[0], 0
	}
	scene := g.level_size[0]
	enc := begin_pass(cmd, g.scene, r.clear)
	scale := [2]f32{f32(w) / f32(scene.x), f32(h) / f32(scene.y)}
	draw_calls = draw_batches(r, enc, r.batches[:bd.batch], {bd.region.x, bd.region.y, f32(w), f32(h)}, scale, nil)
	enc->endEncoding()

	// Drawing the scene at half size was the first halving.
	src := g.scene
	for i in 0 ..< bd.levels - 1 {
		blur_pass(cmd, g.blur_down, src, g.levels[i], g.level_size[i])
		src = g.levels[i]
	}
	for i := bd.levels - 2; i > 0; i -= 1 {
		blur_pass(cmd, g.blur_up, g.levels[i], g.levels[i - 1], g.level_size[i + 1])
	}
	g.blurred_hash = bd.hash
	return g.levels[0], draw_calls + 2 * bd.levels - 3
}

// blur_pass draws one pass of the dual filter from src, src_size texels,
// into dst.
@(private)
blur_pass :: proc(cmd: ^MTL.CommandBuffer, pipeline: ^MTL.RenderPipelineState, src, dst: ^MTL.Texture, src_size: [2]int) {
	pass := MTL.RenderPassDescriptor.renderPassDescriptor()
	color := pass->colorAttachments()->objectAtIndexedSubscript(0)
	color->setTexture(dst)
	color->setLoadAction(.DontCare)
	color->setStoreAction(.Store)
	enc := cmd->renderCommandEncoderWithDescriptor(pass)
	half_pixel := [2]f32{0.5 / f32(src_size.x), 0.5 / f32(src_size.y)}
	enc->setRenderPipelineState(pipeline)
	enc->setFragmentTexture(src, 0)
	enc->setFragmentBytes_(&half_pixel, size_of(half_pixel), 0)
	enc->drawPrimitives_vertexStart_vertexCount(.Triangle, 0, 3)
	enc->endEncoding()
}

// backdrop_textures makes the scene texture for a region w by h pixels
// and the levels under it, unless they're that size already.
@(private)
backdrop_textures :: proc(r: ^Renderer, w, h: int) -> bool {
	g := &r.gpu
	if g.scene != nil && g.region_size == {w, h} {
		return true
	}
	release(g.scene)
	for &t in g.levels {
		release(t)
		t = nil
	}
	g.region_size = {}
	g.blurred_hash = 0
	pixel_format := g.layer->pixelFormat()
	g.level_size[0] = {max((w + 1) / 2, 1), max((h + 1) / 2, 1)}
	g.scene = render_texture(r, pixel_format, g.level_size[0].x, g.level_size[0].y)
	ok := g.scene != nil
	for i in 0 ..< MAX_BLUR_LEVELS {
		size := g.level_size[i]
		g.level_size[i + 1] = {max((size.x + 1) / 2, 1), max((size.y + 1) / 2, 1)}
		g.levels[i] = render_texture(r, .RGBA16Float, g.level_size[i + 1].x, g.level_size[i + 1].y)
		ok &&= g.levels[i] != nil
	}
	if ok {
		g.region_size = {w, h}
	}
	return ok
}

// render_texture is a texture passes draw into and later ones sample.
@(private)
render_texture :: proc(r: ^Renderer, format: MTL.PixelFormat, w, h: int) -> ^MTL.Texture {
	desc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(format, NS.UInteger(w), NS.UInteger(h), false)
	desc->setUsage({.ShaderRead, .RenderTarget})
	desc->setStorageMode(.Private)
	return r.gpu.device->newTextureWithDescriptor_(desc)
}

@(private)
encode_capture :: proc(r: ^Renderer, cmd: ^MTL.CommandBuffer, texture: ^MTL.Texture, w, h: uint) -> ^MTL.Buffer {
	buf := r.gpu.device->newBufferWithLength_options(NS.UInteger(w * h * 4), {}) // shared
	blit := cmd->blitCommandEncoder()
	blit->copyFromTexture_sourceSlice_sourceLevel_sourceOrigin_sourceSize_toBuffer_destinationOffset_destinationBytesPerRow_destinationBytesPerImage(texture, 0, 0, {}, {NS.UInteger(w), NS.UInteger(h), 1}, buf, 0, NS.UInteger(w * 4), NS.UInteger(w * h * 4))
	blit->endEncoding()
	return buf
}

// release releases obj unless it's nil.
release :: proc "contextless" (obj: ^$T) {
	if obj != nil {
		(^NS.Object)(obj)->release()
	}
}

retain :: proc "contextless" (obj: ^$T) -> ^T {
	(^NS.Object)(obj)->retain()
	return obj
}

// new_function returns the library's function called name, or nil.
@(private)
new_function :: proc "contextless" (library: ^MTL.Library, name: string) -> ^MTL.Function {
	ns_name := NS.String.alloc()->initWithBytes(raw_data(name), NS.UInteger(len(name)), NS.UTF8StringEncoding)
	defer release(ns_name)
	return library->newFunctionWithName_(ns_name)
}

// error_string returns the localized description of an NSError. The string
// lives as long as the current autorelease pool.
@(private)
error_string :: proc "contextless" (err: ^NS.Error) -> string {
	if err == nil {
		return "unknown error"
	}
	return err->localizedDescription()->odinString()
}
