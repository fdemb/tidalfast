package tidal_tests

import "core:strings"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/platform"
import "../src/tidal"

// What the app last sent to Now Playing, copied as the shell would.
@(private = "file")
Seen_Now_Playing :: struct {
	calls:    int,
	title:    [64]u8,
	duration: f64,
	elapsed:  f64,
	state:    platform.Now_Playing_State,
}

@(private = "file")
seen: Seen_Now_Playing

@(private = "file")
record_now_playing :: proc "c" (np: ^platform.Now_Playing) {
	seen.calls += 1
	seen.title = {}
	if np.title != nil {
		t := string(np.title)
		copy(seen.title[:len(seen.title) - 1], t)
	}
	seen.duration, seen.elapsed, seen.state = np.duration, np.elapsed, np.state
}

@(private = "file")
seen_title :: proc() -> string {
	return strings.truncate_to_byte(string(seen.title[:]), 0)
}

@(private = "file")
no_redraw :: proc "c" () {}

@(private = "file")
media :: proc(s: ^app.State, cmd: platform.Media_Command, position: f32 = 0) {
	e := platform.Event {
		kind     = .Media,
		media    = cmd,
		dx       = position,
	}
	app.playback_update(s, {e})
}

// The shell turns each MPRemoteCommandCenter command into an Event_Media.
// This sends those events through the app's frame update, with the fake
// queue's tones playing on the silent null device, and checks what
// each one does to the queue, the player and Now Playing.
@(test)
media_commands :: proc(t: ^testing.T) {
	s := new(app.State)
	defer free(s)
	rows := []app.Row {
		{title = "One", artist = "A", album = "X", seconds = 30},
		{title = "Two", artist = "A", album = "X", seconds = 30},
		{title = "Three", artist = "A", album = "X", seconds = 30},
	}
	s.rows = rows
	s.data.fake = true
	s.library.selected = -1
	pb := &s.playback
	pb.index = -1
	pb.set_now_playing = record_now_playing
	pb.player = audio.create(no_redraw, 0, null_output = true)
	defer app.playback_shutdown(s)

	// Play with nothing loaded starts the first row.
	media(s, .Play)
	testing.expect_value(t, pb.index, 0)
	testing.expect(t, app.playback_playing(s))
	testing.expect_value(t, seen_title(), "One")
	testing.expect_value(t, seen.state, platform.Now_Playing_State.Playing)
	testing.expect_value(t, seen.duration, f64(app.FAKE_TONE_SECONDS))

	media(s, .Next)
	testing.expect_value(t, pb.index, 1)
	testing.expect_value(t, seen_title(), "Two")
	// Early in a track, previous goes back one.
	media(s, .Previous)
	testing.expect_value(t, pb.index, 0)

	// changePlaybackPosition: the position shows at once, before the audio.
	media(s, .Seek, 12)
	testing.expect_value(t, app.playback_position(s), 12.0)
	testing.expect(t, pb.seek_id != 0)
	testing.expect_value(t, seen.elapsed, 12.0)

	media(s, .Pause)
	testing.expect(t, !app.playback_playing(s))
	testing.expect_value(t, seen.state, platform.Now_Playing_State.Paused)
	media(s, .Toggle)
	testing.expect(t, app.playback_playing(s))
	testing.expect_value(t, seen.state, platform.Now_Playing_State.Playing)

	// The seek lands in the audio: the player's position moves to 12 s.
	deadline := time.tick_now()
	for pb.seek_id != 0 && time.tick_since(deadline) < 3 * time.Second {
		time.sleep(5 * time.Millisecond)
		app.playback_update(s, nil)
	}
	testing.expect_value(t, pb.seek_id, u32(0))
	testing.expect_value(t, pb.status.serial, pb.cur.serial)
	at := app.playback_position(s)
	testing.expectf(t, at >= 12 && at < 13, "the player reports %v s, not the seek target", at)

	// Past 3 s, previous restarts the track instead.
	media(s, .Previous)
	testing.expect_value(t, pb.index, 0)
	testing.expect_value(t, app.playback_position(s), 0.0)

	// Next stops at the end of the queue.
	media(s, .Next)
	media(s, .Next)
	media(s, .Next)
	testing.expect_value(t, pb.index, 2)
	testing.expect_value(t, seen_title(), "Three")
	media(s, .None)
	testing.expect_value(t, pb.index, 2)
}

// wait_until runs frames until done says so, for up to 3 s.
@(private = "file")
wait_until :: proc(s: ^app.State, done: proc(s: ^app.State) -> bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 3 * time.Second {
		app.playback_update(s, nil)
		if done(s) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

@(private = "file")
fake_player_state :: proc(rows: []app.Row) -> ^app.State {
	s := new(app.State)
	s.rows = rows
	s.data.fake = true
	s.library.selected = -1
	s.playback.index = -1
	s.playback.player = audio.create(no_redraw, 0, null_output = true)
	return s
}

@(private = "file")
toggle_no_status :: proc(s: ^app.State) {
	app.playback_media(s, {{kind = .Media, media = .Toggle}})
}

// List A plays with its row 1 preloaded. Double-clicking row 1 of list B
// must play B's row 1, not the bytes preloaded for A's.
@(test)
new_queue_doesnt_reuse_the_preload :: proc(t: ^testing.T) {
	list_a := []app.Row{{title = "A1", seconds = 30}, {title = "A2", seconds = 30}, {title = "A3", seconds = 30}}
	list_b := []app.Row{{title = "B1", seconds = 30}, {title = "B2", seconds = 30}, {title = "B3", seconds = 30}}
	s := fake_player_state(list_a)
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback

	app.playback_play_row(s, 0)
	app.playback_observe(s, {serial = pb.cur.serial, rate = 44100, state = .Playing, want_next = true})
	testing.expect(t, pb.next.resolved)
	testing.expect_value(t, pb.next.item, 1)
	preloaded := pb.next.serial

	s.rows = list_b
	s.library.playlist = 1
	app.playback_play_row(s, 1)
	testing.expect(t, pb.cur.serial != preloaded, "B's row 1 took the source preloaded for A's")
	testing.expect_value(t, app.playback_item(s).title, "B2")
	testing.expect(t, pb.cur.resolved)
}

// The player bar's play button and the remote's toggle start playback when
// nothing is loaded, and start the queue again once it has played out.
@(test)
toggle_plays_from_idle_and_the_end :: proc(t: ^testing.T) {
	rows := []app.Row{{title = "One", seconds = 30}, {title = "Two", seconds = 30}}
	s := fake_player_state(rows)
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback

	toggle_no_status(s)
	testing.expect_value(t, pb.index, 0)
	testing.expect(t, app.playback_playing(s))
	toggle_no_status(s)
	testing.expect(t, !app.playback_playing(s))
	toggle_no_status(s)
	testing.expect(t, app.playback_playing(s))

	// The last entry of the queue, played to its end.
	app.playback_play_row(s, 1)
	last := pb.cur.serial
	end := i64(app.FAKE_TONE_SECONDS * 44100)
	app.playback_observe(s, {serial = last, sample = end, total = end, rate = 44100, state = .Ended})
	testing.expect_value(t, pb.index, 1)
	testing.expect(t, !app.playback_playing(s))

	toggle_no_status(s)
	testing.expect_value(t, pb.index, 0)
	testing.expect(t, app.playback_playing(s))
	testing.expect(t, pb.cur.serial != last && pb.cur.resolved, "the first track isn't sent to the player again")
}

// A seek sent for track one after the audio moved on to the preloaded
// track two, before the app saw that. The decoder drops it, and the
// position must follow track two instead of staying on the target.
@(test)
advance_drops_a_pending_seek :: proc(t: ^testing.T) {
	rows := []app.Row{{title = "One", seconds = 30}, {title = "Two", seconds = 30}}
	s := fake_player_state(rows)
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback

	app.playback_play_row(s, 0)
	one := pb.cur.serial
	app.playback_observe(s, {serial = one, sample = 29 * 44100, rate = 44100, state = .Playing, want_next = true})
	testing.expect(t, pb.next.resolved)
	two := pb.next.serial
	testing.expect_value(t, pb.index, 0)
	app.playback_seek(s, 12)
	testing.expect(t, pb.seek_id != 0)

	app.playback_observe(s, {serial = two, sample = 4410, rate = 44100, state = .Playing})
	testing.expect_value(t, pb.index, 1)
	testing.expect_value(t, pb.cur.serial, two)
	app.playback_observe(s, {serial = two, sample = 8820, rate = 44100, state = .Playing})
	at := app.playback_position(s)
	testing.expectf(t, at < 5, "track two shows %v s, the seek target meant for track one", at)
	testing.expect_value(t, pb.seek_id, u32(0))
}

// A queue restored at sign-in, as from its file, with no stream resolved
// and no workers running.
@(private = "file")
restored_player_state :: proc(rows: []app.Row, sample, rate: i64) -> ^app.State {
	s := fake_player_state(nil)
	s.data.fake = false
	app.playback_restore(s, {header = {index = 0, sample = sample, rate = rate}, rows = rows})
	return s
}

// The restored track's stream fails. The queue moves on to the next one,
// and that one must stay paused too, rather than play by itself.
@(test)
restored_queue_stays_paused_past_a_failure :: proc(t: ^testing.T) {
	rows := []app.Row{{title = "One", seconds = 300, id = 101}, {title = "Two", seconds = 300, id = 102}}
	s := restored_player_state(rows, 100 * 44100, 44100)
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	testing.expect_value(t, pb.index, 0)
	testing.expect(t, !app.playback_playing(s))

	res := app.Result {
		job = {payload = app.Stream_Job{serial = pb.cur.serial}},
		err = .Stream_Not_Available,
	}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, pb.index, 1)
	testing.expect(t, !app.playback_playing(s), "the next track plays without the user")
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.serial == s.playback.cur.serial}))
	testing.expect(t, s.playback.status.state != .Playing, "the player plays the next track's placeholder")
}

// A seek before the restored track's stream resolves moves the position
// shown, and the one saved, from where the file had it.
@(test)
seek_before_resolve_moves_the_position :: proc(t: ^testing.T) {
	rows := []app.Row{{title = "One", seconds = 300, id = 101}}
	s := restored_player_state(rows, 100 * 44100, 44100)
	defer free(s)
	defer app.playback_shutdown(s)
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.serial == s.playback.cur.serial}))

	app.playback_seek(s, 10)
	time.sleep(100 * time.Millisecond)
	app.playback_update(s, nil)
	at := app.playback_position(s)
	testing.expectf(t, at >= 10 && at < 11, "after a seek to 10 s the position is %v s", at)
}

// The current track's stream fails in a way that stops the queue: a lossy
// stream, or the last track. The player bar shows paused, and the player
// must stop too, not go on playing the placeholder's silence.
@(test)
failed_track_stops_the_player :: proc(t: ^testing.T) {
	Case :: struct {
		name: string,
		rows: []app.Row,
		err:  tidal.Error_Kind,
	}
	cases := []Case {
		{"lossy", {{title = "One", seconds = 300, id = 101}, {title = "Two", seconds = 300, id = 102}}, .Lossy_Stream},
		{"last track", {{title = "One", seconds = 300, id = 101}}, .Stream_Not_Available},
	}
	for c in cases {
		s := restored_player_state(c.rows, 0, 44100)
		pb := &s.playback
		app.playback_set_paused(s, false)
		testing.expect(t, app.playback_playing(s), c.name)
		testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.serial == s.playback.cur.serial && s.playback.status.state == .Playing}), c.name)

		res := app.Result {
			job = {payload = app.Stream_Job{serial = pb.cur.serial}},
			err = c.err,
		}
		app.handle_result(s, &res, 0)
		testing.expect(t, pb.paused, c.name)
		testing.expectf(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.state != .Playing}), "%s: the player still plays", c.name)
		app.playback_shutdown(s)
		free(s)
	}
}

@(private = "file")
controls_seen: platform.Player_Controls
@(private = "file")
controls_calls: int

@(private = "file")
record_controls :: proc "c" (c: ^platform.Player_Controls) {
	controls_seen = c^
	controls_calls += 1
}

// MPRIS sets the volume, shuffle and repeat with media commands. The app
// takes them as the player bar's controls would, saves the volume as the
// slider's release does, ignores values out of range, and tells the shell
// each change once.
@(test)
media_sets_the_controls :: proc(t: ^testing.T) {
	s := fake_player_state({{title = "One", seconds = 30}, {title = "Two", seconds = 30}})
	defer free(s)
	defer app.playback_shutdown(s)
	controls_calls = 0
	s.playback.set_controls = record_controls
	s.settings.volume = 1
	s.volume_before_override = 0.9 // TIDALFAST_VOLUME, which a save replaces

	media(s, .None)
	testing.expect_value(t, controls_calls, 1)
	testing.expect_value(t, controls_seen, platform.Player_Controls{volume = 1, shuffle = false, repeat = .Off})
	media(s, .None)
	testing.expect_value(t, controls_calls, 1)

	media(s, .Volume, 0.25)
	testing.expect_value(t, s.settings.volume, 0.25)
	testing.expect(t, s.volume_before_override == nil, "the volume wasn't saved")
	media(s, .Volume, -2)
	testing.expect_value(t, s.settings.volume, 0)
	media(s, .Volume, 3)
	testing.expect_value(t, s.settings.volume, 1)
	nan := f32(0)
	media(s, .Volume, nan / nan)
	testing.expect_value(t, s.settings.volume, 1)

	media(s, .Shuffle, 1)
	testing.expect(t, s.settings.shuffle)
	media(s, .Repeat, f32(platform.Player_Repeat.One))
	testing.expect_value(t, s.settings.repeat, audio.Repeat.One)
	media(s, .Repeat, f32(platform.Player_Repeat.All))
	testing.expect_value(t, s.settings.repeat, audio.Repeat.All)
	media(s, .Repeat, 3)
	media(s, .Repeat, -1)
	testing.expect_value(t, s.settings.repeat, audio.Repeat.All)
	testing.expect_value(t, controls_seen, platform.Player_Controls{volume = 1, shuffle = true, repeat = .All})
	media(s, .Shuffle, 0)
	testing.expect(t, !s.settings.shuffle)
	testing.expect_value(t, controls_seen.shuffle, false)
}
