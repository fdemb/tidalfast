package tidal_tests

import vmem "core:mem/virtual"
import "core:testing"

import app "../src/app"
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
	f: Frame
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
