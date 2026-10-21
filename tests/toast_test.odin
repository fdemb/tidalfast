package tidal_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/ui"

@(private = "file")
toast_node :: proc(s: ^app.State) -> (platform.Access_Node, bool) {
	box := ui.box_lookup(&s.ui, ui.key_from_string(0, "###toast"))
	if box == nil || box.open_t == 0 {
		return {}, false
	}
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.id == u64(box.key) {
			return n, true
		}
	}
	return {}, false
}

@(private = "file")
settle :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, seconds: f64) {
	for _ in 0 ..< int(seconds / 0.1) {
		library_frame(t, s, f, dt = 0.1)
	}
}

// An error shows in a toast for a few seconds; the rest of the status
// doesn't.
@(test)
toast_shows_only_errors :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	settle(t, s, &f, 0.5)
	_, shown := toast_node(s)
	testing.expect(t, !shown, "no toast without an error")

	app.set_status(s, .Copied_Page, -1)
	settle(t, s, &f, 0.5)
	_, shown = toast_node(s)
	testing.expect(t, !shown, "no toast for a copied link")

	app.set_status(s, .Add_Failed, 0, 1)
	settle(t, s, &f, 0.5)
	n, ok := toast_node(s)
	testing.expect(t, ok, "a failed add shows a toast")
	testing.expect(t, strings.has_prefix(string(n.label), "Couldn't add "), fmt.tprintf("the toast says what failed, not %q", n.label))
	testing.expect(t, s.ui.wake > 0, "a wake-up to hide it, not a frame every vsync")

	settle(t, s, &f, app.TOAST_SECONDS + 1)
	_, shown = toast_node(s)
	testing.expect(t, !shown, "gone after a few seconds")

	// Another add failing is a new error.
	app.set_status(s, .Add_Failed, 1, 1)
	settle(t, s, &f, 0.5)
	_, ok = toast_node(s)
	testing.expect(t, ok, "a new error shows again")
	box := ui.box_lookup(&s.ui, ui.key_from_string(0, "###toast"))
	down := platform.Event{kind = .Mouse_Down, x = box.rect.x + 10, y = box.rect.y + 10, button = .Left, click_count = 1}
	up := platform.Event{kind = .Mouse_Up, x = down.x, y = down.y, button = .Left}
	library_frame(t, s, &f, down, up)
	settle(t, s, &f, 1)
	_, shown = toast_node(s)
	testing.expect(t, !shown, "a click dismisses it")
}
