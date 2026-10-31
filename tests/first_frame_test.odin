package tidal_tests

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/render"
import "../src/ui"

// A page's first frame is laid out as the frame after it, with nothing in
// between. Code that places a box from a rect while building reads the
// last layout's, which a new box doesn't have, so its first frame differs
// from its second. This walks the pages at a narrow, a medium and a wide
// window and compares every box's rect in the frame each page first shows
// with the next one. The mouse stays out of the window, since hover goes
// by the last layout on purpose.
@(test)
first_frames_match_the_next :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)

	for size in ([][2]f32{{820, 600}, {1100, 760}, {1600, 900}}) {
		s := library_state(true)
		defer library_state_free(s)
		// Past the first second, which a new view's floating scrollbar
		// takes as having just scrolled.
		f := Frame{fonts = &fonts, size = size, now = 100}
		at := fmt.aprintf("%vx%v", size.x, size.y)

		library_frame(t, s, &f)
		expect_next_frame_same(t, s, &f, at, "the first frame")
		settle_frames(t, s, &f)

		library_frame(t, s, &f, press(s, s.rows[0].artist))
		library_frame(t, s, &f)
		expect_next_frame_same(t, s, &f, at, "an artist's page")
		settle_frames(t, s, &f)

		mid := [2]f32{size.x - 200, size.y / 2}
		library_frame(t, s, &f, {kind = .Mouse_Move, x = mid.x, y = mid.y})
		library_frame(t, s, &f, {kind = .Scroll, x = mid.x, y = mid.y, dy = -600, precise = true, phase = .Began})
		library_frame(t, s, &f, {kind = .Mouse_Leave})
		settle_frames(t, s, &f)
		library_frame(t, s, &f, press(s, "View all Albums"))
		library_frame(t, s, &f)
		expect_next_frame_same(t, s, &f, at, "an artist's albums")
		settle_frames(t, s, &f)

		library_frame(t, s, &f, press(s, "Home"))
		library_frame(t, s, &f)
		expect_next_frame_same(t, s, &f, at, "Home")
		settle_frames(t, s, &f)

		library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
		library_frame(t, s, &f)
		expect_next_frame_same(t, s, &f, at, "the empty search page")
		settle_frames(t, s, &f)

		library_frame(t, s, &f, type_text(&f, s.rows[0].album))
		library_frame(t, s, &f, dt = 1)
		expect_next_frame_same(t, s, &f, at, "the songs found")
		settle_frames(t, s, &f)

		library_frame(t, s, &f, press(s, "Albums"))
		library_frame(t, s, &f)
		expect_next_frame_same(t, s, &f, at, "the albums found")
		settle_frames(t, s, &f)

		library_frame(t, s, &f, key(.Left, {ui.PRIMARY}))
		library_frame(t, s, &f)
		expect_next_frame_same(t, s, &f, at, "back to Home")
	}
}

@(private = "file")
settle_frames :: proc(t: ^testing.T, s: ^app.State, f: ^Frame) {
	for _ in 0 ..< 3 {
		library_frame(t, s, f)
	}
}

@(private = "file")
Placed :: struct {
	name: string, // the box's id, or its nearest named ancestor's
	rect: render.Rect,
}

// expect_next_frame_same builds one more frame without input and checks
// that every box is where the last frame put it.
@(private = "file")
expect_next_frame_same :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, at, page: string, loc := #caller_location) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	a := vmem.arena_allocator(&arena)
	first := placed_boxes(&s.ui, a)
	library_frame(t, s, f, loc = loc)
	next := placed_boxes(&s.ui, a)
	if len(first) != len(next) {
		testing.expectf(t, false, "%s, %s: %d boxes in the first frame, %d in the next", at, page, len(first), len(next), loc = loc)
		counts := make(map[string]int, a)
		for p in first {
			counts[p.name] += 1
		}
		for q in next {
			counts[q.name] -= 1
		}
		for name, n in counts {
			if n != 0 {
				testing.expectf(t, false, "%s, %s: %q %+d", at, page, name, n, loc = loc)
			}
		}
		return
	}
	moved := 0
	for p, i in first {
		q := next[i]
		if p.name != q.name || !rect_close(p.rect, q.rect) {
			moved += 1
			if moved <= 5 {
				testing.expectf(t, false, "%s, %s: %q at %v in the first frame, %q at %v in the next", at, page, p.name, p.rect, q.name, q.rect, loc = loc)
			}
		}
	}
	testing.expectf(t, moved <= 5, "%s, %s: %d boxes moved in all", at, page, moved, loc = loc)
}

// placed_boxes lists the boxes the last frame drew, depth first, each
// named after its id or its nearest ancestor's with one. Like draw_box it
// leaves out a box with no opacity and everything in it, such as a
// floating scrollbar that hasn't faded in.
@(private = "file")
placed_boxes :: proc(u: ^ui.State, a: mem.Allocator) -> []Placed {
	out := make([dynamic]Placed, a)
	walk :: proc(b: ^ui.Box, name: string, out: ^[dynamic]Placed, a: mem.Allocator) {
		if b.opacity <= 0 {
			return
		}
		name := strings.clone(b.id, a) if b.id != "" else name
		append(out, Placed{name, b.rect})
		for c := b.first; c != nil; c = c.next {
			walk(c, name, out, a)
		}
	}
	walk(u.root, "root", &out, a)
	walk(u.floating_root, "floating", &out, a)
	return out[:]
}

@(private = "file")
rect_close :: proc(a, b: render.Rect) -> bool {
	return abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.w - b.w) < 0.5 && abs(a.h - b.h) < 0.5
}
