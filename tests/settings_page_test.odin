package tidal_tests

import "core:mem"
import vmem "core:mem/virtual"
import "core:fmt"
import "core:testing"

import app "../src/app"
import "../src/audio"
import "../src/platform"
import "../src/ui"

// Settings in the user menu shows the page, where a choice and the switch
// change the settings, the switch stops asking for frames once its knob is
// across, and Back leaves the page.
@(test)
settings_page_changes_settings :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	open_settings(t, s, &f, "Fake data")
	_, titled := access_node(s, "Appearance")
	testing.expect(t, titled, "the Appearance card")
	_, account := access_node(s, "Account")
	testing.expect(t, !account, "the fake data has no account")

	floating, _ := settings_button(s, "Floating scrollbars")
	testing.expect(t, .Selected in floating.flags, "Floating is the default")
	docked, _ := settings_button(s, "Docked scrollbars")
	library_frame(t, s, &f, {kind = .Access_Press, target = docked.id})
	library_frame(t, s, &f)
	testing.expect_value(t, s.settings.scrollbars, ui.Scrollbars.Docked)
	docked, _ = settings_button(s, "Docked scrollbars")
	testing.expect(t, .Selected in docked.flags, "Docked shows as chosen")
	floating, _ = settings_button(s, "Floating scrollbars")
	testing.expect(t, .Selected not_in floating.flags, "Floating no longer does")

	bit_perfect, has_switch := settings_button(s, "Bit-perfect output")
	if testing.expect(t, has_switch, "the bit-perfect switch") {
		testing.expect_value(t, string(bit_perfect.value), "Off")
		library_frame(t, s, &f, {kind = .Access_Press, target = bit_perfect.id})
		testing.expect(t, s.settings.bit_perfect, "the switch turns bit-perfect output on")
		library_frame(t, s, &f)
		testing.expect(t, f.animating, "the knob slides")
		for _ in 0 ..< 60 {
			library_frame(t, s, &f)
		}
		testing.expect(t, !f.animating, "and stops")
		bit_perfect, _ = settings_button(s, "Bit-perfect output")
		testing.expect_value(t, string(bit_perfect.value), "On")
	}

	app.pending_set(s, app.Go_Back{})
	app.pending_apply(s)
	library_frame(t, s, &f)
	testing.expect(t, !app.settings_showing(s), "Back leaves the page")
}

// The title bar's row shows only where the compositor offers decorations,
// and its choices change the setting.
@(test)
settings_page_has_the_title_bar :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	open_settings(t, s, &f, "Fake data")
	_, shown := settings_button(s, "System title bar")
	testing.expect(t, !shown, "no title bar row without decorations")

	s.window.decorations = true
	library_frame(t, s, &f)
	automatic, _ := settings_button(s, "Automatic title bar")
	testing.expect(t, .Selected in automatic.flags, "Automatic is the default")
	own, ok := settings_button(s, "TIDALfast title bar")
	if !testing.expect(t, ok, "the TIDALfast choice") {
		return
	}
	library_frame(t, s, &f, {kind = .Access_Press, target = own.id})
	library_frame(t, s, &f)
	testing.expect_value(t, s.settings.title_bar, app.Title_Bar.Own)
	own, _ = settings_button(s, "TIDALfast title bar")
	testing.expect(t, .Selected in own.flags, "TIDALfast shows as chosen")
}

// The ReplayGain row starts on Automatic, its choices change the setting
// and the output menu's path, and with bit-perfect output on it says the
// gain isn't applied.
@(test)
settings_page_has_replay_gain :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	open_settings(t, s, &f, "Fake data")
	_, row := access_node(s, "ReplayGain")
	testing.expect(t, row, "the ReplayGain row")
	_, about := access_node(s, "Applies from the next track. Albums in order get album gain")
	testing.expect(t, about, "what it does and when")
	automatic, _ := settings_button(s, "ReplayGain Automatic")
	testing.expect(t, .Selected in automatic.flags, "Automatic is the default")
	testing.expect_value(t, app.signal_path(s)[1].detail, "Applies volume and ReplayGain")

	for g in audio.Gain_Setting {
		b, ok := settings_button(s, fmt.tprintf("ReplayGain %v", g))
		if !testing.expectf(t, ok, "the %v choice", g) {
			return
		}
		library_frame(t, s, &f, {kind = .Access_Press, target = b.id})
		library_frame(t, s, &f)
		testing.expect_value(t, s.settings.replay_gain, g)
		b, _ = settings_button(s, fmt.tprintf("ReplayGain %v", g))
		testing.expectf(t, .Selected in b.flags, "%v shows as chosen", g)
	}
	testing.expect_value(t, s.settings.replay_gain, audio.Gain_Setting.Off)
	testing.expect_value(t, app.signal_path(s)[1].detail, "Applies volume")

	when audio.BIT_PERFECT {
		s.settings.bit_perfect = true
		library_frame(t, s, &f)
		_, note := access_node(s, "Not applied in bit-perfect mode")
		testing.expect(t, note, "bit-perfect output says the gain is skipped")
		testing.expect_value(t, app.signal_path(s)[1].detail, "No volume or ReplayGain")
	}
}

// At the bottom of the page every shortcut has a row, with what it does
// and its keys as static text.
@(test)
settings_page_lists_the_shortcuts :: proc(t: ^testing.T) {
	// The keycaps are as wide as their text, and the window tall enough
	// for the whole page.
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 1400}}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	open_settings(t, s, &f, "Fake data")
	testing.expect(t, static_text(s, "Keyboard shortcuts"), "the shortcuts' card")
	for sc in app.SHORTCUTS {
		testing.expectf(t, static_text(s, sc.does), "the shortcut to %s", sc.does)
		testing.expectf(t, static_text(s, sc.keys), "its keys, %s", sc.keys)
	}
}

// Signed in, the page has the account's card, whose button logs out.
@(test)
settings_page_logs_out :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	res := app.Result {
		job     = {auth = s.data.auth_gen, payload = app.Profile_Job{}},
		payload = app.Profile_Result{name = app.small("Ada Lovelace")},
	}
	app.handle_result(s, &res, 0)
	f := Frame{size = {1000, 800}} // tall enough for the account's card
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	open_settings(t, s, &f, "Ada Lovelace")
	_, signed_in := access_node(s, "Signed in to TIDAL")
	testing.expect(t, signed_in, "the account's row")
	log_out, ok := settings_button(s, "Log out")
	if !testing.expect(t, ok, "the Log out button") {
		return
	}
	library_frame(t, s, &f, {kind = .Access_Press, target = log_out.id})
	library_frame(t, s, &f)
	testing.expect_value(t, s.data.account, app.Account.Signed_Out)
}

// open_settings opens the user menu from the row labelled user and presses
// its Settings.
@(private = "file")
open_settings :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, user: string, loc := #caller_location) {
	library_frame(t, s, f, press(s, user), loc = loc)
	for _ in 0 ..< 30 {
		library_frame(t, s, f, loc = loc)
	}
	library_frame(t, s, f, press(s, "Settings"), loc = loc)
	for _ in 0 ..< 30 {
		library_frame(t, s, f, loc = loc)
	}
	testing.expect(t, app.settings_showing(s), "Settings shows the settings page", loc = loc)
}

// static_text says whether the last frame has a static text labelled label.
@(private = "file")
static_text :: proc(s: ^app.State, label: string) -> bool {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Static_Text && string(n.label) == label {
			return true
		}
	}
	return false
}

// settings_button is the last frame's button labelled label.
@(private = "file")
settings_button :: proc(s: ^app.State, label: string) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Button && string(n.label) == label {
			return n, true
		}
	}
	return {}, false
}
