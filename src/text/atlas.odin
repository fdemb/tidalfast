package text

import "core:math"
import "core:mem"
import "core:time"
import stbrp "vendor:stb/rect_pack"

import "../render"

// Glyph bitmaps, rasterized by the OS (glyph_box and rasterize in
// fonts_darwin.odin and fonts_linux.odin) at physical pixel sizes. Coverage
// goes into R8 pages, colour glyphs (emoji) into BGRA pages. A page starts
// at a quarter of its full side and doubles when it fills, keeping what it
// holds; a full-size page that fills gets a sibling; when every page is
// full the whole atlas starts over at the next frame.

PAGE_SIZE :: 2048
COLOR_PAGE_SIZE :: 1024
PAGE_START_SHIFT :: 2 // a page starts at its full side >> this
MAX_PAGES :: 8
ATLAS_CAPACITY :: 16384 // glyph slots, kept under three quarters full
SUBPIXEL_STEPS :: 4
// Rasterizing stops for the frame after this long; the rest of the new
// glyphs show up over the next frames instead of one frame stalling. A page
// of new CJK text can be a few hundred glyphs.
RASTER_BUDGET :: 2 * time.Millisecond

Atlas_Entry :: struct {
	key:        u64, // 0 is empty
	x, y, w, h: u16, // texels in the page; w = 0 draws nothing
	left, top:  i16, // pixels from the pen position and up from the baseline
	page:       u8,
}

Page :: struct {
	texture: render.Texture,
	size:    int, // texels across, up to PAGE_SIZE or COLOR_PAGE_SIZE
	color:   bool,
	packer:  stbrp.Context,
	nodes:   []stbrp.Node,
}

Atlas :: struct {
	entries:        []Atlas_Entry,
	entry_count:    int,
	pages:          [MAX_PAGES]Page,
	page_count:     int,
	full:           bool, // reset at the next begin_frame
	// Textures of pages that grew this frame. Instances drawn earlier in the
	// frame still sample them, so they're destroyed at the next begin_frame.
	outgrown:       [MAX_PAGES]render.Texture,
	outgrown_count: int,
	raster_time:    time.Duration, // spent rasterizing this frame
	raster:         Raster, // the rasterizer's own state
}

@(private)
atlas_init :: proc(a: ^Atlas) {
	a.entries = make([]Atlas_Entry, ATLAS_CAPACITY)
	for &page in a.pages {
		page.nodes = make([]stbrp.Node, PAGE_SIZE)
	}
	raster_init(&a.raster)
}

@(private)
atlas_destroy :: proc(a: ^Atlas, r: ^render.Renderer) {
	atlas_clear(a, r)
	raster_destroy(&a.raster)
}

@(private)
atlas_begin_frame :: proc(a: ^Atlas, r: ^render.Renderer) {
	a.raster_time = 0
	for t in a.outgrown[:a.outgrown_count] {
		render.texture_destroy(r, t)
	}
	a.outgrown_count = 0
	if a.full {
		atlas_clear(a, r)
	}
}

// atlas_clear drops every glyph. The old pages may still be in flight, so
// they're destroyed (Metal keeps them until the GPU is done) rather than
// overwritten.
@(private)
atlas_clear :: proc(a: ^Atlas, r: ^render.Renderer) {
	for page in a.pages[:a.page_count] {
		render.texture_destroy(r, page.texture)
	}
	for t in a.outgrown[:a.outgrown_count] {
		render.texture_destroy(r, t)
	}
	a.outgrown_count = 0
	a.page_count = 0
	mem.zero_slice(a.entries)
	a.entry_count = 0
	a.full = false
}

// subpixel splits a pixel x into a whole pixel and one of SUBPIXEL_STEPS
// offsets, rounding to the nearest step.
subpixel :: proc(x: f32) -> (whole: f32, bucket: u8) {
	q := math.round(x * SUBPIXEL_STEPS)
	whole = math.floor(q / SUBPIXEL_STEPS)
	return whole, u8(q - whole * SUBPIXEL_STEPS)
}

// glyph_key packs what identifies a glyph bitmap: the pixel size, and the
// point size, which sets a variable font's optical size. Both are quantized
// to a quarter. Never 0.
glyph_key :: proc(face: u8, id: u16, px_size, size: f32, bucket: u8) -> u64 {
	sizes := u64(u16(math.round(px_size * 4))) << 16 | u64(u16(math.round(size * 4)))
	return 1 << 63 | u64(face) << 56 | u64(id) << 40 | sizes << 8 | u64(bucket)
}

// draw_run draws a run with its top left at pos (points), truncated with an
// ellipsis to max_width if that's above 0. The baseline lands on a whole
// pixel; each glyph's bitmap is picked by its fractional x. Draw a pending
// run again after begin_frame takes its fonts: shape the string again, or
// keep the ^Run only for the frame.
draw_run :: proc(t: ^State, r: ^render.Renderer, run: ^Run, pos: [2]f32, color: render.Color, max_width: f32 = 0) -> Metrics {
	glyphs := run.glyphs
	width := run.width
	shift, ellipsis_x: f32
	ellipsis: ^Run
	if max_width > 0 && run.width > max_width + FIT_SLACK {
		ellipsis = shape(t, run.font, run.size, ELLIPSIS)
		first, last: int
		first, last, shift, ellipsis_x, width = truncate(glyphs, run.width, max_width, ellipsis.width, run.rtl)
		glyphs = glyphs[first:last]
	}

	scale := r.scale
	baseline := math.round((pos.y + run.ascent) * scale)
	x0 := pos.x * scale
	for g in glyphs {
		// A pending run's missing glyphs wait for their font, blank.
		if run.pending && g.id == 0 {
			continue
		}
		draw_glyph(t, r, g, run.size, x0 + (g.pen + g.offset.x + shift) * scale, baseline + math.round(g.offset.y * scale), color)
	}
	if ellipsis != nil {
		for g in ellipsis.glyphs {
			draw_glyph(t, r, g, run.size, x0 + (ellipsis_x + g.pen + g.offset.x) * scale, baseline + math.round(g.offset.y * scale), color)
		}
	}
	return {width = width, height = run.ascent + run.descent, ascent = run.ascent, truncated = ellipsis != nil}
}

// draw shapes s (or finds it in the cache) and draws it like draw_run.
draw :: proc(t: ^State, r: ^render.Renderer, font: Font, size: f32, pos: [2]f32, color: render.Color, s: string, max_width: f32 = 0) -> Metrics {
	return draw_run(t, r, shape(t, font, size, s), pos, color, max_width)
}

// draw_glyph draws one glyph with its pen at pixel x on pixel row baseline.
@(private)
draw_glyph :: proc(t: ^State, r: ^render.Renderer, g: Glyph, size: f32, x, baseline: f32, color: render.Color) {
	face := &t.faces[g.face]
	whole, bucket := subpixel(x)
	if face.color {
		whole, bucket = math.round(x), 0
	}
	e := glyph_entry(t, r, g.face, g.id, size * r.scale, size, bucket)
	if e == nil || e.w == 0 {
		return
	}
	s := r.scale
	rect := render.Rect{(whole + f32(e.left)) / s, (baseline - f32(e.top)) / s, f32(e.w) / s, f32(e.h) / s}
	src := render.Rect{f32(e.x), f32(e.y), f32(e.w), f32(e.h)}
	tint := render.Color{1, 1, 1, color.a} if face.color else color
	render.push_image(r, rect, t.atlas.pages[e.page].texture, src, tint)
}

// glyph_entry finds a glyph bitmap at px_size for text size points,
// rasterizing it on a miss. nil if the atlas is full; the glyph then shows
// up from the next frame.
@(private)
glyph_entry :: proc(t: ^State, r: ^render.Renderer, face_index: u8, id: u16, px_size, size: f32, bucket: u8) -> ^Atlas_Entry {
	a := &t.atlas
	key := glyph_key(face_index, id, px_size, size, bucket)
	mask := len(a.entries) - 1
	slot := int(mix64(key)) & mask
	for a.entries[slot].key != 0 {
		if a.entries[slot].key == key {
			return &a.entries[slot]
		}
		slot = (slot + 1) & mask
	}
	if a.full || a.entry_count >= len(a.entries) * 3 / 4 {
		a.full = true
		t.needs_redraw = true
		return nil
	}
	if a.raster_time >= RASTER_BUDGET {
		t.needs_redraw = true
		return nil
	}
	start := time.tick_now()
	defer a.raster_time += time.tick_since(start)

	face := &t.faces[face_index]
	box := glyph_box(a, face, px_size, size, id)
	e := Atlas_Entry{key = key}
	if box[2] > box[0] && box[3] > box[1] {
		// One pixel of padding on each side, and room for the subpixel shift.
		left := math.floor(box[0]) - 1
		bottom := math.floor(box[1]) - 1
		right := math.ceil(box[2] + f64(SUBPIXEL_STEPS - 1) / SUBPIXEL_STEPS) + 1
		top := math.ceil(box[3]) + 1
		w, h := int(right - left), int(top - bottom)
		page, x, y, ok := atlas_pack(a, r, face.color, w, h)
		if !ok {
			a.full = true
			t.needs_redraw = true
			return nil
		}
		pixels := rasterize(a, face, px_size, size, id, w, h, {-left + f64(bucket) / SUBPIXEL_STEPS, -bottom})
		// rasterize hands back its own copy, so a colour glyph converts in place.
		if face.color {
			render.convert_premultiplied(pixels)
		}
		render.texture_update(r, a.pages[page].texture, pixels, x, y, w, h, converted = true)
		e.x, e.y, e.w, e.h = u16(x), u16(y), u16(w), u16(h)
		e.left, e.top = i16(left), i16(top)
		e.page = u8(page)
		t.stats.rasterized += 1
	}
	a.entries[slot] = e
	a.entry_count += 1
	return &a.entries[slot]
}

// atlas_pack finds room for a w by h bitmap plus a one texel gap, growing
// the newest page of its kind or adding a page if the others are full.
@(private)
atlas_pack :: proc(a: ^Atlas, r: ^render.Renderer, color: bool, w, h: int) -> (page, x, y: int, ok: bool) {
	rect := stbrp.Rect{w = stbrp.Coord(w + 1), h = stbrp.Coord(h + 1)}
	for i := a.page_count - 1; i >= 0; i -= 1 {
		p := &a.pages[i]
		if p.color != color {
			continue
		}
		for {
			if stbrp.pack_rects(&p.packer, &rect, 1) == 1 {
				return i, int(rect.x), int(rect.y), true
			}
			if !atlas_grow(a, r, p) {
				break
			}
		}
	}
	if a.page_count == MAX_PAGES {
		return
	}
	p := &a.pages[a.page_count]
	p.size = (COLOR_PAGE_SIZE if color else PAGE_SIZE) >> PAGE_START_SHIFT
	p.texture = render.texture_create(r, p.size, p.size, .BGRA8 if color else .R8)
	p.color = color
	stbrp.init_target(&p.packer, i32(p.size), i32(p.size), raw_data(p.nodes), i32(len(p.nodes)))
	a.page_count += 1
	for stbrp.pack_rects(&p.packer, &rect, 1) != 1 {
		if !atlas_grow(a, r, p) {
			return
		}
	}
	return a.page_count - 1, int(rect.x), int(rect.y), true
}

// atlas_grow doubles a page that isn't at its full size yet. The GPU copies
// the old texture into the top left of the new one ahead of the next frame,
// and the packer starts over with that corner taken, so every glyph keeps
// its place.
@(private)
atlas_grow :: proc(a: ^Atlas, r: ^render.Renderer, p: ^Page) -> bool {
	if p.size >= (COLOR_PAGE_SIZE if p.color else PAGE_SIZE) || a.outgrown_count == MAX_PAGES {
		return false
	}
	size := p.size * 2
	t := render.texture_create(r, size, size, .BGRA8 if p.color else .R8)
	if t == 0 {
		return false
	}
	render.texture_copy(r, p.texture, t, p.size, p.size)
	a.outgrown[a.outgrown_count] = p.texture
	a.outgrown_count += 1
	p.texture = t
	stbrp.init_target(&p.packer, i32(size), i32(size), raw_data(p.nodes), i32(len(p.nodes)))
	taken := stbrp.Rect{w = stbrp.Coord(p.size), h = stbrp.Coord(p.size)}
	stbrp.pack_rects(&p.packer, &taken, 1)
	assert(bool(taken.was_packed) && taken.x == 0 && taken.y == 0)
	p.size = size
	return true
}
