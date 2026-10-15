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
		key_code = u32(cmd),
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
