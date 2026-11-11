// The user row at the bottom of the sidebar: the signed-in user's picture,
// and on hover a button with their name that opens a menu with Settings and
// Log out. The name and picture come from TIDAL once per login.
package app

import "core:fmt"
import "core:log"
import "core:unicode"
import "core:unicode/utf8"

import "../cover"
import "../text"
import "../ui"

USER_ROW_PAD :: 6 // above and below the button
USER_ROW_H :: NAV_ROW_H + 2 * USER_ROW_PAD
USER_AVATAR :: 24
USER_MENU :: "user_menu"

// Profile is the signed-in user's name and picture. A failed fetch counts
// as loaded, so it isn't asked for every frame; the next login asks again.
Profile :: struct {
	name:    Small,
	picture: Small, // TIDAL's image id, "" for none
	loaded:  bool,
	loading: bool,
}

profile_want :: proc(d: ^Data) {
	p := &d.profile
	if d.fake || d.account != .Signed_In || p.loaded || p.loading {
		return
	}
	p.loading = true
	push_job(d, {payload = Profile_Job{}})
}

profile_result :: proc(d: ^Data, res: ^Result, failed: bool) {
	p := &d.profile
	p.loading = false
	p.loaded = true
	if failed {
		if err, ok := res.err.?; ok {
			log.warnf("app: fetching the profile failed: %v", err)
		}
		return
	}
	answer, _ := res.payload.(Profile_Result)
	p.name = answer.name
	p.picture = answer.picture
}

// draw_user_row is the user row under the playlists. The
// button's background, the name and the chevron fade in while it's hovered
// or focused, and stay while its menu is open.
draw_user_row :: proc(s: ^State) {
	d := &s.data
	profile_want(d)
	name := small_str(&d.profile.name)
	if d.fake {
		name = "Fake data"
	}
	label := name if name != "" else "Account"
	open := ui.menu_is_open(USER_MENU)

	ui.column("", {}, ui.fill(), ui.px(USER_ROW_H)).pad = {SIDEBAR_PAD, USER_ROW_PAD}
	ui.set_next_radius(8)
	sidebar_selected(open)
	b := ui.row("##user", {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Instant_Hover}, ui.fill(), ui.fill())
	ui.accessible(b, .Button, label)
	if ui.signal(b).clicked {
		ui.open_menu(USER_MENU, {b.rect.x, b.rect.y - 4}, up = true)
	}
	shown := max(ui.hover_t(b), b.focus_t, 1 if open else 0)
	// The avatar's centre is level with Home's and Search's icons.
	ui.spacer(ui.px(ROW_PAD - 3))
	draw_avatar(s, small_str(&d.profile.picture), name)
	ui.spacer(ui.px(10))
	ui.text_style(.Medium, 13, NAV_TEXT)
	ui.label(label, ui.fill(), ui.fill()).opacity = shown
	ui.text_style(.Icon, 14, QUIET)
	ui.set_next_text_align(.Center)
	ui.label(text.ICON_CARET_UP_DOWN, ui.px(18), ui.fill()).opacity = shown
	ui.spacer(ui.px(ROW_PAD - 3))

	if ui.menu(USER_MENU, b.rect.w) {
		ui.text_style(.Regular, 13, TEXT)
		if ui.menu_item("Settings###user_settings").clicked {
			ui.open_menu(SETTINGS_MENU, {b.rect.x, b.rect.y - 4}, up = true)
		}
		if d.account == .Signed_In {
			ui.menu_separator()
			if ui.menu_item("Log out###log_out").clicked {
				pending_set(s, Log_Out{})
			}
		}
	}
}

// draw_avatar is the user's picture in a circle. Until it has come, or
// without one, the circle holds the name's first letter, or a person
// before the name has come.
@(private = "file")
draw_avatar :: proc(s: ^State, picture, name: string) {
	ui.column("", {.Center_Children}, ui.px(USER_AVATAR), ui.fill())
	ui.radius(USER_AVATAR / 2)
	ui.set_next_background(SURFACE_ACTIVE)
	a := ui.box_make("", {.Draw_Background}, ui.px(USER_AVATAR), ui.px(USER_AVATAR))
	a.rim = COVER_RIM
	ui.parent(a)
	e := cover_want(s, .User, picture, USER_AVATAR, PRIORITY_COVER)
	ready := e != nil && e.state == .Ready
	if !ready || cover.alpha(e, s.ui.time) < 1 {
		if name != "" {
			r, _ := utf8.decode_rune_in_string(name)
			ui.text_style(.Semibold, 11, TEXT)
			ui.set_next_text_align(.Center)
			ui.label(fmt.tprintf("%c", unicode.to_upper(r)), ui.fill(), ui.fill())
		} else {
			ui.text_style(.Icon, 13, SECONDARY)
			ui.set_next_text_align(.Center)
			ui.label(text.ICON_USER, ui.fill(), ui.fill())
		}
	}
	if ready {
		img := ui.box_make("", {.Floating_X, .Floating_Y}, ui.px(USER_AVATAR), ui.px(USER_AVATAR))
		img.texture = cover.texture(&s.data.covers, e)
		img.texture_src = cover.src(&s.data.covers, e)
		img.rim = COVER_RIM
		img.opacity = cover.alpha(e, s.ui.time)
		if img.opacity < 1 {
			ui.request_frame()
		}
	}
}
