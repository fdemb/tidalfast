// The keyboard shortcuts that work anywhere in the library. SHORTCUTS is
// the one list of them: library_shortcuts takes their keys, the player
// bar's and the sidebar's hints show their keys, and the settings page
// lists them all.
package app

import "../platform"
import "../ui"

Shortcut_Kind :: enum u8 {
	Play,
	Previous,
	Next,
	Seek_Back,
	Seek_Forward,
	Volume_Up,
	Volume_Down,
	Shuffle,
	Repeat,
	Back,
	Forward,
	Search,
}

// Shortcut is a key with exactly these modifiers, keys as this OS writes
// them, and what it does.
Shortcut :: struct {
	code:      platform.Key,
	modifiers: platform.Modifiers,
	keys:      string,
	does:      string,
}

PRIMARY_KEYS :: "⌘" when ODIN_OS == .Darwin else "Ctrl+"
ALT_KEYS :: "⌥" when ODIN_OS == .Darwin else "Alt+"
SHIFT_KEYS :: "⇧" when ODIN_OS == .Darwin else "Shift+"

// Alt with the arrows goes back and forward, as in a browser on Linux and
// Windows. The shells have no keys for macOS's Command-[ and Command-].
SHORTCUTS :: [Shortcut_Kind]Shortcut {
	.Play         = {.Space, {}, "Space", "Play or pause"},
	.Previous     = {.Left, {ui.PRIMARY}, PRIMARY_KEYS + "←", "Previous track"},
	.Next         = {.Right, {ui.PRIMARY}, PRIMARY_KEYS + "→", "Next track"},
	.Seek_Back    = {.Left, {.Shift}, SHIFT_KEYS + "←", "Back 5 seconds"},
	.Seek_Forward = {.Right, {.Shift}, SHIFT_KEYS + "→", "Forward 5 seconds"},
	.Volume_Up    = {.Up, {ui.PRIMARY}, PRIMARY_KEYS + "↑", "Volume up"},
	.Volume_Down  = {.Down, {ui.PRIMARY}, PRIMARY_KEYS + "↓", "Volume down"},
	.Shuffle      = {.S, {ui.PRIMARY}, PRIMARY_KEYS + "S", "Shuffle on or off"},
	.Repeat       = {.R, {ui.PRIMARY}, PRIMARY_KEYS + "R", "Repeat all, one or off"},
	.Back         = {.Left, {.Alt}, ALT_KEYS + "←", "Go back"},
	.Forward      = {.Right, {.Alt}, ALT_KEYS + "→", "Go forward"},
	.Search       = {.F, {ui.PRIMARY}, PRIMARY_KEYS + "F", "Search"},
}

// SEARCH_KEY_ALT also opens search, as the address bar's key in a browser.
SEARCH_KEY_ALT :: platform.Key.L

VOLUME_STEP :: 0.1
SEEK_STEP :: 5 // seconds

shortcut_keys :: proc(k: Shortcut_Kind) -> string {
	shortcuts := SHORTCUTS
	return shortcuts[k].keys
}

// take_shortcut takes a press of k's key from this frame's unused keys.
take_shortcut :: proc(k: Shortcut_Kind, repeats := true) -> bool {
	shortcuts := SHORTCUTS
	return ui.take_key(shortcuts[k].code, shortcuts[k].modifiers, repeats)
}

// library_shortcuts runs the shortcuts that work anywhere in the library,
// with the keys the views didn't take, and the mouse's Back and Forward. A
// text field keeps its own keys.
library_shortcuts :: proc(s: ^State) {
	if ui.take_button(.Back) {
		pending_set(s, Go_Back{})
	}
	if ui.take_button(.Forward) {
		pending_set(s, Go_Forward{})
	}
	// On the search page the field takes these itself (focus_shortcut).
	for take_shortcut(.Search) || ui.take_key(SEARCH_KEY_ALT, {ui.PRIMARY}) {
		pending_set(s, Search_Place{})
	}
	if ui.text_focused() {
		return
	}
	for take_shortcut(.Play, repeats = false) {
		playback_toggle(s)
		ui.data_changed()
	}
	for take_shortcut(.Next) {
		playback_next(s)
		ui.data_changed()
	}
	for take_shortcut(.Previous) {
		playback_previous(s)
		ui.data_changed()
	}
	for take_shortcut(.Seek_Forward) {
		playback_seek_by(s, SEEK_STEP)
		ui.data_changed()
	}
	for take_shortcut(.Seek_Back) {
		playback_seek_by(s, -SEEK_STEP)
		ui.data_changed()
	}
	for take_shortcut(.Volume_Up) {
		playback_set_volume(s, min(s.settings.volume + VOLUME_STEP, 1), true)
		ui.data_changed()
	}
	for take_shortcut(.Volume_Down) {
		playback_set_volume(s, max(s.settings.volume - VOLUME_STEP, 0), true)
		ui.data_changed()
	}
	for take_shortcut(.Shuffle, repeats = false) {
		playback_set_shuffle(s, !s.settings.shuffle)
		ui.data_changed()
	}
	for take_shortcut(.Repeat, repeats = false) {
		playback_set_repeat(s, repeat_after(s.settings.repeat))
		ui.data_changed()
	}
	for take_shortcut(.Back, repeats = false) {
		pending_set(s, Go_Back{})
	}
	for take_shortcut(.Forward, repeats = false) {
		pending_set(s, Go_Forward{})
	}
}
