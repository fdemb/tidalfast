package app

// The login screen. The main login is the PKCE login of TIDAL's Android
// client, the only client TIDAL gives FLAC: "Log in with TIDAL" opens
// TIDAL's login page in the browser, which ends on a page that doesn't
// load. Its address holds a one-time code; the user pastes the address
// into the field, and a worker trades the code for tokens.
//
// The device-code login stays as the other way in: the app asks TIDAL for
// a short code, the user enters it at link.tidal.com, and a worker polls
// until they approve. TIDAL gives that client AAC only, which the player
// doesn't decode.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

import "../os_services"
import "../render"
import "../text"
import "../tidal"
import "../ui"

LOGIN_W :: 460
LOGIN_H :: 430

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
	ui.accessible(b, .Static_Text, str)
	return b
}

@(private = "file")
centered_button :: proc(id, label: string, width, height: f32, background, color: render.Color) -> bool {
	ui.row("", {}, ui.fill(), ui.px(height))
	ui.spacer(ui.fill())
	clicked := pill_button(id, label, width, background, color)
	ui.spacer(ui.fill())
	return clicked
}

@(private = "file")
login_card :: proc(s: ^State) {
	d := &s.data
	l := &d.login
	ui.spacer(ui.px(32))
	if l.pkce == .Off {
		device_card(s)
	} else {
		pkce_card(s)
	}
	if wait := tidal.backoff_remaining(d.session); wait > 0 {
		line(fmt.tprintf("TIDAL asked us to slow down. Trying again in %d s.", int(wait + 0.5)), .Regular, 12, 18, DIM)
	}
}

pill_button :: proc(id, label: string, width: f32, background, color: render.Color) -> bool {
	b := ui.row(id, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(width), ui.fill())
	b.background = background
	b.hover_color = {1, 1, 1, 0.2}
	b.active_color = {0, 0, 0, 0.15}
	b.radius = 20
	ui.accessible(b, .Button, label)
	ui.text_style(.Semibold, 14, color)
	caption := ui.label(label, ui.fill(), ui.fill())
	caption.text_align = .Center
	return ui.signal(b).clicked
}

@(private = "file")
pkce_card :: proc(s: ^State) {
	d := &s.data
	l := &d.login
	line("Log in to TIDAL", .Bold, 24, 34, TEXT)
	ui.spacer(ui.px(12))
	if l.pkce == .Exchanging {
		line("Logging you in…", .Regular, 14, 20, SECONDARY)
		return
	}
	if pkce_has_tokens(d) {
		// The code is spent; the tokens it got finish the login.
		line("TIDAL accepted the login, but your account didn't load.", .Regular, 14, 20, SECONDARY)
		ui.spacer(ui.px(18))
		if centered_button("pkce_retry", "Try again", 160, 40, ACCENT, PANEL) {
			pkce_resume(d)
		}
		ui.spacer(ui.px(12))
		line(small_str(&l.pkce_note), .Regular, 12, 18, PLAYBACK_ERROR)
		return
	}
	if l.note.len > 0 {
		line(small_str(&l.note), .Regular, 13, 20, SECONDARY)
		ui.spacer(ui.px(10))
	}
	if centered_button("pkce_open", "Log in with TIDAL", 220, 40, ACCENT, PANEL) {
		pkce_begin(d)
	}
	ui.spacer(ui.px(20))
	line("TIDAL ends on a page that doesn't load.", .Regular, 14, 20, SECONDARY)
	line("Copy that page's address and paste it here.", .Regular, 14, 20, SECONDARY)
	ui.spacer(ui.px(14))
	{
		ui.row("", {}, ui.fill(), ui.px(36))
		ui.spacer(ui.px(24))
		l.field.limit = PKCE_REDIRECT_MAX
		ui.text_style(.Regular, 13, TEXT)
		sig := ui.text_field("pkce_url", &l.field, "Paste the address here", ui.fill(), ui.px(36))
		sig.box.background = SURFACE
		sig.box.border_color = ACCENT if sig.focused else OUTLINE
		if l.focus_field {
			ui.focus_text_field(sig.box, &l.field)
			l.focus_field = false
		}
		ui.spacer(ui.px(10))
		if pill_button("pkce_continue", "Continue", 110, SURFACE_ACTIVE, TEXT) {
			pkce_submit(s, ui.field_text(&l.field))
		} else if sig.submitted {
			pkce_submit(s, sig.submitted_text)
		}
		ui.spacer(ui.px(24))
	}
	ui.spacer(ui.px(8))
	if note := small_str(&l.pkce_note); note != "" {
		line(note, .Regular, 12, 18, PLAYBACK_ERROR)
	} else {
		line(fmt.tprintf("It starts with %s", d.session.config.pkce_uri_redirect), .Regular, 12, 18, DIM)
	}
	ui.spacer(ui.fill())
	if d.relogin {
		if centered_button("relogin_back", "Back to your library", 220, 32, SURFACE_ACTIVE, TEXT) {
			d.relogin = false
			l.pkce_note = {}
		}
	} else if centered_button("use_code", "Log in with a code instead (AAC only, no lossless)", 410, 32, SURFACE_ACTIVE, SECONDARY) {
		device_begin(d)
	}
	ui.spacer(ui.px(24))
}

@(private = "file")
device_card :: proc(s: ^State) {
	d := &s.data
	l := &d.login
	line("Log in with a code", .Bold, 24, 34, TEXT)
	line("TIDAL streams AAC only to this login, which TIDALfast can't play.", .Regular, 12, 18, DIM)
	ui.spacer(ui.px(12))

	code := small_str(&l.link.user_code)
	switch {
	case l.error.len > 0:
		line(small_str(&l.error), .Regular, 14, 20, SECONDARY)
		ui.spacer(ui.px(16))
		if centered_button("retry", "Try again", 160, 40, SURFACE_ACTIVE, TEXT) {
			l.error = {}
			request_login_code(d)
		}
	case code != "":
		line("On your phone or computer, go to", .Regular, 14, 20, SECONDARY)
		line(small_str(&l.link.uri), .Semibold, 15, 22, ACCENT)
		line("and enter this code:", .Regular, 14, 20, SECONDARY)
		ui.spacer(ui.px(10))
		line(code, .Bold, 40, 52, TEXT)
		ui.spacer(ui.px(18))
		if centered_button("open_link", "Open in your browser", 240, 40, ACCENT, PANEL) {
			os_services.open_url(small_str(&l.link.uri_full))
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
	ui.spacer(ui.fill())
	if centered_button("use_pkce", "Log in with TIDAL instead", 240, 32, SURFACE_ACTIVE, TEXT) {
		pkce_begin(d)
	}
	ui.spacer(ui.px(24))
}

// draw_login_notice is the library's line for a device-code login, which
// TIDAL gives only AAC, until the user hides it. They can browse meanwhile.
draw_login_notice :: proc(s: ^State) {
	d := &s.data
	if !d.device_login || d.notice_hidden {
		return
	}
	bar := ui.row("login_notice", {.Draw_Background}, ui.fill(), ui.px(48))
	bar.background = SURFACE
	ui.spacer(ui.px(16))
	ui.text_style(.Regular, 13, TEXT)
	msg := ui.label("This login can only stream AAC. Log in again for lossless.", ui.fill(), ui.fill())
	ui.accessible(msg, .Static_Text, msg.label)
	{
		ui.column("", {}, ui.px(170), ui.fill())
		ui.spacer(ui.px(8))
		{
			ui.row("", {}, ui.fill(), ui.px(32))
			if pill_button("notice_login", "Log in with TIDAL", 170, ACCENT, PANEL) {
				relogin_begin(d)
			}
		}
	}
	ui.spacer(ui.px(8))
	{
		ui.column("", {}, ui.px(90), ui.fill())
		ui.spacer(ui.px(8))
		{
			ui.row("", {}, ui.fill(), ui.px(32))
			if pill_button("notice_hide", "Not now", 90, SURFACE_ACTIVE, TEXT) {
				d.notice_hidden = true
			}
		}
	}
	ui.spacer(ui.px(16))
}

// pkce_prepare makes the PKCE verifier and client key for the next login
// page, if there are none. They're kept in Data, so a hot reload doesn't
// lose them.
pkce_prepare :: proc(d: ^Data) {
	if d.pkce_verifier.len == 0 {
		verifier, key := tidal.pkce_new_state(context.temp_allocator)
		d.pkce_verifier = small(verifier)
		d.pkce_key = small(key)
	}
	tidal.session_set_pkce_state(d.session, small_str(&d.pkce_verifier), small_str(&d.pkce_key))
}

// pkce_begin opens TIDAL's login page for the PKCE client in the browser.
pkce_begin :: proc(d: ^Data) {
	pkce_show(d)
	os_services.open_url(tidal.pkce_login_url(d.session, context.temp_allocator))
}

// pkce_show switches to the PKCE login as a new attempt, without the
// browser. A device-code poll stops.
pkce_show :: proc(d: ^Data) {
	l := &d.login
	pkce_prepare(d)
	login_next_attempt(d)
	sync.atomic_store(&d.device_cancel, true)
	l.pkce = .Paste
	l.pkce_note = {}
	l.focus_field = true
}

// device_begin switches to the device-code login.
device_begin :: proc(d: ^Data) {
	l := &d.login
	l.pkce = .Off
	l.pkce_note = {}
	login_next_attempt(d)
	sync.atomic_store(&d.device_cancel, false)
	if l.link.device_code.len > 0 {
		request_login_poll(d)
	} else {
		request_login_code(d)
	}
}

// relogin_begin shows the PKCE login over a signed-in device-code login.
// The account stays until the user submits an address.
relogin_begin :: proc(d: ^Data) {
	d.relogin = true
	d.login = {}
	pkce_begin(d)
}

// pkce_check validates a pasted redirect address. It returns the address
// trimmed, and what's wrong with it, or "".
pkce_check :: proc(text: string, redirect_uri: string) -> (url: string, problem: string) {
	url = strings.trim(text, " \t\r\n\"'<>")
	if url == "" {
		return url, "Paste the address first."
	}
	if len(url) > PKCE_REDIRECT_MAX {
		return url, "That address is too long to be TIDAL's."
	}
	_, err := tidal.pkce_redirect_code(url, redirect_uri)
	e, failed := err.?
	switch {
	case !failed:
		return url, ""
	case e.kind == .Authentication:
		return url, fmt.tprintf("TIDAL ended the login (%s). Try again.", tidal.error_detail(&e))
	case e.kind == .Invalid_Argument && strings.has_prefix(url, redirect_uri) && (len(url) == len(redirect_uri) || url[len(redirect_uri)] == '?' || url[len(redirect_uri)] == '/'):
		return url, "That address has no login code. Copy all of it."
	}
	return url, "That isn't the address TIDAL ends on."
}

// pkce_submit checks a pasted redirect address and sends it to a worker,
// which trades its code for tokens. Over a signed-in account (relogin),
// that account ends first, keeping its Keychain item until the new login
// replaces it.
pkce_submit :: proc(s: ^State, text: string) {
	d := &s.data
	l := &d.login
	url, problem := pkce_check(text, d.session.config.pkce_uri_redirect)
	if problem != "" {
		l.pkce = .Paste
		l.pkce_note = small(problem)
		return
	}
	if d.account == .Signed_In {
		account_end(s)
		d.relogin = false
	}
	pkce_prepare(d)
	sync.lock(&d.pkce_mutex)
	d.pkce_len = copy(d.pkce_redirect[:], url)
	sync.unlock(&d.pkce_mutex)
	sync.atomic_store(&d.device_cancel, true)
	l.pkce = .Exchanging
	l.pkce_note = {}
	push_job(d, {payload = Login_Pkce_Job{attempt = d.login_attempt}})
}

// pkce_has_tokens says whether a PKCE login got its tokens but hasn't
// loaded the account yet.
pkce_has_tokens :: proc(d: ^Data) -> bool {
	return login_has_tokens(d) && tidal.session_is_pkce(d.session)
}

// pkce_resume finishes a PKCE login with the tokens it already has. The
// Login_Pkce job sees them and loads the account instead of trading the
// spent code again.
pkce_resume :: proc(d: ^Data) {
	l := &d.login
	l.pkce = .Exchanging
	l.pkce_note = {}
	push_job(d, {payload = Login_Pkce_Job{attempt = d.login_attempt}})
}

// pkce_done takes a Login_Pkce result.
pkce_done :: proc(d: ^Data, res: ^Result, failed: bool) {
	l := &d.login
	if !failed {
		d.login = {}
		d.pkce_verifier, d.pkce_key = {}, {}
		signed_in(d)
		return
	}
	l.pkce = .Paste
	l.pkce_note = pkce_failure(res)
	if pkce_has_tokens(d) {
		return // "Try again" finishes with the tokens
	}
	// The next try opens the login page again, with a new verifier.
	d.pkce_verifier, d.pkce_key = {}, {}
	ui.field_clear(&l.field)
}

@(private = "file")
pkce_failure :: proc(res: ^Result) -> Small {
	e, _ := res.err.?
	#partial switch e {
	case .Network:
		return small("Can't reach TIDAL. Check your connection.")
	case .Authentication:
		return small("TIDAL didn't take this address. Log in with TIDAL again.")
	}
	return res.message
}

// pkce_redirect_env is TIDALFAST_PKCE_REDIRECT in debug and MOCK_API
// builds: with no saved login, the PKCE login finishes with it at start,
// for testing against tests/mock_tidal.
pkce_redirect_env :: proc() -> string {
	if !ODIN_DEBUG && !MOCK_API {
		return ""
	}
	return os.get_env("TIDALFAST_PKCE_REDIRECT", context.temp_allocator)
}
