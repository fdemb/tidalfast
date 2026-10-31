package tidal_tests

import "base:runtime"
import "core:mem"
import "core:testing"

import app "../src/app"
import "../src/ui"

// Every scroll view's size comes from arithmetic on the window's (see
// draw_library), which must match what the layout gives the boxes around
// it. On every page, and with the parts that take room at the top or the
// bottom shown or not, each view that scrolls down ends at the bottom of
// the window's body: the playlists LIST_PAD_Y above it, the rest on it.
@(test)
views_reach_the_bottom_of_the_body :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)

	Setup :: struct {
		status_bar, over, notice: bool,
		titlebar:                 f32,
		size:                     [2]f32,
	}
	setups := []Setup {
		{size = {1000, 700}},
		{status_bar = true, titlebar = 28, size = {820, 600}},
		{over = true, notice = true, size = {1600, 900}},
		{status_bar = true, over = true, notice = true, titlebar = 28, size = {1100, 760}},
	}
	for setup in setups {
		s := library_state(true)
		defer library_state_free(s)
		s.status_bar = setup.status_bar
		s.bar_over_content = setup.over
		s.data.device_login = setup.notice
		s.titlebar_h = setup.titlebar
		f := Frame{fonts = &fonts, size = setup.size}
		settle_views :: proc(t: ^testing.T, s: ^app.State, f: ^Frame) {
			for _ in 0 ..< 3 {
				library_frame(t, s, f)
			}
		}

		settle_views(t, s, &f)
		expect_views_fit(t, s, f.size, "a playlist", 2)

		library_frame(t, s, &f, press(s, s.rows[0].artist))
		settle_views(t, s, &f)
		expect_views_fit(t, s, f.size, "an artist's page", 2)
		// Down to the shelves, whose View all opens a grid.
		mid := [2]f32{f.size.x - 200, f.size.y / 2}
		library_frame(t, s, &f, {kind = .Mouse_Move, x = mid.x, y = mid.y})
		library_frame(t, s, &f, {kind = .Scroll, x = mid.x, y = mid.y, dy = -600, precise = true, phase = .Began})
		settle_views(t, s, &f)
		library_frame(t, s, &f, press(s, "View all Albums"))
		settle_views(t, s, &f)
		expect_views_fit(t, s, f.size, "an artist's albums", 2)

		library_frame(t, s, &f, press(s, "Home"))
		settle_views(t, s, &f)
		expect_views_fit(t, s, f.size, "Home", 2)

		open_search(t, s, &f)
		settle_views(t, s, &f)
		expect_views_fit(t, s, f.size, "the empty search page", 1)
		library_frame(t, s, &f, type_text(&f, "abc"))
		library_frame(t, s, &f, dt = 1)
		settle_views(t, s, &f)
		expect_views_fit(t, s, f.size, "the songs found", 2)
		library_frame(t, s, &f, press(s, "Albums"))
		settle_views(t, s, &f)
		expect_views_fit(t, s, f.size, "the albums found", 2)
	}
}

// expect_views_fit checks the last frame's views that scroll down, of
// which there are want.
@(private = "file")
expect_views_fit :: proc(t: ^testing.T, s: ^app.State, size: [2]f32, page: string, want: int, loc := #caller_location) {
	bar_in_flow := !s.blur_reference && !s.bar_over_content
	bottom := size.y - app.status_bar_h(s) - (app.PLAYER_BAR_H if bar_in_flow else 0)
	found := 0
	check :: proc(t: ^testing.T, b: ^ui.Box, bottom: f32, page: string, found: ^int, loc: runtime.Source_Code_Location) {
		if .View_Scroll in b.flags && .Allow_Overflow_Y in b.flags {
			found^ += 1
			end := bottom - (app.LIST_PAD_Y if b.id == "playlists" else 0)
			got := b.rect.y + b.rect.h
			testing.expectf(t, abs(got - end) < 0.5, "%s: %q ends at %v, not %v", page, b.id, got, end, loc = loc)
		}
		for c := b.first; c != nil; c = c.next {
			check(t, c, bottom, page, found, loc)
		}
	}
	check(t, s.ui.root, bottom, page, &found, loc)
	testing.expectf(t, found == want, "%s: %d views that scroll down, not %d", page, found, want, loc = loc)
}
