package app

// Settings: the volume, shuffle and repeat, how ReplayGain applies,
// bit-perfect output, how lists
// show their scrollbars, whether the player bar blurs them, whether covers
// lean under the pointer and, on Linux,
// whose title bar the window has and GNOME's button layout. They live in
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
// 24/96. The settings page has them all (settings_page.odin).

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
import "../sys"
import "../ui"

Settings :: struct {
	bit_perfect: bool,
	device:      audio.Device_Change, // rate 0 when no device is changed
	scrollbars:  ui.Scrollbars,
	bar:         Player_Bar,
	volume:      f32, // 0 to 1
	shuffle:     bool,
	repeat:      audio.Repeat,
	replay_gain: audio.Gain_Setting,
	title_bar:   Title_Bar,
	// Covers stay flat under the pointer. Named for the off state, so a
	// file from before it has the effect on.
	still_covers: bool,
	// GNOME's window button layout as the portal last gave it, for the
	// window's first frame. nil until it has.
	button_layout: Maybe(Button_Layout),
}

VOLUME_DEFAULT :: 0.7

// Title_Bar is whose title bar the window has on Linux, where the
// compositor can draw one (Frame_Input.window's Decorations). Where it
// can't, as on GNOME, the app draws its own whatever this says. Either
// way the compositor has the last word, as sway does keeping its own on a
// tiled window.
Title_Bar :: enum u8 {
	Automatic, // the app's own, but the compositor's on a tiling one (tiling_desktop)
	System, // the compositor's, or none on a tiling one that draws none
	Own, // the app's buttons in the room at the top of the view
}

// title_bar_name is what the settings page calls each choice.
title_bar_name :: proc(t: Title_Bar) -> string {
	switch t {
	case .Automatic:
		return "Automatic"
	case .System:
		return "System"
	case .Own:
		return "TIDALfast"
	}
	return ""
}

// title_bar_own says whether the window asks for its own title bar, the
// desktop being XDG_CURRENT_DESKTOP.
title_bar_own :: proc(t: Title_Bar, desktop: string) -> bool {
	switch t {
	case .Automatic:
		return !tiling_desktop(desktop)
	case .System:
		return false
	case .Own:
		return true
	}
	return false
}

// tiling_desktop says whether XDG_CURRENT_DESKTOP, a list split by
// colons, names a tiling compositor. Their users set them up without
// title bars, or with the compositor's, and a window's own buttons would
// be in the way.
tiling_desktop :: proc(desktop: string) -> bool {
	return desktop_is_one_of(desktop, {"sway", "hyprland", "niri", "river", "dwl", "qtile", "jay", "miracle-wm", "mango", "i3", "swayfx"})
}

// gnome_desktop says whether XDG_CURRENT_DESKTOP names GNOME or a desktop
// that keeps GNOME's button-layout setting. Elsewhere that setting is
// GNOME's default, close alone, which nobody chose.
gnome_desktop :: proc(desktop: string) -> bool {
	return desktop_is_one_of(desktop, {"gnome", "unity", "pantheon"})
}

@(private = "file")
desktop_is_one_of :: proc(desktop: string, names: []string) -> bool {
	rest := desktop
	for name in strings.split_iterator(&rest, ":") {
		for n in names {
			if strings.equal_fold(strings.trim_space(name), n) {
				return true
			}
		}
	}
	return false
}

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
	replay_gain:   audio.Gain_Setting, // a name it doesn't know reads as Automatic
	title_bar:     Title_Bar,
	still_covers:  bool,
	button_layout: string `json:"button_layout,omitempty"`,
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
	// A choice can come as a number, and one out of range would index past
	// the tables named by it.
	known :: proc(v: $T) -> T {
		return v if v >= min(T) && v <= max(T) else {}
	}
	st = {bit_perfect = f.bit_perfect, scrollbars = known(f.scrollbars), bar = known(f.bar), volume = clamp(f.volume.? or_else VOLUME_DEFAULT, 0, 1), shuffle = f.shuffle, repeat = known(f.repeat), replay_gain = known(f.replay_gain), title_bar = known(f.title_bar), still_covers = f.still_covers}
	if f.button_layout != "" {
		st.button_layout = button_layout_parse(f.button_layout)
	}
	if c, has := f.device_change.?; has && c.rate > 0 && c.orig_rate > 0 && len(c.uid) <= len(st.device.uid) {
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
		replay_gain = st.replay_gain,
		title_bar   = st.title_bar,
		still_covers = st.still_covers,
	}
	if l, ok := st.button_layout.?; ok {
		f.button_layout = button_layout_string(l)
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
		if !sys.replace_file(tmp, path) {
			werr = .Unknown
		}
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
	if output_of(st) != output_of(s.settings) {
		s.playback.output_seen = {}
	}
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

// save_settings_result shows why the settings didn't save, if they didn't.
save_settings_result :: proc(d: ^Data, res: ^Result) {
	if res.err != nil {
		d.message = res.message
	}
}
