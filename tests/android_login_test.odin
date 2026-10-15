package tidal_tests

// The Android (PKCE) login as the main login: the login screen's states,
// the device-code login's AAC notice and player bar message, and the
// stream quality fallback.

import "core:crypto"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/audio"
import "../src/jobs"
import "../src/mac"
import tidal "../src/tidal"
import "../src/ui"

@(private = "file")
REDIRECT :: "https://tidal.com/android/login/auth"

@(private = "file")
AAC_MESSAGE :: "TIDAL sent AAC for this login. Log in with TIDAL again for lossless."

@(private = "file")
quiet :: proc "c" () {}

// A State with a session that sends nothing and a Keychain item of its own.
@(private = "file")
login_state :: proc() -> ^app.State {
	s := new(app.State)
	d := &s.data
	key: u64
	crypto.rand_bytes(([^]u8)(&key)[:8])
	d.keychain = app.small(fmt.tprintf("tidalfast-test-%x", key))
	d.wake = quiet
	s.playback.index = -1
	s.library.selected = -1
	app.session_open(d)
	return s
}

@(private = "file")
login_state_free :: proc(s: ^app.State) {
	mac.keychain_delete(app.keychain_service(&s.data), app.KEYCHAIN_ACCOUNT)
	if s.playback.player != nil {
		app.playback_shutdown(s)
	}
	app.data_shutdown(s)
	free(s)
}

// queued_kinds empties the queue and returns what was in it.
@(private = "file")
queued_kinds :: proc(d: ^app.Data) -> (kinds: bit_set[app.Job_Kind; u16], jobs_out: [dynamic]app.Job) {
	jobs_out = make([dynamic]app.Job, context.temp_allocator)
	for {
		job, ok := jobs.try_pop(&d.queue)
		if !ok {
			return
		}
		kinds += {job.kind}
		append(&jobs_out, job)
	}
}

@(test)
pkce_redirect_check :: proc(t: ^testing.T) {
	good := []string {
		REDIRECT + "?code=abc&state=na",
		"  " + REDIRECT + "?code=abc \n",
		"\"" + REDIRECT + "?code=a%2Bb\"",
		REDIRECT + "/?code=abc",
	}
	for u in good {
		url, problem := app.pkce_check(u, REDIRECT)
		testing.expectf(t, problem == "", "%q: %s", u, problem)
		testing.expect(t, strings.has_prefix(url, REDIRECT))
	}
	Case :: struct {
		text, want: string,
	}
	NOT_IT :: "That isn't the address TIDAL ends on."
	NO_CODE :: "That address has no login code. Copy all of it."
	bad := []Case {
		{"", "Paste the address first."},
		{" \t\n", "Paste the address first."},
		{"https://tidal.com/browse?code=abc", NOT_IT},
		{"https://tidal.com/android/login/authx?code=abc", NOT_IT},
		{"http://tidal.com/android/login/auth?code=abc", NOT_IT},
		{"abc", NOT_IT},
		{REDIRECT, NO_CODE},
		{REDIRECT + "?state=na", NO_CODE},
		{REDIRECT + "?code=&state=na", NO_CODE},
		{REDIRECT + "?error=access_denied&state=na", "TIDAL ended the login (access_denied). Try again."},
		{fmt.tprintf("%s?code=%s", REDIRECT, strings.repeat("a", app.PKCE_REDIRECT_MAX, context.temp_allocator)), "That address is too long to be TIDAL's."},
	}
	for c in bad {
		_, problem := app.pkce_check(c.text, REDIRECT)
		testing.expectf(t, problem == c.want, "%q: got %q, want %q", c.text, problem, c.want)
	}
}

// With no saved login the screen shows the PKCE login and asks TIDAL for
// nothing. A bad address stays on the screen with a note; a good one goes
// to a worker. The code login is the other way in.
@(test)
login_screen_transitions :: proc(t: ^testing.T) {
	s := login_state()
	defer login_state_free(s)
	d := &s.data
	res := app.Result {
		job = {kind = .Restore},
	}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, d.account, app.Account.Signed_Out)
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Paste)
	testing.expect(t, app.show_login(s))
	testing.expect(t, d.pkce_verifier.len > 0, "the login page's verifier is ready")
	kinds, _ := queued_kinds(d)
	testing.expect_value(t, kinds, bit_set[app.Job_Kind; u16]{})

	app.pkce_submit(s, "https://example.com/?code=x")
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Paste)
	testing.expect_value(t, app.small_str(&d.login.pkce_note), "That isn't the address TIDAL ends on.")
	kinds, _ = queued_kinds(d)
	testing.expect_value(t, kinds, bit_set[app.Job_Kind; u16]{})

	app.pkce_submit(s, " " + REDIRECT + "?code=good&state=na\n")
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Exchanging)
	testing.expect_value(t, d.login.pkce_note.len, 0)
	testing.expect_value(t, string(d.pkce_redirect[:d.pkce_len]), REDIRECT + "?code=good&state=na")
	queued: [dynamic]app.Job
	kinds, queued = queued_kinds(d)
	testing.expect_value(t, kinds, bit_set[app.Job_Kind; u16]{.Login_Pkce})
	testing.expect_value(t, queued[0].view, d.login_attempt)

	// The exchange failed: back to an empty field, with a plain reason.
	ui.field_set_text(&d.login.field, REDIRECT + "?code=good&state=na")
	failed := app.Result {
		job = {kind = .Login_Pkce, view = d.login_attempt},
		err = .Authentication,
		message = app.small("Authentication: TIDAL didn't accept this login."),
	}
	app.handle_result(s, &failed, 0)
	testing.expect_value(t, d.account, app.Account.Signed_Out)
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Paste)
	testing.expect_value(t, app.small_str(&d.login.pkce_note), "TIDAL didn't take this address. Log in with TIDAL again.")
	testing.expect_value(t, ui_text(&d.login), "")

	before := d.login_attempt
	app.device_begin(d)
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Off)
	testing.expect(t, d.login_attempt > before)
	kinds, _ = queued_kinds(d)
	testing.expect_value(t, kinds, bit_set[app.Job_Kind; u16]{.Login_Start})
}

@(private = "file")
ui_text :: proc(l: ^app.Login) -> string {
	return string(l.field.buf[:l.field.len])
}

// A Login_Pkce the full queue refused goes out again on the next frame.
@(test)
refused_pkce_login_is_retried :: proc(t: ^testing.T) {
	s := login_state()
	defer login_state_free(s)
	d := &s.data
	d.account = .Signed_Out
	for jobs.push(&d.queue, app.Job{kind = .Tracks}, app.PRIORITY_DATA) {}
	app.pkce_submit(s, REDIRECT + "?code=c")
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Exchanging)
	testing.expect(t, .Login_Pkce in d.retry)
	_, ok := jobs.try_pop(&d.queue)
	testing.expect(t, ok)
	app.data_retry(d)
	kinds, _ := queued_kinds(d)
	testing.expect(t, .Login_Pkce in kinds)
	testing.expect(t, .Login_Pkce not_in d.retry)
}

// A saved login from the device-code client gets the AAC notice; a PKCE one
// doesn't. Logging in again over it keeps the Keychain item until the new
// login replaces it.
@(test)
device_login_notice :: proc(t: ^testing.T) {
	s := login_state()
	defer login_state_free(s)
	d := &s.data
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "a", refresh_token = "r", user_id = 123, user_kind = .Logged_In_User})
	app.auth_changed(d.session, d)

	// The Keychain item names the device client, which restores as not PKCE.
	item, status := mac.keychain_get(app.keychain_service(d), app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, status, mac.ERR_SEC_SUCCESS)
	testing.expect(t, strings.contains(string(item), fmt.tprintf(`"client_id":"%s"`, d.session.config.client_id)))
	restored := tidal.session_create()
	defer tidal.session_destroy(restored)
	testing.expect(t, app.auth_restore(restored, item))
	testing.expect(t, !tidal.session_is_pkce(restored))

	res := app.Result {
		job       = {kind = .Restore},
		signed_in = true,
	}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, d.account, app.Account.Signed_In)
	testing.expect(t, d.device_login)
	testing.expect(t, !app.show_login(s), "the user can browse")

	// "Log in with TIDAL" on the notice, as relogin_begin does without the
	// browser.
	d.relogin = true
	d.login = {}
	testing.expect(t, app.show_login(s))
	app.pkce_submit(s, REDIRECT + "?code=c")
	testing.expect_value(t, d.account, app.Account.Signed_Out)
	testing.expect(t, !d.relogin)
	testing.expect(t, !d.device_login)
	testing.expect_value(t, d.auth_gen, 1)
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "")
	_, status = mac.keychain_get(app.keychain_service(d), app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, status, mac.ERR_SEC_SUCCESS)
	kinds, queued := queued_kinds(d)
	testing.expect_value(t, kinds, bit_set[app.Job_Kind; u16]{.Login_Pkce})
	testing.expect_value(t, queued[0].auth, 1)

	// The PKCE login finished.
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "p", refresh_token = "pr", user_id = 123, user_kind = .Logged_In_User, is_pkce = true})
	done := app.Result {
		job = {kind = .Login_Pkce, view = d.login_attempt, auth = d.auth_gen},
	}
	app.handle_result(s, &done, 0)
	testing.expect_value(t, d.account, app.Account.Signed_In)
	testing.expect(t, !d.device_login)
	testing.expect(t, !app.show_login(s))
}

// A stream that comes as AAC says so in the player bar and stops there:
// every track would come the same way. Other failures skip on.
@(test)
aac_stream_message :: proc(t: ^testing.T) {
	s := login_state()
	defer login_state_free(s)
	d := &s.data
	s.playback.player = audio.create(quiet, 0, null_output = true)
	d.account = .Signed_In
	app.view_open(d, .Playlist, "pl", "pl", "", 3)
	rows := make([]app.Row, 3, context.temp_allocator)
	for &r, i in rows {
		r.title = fmt.tprintf("Track %d", i + 1)
		r.id = i64(1000 + i)
		r.seconds = 30
	}
	app.view_add_rows(&d.view, 0, len(rows), rows, len(rows))

	stream_job :: proc(d: ^app.Data) -> (app.Job, bool) {
		_, queued := queued_kinds(d)
		for job in queued {
			if job.kind == .Stream {
				return job, true
			}
		}
		return {}, false
	}

	app.playback_play_row(s, 0)
	job, ok := stream_job(d)
	testing.expect(t, ok)
	res := app.Result {
		job     = job,
		err     = .Lossy_Stream,
		message = app.small("Lossy_Stream: Not a FLAC stream (MP4A)"),
		codec   = app.small("MP4A"),
	}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, app.small_str(&s.playback.message), AAC_MESSAGE)
	testing.expect(t, s.playback.paused)
	testing.expect_value(t, s.playback.index, 0)
	_, skipped := stream_job(d)
	testing.expect(t, !skipped, "no other track is tried")

	testing.expect_value(t, app.lossy_message("EAC3"), "TIDAL sent EAC3 for this login, which TIDALfast doesn't play. Log in with TIDAL again for lossless.")

	app.playback_play_row(s, 1)
	job, ok = stream_job(d)
	testing.expect(t, ok)
	other := app.Result {
		job     = job,
		err     = .Stream_Not_Available,
		message = app.small("Stream_Not_Available: Stream not available for this track"),
	}
	app.handle_result(s, &other, 0)
	testing.expect(t, strings.has_prefix(app.small_str(&s.playback.message), "Couldn't play Track 2"))
	testing.expect_value(t, s.playback.index, 2)
}

@(private = "file")
bts_answer :: proc(quality, codec, mime: string) -> Mock_Answer {
	manifest := fmt.tprintf(`{{"mimeType":"%s","codecs":"%s","encryptionType":"NONE","urls":["http://127.0.0.1/a"]}}`, mime, codec)
	encoded, _ := base64.encode(transmute([]u8)manifest, allocator = context.temp_allocator)
	return {200, fmt.aprintf(`{{"trackId":1,"audioQuality":"%s","manifestMimeType":"application/vnd.tidal.bts","manifest":"%s","bitDepth":16,"sampleRate":44100}}`, quality, encoded)}
}

@(private = "file")
dash_answer :: proc(quality, codecs: string) -> Mock_Answer {
	mpd := fmt.tprintf(`<MPD mediaPresentationDuration="PT4S"><Period><AdaptationSet><Representation codecs="%s"><SegmentTemplate timescale="1" media="$Number$.mp4" initialization="i.mp4"><SegmentTimeline><S d="4"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`, codecs)
	encoded, _ := base64.encode(transmute([]u8)mpd, allocator = context.temp_allocator)
	return {200, fmt.aprintf(`{{"trackId":1,"audioQuality":"%s","manifestMimeType":"application/dash+xml","manifest":"%s","bitDepth":24,"sampleRate":96000}}`, quality, encoded)}
}

@(private = "file")
asked :: proc(m: ^Mock, quality: string) -> int {
	n := 0
	for r in m.requests {
		if strings.contains(r, "playbackinfopostpaywall") && strings.contains(r, fmt.tprintf("audioquality=%s", quality)) {
			n += 1
		}
	}
	return n
}

// The PKCE login asks for HI_RES_LOSSLESS and falls back to LOSSLESS when
// TIDAL refuses it; LOSSLESS may come as DASH. The device-code login asks
// for LOSSLESS only.
@(test)
stream_quality_fallback :: proc(t: ^testing.T) {
	Case :: struct {
		name:          string,
		pkce:          bool,
		hires, lossless: Mock_Answer,
		quality:       string, // what plays, "" for an error
		dash:          bool,
		refused:       Maybe(tidal.Error_Kind),
		err:           tidal.Error_Kind,
		hires_asks, lossless_asks: int,
	}
	no_hires := Mock_Answer{403, `{"status":403,"subStatus":4005,"userMessage":"Not available at this quality"}`}
	cases := []Case {
		{name = "hi-res as DASH", pkce = true, hires = dash_answer("HI_RES_LOSSLESS", "flac"), quality = "HI_RES_LOSSLESS", dash = true, hires_asks = 1},
		{name = "403, then BTS", pkce = true, hires = no_hires, lossless = bts_answer("LOSSLESS", "flac", "audio/flac"), quality = "LOSSLESS", refused = .Http, hires_asks = 1, lossless_asks = 1},
		{name = "AAC, then DASH", pkce = true, hires = dash_answer("HI_RES_LOSSLESS", "mp4a.40.2"), lossless = dash_answer("LOSSLESS", "flac"), quality = "LOSSLESS", dash = true, refused = .Lossy_Stream, hires_asks = 1, lossless_asks = 1},
		{name = "404, then BTS", pkce = true, hires = {404, `{"status":404,"userMessage":"not found"}`}, lossless = bts_answer("LOSSLESS", "flac", "audio/flac"), quality = "LOSSLESS", refused = .Stream_Not_Available, hires_asks = 1, lossless_asks = 1},
		{name = "a 500 isn't a refusal", pkce = true, hires = {500, `{"status":500}`}, err = .Http, hires_asks = 1},
		{name = "device client", pkce = false, lossless = bts_answer("LOSSLESS", "mp4a.40.2", "audio/mp4"), err = .Lossy_Stream, lossless_asks = 1},
	}
	for c in cases {
		m: Mock
		mock_start(&m)
		if c.hires.status != 0 {
			m.playback["HI_RES_LOSSLESS"] = c.hires
		}
		if c.lossless.status != 0 {
			m.playback["LOSSLESS"] = c.lossless
		}
		s := tidal.session_create()
		s.config.api_v1_location = m.base_url
		s.config.api_oauth2_token = fmt.tprintf("%stoken", m.base_url)
		tidal.session_restore(s, {token_type = "Bearer", access_token = "a", refresh_token = "r", user_id = 123, user_kind = .Logged_In_User, country_code = "PL", is_pkce = c.pkce})
		info, refused, err := tidal.resolve_stream_flac(s, 1, context.temp_allocator)
		if c.quality != "" {
			testing.expectf(t, err == nil, "%s: %v", c.name, err)
			testing.expectf(t, info.quality == c.quality, "%s: quality %s", c.name, info.quality)
			testing.expectf(t, info.dash == c.dash, "%s: dash %v", c.name, info.dash)
			testing.expectf(t, info.codec == "FLAC", "%s: codec %s", c.name, info.codec)
		} else {
			kind, _ := tidal.error_kind(err)
			testing.expectf(t, kind == c.err, "%s: error %v", c.name, err)
		}
		rkind, has_refused := tidal.error_kind(refused)
		want, want_refused := c.refused.?
		testing.expectf(t, has_refused == want_refused && rkind == want, "%s: refused %v", c.name, refused)
		if c.name == "device client" {
			e, _ := err.?
			testing.expect_value(t, tidal.error_detail(&e), "MP4A")
		}
		testing.expectf(t, asked(&m, "HI_RES_LOSSLESS") == c.hires_asks, "%s: asked for HI_RES_LOSSLESS %d times", c.name, asked(&m, "HI_RES_LOSSLESS"))
		testing.expectf(t, asked(&m, "LOSSLESS") == c.lossless_asks, "%s: asked for LOSSLESS %d times", c.name, asked(&m, "LOSSLESS"))
		tidal.session_destroy(s)
		mock_stop(&m)
	}
}
