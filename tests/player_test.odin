package tidal_tests

import "core:strings"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/platform"

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
// queue's tones playing on miniaudio's silent null device, and checks what
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
	// The fake tones are 30 s, so the player asks for the next one at once.
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.next.resolved}))
	testing.expect_value(t, pb.next.item, 1)
	preloaded := pb.next.serial

	s.rows = list_b
	s.library.playlist = 1
	app.playback_play_row(s, 1)
	testing.expect(t, pb.cur.serial != preloaded, "B's row 1 took the source preloaded for A's")
	testing.expect_value(t, app.playback_item(s).title, "B2")
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.serial == s.playback.cur.serial}))
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

	media(s, .Toggle)
	testing.expect_value(t, pb.index, 0)
	testing.expect(t, app.playback_playing(s))
	media(s, .Toggle)
	testing.expect(t, !app.playback_playing(s))
	media(s, .Toggle)
	testing.expect(t, app.playback_playing(s))

	// The last entry of the queue, played to its end.
	app.playback_play_row(s, 1)
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.serial == s.playback.cur.serial}))
	app.playback_seek(s, app.FAKE_TONE_SECONDS - 0.05)
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.state == .Ended}))
	testing.expect(t, !app.playback_playing(s))

	media(s, .Toggle)
	testing.expect_value(t, pb.index, 0)
	testing.expect(t, app.playback_playing(s))
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.serial == s.playback.cur.serial && s.playback.status.state == .Playing}))
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
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.next.resolved}))
	app.playback_seek(s, app.FAKE_TONE_SECONDS - 0.1)
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.seek_id == 0}))
	// Wait for track two without running a frame, so the app still thinks
	// track one plays.
	start := time.tick_now()
	for audio.status(pb.player).serial != pb.next.serial && time.tick_since(start) < 3 * time.Second {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, pb.index, 0)
	app.playback_seek(s, 12)

	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.index == 1 && s.playback.status.serial == s.playback.cur.serial}))
	time.sleep(100 * time.Millisecond)
	app.playback_update(s, nil)
	at := app.playback_position(s)
	testing.expectf(t, at < 5, "track two shows %v s, the seek target meant for track one", at)
	testing.expect_value(t, pb.seek_id, u32(0))
}

// A hot reload while a seek is pending resumes at the seek's target, and
// the position goes back to following the audio.
@(test)
reload_keeps_a_pending_seek :: proc(t: ^testing.T) {
	rows := []app.Row{{title = "One", seconds = 30}, {title = "Two", seconds = 30}}
	s := fake_player_state(rows)
	defer free(s)
	defer app.playback_shutdown(s)
	pb := &s.playback
	pb.null_output = true
	pb.window = audio.STREAM_WINDOW

	app.playback_play_row(s, 0)
	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.status.serial == s.playback.cur.serial}))
	app.playback_seek(s, 20)
	app.playback_unload(s)
	shell := platform.Shell {
		request_redraw = no_redraw,
	}
	app.playback_reload(s, &shell)

	testing.expect(t, wait_until(s, proc(s: ^app.State) -> bool {return s.playback.seek_id == 0 && s.playback.status.serial == s.playback.cur.serial}))
	at := app.playback_position(s)
	testing.expectf(t, at >= 20 && at < 21, "after the reload the player is at %v s, not the seek target", at)
	time.sleep(300 * time.Millisecond)
	app.playback_update(s, nil)
	later := app.playback_position(s)
	testing.expectf(t, later > at, "the position stays at %v s", later)
}
