package app

// The login screen for TIDAL's device-code login: the app asks TIDAL for a
// short code, the user enters it at link.tidal.com (or opens the link with
// the code in it), and a worker polls until they approve.

import "core:fmt"

import "../mac"
import "../render"
import "../text"
import "../tidal"
import "../ui"

LOGIN_W :: 420
LOGIN_H :: 360

draw_login :: proc(s: ^State) {
	bg := ui.box_make("", {.Draw_Background}, ui.fill(), ui.fill())
	bg.background = WINDOW_BG
	bg.child_axis = .Y
	ui.parent(bg)
	ui.spacer(ui.fill())
	{
		ui.row("", {}, ui.fill(), ui.px(LOGIN_H))
		ui.spacer(ui.fill())
		{
			card := ui.column("login", {.Draw_Background, .Draw_Border}, ui.px(LOGIN_W), ui.fill())
			card.background = PANEL
			card.border_color = OUTLINE
			card.radius = 12
			login_card(s)
		}
		ui.spacer(ui.fill())
	}
	ui.spacer(ui.fill())
}

@(private = "file")
line :: proc(str: string, font: text.Font, size, height: f32, color: render.Color) -> ^ui.Box {
	ui.text_style(font, size, color)
	b := ui.label(str, ui.fill(), ui.px(height))
	b.text_align = .Center
	b.text_pad = 24
	return b
}

@(private = "file")
login_card :: proc(s: ^State) {
	l := &s.data.login
	ui.spacer(ui.px(32))
	line("Log in to TIDAL", .Bold, 24, 34, TEXT)
	ui.spacer(ui.px(12))

	code := small_str(&l.link.user_code)
	switch {
	case l.error.len > 0:
		line(small_str(&l.error), .Regular, 14, 20, SECONDARY)
		ui.spacer(ui.px(16))
		{
			ui.row("", {}, ui.fill(), ui.px(40))
			ui.spacer(ui.fill())
			if pill_button("retry", "Try again", 160, SURFACE_ACTIVE, TEXT) {
				l.error = {}
				request_login_code(&s.data)
			}
			ui.spacer(ui.fill())
		}
	case code != "":
		line("On your phone or computer, go to", .Regular, 14, 20, SECONDARY)
		line(small_str(&l.link.uri), .Semibold, 15, 22, ACCENT)
		line("and enter this code:", .Regular, 14, 20, SECONDARY)
		ui.spacer(ui.px(10))
		line(code, .Bold, 40, 52, TEXT)
		ui.spacer(ui.px(18))
		{
			ui.row("", {}, ui.fill(), ui.px(40))
			ui.spacer(ui.fill())
			if pill_button("open_link", "Open in your browser", 240, ACCENT, PANEL) {
				mac.open_url(small_str(&l.link.uri_full))
			}
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(18))
		if l.note.len > 0 {
			line(small_str(&l.note), .Regular, 12, 18, DIM)
		} else {
			line("Waiting for you to approve this device…", .Regular, 12, 18, DIM)
		}
	case:
		line("Getting a code from TIDAL…", .Regular, 14, 20, SECONDARY)
		if l.note.len > 0 {
			line(small_str(&l.note), .Regular, 12, 18, DIM)
		}
	}
	if wait := tidal.backoff_remaining(s.data.session); wait > 0 {
		line(fmt.tprintf("TIDAL asked us to slow down. Trying again in %d s.", int(wait + 0.5)), .Regular, 12, 18, DIM)
	}
}

@(private = "file")
pill_button :: proc(id, label: string, width: f32, background, color: render.Color) -> bool {
	b := ui.row(id, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(width), ui.fill())
	b.background = background
	b.hover_color = {1, 1, 1, 0.2}
	b.active_color = {0, 0, 0, 0.15}
	b.radius = 20
	ui.text_style(.Semibold, 14, color)
	caption := ui.label(label, ui.fill(), ui.fill())
	caption.text_align = .Center
	return ui.signal(b).clicked
}
