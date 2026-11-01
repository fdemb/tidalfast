package tidal_tests

import "core:mem"
import "core:slice"
import "core:testing"

import app "../src/app"
import "../src/ui"

// With the player bar over the list, the rows under it are cut to what
// shows above it, and a row it hides entirely isn't read out.
@(test)
rows_under_the_player_bar_are_cut :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	s.bar_over_content = true
	f := Frame{size = {1100, 700}}
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	bar_top := f.size.y - app.PLAYER_BAR_H
	nodes, _ := ui.access_tree(&s.ui)
	rows := 0
	for n in nodes {
		if n.role != .Row || n.frame[0] < app.SIDEBAR_DEFAULT {
			continue
		}
		rows += 1
		testing.expectf(t, n.frame[3] > 0, "row %q has a frame", n.label)
		testing.expectf(t, n.frame[1] + n.frame[3] <= bar_top + 0.5, "row %q ends at %v, under the player bar at %v", n.label, n.frame[1] + n.frame[3], bar_top)
	}
	testing.expect(t, rows > 0, "the list's rows are in the tree")
}

// The volume slider's frame is about its bar, not the player bar's height.
@(test)
volume_slider_is_its_own_height :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1100, 700}}
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	nodes, _ := ui.access_tree(&s.ui)
	found := false
	for n in nodes {
		if n.role == .Slider && string(n.label) == "Volume" {
			found = true
			testing.expectf(t, n.frame[3] <= 32, "the slider is %v tall", n.frame[3])
		}
	}
	testing.expect(t, found, "a volume slider")
}

// A playlist with one song says so in the singular.
@(test)
one_song_is_singular :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	s.data.sidebar.items = []app.Sidebar_Item{{id = "one", name = "One", tracks = 1}, {id = "two", name = "Two", tracks = 2}}
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	labels: [dynamic]string
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Row {
			append(&labels, string(n.label))
		}
	}
	testing.expectf(t, slice.contains(labels[:], "One, 1 song"), "rows %q", labels[:])
	testing.expectf(t, slice.contains(labels[:], "Two, 2 songs"), "rows %q", labels[:])
}
