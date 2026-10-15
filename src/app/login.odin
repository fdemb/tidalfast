package app

// The login screen for TIDAL's device-code login: the app asks TIDAL for a
// short code, the user enters it at link.tidal.com (or opens the link with
// the code in it), and a worker polls until they approve.
//
// "Log in for hi-res" runs the PKCE login of TIDAL's Android client instead,
// the only one TIDAL gives hi-res streams: the login page opens in the
// browser, which ends on an "Oops" page whose address holds a one-time
// code. The user copies that address and clicks "Paste the address", which
// reads the clipboard. A worker trades the code for tokens. This stands in
// for a text field until there is one.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

import "../mac"
import "../render"
import "../text"
import "../tidal"
import "../ui"

LOGIN_W :: 440
LOGIN_H :: 380

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
	if l.pkce != .Off {
		pkce_card(s)
		return
	}
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
		ui.spacer(ui.px(14))
		hires_button(s)
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
		ui.spacer(ui.px(14))
		hires_button(s)
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

@(private = "file")
hires_button :: proc(s: ^State) {
	ui.row("", {}, ui.fill(), ui.px(32))
	ui.spacer(ui.fill())
	if pill_button("hires", "Log in for hi-res", 200, SURFACE_ACTIVE, TEXT) {
		pkce_begin(&s.data)
	}
	ui.spacer(ui.fill())
}

@(private = "file")
pkce_card :: proc(s: ^State) {
	d := &s.data
	l := &d.login
	line("Log in for hi-res", .Bold, 24, 34, TEXT)
	ui.spacer(ui.px(12))
	if l.pkce == .Exchanging {
		line("Logging you in…", .Regular, 14, 20, SECONDARY)
		return
	}
	if pkce_has_tokens(d) {
		// The code is spent; the tokens it got finish the login.
		line("TIDAL accepted the login, but your account didn't load.", .Regular, 14, 20, SECONDARY)
		ui.spacer(ui.px(18))
		{
			ui.row("", {}, ui.fill(), ui.px(40))
			ui.spacer(ui.fill())
			if pill_button("pkce_retry", "Try again", 160, ACCENT, PANEL) {
				pkce_resume(d)
			}
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(12))
		line(small_str(&l.pkce_note), .Regular, 12, 18, PLAYBACK_ERROR)
		return
	}
	line("Log in on the TIDAL page in your browser.", .Regular, 14, 20, SECONDARY)
	line("It ends on a page that says Oops.", .Regular, 14, 20, SECONDARY)
	line("Copy that page's address, then come back here.", .Regular, 14, 20, SECONDARY)
	ui.spacer(ui.px(18))
	{
		ui.row("", {}, ui.fill(), ui.px(40))
		ui.spacer(ui.fill())
		if pill_button("paste", "Paste the address", 220, ACCENT, PANEL) {
			text := pkce_redirect_env()
			if text == "" {
				text = mac.clipboard_text(context.temp_allocator)
			}
			pkce_submit(d, text)
		}
		ui.spacer(ui.fill())
	}
	ui.spacer(ui.px(12))
	note := small_str(&l.pkce_note)
	line(note if note != "" else fmt.tprintf("The address starts with %s", d.session.config.pkce_uri_redirect), .Regular, 12, 18, PLAYBACK_ERROR if note != "" else DIM)
	ui.spacer(ui.px(14))
	{
		ui.row("", {}, ui.fill(), ui.px(32))
		ui.spacer(ui.fill())
		if pill_button("reopen", "Open the page again", 180, SURFACE_ACTIVE, TEXT) {
			pkce_begin(d)
		}
		ui.spacer(ui.px(10))
		if pill_button("back", "Use a code instead", 180, SURFACE_ACTIVE, TEXT) {
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
		ui.spacer(ui.fill())
	}
}

// pkce_begin opens TIDAL's login page for the PKCE client in the browser.
// The verifier is kept in Data, so a hot reload doesn't lose it. The
// device-code poll stops; going back starts it again.
pkce_begin :: proc(d: ^Data) {
	l := &d.login
	if d.pkce_verifier.len == 0 {
		// A fresh verifier for each login.
		verifier, key := tidal.pkce_new_state(context.temp_allocator)
		d.pkce_verifier = small(verifier)
		d.pkce_key = small(key)
	}
	tidal.session_set_pkce_state(d.session, small_str(&d.pkce_verifier), small_str(&d.pkce_key))
	login_next_attempt(d)
	sync.atomic_store(&d.device_cancel, true)
	l.pkce = .Paste
	l.pkce_note = {}
	mac.open_url(tidal.pkce_login_url(d.session, context.temp_allocator))
}

// pkce_submit checks a pasted redirect address and sends it to a worker,
// which trades its code for tokens.
pkce_submit :: proc(d: ^Data, text: string) {
	l := &d.login
	url := strings.trim_space(text)
	if _, err := tidal.pkce_redirect_code(url, d.session.config.pkce_uri_redirect); err != nil {
		l.pkce = .Paste
		l.pkce_note = small("The clipboard is empty. Copy the Oops page's address first." if url == "" else tidal.error_string(err, context.temp_allocator))
		return
	}
	if len(url) > len(d.pkce_redirect) {
		l.pkce = .Paste
		l.pkce_note = small("That address is too long to be TIDAL's.")
		return
	}
	sync.lock(&d.pkce_mutex)
	d.pkce_len = copy(d.pkce_redirect[:], url)
	sync.unlock(&d.pkce_mutex)
	sync.atomic_store(&d.device_cancel, true)
	l.pkce = .Exchanging
	l.pkce_note = {}
	if !push_job(d, {kind = .Login_Pkce, view = d.login_attempt}) {
		l.pkce = .Paste
		l.pkce_note = small("Busy. Try again.")
	}
}

// pkce_has_tokens says whether a hi-res login got its tokens but hasn't
// loaded the account yet.
pkce_has_tokens :: proc(d: ^Data) -> bool {
	return login_has_tokens(d) && tidal.session_is_pkce(d.session)
}

// pkce_resume finishes a hi-res login with the tokens it already has. The
// Login_Pkce job sees them and loads the account instead of trading the
// spent code again.
pkce_resume :: proc(d: ^Data) {
	l := &d.login
	l.pkce = .Exchanging
	l.pkce_note = {}
	if !push_job(d, {kind = .Login_Pkce, view = d.login_attempt}) {
		l.pkce = .Paste
		l.pkce_note = small("Busy. Try again.")
	}
}

// pkce_done takes a Login_Pkce result.
pkce_done :: proc(d: ^Data, res: ^Result, failed: bool) {
	l := &d.login
	if !failed {
		d.login = {}
		d.pkce_verifier, d.pkce_key = {}, {}
		d.account = .Signed_In
		request_playlists(d)
		return
	}
	l.pkce = .Paste
	l.pkce_note = res.message
	if pkce_has_tokens(d) {
		return // "Try again" finishes with the tokens
	}
	// The next try opens the login page again, with a new verifier.
	d.pkce_verifier, d.pkce_key = {}, {}
}

// pkce_redirect_env is TIDALFAST_PKCE_REDIRECT in debug builds: what
// "Paste the address" uses instead of the clipboard, and, with no saved
// login, finishes the hi-res login with at start, for testing against
// tests/mock_tidal.
pkce_redirect_env :: proc() -> string {
	if !ODIN_DEBUG {
		return ""
	}
	return os.get_env("TIDALFAST_PKCE_REDIRECT", context.temp_allocator)
}
