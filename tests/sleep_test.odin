package tidal_tests

import "core:math"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/ui"

@(private = "file")
no_redraw_sleep :: proc "c" () {}

@(private = "file")
sleep_rows := []app.Row {
	{title = "One", artist = "A", seconds = 30},
	{title = "Two", artist = "A", seconds = 30},
	{title = "Three", artist = "A", seconds = 30},
}

// sleep_state is the library with the fake rows and a player on the null
// device.
@(private = "file")
sleep_state :: proc() -> ^app.State {
	s := library_state(true)
	s.settings.volume = 0.5
	s.playback.player = audio.create(no_redraw_sleep, 0.5, null_output = true)
	s.playback.volume_sent = 0.5
	return s
}

// sleep_player_state is a player with no UI, for feeding playback_observe
// made-up statuses, as the tests in player_test.odin do.
@(private = "file")
sleep_player_state :: proc() -> ^app.State {
	s := new(app.State)
	s.rows = sleep_rows
	s.data.fake = true
	s.library.selected = -1
	s.playback.index = -1
	s.playback.player = audio.create(no_redraw_sleep, 0, null_output = true)
	return s
}

@(private = "file")
sleep_value :: proc(s: ^app.State) -> string {
	n, ok := access_node(s, "Sleep timer")
	if !ok {
		return "no button"
	}
	return string(n.value)
}

// settle runs frames until whatever was fading or waiting to show, such
// as a menu closing or a tooltip, has settled.
@(private = "file")
settle :: proc(t: ^testing.T, s: ^app.State, f: ^Frame) {
	for _ in 0 ..< 30 {
		library_frame(t, s, f, dt = 0.1)
	}
}

// player_gain is the gain the player's callback heads for.
@(private = "file")
player_gain :: proc(s: ^app.State) -> f32 {
	return transmute(f32)sync.atomic_load(&s.playback.player.volume_bits)
}

// The menu's choices each set a deadline that far from the frame they were
// picked in, and the frames after ask for one wake, at the deadline. End of
// track asks for none, and Off clears the deadline and the wake. The
// button's value and the menu's first item say what's left.
@(test)
sleep_menu_sets_the_deadline :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := sleep_state()
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	f: Frame
	settle(t, s, &f)
	testing.expect_value(t, sleep_value(s), "Off")
	testing.expect_value(t, ui.wake_after(&s.ui), 0)

	CHOICES :: [4]struct {
		name:    string,
		minutes: int,
		left:    string,
	}{{"15 minutes", 15, "15 minutes left"}, {"30 minutes", 30, "30 minutes left"}, {"45 minutes", 45, "45 minutes left"}, {"1 hour", 60, "60 minutes left"}}
	for c in CHOICES {
		library_frame(t, s, &f, press(s, "Sleep timer"))
		library_frame(t, s, &f)
		testing.expect(t, ui.menu_is_open("sleep_menu"))
		library_frame(t, s, &f, press(s, c.name))
		picked := f.now
		testing.expect_value(t, pb.sleep.at, picked + f64(c.minutes) * 60)
		testing.expect_value(t, pb.sleep.minutes, c.minutes)
		settle(t, s, &f)
		testing.expect(t, !f.animating, "the timer keeps no frames coming")
		testing.expectf(t, abs(f64(ui.wake_after(&s.ui)) - (pb.sleep.at - f.now)) < 1e-3, "%s: a wake in %v s, not at the deadline %v s away", c.name, ui.wake_after(&s.ui), pb.sleep.at - f.now)
		testing.expect_value(t, sleep_value(s), c.left)
	}

	// With the menu open, its first item says what's left and is Turn off.
	library_frame(t, s, &f, press(s, "Sleep timer"))
	library_frame(t, s, &f)
	off := node_box(s, "Turn off")
	testing.expect_value(t, off.label, "Turn off (60 min left)")
	library_frame(t, s, &f, press(s, "Turn off"))
	settle(t, s, &f)
	testing.expect(t, !app.sleep_on(pb))
	testing.expect_value(t, ui.wake_after(&s.ui), 0)
	testing.expect_value(t, sleep_value(s), "Off")

	library_frame(t, s, &f, press(s, "Sleep timer"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "End of track"))
	settle(t, s, &f)
	testing.expect(t, pb.sleep.end_of_track)
	testing.expect_value(t, pb.sleep.at, 0)
	testing.expect_value(t, ui.wake_after(&s.ui), 0)
	testing.expect_value(t, sleep_value(s), "at the end of this track")
	library_frame(t, s, &f, press(s, "Sleep timer"))
	library_frame(t, s, &f)
	testing.expect_value(t, node_box(s, "Turn off").label, "Turn off (end of track)")
	_, marked := access_node(s, "End of track")
	testing.expect(t, marked)
}

// The value counts whole minutes up, so it says 1 minute in the last one.
// While the menu is open it asks for a frame when the minutes change, and
// none once it's closed.
@(test)
sleep_minutes_left :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := sleep_state()
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	f: Frame
	library_frame(t, s, &f)
	app.sleep_set(s, f.now, minutes = 15)
	library_frame(t, s, &f, dt = 30)
	testing.expect_value(t, sleep_value(s), "15 minutes left")
	library_frame(t, s, &f, dt = 31)
	testing.expect_value(t, sleep_value(s), "14 minutes left")

	library_frame(t, s, &f, press(s, "Sleep timer"))
	library_frame(t, s, &f)
	turn := pb.sleep.at - 13 * 60
	testing.expectf(t, abs(f64(ui.wake_after(&s.ui)) - (turn - f.now)) < 1e-3, "the open menu wakes in %v s, not at the next minute's turn %v s away", ui.wake_after(&s.ui), turn - f.now)
	library_frame(t, s, &f, key(.Escape))
	settle(t, s, &f)
	testing.expectf(t, abs(f64(ui.wake_after(&s.ui)) - (pb.sleep.at - f.now)) < 1e-3, "closed, it wakes in %v s, not at the deadline", ui.wake_after(&s.ui))

	library_frame(t, s, &f, dt = pb.sleep.at - f.now - 30)
	testing.expect_value(t, sleep_value(s), "1 minute left")
}

// wait_status runs playback_update until the player's status has state.
@(private = "file")
wait_status :: proc(s: ^app.State, state: audio.Play_State) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 3 * time.Second {
		app.playback_update(s, nil)
		if s.playback.status.state == state && s.playback.status.serial == s.playback.cur.serial {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

// At the deadline the volume fades out, then playback pauses, the timer
// is gone, the status bar says so and no more frames are asked for. The
// player's volume comes back once the pause has taken. Pausing by hand
// before that doesn't cancel it.
@(test)
sleep_timer_fades_and_pauses :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := sleep_state()
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	f: Frame
	library_frame(t, s, &f)
	app.playback_play_row(s, 0)
	app.sleep_set(s, f.now, minutes = 30)

	// A pause and play in between leaves it set.
	app.playback_set_paused(s, true)
	library_frame(t, s, &f, dt = 60)
	testing.expect(t, app.sleep_on(pb), "a pause by hand cancelled it")
	app.playback_set_paused(s, false)
	testing.expect(t, wait_status(s, .Playing))
	full := player_gain(s)

	// The frame at the deadline starts the fade.
	library_frame(t, s, &f, dt = pb.sleep.at - f.now)
	testing.expect(t, !app.sleep_on(pb))
	testing.expect(t, app.playback_playing(s), "it fades before it pauses")
	testing.expect_value(t, s.library.status, app.Status.Slept)
	testing.expect(t, ui.wake_after(&s.ui) > 0 && ui.wake_after(&s.ui) <= f32(app.SLEEP_FADE_STEP) + 1e-3, "the fade asks for its next step")
	library_frame(t, s, &f, dt = app.SLEEP_FADE / 2)
	half := player_gain(s)
	testing.expectf(t, half > 0 && half < full, "half way through the fade the gain is %v of %v", half, full)

	library_frame(t, s, &f, dt = app.SLEEP_FADE)
	testing.expect(t, !app.playback_playing(s))
	testing.expect(t, pb.paused)
	testing.expect(t, wait_status(s, .Paused))
	library_frame(t, s, &f)
	testing.expectf(t, abs(player_gain(s) - full) < 1e-6, "the gain is %v after the pause, not %v", player_gain(s), full)
	settle(t, s, &f)
	testing.expect_value(t, ui.wake_after(&s.ui), 0)
	testing.expect(t, !f.animating)
}

// A timer that comes due with nothing playing only clears. One whose
// frame comes hours late, as after the process was stopped, fires in that
// frame.
@(test)
sleep_timer_when_paused_or_late :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := sleep_state()
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	f: Frame
	library_frame(t, s, &f)
	app.playback_play_row(s, 0)
	app.playback_set_paused(s, true)
	app.sleep_set(s, f.now, minutes = 15)
	library_frame(t, s, &f, dt = 15 * 60)
	testing.expect(t, !app.sleep_on(pb))
	testing.expect_value(t, pb.sleep.fade_from, 0)
	testing.expect_value(t, s.library.status, app.Status.None)
	testing.expect_value(t, ui.wake_after(&s.ui), 0)
	testing.expect(t, pb.paused)

	app.playback_set_paused(s, false)
	app.sleep_set(s, f.now, minutes = 45)
	library_frame(t, s, &f, dt = 5 * 3600)
	testing.expect(t, !app.sleep_on(pb))
	testing.expect_value(t, pb.sleep.fade_from, f.now)
	library_frame(t, s, &f, dt = app.SLEEP_FADE)
	testing.expect(t, pb.paused)
	testing.expect_value(t, s.library.status, app.Status.Slept)
}

// Muted there's nothing to fade, as with bit-perfect output, which skips
// the volume: it pauses at once.
@(test)
sleep_timer_pauses_at_once_when_muted :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := sleep_state()
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	f: Frame
	library_frame(t, s, &f)
	app.playback_play_row(s, 0)
	s.settings.muted = true
	app.sleep_set(s, f.now, minutes = 15)
	library_frame(t, s, &f, dt = 15 * 60)
	testing.expect(t, s.playback.paused)
	testing.expect_value(t, s.playback.sleep.fade_from, 0)
	testing.expect_value(t, ui.wake_after(&s.ui), 0)
}

// End of track with the next track already preloaded: setting it drops
// the preload, the player isn't given another, and when the track ends
// the next one is current, paused at its start.
@(test)
sleep_end_of_track_holds_the_preload :: proc(t: ^testing.T) {
	s := sleep_player_state()
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	app.playback_play_row(s, 0)
	one := pb.cur.serial
	app.playback_observe(s, {serial = one, rate = 44100, state = .Playing, want_next = true})
	testing.expect(t, pb.next.resolved)
	app.playback_observe(s, {serial = one, rate = 44100, state = .Playing, next_serial = pb.next.serial})

	app.sleep_set(s, 1, end_of_track = true)
	testing.expect_value(t, pb.next.serial, u64(0))
	app.playback_observe(s, {serial = one, sample = 29 * 44100, rate = 44100, state = .Playing, want_next = true})
	testing.expect_value(t, pb.next.serial, u64(0))

	end := i64(app.FAKE_TONE_SECONDS * 44100)
	app.playback_observe(s, {serial = one, sample = end, total = end, rate = 44100, state = .Ended})
	testing.expect_value(t, pb.index, 1)
	testing.expect(t, pb.paused)
	testing.expect(t, !app.playback_playing(s))
	testing.expect_value(t, app.playback_position(s), 0.0)
	testing.expect(t, !app.sleep_on(pb))
	testing.expect_value(t, s.library.status, app.Status.Slept)
	// Play goes on from there.
	app.playback_set_paused(s, false)
	testing.expect_value(t, pb.index, 1)
	testing.expect(t, app.playback_playing(s))
}

// In a track's last seconds the decoder may already have put the next
// track's first frames in the ring. End of track pulls them back with a
// seek to where the current track is, then drops the next track. If the
// player still goes on to it, it pauses there at its start.
@(test)
sleep_end_of_track_pulls_back_the_next :: proc(t: ^testing.T) {
	s := sleep_player_state()
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	app.playback_play_row(s, 0)
	one := pb.cur.serial
	app.playback_observe(s, {serial = one, rate = 44100, state = .Playing, want_next = true})
	two := pb.next.serial
	// The decoder has moved on to it: the status no longer names it.
	app.playback_observe(s, {serial = one, sample = 28 * 44100, rate = 44100, state = .Playing})
	app.sleep_set(s, 1, end_of_track = true)
	testing.expect(t, pb.seek_id != 0, "no seek pulled the next track back")
	testing.expect_value(t, pb.next.serial, two)
	seek := pb.seek_id
	app.playback_observe(s, {serial = one, sample = 28 * 44100, rate = 44100, state = .Playing, seek_id = seek, next_serial = two})
	testing.expect_value(t, pb.next.serial, u64(0))

	// Again, but the player gets to it first.
	s2 := sleep_player_state()
	defer free(s2)
	defer app.playback_shutdown(s2)
	pb2 := &s2.playback
	app.playback_play_row(s2, 0)
	app.playback_observe(s2, {serial = pb2.cur.serial, rate = 44100, state = .Playing, want_next = true})
	two = pb2.next.serial
	pb2.sleep.end_of_track = true
	app.playback_observe(s2, {serial = two, sample = 441, rate = 44100, state = .Playing})
	testing.expect_value(t, pb2.index, 1)
	testing.expect(t, pb2.paused)
	testing.expect_value(t, app.playback_position(s2), 0.0)
	testing.expect(t, !app.sleep_on(pb2))
}

// End of track on the queue's last track: the queue ends as it would,
// and the timer clears.
@(test)
sleep_end_of_track_at_the_end_of_the_queue :: proc(t: ^testing.T) {
	s := sleep_player_state()
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	app.playback_play_row(s, 2)
	app.sleep_set(s, 1, end_of_track = true)
	end := i64(app.FAKE_TONE_SECONDS * 44100)
	app.playback_observe(s, {serial = pb.cur.serial, sample = end, total = end, rate = 44100, state = .Ended})
	testing.expect_value(t, pb.index, 2)
	testing.expect(t, !app.playback_playing(s))
	testing.expect(t, !app.sleep_on(pb))
	testing.expect_value(t, s.library.status, app.Status.Slept_At_End)
}

// Stopping playback, as signing out does, clears the timer.
@(test)
sleep_timer_cleared_by_stop_and_sign_out :: proc(t: ^testing.T) {
	s := sleep_player_state()
	defer free(s)
	defer app.playback_shutdown(s)
	app.playback_play_row(s, 0)
	app.sleep_set(s, 1, minutes = 15)
	app.playback_stop(s)
	testing.expect(t, !app.sleep_on(&s.playback))
	testing.expect_value(t, app.sleep_update(s, 2), 0)

	s2 := new(app.State)
	test_keychain(&s2.data)
	app.session_open(&s2.data)
	sign_in(s2)
	defer {
		app.data_shutdown(s2)
		test_state_free(s2)
		free(s2)
	}
	app.sleep_set(s2, 1, end_of_track = true)
	app.sign_out(s2, "")
	testing.expect(t, !app.sleep_on(&s2.playback))
	app.sleep_set(s2, 1, minutes = 60)
	app.sign_out(s2, "")
	testing.expect(t, !app.sleep_on(&s2.playback))
}

// The button and its menu work from the keyboard: Enter on the focused
// button opens the menu with its first item highlighted, the arrows move,
// and Enter picks.
@(test)
sleep_menu_from_the_keyboard :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := sleep_state()
	defer library_state_free(s)
	defer app.playback_shutdown(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	b := node_box(s, "Sleep timer")
	s.ui.focus = b.key
	s.ui.focus_visible = true
	library_frame(t, s, &f, key(.Return))
	library_frame(t, s, &f)
	testing.expect(t, ui.menu_is_open("sleep_menu"))
	library_frame(t, s, &f, key(.Down))
	library_frame(t, s, &f, key(.Return))
	testing.expect_value(t, s.playback.sleep.minutes, 15)
	testing.expect(t, math.abs(s.playback.sleep.at - (f.now + 15 * 60)) < 1e-9)
	testing.expect(t, !ui.menu_is_open("sleep_menu"))
}
