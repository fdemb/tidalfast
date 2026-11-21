package tidal_tests

import "core:mem"
import "core:testing"

import app "../src/app"
import "../src/audio"
import "../src/platform"
import "../src/text"
import "../src/ui"

@(private = "file")
no_redraw_volume :: proc "c" () {}

@(private = "file")
volume_state :: proc(volume: f32) -> ^app.State {
	s := library_state(true)
	s.settings.volume = volume
	s.playback.player = audio.create(no_redraw_volume, volume, null_output = true)
	s.playback.volume_sent = volume
	return s
}

@(private = "file")
slider_value :: proc(s: ^app.State) -> string {
	n, ok := access_node(s, "Volume")
	if !ok {
		return "no slider"
	}
	return string(n.value)
}

@(private = "file")
expect_volume :: proc(t: ^testing.T, s: ^app.State, volume: f32, muted: bool, loc := #caller_location) {
	testing.expectf(t, abs(s.settings.volume - volume) < 1e-4, "the volume is %v, not %v", s.settings.volume, volume, loc = loc)
	testing.expect_value(t, s.settings.muted, muted, loc = loc)
	heard := f32(0) if muted else volume
	testing.expectf(t, abs(s.playback.volume_sent - heard) < 1e-4, "the player has %v, not %v", s.playback.volume_sent, heard, loc = loc)
}

// The speaker button mutes and unmutes back at the level from before, and
// its icon, name and the slider follow. Dragging the slider or the volume
// keys while muted unmute at the new level.
@(test)
speaker_button_mutes_and_unmutes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := volume_state(0.4)
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	testing.expect_value(t, node_box(s, "Mute").label, text.ICON_SPEAKER_LOW)
	testing.expect_value(t, slider_value(s), "40%")

	saves := s.data.settings_store.gen
	library_frame(t, s, &f, press(s, "Mute"))
	library_frame(t, s, &f)
	expect_volume(t, s, 0.4, true)
	testing.expect_value(t, s.data.settings_store.gen, saves + 1)
	testing.expect_value(t, slider_value(s), "Muted")
	testing.expect_value(t, node_box(s, "Unmute").label, text.ICON_SPEAKER_X)
	_, mute := access_node(s, "Mute")
	testing.expect(t, !mute, "the button is Unmute while muted")

	library_frame(t, s, &f, press(s, "Unmute"))
	library_frame(t, s, &f)
	expect_volume(t, s, 0.4, false)
	testing.expect_value(t, slider_value(s), "40%")

	library_frame(t, s, &f, press(s, "Mute"))
	library_frame(t, s, &f, key(.Up, {ui.PRIMARY}))
	library_frame(t, s, &f)
	expect_volume(t, s, 0.5, false)
	testing.expect_value(t, node_box(s, "Mute").label, text.ICON_SPEAKER_HIGH)

	library_frame(t, s, &f, press(s, "Mute"))
	library_frame(t, s, &f)
	n, _ := access_node(s, "Volume")
	x, y := n.frame[0] + n.frame[2] / 4, n.frame[1] + n.frame[3] / 2
	library_frame(t, s, &f, {kind = .Mouse_Down, x = x, y = y, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = x, y = y, button = .Left})
	library_frame(t, s, &f)
	expect_volume(t, s, 0.25, false)
	testing.expect_value(t, slider_value(s), "25%")
}

// At a volume of 0 the button already shows the sound off, and unmuting
// from there, or from a mute at 0, brings back the default.
@(test)
unmute_at_zero_gives_the_default :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := volume_state(0)
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	testing.expect_value(t, node_box(s, "Unmute").label, text.ICON_SPEAKER_X)
	testing.expect_value(t, slider_value(s), "0%")
	library_frame(t, s, &f, press(s, "Unmute"))
	library_frame(t, s, &f)
	expect_volume(t, s, app.VOLUME_DEFAULT, false)

	app.playback_set_volume(s, 0, true)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Unmute"))
	library_frame(t, s, &f)
	expect_volume(t, s, app.VOLUME_DEFAULT, false)

	// Muted at 0, as a file can have it.
	s.settings.volume = 0
	s.settings.muted = true
	library_frame(t, s, &f)
	testing.expect_value(t, slider_value(s), "Muted")
	library_frame(t, s, &f, press(s, "Unmute"))
	library_frame(t, s, &f)
	expect_volume(t, s, app.VOLUME_DEFAULT, false)
}

// M mutes and unmutes, once per press and only without modifiers, and the
// search field keeps it.
@(test)
m_key_mutes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := volume_state(0.6)
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	library_frame(t, s, &f, key(.M))
	expect_volume(t, s, 0.6, true)
	library_frame(t, s, &f, {kind = .Key_Down, key = .M, repeat = true})
	expect_volume(t, s, 0.6, true)
	library_frame(t, s, &f, key(.M, {.Shift}), key(.M, {ui.PRIMARY}))
	expect_volume(t, s, 0.6, true)
	library_frame(t, s, &f, key(.M))
	expect_volume(t, s, 0.6, false)

	open_search(t, s, &f)
	testing.expect(t, ui.text_focused())
	library_frame(t, s, &f, key(.M))
	expect_volume(t, s, 0.6, false)
}

// The wheel over the slider or the speaker turns the volume, a notch by
// 5% and a trackpad in proportion, from the level before a mute. It saves
// once, after the wheel stops, or at shutdown if that comes first.
@(test)
wheel_turns_the_volume :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := volume_state(0.5)
	defer library_state_free(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	n, _ := access_node(s, "Volume")
	over := platform.Event{kind = .Mouse_Move, x = n.frame[0] + n.frame[2] / 2, y = n.frame[1] + n.frame[3] / 2}
	saves := s.data.settings_store.gen

	library_frame(t, s, &f, over, {kind = .Scroll, dy = app.WHEEL_NOTCH_LINES})
	expect_volume(t, s, 0.55, false)
	library_frame(t, s, &f, {kind = .Scroll, dy = -2 * app.WHEEL_NOTCH_LINES})
	expect_volume(t, s, 0.45, false)
	library_frame(t, s, &f, {kind = .Scroll, dy = 40, precise = true, phase = .Began})
	expect_volume(t, s, 0.55, false)
	library_frame(t, s, &f, {kind = .Scroll, precise = true, phase = .Ended})
	testing.expect_value(t, s.data.settings_store.gen, saves)
	testing.expect(t, ui.wake_after(&s.ui) > 0, "a frame is asked for when the save is due")

	for _ in 0 ..< 40 {
		library_frame(t, s, &f, dt = 0.05)
	}
	testing.expect_value(t, s.data.settings_store.gen, saves + 1)
	testing.expect_value(t, ui.wake_after(&s.ui), 0)

	// Muted, the wheel unmutes from the level before.
	library_frame(t, s, &f, key(.M))
	library_frame(t, s, &f)
	speaker, found := access_node(s, "Unmute")
	testing.expect(t, found)
	library_frame(t, s, &f, {kind = .Mouse_Move, x = speaker.frame[0] + 4, y = speaker.frame[1] + 4}, {kind = .Scroll, dy = -app.WHEEL_NOTCH_LINES})
	expect_volume(t, s, 0.5, false)

	// Shutdown saves what the wheel left.
	saves = s.data.settings_store.gen
	app.playback_shutdown(s)
	testing.expect_value(t, s.data.settings_store.gen, saves + 1)
}
