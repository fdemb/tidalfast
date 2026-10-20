package tidal_tests

import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

import "../src/render"
import "../src/text"

foreign import metal "system:Metal.framework"

@(default_calling_convention = "c")
foreign metal {
	MTLCreateSystemDefaultDevice :: proc() -> rawptr ---
}

@(private = "file")
Origin :: struct {
	x, y, z: uint,
}

@(private = "file")
Size :: struct {
	w, h, d: uint,
}

@(private = "file")
Region :: struct {
	origin: Origin,
	size:   Size,
}

// read_texels reads an R8 texture's w by h texels at (x, y) on the CPU.
@(private = "file")
read_texels :: proc(r: ^render.Renderer, t: render.Texture, x, y, w, h: int) -> []u8 {
	out := make([]u8, w * h, context.temp_allocator)
	tex := r.textures[t & 0xffff].gpu.texture
	region := Region{{uint(x), uint(y), 0}, {uint(w), uint(h), 1}}
	render.msg_proc(proc "c" (render.id, render.SEL, rawptr, uint, Region, uint))(tex, render.sel_registerName("getBytes:bytesPerRow:fromRegion:mipmapLevel:"), raw_data(out), uint(w), region, 0)
	return out
}

// A glyph page starts small and doubles as it fills. The GPU copies the old
// page into the new one, so a glyph drawn before the page grew is still
// there, at the same place, afterwards.
@(test)
atlas_pages_grow_and_keep_their_glyphs :: proc(t: ^testing.T) {
	device := MTLCreateSystemDefaultDevice()
	if device == nil {
		return // no GPU to test with
	}
	backing := make([]byte, 64 << 20)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	context.allocator = mem.arena_allocator(&arena)
	r := new(render.Renderer)
	r.gpu.device = device
	r.gpu.queue = render.msg(device, "newCommandQueue")
	s := new(text.State)
	testing.expect(t, text.init(s))
	defer {
		text.destroy(s, r)
		render.destroy(r)
	}

	frame :: proc(s: ^text.State, r: ^render.Renderer) {
		free_all(context.temp_allocator)
		render.begin_frame(r, 1000, 1000, 2, {})
		text.begin_frame(s, r)
	}
	frame(s, r)
	text.draw(s, r, .Regular, 20, {0, 0}, render.WHITE, "A")
	a := &s.atlas
	testing.expect_value(t, a.page_count, 1)
	testing.expect_value(t, a.pages[0].size, text.PAGE_SIZE >> text.PAGE_START_SHIFT)
	glyph: text.Atlas_Entry
	for e in a.entries {
		if e.key != 0 && e.w > 0 {
			glyph = e
		}
	}
	before := strings.clone(string(read_texels(r, a.pages[0].texture, int(glyph.x), int(glyph.y), int(glyph.w), int(glyph.h))))
	testing.expect(t, strings.count(before, "\x00") < len(before), "the glyph has coverage")

	// Big glyphs until the first page has grown.
	for size: f32 = 30; size < 400 && a.pages[0].size == text.PAGE_SIZE >> text.PAGE_START_SHIFT; size += 10 {
		for i := 0; i < 100; i += 1 {
			frame(s, r)
			text.draw(s, r, .Bold, size, {0, 0}, render.WHITE, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
			if !s.needs_redraw {
				break
			}
		}
	}
	testing.expect_value(t, a.page_count, 1)
	testing.expect_value(t, a.pages[0].size, text.PAGE_SIZE >> (text.PAGE_START_SHIFT - 1))

	// The copy runs on the GPU ahead of anything committed after it.
	cmd := render.msg(r.gpu.queue, "commandBuffer")
	render.msg(cmd, "commit")
	render.msg(cmd, "waitUntilCompleted")
	after := read_texels(r, a.pages[0].texture, int(glyph.x), int(glyph.y), int(glyph.w), int(glyph.h))
	testing.expect_value(t, string(after), before)
}

// When the atlas fills up, only pages nothing was drawn from last frame go.
// Text drawn every frame keeps its bitmaps and isn't rasterized again.
@(test)
atlas_keeps_hot_pages_when_full :: proc(t: ^testing.T) {
	device := MTLCreateSystemDefaultDevice()
	if device == nil {
		return // no GPU to test with
	}
	backing := make([]byte, 64 << 20)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	context.allocator = mem.arena_allocator(&arena)
	r := new(render.Renderer)
	r.gpu.device = device
	r.gpu.queue = render.msg(device, "newCommandQueue")
	s := new(text.State)
	testing.expect(t, text.init(s))
	defer {
		text.destroy(s, r)
		render.destroy(r)
	}

	frame :: proc(s: ^text.State, r: ^render.Renderer) {
		free_all(context.temp_allocator)
		render.begin_frame(r, 1000, 1000, 2, {})
		text.begin_frame(s, r)
	}
	a := &s.atlas
	size: f32 = 60
	for i := 0; i < 5000 && a.full == .No; i += 1 {
		frame(s, r)
		text.draw(s, r, .Regular, 13, {0, 0}, render.WHITE, "Hot")
		text.draw(s, r, .Bold, size, {0, 0}, render.WHITE, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
		if !s.needs_redraw {
			size += 10
		}
	}
	testing.expect(t, a.full != .No, "the atlas filled up")
	pages := s.stats.pages

	frame(s, r)
	testing.expect(t, a.full == .No)
	testing.expect(t, s.stats.pages < pages, "cold pages are gone")
	text.draw(s, r, .Regular, 13, {0, 0}, render.WHITE, "Hot")
	testing.expect_value(t, s.stats.rasterized, 0)
	text.draw(s, r, .Bold, 55, {0, 0}, render.WHITE, "ABC")
	testing.expect(t, s.stats.rasterized > 0 && a.full == .No, "freed room takes new glyphs")
}

// When the glyph table fills but the page that holds most glyphs is drawn
// from every frame, freeing the cold pages would leave the table nearly full
// and new glyphs missing again. The frame after the atlas fills draws new
// glyphs.
@(test)
atlas_full_table_on_a_hot_page_takes_new_glyphs :: proc(t: ^testing.T) {
	device := MTLCreateSystemDefaultDevice()
	if device == nil {
		return // no GPU to test with
	}
	backing := make([]byte, 64 << 20)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	context.allocator = mem.arena_allocator(&arena)
	r := new(render.Renderer)
	r.gpu.device = device
	r.gpu.queue = render.msg(device, "newCommandQueue")
	s := new(text.State)
	testing.expect(t, text.init(s))
	defer {
		text.destroy(s, r)
		render.destroy(r)
	}

	frame :: proc(s: ^text.State, r: ^render.Renderer) {
		free_all(context.temp_allocator)
		render.begin_frame(r, 1000, 1000, 2, {})
		text.begin_frame(s, r)
	}
	a := &s.atlas
	// The cold page: a colour page drawn from until it exists, then never.
	for i := 0; i < 5000 && s.stats.pages < 1; i += 1 {
		time.sleep(time.Millisecond)
		frame(s, r)
		text.draw(s, r, .Regular, 13, {0, 0}, render.WHITE, "😀")
	}
	testing.expect_value(t, s.stats.pages, 1)

	// The hot page: small glyphs in every subpixel position and a few sizes,
	// all drawn every frame, until the table is full.
	b := strings.builder_make(context.temp_allocator)
	for ranges in ([][2]rune{{0x21, 0x7e}, {0xa1, 0x17f}, {0x391, 0x3a9}, {0x3b1, 0x3c9}, {0x410, 0x44f}}) {
		for c in ranges[0] ..= ranges[1] {
			strings.write_rune(&b, c)
		}
	}
	filler := strings.clone(strings.to_string(b))
	for i := 0; i < 5000 && a.full == .No; i += 1 {
		frame(s, r)
		for font in ([]text.Font{.Regular, .Bold}) {
			for size: f32 = 5; size <= 6; size += 0.25 {
				for x: f32 = 0; x < 0.5; x += 0.125 {
					text.draw(s, r, font, size, {x, 0}, render.WHITE, filler)
				}
			}
		}
	}
	testing.expect(t, a.full != .No, "the glyph table filled up")
	testing.expect_value(t, s.stats.pages, 2)

	// More new glyphs than the cold page held.
	rasterized := 0
	for i := 0; i < 100 && (i == 0 || s.needs_redraw); i += 1 {
		frame(s, r)
		text.draw(s, r, .Bold, 20, {0, 0}, render.WHITE, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn")
		testing.expect(t, a.full == .No, "the table has room again")
		rasterized += s.stats.rasterized
	}
	testing.expect_value(t, rasterized, 40)
}

// When the glyph table fills with glyphs on a page that is still drawn
// from, the glyphs not drawn in the frame that filled it go and the page
// stays. Text drawn every frame keeps its bitmaps and isn't rasterized again.
@(test)
atlas_full_table_drops_glyphs_not_drawn :: proc(t: ^testing.T) {
	device := MTLCreateSystemDefaultDevice()
	if device == nil {
		return // no GPU to test with
	}
	backing := make([]byte, 64 << 20)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	context.allocator = mem.arena_allocator(&arena)
	r := new(render.Renderer)
	r.gpu.device = device
	r.gpu.queue = render.msg(device, "newCommandQueue")
	s := new(text.State)
	testing.expect(t, text.init(s))
	defer {
		text.destroy(s, r)
		render.destroy(r)
	}

	// At scale 1 the small glyphs that fill the table fit in one page.
	frame :: proc(s: ^text.State, r: ^render.Renderer) {
		free_all(context.temp_allocator)
		render.begin_frame(r, 1000, 1000, 1, {})
		text.begin_frame(s, r)
	}
	b := strings.builder_make(context.temp_allocator)
	for ranges in ([][2]rune{{0x21, 0x7e}, {0xa1, 0x17f}, {0x391, 0x3a9}, {0x3b1, 0x3c9}, {0x410, 0x44f}}) {
		for c in ranges[0] ..= ranges[1] {
			strings.write_rune(&b, c)
		}
	}
	filler := strings.clone(strings.to_string(b))
	fonts := []text.Font{.Regular, .Medium, .Semibold, .Bold}

	// Each filler variant is drawn only until it is all in the atlas.
	a := &s.atlas
	variant := 0
	for i := 0; i < 5000 && a.entry_count < len(a.entries) * 3 / 4; i += 1 {
		frame(s, r)
		text.draw(s, r, .Regular, 13, {0, 0}, render.WHITE, "Hot")
		size := 5 + 0.25 * f32(variant / len(fonts))
		for x: f32 = 0; x < 1; x += 0.25 {
			text.draw(s, r, fonts[variant % len(fonts)], size, {x, 0}, render.WHITE, filler)
		}
		if !s.needs_redraw {
			variant += 1
		}
	}
	testing.expect(t, a.entry_count >= len(a.entries) * 3 / 4, "the glyph table filled up")
	text.draw(s, r, .Regular, 20, {0, 0}, render.WHITE, "ABC")

	frame(s, r)
	testing.expect_value(t, s.stats.pages, 1)
	testing.expect(t, a.entry_count < len(a.entries) / 4, "the glyphs not drawn are gone")
	text.draw(s, r, .Regular, 13, {0, 0}, render.WHITE, "Hot")
	testing.expect_value(t, s.stats.rasterized, 0)
	text.draw(s, r, .Regular, 20, {0, 0}, render.WHITE, "ABC")
	testing.expect_value(t, s.stats.rasterized, 3)
}
