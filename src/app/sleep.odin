package app

// The sleep timer: a button in the player bar whose menu pauses playback
// after 15, 30, 45 or 60 minutes, or at the end of the current track.
//
// A timed one keeps its deadline on the frame clock, the shell's monotonic
// clock, and asks for one frame at it (ui.wake_at), so it costs nothing
// while it waits. The frame that runs at or after the deadline fires it,
// however late that is. If something plays then, the volume fades out over
// SLEEP_FADE and the player pauses, as the pause button does; if nothing
// plays, it only clears. The remaining time is worked out when the button's
// tooltip or the menu is drawn, not counted down.
//
// End of track is playback_observe's: while it's set the next track isn't
// preloaded (sleep_hold_next), so the current one ends, and the queue moves
// to the next track paused at its start.
//
// The timer isn't saved, and playback_stop clears it with the rest of
// Playback. Pausing by hand leaves it set.

import "core:fmt"
import "core:math"

import "../audio"
import "../text"
import "../ui"

SLEEP_MINUTES :: [4]int{15, 30, 45, 60}
SLEEP_FADE :: 3.0 // seconds the volume takes to fade out when a timed one fires
SLEEP_FADE_STEP :: 1.0 / 30 // between the fade's volume changes
SLEEP_MENU_W :: 220

Sleep_Timer :: struct {
	minutes:      int, // the choice for a timed one, 0 for none
	at:           f64, // when a timed one fires, on the frame clock; 0 for none
	end_of_track: bool,
	fade_from:    f64, // the fade-out began then; 0 for none
	fade_serial:  u64, // the track the fade was on
	restore:      bool, // the fade left the player's volume down: put it back once the pause has taken
}

// sleep_on says whether a sleep timer is set.
sleep_on :: proc(pb: ^Playback) -> bool {
	return pb.sleep.at != 0 || pb.sleep.end_of_track
}

// sleep_set sets the timer at now for minutes, or for the end of the
// current track, or with neither turns it off.
sleep_set :: proc(s: ^State, now: f64, minutes := 0, end_of_track := false) {
	pb := &s.playback
	pb.sleep.minutes = minutes
	pb.sleep.at = now + f64(minutes) * 60 if minutes > 0 else 0
	pb.sleep.end_of_track = end_of_track && minutes == 0
	// Turned off or changed during a fade: the fade stops too.
	if pb.sleep.fade_from != 0 {
		pb.sleep.fade_from = 0
		pb.sleep.restore = true
	}
	sleep_hold_next(s)
}

// sleep_set_seconds sets a timed timer that fires seconds from now, for
// TIDALFAST_SLEEP_TEST. No menu choice is marked for it.
sleep_set_seconds :: proc(s: ^State, now, seconds: f64) {
	pb := &s.playback
	pb.sleep = {at = now + seconds, restore = pb.sleep.restore, fade_serial = pb.sleep.fade_serial}
}

// sleep_fired clears the timer once it has done its work, and says so in
// the status bar.
sleep_fired :: proc(s: ^State, status: Status) {
	pb := &s.playback
	pb.sleep.minutes, pb.sleep.at, pb.sleep.end_of_track = 0, 0, false
	set_status(s, status, -1)
}

// sleep_left is how many whole minutes a timed timer has left, rounded up,
// so it shows 1 until it fires; 0 with no timed timer.
sleep_left :: proc(pb: ^Playback, now: f64) -> int {
	if pb.sleep.at == 0 {
		return 0
	}
	return max(int(math.ceil((pb.sleep.at - now) / 60)), 1)
}

// sleep_update fires a timed timer that is due and runs its fade. It
// returns when it next wants a frame, 0 for never: the deadline while
// waiting, the next step while fading.
sleep_update :: proc(s: ^State, now: f64) -> f64 {
	pb := &s.playback
	sl := &pb.sleep
	if pb.sleep_test > 0 {
		sleep_set_seconds(s, now, pb.sleep_test)
		pb.sleep_test = 0
	}
	// The volume goes back once the faded track is no longer heard: the
	// pause or a stop has reached the player, another track plays, or
	// play was pressed again.
	if sl.restore && (pb.status.state != .Playing || pb.status.serial != sl.fade_serial || !pb.paused && pb.index >= 0) {
		sl.restore = false
		if pb.player != nil {
			audio.set_volume(pb.player, pb.volume_sent)
		}
	}
	if sl.fade_from != 0 {
		t := (now - sl.fade_from) / SLEEP_FADE
		if t < 1 && playback_playing(s) {
			audio.set_volume(pb.player, pb.volume_sent * f32(1 - t))
			return now + SLEEP_FADE_STEP
		}
		sl.fade_from = 0
		sl.restore = true
		if playback_playing(s) {
			playback_set_paused(s, true)
		}
	}
	if sl.at == 0 {
		return 0
	}
	if now < sl.at {
		return sl.at
	}
	if !playback_playing(s) {
		sl.minutes, sl.at = 0, 0
		return 0
	}
	sleep_fired(s, .Slept)
	// Bit-perfect output plays without the volume, so it can't fade.
	if pb.player == nil || output_on(s) || volume_heard(s.settings) == 0 {
		playback_set_paused(s, true)
		return 0
	}
	sl.fade_from = now
	sl.fade_serial = pb.cur.serial
	return now
}

// sleep_value is what the button says is left, for its accessible value
// and its tooltip.
sleep_value :: proc(pb: ^Playback, now: f64) -> string {
	switch {
	case pb.sleep.end_of_track:
		return "at the end of this track"
	case pb.sleep.at != 0:
		n := sleep_left(pb, now)
		return fmt.tprintf("%d minute%s left", n, "" if n == 1 else "s")
	}
	return "Off"
}

// draw_sleep_button is the player bar's moon, lit while a timer is set,
// and its menu.
draw_sleep_button :: proc(s: ^State) {
	pb := &s.playback
	now := s.ui.time
	on := sleep_on(pb)
	ui.column("", {.Center_Children}, ui.px(SPEAKER_SIZE), ui.fill())
	ui.text_style(.Icon, OUTPUT_ICON, ACCENT if on else SECONDARY)
	ui.text_align(.Center)
	ui.text_pad(0)
	ui.set_next_background({})
	ui.set_next_hover_color({1, 1, 1, 0.08})
	ui.set_next_radius(SPEAKER_SIZE / 2)
	b := ui.box_make("###sleep", {.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(SPEAKER_SIZE), ui.px(SPEAKER_SIZE))
	b.label = text.ICON_MOON
	value := sleep_value(pb, now)
	ui.accessible(b, .Button, "Sleep timer", value)
	sig := ui.signal(b)
	if sig.clicked {
		ui.open_menu("sleep_menu", {b.rect.x + b.rect.w - SLEEP_MENU_W, b.rect.y - 8})
	}
	ui.tooltip(sig, fmt.tprintf("Sleep timer, %s", value) if on else "Sleep timer")

	// The minutes left change in the tooltip or the open menu: one frame
	// at each minute's turn while either can show it.
	if n := sleep_left(pb, now); n > 1 && (sig.hovering || ui.menu_is_open("sleep_menu")) {
		ui.wake_at(pb.sleep.at - f64(n - 1) * 60)
	}
	if ui.menu("sleep_menu", SLEEP_MENU_W) {
		draw_sleep_menu(s, now)
	}
}

@(private = "file")
draw_sleep_menu :: proc(s: ^State, now: f64) {
	pb := &s.playback
	on := sleep_on(pb)
	ui.text_style(.Regular, 13, TEXT)
	label := fmt.tprintf("%s Off###sleep_off", "✓" if !on else "   ")
	name := "Off"
	switch {
	case pb.sleep.end_of_track:
		label, name = "Turn off (end of track)###sleep_off", "Turn off"
	case on:
		label, name = fmt.tprintf("Turn off (%d min left)###sleep_off", sleep_left(pb, now)), "Turn off"
	}
	if sleep_item(label, name, !on) {
		sleep_set(s, now)
	}
	for m in SLEEP_MINUTES {
		choice := "1 hour" if m == 60 else fmt.tprintf("%d minutes", m)
		chosen := pb.sleep.at != 0 && pb.sleep.minutes == m
		if sleep_item(fmt.tprintf("%s %s###sleep_%d", "✓" if chosen else "   ", choice, m), choice, chosen) {
			sleep_set(s, now, minutes = m)
		}
	}
	chosen := pb.sleep.end_of_track
	if sleep_item(fmt.tprintf("%s End of track###sleep_end", "✓" if chosen else "   "), "End of track", chosen) {
		sleep_set(s, now, end_of_track = true)
	}
}

// sleep_item is a menu item with name in the accessibility tree, without
// the mark its label starts with. It says whether it was clicked.
@(private = "file")
sleep_item :: proc(label, name: string, chosen: bool) -> bool {
	sig := ui.menu_item(label)
	ui.accessible(sig.box, .Menu_Item, name, selected = chosen)
	if sig.clicked {
		ui.data_changed()
	}
	return sig.clicked
}
