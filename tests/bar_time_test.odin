package tidal_tests

import "core:mem"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/platform"

// The time right of the progress bar: the time left, which with the
// elapsed time left of the bar adds up to the length, even part way
// through a second; never below -0:00; the length in the other form; and
// 0:00 with nothing loaded.
@(test)
bar_time_text :: proc(t: ^testing.T) {
	testing.expect_value(t, app.bar_time(0, 225, true, true), "-3:45")
	testing.expect_value(t, app.bar_time(100, 225, true, true), "-2:05")
	// 0:12 shown left of the bar, so 0:18 left of a 0:30 track.
	testing.expect_value(t, app.bar_time(12.7, 30, true, true), "-0:18")
	testing.expect_value(t, app.bar_time(224.5, 225, true, true), "-0:01")
	testing.expect_value(t, app.bar_time(225, 225, true, true), "-0:00")
	testing.expect_value(t, app.bar_time(231.2, 225, true, true), "-0:00")
	testing.expect_value(t, app.bar_time(100, 225, true, false), "3:45")

	testing.expect_value(t, app.bar_time(62, 3723, true, true), "-1:01:01")
	testing.expect_value(t, app.bar_time(3600, 3723, true, true), "-2:03")
	testing.expect_value(t, app.bar_time(62, 3723, true, false), "1:02:03")

	testing.expect_value(t, app.bar_time(0, 0, false, true), "0:00")
	testing.expect_value(t, app.bar_time(0, 0, false, false), "0:00")

	for tenths in 0 ..= 2256 {
		p := f64(tenths) / 10
		rest := app.bar_time(p, 225.6, true, true)
		testing.expect(t, strings.has_prefix(rest, "-"))
		if seconds(app.clock(p)) + seconds(rest[1:]) != 225 {
			testing.expectf(t, false, "%s and %s don't add up to 3:45", app.clock(p), rest)
			return
		}
	}
}

@(private = "file")
seconds :: proc(clock: string) -> int {
	n, part := 0, 0
	for c in clock {
		if c == ':' {
			n, part = n * 60 + part, 0
		} else {
			part = part * 10 + int(c - '0')
		}
	}
	return n * 60 + part
}

// Clicking the time, or pressing it as a button, switches it between the
// time left and the length, queues the choice for saving and keeps its
// width and the progress bar's. The time left follows a drag on the bar.
@(test)
bar_time_switches :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	items := []app.Queue_Item{{title = "Song", artist = "Someone", seconds = 225}}
	s.playback.items = items
	s.playback.index = 0
	defer s.playback.items = nil
	s.playback.seek_id = 1
	s.playback.seek_seconds = 100.5
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	n, ok := access_node(s, "Time remaining")
	testing.expect(t, ok, "the time left, as a button")
	testing.expect_value(t, n.role, platform.Access_Role.Button)
	testing.expect_value(t, string(n.value), "2:05")
	testing.expect_value(t, node_box(s, "Time remaining").label, "-2:05")
	before := node_box(s, "Time remaining").rect
	progress := node_box(s, "Position").rect

	gen := s.data.settings_store.gen
	library_frame(t, s, &f, press(s, "Time remaining"))
	library_frame(t, s, &f)
	testing.expect(t, s.settings.show_duration)
	testing.expect_value(t, s.data.settings_store.gen, gen + 1)
	testing.expect(t, s.data.settings_store.latest.show_duration, "the choice queued for saving")
	n, ok = access_node(s, "Duration")
	testing.expect(t, ok, "the length, as a button")
	testing.expect_value(t, string(n.value), "3:45")
	testing.expect_value(t, node_box(s, "Duration").label, "3:45")
	testing.expect_value(t, node_box(s, "Duration").rect, before)
	testing.expect_value(t, node_box(s, "Position").rect, progress)

	down, up := left_click(s, "Duration")
	library_frame(t, s, &f, down)
	library_frame(t, s, &f, up)
	library_frame(t, s, &f)
	testing.expect(t, !s.settings.show_duration, "a click switches it back")
	testing.expect_value(t, s.data.settings_store.gen, gen + 2)
	testing.expect_value(t, node_box(s, "Time remaining").rect, before)

	// Held part way along the bar, both times show the drag position.
	x, y := progress.x + progress.w * 0.4, progress.y + progress.h / 2
	library_frame(t, s, &f, {kind = .Mouse_Move, x = x, y = y})
	library_frame(t, s, &f, {kind = .Mouse_Down, x = x, y = y, button = .Left, click_count = 1})
	library_frame(t, s, &f)
	testing.expect(t, s.playback.dragging)
	at := s.playback.drag_seconds
	testing.expect(t, at > 80 && at < 100, "dragged to 40%")
	testing.expect_value(t, node_box(s, "Time remaining").label, app.bar_time(at, 225, true, true))
	pos, _ := access_node(s, "Position")
	testing.expect_value(t, seconds(strings.split(string(pos.value), " ", context.temp_allocator)[0]) + seconds(string(node_box(s, "Time remaining").label[1:])), 225)
	library_frame(t, s, &f, {kind = .Mouse_Up, x = x, y = y, button = .Left})
}

// With nothing loaded the time shows 0:00 with no minus sign.
@(test)
bar_time_with_nothing_loaded :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	for _ in 0 ..< 2 {
		library_frame(t, s, &f)
	}
	testing.expect_value(t, node_box(s, "Time remaining").label, "0:00")
}
