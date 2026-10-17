package tidal_tests

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/cover"
import "../src/jobs"
import "../src/os_services"
import "../src/platform"
import tidal "../src/tidal"
import "../src/ui"

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

// A device wait between polls stops as soon as another login attempt
// starts, and polls no more.
@(test)
device_wait_stops_with_its_attempt :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)
	s.config.api_oauth2_token = fmt.tprintf("%sdevice_token", m.base_url)
	tidal.session_set_login_attempt(s, 1)

	worker := thread.create_and_start_with_poly_data(s, proc(s: ^tidal.Session) {
		time.sleep(300 * time.Millisecond)
		tidal.session_set_login_attempt(s, 2)
	})
	link := tidal.Link_Login {
		device_code = "dc",
		interval    = 2,
		expires_in  = 3,
	}
	start := time.tick_now()
	err := tidal.login_device_wait(s, &link, until_expiry = true, attempt = 1)
	took := time.duration_seconds(time.tick_since(start))
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, tidal.is_error(err, .Cancelled), fmt.tprint(err))
	testing.expect(t, took < 1, fmt.tprint(took))
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
// nothing unless a test asks, and a keychain in memory.
@(private = "file")
data_state :: proc() -> ^app.State {
	s := new(app.State)
	test_keychain(&s.data)
	app.session_open(&s.data)
	return s
}

@(private = "file")
data_state_free :: proc(s: ^app.State) {
	app.data_shutdown(s)
	test_state_free(s)
	free(s)
}

// test_keychain is d's keychain, made in memory if it has none. An OS
// Keychain item other than a throwaway tidalfast-test-* one stops the
// test, so no test can sign in or out on the user's login.
test_keychain :: proc(d: ^app.Data) -> ^app.Keychain {
	switch &k in d.keychain {
	case nil:
		d.keychain = new(app.Memory_Keychain, runtime.heap_allocator())
	case app.Os_Keychain:
		service := app.small_str(&k.service)
		if !strings.has_prefix(service, "tidalfast-test-") {
			fmt.panicf("a test reached the Keychain item of service %q", service)
		}
	case ^app.Memory_Keychain:
	}
	return &d.keychain
}

// keychain_auth is the login the keychain holds, read the way a launch
// reads it, or false for none.
keychain_auth :: proc(d: ^app.Data) -> (a: tidal.Auth, ok: bool) {
	data, status := app.keychain_get(test_keychain(d), context.temp_allocator)
	if status != os_services.SECRET_OK {
		return
	}
	restored := tidal.session_create()
	defer tidal.session_destroy(restored)
	ok = app.auth_restore(restored, data)
	return tidal.session_auth(restored, context.temp_allocator), ok
}

// test_state_free frees what the test helpers here gave s: the keychain
// and the UI the login screen was drawn with.
test_state_free :: proc(s: ^app.State) {
	if k, ok := s.data.keychain.(^app.Memory_Keychain); ok {
		app.keychain_delete(&s.data.keychain)
		free(k, runtime.heap_allocator())
		s.data.keychain = nil
	}
	if s.ui.boxes != nil {
		delete(s.ui.boxes)
		delete(s.ui.table)
		delete(s.ui.hits)
		s.ui.boxes = nil
	}
}

TEST_LOGIN :: tidal.Auth {
	token_type    = "Bearer",
	access_token  = "a",
	refresh_token = "r",
	user_id       = 123,
	user_kind     = .Logged_In_User,
}

// sign_in signs s in as a launch with a saved login does: the keychain
// holds the login and the Restore job reads it. The account's first jobs
// go in the queue, or wait for room in it.
sign_in :: proc(s: ^app.State, login := TEST_LOGIN) {
	d := &s.data
	if d.session == nil {
		app.session_open(d)
	}
	app.keychain_set(test_keychain(d), app.auth_marshal(login, context.temp_allocator))
	run_now(s, {auth = d.auth_gen, payload = app.Restore_Job{}})
}

// launch_signed_out is a launch with no saved login: the login screen.
launch_signed_out :: proc(s: ^app.State) {
	d := &s.data
	app.keychain_delete(test_keychain(d))
	// Restore reads TIDALFAST_PKCE_REDIRECT when it finds no login.
	sync.guard(&env_mutex)
	run_now(s, {auth = d.auth_gen, payload = app.Restore_Job{}})
}

// run_now runs job as a worker would, on this thread, and hands the app
// its result. Only for jobs that stay on this machine or go to a mock.
run_now :: proc(s: ^app.State, job: app.Job) {
	res := app.run_job(&s.data, job)
	app.handle_result(s, &res, 0)
	app.result_free(&res)
}

// run_queued empties the queue: it runs the jobs of type T with run_now
// and drops the rest. It returns how many it ran.
run_queued :: proc(s: ^app.State, $T: typeid) -> int {
	queued := make([dynamic]app.Job, context.temp_allocator)
	for {
		job, ok := jobs.try_pop(&s.data.queue)
		if !ok {
			break
		}
		append(&queued, job)
	}
	n := 0
	for &job in queued {
		if _, is := job.payload.(T); is {
			run_now(s, job)
			n += 1
		} else {
			app.job_free(&job)
		}
	}
	return n
}

// login_screen draws a frame of the login screen with events, text typed
// in it if events has a .Text event, and returns what the frame reads out
// to accessibility: every node's label and then its value, one a line.
login_screen :: proc(t: ^testing.T, s: ^app.State, events: []platform.Event = nil, text := "", loc := #caller_location) -> string {
	if !testing.expect(t, app.show_login(s), "the login screen shows", loc = loc) {
		return ""
	}
	return screen_of(s, app.draw_login, events, text)
}

// screen_of is login_screen for what draw draws.
screen_of :: proc(s: ^app.State, draw: proc(s: ^app.State), events: []platform.Event = nil, text := "") -> string {
	if s.ui.boxes == nil {
		ui.init(&s.ui)
	}
	ui.begin_frame(&s.ui, events, nil, nil, 1000, 700, 0, nil, transmute([]u8)strings.clone(text, context.temp_allocator))
	draw(s)
	ui.end_frame()
	b := strings.builder_make(context.temp_allocator)
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		fmt.sbprintf(&b, "%s\n", n.label)
		if n.value != nil {
			fmt.sbprintf(&b, "%s\n", n.value)
		}
	}
	return strings.to_string(b)
}

// login_press presses the login screen's button whose label starts with
// label, or with .Access_Focus focuses its field, through accessibility.
login_press :: proc(t: ^testing.T, s: ^app.State, label: string, kind := platform.Event_Kind.Access_Press, loc := #caller_location) {
	login_screen(t, s, loc = loc)
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if strings.has_prefix(string(n.label), label) {
			login_screen(t, s, {{kind = kind, target = n.id}}, loc = loc)
			return
		}
	}
	testing.fail_now(t, fmt.tprint("nothing on the login screen reads", label), loc)
}

// shows says whether screen, from login_screen, has a line that is line.
shows :: proc(screen, line: string) -> bool {
	return strings.contains(screen, fmt.tprintf("\n%s\n", line)) || strings.has_prefix(screen, fmt.tprintf("%s\n", line))
}

@(private = "file")
fail_job :: proc(d: ^app.Data, kind: tidal.Error_Kind) -> app.Result {
	job, _, ok := jobs.pop_wait(&d.queue)
	assert(ok)
	jobs.done(&d.queue)
	return {job = job, err = kind, message = app.small("Authentication: 401")}
}

// Two requests under the old login come back refused. The first signs
// out: the keychain item goes and the login screen says why. The second,
// arriving after the user logged in again, leaves the new login alone.
@(test)
auth_failures_sign_out_once :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	sign_in(s, {token_type = "Bearer", access_token = "old", refresh_token = "old-r", user_id = 123, user_kind = .Logged_In_User})
	_, saved := keychain_auth(d)
	testing.expect(t, saved)
	testing.expect(t, !app.show_login(s))
	data_jobs(d)

	app.push_job(d, {payload = app.Playlists_Job{}})
	app.push_job(d, {payload = app.Tracks_Job{}})
	first := fail_job(d, .Authentication)
	second := fail_job(d, .Authentication)

	app.handle_result(s, &first, 0)
	_, saved = keychain_auth(d)
	testing.expect(t, !saved, "the keychain item went")
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "")
	// The login screen shows the PKCE login, which waits for the user.
	screen := login_screen(t, s)
	testing.expect(t, shows(screen, "Log in to TIDAL"), screen)
	testing.expect(t, shows(screen, "Your TIDAL session ended. Log in again."), screen)
	testing.expect_value(t, len(data_jobs(d)), 0)

	// The user logs in again before the second failure arrives.
	m.polls = {"ok"}
	app.pkce_submit(s, fmt.tprintf("%sandroid/login/auth?code=c", m.base_url))
	testing.expect_value(t, run_queued(s, app.Login_Pkce_Job), 1)
	testing.expect(t, !app.show_login(s))
	data_jobs(d)

	app.handle_result(s, &second, 0)
	testing.expect(t, !app.show_login(s), "the new login stays")
	testing.expect_value(t, len(data_jobs(d)), 0)
	a, kept := keychain_auth(d)
	testing.expect(t, kept)
	testing.expect_value(t, a.access_token, "device-access")
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "device-access")
}

// A token refresh that got its tokens before the account ended, and saves
// them after, leaves the keychain as the account left it.
@(test)
refresh_after_the_account_ended_is_not_saved :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)
	m.polls = {"ok"}

	// Saves wait for this lock, so the refresh stops between reading its
	// tokens and saving them.
	sync.mutex_lock(&d.keychain_mutex)
	refresh := thread.create_and_start_with_poly_data(d.session, proc(s: ^tidal.Session) {
		tidal.token_refresh(s, "r")
	})
	start := time.tick_now()
	for tidal.session_auth(d.session, context.temp_allocator).access_token != "device-access" && time.tick_since(start) < 5 * time.Second {
		time.sleep(10 * time.Millisecond)
	}
	time.sleep(100 * time.Millisecond)
	app.account_end(s)
	sync.mutex_unlock(&d.keychain_mutex)
	thread.join(refresh)
	thread.destroy(refresh)

	testing.expect_value(t, m.poll_count, 1)
	a, saved := keychain_auth(d)
	testing.expect(t, saved)
	testing.expect_value(t, a.access_token, TEST_LOGIN.access_token)
	testing.expect_value(t, a.refresh_token, TEST_LOGIN.refresh_token)
}

// data_jobs empties the queue and returns the jobs in it but covers.
data_jobs :: proc(d: ^app.Data) -> [dynamic]app.Job {
	out := make([dynamic]app.Job, context.temp_allocator)
	for {
		job, ok := jobs.try_pop(&d.queue)
		if !ok {
			return out
		}
		if _, cover := job.payload.(app.Cover_Job); !cover {
			append(&out, job)
		}
	}
}

@(private = "file")
fill_with_covers :: proc(d: ^app.Data) {
	for jobs.push(&d.queue, app.Job{payload = app.Cover_Job{}}, app.PRIORITY_COVER) {}
}

@(private = "file")
free_slots :: proc(d: ^app.Data, n: int) {
	for _ in 0 ..< n {
		jobs.try_pop(&d.queue)
	}
}

// Jobs a full queue refused go out once there's room, and only those still
// wanted: pages of the open list, not of one closed since, and nothing for
// an account that ended.
@(test)
refused_jobs_wait_for_room :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	fill_with_covers(d)

	sign_in(s)
	app.view_open(d, .Playlist, "closed", "closed", "", 300)
	closed := d.view.gen
	app.view_open(d, .Playlist, "open", "open", "", 300)
	app.push_job(d, {payload = app.Add_Track_Job{track = 5, source = .Liked}})
	app.data_retry(d)
	testing.expect_value(t, len(data_jobs(d)), 0)

	fill_with_covers(d)
	free_slots(d, 8)
	app.data_retry(d)
	playlists, adds: int
	pages := make([dynamic]i32, context.temp_allocator)
	for job in data_jobs(d) {
		#partial switch p in job.payload {
		case app.Playlists_Job:
			playlists += 1
		case app.Add_Track_Job:
			adds += 1
			testing.expect_value(t, p.track, 5)
		case app.Tracks_Job:
			testing.expect(t, p.view != closed, "no pages for the list closed since")
			testing.expect_value(t, p.view, d.view.gen)
			append(&pages, p.offset)
		case:
			testing.fail_now(t, fmt.tprint("unexpected job", job.payload))
		}
	}
	testing.expect_value(t, playlists, 1)
	testing.expect_value(t, adds, 1)
	testing.expect_value(t, len(pages), 2)
	testing.expect(t, slice.contains(pages[:], 0) && slice.contains(pages[:], app.PAGE_FIRST))
	testing.expect(t, d.sidebar.loading)
	testing.expect_value(t, d.view.in_flight, 2)

	fill_with_covers(d)
	app.push_job(d, {payload = app.Add_Track_Job{track = 6, source = .Liked}})
	app.account_end(s)
	free_slots(d, 8)
	app.data_retry(d)
	testing.expect_value(t, len(data_jobs(d)), 0)
}

// Adds piling up while the queue is full push out the oldest adds, never
// the list's pages or the sidebar, which nothing would ask for again.
@(test)
held_jobs_keep_what_waits :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	fill_with_covers(d)

	sign_in(s)
	app.view_open(d, .Playlist, "pl", "pl", "", 300)
	for track in 0 ..< 20 {
		app.push_job(d, {payload = app.Add_Track_Job{track = i64(track), source = .Liked}})
	}
	free_slots(d, 32)
	app.data_retry(d)
	pages, playlists: int
	adds := make([dynamic]i64, context.temp_allocator)
	for job in data_jobs(d) {
		#partial switch p in job.payload {
		case app.Tracks_Job:
			pages += 1
		case app.Playlists_Job:
			playlists += 1
		case app.Add_Track_Job:
			append(&adds, p.track)
		}
	}
	testing.expect_value(t, pages, 2)
	testing.expect_value(t, playlists, 1)
	testing.expect_value(t, len(adds), app.HELD_JOBS - 2)
	testing.expect(t, slice.contains(adds[:], 19) && !slice.contains(adds[:], 0), "the oldest adds went")
}

// A refused login job goes out when there's room while the login still
// waits for it, and not once the login has moved on.
@(test)
refused_login_jobs_wait_for_room :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	launch_signed_out(s)
	fill_with_covers(d)

	app.device_begin(d)
	app.data_retry(d)
	free_slots(d, 4)
	app.data_retry(d)
	queued := data_jobs(d)
	if !testing.expect_value(t, len(queued), 1) {
		return
	}
	_, is_start := queued[0].payload.(app.Login_Start_Job)
	testing.expect(t, is_start)

	// TIDAL's code comes back while the queue is full again.
	fill_with_covers(d)
	answer_login_start(s, queued[0])
	testing.expect(t, shows(login_screen(t, s), "ABCDE"))
	free_slots(d, 4)
	app.data_retry(d)
	queued = data_jobs(d)
	if !testing.expect_value(t, len(queued), 1) {
		return
	}
	wait, is_wait := queued[0].payload.(app.Login_Wait_Job)
	testing.expect(t, is_wait)
	testing.expect_value(t, app.small_str(&wait.device_code), "dc")
	// It's the code's own poll: its answer is taken.
	failed := app.Result{job = queued[0], err = .Network}
	app.handle_result(s, &failed, 0)
	testing.expect(t, shows(login_screen(t, s), "Can't reach TIDAL. Trying again in 2 s."))
}

// A code the queue refused never goes out once the PKCE login finished.
@(test)
held_login_code_dropped_after_the_pkce_login :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	launch_signed_out(s)
	fill_with_covers(d)

	app.device_begin(d)
	app.pkce_show(d)
	m.polls = {"ok"}
	app.pkce_submit(s, fmt.tprintf("%sandroid/login/auth?code=c", m.base_url))
	for _ in 0 ..< 3 {
		free_slots(d, 4)
		app.data_retry(d)
		for job in data_jobs(d) {
			_, start := job.payload.(app.Login_Start_Job)
			testing.expect(t, !start, "no code for a login that finished")
			if _, pkce := job.payload.(app.Login_Pkce_Job); pkce {
				run_now(s, job)
			}
		}
	}
	testing.expect(t, !app.show_login(s))
}

// answer_login_start hands the app TIDAL's code for job, a Login_Start, as
// a worker would.
answer_login_start :: proc(s: ^app.State, job: app.Job, interval: f32 = 1, expires: f32 = 300) {
	res := app.Result {
		job  = job,
		link = {user_code = app.small("ABCDE"), device_code = app.small("dc"), interval = interval, expires = expires},
	}
	app.handle_result(s, &res, 0)
}

// login_starts answers the queued Login_Start jobs with a code, as the
// workers would, until no more go out, and empties the queue. It returns how
// many there were.
@(private = "file")
login_starts :: proc(s: ^app.State) -> int {
	n := 0
	for {
		starts := 0
		for job in data_jobs(&s.data) {
			if _, start := job.payload.(app.Login_Start_Job); start {
				answer_login_start(s, job)
				starts += 1
			}
		}
		if starts == 0 {
			return n
		}
		n += starts
	}
}

// show_code is the code login with TIDAL's code on screen and its poll
// queued.
show_code :: proc(t: ^testing.T, s: ^app.State, interval: f32 = 1, expires: f32 = 300, loc := #caller_location) {
	launch_signed_out(s)
	app.device_begin(&s.data)
	start, ok := jobs.try_pop(&s.data.queue)
	_, is_start := start.payload.(app.Login_Start_Job)
	testing.expect(t, ok && is_start, "the code login asks for a code", loc = loc)
	answer_login_start(s, start, interval, expires)
	testing.expect(t, shows(login_screen(t, s, loc = loc), "ABCDE"), "the code shows", loc = loc)
}

// A code that expired is replaced, whether a poll found it expired or it
// ran out while TIDAL couldn't be reached. The card says so and asks TIDAL
// for a new one.
@(test)
expired_code_is_replaced :: proc(t: ^testing.T) {
	for kind in ([]tidal.Error_Kind{.Timeout, .Network}) {
		s := data_state()
		show_code(t, s, expires = 0)
		polls := data_jobs(&s.data)
		if testing.expect_value(t, len(polls), 1) {
			res := app.Result{job = polls[0], err = kind}
			app.handle_result(s, &res, 0)
			screen := login_screen(t, s)
			testing.expect(t, shows(screen, "The code expired. Here's a new one."), screen)
			testing.expect(t, !shows(screen, "ABCDE"), screen)
			starts := data_jobs(&s.data)
			if testing.expectf(t, len(starts) == 1, "%v: queued %v", kind, starts) {
				_, start := starts[0].payload.(app.Login_Start_Job)
				testing.expectf(t, start, "%v asks for a new code: %v", kind, starts[0].payload)
			}
		}
		data_state_free(s)
	}
}

// A code the queue refused isn't asked for once the user has moved on to
// the PKCE login, and going back to the code login asks for one code.
@(test)
held_login_code_follows_the_login_shown :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	launch_signed_out(s)
	fill_with_covers(d)

	app.device_begin(d)
	app.pkce_show(d)
	free_slots(d, 4)
	app.data_retry(d)
	testing.expect_value(t, login_starts(s), 0)

	app.device_begin(d)
	testing.expect_value(t, login_starts(s), 1)
	testing.expect(t, shows(login_screen(t, s), "ABCDE"))
}

// After a failed code login, going to the PKCE login and back asks TIDAL
// for a new code and says so, not the old error, whether the queue takes
// the ask at once or holds it for room.
@(test)
code_login_after_a_failure_asks_again :: proc(t: ^testing.T) {
	FAILED :: "Can't reach TIDAL. Check your connection."
	for full in ([]bool{false, true}) {
		s := data_state()
		d := &s.data
		launch_signed_out(s)
		app.device_begin(d)
		starts := data_jobs(d)
		if testing.expect_value(t, len(starts), 1) {
			res := app.Result{job = starts[0], err = .Network}
			app.handle_result(s, &res, 0)
		}
		testing.expect(t, shows(login_screen(t, s), FAILED))

		app.pkce_show(d)
		if full {
			fill_with_covers(d)
		}
		app.device_begin(d)
		if full {
			free_slots(d, 4)
			app.data_retry(d)
		}
		screen := login_screen(t, s)
		testing.expectf(t, shows(screen, "Getting a code from TIDAL…"), "full queue %v: %s", full, screen)
		testing.expectf(t, !shows(screen, FAILED), "full queue %v: %s", full, screen)
		testing.expectf(t, login_starts(s) == 1, "full queue %v: one code asked for", full)
		screen = login_screen(t, s)
		testing.expectf(t, shows(screen, "ABCDE"), "full queue %v: %s", full, screen)
		data_state_free(s)
	}
}

// A pasted address does nothing unless the paste form shows: not on the
// code login's card, and not a second time while the first is exchanged.
@(test)
pkce_submit_needs_the_paste_form :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	URL :: "https://tidal.com/android/login/auth?code=c"
	show_code(t, s)
	data_jobs(d)
	app.pkce_submit(s, URL)
	testing.expect_value(t, len(data_jobs(d)), 0)
	testing.expect(t, shows(login_screen(t, s), "ABCDE"))

	app.pkce_show(d)
	app.pkce_submit(s, URL)
	app.pkce_submit(s, URL)
	queued := data_jobs(d)
	testing.expect_value(t, len(queued), 1)
	for job in queued {
		_, pkce := job.payload.(app.Login_Pkce_Job)
		testing.expectf(t, pkce, "queued %v", job.payload)
	}
}

// A full hold list makes room from a job no longer wanted before any add,
// and going back to the code login asks for a code again.
@(test)
full_hold_list_drops_unwanted_jobs_first :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	launch_signed_out(s)
	fill_with_covers(d)

	app.device_begin(d)
	for track in 0 ..< app.HELD_JOBS - 1 {
		app.push_job(d, {payload = app.Add_Track_Job{track = i64(track), source = .Liked}})
	}
	app.pkce_show(d)
	app.push_job(d, {payload = app.Add_Track_Job{track = app.HELD_JOBS - 1, source = .Liked}})
	app.device_begin(d)
	free_slots(d, app.HELD_JOBS + 1)
	app.data_retry(d)
	adds := make([dynamic]i64, context.temp_allocator)
	starts := 0
	for job in data_jobs(d) {
		#partial switch p in job.payload {
		case app.Add_Track_Job:
			append(&adds, p.track)
		case app.Login_Start_Job:
			answer_login_start(s, job)
			starts += 1
		}
	}
	testing.expect_value(t, starts, 1)
	testing.expect(t, shows(login_screen(t, s), "ABCDE"), "the code is the one the login shown asked for")
	testing.expect_value(t, len(adds), app.HELD_JOBS - 1)
	testing.expect(t, !slice.contains(adds[:], 0) && slice.contains(adds[:], 1), "the new code's room came from the oldest add")
	testing.expect(t, slice.contains(adds[:], app.HELD_JOBS - 1), "the unwanted code made room for the last add")
}

// Jobs that wait behind a flag or a list are never pushed out of the hold
// list: nothing would ask for a lost Restore or settings save again.
@(test)
full_hold_list_never_drops_a_waiting_job :: proc(t: ^testing.T) {
	s := data_state()
	testing.cleanup(t, proc(s: rawptr) {data_state_free((^app.State)(s))}, s)
	d := &s.data
	fill_with_covers(d)
	for _ in 0 ..< app.HELD_JOBS {
		app.push_job(d, {payload = app.Cover_Job{}}, app.PRIORITY_COVER)
	}
	testing.expect_assert(t, "the hold list is full of jobs that wait behind a flag")
	sign_in(s)
	testing.fail_now(t, "a full hold list of waiting jobs pushed one out")
}

// A held page for a list that's ended since isn't sent: page 50 came back as
// the list's last while page 150 waited for room.
@(test)
held_page_past_the_end_stays_home :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)
	app.view_open(d, .Playlist, "pl", "pl", "", 300)
	v := &d.view
	out := data_jobs(d)
	testing.expect_value(t, len(out), 2)
	fill_with_covers(d)

	first := app.Result{job = out[0], rows = fake_rows(app.PAGE_FIRST), total = 300}
	app.handle_result(s, &first, 0)
	testing.expect_value(t, v.in_flight, 2)
	last := app.Result{job = out[1], rows = fake_rows(120 - app.PAGE_FIRST), total = 120}
	app.handle_result(s, &last, 0)

	free_slots(d, 8)
	app.data_retry(d)
	for job in data_jobs(d) {
		p, page := job.payload.(app.Tracks_Job)
		testing.expect(t, !page, fmt.tprint("a page past the end went out at", p.offset))
	}
	testing.expect_value(t, v.in_flight, 0)
	testing.expect(t, app.view_complete(v), "the list loaded in full")
	testing.expect_value(t, v.loaded_rows, 120)
}

// Pages go out in order while the queue is full. Page 250 mustn't go out
// ahead of a held page 150 and end the list with rows 150 to 249 empty.
@(test)
held_page_keeps_later_pages_back :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)
	app.view_open(d, .Playlist, "pl", "pl", "", 300)
	v := &d.view
	out := data_jobs(d)
	testing.expect_value(t, len(out), 2)
	fill_with_covers(d)

	first := app.Result{job = out[0], rows = fake_rows(app.PAGE_FIRST), total = 300}
	app.handle_result(s, &first, 0)
	free_slots(d, 1)
	second := app.Result{job = out[1], rows = fake_rows(app.PAGE_SIZE), total = 300}
	app.handle_result(s, &second, 0)
	app.data_retry(d)
	for _ in 0 ..< 8 {
		for job in data_jobs(d) {
			if p, page := job.payload.(app.Tracks_Job); page {
				res := app.Result{job = job, rows = fake_rows(clamp(300 - int(p.offset), 0, int(p.limit))), total = 300}
				app.handle_result(s, &res, 0)
			}
		}
		app.data_retry(d)
	}
	testing.expect(t, app.view_complete(v), "the list loaded")
	testing.expect_value(t, v.count, 300)
	testing.expect_value(t, v.loaded_rows, 300)
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
	app.view_add_rows(v, 0, 50, fake_rows(50))
	app.view_add_rows(v, 150, 100, nil)
	testing.expect_value(t, v.count, 150)
	app.view_add_rows(v, 50, 100, fake_rows(70))
	testing.expect_value(t, v.count, 120)
	// A late empty page past the end doesn't bring placeholders back.
	app.view_add_rows(v, 150, 100, nil)
	app.view_add_rows(v, 250, 100, nil)
	testing.expect_value(t, v.count, 120)
	testing.expect_value(t, v.loaded_rows, 120)

	// The other order.
	app.view_open(d, .Playlist, "pl", "pl", "", 160)
	app.view_add_rows(v, 50, 100, fake_rows(70))
	app.view_add_rows(v, 150, 100, nil)
	testing.expect_value(t, v.count, 120)
	app.view_add_rows(v, 0, 50, fake_rows(50))
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
		p := job.payload.(app.Tracks_Job)
		v.in_flight -= 1
		app.view_add_rows(v, int(p.offset), int(p.limit), fake_rows(int(p.limit)))
	}
	testing.expect_value(t, v.count, 150)
	app.view_request_pages(d)
	job, _ := jobs.try_pop(&d.queue)
	testing.expect_value(t, job.payload.(app.Tracks_Job).offset, 150)
	v.in_flight -= 1
	app.view_add_rows(v, 150, 100, fake_rows(80))
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

// Held by the tests that set environment variables, which are process-wide.
@(private = "file")
env_mutex: sync.Mutex

@(test)
api_override_debug_only :: proc(t: ^testing.T) {
	sync.guard(&env_mutex)
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

// A run that asks for the mock, with TIDALFAST_KEYCHAIN, TIDALFAST_API or
// TIDALFAST_PKCE_REDIRECT, but has no mock URL the app takes never falls
// back to the user's login: no session to reach TIDAL with, no Keychain
// read queued, not the real item or list cache. d.running is set before
// data_start so that no worker can start and read the Keychain if it does
// fall back.
@(test)
mock_run_without_mock_url_keeps_off_tidal :: proc(t: ^testing.T) {
	sync.guard(&env_mutex)
	saved := env_clear()
	defer env_restore(saved)
	os.set_env("TIDALFAST_SETTINGS", fmt.tprintf("%s/tidalfast-settings-%d/settings.json", temp_base(), time.now()._nsec))
	real_cache := app.lists_root(false)
	defer delete(real_cache, runtime.heap_allocator())
	keychain := test_keychain_service()

	Case :: struct {
		api, keychain, pkce: Maybe(string),
		service:             string, // the Keychain item the login is read from, "" for none
	}
	cases := make([dynamic]Case, context.temp_allocator)
	append(
		&cases,
		Case{keychain = keychain},
		Case{keychain = keychain, api = ""},
		Case{keychain = keychain, api = "http://example.com"},
		Case{keychain = keychain, api = strings.concatenate({"http://127.0.0.1:1/", strings.repeat("x", 300, context.temp_allocator)}, context.temp_allocator)},
		Case{api = ""},
		Case{pkce = "http://127.0.0.1:1/android/login/auth?code=mock-pkce-code-1"},
	)
	when ODIN_DEBUG {
		append(&cases, Case{api = "http://127.0.0.1:8787", keychain = keychain, service = keychain})
	}
	for c in cases {
		env_put("TIDALFAST_API", c.api)
		env_put("TIDALFAST_KEYCHAIN", c.keychain)
		env_put("TIDALFAST_PKCE_REDIRECT", c.pkce)
		s := new(app.State)
		d := &s.data
		d.running = true
		shell := platform.Shell {
			request_redraw = proc "c" () {},
		}
		app.data_start(s, &shell)
		queued, _ := jobs.pending(&d.queue)
		label := fmt.tprint(c)
		if c.service != "" {
			testing.expect(t, d.session != nil, label)
			k, os_keychain := d.keychain.(app.Os_Keychain)
			testing.expect(t, os_keychain && app.small_str(&k.service) == c.service, label)
			testing.expect(t, queued == 1, label)
		} else {
			testing.expect(t, d.session == nil, label)
			testing.expect(t, d.keychain == nil, label)
			testing.expect(t, queued == 0, label)
			testing.expect(t, d.lists.root != real_cache, label)
		}
		d.running = false
		for {
			if _, ok := jobs.try_pop(&d.queue); !ok {
				break
			}
		}
		app.data_shutdown(s)
		free(s)
	}
}

// Only a run that asks for neither the mock nor fake data gets TIDAL and the
// user's Keychain item. The mock gets its own item, and fake data, asked
// for or fallen back to, gets none. Fake data asked for uses a settings
// file only when TIDALFAST_SETTINGS names one, so its loud tones never
// play bit-perfect from the user's settings.
@(test)
run_decide_picks_the_run :: proc(t: ^testing.T) {
	CONFIG :: "/config"
	DEFAULT :: CONFIG + "/tidalfast/settings.json"
	MOCK :: "http://127.0.0.1:8787"
	Case :: struct {
		env:  app.Run_Env,
		want: app.Run,
	}
	cases := []Case {
		{{config_dir = CONFIG}, {mode = .Real, keychain = app.KEYCHAIN_SERVICE, settings = DEFAULT}},
		{{settings = "/s.json", config_dir = CONFIG}, {mode = .Real, keychain = app.KEYCHAIN_SERVICE, settings = "/s.json"}},
		{{}, {mode = .Real, keychain = app.KEYCHAIN_SERVICE}},
		{{bench = "covers", config_dir = CONFIG}, {mode = .Real, keychain = app.KEYCHAIN_SERVICE, settings = DEFAULT}},
		{{api = MOCK, wants_mock = true, config_dir = CONFIG}, {mode = .Mock, keychain = app.KEYCHAIN_MOCK_SERVICE, settings = DEFAULT}},
		{{api = MOCK, wants_mock = true, keychain = "tidalfast-test"}, {mode = .Mock, keychain = "tidalfast-test"}},
		{{api = MOCK, wants_mock = true, keychain = app.KEYCHAIN_SERVICE}, {mode = .Mock, keychain = app.KEYCHAIN_MOCK_SERVICE}},
		{{wants_mock = true, keychain = "tidalfast-test", settings = "/s.json", config_dir = CONFIG}, {mode = .Fake, fallback = true}},
		{{fake = "1", settings = "/s.json", config_dir = CONFIG}, {mode = .Fake, settings = "/s.json"}},
		{{fake = "1", wants_mock = true, config_dir = CONFIG}, {mode = .Fake}},
		{{bench = "1", api = MOCK, wants_mock = true, config_dir = CONFIG}, {mode = .Fake}},
		{{bench = "text", config_dir = CONFIG}, {mode = .Fake}},
	}
	for c in cases {
		testing.expect_value(t, app.run_decide(c.env, context.temp_allocator), c.want)
	}
}

// A run that fell back to the fake data, as above, plays its tones
// without bit-perfect output or hog mode whatever the settings say, and
// reads and writes no settings file: not the user's, not TIDALFAST_SETTINGS.
@(test)
mock_fallback_leaves_bit_perfect_and_the_settings_alone :: proc(t: ^testing.T) {
	sync.guard(&env_mutex)
	saved := env_clear()
	defer env_restore(saved)
	dir := fmt.tprintf("%s/tidalfast-settings-%d", temp_base(), time.now()._nsec)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	path := fmt.tprintf("%s/settings.json", dir)
	on := `{"bit_perfect": true, "hog": true, "volume": 0.5}`
	testing.expect(t, os.write_entire_file(path, transmute([]u8)on) == nil)
	os.set_env("TIDALFAST_API", "")

	for settings in ([]Maybe(string){nil, path}) {
		env_put("TIDALFAST_SETTINGS", settings)
		s := new(app.State)
		d := &s.data
		d.running = true
		shell := platform.Shell {
			request_redraw = proc "c" () {},
		}
		app.data_start(s, &shell)
		label := fmt.tprint(settings)
		testing.expect(t, d.fake, label)
		testing.expect_value(t, app.output_of(s.settings), audio.Output{})
		testing.expect_value(t, d.settings_store.path, "")
		if settings != nil {
			st := s.settings
			st.volume = 0.2
			app.settings_queue(d, st, now = true)
			data, _ := os.read_entire_file(path, context.temp_allocator)
			testing.expect_value(t, string(data), on)
		}
		d.running = false
		app.data_shutdown(s)
		free(s)
	}
}

// The variables the mock tests set, cleared for the test and put back by
// env_restore.
@(private = "file")
MOCK_ENV :: [?]string{"TIDALFAST_API", "TIDALFAST_KEYCHAIN", "TIDALFAST_PKCE_REDIRECT", "TIDALFAST_SETTINGS", "TIDALFAST_FAKE", "TIDALFAST_BENCH"}

@(private = "file")
env_clear :: proc() -> (saved: [len(MOCK_ENV)]Maybe(string)) {
	for name, i in MOCK_ENV {
		if value, found := os.lookup_env(name, context.temp_allocator); found {
			saved[i] = value
		}
		os.unset_env(name)
	}
	return
}

@(private = "file")
env_restore :: proc(saved: [len(MOCK_ENV)]Maybe(string)) {
	for name, i in MOCK_ENV {
		env_put(name, saved[i])
	}
}

@(private = "file")
env_put :: proc(name: string, value: Maybe(string)) {
	if v, ok := value.?; ok {
		os.set_env(name, v)
	} else {
		os.unset_env(name)
	}
}

// A State whose session talks to the mock, with a keychain in memory.
// Workers aren't started.
@(private = "file")
mock_data_state :: proc(m: ^Mock) -> ^app.State {
	s := new(app.State)
	d := &s.data
	test_keychain(d)
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
	sign_in(s, {token_type = "Bearer", access_token = "new", refresh_token = "new-r", user_id = 123, user_kind = .Logged_In_User})
	data_jobs(d)

	e := cover.want(&d.covers, .Album, "cover-id", 80, 80, 1, app.PRIORITY_COVER)
	key := e.key
	app.push_job(d, {payload = app.Cover_Job{key = key, image = {id = app.small("cover-id"), size = 80, fetch = 80}}}, app.PRIORITY_COVER)
	app.workers_start(d)
	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)

	testing.expect_value(t, mock_count(&m, "GET /images/"), 1)
	testing.expect_value(t, cover.lookup(&d.covers, key).state, cover.State.Failed)
	testing.expect(t, !app.show_login(s))
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "new")
	a, saved := keychain_auth(d)
	testing.expect(t, saved)
	testing.expect_value(t, a.access_token, "new")
}

// An Add_Track adds the track on TIDAL, then brings back the list's version
// and the track as the list has it now, for the kept copies. A track the
// list has already comes back not added.
@(test)
add_track_job :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m, {{"track", 11}, {"track", 22}})
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)
	app.workers_start(d)

	app.push_job(d, {payload = app.Add_Track_Job{track = 33, source = .Playlist, id = app.small("pl")}})
	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, res.err, nil)
	testing.expect(t, res.added)
	testing.expect(t, len(res.rows) == 1 && res.rows[0].id == 33 && res.rows[0].added == "Feb 3, 2026")
	testing.expect_value(t, res.version.count, 3)
	testing.expect(t, res.version.updated != 0)
	ids := mock_item_ids(&m, context.temp_allocator)
	testing.expect(t, len(ids) == 3 && ids[2] == 33)
	app.result_free(&res)

	app.push_job(d, {payload = app.Add_Track_Job{track = 33, source = .Playlist, id = app.small("pl")}})
	res, ok = wait_result(d, 5 * time.Second)
	testing.expect(t, ok && res.err == nil && !res.added && len(res.rows) == 0)
	testing.expect_value(t, len(mock_item_ids(&m, context.temp_allocator)), 3)
	app.result_free(&res)

	app.push_job(d, {payload = app.Add_Track_Job{track = 5000, source = .Liked}})
	res, ok = wait_result(d, 5 * time.Second)
	testing.expect(t, ok && res.err == nil && res.added)
	testing.expect(t, len(res.rows) == 1 && res.rows[0].id == 5000)
	testing.expect_value(t, res.version, app.List_Version{count = MOCK_LIKED + 1, newest = 5000})
	app.result_free(&res)
}

// TIDAL took the add, then rate limited the read after it. The add still
// counts, without the row, so the kept copies are dropped. Before this,
// the job failed and went back in the queue, and the second POST found
// the track there and said it was already in.
@(test)
add_track_stands_when_the_read_after_fails :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m, {{"track", 11}, {"track", 22}})
	defer mock_stop(&m)
	m.add_then_limit = 1
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)
	app.workers_start(d)

	app.push_job(d, {payload = app.Add_Track_Job{track = 33, source = .Playlist, id = app.small("pl")}})
	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, res.err, nil)
	testing.expect(t, res.added)
	testing.expect_value(t, len(res.rows), 0)
	testing.expect_value(t, mock_count(&m, "POST /playlists/pl/items"), 1)
	testing.expect_value(t, len(mock_item_ids(&m, context.temp_allocator)), 3)
	app.result_free(&res)
}

// During a backoff the workers still run jobs that stay on this machine,
// and keep the ones for TIDAL, a cover not on disk included, queued.
@(test)
local_jobs_run_during_a_backoff :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)
	tidal.backoff_restore(d.session, time.tick_add(time.tick_now(), 30 * time.Second), "test")
	path := fmt.tprintf("/tmp/tidalfast-backoff-%d.log", time.tick_now()._nsec)
	defer os.remove(path)
	d.launch_log_path = path
	defer d.launch_log_path = ""

	app.push_job(d, {payload = app.Playlists_Job{}})
	app.push_job(d, {payload = app.Cover_Job{key = 7, image = {id = app.small("cover-id"), size = 80, fetch = 80}}}, app.PRIORITY_COVER)
	app.push_job(d, {payload = app.Launch_Log_Job{line = slice.clone([]u8{'x', '\n'}, runtime.heap_allocator())}})
	app.workers_start(d)
	res, ok := wait_result(d, 2 * time.Second)
	testing.expect(t, ok)
	_, launch_log := res.job.payload.(app.Launch_Log_Job)
	testing.expect(t, launch_log)
	testing.expect_value(t, res.err, nil)
	app.result_free(&res)

	time.sleep(300 * time.Millisecond)
	_, ok = jobs.try_pop(&d.results)
	testing.expect(t, !ok)
	queued, busy := jobs.pending(&d.queue)
	testing.expect_value(t, queued, 2)
	testing.expect_value(t, busy, 0)
	testing.expect_value(t, mock_count(&m, ""), 0)
}

// The approval got the tokens, then loading the session failed until
// after the code expired. The tokens still finish the login, without
// polling the spent code again.
@(test)
login_resumes_with_tokens_after_the_code_expired :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	m.polls = {"ok"}
	m.sessions_fail = 1
	show_code(t, s, interval = 0.2, expires = 1)
	app.workers_start(d)
	for _ in 0 ..< 2 {
		res, ok := wait_result(d, 5 * time.Second)
		testing.expect(t, ok)
		app.handle_result(s, &res, 0)
		app.result_free(&res)
	}

	testing.expect_value(t, m.poll_count, 1)
	testing.expect(t, !app.show_login(s))
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).user_id, 123)
	a, saved := keychain_auth(d)
	testing.expect(t, saved, "the login is saved")
	testing.expect_value(t, a.access_token, "device-access")
	testing.expect_value(t, a.user_id, 123)
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
	m.polls = {"ok"}
	m.sessions_fail = 1
	show_code(t, s, interval = 0.2)
	testing.expect_value(t, run_queued(s, app.Login_Wait_Job), 1)

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

	testing.expect_value(t, m.poll_count, 1)
	testing.expect(t, !app.show_login(s))
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
	show_code(t, s, interval = 0.2)
	app.workers_start(d)
	res, ok := wait_result(d, 20 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)

	testing.expect(t, !app.show_login(s))
	testing.expect_value(t, len(m.poll_times), 3)
	interval := 0.2 + f64(tidal.SLOW_DOWN_STEP)
	for i in 1 ..< len(m.poll_times) {
		gap := time.duration_seconds(time.tick_diff(m.poll_times[i - 1], m.poll_times[i]))
		testing.expectf(t, gap >= interval - 0.05, "poll %d came %.3f s after the one before, interval %.1f s", i, gap, interval)
	}
}

// TIDAL answering 503 to every poll counts as not reaching it: the poll
// fails at once, and the login checks again after 2 s, then 4 s, once each
// time, instead of polling on as if the code were pending.
@(test)
login_5xx_backs_off :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	m.polls = {"503", "503", "503"}
	show_code(t, s, interval = 0.2)

	poll, ok := jobs.try_pop(&d.queue)
	testing.expect(t, ok, "the code is polled")
	for want_wait in ([]int{2, 4}) {
		run_now(s, poll)
		screen := login_screen(t, s)
		testing.expect(t, shows(screen, fmt.tprintf("Can't reach TIDAL. Trying again in %d s.", want_wait)), screen)

		// What the workers are asked to do next: one check, when the note says.
		queued := data_jobs(d)
		if !testing.expect_value(t, len(queued), 1) {
			return
		}
		poll = queued[0]
		retry, is_wait := poll.payload.(app.Login_Wait_Job)
		testing.expect(t, is_wait, fmt.tprint(poll.payload))
		testing.expect(t, retry.once, "the retry checks once")
		wait := time.duration_seconds(time.tick_diff(time.tick_now(), retry.not_before))
		testing.expectf(t, wait > f64(want_wait) - 0.2 && wait <= f64(want_wait), "the retry is in %.2f s, not %d s", wait, want_wait)
	}
	testing.expect_value(t, len(m.poll_times), 2)
	if len(m.poll_times) == 2 {
		gap := time.duration_seconds(time.tick_diff(m.poll_times[0], m.poll_times[1]))
		testing.expectf(t, gap > 1.8, "the second check came %.2f s after the first, not 2 s", gap)
	}
}

@(private = "file")
now_playing_calls, now_playing_cleared: int

@(private = "file")
count_now_playing :: proc "c" (np: ^platform.Now_Playing) {
	now_playing_calls += 1
	if np.title == nil {
		now_playing_cleared += 1
	}
}

// A sign-out stops playback and forgets the queue, the track and Now
// Playing. The player and its volume stay for the next login.
@(test)
sign_out_stops_playback :: proc(t: ^testing.T) {
	s := data_state()
	defer data_state_free(s)
	s.rows = []app.Row{{title = "One", seconds = 30}, {title = "Two", seconds = 30}}
	sign_in(s)
	s.data.fake = true
	pb := &s.playback
	pb.index = -1
	pb.set_now_playing = count_now_playing
	pb.player = audio.create(proc "c" () {}, 0.5, null_output = true)
	pb.volume_sent = 0.5
	defer {
		app.workers_stop(&s.data)
		app.playback_shutdown(s)
	}

	app.playback_play_row(s, 0)
	start := time.tick_now()
	for time.tick_since(start) < 3 * time.Second && !(pb.status.state == .Playing && pb.status.serial == pb.cur.serial && pb.status.sample > 0) {
		app.playback_update(s, nil)
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, app.playback_playing(s))
	player := pb.player
	cleared := now_playing_cleared

	app.sign_out(s, "Your TIDAL session ended. Log in again.")
	testing.expect_value(t, pb.index, -1)
	testing.expect_value(t, pb.cur.serial, u64(0))
	testing.expect_value(t, pb.next.serial, u64(0))
	testing.expect_value(t, len(pb.items), 0)
	testing.expect(t, app.playback_item(s) == nil)
	testing.expect_value(t, now_playing_cleared, cleared + 1)
	testing.expect(t, pb.player == player)
	testing.expect_value(t, pb.volume_sent, f32(0.5))

	time.sleep(100 * time.Millisecond)
	app.playback_update(s, nil)
	st := audio.status(pb.player)
	testing.expect_value(t, st.state, audio.Play_State.Idle)
	testing.expect_value(t, st.serial, u64(0))
	testing.expect(t, !app.playback_playing(s))
}

// After the approval, a 503 loading the session is passing trouble: the
// login keeps its tokens and tries again, instead of stopping with an error
// whose "Try again" would throw the approval away.
@(test)
session_5xx_after_approval_retries :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	m.polls = {"ok"}
	m.sessions_fail = 1
	show_code(t, s, interval = 0.2)
	app.workers_start(d)

	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)
	screen := login_screen(t, s)
	testing.expect(t, !shows(screen, "Try again"), screen)
	testing.expect(t, shows(screen, "Can't reach TIDAL. Trying again in 2 s."), screen)
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).refresh_token, "device-refresh")

	res, ok = wait_result(d, 10 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)
	testing.expect(t, !app.show_login(s))
	testing.expect_value(t, mock_count(&m, "GET /sessions"), 2)
	testing.expect_value(t, m.poll_count, 1)
}

// "Try again" on a login that has its tokens loads the session with them
// rather than asking for a new code.
@(test)
try_again_keeps_the_tokens :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	m.polls = {"ok"}
	m.sessions_fail = 1
	m.sessions_status = 404
	show_code(t, s, interval = 0.2)
	testing.expect_value(t, run_queued(s, app.Login_Wait_Job), 1)

	login_press(t, s, "Try again")
	job, ok := jobs.try_pop(&d.queue)
	testing.expect(t, ok)
	_, wait := job.payload.(app.Login_Wait_Job)
	testing.expect(t, wait, fmt.tprint(job.payload))
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "device-access")
}

// The user switched from the device login to the PKCE login, which
// finished. A device-code poll from the abandoned attempt that comes back
// approved afterwards doesn't touch the session.
@(test)
superseded_device_login_is_dropped :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := oauth_session(&m)
	defer tidal.session_destroy(s)

	tidal.session_set_login_attempt(s, 2)
	err := tidal.login_pkce_complete(s, "https://tidal.com/android/login/auth?code=c", 2)
	testing.expect_value(t, err, nil)
	pkce := tidal.session_auth(s, context.temp_allocator)
	testing.expect(t, pkce.is_pkce)

	link := tidal.Link_Login {
		device_code = "dc",
		interval    = 0.1,
		expires_in  = 5,
	}
	err = tidal.login_device_wait(s, &link, until_expiry = false, attempt = 1)
	testing.expect(t, tidal.is_error(err, .Cancelled), fmt.tprint(err))
	a := tidal.session_auth(s, context.temp_allocator)
	testing.expect_value(t, a.access_token, pkce.access_token)
	testing.expect_value(t, a.refresh_token, pkce.refresh_token)
	testing.expect(t, a.is_pkce)
}

// A device-code poll queued before the user moved to another login never
// polls, and its result is dropped without an error on screen. If the user
// came back to the code meanwhile, a poll for the new attempt goes out.
@(test)
superseded_login_wait_job :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_data_state(&m)
	defer data_state_free(s)
	d := &s.data
	m.polls = {"ok"}
	show_code(t, s, interval = 0.2)

	// On to the hi-res login, as pkce_begin does.
	app.pkce_show(d)
	app.workers_start(d)
	res, ok := wait_result(d, 5 * time.Second)
	testing.expect(t, ok)
	app.handle_result(s, &res, 0)
	app.result_free(&res)
	testing.expect_value(t, m.poll_count, 0)
	screen := login_screen(t, s)
	testing.expect(t, shows(screen, "Log in to TIDAL"), screen)
	testing.expect(t, !shows(screen, "Try again"), screen)
	testing.expect_value(t, tidal.session_auth(d.session, context.temp_allocator).access_token, "")

	// There and back to the code before the queued poll ran.
	app.device_begin(d)
	app.pkce_show(d)
	app.device_begin(d)
	for _ in 0 ..< 2 {
		res, ok = wait_result(d, 5 * time.Second)
		testing.expect(t, ok)
		app.handle_result(s, &res, 0)
		app.result_free(&res)
	}
	testing.expect_value(t, m.poll_count, 1)
	testing.expect(t, !app.show_login(s))
}

// The PKCE exchange worked but loading the session got a 503. Trying again,
// and trying again after a hot reload, finish with the tokens: the one-use
// code isn't sent a second time.
@(test)
pkce_retry_keeps_the_tokens :: proc(t: ^testing.T) {
	for reload in ([]bool{false, true}) {
		m: Mock
		mock_start(&m)
		s := mock_data_state(&m)
		d := &s.data
		m.polls = {"ok"}
		m.sessions_fail = 1
		launch_signed_out(s)
		app.pkce_submit(s, fmt.tprintf("%sandroid/login/auth?code=one-use", m.base_url))
		testing.expect(t, shows(login_screen(t, s), "Logging you in…"))
		app.workers_start(d)
		res, ok := wait_result(d, 5 * time.Second)
		testing.expect(t, ok)
		app.handle_result(s, &res, 0)
		app.result_free(&res)
		ACCEPTED :: "TIDAL accepted the login, but your account didn't load."
		testing.expect(t, shows(login_screen(t, s), ACCEPTED))
		testing.expect_value(t, m.poll_count, 1)

		if reload {
			shell := platform.Shell {
				request_redraw = proc "c" () {},
			}
			app.data_unload(s)
			app.data_reload(s, &shell)
			testing.expect(t, shows(login_screen(t, s), ACCEPTED))
		}
		login_press(t, s, "Try again")
		res, ok = wait_result(d, 5 * time.Second)
		testing.expect(t, ok)
		app.handle_result(s, &res, 0)
		app.result_free(&res)
		testing.expect(t, !app.show_login(s))
		testing.expect_value(t, m.poll_count, 1)
		testing.expect_value(t, mock_count(&m, "GET /sessions"), 2)
		testing.expect(t, tidal.session_is_pkce(d.session))
		a, saved := keychain_auth(d)
		testing.expect(t, saved, "the login is saved")
		testing.expect(t, a.is_pkce)
		testing.expect_value(t, a.access_token, "device-access")
		testing.expect_value(t, a.user_id, 123)

		data_state_free(s)
		mock_stop(&m)
	}
}
