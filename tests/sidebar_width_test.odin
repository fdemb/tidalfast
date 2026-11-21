package tidal_tests

import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import app "../src/app"
// handle_at is the middle of the sidebar's handle in the last frame.
@(private = "file")
handle_at :: proc(s: ^app.State) -> [2]f32 {
	n, ok := access_node(s, "Sidebar width")
	assert(ok)
	return {n.frame[0] + n.frame[2] / 2, n.frame[1] + n.frame[3] / 2}
}

// drag_handle drags the sidebar's handle by dx over a few frames, as a
// person would, moving the mouse onto it first.
@(private = "file")
drag_handle :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, dx: f32, click_count: u32 = 1) {
	p := handle_at(s)
	library_frame(t, s, f, {kind = .Mouse_Move, x = p.x, y = p.y})
	library_frame(t, s, f, {kind = .Mouse_Down, x = p.x, y = p.y, button = .Left, click_count = click_count})
	library_frame(t, s, f, {kind = .Mouse_Move, x = p.x + dx / 2, y = p.y})
	library_frame(t, s, f, {kind = .Mouse_Move, x = p.x + dx, y = p.y})
	library_frame(t, s, f, {kind = .Mouse_Up, x = p.x + dx, y = p.y, button = .Left})
	library_frame(t, s, f, {kind = .Mouse_Leave})
}

// saves is how many times the settings were handed over to be written.
@(private = "file")
saves :: proc(s: ^app.State) -> u64 {
	return s.data.settings_store.gen
}

@(test)
sidebar_width_saves_once_per_drag :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1400, 800}}
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.sidebar_w, app.SIDEBAR_DEFAULT)

	drag_handle(t, s, &f, 150)
	testing.expect_value(t, s.library.sidebar_w, 400)
	testing.expect_value(t, s.settings.sidebar_w, 400)
	testing.expect_value(t, saves(s), 1)
	testing.expect_value(t, s.data.settings_store.latest.sidebar_w, 400)

	// A click that doesn't move it saves nothing.
	drag_handle(t, s, &f, 0)
	testing.expect_value(t, s.settings.sidebar_w, 400)
	testing.expect_value(t, saves(s), 1)

	// Past the ends it stops at them.
	drag_handle(t, s, &f, 1000)
	testing.expect_value(t, s.settings.sidebar_w, app.SIDEBAR_MAX)
	drag_handle(t, s, &f, -1000)
	testing.expect_value(t, s.settings.sidebar_w, app.SIDEBAR_MIN)
	testing.expect_value(t, saves(s), 3)
}

@(test)
sidebar_width_resets_on_double_click :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1400, 800}}
	s.settings.sidebar_w = 480
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.sidebar_w, 480)

	drag_handle(t, s, &f, 0)
	drag_handle(t, s, &f, 0, click_count = 2)
	testing.expect_value(t, s.settings.sidebar_w, 0)
	testing.expect_value(t, s.library.sidebar_w, app.SIDEBAR_DEFAULT)
	testing.expect_value(t, saves(s), 1)
	testing.expect_value(t, s.data.settings_store.latest.sidebar_w, 0)
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.sidebar_w, app.SIDEBAR_DEFAULT)

	// At the default already there's nothing to save.
	drag_handle(t, s, &f, 0, click_count = 2)
	testing.expect_value(t, saves(s), 1)
}

// A narrow window squeezes the sidebar for as long as it's narrow, and the
// width chosen comes back when it widens.
@(test)
sidebar_width_survives_a_narrow_window :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1400, 800}}
	library_frame(t, s, &f)
	drag_handle(t, s, &f, 250)
	testing.expect_value(t, s.settings.sidebar_w, 500)

	f.size = {665, 800}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.sidebar_w, 300)
	testing.expect_value(t, s.settings.sidebar_w, 500)
	// A click on the squeezed handle keeps the width chosen too.
	drag_handle(t, s, &f, 0)
	testing.expect_value(t, s.settings.sidebar_w, 500)

	f.size = {1400, 800}
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.sidebar_w, 500)
	testing.expect_value(t, s.settings.sidebar_w, 500)
	testing.expect_value(t, saves(s), 1)
	testing.expect_value(t, s.data.settings_store.latest.sidebar_w, 500)
}

// Whatever the file says, the sidebar stays between its ends, and a width
// that isn't one is the default.
@(test)
sidebar_width_from_a_bad_file :: proc(t: ^testing.T) {
	testing.expect_value(t, app.sidebar_width(0, 1400), app.SIDEBAR_DEFAULT)
	testing.expect_value(t, app.sidebar_width(-40, 1400), app.SIDEBAR_DEFAULT)
	testing.expect_value(t, app.sidebar_width(f32(math.nan_f32()), 1400), app.SIDEBAR_DEFAULT)
	testing.expect_value(t, app.sidebar_width(f32(math.inf_f32(1)), 1400), app.SIDEBAR_MAX)
	testing.expect_value(t, app.sidebar_width(1e30, 1400), app.SIDEBAR_MAX)
	testing.expect_value(t, app.sidebar_width(20, 1400), app.SIDEBAR_MIN)
	testing.expect_value(t, app.sidebar_width(500, 700), 700 - app.HANDLE_W - app.MAIN_MIN)
	testing.expect_value(t, app.sidebar_width(500, 300), app.SIDEBAR_MIN)

	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1400, 800}}
	s.settings.sidebar_w = f32(math.nan_f32())
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.sidebar_w, app.SIDEBAR_DEFAULT)
	_, ok := access_node(s, "Sidebar width")
	testing.expect(t, ok)
}

@(test)
sidebar_width_in_the_settings_file :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/tidalfast-sidebar-%d", temp_base(), time.now()._nsec)
	path := fmt.tprintf("%s/settings.json", dir)
	defer os.remove_all(dir)

	testing.expect(t, app.settings_save(path, {volume = 0.5, sidebar_w = 420}))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"sidebar_width": 420`))
	st, ok := app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{volume = 0.5, sidebar_w = 420})

	// The default width isn't written, and a file from before it was
	// saved, or without it, has the default.
	testing.expect(t, app.settings_save(path, {volume = 0.5}))
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data), "sidebar_width"))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st.sidebar_w, 0)
	_ = os.write_entire_file(path, transmute([]u8)string(`{"bit_perfect": false, "scrollbars": "Floating", "volume": 0.3}`))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{volume = 0.3})

	cases := []struct {
		json: string,
		want: f32,
	}{{`{"sidebar_width": 5}`, app.SIDEBAR_MIN}, {`{"sidebar_width": 99999}`, app.SIDEBAR_MAX}, {`{"sidebar_width": 1e300}`, app.SIDEBAR_MAX}, {`{"sidebar_width": -300}`, 0}, {`{"sidebar_width": 0}`, 0}, {`{"sidebar_width": 333.5}`, 333.5}}
	for c in cases {
		_ = os.write_entire_file(path, transmute([]u8)c.json)
		st, ok = app.settings_load(path)
		testing.expectf(t, ok, "%s doesn't load", c.json)
		testing.expectf(t, st.sidebar_w == c.want, "%s gives %v, not %v", c.json, st.sidebar_w, c.want)
		testing.expectf(t, st.volume == 0.7, "%s loses the other settings", c.json)
	}
	// A width that isn't a number is a broken file, which gives the
	// defaults as any broken file does.
	_ = os.write_entire_file(path, transmute([]u8)string(`{"sidebar_width": "wide"}`))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st.sidebar_w, 0)
	_ = os.write_entire_file(path, transmute([]u8)string(`{"sidebar_width": NaN}`))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st.sidebar_w, 0)
}
