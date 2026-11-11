package tidal_tests

import "core:mem"
import vmem "core:mem/virtual"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/ui"

// The profile comes from the logged in user's record, first and last name.
@(test)
profile_job_reads_the_name :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	d := &s.data
	run_now(s, {auth = d.auth_gen, payload = app.Profile_Job{}})
	testing.expect(t, d.profile.loaded)
	testing.expect_value(t, app.small_str(&d.profile.name), "F L")
	testing.expect_value(t, app.small_str(&d.profile.picture), "")
}

// The row shows only the avatar until the mouse is over it, then the name
// and the chevron fade in.
@(test)
user_row_shows_the_name_on_hover :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(false)
	defer library_state_free(s)
	signed_in_as(s, "Ada Lovelace")
	f := Frame{fonts = &fonts}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect_value(t, name_opacity(s, "Ada Lovelace"), 0)

	n, _ := access_node(s, "Ada Lovelace")
	library_frame(t, s, &f, {kind = .Mouse_Move, x = n.frame[0] + n.frame[2] / 2, y = n.frame[1] + n.frame[3] / 2})
	for _ in 0 ..< 60 {
		library_frame(t, s, &f)
	}
	testing.expect_value(t, name_opacity(s, "Ada Lovelace"), 1)
	testing.expect(t, !f.animating, "the row settles")

	library_frame(t, s, &f, {kind = .Mouse_Move, x = 600, y = 300})
	for _ in 0 ..< 60 {
		library_frame(t, s, &f)
	}
	testing.expect_value(t, name_opacity(s, "Ada Lovelace"), 0)
}

// The menu opens above the row, Settings opens the settings menu there,
// and Log out signs out.
@(test)
user_menu_opens_settings_and_logs_out :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	signed_in_as(s, "Ada Lovelace")
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	row := node_box(s, "Ada Lovelace").rect

	open_user_menu(t, s, &f)
	settings := menu_item(s, "Settings")
	settings_rect := ui.box_lookup(&s.ui, ui.Key(settings.id)).rect
	bottom := settings_rect.y + settings_rect.h
	testing.expectf(t, bottom <= row.y, "the menu ends at %v, above the row at %v", bottom, row.y)
	library_frame(t, s, &f, {kind = .Access_Press, target = settings.id})
	library_frame(t, s, &f)
	testing.expect(t, ui.menu_is_open(app.SETTINGS_MENU), "Settings opens the settings menu")
	library_frame(t, s, &f, key(.Escape))
	for _ in 0 ..< 30 {
		library_frame(t, s, &f)
	}

	open_user_menu(t, s, &f)
	library_frame(t, s, &f, {kind = .Access_Press, target = menu_item(s, "Log out").id})
	library_frame(t, s, &f)
	testing.expect_value(t, s.data.account, app.Account.Signed_Out)
	testing.expect(t, !s.data.profile.loaded, "the profile goes with the login")
}

// With the fake data there's no login to end.
@(test)
fake_user_menu_has_no_log_out :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Fake data"))
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, ui.menu_is_open(app.USER_MENU))
	testing.expect(t, menu_item(s, "Settings").id != 0)
	testing.expect(t, menu_item(s, "Log out").id == 0)
}

@(private = "file")
signed_in_as :: proc(s: ^app.State, name: string) {
	res := app.Result {
		job     = {auth = s.data.auth_gen, payload = app.Profile_Job{}},
		payload = app.Profile_Result{name = app.small(name)},
	}
	app.handle_result(s, &res, 0)
}

@(private = "file")
open_user_menu :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, loc := #caller_location) {
	library_frame(t, s, f, press(s, "Ada Lovelace"), loc = loc)
	for _ in 0 ..< 30 {
		library_frame(t, s, f, loc = loc)
	}
	testing.expect(t, ui.menu_is_open(app.USER_MENU), "the row opens its menu", loc = loc)
}

// menu_item is the last frame's menu item labelled label, zero if none.
@(private = "file")
menu_item :: proc(s: ^app.State, label: string) -> platform.Access_Node {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Menu_Item && string(n.label) == label {
			return n
		}
	}
	return {}
}

// name_opacity is the opacity of the label in the user row's button.
@(private = "file")
name_opacity :: proc(s: ^app.State, name: string) -> f32 {
	b := node_box(s, name)
	for c := b.first; c != nil; c = c.next {
		if c.label == name {
			return ui.drawn_opacity(c)
		}
	}
	return -1
}
