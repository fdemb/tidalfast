package tidal_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/ui"

@(private = "file")
static_text :: proc(s: ^app.State, label: string) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Static_Text && string(n.label) == label {
			return n, true
		}
	}
	return {}, false
}

// What's playing shows only in the status bar, under the player bar, and
// only when TIDALFAST_STATUS_BAR turns it on.
@(test)
status_bar_says_whats_playing :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	items := []app.Queue_Item{{title = "Song", artist = "Someone"}}
	s.playback.items = items
	s.playback.index = 0
	defer s.playback.items = nil
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	_, shown := static_text(s, "Playing Song by Someone")
	testing.expect(t, !shown, "no status bar unless asked for")
	app.set_status(s, .Copied_Page, -1)
	library_frame(t, s, &f)
	// The next frame frees status_text's string.
	copied := strings.clone(app.status_text(s))
	testing.expect(t, copied != "", "a status to show")
	_, shown = static_text(s, copied)
	testing.expect(t, !shown, "no status line in the views")

	s.status_bar = true
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	line, ok := static_text(s, fmt.tprintf("Playing Song by Someone · %s", copied))
	testing.expect(t, ok, "the status bar says what's playing")
	player := ui.box_lookup(&s.ui, ui.key_from_string(0, "player"))
	testing.expect(t, player != nil, "the player bar")
	if ok && player != nil {
		testing.expect(t, line.frame[1] >= player.rect.y + player.rect.h, "the status bar is under the player bar")
	}

	s.playback.paused = true
	app.set_status(s, .None, -1)
	library_frame(t, s, &f)
	_, ok = static_text(s, "Paused Song by Someone")
	testing.expect(t, ok, "and when it's paused")
}
