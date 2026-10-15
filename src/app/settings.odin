package app

// Output settings: bit-perfect output and hog mode. They live in a small
// JSON file, ~/Library/Application Support/tidalfast/settings.json, or
// wherever TIDALFAST_SETTINGS points. A worker writes it, so a click never
// waits on the disk.
//
// The player bar has a button for them that opens a menu. In bit-perfect
// mode the button shows what the device plays, such as 24/96.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../audio"
import "../render"
import "../ui"

Settings :: struct {
	bit_perfect: bool,
	hog:         bool,
}

// settings_default_path is TIDALFAST_SETTINGS, or the file under
// ~/Library/Application Support. Allocated with allocator.
settings_default_path :: proc(allocator: runtime.Allocator) -> string {
	if p := os.get_env("TIDALFAST_SETTINGS", context.temp_allocator); p != "" {
		return strings.clone(p, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return strings.concatenate({home, "/Library/Application Support/tidalfast/settings.json"}, allocator)
}

// settings_load reads the file at path. A missing or broken file gives
// the defaults, with ok false.
settings_load :: proc(path: string) -> (st: Settings, ok: bool) {
	if path == "" {
		return {}, false
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	if json.unmarshal(data, &st, allocator = context.temp_allocator) != nil {
		fmt.eprintfln("app: %s isn't valid settings, using the defaults", path)
		return {}, false
	}
	return st, true
}

// settings_save writes st to path through a temp file renamed over it, so
// a crash leaves the old file or the new one. Makes the directory.
settings_save :: proc(path: string, st: Settings) -> bool {
	if path == "" {
		return false
	}
	data, merr := json.marshal(st, {pretty = true}, context.temp_allocator)
	if merr != nil {
		return false
	}
	os.make_directory_all(filepath.dir(path))
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, data) != nil {
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

settings_encode :: proc(st: Settings) -> u64 {
	return u64(st.bit_perfect) | u64(st.hog) << 1
}

settings_decode :: proc(v: u64) -> Settings {
	return {bit_perfect = v & 1 != 0, hog = v & 2 != 0}
}

// playback_set_settings applies st to the player and saves it.
playback_set_settings :: proc(s: ^State, st: Settings) {
	pb := &s.playback
	pb.settings = st
	if pb.player != nil {
		audio.set_output(pb.player, output_of(st))
	}
	d := &s.data
	if d.running {
		push_job(d, {kind = .Save_Settings, key = settings_encode(st)})
	} else if !settings_save(pb.settings_path, st) {
		// No workers: the fake data, or tests.
		fmt.eprintfln("app: couldn't save the settings to %s", pb.settings_path)
	}
}

output_of :: proc(st: Settings) -> audio.Output {
	return {bit_perfect = st.bit_perfect, hog = st.bit_perfect && st.hog}
}

// draw_output_button is the player bar's button for the output menu. In
// bit-perfect mode it shows the format reaching the device.
draw_output_button :: proc(s: ^State) {
	pb := &s.playback
	dev := pb.status.device
	label := "Output"
	color := SECONDARY
	if pb.settings.bit_perfect {
		label = "Bit-perfect"
		if dev.bit_perfect && pb.status.bits > 0 {
			label = fmt.tprintf("%d/%s", pb.status.bits, khz(dev.rate))
			color = ACCENT
		}
	}
	output_pill(s, label, color)
	ui.spacer(ui.px(12))

	if ui.menu("output_menu", 250) {
		ui.text_style(.Regular, 13, TEXT)
		st := pb.settings
		if ui.menu_item(fmt.tprintf("%s Bit-perfect output###bit_perfect", "✓" if st.bit_perfect else "   ")).clicked {
			st.bit_perfect = !st.bit_perfect
			playback_set_settings(s, st)
			ui.close_menu()
		}
		if st.bit_perfect {
			if ui.menu_item(fmt.tprintf("%s Hog mode###hog", "✓" if st.hog else "   ")).clicked {
				st.hog = !st.hog
				playback_set_settings(s, st)
				ui.close_menu()
			}
		}
		ui.menu_separator()
		ui.text_style(.Regular, 11, DIM)
		note := ui.label(output_description(s), ui.fill(), ui.px(26))
		note.text_pad = 14
	}
}

// output_pill is the button, centred in a column as tall as the bar.
@(private = "file")
output_pill :: proc(s: ^State, label: string, color: render.Color) {
	ui.column("", {}, ui.px(78), ui.fill())
	ui.spacer(ui.fill())
	ui.text_style(.Semibold, 11, color)
	b := ui.box_make(fmt.tprintf("%s###output", label), {.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects, .Draw_Active_Effects, .Draw_Text}, ui.fill(), ui.px(24))
	b.text_align = .Center
	b.background = {}
	b.border_color = color
	b.hover_color = {1, 1, 1, 0.08}
	b.radius = 12
	sig := ui.signal(b)
	if sig.clicked {
		ui.open_menu("output_menu", {b.rect.x, b.rect.y - 8})
	}
	ui.tooltip(sig, output_description(s))
	ui.spacer(ui.fill())
}

// output_description says what reaches the device.
output_description :: proc(s: ^State) -> string {
	pb := &s.playback
	dev := pb.status.device
	switch {
	case !pb.settings.bit_perfect:
		return "The system mixer plays it, with ReplayGain and the volume slider"
	case dev.rate == 0:
		return "Bit-perfect: volume and ReplayGain are off"
	case dev.bit_perfect:
		hog := ", hog mode" if dev.hogged else ""
		return fmt.tprintf("Bit-perfect at %s kHz%s, no volume or ReplayGain", khz(dev.rate), hog)
	}
	return fmt.tprintf("The device can't run at %d Hz, so the system converts it", pb.status.rate)
}

@(private = "file")
khz :: proc(rate: int) -> string {
	if rate % 1000 == 0 {
		return fmt.tprintf("%d", rate / 1000)
	}
	return fmt.tprintf("%.1f", f64(rate) / 1000)
}
