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
// coverage. Text relies on this: glyph coverage is blended in
// linear light. Colour textures hold premultiplied linear values, sRGB
// encoded, so the hardware decodes before filtering and gets premultiplied
// linear out; texture_update converts to that from ordinary premultiplied
// sRGB.
//
// The backend is picked by file: metal_darwin.odin on macOS and
// vulkan_linux.odin on Linux. Each defines Gpu and Gpu_Texture, the
// backend's part of Renderer and of a texture slot, BACKDROPS, and the procs
// this file leaves out: init, reload, destroy, end_frame and gpu_allocated,
// and privately new_texture_slot, gpu_texture_free, gpu_texture_write,
// gpu_texture_copy, gpu_frame_begin and grow_instances.
//
// Backdrop: push_backdrop fills a rect with a blur of what was pushed before
// it, as a window's material over content scrolling under it. The frame
// then draws twice. First the instances before the backdrop go to an
// offscreen texture half the size of the rect plus the blur's reach, which
// the backend blurs with a dual Kawase filter: each level halves the size,
// then the levels add back up. Then the whole frame draws to the drawable
// as usual, the backdrop instance sampling the blurred texture. The first
// part is skipped while backdrop_hash stays the same. Only one backdrop a
// frame, and only where BACKDROPS is true.
package render

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:os"

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
	additive: bool, // add the colour to what's under it, see Instance_Flag.Additive
	darken:   f32, // with additive, scale what's under it by 1 - darken first
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
	Backdrop, // sample the blurred backdrop, see push_backdrop
	// Write extra as the alpha, so the premultiplied blend gives
	// dst * (1 - extra) + colour: with extra 0 it adds the colour to what's
	// under it, as plus-lighter does.
	Additive,
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
	extra:    f32, // Backdrop: the saturation. Additive: the alpha
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

// A slot is free while its width is zero.
Texture_Slot :: struct {
	gpu:        Gpu_Texture,
	width:      i32,
	height:     i32,
	generation: u16,
	format:     Texture_Format,
	mipmapped:  bool,
}

Stats :: struct {
	draw_calls: int,
	instances:  int,
}

MAX_BLUR_LEVELS :: 6

// What end_frame needs for the frame's backdrop.
Backdrop_Pass :: struct {
	batch:  int, // the backdrop's batch; the ones before it are what it blurs
	region: [4]f32, // x0 y0 x1 y1, the drawable's pixels the blur reads
	levels: int, // halvings, 2 to MAX_BLUR_LEVELS
	// Of what the blur reads: the instances before the backdrop that reach
	// into region, their textures, and the rest that changes the result.
	// end_frame blurs again only when it changes.
	hash:   u64,
}

// Renderer is plain data so it can live in the app's persistent memory.
Renderer :: struct {
	gpu:            Gpu,
	textures:       [MAX_TEXTURES]Texture_Slot,

	// Each frame writes instances into its slot's buffer while the GPU may
	// still read the other slots'.
	frame_index:    u64,
	slot:           int,
	capacity:       [FRAMES_IN_FLIGHT]int, // in instances

	// The frame being built.
	width, height:  f32, // points
	scale:          f32,
	clear:          Color,
	instances:      [^]Instance, // the slot's instance buffer
	instance_count: int,
	batches:        [MAX_BATCHES]Batch,
	batch_count:    int,
	clips:          [MAX_CLIP_DEPTH][4]f32, // pixels
	clip_depth:     int,
	backdrop:       Backdrop_Pass, // batch is -1 without one

	stats:          Stats, // of the last frame end_frame drew
	// Milliseconds the GPU took on the newest frame it has finished, a frame
	// or two behind; 0 where the backend can't tell.
	gpu_ms:         f32,
	// Milliseconds this frame waited: for the GPU to finish with its slot's
	// instance buffer (begin_frame), and for a drawable (end_frame).
	slot_wait_ms:     f32,
	drawable_wait_ms: f32,
	// Debug: when set, end_frame waits for the GPU and writes each frame to
	// this path as a TGA. Set it before init.
	capture_path:   string,
}

// Gpu_Memory is the GPU memory the renderer allocates for itself, in bytes.
Gpu_Memory :: struct {
	instances: int, // the frames' instance buffers
	staging:   int, // upload and capture buffers (Vulkan)
	backdrop:  int, // the blur's textures (Metal)
}

// Textures

// texture_bytes is the GPU memory behind t, 0 for none.
texture_bytes :: proc(r: ^Renderer, t: Texture) -> int {
	slot := texture_slot(r, t)
	if slot == nil {
		return 0
	}
	return gpu_texture_bytes(slot)
}

// texture_create makes a texture with undefined contents; fill it with
// texture_update. Mipmapped textures regenerate their mips on every update,
// which suits cover art (written once) and not the glyph atlas.
texture_create :: proc(r: ^Renderer, width, height: int, format: Texture_Format, mipmapped := false) -> Texture {
	for i in 1 ..< MAX_TEXTURES {
		slot := &r.textures[i]
		if slot.width == 0 {
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
	gpu_texture_write(r, slot, pixels, x, y, w, h, bpp)
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

// texture_destroy frees the texture. It's safe while a frame that uses it
// is in flight.
texture_destroy :: proc(r: ^Renderer, t: Texture) {
	slot := texture_slot(r, t)
	if slot == nil || t == 0 {
		return
	}
	gpu_texture_free(r, slot.gpu)
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
	gpu_texture_copy(r, from, to, w, h)
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
	if slot.width == 0 || u32(slot.generation) != u32(t) >> 16 {
		return nil
	}
	return slot
}

// Frame

begin_frame :: proc(r: ^Renderer, width, height, scale: f32, clear: Color) {
	r.width = width
	r.height = height
	r.scale = scale
	r.clear = clear
	r.slot = int(r.frame_index % FRAMES_IN_FLIGHT)
	r.instances = gpu_frame_begin(r)
	r.instance_count = 0
	r.batch_count = 0
	r.clip_depth = 1
	r.clips[0] = {-1e9, -1e9, 1e9, 1e9}
	r.backdrop = {batch = -1}
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
	if style.additive {
		inst.flags += {.Additive}
		inst.extra = style.darken
	}
	inst.clip = r.clips[min(r.clip_depth, MAX_CLIP_DEPTH) - 1]
	append_instance(r, inst, texture, kind)
}

// append_instance adds inst to the frame. It opens a new batch only when
// inst needs a texture other than the one the current batch binds for its
// kind, or new_batch is set.
@(private)
append_instance :: proc(r: ^Renderer, inst: Instance, texture: Texture, kind: int, new_batch := false) -> bool {
	b := &r.batches[max(r.batch_count - 1, 0)]
	if r.batch_count == 0 || new_batch || (texture != 0 && b.textures[kind] != 0 && b.textures[kind] != texture) {
		if r.batch_count == MAX_BATCHES {
			return false
		}
		b = &r.batches[r.batch_count]
		b^ = {first = u32(r.instance_count)}
		r.batch_count += 1
	}
	if texture != 0 {
		b.textures[kind] = texture
	}

	if r.instances == nil {
		return false
	}
	if r.instance_count == r.capacity[r.slot] {
		grow_instances(r)
		if r.instance_count == r.capacity[r.slot] {
			return false
		}
	}
	r.instances[r.instance_count] = inst
	r.instance_count += 1
	b.count += 1
	return true
}

// push_backdrop fills rect, with corners of radius, with a blur of what was
// pushed before it there: reaching blur points, its colours saturated by
// saturation (1 keeps them), and tint drawn over it. A frame's second
// backdrop, or one where BACKDROPS is false, draws tint at full alpha.
push_backdrop :: proc(r: ^Renderer, rect: Rect, blur, saturation: f32, tint: Color, radius: f32 = 0) {
	if !BACKDROPS || r.backdrop.batch >= 0 {
		push_rect(r, rect, {tint.r, tint.g, tint.b, 1}, radius)
		return
	}
	inst: Instance
	inst.dst = snap(r, rect)
	if inst.dst.x >= inst.dst.z || inst.dst.y >= inst.dst.w {
		return
	}
	// The blur reads past the rect as far as it reaches, within the
	// drawable, whose edges it repeats.
	reach := math.round(blur * r.scale)
	w, h := math.round(r.width * r.scale), math.round(r.height * r.scale)
	region := [4]f32{max(inst.dst.x - reach, 0), max(inst.dst.y - reach, 0), min(inst.dst.z + reach, w), min(inst.dst.w + reach, h)}
	size := [2]f32{region.z - region.x, region.w - region.y}
	if size.x <= 0 || size.y <= 0 {
		return
	}
	inst.flags = {.Backdrop}
	inst.src = {(inst.dst.x - region.x) / size.x, (inst.dst.y - region.y) / size.y, (inst.dst.z - region.x) / size.x, (inst.dst.w - region.y) / size.y}
	inst.extra = saturation
	for c in Corner {
		inst.colors[c] = tint
		inst.radii[c] = radius * r.scale
	}
	inst.clip = r.clips[min(r.clip_depth, MAX_CLIP_DEPTH) - 1]
	batch := r.batch_count
	if !append_instance(r, inst, 0, 0, new_batch = true) {
		return
	}
	// Each level of the dual filter about doubles the reach, starting from
	// a couple of pixels.
	levels := clamp(int(math.round(math.log2(max(reach, 2) / 2))), 2, MAX_BLUR_LEVELS)
	r.backdrop = {batch, region, levels, backdrop_hash(r, batch, region, levels)}
}

// backdrop_hash hashes what a backdrop over region blurs: the instances in
// the batches before batch that draw into region, those batches' textures,
// and the levels, scale and clear colour.
@(private)
backdrop_hash :: proc(r: ^Renderer, batch: int, region: [4]f32, levels: int) -> u64 {
	bytes :: proc(v: ^$T) -> []byte {
		return ([^]byte)(v)[:size_of(T)]
	}
	region, levels, scale, clear := region, levels, r.scale, r.clear
	h := hash.fnv64a(bytes(&region))
	h = hash.fnv64a(bytes(&levels), h)
	h = hash.fnv64a(bytes(&scale), h)
	h = hash.fnv64a(bytes(&clear), h)
	for &b in r.batches[:batch] {
		h = hash.fnv64a(bytes(&b.textures), h)
		for &inst in r.instances[b.first:b.first + b.count] {
			pad := inst.softness + 1
			x0, y0 := max(inst.dst.x - pad, inst.clip.x), max(inst.dst.y - pad, inst.clip.y)
			x1, y1 := min(inst.dst.z + pad, inst.clip.z), min(inst.dst.w + pad, inst.clip.w)
			if x0 < region.z && x1 > region.x && y0 < region.w && y1 > region.y {
				h = hash.fnv64a(bytes(&inst), h)
			}
		}
	}
	return h
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

// Rim is how a rim changes the linear colour c under it: c * (1 - darken)
// + lift. Colours move toward lift / darken, so with the two equal it is
// white at that alpha.
Rim :: struct {
	lift:   f32,
	darken: f32,
	width:  f32, // in points, 0 for one physical pixel
}

// push_rim draws a hairline just inside rect's edge that changes what's under
// it by rim.
push_rim :: proc(r: ^Renderer, rect: Rect, rim: Rim, radius: f32 = 0) {
	push(r, rect, {colors = corners(Color{1, 1, 1, rim.lift}), radii = corners(radius), border = rim.width if rim.width > 0 else 1 / r.scale, additive = true, darken = rim.darken})
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

linear_from_srgb :: proc(c: f32) -> f32 {
	return c / 12.92 if c <= 0.04045 else math.pow((c + 0.055) / 1.055, 2.4)
}

srgb_from_linear :: proc(c: f32) -> f32 {
	return c * 12.92 if c <= 0.0031308 else 1.055 * math.pow(c, 1 / 2.4) - 0.055
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
