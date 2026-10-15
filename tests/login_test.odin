package tidal_tests

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"
import "core:time"

import app "../src/app"
import "../src/cover"
import "../src/jobs"
import "../src/mac"
import "../src/platform"
import tidal "../src/tidal"

@(private = "file")
oauth_session :: proc(m: ^Mock) -> ^tidal.Session {
	s := tidal.session_create()
	s.config.api_v1_location = m.base_url
	s.config.api_oauth2_token = fmt.tprintf("%stoken", m.base_url)
	s.config.api_device_auth = fmt.tprintf("%sdevice", m.base_url)
	return s
}

@(test)
device_login_rate_limit_starts_backoff :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	m.device_status = 429

	_, err := tidal.login_device_start(s, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Too_Many_Requests), fmt.tprint(err))
	wait := tidal.backoff_remaining(s)
	testing.expect(t, wait > 0.8 && wait <= 1, fmt.tprint(wait))

	// The second try waits for Retry-After instead of reaching TIDAL.
	_, err = tidal.login_device_start(s, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Backing_Off), fmt.tprint(err))
	testing.expect_value(t, mock_count(&m, "POST /device"), 1)
}

@(test)
refresh_rate_limit_is_not_an_auth_failure :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	tidal.session_restore(s, {token_type = "Bearer", access_token = "old", refresh_token = "refresh-0", user_id = 123, user_kind = .Logged_In_User})

	m.token_status = 503
	_, err := tidal.token_refresh(s, "refresh-0")
	testing.expect(t, tidal.is_error(err, .Refresh_Failed), fmt.tprint(err))

	m.token_status = 429
	_, err = tidal.token_refresh(s, "refresh-0")
	testing.expect(t, tidal.is_error(err, .Too_Many_Requests), fmt.tprint(err))
	testing.expect(t, tidal.backoff_remaining(s) > 0.5)
	_, err = tidal.token_refresh(s, "refresh-0")
	testing.expect(t, tidal.is_error(err, .Backing_Off), fmt.tprint(err))
	testing.expect_value(t, mock_count(&m, "POST /token"), 2)

	// Only TIDAL turning the refresh token down ends the login.
	time.sleep(1100 * time.Millisecond)
	m.token_status = 400
	m.token_error = "invalid_grant"
	_, err = tidal.token_refresh(s, "refresh-0")
	testing.expect(t, tidal.is_error(err, .Authentication), fmt.tprint(err))
	testing.expect_value(t, tidal.session_auth(s, context.temp_allocator).refresh_token, "refresh-0")
}

// Only 400 or 401 with an OAuth error that refuses the refresh token ends
// the login. Anything else keeps the tokens.
@(test)
refresh_keeps_tokens_unless_refused :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	tidal.session_restore(s, {token_type = "Bearer", access_token = "old", refresh_token = "refresh-0", user_id = 123, user_kind = .Logged_In_User})

	Case :: struct {
		status:  int,
		error:   string,
		refused: bool,
	}
	cases := []Case {
		{408, "", false},
		{400, "", false},
		{400, "invalid_request", false},
		{401, "", false},
		{403, "invalid_grant", false},
		{400, "invalid_grant", true},
		{401, "invalid_grant", true},
		{401, "invalid_client", false},
	}
	for c in cases {
		m.token_status = c.status
		m.token_error = c.error
		_, err := tidal.token_refresh(s, "refresh-0")
		testing.expect(t, err != nil, fmt.tprint(c))
		testing.expect_value(t, tidal.is_error(err, .Authentication), c.refused)
		testing.expect_value(t, tidal.is_error(err, .Refresh_Failed), !c.refused)
		a := tidal.session_auth(s, context.temp_allocator)
		testing.expect_value(t, a.refresh_token, "refresh-0")
		testing.expect_value(t, a.access_token, "old")
	}

	// No answer at all is temporary too.
	s.config.api_oauth2_token = "http://127.0.0.1:1/token"
	_, err := tidal.token_refresh(s, "refresh-0")
	testing.expect(t, tidal.is_error(err, .Refresh_Failed), fmt.tprint(err))
}

// The token expired and the refresh timed out, then TIDAL answers the
// request with a plain 401. The refresh failure comes back, not the 401,
// so the login stays.
@(test)
expired_token_with_failed_refresh_keeps_the_login :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	expired := time.time_add(time.now(), -time.Minute)
	tidal.session_restore(s, {token_type = "Bearer", access_token = "old", refresh_token = "refresh-0", expiry_time = expired, user_id = 123, user_kind = .Logged_In_User})

	m.token_status = 408
	_, err := tidal.request(s, {method = .GET, path = "refused"}, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Refresh_Failed), fmt.tprint(err))
	testing.expect_value(t, mock_count(&m, "POST /token"), 1)

	// Refused for good, the 401 stands.
	m.token_status = 400
	m.token_error = "invalid_grant"
	_, err = tidal.request(s, {method = .GET, path = "refused"}, context.temp_allocator)
	testing.expect(t, !tidal.is_error(err, .Refresh_Failed), fmt.tprint(err))
	e, _ := err.?
	testing.expect_value(t, e.status, 401)
}

@(test)
device_wait_honours_interval_and_slow_down :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	s.config.api_oauth2_token = fmt.tprintf("%sdevice_token", m.base_url)

	// One check: slow_down makes the interval longer for the caller's
	// next poll.
	m.polls = {"slow_down"}
	link := tidal.Link_Login {
		device_code = "dc",
		interval    = 0.2,
		expires_in  = 60,
	}
	err := tidal.login_device_wait(s, &link, until_expiry = false)
	testing.expect(t, tidal.is_error(err, .Timeout), fmt.tprint(err))
	testing.expect_value(t, link.interval, 0.2 + tidal.SLOW_DOWN_STEP)

	// Polls wait the interval TIDAL gave between them.
	m.polls = {"pending", "pending", "ok"}
	m.poll_count = 0
	link.interval = 0.2
	start := time.tick_now()
	err = tidal.login_device_wait(s, &link)
	took := time.duration_seconds(time.tick_since(start))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.poll_count, 3)
	testing.expect(t, took >= 0.4, fmt.tprint(took))
	a := tidal.session_auth(s, context.temp_allocator)
	testing.expect_value(t, a.access_token, "device-access")
	testing.expect_value(t, a.user_id, 123)

	m.polls = {"denied"}
	m.poll_count = 0
	err = tidal.login_device_wait(s, &link)
	testing.expect(t, tidal.is_error(err, .Authentication), fmt.tprint(err))

	// A 429 ends the wait with the backoff running, instead of polling on.
	m.polls = {"429"}
	m.poll_count = 0
	err = tidal.login_device_wait(s, &link)
	testing.expect(t, tidal.is_error(err, .Too_Many_Requests), fmt.tprint(err))
	testing.expect(t, tidal.backoff_remaining(s) > 0.5)
	testing.expect_value(t, m.poll_count, 1)
}

@(test)
clear_auth_cancels_requests_in_flight :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	tidal.session_restore(s, {token_type = "Bearer", access_token = "a", refresh_token = "r", user_id = 123, user_kind = .Logged_In_User})

	Shared :: struct {
		s:    ^tidal.Session,
		err:  tidal.Error,
		took: f64,
	}
	sh := Shared {
		s = s,
	}
	worker := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		start := time.tick_now()
		_, sh.err = tidal.request(sh.s, {method = .GET, path = "slow"}, context.temp_allocator)
		sh.took = time.duration_seconds(time.tick_since(start))
	})
	time.sleep(200 * time.Millisecond)
	tidal.session_clear_auth(s)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, tidal.is_error(sh.err, .Cancelled), fmt.tprint(sh.err))
	testing.expect(t, sh.took < 1.9, fmt.tprint(sh.took))
	a := tidal.session_auth(s, context.temp_allocator)
	testing.expect_value(t, a.access_token, "")
	testing.expect_value(t, a.user_id, 0)
}

@(test)
clear_auth_drops_a_refresh_in_flight :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	tidal.session_restore(s, {token_type = "Bearer", access_token = "a", refresh_token = "refresh-0", user_id = 123, user_kind = .Logged_In_User})
	m.token_delay = 500 * time.Millisecond

	Shared :: struct {
		s:   ^tidal.Session,
		err: tidal.Error,
	}
	sh := Shared {
		s = s,
	}
	worker := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		_, sh.err = tidal.token_refresh(sh.s, "refresh-0")
	})
	time.sleep(100 * time.Millisecond)
	tidal.session_clear_auth(s)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, tidal.is_error(sh.err, .Cancelled), fmt.tprint(sh.err))
	testing.expect_value(t, tidal.session_auth(s, context.temp_allocator).refresh_token, "")
}

@(test)
queue_keeps_room_for_popped_jobs :: proc(t: ^testing.T) {
	q: jobs.Queue(Test_Job, 2)
	testing.expect(t, jobs.push(&q, {1}))
	testing.expect(t, jobs.push(&q, {2}))
	first, ticket, _ := jobs.pop_wait(&q)
	// The popped job still holds its slot, so the UI can't fill it...
	testing.expect_value(t, jobs.room(&q), 0)
	testing.expect(t, !jobs.push(&q, {3}))
	// ...and the job cut short always goes back.
	jobs.stop(&q)
	jobs.requeue(&q, first, ticket)
	queued, busy := jobs.pending(&q)
	testing.expect_value(t, queued, 2)
	testing.expect_value(t, busy, 0)
	jobs.start(&q)
	again, _, _ := jobs.pop_wait(&q)
	testing.expect_value(t, again.id, 1)
	jobs.done(&q)
	testing.expect_value(t, jobs.room(&q), 1)
}

@(private = "file")
test_keychain_service :: proc() -> string {
	key: u64
	crypto.rand_bytes(([^]u8)(&key)[:8])
	return fmt.tprintf("tidalfast-test-%x", key)
}

// A State for data tests: no renderer, no workers, a session that sends
// nothing unless a test asks, and a Keychain service of its own.
@(private = "file")
data_state :: proc() -> ^app.State {
	s := new(app.State)
	d := &s.data
	d.keychain = app.small(test_keychain_service())
	app.session_open(d)
	return s
}

@(private = "file")
data_state_free :: proc(s: ^app.State) {
	mac.keychain_delete(app.keychain_service(&s.data), app.KEYCHAIN_ACCOUNT)
	app.data_shutdown(s)
	free(s)
}

@(private = "file")
fail_job :: proc(d: ^app.Data, kind: tidal.Error_Kind) -> app.Result {
	job, _, ok := jobs.pop_wait(&d.queue)
	assert(ok)
	jobs.done(&d.queue)
	return {job = job, err = kind, message = app.small("Authentication: 401")}
}

@(test)
auth_failures_sign_out_once :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	service := app.keychain_service(d)
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "old", refresh_token = "old-r", user_id = 123, user_kind = .Logged_In_User})
	d.account = .Signed_In
	app.auth_changed(d.session, d)
	_, status := mac.keychain_get(service, app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, status, mac.ERR_SEC_SUCCESS)

	// Two requests under the old login, both refused.
	app.push_job(d, {kind = .Playlists})
	app.push_job(d, {kind = .Tracks})
	first := fail_job(d, .Authentication)
	second := fail_job(d, .Authentication)

	app.handle_result(s, &first, 0)
	testing.expect_value(t, d.auth_gen, 1)
	testing.expect_value(t, d.account, app.Account.Signed_Out)
	_, status = mac.keychain_get(service, app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, status, mac.ERR_SEC_ITEM_NOT_FOUND)
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "")
	queued, _ := jobs.pending(&d.queue)
	testing.expect_value(t, queued, 1)
	login, _ := jobs.try_pop(&d.queue)
	testing.expect_value(t, login.kind, app.Job_Kind.Login_Start)
	testing.expect_value(t, login.auth, 1)

	// The new login is saved before the second failure arrives.
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "new", refresh_token = "new-r", user_id = 123, user_kind = .Logged_In_User})
	app.auth_changed(d.session, d)
	d.account = .Signed_In
	d.login = {}

	app.handle_result(s, &second, 0)
	testing.expect_value(t, d.auth_gen, 1)
	testing.expect_value(t, d.account, app.Account.Signed_In)
	queued, _ = jobs.pending(&d.queue)
	testing.expect_value(t, queued, 0)
	data, kstatus := mac.keychain_get(service, app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, kstatus, mac.ERR_SEC_SUCCESS)
	restored := tidal.session_create()
	defer tidal.session_destroy(restored)
	testing.expect(t, app.auth_restore(restored, data))
	testing.expect_value(t, tidal.session_auth(restored, context.temp_allocator).access_token, "new")
}

@(test)
refused_pushes_are_retried :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	d.account = .Signed_In
	for jobs.push(&d.queue, app.Job{kind = .Cover}, app.PRIORITY_COVER) {}

	app.request_playlists(d)
	app.view_open(d, .Playlist, "pl", "pl", "", 300)
	testing.expect(t, !d.sidebar.loading)
	testing.expect_value(t, d.view.in_flight, 0)
	testing.expect_value(t, d.retry, bit_set[app.Job_Kind; u16]{.Playlists, .Tracks})

	// Still full: nothing changes and the retries stay wanted.
	app.data_retry(d)
	testing.expect_value(t, d.retry, bit_set[app.Job_Kind; u16]{.Playlists, .Tracks})

	for _ in 0 ..< 3 {
		jobs.try_pop(&d.queue)
	}
	app.data_retry(d)
	testing.expect(t, d.sidebar.loading)
	testing.expect_value(t, d.view.in_flight, 2)
	testing.expect_value(t, d.retry, bit_set[app.Job_Kind; u16]{})
}

@(private = "file")
fake_rows :: proc(n: int) -> []app.Row {
	rows := make([]app.Row, n, context.temp_allocator)
	for &r, i in rows {
		r.title = fmt.tprint(i)
	}
	return rows
}

@(test)
view_keeps_the_earliest_end :: proc(t: ^testing.T) {
	d := new(app.Data)
	defer free(d)
	defer app.view_close(d)
	// TIDAL said 160, the list has 120. The empty page past the end comes
	// back before the short one.
	app.view_open(d, .Playlist, "pl", "pl", "", 160)
	v := &d.view
	app.view_add_rows(v, 0, fake_rows(50), false)
	app.view_add_rows(v, 150, nil, true)
	testing.expect_value(t, v.count, 150)
	app.view_add_rows(v, 50, fake_rows(70), true)
	testing.expect_value(t, v.count, 120)
	// A late empty page past the end doesn't bring placeholders back.
	app.view_add_rows(v, 150, nil, true)
	app.view_add_rows(v, 250, nil, true)
	testing.expect_value(t, v.count, 120)
	testing.expect_value(t, v.loaded_rows, 120)

	// The other order.
	app.view_open(d, .Playlist, "pl", "pl", "", 160)
	app.view_add_rows(v, 50, fake_rows(70), true)
	app.view_add_rows(v, 150, nil, true)
	testing.expect_value(t, v.count, 120)
	app.view_add_rows(v, 0, fake_rows(50), false)
	testing.expect_value(t, v.count, 120)
	testing.expect_value(t, v.loaded_rows, 120)
}

@(test)
view_grows_past_the_count :: proc(t: ^testing.T) {
	d := new(app.Data)
	defer free(d)
	defer app.view_close(d)
	// TIDAL said 100, the list has 230: pages go on until a short one.
	app.view_open(d, .Playlist, "pl", "pl", "", 100)
	v := &d.view
	queued, _ := jobs.pending(&d.queue)
	testing.expect_value(t, queued, 2)
	for _ in 0 ..< 2 {
		job, _ := jobs.try_pop(&d.queue)
		v.in_flight -= 1
		app.view_add_rows(v, int(job.offset), fake_rows(int(job.limit)), false)
	}
	testing.expect_value(t, v.count, 150)
	app.view_request_pages(d)
	job, _ := jobs.try_pop(&d.queue)
	testing.expect_value(t, job.offset, 150)
	v.in_flight -= 1
	app.view_add_rows(v, 150, fake_rows(80), true)
	testing.expect_value(t, v.count, 230)
	testing.expect(t, v.done)
	app.view_request_pages(d)
	queued, _ = jobs.pending(&d.queue)
	testing.expect_value(t, queued, 0)
}

@(test)
reload_keeps_the_backoff :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := new(app.State)
	defer free(s)
	d := &s.data
	d.keychain = app.small(test_keychain_service())
	d.api = app.small(m.base_url)
	app.session_open(d)
	defer app.data_shutdown(s)

	_, err := tidal.request(d.session, {method = .GET, path = "limited"}, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Too_Many_Requests))

	shell := platform.Shell {
		request_redraw = proc "c" () {},
	}
	app.data_unload(s)
	app.data_reload(s, &shell)
	wait := tidal.backoff_remaining(d.session)
	testing.expect(t, wait > 0.5 && wait <= 1, fmt.tprint(wait))
	_, err = tidal.request(d.session, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Backing_Off), fmt.tprint(err))
	testing.expect_value(t, mock_count(&m, "GET /echo"), 0)
}

@(test)
api_override_only_for_loopback :: proc(t: ^testing.T) {
	for url in ([]string{"http://127.0.0.1:8787", "http://127.0.0.1:8787/", "https://localhost/api", "http://LOCALHOST:1", "http://[::1]:8787/x"}) {
		testing.expect(t, app.is_loopback_url(url), url)
	}
	for url in ([]string{"http://example.com", "http://127.0.0.1.example.com", "http://localhost@example.com", "http://127.0.0.1:80@example.com/", "http://example.com/127.0.0.1", "ftp://127.0.0.1", "127.0.0.1:8787", "http://[::1]x", "http://127.0.0.1:", "http://localhost:80:80", "http://127.0.0.2"}) {
		testing.expect(t, !app.is_loopback_url(url), url)
	}
}

// The only test that sets an environment variable, which is process-wide.
@(test)
api_override_debug_only :: proc(t: ^testing.T) {
	os.set_env("TIDALFAST_API", "http://127.0.0.1:8787")
	defer os.unset_env("TIDALFAST_API")
	when ODIN_DEBUG {
		testing.expect_value(t, app.api_override(), "http://127.0.0.1:8787")
		os.set_env("TIDALFAST_API", "http://example.com")
		testing.expect_value(t, app.api_override(), "")
	} else {
		testing.expect_value(t, app.api_override(), "")
	}
}

// A State whose session talks to the mock, with a Keychain service of its
// own. Workers aren't started.
@(private = "file")
mock_data_state :: proc(m: ^Mock) -> ^app.State {
	s := new(app.State)
	d := &s.data
	d.keychain = app.small(test_keychain_service())
	d.api = app.small(m.base_url)
	d.wake = proc "c" () {}
	cover.init(&d.covers, app.COVER_BUDGET)
	app.session_open(d)
	return s
}

// wait_result waits up to timeout for the workers' next result.
@(private = "file")
wait_result :: proc(d: ^app.Data, timeout: time.Duration) -> (res: app.Result, ok: bool) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if res, ok = jobs.try_pop(&d.results); ok {
			return
		}
		time.sleep(10 * time.Millisecond)
	}
	return
}

// A cover that answers 401 after a new login leaves the login alone: covers
// carry no token.
@(test)
cover_401_keeps_the_login :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	service := app.keychain_service(d)
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "new", refresh_token = "new-r", user_id = 123, user_kind = .Logged_In_User})
	d.account = .Signed_In
	app.auth_changed(d.session, d)

	e := cover.want(&d.covers, .Album, "cover-id", 80, 1, app.PRIORITY_COVER)
	key := e.key
	app.push_job(d, {kind = .Cover, key = key, size = 80, id = app.small("cover-id")}, app.PRIORITY_COVER)
	app.workers_start(d)
	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)

	testing.expect_value(t, mock_count(&m, "GET /images/"), 1)
	testing.expect_value(t, cover.lookup(&d.covers, key).state, cover.State.Failed)
	testing.expect_value(t, d.account, app.Account.Signed_In)
	testing.expect_value(t, d.auth_gen, 0)
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "new")
	_, status := mac.keychain_get(service, app.KEYCHAIN_ACCOUNT, context.temp_allocator)
	testing.expect_value(t, status, mac.ERR_SEC_SUCCESS)
}

// The approval got the tokens, then loading the session was held back
// until after the code expired. The tokens still finish the login.
@(test)
login_resumes_with_tokens_after_the_code_expired :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "device-access", refresh_token = "device-refresh"})
	d.account = .Signed_Out
	d.login.link.device_code = app.small("dc")
	d.login.link.interval = 1
	d.login.deadline = time.tick_add(time.tick_now(), -time.Second)
	app.request_login_poll(d)
	app.workers_start(d)
	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)

	testing.expect_value(t, m.poll_count, 0)
	testing.expect_value(t, d.account, app.Account.Signed_In)
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).user_id, 123)
}

// A reload after the approval, before the session loaded, keeps the tokens,
// and the Login_Wait finishes with them instead of polling the spent code.
@(test)
reload_keeps_an_approved_login :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	tidal.session_restore(d.session, {token_type = "Bearer", access_token = "device-access", refresh_token = "device-refresh"})
	d.account = .Signed_Out
	d.login.link.device_code = app.small("dc")
	d.login.link.interval = 1
	d.login.deadline = time.tick_add(time.tick_now(), 300 * time.Second)
	app.request_login_poll(d)

	shell := platform.Shell {
		request_redraw = proc "c" () {},
	}
	app.data_unload(s)
	app.data_reload(s, &shell)
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).refresh_token, "device-refresh")
	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)

	testing.expect_value(t, m.poll_count, 0)
	testing.expect_value(t, d.account, app.Account.Signed_In)
}

// slow_down, then a 429: the poll after the backoff still waits the slower
// interval.
@(test)
login_requeue_keeps_the_interval :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	m.polls = {"slow_down", "429", "ok"}
	d.account = .Signed_Out
	d.login.link.device_code = app.small("dc")
	d.login.link.interval = 0.2
	d.login.deadline = time.tick_add(time.tick_now(), 300 * time.Second)
	app.request_login_poll(d)
	app.workers_start(d)
	res, ok := wait_result(d, 20 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)

	testing.expect_value(t, d.account, app.Account.Signed_In)
	testing.expect_value(t, len(m.poll_times), 3)
	interval := 0.2 + f64(tidal.SLOW_DOWN_STEP)
	for i in 1 ..< len(m.poll_times) {
		gap := time.duration_seconds(time.tick_diff(m.poll_times[i - 1], m.poll_times[i]))
		testing.expectf(t, gap >= interval - 0.05, "poll %d came %.3f s after the one before, interval %.1f s", i, gap, interval)
	}
}
