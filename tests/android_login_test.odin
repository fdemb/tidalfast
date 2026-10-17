package tidal_tests

// The Android (PKCE) login as the main login: the login screen's states,
// the device-code login's AAC notice and player bar message, and the
// stream quality fallback.

import "base:runtime"
import "core:crypto"
import "core:encoding/base64"
import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/jobs"
import "../src/os_services"
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
	os_services.secret_delete(app.keychain_service(&s.data), app.KEYCHAIN_ACCOUNT)
	if s.playback.player != nil {
		app.workers_stop(&s.data)
		app.playback_shutdown(s)
	}
	app.data_shutdown(s)
	free(s)
}

// queued_kinds empties the queue and returns what was in it, and the
// payload types of those jobs.
@(private = "file")
queued_kinds :: proc(d: ^app.Data) -> (kinds: []typeid, jobs_out: [dynamic]app.Job) {
	jobs_out = make([dynamic]app.Job, context.temp_allocator)
	types := make([dynamic]typeid, context.temp_allocator)
	for {
		job, ok := jobs.try_pop(&d.queue)
		if !ok {
			return types[:], jobs_out
		}
		if !slice.contains(types[:], reflect.union_variant_typeid(job.payload)) {
			append(&types, reflect.union_variant_typeid(job.payload))
		}
		append(&jobs_out, job)
	}
}

@(private = "file")
expect_kinds :: proc(t: ^testing.T, kinds: []typeid, want: ..typeid, loc := #caller_location) {
	same := len(kinds) == len(want)
	for k in want {
		same &&= slice.contains(kinds, k)
	}
	testing.expectf(t, same, "queued %v, want %v", kinds, want, loc = loc)
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
		job = {payload = app.Restore_Job{}},
	}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, d.account, app.Account.Signed_Out)
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Paste)
	testing.expect(t, app.show_login(s))
	testing.expect(t, d.pkce_verifier.len > 0, "the login page's verifier is ready")
	kinds, _ := queued_kinds(d)
	expect_kinds(t, kinds)

	app.pkce_submit(s, "https://example.com/?code=x")
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Paste)
	testing.expect_value(t, app.small_str(&d.login.pkce_note), "That isn't the address TIDAL ends on.")
	kinds, _ = queued_kinds(d)
	expect_kinds(t, kinds)

	app.pkce_submit(s, " " + REDIRECT + "?code=good&state=na\n")
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Exchanging)
	testing.expect_value(t, d.login.pkce_note.len, 0)
	testing.expect_value(t, string(d.pkce_redirect[:d.pkce_len]), REDIRECT + "?code=good&state=na")
	queued: [dynamic]app.Job
	kinds, queued = queued_kinds(d)
	expect_kinds(t, kinds, app.Login_Pkce_Job)
	testing.expect_value(t, queued[0].payload.(app.Login_Pkce_Job).attempt, d.login_attempt)

	// The exchange failed: back to an empty field, with a plain reason.
	ui.field_set_text(&d.login.field, REDIRECT + "?code=good&state=na")
	failed := app.Result {
		job = {payload = app.Login_Pkce_Job{attempt = d.login_attempt}},
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
	expect_kinds(t, kinds, app.Login_Start_Job)
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
	for jobs.push(&d.queue, app.Job{payload = app.Tracks_Job{}}, app.PRIORITY_DATA) {}
	app.pkce_submit(s, REDIRECT + "?code=c")
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Exchanging)
	_, ok := jobs.try_pop(&d.queue)
	testing.expect(t, ok)
	app.data_retry(d)
	kinds, _ := queued_kinds(d)
	testing.expect(t, slice.contains(kinds, app.Login_Pkce_Job))
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
	item, status := os_services.secret_get(app.keychain_service(d), app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, status, os_services.SECRET_OK)
	testing.expect(t, strings.contains(string(item), fmt.tprintf(`"client_id":"%s"`, d.session.config.client_id)))
	restored := tidal.session_create()
	defer tidal.session_destroy(restored)
	testing.expect(t, app.auth_restore(restored, item))
	testing.expect(t, !tidal.session_is_pkce(restored))

	res := app.Result {
		job       = {payload = app.Restore_Job{}},
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
	_, status = os_services.secret_get(app.keychain_service(d), app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, status, os_services.SECRET_OK)
	kinds, queued := queued_kinds(d)
	expect_kinds(t, kinds, app.Login_Pkce_Job)
	testing.expect_value(t, queued[0].auth, 1)

	// The PKCE login finished.
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "p", refresh_token = "pr", user_id = 123, user_kind = .Logged_In_User, is_pkce = true})
	done := app.Result {
		job = {auth = d.auth_gen, payload = app.Login_Pkce_Job{attempt = d.login_attempt}},
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
			if _, stream := job.payload.(app.Stream_Job); stream {
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
	return {200, fmt.tprintf(`{{"trackId":1,"audioQuality":"%s","manifestMimeType":"application/vnd.tidal.bts","manifest":"%s","bitDepth":16,"sampleRate":44100}}`, quality, encoded)}
}

@(private = "file")
dash_answer :: proc(quality, codecs: string) -> Mock_Answer {
	mpd := fmt.tprintf(`<MPD mediaPresentationDuration="PT4S"><Period><AdaptationSet><Representation codecs="%s"><SegmentTemplate timescale="1" media="$Number$.mp4" initialization="i.mp4"><SegmentTimeline><S d="4"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`, codecs)
	encoded, _ := base64.encode(transmute([]u8)mpd, allocator = context.temp_allocator)
	return {200, fmt.tprintf(`{{"trackId":1,"audioQuality":"%s","manifestMimeType":"application/dash+xml","manifest":"%s","bitDepth":24,"sampleRate":96000}}`, quality, encoded)}
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

// The code login asked TIDAL for a code, and the user went back to the
// PKCE login before TIDAL answered. The late answer leaves the PKCE login
// on screen and polls nothing. If the user is back on the code login by
// then, it asks for a code of its own.
@(test)
stale_login_start_is_dropped :: proc(t: ^testing.T) {
	s := login_state()
	defer login_state_free(s)
	d := &s.data
	d.account = .Signed_Out
	answer :: proc(job: app.Job) -> app.Result {
		return {job = job, link = {user_code = app.small("ABCDE"), device_code = app.small("dc"), interval = 1, expires = 300}}
	}
	start_job :: proc(t: ^testing.T, d: ^app.Data) -> app.Job {
		kinds, queued := queued_kinds(d)
		expect_kinds(t, kinds, app.Login_Start_Job)
		if len(queued) == 0 {
			return {}
		}
		testing.expect_value(t, queued[0].payload.(app.Login_Start_Job).attempt, d.login_attempt)
		return queued[0]
	}

	app.device_begin(d)
	first := start_job(t, d)
	app.pkce_show(d)
	late := answer(first)
	app.handle_result(s, &late, 0)
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Paste)
	testing.expect_value(t, d.login.link.device_code.len, 0)
	kinds, _ := queued_kinds(d)
	expect_kinds(t, kinds)

	app.device_begin(d)
	second := start_job(t, d)
	app.pkce_show(d)
	app.device_begin(d)
	kinds, _ = queued_kinds(d)
	expect_kinds(t, kinds)
	stale := answer(second)
	app.handle_result(s, &stale, 0)
	testing.expect_value(t, d.login.link.device_code.len, 0)
	third := start_job(t, d)

	fresh := answer(third)
	app.handle_result(s, &fresh, 0)
	testing.expect_value(t, d.login.pkce, app.Pkce_Step.Off)
	testing.expect_value(t, app.small_str(&d.login.link.user_code), "ABCDE")
	kinds, _ = queued_kinds(d)
	expect_kinds(t, kinds, app.Login_Wait_Job)
}

// stream_jobs empties the queue and returns the Stream jobs in it.
@(private = "file")
stream_jobs :: proc(d: ^app.Data) -> [dynamic]app.Job {
	out := make([dynamic]app.Job, context.temp_allocator)
	_, queued := queued_kinds(d)
	for job in queued {
		if _, stream := job.payload.(app.Stream_Job); stream {
			append(&out, job)
		}
	}
	return out
}

// The next track's stream fails to resolve while the current one plays.
// The player keeps asking for a next track, but that one isn't asked for
// again until it's current. Then it's tried once, the player bar says why,
// and the queue skips on.
@(test)
failed_prefetch_is_not_retried :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	file, _ := test_flac(200, 0) // 5.2 s
	m.files["/a.flac"] = file
	s := login_state()
	defer login_state_free(s)
	d := &s.data
	pb := &s.playback
	pb.player = audio.create(quiet, 0, null_output = true)
	d.account = .Signed_In
	app.view_open(d, .Playlist, "pl", "pl", "", 3)
	rows := make([]app.Row, 3, context.temp_allocator)
	for &r, i in rows {
		r.title = fmt.tprintf("Track %d", i + 1)
		r.id = i64(1000 + i)
		r.seconds = 5
	}
	app.view_add_rows(&d.view, 0, len(rows), rows, len(rows))

	app.playback_play_row(s, 0)
	queued := stream_jobs(d)
	testing.expect_value(t, len(queued), 1)
	if len(queued) != 1 {
		return
	}
	resolved := app.Result {
		job = queued[0],
		stream = {track_id = 1000, quality = "LOSSLESS", codec = "FLAC", url = fmt.tprintf("%sa.flac", m.base_url), sample_rate = 44100, bit_depth = 16, track_peak = 1, album_peak = 1},
	}
	app.handle_result(s, &resolved, 0)

	// The whole file is in at once, so the player asks for the next track.
	next: app.Job
	start := time.tick_now()
	for next.payload == nil && time.tick_since(start) < 3 * time.Second {
		app.playback_update(s, nil)
		for job in stream_jobs(d) {
			next = job
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, next.payload.(app.Stream_Job).track, 1001)
	failed := app.Result {
		job     = next,
		err     = .Stream_Not_Available,
		message = app.small("Stream_Not_Available: Stream not available for this track"),
	}
	app.handle_result(s, &failed, 0)

	asked := 0
	start = time.tick_now()
	for time.tick_since(start) < 500 * time.Millisecond {
		app.playback_update(s, nil)
		asked += len(stream_jobs(d))
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, asked, 0)
	testing.expect(t, pb.status.want_next, "the player still wants a next track")
	testing.expect_value(t, pb.index, 0)

	// Track one ends and track two is current: one more try.
	app.playback_seek(s, 5.1)
	start = time.tick_now()
	for pb.index == 0 && time.tick_since(start) < 3 * time.Second {
		app.playback_update(s, nil)
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, pb.index, 1)
	queued = stream_jobs(d)
	testing.expect_value(t, len(queued), 1)
	if len(queued) != 1 {
		return
	}
	testing.expect_value(t, queued[0].payload.(app.Stream_Job).track, 1001)
	again := failed
	again.job = queued[0]
	app.handle_result(s, &again, 0)
	testing.expect(t, strings.has_prefix(app.small_str(&pb.message), "Couldn't play Track 2"))
	testing.expect_value(t, pb.index, 2)
	queued = stream_jobs(d)
	testing.expect_value(t, len(queued), 1)
	if len(queued) == 1 {
		testing.expect_value(t, queued[0].payload.(app.Stream_Job).track, 1002)
	}
}

@(private = "file")
capture_log :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	b := (^strings.Builder)(data)
	strings.write_string(b, text)
	strings.write_byte(b, '\n')
}

// Error bodies are server text and may hold a signed URL. Neither the
// app's stream error line nor what src/tidal logs on the way may print
// them: only the kind, the HTTP status, the subStatus and a known codec.
@(test)
stream_errors_log_no_server_text :: proc(t: ^testing.T) {
	URL :: "https://cdn.example/audio?token=FAKE-SIGNED-SECRET"
	Case :: struct {
		name:   string,
		answer: Mock_Answer,
		want:   string, // in the app's line
	}
	cases := []Case {
		{"userMessage", {500, `{"status":500,"subStatus":1234,"userMessage":"` + URL + `"}`}, "Http, HTTP 500, subStatus 1234"},
		{"errors detail", {500, `{"errors":[{"detail":"` + URL + `"}]}`}, "Http, HTTP 500"},
		{"not JSON", {502, `<html>` + URL + `</html>`}, "Http, HTTP 502"},
		{"anti-abuse", {403, `abuse detected ` + URL}, "Abuse_Detected, HTTP 403"},
		{"codec", dash_answer("HI_RES_LOSSLESS", URL), "Lossy_Stream, codec unknown"},
	}
	for c in cases {
		m: Mock
		mock_start(&m)
		m.playback["HI_RES_LOSSLESS"] = c.answer
		m.playback["LOSSLESS"] = c.answer
		// Not the temp allocator: log.logf frees what's allocated from it
		// while the logger runs.
		log := strings.builder_make()
		s := tidal.session_create()
		s.config.api_v1_location = m.base_url
		s.config.api_oauth2_token = fmt.tprintf("%stoken", m.base_url)
		tidal.session_restore(s, {token_type = "Bearer", access_token = "a", refresh_token = "r", user_id = 123, user_kind = .Logged_In_User, country_code = "PL", is_pkce = true})
		// Only around the request: the test's own failures go to the
		// runner's logger.
		runner := context.logger
		context.logger = {capture_log, &log, .Debug, {}}
		_, refused, err := tidal.resolve_stream_flac(s, 1, context.temp_allocator)
		context.logger = runner
		testing.expectf(t, err != nil, "%s: resolved", c.name)
		line := app.stream_error_line(1, "failed", err, context.temp_allocator)
		testing.expectf(t, strings.contains(line, c.want), "%s: %q", c.name, line)
		if refused != nil {
			strings.write_string(&log, app.stream_error_line(1, "refused", refused, context.temp_allocator))
			strings.write_byte(&log, '\n')
		}
		strings.write_string(&log, line)
		all := strings.to_lower(strings.to_string(log), context.temp_allocator)
		testing.expectf(t, !strings.contains(all, "fake-signed-secret") && !strings.contains(all, "cdn.example"), "%s: logged %q", c.name, strings.to_string(log))
		tidal.session_destroy(s)
		mock_stop(&m)
		strings.builder_destroy(&log)
		if c.name == "codec" {
			delete(c.answer.body) // dash_answer's
		}
	}
	testing.expect_value(t, tidal.codec_name("mp4a.40.2"), "MP4A")
	testing.expect_value(t, tidal.codec_name("flac"), "FLAC")
	testing.expect_value(t, tidal.quality_name("HI_RES_LOSSLESS"), "HI_RES_LOSSLESS")
	testing.expect_value(t, tidal.quality_name(URL), "unknown")
}

// Playing a track with a cover asks for its Now Playing artwork at 640 px.
// The shared cover pages split the job's size into the size drawn and the
// size downloaded, and artwork used to download at size 0.
@(test)
artwork_downloads_at_its_size :: proc(t: ^testing.T) {
	s := login_state()
	defer login_state_free(s)
	d := &s.data
	pb := &s.playback
	pb.player = audio.create(quiet, 0, null_output = true)
	d.account = .Signed_In
	app.view_open(d, .Playlist, "pl", "pl", "", 1)
	rows := make([]app.Row, 1, context.temp_allocator)
	rows[0] = {title = "Track", id = 1000, seconds = 5, cover = "aa-bb-cc"}
	app.view_add_rows(&d.view, 0, len(rows), rows, len(rows))

	app.playback_play_row(s, 0)
	_, queued := queued_kinds(d)
	found := false
	for job in queued {
		if p, artwork := job.payload.(app.Artwork_Job); artwork {
			found = true
			testing.expect_value(t, app.fetch_size(p.image), 640)
		}
	}
	testing.expect(t, found, "playing a track with a cover queues its artwork")
}
