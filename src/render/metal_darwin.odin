// The Metal backend.
package render

import "core:log"
import "core:mem"
import MTL "vendor:darwin/Metal"

// The Metal objects are owned by the Obj-C runtime, not by the dylib, so
// they survive a reload. The pipeline is rebuilt on reload because the
// shader source lives in the dylib.
Gpu :: struct {
	device:    id, // id<MTLDevice>
	layer:     id, // CAMetalLayer*
	queue:     id, // id<MTLCommandQueue>
	pipeline:  id, // id<MTLRenderPipelineState>
	// Triple buffering. Each frame writes into buffers[slot] while the GPU may
	// still read the other two. in_flight[slot] is the retained command buffer
	// that last read buffers[slot]; begin_frame waits for it before writing.
	buffers:   [FRAMES_IN_FLIGHT]id, // id<MTLBuffer>, shared storage
	in_flight: [FRAMES_IN_FLIGHT]id, // id<MTLCommandBuffer>
}

Gpu_Texture :: struct {
	texture: id, // id<MTLTexture>
	// The retained command buffer that last regenerated the mips. It reads
	// the whole base level, so the next CPU write waits for it.
	mip_cmd: id,
}

// Compiled at runtime with newLibraryWithSource. The Metal compiler is not
// part of the command line tools, and keeping the source here means shader
// edits hot reload with the rest of the dylib.
SHADER_SOURCE :: `
#include <metal_stdlib>
using namespace metal;

struct Instance {
	float4 dst;
	float4 src;
	float4 colors[4];
	float4 radii;
	float border;
	float softness;
	uint flags;
	float pad;
	float4 clip;
};

constant uint TEXTURED = 1;
constant uint NEAREST = 2;
constant uint COVERAGE = 4;

struct Fragment_In {
	float4 position [[position]];
	uint iid [[flat]];
};

// Signed distance from p to a box centred on the origin with rounded corners.
// Negative inside.
float box_sdf(float2 p, float2 half_size, float r) {
	float2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Coverage of the inside of an edge at signed distance d, blurred over w
// pixels either side. w = 0.5 is plain antialiasing.
float inside(float d, float w) {
	return 1.0 - smoothstep(-w, w, d);
}

float3 linear_from_srgb(float3 c) {
	return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

float4 premultiply(float4 c) {
	return float4(c.rgb * c.a, c.a);
}

// The quad covers the rect plus its soft edge, cut down to the clip rect.
// The fragment shader works from the pixel position alone, so clipping the
// quad clips the shape exactly, and a clipped-away instance costs no pixels.
vertex Fragment_In rect_vertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               device const Instance *instances [[buffer(0)]],
                               constant float2 &viewport [[buffer(1)]]) {
	Instance r = instances[iid];
	float pad = max(r.softness, 0.5) + 1.0;
	float2 p0 = max(r.dst.xy - pad, r.clip.xy);
	float2 p1 = max(min(r.dst.zw + pad, r.clip.zw), p0);
	float2 p = mix(p0, p1, float2(vid & 1, vid >> 1));
	Fragment_In out;
	out.position = float4(p / viewport * float2(2, -2) + float2(-1, 1), 0, 1);
	out.iid = iid;
	return out;
}

fragment float4 rect_fragment(Fragment_In in [[stage_in]],
                              device const Instance *instances [[buffer(0)]],
                              texture2d<float> colour_tex [[texture(0)]],
                              texture2d<float> coverage_tex [[texture(1)]]) {
	constexpr sampler linear_sampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
	constexpr sampler nearest_sampler(filter::nearest, address::clamp_to_edge);

	Instance r = instances[in.iid];
	float2 pixel = in.position.xy; // pixel centre, top left origin
	float2 size = max(r.dst.zw - r.dst.xy, 1e-4);
	float2 half_size = size * 0.5;
	float2 local = pixel - (r.dst.xy + half_size);
	float2 t = (pixel - r.dst.xy) / size;

	float radius = local.y < 0 ? (local.x < 0 ? r.radii.x : r.radii.y)
	                           : (local.x < 0 ? r.radii.z : r.radii.w);
	radius = min(radius, min(half_size.x, half_size.y));
	float w = max(r.softness, 0.5);
	float coverage = inside(box_sdf(local, half_size, radius), w);
	if (r.border > 0) {
		float inner = box_sdf(local, half_size - r.border, max(radius - r.border, 0.0));
		coverage *= 1.0 - inside(inner, w);
	}

	float2 tc = saturate(t);
	float4 top = mix(premultiply(r.colors[0]), premultiply(r.colors[1]), tc.x);
	float4 bottom = mix(premultiply(r.colors[2]), premultiply(r.colors[3]), tc.x);
	float4 c = mix(top, bottom, tc.y);
	float3 rgb = c.a > 0 ? c.rgb / c.a : float3(0);
	float4 color = float4(linear_from_srgb(rgb) * c.a, c.a);

	if (r.flags & TEXTURED) {
		float2 uv = mix(r.src.xy, r.src.zw, t);
		if (r.flags & COVERAGE) {
			color *= (r.flags & NEAREST) ? coverage_tex.sample(nearest_sampler, uv) : coverage_tex.sample(linear_sampler, uv);
		} else {
			color *= (r.flags & NEAREST) ? colour_tex.sample(nearest_sampler, uv) : colour_tex.sample(linear_sampler, uv);
		}
	}
	return color * coverage;
}
`

// init draws to surface, a CAMetalLayer, on the layer's device.
init :: proc(r: ^Renderer, surface: rawptr) -> bool {
	g := &r.gpu
	g.layer = surface
	g.device = msg(g.layer, "device")
	g.queue = msg(g.device, "newCommandQueue")
	if r.capture_path != "" {
		msg_bool(g.layer, "setFramebufferOnly:", false)
	}
	// Slot 0 is the white texture behind the zero handle.
	r.textures[0] = new_texture_slot(r, 1, 1, .RGBA8, false)
	white := [4]u8{255, 255, 255, 255}
	texture_update(r, 0, white[:], 0, 0, 1, 1)
	g.pipeline = build_pipeline(r)
	return g.pipeline != nil
}

// reload rebuilds the pipeline from this dylib's shader source. If that
// fails, the old pipeline stays in place and reload returns false.
reload :: proc(r: ^Renderer) -> bool {
	pipeline := build_pipeline(r)
	if pipeline == nil {
		return false
	}
	release(r.gpu.pipeline)
	r.gpu.pipeline = pipeline
	return true
}

destroy :: proc(r: ^Renderer) {
	g := &r.gpu
	for &cmd in g.in_flight {
		if cmd != nil {
			msg(cmd, "waitUntilCompleted")
			release(cmd)
		}
	}
	for buf in g.buffers {
		release(buf)
	}
	for slot in r.textures {
		gpu_texture_free(slot.gpu)
	}
	release(g.pipeline)
	release(g.queue)
	r^ = {}
}

// gpu_allocated is the Metal device's currentAllocatedSize: every buffer and
// texture the app holds, in bytes. Safe from any thread.
gpu_allocated :: proc "contextless" (r: ^Renderer) -> int {
	if r.gpu.device == nil {
		return 0
	}
	return int(msg_proc(proc "c" (id, SEL) -> uint)(r.gpu.device, sel_registerName("currentAllocatedSize")))
}

// build_pipeline returns a new pipeline, or nil after logging why it failed.
@(private)
build_pipeline :: proc(r: ^Renderer) -> id {
	err: id
	library := msg_proc(proc "c" (id, SEL, id, id, ^id) -> id)(r.gpu.device, sel_registerName("newLibraryWithSource:options:error:"), ns_string(SHADER_SOURCE), nil, &err)
	if library == nil {
		log.error("render: shader compile failed:", error_string(err))
		return nil
	}
	defer release(library)

	vs := msg_id(library, "newFunctionWithName:", ns_string("rect_vertex"))
	fs := msg_id(library, "newFunctionWithName:", ns_string("rect_fragment"))
	defer release(vs)
	defer release(fs)

	desc := new_object("MTLRenderPipelineDescriptor")
	defer release(desc)
	msg_id(desc, "setVertexFunction:", vs)
	msg_id(desc, "setFragmentFunction:", fs)
	att := msg_uint(msg(desc, "colorAttachments"), "objectAtIndexedSubscript:", 0)
	pixel_format := msg_proc(proc "c" (id, SEL) -> MTL.PixelFormat)(r.gpu.layer, sel_registerName("pixelFormat"))
	msg_uint(att, "setPixelFormat:", uint(pixel_format))
	// The fragment shader outputs premultiplied colour.
	msg_bool(att, "setBlendingEnabled:", true)
	msg_uint(att, "setSourceRGBBlendFactor:", uint(MTL.BlendFactor.One))
	msg_uint(att, "setDestinationRGBBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))
	msg_uint(att, "setSourceAlphaBlendFactor:", uint(MTL.BlendFactor.One))
	msg_uint(att, "setDestinationAlphaBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))

	pipeline := msg_proc(proc "c" (id, SEL, id, ^id) -> id)(r.gpu.device, sel_registerName("newRenderPipelineStateWithDescriptor:error:"), desc, &err)
	if pipeline == nil {
		log.error("render: pipeline failed:", error_string(err))
		return nil
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
	desc := msg_proc(proc "c" (id, SEL, uint, uint, uint, bool) -> id)(objc_getClass("MTLTextureDescriptor"), sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"), uint(pixel_format), uint(width), uint(height), mipmapped)
	if format == .R8 {
		swizzle := MTL.TextureSwizzleChannels{.Red, .Red, .Red, .Red}
		msg_proc(proc "c" (id, SEL, MTL.TextureSwizzleChannels))(desc, sel_registerName("setSwizzle:"), swizzle)
	}
	texture := msg_id(r.gpu.device, "newTextureWithDescriptor:", desc)
	if texture == nil {
		return {}
	}
	return {gpu = {texture = texture}, width = i32(width), height = i32(height), format = format, mipmapped = mipmapped}
}

// Metal keeps a released texture alive until the command buffers that use
// it finish, so this is safe mid-flight.
@(private)
gpu_texture_free :: proc(t: Gpu_Texture) {
	release(t.texture)
	release(t.mip_cmd)
}

@(private)
gpu_texture_write :: proc(r: ^Renderer, slot: ^Texture_Slot, pixels: []byte, x, y, w, h, bpp: int) {
	t := &slot.gpu
	if t.mip_cmd != nil {
		msg(t.mip_cmd, "waitUntilCompleted")
		release(t.mip_cmd)
		t.mip_cmd = nil
	}
	region := Region{{uint(x), uint(y), 0}, {uint(w), uint(h), 1}}
	msg_proc(proc "c" (id, SEL, Region, uint, rawptr, uint))(t.texture, sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), region, 0, raw_data(pixels), uint(w * bpp))
	if slot.mipmapped {
		// Queued ahead of the next frame's command buffer, so the frame sees
		// the new mips.
		cmd := msg(r.gpu.queue, "commandBuffer")
		blit := msg(cmd, "blitCommandEncoder")
		msg_id(blit, "generateMipmapsForTexture:", t.texture)
		msg(blit, "endEncoding")
		msg(cmd, "commit")
		t.mip_cmd = msg(cmd, "retain")
	}
}

@(private)
gpu_texture_copy :: proc(r: ^Renderer, from, to: ^Texture_Slot, w, h: int) {
	cmd := msg(r.gpu.queue, "commandBuffer")
	blit := msg(cmd, "blitCommandEncoder")
	msg_proc(proc "c" (id, SEL, id, uint, uint, Origin, Size, id, uint, uint, Origin))(
		blit,
		sel_registerName("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"),
		from.gpu.texture, 0, 0, {}, {uint(w), uint(h), 1}, to.gpu.texture, 0, 0, {},
	)
	msg(blit, "endEncoding")
	msg(cmd, "commit")
}

// Frame

// gpu_frame_begin waits until the GPU is done with this frame's slot and
// returns its instance buffer.
@(private)
gpu_frame_begin :: proc(r: ^Renderer) -> [^]Instance {
	g := &r.gpu
	// The GPU usually finished this slot two frames ago, so this rarely waits.
	if cmd := g.in_flight[r.slot]; cmd != nil {
		msg(cmd, "waitUntilCompleted")
		release(cmd)
		g.in_flight[r.slot] = nil
	}
	if g.buffers[r.slot] == nil {
		g.buffers[r.slot] = new_instance_buffer(r, INITIAL_INSTANCES)
		r.capacity[r.slot] = INITIAL_INSTANCES
	}
	return ([^]Instance)(msg(g.buffers[r.slot], "contents"))
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
	instances := ([^]Instance)(msg(buf, "contents"))
	mem.copy(instances, r.instances, r.instance_count * size_of(Instance))
	release(r.gpu.buffers[r.slot])
	r.gpu.buffers[r.slot] = buf
	r.capacity[r.slot] = capacity
	r.instances = instances
}

@(private)
new_instance_buffer :: proc(r: ^Renderer, capacity: int) -> id {
	return msg_proc(proc "c" (id, SEL, uint, uint) -> id)(r.gpu.device, sel_registerName("newBufferWithLength:options:"), uint(capacity * size_of(Instance)), MTL_RESOURCE_STORAGE_MODE_SHARED)
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
	drawable := msg(g.layer, "nextDrawable")
	if drawable == nil {
		return
	}
	texture := msg(drawable, "texture")
	tex_w := msg_proc(proc "c" (id, SEL) -> uint)(texture, sel_registerName("width"))
	tex_h := msg_proc(proc "c" (id, SEL) -> uint)(texture, sel_registerName("height"))

	pass := msg(objc_getClass("MTLRenderPassDescriptor"), "renderPassDescriptor")
	color := msg_uint(msg(pass, "colorAttachments"), "objectAtIndexedSubscript:", 0)
	msg_id(color, "setTexture:", texture)
	msg_uint(color, "setLoadAction:", uint(MTL.LoadAction.Clear))
	msg_uint(color, "setStoreAction:", uint(MTL.StoreAction.Store))
	// The drawable is sRGB, so the clear colour is given in linear.
	clear := MTL.ClearColor{f64(linear_from_srgb(r.clear.r)), f64(linear_from_srgb(r.clear.g)), f64(linear_from_srgb(r.clear.b)), f64(r.clear.a)}
	msg_proc(proc "c" (id, SEL, MTL.ClearColor))(color, sel_registerName("setClearColor:"), clear)

	cmd := msg(g.queue, "commandBuffer")
	enc := msg_id(cmd, "renderCommandEncoderWithDescriptor:", pass)
	draw_calls := 0
	if r.instance_count > 0 {
		viewport := [2]f32{f32(tex_w), f32(tex_h)}
		buf := g.buffers[r.slot]
		msg_id(enc, "setRenderPipelineState:", g.pipeline)
		msg_proc(proc "c" (id, SEL, id, uint, uint))(enc, sel_registerName("setVertexBuffer:offset:atIndex:"), buf, 0, 0)
		msg_proc(proc "c" (id, SEL, id, uint, uint))(enc, sel_registerName("setFragmentBuffer:offset:atIndex:"), buf, 0, 0)
		msg_proc(proc "c" (id, SEL, rawptr, uint, uint))(enc, sel_registerName("setVertexBytes:length:atIndex:"), &viewport, size_of(viewport), 1)
		for b in r.batches[:r.batch_count] {
			if b.count == 0 {
				continue
			}
			for t, index in b.textures {
				slot := texture_slot(r, t)
				tex := slot.gpu.texture if slot != nil else r.textures[0].gpu.texture
				msg_proc(proc "c" (id, SEL, id, uint))(enc, sel_registerName("setFragmentTexture:atIndex:"), tex, uint(index))
			}
			msg_proc(proc "c" (id, SEL, uint, uint, uint, uint, uint))(enc, sel_registerName("drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:"), uint(MTL.PrimitiveType.TriangleStrip), 0, 4, uint(b.count), uint(b.first))
			draw_calls += 1
		}
	}
	msg(enc, "endEncoding")

	capture: id
	if r.capture_path != "" {
		capture = encode_capture(r, cmd, texture, tex_w, tex_h)
	}

	msg_id(cmd, "presentDrawable:", drawable)
	msg(cmd, "commit")
	// commandBuffer returns an autoreleased object; keep it until begin_frame
	// comes back to this slot.
	g.in_flight[r.slot] = msg(cmd, "retain")
	r.stats = {draw_calls, r.instance_count}

	if capture != nil {
		msg(cmd, "waitUntilCompleted")
		write_tga(r.capture_path, ([^]byte)(msg(capture, "contents"))[:tex_w * tex_h * 4], tex_w, tex_h)
		release(capture)
	}
}

@(private)
MTL_RESOURCE_STORAGE_MODE_SHARED :: 0

// MTLOrigin, MTLSize and MTLRegion. Plain structs rather than the vendor
// types, whose Origin is an array, so they pass by value the way C expects.
@(private)
Origin :: struct {
	x, y, z: uint,
}
@(private)
Size :: struct {
	width, height, depth: uint,
}
@(private)
Region :: struct {
	origin: Origin,
	size:   Size,
}

@(private)
encode_capture :: proc(r: ^Renderer, cmd, texture: id, w, h: uint) -> id {
	buf := msg_proc(proc "c" (id, SEL, uint, uint) -> id)(r.gpu.device, sel_registerName("newBufferWithLength:options:"), w * h * 4, MTL_RESOURCE_STORAGE_MODE_SHARED)
	blit := msg(cmd, "blitCommandEncoder")
	msg_proc(proc "c" (id, SEL, id, uint, uint, Origin, Size, id, uint, uint, uint))(
		blit,
		sel_registerName("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:"),
		texture, 0, 0, {}, {w, h, 1}, buf, 0, w * 4, w * h * 4,
	)
	msg(blit, "endEncoding")
	return buf
}
