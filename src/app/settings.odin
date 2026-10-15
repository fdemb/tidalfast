package app

// Settings: bit-perfect output, hog mode and how lists show their
// scrollbars. They live in a small JSON file, ~/Library/Application Support/tidalfast/settings.json, or
// wherever TIDALFAST_SETTINGS points. A worker writes it, so a click never
// waits on the disk. Saves go one at a time and only the newest settings
// are written (settings_queue).
//
// While bit-perfect output has a device switched to another rate, the file
// also says which device and what it had. If the app dies before it puts
// the device back, the next start does (playback_start).
//
// The player bar has a button for the output settings that opens a menu.
// In bit-perfect mode the button shows what the device plays, such as
// 24/96. The sidebar has one for the rest.

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "../audio"
import "../render"
import "../ui"

Settings :: struct {
	bit_perfect: bool,
	hog:         bool,
	device:      audio.Device_Change, // rate 0 when no device is changed
	scrollbars:  ui.Scrollbars,
}

// Settings_File is Settings as the JSON in the file.
@(private = "file")
Settings_File :: struct {
	bit_perfect:   bool,
	hog:           bool,
	scrollbars:    ui.Scrollbars,
	device_change: Maybe(Device_Change_File) `json:"device_change,omitempty"`,
}

@(private = "file")
Device_Change_File :: struct {
	uid:         string,
	orig_rate:   f64,
	orig_format: audio.Stream_Description,
	rate:        f64,
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
	if st, ok = settings_decode_json(data); !ok {
		log.warnf("app: %s isn't valid settings, using the defaults", path)
	}
	return
}

// settings_decode_json reads the file's JSON.
settings_decode_json :: proc(data: []u8) -> (st: Settings, ok: bool) {
	f: Settings_File
	if json.unmarshal(data, &f, allocator = context.temp_allocator) != nil {
		return {}, false
	}
	st = {bit_perfect = f.bit_perfect, hog = f.hog, scrollbars = f.scrollbars}
	if c, has := f.device_change.?; has && c.rate != 0 && len(c.uid) <= len(st.device.uid) {
		st.device = {orig_rate = c.orig_rate, orig_format = c.orig_format, rate = c.rate}
		st.device.uid_len = copy(st.device.uid[:], c.uid)
	}
	return st, true
}

// settings_save writes st to path through a temp file of its own, synced
// and renamed over it, so a crash leaves the old file or the new one, and
// another process saving at the same time can't mix its bytes in. Makes
// the directory. Use settings_queue from the app, which keeps saves in
// order.
settings_save :: proc(path: string, st: Settings) -> bool {
	if path == "" {
		return false
	}
	f := Settings_File {
		bit_perfect = st.bit_perfect,
		hog         = st.hog,
		scrollbars  = st.scrollbars,
	}
	if st.device.rate != 0 {
		c := st.device
		f.device_change = Device_Change_File{audio.device_change_uid(&c), c.orig_rate, c.orig_format, c.rate}
	}
	data, merr := json.marshal(f, {pretty = true, use_enum_names = true}, context.temp_allocator)
	if merr != nil {
		return false
	}
	os.make_directory_all(filepath.dir(path))
	key: u64
	crypto.rand_bytes(mem.ptr_to_bytes(&key))
	tmp := fmt.tprintf("%s.tmp-%x", path, key)
	file, oerr := os.open(tmp, os.O_WRONLY | os.O_CREATE | os.O_EXCL, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	if oerr != nil {
		return false
	}
	_, werr := os.write(file, data)
	if werr == nil {
		werr = os.sync(file)
	}
	if cerr := os.close(file); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.rename(tmp, path)
	}
	if werr != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// settings_queue makes st the newest settings to save and has a worker
// save them, or saves them now when there are no workers or now is set.
settings_queue :: proc(d: ^Data, st: Settings, now := false) {
	sync.lock(&d.settings_mutex)
	d.settings_latest = st
	d.settings_gen += 1
	sync.unlock(&d.settings_mutex)
	if d.running && !now {
		push_job(d, {kind = .Save_Settings})
	} else if !settings_flush(d) {
		log.errorf("app: couldn't save the settings to %s", d.settings_path)
	}
}

// settings_flush writes the newest settings if the file doesn't have them
// yet. One write at a time: a second caller waits for the first and then
// writes only if there's something newer, so older settings never land
// after newer ones and a burst of changes makes few writes. False if the
// write failed.
settings_flush :: proc(d: ^Data) -> bool {
	sync.guard(&d.settings_write)
	sync.lock(&d.settings_mutex)
	st, gen := d.settings_latest, d.settings_gen
	sync.unlock(&d.settings_mutex)
	if gen == d.settings_written {
		return true
	}
	if !settings_save(d.settings_path, st) {
		return false
	}
	d.settings_written = gen
	return true
}

// playback_set_settings applies st to the player and saves it.
playback_set_settings :: proc(s: ^State, st: Settings) {
	pb := &s.playback
	pb.settings = st
	if pb.player != nil {
		audio.set_output(pb.player, output_of(st))
	}
	settings_queue(&s.data, st)
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
	ui.spacer(ui.px(OUTPUT_GAP))

	if ui.menu("output_menu", 300) {
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
	ui.column("", {}, ui.px(OUTPUT_W), ui.fill())
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
		return "System mixer"
	case dev.rate == 0:
		return "Bit-perfect"
	case dev.bit_perfect:
		hog := ", hog mode" if dev.hogged else ""
		return fmt.tprintf("Bit-perfect, %s kHz%s", khz(dev.rate), hog)
	case dev.reason_len > 0:
		return fmt.tprintf("Not bit-perfect: %s", audio.device_reason(&dev))
	}
	return "Not bit-perfect"
}

// draw_settings_button is the sidebar's button for the settings menu.
draw_settings_button :: proc(s: ^State) {
	ui.text_style(.Regular, 12, SECONDARY)
	b := ui.box_make("Settings###settings", {.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.text_size(), ui.px(26))
	b.text_pad = 10
	b.radius = 6
	ui.accessible(b, .Button, "Settings")
	if ui.signal(b).clicked {
		ui.open_menu("settings_menu", {b.rect.x, b.rect.y + b.rect.h + 4})
	}

	if ui.menu("settings_menu") {
		pb := &s.playback
		ui.text_style(.Regular, 11, DIM)
		heading := ui.label("Scrollbars", ui.fill(), ui.px(24))
		heading.text_pad = 14
		ui.text_style(.Regular, 13, TEXT)
		for mode in ui.Scrollbars {
			on := pb.settings.scrollbars == mode
			name := fmt.tprint(mode)
			item := ui.menu_item(fmt.tprintf("%s %s###scrollbars_%s", "✓" if on else "   ", name, name))
			ui.accessible(item.box, .Menu_Item, name, selected = on)
			if item.clicked {
				st := pb.settings
				st.scrollbars = mode
				pb.settings = st
				settings_queue(&s.data, st)
			}
		}
	}
}

@(private = "file")
khz :: proc(rate: int) -> string {
	if rate % 1000 == 0 {
		return fmt.tprintf("%d", rate / 1000)
	}
	return fmt.tprintf("%.1f", f64(rate) / 1000)
}
