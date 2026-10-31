package tidal_tests

import "core:fmt"
import "core:mem"
import "core:testing"

import app "../src/app"
import "../src/audio"
import "../src/platform"
import "../src/ui"

// The library's shortcuts work with any box focused by a click, as a row
// is, and stay out of a text field's way.
@(test)
library_shortcuts_control_playback :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	s.playback.player = audio.create(no_redraw_shortcuts, 0, null_output = true)
	defer app.playback_shutdown(s)
	s.settings.volume = 0.5
	pb := &s.playback
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}

	// A click on row 2 selects it and gives the table the focus. Space
	// plays the selected row, and Space again pauses it.
	row := app.view_row(s, 2)
	down, up := left_click(s, fmt.tprintf("%s, %s, %s", row.title, row.artist, row.album))
	library_frame(t, s, &f, down, up)
	testing.expect_value(t, s.library.selected, 2)
	library_frame(t, s, &f, key(.Space))
	testing.expect(t, app.playback_playing(s), "Space plays the selected row")
	testing.expect_value(t, pb.index, 2)
	library_frame(t, s, &f, key(.Space))
	testing.expect(t, !app.playback_playing(s), "Space again pauses it")
	library_frame(t, s, &f, {kind = .Key_Down, key = .Space, repeat = true})
	testing.expect(t, !app.playback_playing(s), "a held Space doesn't toggle again")

	library_frame(t, s, &f, key(.Right, {ui.PRIMARY}))
	testing.expect_value(t, pb.index, 3)
	library_frame(t, s, &f, key(.Left, {ui.PRIMARY}))
	testing.expect_value(t, pb.index, 2)
	library_frame(t, s, &f, key(.Down, {ui.PRIMARY}))
	testing.expect_value(t, s.settings.volume, f32(0.4))
	library_frame(t, s, &f, key(.Up, {ui.PRIMARY}), key(.Up, {ui.PRIMARY}))
	testing.expect_value(t, s.settings.volume, f32(0.6))

	// In the search field the keys are the field's.
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
	testing.expect(t, ui.text_focused())
	playing := app.playback_playing(s)
	library_frame(t, s, &f, key(.Space), key(.Right, {ui.PRIMARY}), key(.Up, {ui.PRIMARY}))
	testing.expect_value(t, app.playback_playing(s), playing)
	testing.expect_value(t, pb.index, 2)
	testing.expect_value(t, s.settings.volume, f32(0.6))
}

// The mouse's Back and Forward go through the places visited, with the
// search field focused too, and with a menu open they only close it.
@(test)
mouse_back_and_forward_go_through_history :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	first := s.library.playlist
	library_frame(t, s, &f, press(s, app.PLAYLISTS[3]))
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.playlist, 3)

	back := platform.Event{kind = .Mouse_Down, x = 600, y = 400, button = .Back}
	back_up := platform.Event{kind = .Mouse_Up, x = 600, y = 400, button = .Back}
	library_frame(t, s, &f, back, back_up)
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.playlist, first)
	testing.expectf(t, s.library.selected == -1, "Back over a row doesn't select it, selected %d", s.library.selected)

	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
	testing.expect(t, ui.text_focused())
	library_frame(t, s, &f, {kind = .Mouse_Down, x = 600, y = 400, button = .Forward}, {kind = .Mouse_Up, x = 600, y = 400, button = .Forward})
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.playlist, 3)

	row := app.view_row(s, 2)
	down, up := right_click(s, fmt.tprintf("%s, %s, %s", row.title, row.artist, row.album))
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	testing.expect(t, s.ui.menu_open, "the track menu is open")
	library_frame(t, s, &f, back, back_up)
	library_frame(t, s, &f)
	testing.expect(t, !s.ui.menu_open, "Back closes the menu")
	testing.expect_value(t, s.library.playlist, 3)
}

@(private = "file")
no_redraw_shortcuts :: proc "c" () {}
