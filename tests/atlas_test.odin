package tidal_tests

import "core:mem"
import "core:strings"
import "core:testing"

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
	tex := r.textures[t & 0xffff].texture
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
	r.device = device
	r.queue = render.msg(device, "newCommandQueue")
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
	cmd := render.msg(r.queue, "commandBuffer")
	render.msg(cmd, "commit")
	render.msg(cmd, "waitUntilCompleted")
	after := read_texels(r, a.pages[0].texture, int(glyph.x), int(glyph.y), int(glyph.w), int(glyph.h))
	testing.expect_value(t, string(after), before)
}
