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
	open_search(t, s, &f)
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

	open_search(t, s, &f)
	testing.expect(t, ui.text_focused())
	testing.expect(t, app.search_page_showing(s))
	library_frame(t, s, &f, back, back_up)
	library_frame(t, s, &f)
	testing.expect(t, !app.search_page_showing(s), "Back from the search page")
	testing.expect_value(t, s.library.playlist, first)
	library_frame(t, s, &f, {kind = .Mouse_Down, x = 600, y = 400, button = .Forward}, {kind = .Mouse_Up, x = 600, y = 400, button = .Forward})
	library_frame(t, s, &f)
	testing.expect(t, app.search_page_showing(s), "Forward to the search page")

	library_frame(t, s, &f, press(s, app.PLAYLISTS[3]))
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

// Shift and the arrows seek by 5 s, held too, between the track's start
// and its end, and do nothing with nothing loaded. The shuffle and repeat
// keys turn them as the buttons do, once per press, and Alt and the arrows
// go through the History. A text field keeps all these keys.
@(test)
library_shortcuts_seek_and_toggle :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	s.playback.player = audio.create(no_redraw_shortcuts, 0, null_output = true)
	defer app.playback_shutdown(s)
	pb := &s.playback
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}

	library_frame(t, s, &f, key(.Right, {.Shift}), key(.Left, {.Shift}))
	testing.expect_value(t, pb.cur.serial, 0)
	testing.expect_value(t, pb.seek_id, 0)

	row := app.view_row(s, 2)
	down, up := left_click(s, fmt.tprintf("%s, %s, %s", row.title, row.artist, row.album))
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f, key(.Space))
	library_frame(t, s, &f, key(.Space))
	testing.expect(t, !app.playback_playing(s), "paused, so the position stays put")
	testing.expect_value(t, pb.index, 2)
	start := app.playback_position(s)
	library_frame(t, s, &f, key(.Right, {.Shift}))
	expect_near(t, app.playback_position(s), start + 5)
	library_frame(t, s, &f, {kind = .Key_Down, key = .Right, modifiers = {.Shift}, repeat = true})
	expect_near(t, app.playback_position(s), start + 10)
	library_frame(t, s, &f, key(.Left, {.Shift}))
	expect_near(t, app.playback_position(s), start + 5)
	library_frame(t, s, &f, key(.Left, {.Shift}), key(.Left, {.Shift}), key(.Left, {.Shift}))
	expect_near(t, app.playback_position(s), 0)
	duration := app.playback_duration(s)
	testing.expect(t, duration > 10, "the track has a length")
	for _ in 0 ..< int(duration / 5) + 3 {
		library_frame(t, s, &f, key(.Right, {.Shift}))
	}
	expect_near(t, app.playback_position(s), duration)
	library_frame(t, s, &f, key(.Left, {.Shift}))
	expect_near(t, app.playback_position(s), duration - 5)
	testing.expect_value(t, pb.index, 2)

	testing.expect(t, !s.settings.shuffle)
	library_frame(t, s, &f, key(.S, {ui.PRIMARY}))
	testing.expect(t, s.settings.shuffle, "the shuffle key turns shuffle on")
	library_frame(t, s, &f, {kind = .Key_Down, key = .S, modifiers = {ui.PRIMARY}, repeat = true})
	testing.expect(t, s.settings.shuffle, "a held key doesn't turn it again")
	library_frame(t, s, &f, key(.S, {ui.PRIMARY}))
	testing.expect(t, !s.settings.shuffle, "and off")

	testing.expect_value(t, s.settings.repeat, audio.Repeat.Off)
	library_frame(t, s, &f, key(.R, {ui.PRIMARY}))
	testing.expect_value(t, s.settings.repeat, audio.Repeat.All)
	library_frame(t, s, &f, {kind = .Key_Down, key = .R, modifiers = {ui.PRIMARY}, repeat = true})
	testing.expect_value(t, s.settings.repeat, audio.Repeat.All)
	library_frame(t, s, &f, key(.R, {ui.PRIMARY}))
	testing.expect_value(t, s.settings.repeat, audio.Repeat.One)
	library_frame(t, s, &f, key(.R, {ui.PRIMARY}))
	testing.expect_value(t, s.settings.repeat, audio.Repeat.Off)

	first := s.library.playlist
	library_frame(t, s, &f, press(s, app.PLAYLISTS[3]))
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.playlist, 3)
	library_frame(t, s, &f, key(.Left, {.Alt}))
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.playlist, first)
	library_frame(t, s, &f, {kind = .Key_Down, key = .Left, modifiers = {.Alt}, repeat = true})
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.playlist, first)
	library_frame(t, s, &f, key(.Right, {.Alt}))
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.playlist, 3)

	open_search(t, s, &f)
	testing.expect(t, ui.text_focused())
	at := app.playback_position(s)
	library_frame(t, s, &f, key(.Right, {.Shift}), key(.Left, {.Shift}), key(.Left, {.Shift}))
	library_frame(t, s, &f, key(.S, {ui.PRIMARY}), key(.R, {ui.PRIMARY}), key(.Left, {.Alt}))
	library_frame(t, s, &f)
	expect_near(t, app.playback_position(s), at)
	testing.expect(t, !s.settings.shuffle, "the search field keeps the shuffle key")
	testing.expect_value(t, s.settings.repeat, audio.Repeat.Off)
	testing.expect(t, app.search_page_showing(s), "the search field keeps Alt-Left")
}

// The tooltips' hints and the settings page come from SHORTCUTS, so no
// two of its entries may share a key.
@(test)
shortcuts_have_their_own_keys :: proc(t: ^testing.T) {
	shortcuts := app.SHORTCUTS
	for a, i in shortcuts {
		testing.expect(t, a.keys != "" && a.does != "", "every shortcut has keys and says what it does")
		for b, j in shortcuts {
			if i < j {
				testing.expectf(t, a.code != b.code || a.modifiers != b.modifiers, "%v and %v share a key", i, j)
			}
		}
	}
}

@(private = "file")
expect_near :: proc(t: ^testing.T, got, want: f64, loc := #caller_location) {
	testing.expectf(t, abs(got - want) < 0.01, "at %.3f s, want %.3f s", got, want, loc = loc)
}

@(private = "file")
no_redraw_shortcuts :: proc "c" () {}
