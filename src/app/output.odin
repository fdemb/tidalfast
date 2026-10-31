package app

// The player bar's output button and its signal path menu. The button is a
// speaker and the name of the device the sound goes to, borderless like the
// bar's other controls. The speaker's colour is the path: cyan when the
// device gets the track's samples unchanged, the error colour when
// bit-perfect output was asked for and something converts them, grey with
// bit-perfect output off, since then the conversion is the user's choice.
// The menu shows each step from the track to the device with dots in the
// same colours, then what reaches the device and the bit-perfect switch.
//
// The track's own format goes on a line under its artist in the player bar
// (track_format), so the button only speaks for the output. Clicking that
// line opens the same menu.

import "core:fmt"

import "../audio"
import "../render"
import "../text"
import "../ui"

OUTPUT_MAX_W :: 180
OUTPUT_PAD :: 10
OUTPUT_ICON :: 16
OUTPUT_ICON_GAP :: 6
OUTPUT_DOT :: 6
OUTPUT_MENU_W :: 380

// Path_Mark is what a step does to the samples.
Path_Mark :: enum u8 {
	None, // nothing has played, or bit-perfect output is off: grey
	Exact, // passes them on unchanged
	Converted, // changes them although bit-perfect output is on
	Expected, // changes them, with bit-perfect output off
}

Path_Step :: struct {
	name:   string,
	detail: string,
	mark:   Path_Mark,
}

mark_color :: proc(m: Path_Mark) -> render.Color {
	switch m {
	case .Exact:
		return ACCENT
	case .Converted:
		return PLAYBACK_ERROR
	case .Expected, .None:
	}
	return DIM
}

output_on :: proc(s: ^State) -> bool {
	return audio.BIT_PERFECT && s.settings.bit_perfect
}

// output_label is the button's text, the device's name, and the speaker's
// colour.
output_label :: proc(s: ^State) -> (string, Path_Mark) {
	dev := &s.playback.output_seen
	name := audio.device_info_name(dev)
	switch {
	case name == "":
		return "Output", .None
	case !output_on(s):
		return name, .None
	case dev.bit_perfect:
		return name, .Exact
	}
	return name, .Converted
}

// output_width is how wide the button is for its label.
output_width :: proc(s: ^State) -> f32 {
	label, _ := output_label(s)
	return min(ui.text_width(.Medium, 12, label) + OUTPUT_ICON + OUTPUT_ICON_GAP + 2 * OUTPUT_PAD, OUTPUT_MAX_W)
}

// track_format is the playing track's format, such as FLAC, 24-bit, 96 kHz,
// "" while nothing plays. TIDAL's lossless streams are all FLAC; the fake
// data's tones have no codec.
track_format :: proc(s: ^State) -> string {
	pb := &s.playback
	st := &pb.status
	if st.serial == 0 || st.rate == 0 || st.bits == 0 {
		return ""
	}
	codec := "" if pb.fake else "FLAC, "
	return fmt.tprintf("%s%d-bit, %s kHz", codec, st.bits, audio.khz_text(st.rate))
}

// signal_path is each step from the track to the device.
signal_path :: proc(s: ^State) -> [4]Path_Step {
	pb := &s.playback
	st := &pb.status
	dev := &pb.output_seen
	on := output_on(s)
	open := dev.rate > 0
	changed := Path_Mark.Converted if on else .Expected
	path: [4]Path_Step

	path[0] = {"Track", "Nothing playing", .None}
	if format := track_format(s); format != "" {
		path[0] = {"Track", format, .Exact}
	}

	path[1] = {"TIDALfast", "No volume or ReplayGain", .Exact if open else .None}
	if !on {
		path[1] = {"TIDALfast", "Applies volume and ReplayGain", .Expected if open else .None}
	}

	path[2] = {audio.MIXER_NAME, "Not open yet", .None}
	switch {
	case dev.bit_perfect:
		path[2].detail, path[2].mark = "Direct, no conversion", .Exact
	case open && dev.bits == 0:
		path[2].detail, path[2].mark = "Converted and mixed", changed
	case open && st.rate > 0 && dev.rate != st.rate:
		path[2].detail, path[2].mark = fmt.tprintf("Resampled to %s kHz and mixed", audio.khz_text(dev.rate)), changed
	case open:
		path[2].detail, path[2].mark = "Mixed with other apps", changed
	}

	path[3] = {"Device", "", .None}
	if open {
		path[3].name = audio.device_info_name(dev)
		path[3].mark = .Exact if dev.bit_perfect else changed
		switch {
		case dev.bits == 0:
			path[3].detail = fmt.tprintf("%s kHz", audio.khz_text(dev.rate))
		case dev.float:
			path[3].detail = fmt.tprintf("%d-bit float, %s kHz", dev.bits, audio.khz_text(dev.rate))
		case:
			path[3].detail = fmt.tprintf("%d-bit integer, %s kHz", dev.bits, audio.khz_text(dev.rate))
		}
	}
	return path
}

// output_description says what reaches the device, for the menu's last
// line and the button's tooltip.
output_description :: proc(s: ^State) -> string {
	dev := &s.playback.output_seen
	switch {
	case !output_on(s):
		return "Bit-perfect output is off"
	case dev.rate == 0:
		return "Bit-perfect output is on"
	case dev.bit_perfect:
		return fmt.tprintf("Bit-perfect, %s kHz", audio.khz_text(dev.rate))
	case dev.reason_len > 0:
		return fmt.tprintf("Not bit-perfect: %s", audio.device_reason(dev))
	}
	return "Not bit-perfect"
}

// draw_output_button is the player bar's button for the output menu,
// width wide (output_width).
draw_output_button :: proc(s: ^State, width: f32) {
	label, mark := output_label(s)
	ui.column("", {}, ui.px(width), ui.fill())
	ui.spacer(ui.fill())
	ui.set_next_background({})
	ui.set_next_hover_color({1, 1, 1, 0.08})
	ui.set_next_radius(14)
	b: ^ui.Box
	{
		b = ui.row("###output", {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.fill(), ui.px(28))
		ui.accessible(b, .Button, label, output_description(s))
		ui.spacer(ui.px(OUTPUT_PAD))
		ui.text_style(.Icon, OUTPUT_ICON, mark_color(mark) if mark != .None else SECONDARY)
		ui.text_pad(0)
		ui.label(text.ICON_SPEAKER_HIFI, ui.px(OUTPUT_ICON), ui.fill())
		ui.spacer(ui.px(OUTPUT_ICON_GAP))
		ui.text_style(.Medium, 12, SECONDARY)
		ui.label(label, ui.fill(), ui.fill())
		ui.spacer(ui.px(OUTPUT_PAD))
	}
	sig := ui.signal(b)
	if sig.clicked {
		open_output_menu(b.rect.x + b.rect.w - OUTPUT_MENU_W, b.rect.y - 8)
	}
	ui.tooltip(sig, output_description(s))
	ui.spacer(ui.fill())

	if ui.menu("output_menu", OUTPUT_MENU_W) {
		draw_signal_path(s)
	}
}

// open_output_menu opens the signal path at x, y, or above y when it
// doesn't fit below, as at the bottom of the window.
open_output_menu :: proc(x, y: f32) {
	ui.open_menu("output_menu", {x, y})
}

// dot is a small filled circle, centred in a column as tall as its parent.
@(private = "file")
dot :: proc(color: render.Color) {
	ui.column("", {}, ui.px(OUTPUT_DOT), ui.fill())
	ui.spacer(ui.fill())
	ui.set_next_background(color)
	ui.set_next_radius(OUTPUT_DOT / 2)
	ui.box_make("", {.Draw_Background}, ui.px(OUTPUT_DOT), ui.px(OUTPUT_DOT))
	ui.spacer(ui.fill())
}

@(private = "file")
draw_signal_path :: proc(s: ^State) {
	ui.text_style(.Semibold, 11, DIM)
	ui.set_next_text_pad(14)
	ui.label("Signal path", ui.fill(), ui.px(24))
	for step in signal_path(s) {
		ui.row("", {}, ui.fill(), ui.px(24))
		ui.spacer(ui.px(14))
		if step.mark == .None {
			ui.spacer(ui.px(OUTPUT_DOT))
		} else {
			dot(mark_color(step.mark))
		}
		ui.spacer(ui.px(8))
		ui.text_pad(0)
		ui.text_style(.Medium, 12, TEXT)
		ui.label(step.name, ui.px(120), ui.fill())
		ui.spacer(ui.px(8))
		ui.text_style(.Regular, 12, SECONDARY)
		ui.label(step.detail, ui.fill(), ui.fill())
		ui.spacer(ui.px(14))
	}
	ui.menu_separator()
	_, mark := output_label(s)
	color := mark_color(mark) if mark != .None else SECONDARY
	ui.text_style(.Regular, 12, color)
	ui.set_next_text_pad(14)
	ui.label(output_description(s), ui.fill(), ui.px(26))
	when audio.BIT_PERFECT {
		ui.menu_separator()
		ui.text_style(.Regular, 13, TEXT)
		on := s.settings.bit_perfect
		if ui.menu_item(fmt.tprintf("%s Bit-perfect output###bit_perfect", "✓" if on else "   ")).clicked {
			st := s.settings
			st.bit_perfect = !on
			settings_set(s, st)
		}
	}
}
