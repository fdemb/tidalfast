// The instanced rect renderer. Every shape is one instance of a quad: a
// rounded box drawn with a signed distance function, with an optional border,
// soft edge, per-corner colours, texture and clip rect. Solid rects, borders,
// shadows, gradients, images and glyphs all go through the same pipeline. A
// draw call binds one colour texture and one coverage (R8) texture, so
// covers and the text next to them share a draw call; a frame takes one
// more only when it needs another texture of a kind already bound.
//
// Units: the app passes points. Push procs multiply by the backing scale and
// write physical pixels into the instance, rounding rect edges, clip rects
// and borders to whole pixels so edges land on the pixel grid.
//
// Colour: the API takes sRGB colours with straight alpha, the same numbers a
// design tool shows. Instances keep them that way. The fragment shader
// interpolates corner colours in premultiplied sRGB, so gradients match CSS,
// then converts to linear once. The drawable is BGRA8Unorm_sRGB, so the GPU
// blends in linear space and encodes back to sRGB when it stores. Textures
// are sRGB formats too (sampling returns linear) except R8, which holds linear
// coverage. Text in phase 2 relies on this: glyph coverage is blended in
// linear light. Colour textures hold premultiplied linear values, sRGB
// encoded, so the hardware decodes before filtering and gets premultiplied
// linear out; texture_update converts to that from ordinary premultiplied
// sRGB.
package render

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import MTL "vendor:darwin/Metal"

FRAMES_IN_FLIGHT :: 3
INITIAL_INSTANCES :: 4096
MAX_BATCHES :: 4096
MAX_CLIP_DEPTH :: 64
MAX_TEXTURES :: 4096

Rect :: struct {
	x, y, w, h: f32, // points, origin top left
}

// sRGB, straight alpha, 0 to 1.
Color :: [4]f32

WHITE :: Color{1, 1, 1, 1}

Corner :: enum {
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
}

// Style is everything about a rect except where it is. The zero value is a
// transparent, square, solid rect.
Style :: struct {
	colors:   [Corner]Color,
	radii:    [Corner]f32, // points
	border:   f32, // points; 0 fills the rect
	softness: f32, // points of edge blur, centred on the edge
	texture:  Texture, // zero draws solid colour
	src:      Rect, // texels; zero means the whole texture
	nearest:  bool, // sample without filtering
}

// A handle into the renderer's texture table: slot index in the low 16 bits,
// the slot's generation in the high 16, so a handle to a destroyed texture
// draws as solid colour instead of whatever reused the slot. The zero handle
// is the 1x1 white texture, which means "solid".
Texture :: distinct u32

Texture_Format :: enum u8 {
	R8, // linear coverage, sampled as premultiplied white (r, r, r, r)
	RGBA8, // premultiplied sRGB, see texture_update
	BGRA8, // premultiplied sRGB, see texture_update
}

Instance_Flag :: enum u32 {
	Textured,
	Nearest,
	Coverage, // sample the R8 texture, bound in its own slot
}
Instance_Flags :: bit_set[Instance_Flag; u32]

// One rect as the shader sees it, all in physical pixels. Matches `Instance`
// in SHADER_SOURCE.
Instance :: struct {
	dst:      [4]f32, // x0 y0 x1 y1
	src:      [4]f32, // u0 v0 u1 v1, normalized
	colors:   [4]Color, // sRGB straight alpha, in Corner order
	radii:    [4]f32, // in Corner order
	border:   f32,
	softness: f32,
	flags:    Instance_Flags,
	_:        f32,
	clip:     [4]f32, // x0 y0 x1 y1
}
#assert(size_of(Instance) == 144)

// A run of instances drawn with one colour and one coverage texture bound.
// Solid instances don't sample, so they join whatever batch is open; only
// an instance needing a texture other than the one its kind's slot holds
// starts a new batch.
Batch :: struct {
	textures: [2]Texture, // colour, coverage; zero until an instance needs one
	first:    u32,
	count:    u32,
}

Texture_Slot :: struct {
	texture:    id, // id<MTLTexture>
	width:      i32,
	height:     i32,
	generation: u16,
	format:     Texture_Format,
	mipmapped:  bool,
	// The retained command buffer that last regenerated the mips. It reads
	// the whole base level, so the next CPU write waits for it.
	mip_cmd:    id,
}

Stats :: struct {
	draw_calls: int,
	instances:  int,
}

// Renderer is plain data so it can live in the app's persistent memory. The
// Metal objects are owned by the Obj-C runtime, not by the dylib, so they
// survive a reload. The pipeline is rebuilt on reload because the shader
// source lives in the dylib.
Renderer :: struct {
	device:         id, // id<MTLDevice>
	layer:          id, // CAMetalLayer*
	queue:          id, // id<MTLCommandQueue>
	pipeline:       id, // id<MTLRenderPipelineState>
	textures:       [MAX_TEXTURES]Texture_Slot,

	// Triple buffering. Each frame writes into buffers[slot] while the GPU may
	// still read the other two. in_flight[slot] is the retained command buffer
	// that last read buffers[slot]; begin_frame waits for it before writing.
	frame_index:    u64,
	slot:           int,
	buffers:        [FRAMES_IN_FLIGHT]id, // id<MTLBuffer>, shared storage
	capacity:       [FRAMES_IN_FLIGHT]int, // in instances
	in_flight:      [FRAMES_IN_FLIGHT]id, // id<MTLCommandBuffer>

	// The frame being built.
	width, height:  f32, // points
	scale:          f32,
	clear:          Color,
	instances:      [^]Instance, // contents of buffers[slot]
	instance_count: int,
	batches:        [MAX_BATCHES]Batch,
	batch_count:    int,
	clips:          [MAX_CLIP_DEPTH][4]f32, // pixels
	clip_depth:     int,

	stats:          Stats, // of the last frame end_frame drew
	// Debug: when set, end_frame waits for the GPU and writes each frame to
	// this path as a TGA. Set it before init.
	capture_path:   string,
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

init :: proc(r: ^Renderer, device, layer: rawptr) -> bool {
	r.device = device
	r.layer = layer
	r.queue = msg(r.device, "newCommandQueue")
	if r.capture_path != "" {
		msg_bool(r.layer, "setFramebufferOnly:", false)
	}
	// Slot 0 is the white texture behind the zero handle.
	r.textures[0] = new_texture_slot(r, 1, 1, .RGBA8, false)
	white := [4]u8{255, 255, 255, 255}
	texture_update(r, 0, white[:], 0, 0, 1, 1)
	r.pipeline = build_pipeline(r)
	return r.pipeline != nil
}

// reload rebuilds the pipeline from this dylib's shader source. If that
// fails, the old pipeline stays in place and reload returns false.
reload :: proc(r: ^Renderer) -> bool {
	pipeline := build_pipeline(r)
	if pipeline == nil {
		return false
	}
	release(r.pipeline)
	r.pipeline = pipeline
	return true
}

destroy :: proc(r: ^Renderer) {
	for &cmd in r.in_flight {
		if cmd != nil {
			msg(cmd, "waitUntilCompleted")
			release(cmd)
		}
	}
	for buf in r.buffers {
		release(buf)
	}
	for slot in r.textures {
		release(slot.mip_cmd)
		release(slot.texture)
	}
	release(r.pipeline)
	release(r.queue)
	r^ = {}
}

// build_pipeline returns a new pipeline, or nil after logging why it failed.
@(private)
build_pipeline :: proc(r: ^Renderer) -> id {
	err: id
	library := msg_proc(proc "c" (id, SEL, id, id, ^id) -> id)(r.device, sel_registerName("newLibraryWithSource:options:error:"), ns_string(SHADER_SOURCE), nil, &err)
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
	pixel_format := msg_proc(proc "c" (id, SEL) -> MTL.PixelFormat)(r.layer, sel_registerName("pixelFormat"))
	msg_uint(att, "setPixelFormat:", uint(pixel_format))
	// The fragment shader outputs premultiplied colour.
	msg_bool(att, "setBlendingEnabled:", true)
	msg_uint(att, "setSourceRGBBlendFactor:", uint(MTL.BlendFactor.One))
	msg_uint(att, "setDestinationRGBBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))
	msg_uint(att, "setSourceAlphaBlendFactor:", uint(MTL.BlendFactor.One))
	msg_uint(att, "setDestinationAlphaBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))

	pipeline := msg_proc(proc "c" (id, SEL, id, ^id) -> id)(r.device, sel_registerName("newRenderPipelineStateWithDescriptor:error:"), desc, &err)
	if pipeline == nil {
		log.error("render: pipeline failed:", error_string(err))
		return nil
	}
	return pipeline
}

// Textures

// texture_create makes a texture with undefined contents; fill it with
// texture_update. Mipmapped textures regenerate their mips on every update,
// which suits cover art (written once) and not the glyph atlas.
texture_create :: proc(r: ^Renderer, width, height: int, format: Texture_Format, mipmapped := false) -> Texture {
	for i in 1 ..< MAX_TEXTURES {
		slot := &r.textures[i]
		if slot.texture == nil {
			generation := slot.generation
			slot^ = new_texture_slot(r, width, height, format, mipmapped)
			slot.generation = generation
			return Texture(u32(i) | u32(generation) << 16)
		}
	}
	log.error("render: out of texture slots")
	return 0
}

// texture_update copies pixels into the region (x, y, w, h). Rows are tightly
// packed. R8 pixels are linear coverage. RGBA8 and BGRA8 pixels are sRGB with
// alpha premultiplied in sRGB space, which is what a premultiplied
// CGBitmapContext or stb_image plus a multiply gives you. Unless converted is
// set, translucent texels go through convert_premultiplied first, in a copy
// in context.temp_allocator made only if some texel is translucent. Pass
// converted = true for pixels already run through convert_premultiplied, as
// a decode worker can do.
//
// The upload happens at once on the CPU, so don't overwrite texels a frame
// still in flight samples; writing into unused space, as an atlas does, is
// fine. A mipmapped texture first waits for its last mip generation.
texture_update :: proc(r: ^Renderer, t: Texture, pixels: []byte, x, y, w, h: int, converted := false) {
	slot := texture_slot(r, t)
	if slot == nil {
		return
	}
	bpp := 1 if slot.format == .R8 else 4
	assert(len(pixels) >= w * h * bpp)
	pixels := pixels
	if bpp == 4 && !converted && has_translucent(pixels[:w * h * 4]) {
		pixels = slice_clone(pixels[:w * h * 4])
		convert_premultiplied(pixels)
	}
	if slot.mip_cmd != nil {
		msg(slot.mip_cmd, "waitUntilCompleted")
		release(slot.mip_cmd)
		slot.mip_cmd = nil
	}
	region := Region{{uint(x), uint(y), 0}, {uint(w), uint(h), 1}}
	msg_proc(proc "c" (id, SEL, Region, uint, rawptr, uint))(slot.texture, sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"), region, 0, raw_data(pixels), uint(w * bpp))
	if slot.mipmapped {
		// Queued ahead of the next frame's command buffer, so the frame sees
		// the new mips.
		cmd := msg(r.queue, "commandBuffer")
		blit := msg(cmd, "blitCommandEncoder")
		msg_id(blit, "generateMipmapsForTexture:", slot.texture)
		msg(blit, "endEncoding")
		msg(cmd, "commit")
		slot.mip_cmd = msg(cmd, "retain")
	}
}

@(private)
slice_clone :: proc(pixels: []byte) -> []byte {
	out := make([]byte, len(pixels), context.temp_allocator)
	copy(out, pixels)
	return out
}

@(private)
has_translucent :: proc(pixels: []byte) -> bool {
	for i := 3; i < len(pixels); i += 4 {
		if pixels[i] != 0 && pixels[i] != 255 {
			return true
		}
	}
	return false
}

// convert_premultiplied rewrites premultiplied sRGB texels (RGBA or BGRA) in
// place as sRGB encodings of premultiplied linear colour: each translucent
// texel's colour channels c become encode(decode(c / a) * a), so white at
// 50% becomes 188 rather than 128 and the texture filters and blends like a
// solid colour of the same alpha. Opaque and fully transparent texels stay
// as they are. It touches no renderer state, so it can run on any thread.
convert_premultiplied :: proc(pixels: []byte) {
	for i := 0; i + 3 < len(pixels); i += 4 {
		a := pixels[i + 3]
		if a == 0 || a == 255 {
			continue
		}
		row := &premultiplied_lut[a]
		pixels[i] = row[pixels[i]]
		pixels[i + 1] = row[pixels[i + 1]]
		pixels[i + 2] = row[pixels[i + 2]]
	}
}

// premultiplied_exact is what convert_premultiplied does to channel c of a
// texel with alpha a, 0 < a < 255, computed directly.
premultiplied_exact :: proc(c, a: u8) -> u8 {
	alpha := f32(a) / 255
	straight := min(f32(c) / 255 / alpha, 1)
	return u8(math.round(srgb_from_linear(linear_from_srgb(straight) * alpha) * 255))
}

// premultiplied_lut[a][c] is premultiplied_exact(c, a) for translucent a.
// Built when the image loads; each loaded dylib has its own.
premultiplied_lut: [256][256]u8

@(init, private)
build_premultiplied_lut :: proc "contextless" () {
	context = runtime.default_context()
	for a in 1 ..< 255 {
		for c in 0 ..< 256 {
			premultiplied_lut[a][c] = premultiplied_exact(u8(c), u8(a))
		}
	}
}

// texture_destroy frees the texture. Metal keeps it alive until the command
// buffers that use it finish, so this is safe mid-flight.
texture_destroy :: proc(r: ^Renderer, t: Texture) {
	slot := texture_slot(r, t)
	if slot == nil || t == 0 {
		return
	}
	release(slot.texture)
	release(slot.mip_cmd)
	slot^ = {generation = slot.generation + 1}
}

// texture_copy copies the w by h texels at the top left of src to the top
// left of dst on the GPU, in a command buffer of its own queued ahead of
// the next frame's. Both must have the same format and no mips.
texture_copy :: proc(r: ^Renderer, src, dst: Texture, w, h: int) {
	from, to := texture_slot(r, src), texture_slot(r, dst)
	if from == nil || to == nil {
		return
	}
	cmd := msg(r.queue, "commandBuffer")
	blit := msg(cmd, "blitCommandEncoder")
	msg_proc(proc "c" (id, SEL, id, uint, uint, Origin, Size, id, uint, uint, Origin))(
		blit,
		sel_registerName("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"),
		from.texture, 0, 0, {}, {uint(w), uint(h), 1}, to.texture, 0, 0, {},
	)
	msg(blit, "endEncoding")
	msg(cmd, "commit")
}

texture_size :: proc(r: ^Renderer, t: Texture) -> [2]int {
	slot := texture_slot(r, t)
	if slot == nil {
		return {}
	}
	return {int(slot.width), int(slot.height)}
}

// texture_slot returns nil for a stale or out of range handle.
@(private)
texture_slot :: proc(r: ^Renderer, t: Texture) -> ^Texture_Slot {
	index := int(t & 0xffff)
	if index >= MAX_TEXTURES {
		return nil
	}
	slot := &r.textures[index]
	if slot.texture == nil || u32(slot.generation) != u32(t) >> 16 {
		return nil
	}
	return slot
}

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
	texture := msg_id(r.device, "newTextureWithDescriptor:", desc)
	return {texture = texture, width = i32(width), height = i32(height), format = format, mipmapped = mipmapped}
}

// Frame

begin_frame :: proc(r: ^Renderer, width, height, scale: f32, clear: Color) {
	r.width = width
	r.height = height
	r.scale = scale
	r.clear = clear
	r.slot = int(r.frame_index % FRAMES_IN_FLIGHT)

	// The GPU usually finished this slot two frames ago, so this rarely waits.
	if cmd := r.in_flight[r.slot]; cmd != nil {
		msg(cmd, "waitUntilCompleted")
		release(cmd)
		r.in_flight[r.slot] = nil
	}
	r.instance_count = 0
	if r.buffers[r.slot] == nil {
		r.buffers[r.slot] = new_instance_buffer(r, INITIAL_INSTANCES)
		r.capacity[r.slot] = INITIAL_INSTANCES
	}
	r.instances = ([^]Instance)(msg(r.buffers[r.slot], "contents"))
	r.batch_count = 0
	r.clip_depth = 1
	r.clips[0] = {-1e9, -1e9, 1e9, 1e9}
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
	release(r.buffers[r.slot])
	r.buffers[r.slot] = buf
	r.capacity[r.slot] = capacity
	r.instances = instances
}

@(private)
new_instance_buffer :: proc(r: ^Renderer, capacity: int) -> id {
	return msg_proc(proc "c" (id, SEL, uint, uint) -> id)(r.device, sel_registerName("newBufferWithLength:options:"), uint(capacity * size_of(Instance)), MTL_RESOURCE_STORAGE_MODE_SHARED)
}

// corners returns v for all four corners, for Style.colors and Style.radii.
corners :: proc(v: $T) -> (out: [Corner]T) {
	for &c in out {
		c = v
	}
	return
}

// push draws a rect with any style. The other push procs are shorthands.
push :: proc(r: ^Renderer, rect: Rect, style: Style) {
	inst: Instance
	inst.dst = snap(r, rect)
	if (inst.dst.x >= inst.dst.z || inst.dst.y >= inst.dst.w) && style.softness == 0 {
		return
	}

	texture := style.texture
	kind := 0 // the batch's texture slot: colour, or coverage for R8
	if texture != 0 {
		slot := texture_slot(r, texture)
		if slot == nil {
			texture = 0
		} else {
			inst.flags += {.Textured}
			if style.nearest {
				inst.flags += {.Nearest}
			}
			if slot.format == .R8 {
				inst.flags += {.Coverage}
				kind = 1
			}
			src := style.src
			if src.w == 0 || src.h == 0 {
				src = {0, 0, f32(slot.width), f32(slot.height)}
			}
			tw, th := f32(slot.width), f32(slot.height)
			inst.src = {src.x / tw, src.y / th, (src.x + src.w) / tw, (src.y + src.h) / th}
		}
	}

	for c in Corner {
		inst.colors[c] = style.colors[c]
		inst.radii[c] = style.radii[c] * r.scale
	}
	if style.border > 0 {
		inst.border = max(math.round(style.border * r.scale), 1)
	}
	inst.softness = style.softness * r.scale
	inst.clip = r.clips[min(r.clip_depth, MAX_CLIP_DEPTH) - 1]

	// Open a new batch only when this instance needs a texture other than
	// the one the current batch binds for its kind.
	b := &r.batches[max(r.batch_count - 1, 0)]
	if r.batch_count == 0 || (texture != 0 && b.textures[kind] != 0 && b.textures[kind] != texture) {
		if r.batch_count == MAX_BATCHES {
			return
		}
		b = &r.batches[r.batch_count]
		b^ = {first = u32(r.instance_count)}
		r.batch_count += 1
	}
	if texture != 0 {
		b.textures[kind] = texture
	}

	if r.instance_count == r.capacity[r.slot] {
		grow_instances(r)
	}
	r.instances[r.instance_count] = inst
	r.instance_count += 1
	b.count += 1
}

push_rect :: proc(r: ^Renderer, rect: Rect, color: Color, radius: f32 = 0, border: f32 = 0) {
	push(r, rect, {colors = corners(color), radii = corners(radius), border = border})
}

// push_gradient fades from `from` to `to`, top to bottom, or left to right
// when horizontal is set.
push_gradient :: proc(r: ^Renderer, rect: Rect, from, to: Color, horizontal := false, radius: f32 = 0) {
	colors := [Corner]Color{.Top_Left = from, .Top_Right = to, .Bottom_Left = to, .Bottom_Right = to}
	if horizontal {
		colors[.Bottom_Left] = from
	} else {
		colors[.Top_Right] = from
	}
	push(r, rect, {colors = colors, radii = corners(radius)})
}

// push_image draws a texture, tinted by `tint`, with rounded corners if
// radius is set. src is in texels; zero means the whole texture.
push_image :: proc(r: ^Renderer, rect: Rect, texture: Texture, src: Rect = {}, tint := WHITE, radius: f32 = 0, nearest := false) {
	push(r, rect, {colors = corners(tint), radii = corners(radius), texture = texture, src = src, nearest = nearest})
}

// push_shadow draws a drop shadow for a box of the given rect and radius.
// Draw it before the box. blur works like CSS box-shadow blur: the shadow is
// half strength at the (offset, spread) box edge and fades out over `blur`
// points either side of it.
push_shadow :: proc(r: ^Renderer, rect: Rect, radius: f32, blur: f32, offset := [2]f32{0, 4}, spread: f32 = 0, color := Color{0, 0, 0, 0.5}) {
	box := Rect{rect.x + offset.x - spread, rect.y + offset.y - spread, rect.w + 2 * spread, rect.h + 2 * spread}
	push(r, box, {colors = corners(color), radii = corners(radius + spread), softness = blur / 2})
}

// push_clip limits drawing to rect, intersected with the current clip.
push_clip :: proc(r: ^Renderer, rect: Rect) {
	if r.clip_depth < MAX_CLIP_DEPTH {
		outer := r.clips[r.clip_depth - 1]
		c := snap(r, rect)
		r.clips[r.clip_depth] = {max(c.x, outer.x), max(c.y, outer.y), min(c.z, outer.z), min(c.w, outer.w)}
	}
	r.clip_depth += 1
}

pop_clip :: proc(r: ^Renderer) {
	if r.clip_depth > 1 {
		r.clip_depth -= 1
	}
}

// snap converts a rect in points to pixel edges x0 y0 x1 y1 on whole pixels.
@(private)
snap :: proc(r: ^Renderer, rect: Rect) -> [4]f32 {
	s := r.scale
	return {math.round(rect.x * s), math.round(rect.y * s), math.round((rect.x + rect.w) * s), math.round((rect.y + rect.h) * s)}
}

// end_frame encodes the frame and presents it. The caller must be inside an
// autorelease pool; the shell wraps every frame in one.
end_frame :: proc(r: ^Renderer) {
	// Counts frames that drew nothing too, so frame_index - FRAMES_IN_FLIGHT
	// is always a frame the GPU has finished once begin_frame returns.
	defer r.frame_index += 1
	if r.pipeline == nil || r.width <= 0 || r.height <= 0 {
		return
	}
	drawable := msg(r.layer, "nextDrawable")
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

	cmd := msg(r.queue, "commandBuffer")
	enc := msg_id(cmd, "renderCommandEncoderWithDescriptor:", pass)
	draw_calls := 0
	if r.instance_count > 0 {
		viewport := [2]f32{f32(tex_w), f32(tex_h)}
		buf := r.buffers[r.slot]
		msg_id(enc, "setRenderPipelineState:", r.pipeline)
		msg_proc(proc "c" (id, SEL, id, uint, uint))(enc, sel_registerName("setVertexBuffer:offset:atIndex:"), buf, 0, 0)
		msg_proc(proc "c" (id, SEL, id, uint, uint))(enc, sel_registerName("setFragmentBuffer:offset:atIndex:"), buf, 0, 0)
		msg_proc(proc "c" (id, SEL, rawptr, uint, uint))(enc, sel_registerName("setVertexBytes:length:atIndex:"), &viewport, size_of(viewport), 1)
		for b in r.batches[:r.batch_count] {
			if b.count == 0 {
				continue
			}
			for t, index in b.textures {
				slot := texture_slot(r, t)
				tex := slot.texture if slot != nil else r.textures[0].texture
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
	r.in_flight[r.slot] = msg(cmd, "retain")
	r.stats = {draw_calls, r.instance_count}

	if capture != nil {
		msg(cmd, "waitUntilCompleted")
		write_tga(r.capture_path, ([^]byte)(msg(capture, "contents"))[:tex_w * tex_h * 4], tex_w, tex_h)
		release(capture)
	}
}

linear_from_srgb :: proc(c: f32) -> f32 {
	return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4)
}

srgb_from_linear :: proc(c: f32) -> f32 {
	return c * 12.92 if c <= 0.0031308 else 1.055 * math.pow(c, 1 / 2.4) - 0.055
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
	buf := msg_proc(proc "c" (id, SEL, uint, uint) -> id)(r.device, sel_registerName("newBufferWithLength:options:"), w * h * 4, MTL_RESOURCE_STORAGE_MODE_SHARED)
	blit := msg(cmd, "blitCommandEncoder")
	msg_proc(proc "c" (id, SEL, id, uint, uint, Origin, Size, id, uint, uint, uint))(
		blit,
		sel_registerName("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:"),
		texture, 0, 0, {}, {w, h, 1}, buf, 0, w * 4, w * h * 4,
	)
	msg(blit, "endEncoding")
	return buf
}

// write_tga writes BGRA pixels, top row first. It writes a temp file and
// renames it over path, so whoever copies path mid-run gets a whole frame.
@(private)
write_tga :: proc(path: string, pixels: []byte, w, h: uint) {
	header := [18]byte{2 = 2, 12 = u8(w), 13 = u8(w >> 8), 14 = u8(h), 15 = u8(h >> 8), 16 = 32, 17 = 0x28}
	tmp := fmt.tprintf("%s.tmp", path)
	f, err := os.create(tmp)
	if err != nil {
		log.error("render: capture failed:", err)
		return
	}
	os.write(f, header[:])
	os.write(f, pixels)
	os.close(f)
	os.rename(tmp, path)
}
