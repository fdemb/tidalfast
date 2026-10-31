package app

// Settings: the volume, shuffle and repeat, bit-perfect output, how lists
// show their scrollbars and whether the player bar blurs them. They live in
// a small JSON file, ~/Library/Application Support/tidalfast/settings.json,
// or wherever TIDALFAST_SETTINGS points. The fake data has none unless
// TIDALFAST_SETTINGS points to one, and a mock run without a mock URL has
// none (run_decide). A worker writes it, so a click never
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

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"

import "../audio"
import "../render"
import "../ui"

Settings :: struct {
	bit_perfect: bool,
	device:      audio.Device_Change, // rate 0 when no device is changed
	scrollbars:  ui.Scrollbars,
	bar:         Player_Bar,
	volume:      f32, // 0 to 1
	shuffle:     bool,
	repeat:      audio.Repeat,
}

VOLUME_DEFAULT :: 0.7

// Player_Bar is how the player bar sits on the views, where the renderer
// has backdrops (render.BACKDROPS).
Player_Bar :: enum u8 {
	Blurred, // over their bottoms, blurring them
	Solid, // under them
}

// Settings_File is Settings as the JSON in the file.
@(private = "file")
Settings_File :: struct {
	bit_perfect:   bool,
	scrollbars:    ui.Scrollbars,
	bar:           Player_Bar,
	device_change: Maybe(Device_Change_File) `json:"device_change,omitempty"`,
	volume:        Maybe(f32) `json:"volume,omitempty"`, // missing in files from before it was saved
	shuffle:       bool,
	repeat:        audio.Repeat,
}

@(private = "file")
Device_Change_File :: struct {
	uid:         string,
	orig_rate:   f64,
	orig_format: audio.Stream_Description,
	rate:        f64,
}

// settings_load reads the file at path. A missing or broken file gives
// the defaults, with ok false.
settings_load :: proc(path: string) -> (st: Settings, ok: bool) {
	if path == "" {
		return {volume = VOLUME_DEFAULT}, false
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {volume = VOLUME_DEFAULT}, false
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
		return {volume = VOLUME_DEFAULT}, false
	}
	st = {bit_perfect = f.bit_perfect, scrollbars = f.scrollbars, bar = f.bar, volume = clamp(f.volume.? or_else VOLUME_DEFAULT, 0, 1), shuffle = f.shuffle, repeat = f.repeat}
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
		scrollbars  = st.scrollbars,
		bar         = st.bar,
		volume      = st.volume,
		shuffle     = st.shuffle,
		repeat      = st.repeat,
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

// Settings_Store is the settings file and the newest settings for it. The
// UI thread puts settings in and a worker, or shutdown, flushes them out.
// The path is the store's own copy, set before the workers start and freed
// after they stop.
Settings_Store :: struct {
	path:    string, // heap, "" for none
	mutex:   sync.Mutex, // guards latest and gen
	latest:  Settings,
	gen:     u64,
	write:   sync.Mutex, // held while a flush writes the file
	written: u64, // the gen on disk; under write
}

// settings_put makes st the newest settings to save.
settings_put :: proc(store: ^Settings_Store, st: Settings) {
	sync.guard(&store.mutex)
	store.latest = st
	store.gen += 1
}

// settings_flush writes the newest settings if the file doesn't have them
// yet. One write at a time: a second caller waits for the first and then
// writes only if there's something newer, so older settings never land
// after newer ones and a burst of changes makes few writes. False if the
// write failed.
settings_flush :: proc(store: ^Settings_Store) -> bool {
	sync.guard(&store.write)
	sync.lock(&store.mutex)
	st, gen := store.latest, store.gen
	sync.unlock(&store.mutex)
	if gen == store.written || store.path == "" {
		return true
	}
	if !settings_save(store.path, st) {
		return false
	}
	store.written = gen
	return true
}

// settings_queue puts st in the store and has a worker save it, or saves
// it now when there are no workers or now is set.
settings_queue :: proc(d: ^Data, st: Settings, now := false) {
	settings_put(&d.settings_store, st)
	if d.running && !now {
		push_job(d, {payload = Save_Settings_Job{}})
	} else if !settings_flush(&d.settings_store) {
		log.errorf("app: couldn't save the settings to %s", d.settings_store.path)
	}
}

// settings_set applies st to the player and saves it.
settings_set :: proc(s: ^State, st: Settings) {
	s.settings = st
	if s.playback.player != nil {
		audio.set_output(s.playback.player, output_of(st))
	}
	settings_queue(&s.data, settings_to_save(s))
}

// settings_to_save is s.settings as the file should have them.
settings_to_save :: proc(s: ^State) -> Settings {
	st := s.settings
	if v, ok := s.volume_before_override.?; ok {
		st.volume = v
	}
	return st
}

output_of :: proc(st: Settings) -> audio.Output {
	return {bit_perfect = audio.BIT_PERFECT && st.bit_perfect}
}

// draw_output_button is the player bar's button for the output menu. In
// bit-perfect mode it shows the format reaching the device.
draw_output_button :: proc(s: ^State) {
	pb := &s.playback
	dev := pb.status.device
	label := "Output"
	color := SECONDARY
	if s.settings.bit_perfect {
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
		when audio.BIT_PERFECT {
			st := s.settings
			if ui.menu_item(fmt.tprintf("%s Bit-perfect output###bit_perfect", "✓" if st.bit_perfect else "   ")).clicked {
				st.bit_perfect = !st.bit_perfect
				settings_set(s, st)
				ui.close_menu()
			}
			ui.menu_separator()
		}
		ui.text_style(.Regular, 11, DIM)
		ui.set_next_text_pad(14)
		ui.label(output_description(s), ui.fill(), ui.px(26))
	}
}

// output_pill is the button, centred in a column as tall as the bar.
@(private = "file")
output_pill :: proc(s: ^State, label: string, color: render.Color) {
	ui.column("", {}, ui.px(OUTPUT_W), ui.fill())
	ui.spacer(ui.fill())
	ui.text_style(.Semibold, 11, color)
	ui.set_next_text_align(.Center)
	ui.set_next_background({})
	ui.set_next_border_color(color)
	ui.set_next_hover_color({1, 1, 1, 0.08})
	ui.set_next_radius(12)
	b := ui.box_make(fmt.tprintf("%s###output", label), {.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects, .Draw_Active_Effects, .Draw_Text}, ui.fill(), ui.px(24))
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
	case !s.settings.bit_perfect:
		return "System mixer"
	case dev.rate == 0:
		return "Bit-perfect"
	case dev.bit_perfect:
		return fmt.tprintf("Bit-perfect, %s kHz", khz(dev.rate))
	case dev.reason_len > 0:
		return fmt.tprintf("Not bit-perfect: %s", audio.device_reason(&dev))
	}
	return "Not bit-perfect"
}

// draw_settings_button is the sidebar's button for the settings menu.
draw_settings_button :: proc(s: ^State) {
	ui.text_style(.Regular, 12, SECONDARY)
	ui.set_next_text_pad(10)
	ui.set_next_radius(6)
	b := ui.box_make("Settings###settings", {.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.text_size(), ui.px(26))
	ui.accessible(b, .Button, "Settings")
	if ui.signal(b).clicked {
		ui.open_menu("settings_menu", {b.rect.x, b.rect.y + b.rect.h + 4})
	}

	if ui.menu("settings_menu") {
		ui.text_style(.Regular, 11, DIM)
		ui.set_next_text_pad(14)
		heading := ui.label("Scrollbars", ui.fill(), ui.px(24))
		ui.text_style(.Regular, 13, TEXT)
		for mode in ui.Scrollbars {
			on := s.settings.scrollbars == mode
			name := fmt.tprint(mode)
			item := ui.menu_item(fmt.tprintf("%s %s###scrollbars_%s", "✓" if on else "   ", name, name))
			ui.accessible(item.box, .Menu_Item, name, selected = on)
			if item.clicked {
				s.settings.scrollbars = mode
				settings_queue(&s.data, settings_to_save(s))
			}
		}
		if render.BACKDROPS {
			ui.text_style(.Regular, 11, DIM)
			ui.set_next_text_pad(14)
			heading = ui.label("Player bar", ui.fill(), ui.px(24))
			ui.text_style(.Regular, 13, TEXT)
			for mode in Player_Bar {
				on := s.settings.bar == mode
				name := fmt.tprint(mode)
				item := ui.menu_item(fmt.tprintf("%s %s###bar_%s", "✓" if on else "   ", name, name))
				ui.accessible(item.box, .Menu_Item, name, selected = on)
				if item.clicked {
					s.settings.bar = mode
					settings_queue(&s.data, settings_to_save(s))
				}
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
