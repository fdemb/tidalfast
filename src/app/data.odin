package app

// The library's data: login, the TIDAL session, the sidebar's playlists,
// the open track list and the cover cache. Requests run on the workers in
// workers.odin; this file is the UI thread's side.
//
// With TIDALFAST_FAKE=1 none of it runs and the library shows the fake
// data from titles.odin, for working on the UI without an account.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../cover"
import "../jobs"
import "../mac"
import "../platform"
import "../render"
import "../tidal"
import "../ui"

KEYCHAIN_SERVICE :: "tidalfast"
KEYCHAIN_MOCK_SERVICE :: "tidalfast-mock" // with TIDALFAST_API
KEYCHAIN_ACCOUNT :: "auth"
COVER_BUDGET :: 48 << 20 // texture bytes
UPLOAD_BUDGET :: 2 * time.Millisecond // cover uploads per frame
PAGES_IN_FLIGHT :: 2
LOGIN_RETRY_MAX :: 30 // seconds between polls while TIDAL can't be reached

Account :: enum u8 {
	Fake,
	Restoring, // reading the Keychain
	Signed_Out,
	Signed_In,
}

Login :: struct {
	link:      Login_Link,
	requested: bool, // a Login_Start job is out
	waiting:   bool, // a Login_Wait job is out
	error:     Small, // the login stopped; the screen offers "Try again"
	note:      Small, // shown under the code while the login goes on
	deadline:  time.Tick, // when the code expires
	poll_at:   time.Tick, // the next Login_Wait polls no sooner
	poll_once: bool, // it checks once whether TIDAL can be reached again
	retries:   int, // polls in a row that couldn't reach TIDAL
}

Sidebar :: struct {
	arena:       ^vmem.Arena, // adopted from the Playlists result
	items:       []Sidebar_Item,
	liked_count: int,
	loading:     bool,
	loaded:      bool,
}

// Track_View is the open track list. Its rows live in its arena, which is
// freed when another list opens. gen tells this list's pages from those of
// lists opened before it.
Track_View :: struct {
	gen:         u32,
	source:      Source,
	id:          Small,
	name:        Small,
	image:       Small,
	hint:        int, // tracks TIDAL said the list has
	arena:       vmem.Arena,
	has_arena:   bool,
	rows:        []Row,
	loaded:      []bool,
	loaded_rows: int,
	count:       int, // rows shown, loaded or not
	next_offset: int,
	in_flight:   int,
	done:        bool,
	error:       Small,
}

Data :: struct {
	fake:           bool,
	mock:           bool, // api is set
	api:            Small, // TIDALFAST_API once checked, "" for TIDAL
	keychain:       Small, // the Keychain service the login goes in
	account:        Account,
	// Goes up with every sign_out. Jobs carry the one they were queued in,
	// and results from an older one are dropped.
	auth_gen:       u32,
	retry:          bit_set[Job_Kind; u16], // pushes the queue refused, tried again next frame
	// Stream and Artwork jobs the queue refused. Their parameters can't be
	// rebuilt from the kind, so they're kept whole and pushed again.
	held:           [4]Held_Job,
	refresh_errors: int, // token refreshes in a row that failed without ending the login (atomic)
	keychain_mutex: sync.Mutex, // orders a sign-out's delete against the workers' saves
	session:        ^tidal.Session, // made by this dylib, so closed on unload
	wake:           proc "c" (), // the shell's request_redraw
	queue:          jobs.Queue(Job, JOB_QUEUE),
	results:        jobs.Queue(Result, RESULT_QUEUE),
	threads:        [WORKERS]posix.pthread_t,
	running:        bool,
	// From unload to reload: the login state (heap) and the backoff.
	saved_auth:     []u8,
	saved_backoff:  time.Tick,
	saved_reason:   Small,
	login:          Login,
	sidebar:        Sidebar,
	view:           Track_View,
	covers:         cover.Cache,
	message:        Small, // the last error worth showing
	evicted:        [64]render.Texture,
	bench:          Cover_Bench,
}

data_start :: proc(s: ^State, shell: ^platform.Shell) {
	d := &s.data
	d.wake = shell.request_redraw
	cover.init(&d.covers, COVER_BUDGET)
	bench := os.get_env("TIDALFAST_BENCH", context.temp_allocator)
	d.fake = os.get_env("TIDALFAST_FAKE", context.temp_allocator) != "" || (bench != "" && bench != "covers")
	// Checked even with fake data, so a refused TIDALFAST_API is always
	// logged.
	api := api_override()
	if d.fake {
		d.account = .Fake
		return
	}
	d.bench.running = bench == "covers"
	d.api = small(api)
	d.mock = api != ""
	d.keychain = small(KEYCHAIN_MOCK_SERVICE if d.mock else KEYCHAIN_SERVICE)
	if d.mock {
		if name := os.get_env("TIDALFAST_KEYCHAIN", context.temp_allocator); name != "" && name != KEYCHAIN_SERVICE {
			d.keychain = small(name)
		}
	}
	session_open(d)
	d.account = .Restoring
	push_job(d, {kind = .Restore})
	workers_start(d)
}

data_unload :: proc(s: ^State) {
	d := &s.data
	workers_stop(d)
	if d.session != nil {
		d.saved_auth = auth_marshal(tidal.session_auth(d.session, context.temp_allocator), runtime.heap_allocator())
		until, reason := tidal.backoff_state(d.session, context.temp_allocator)
		d.saved_backoff = until
		d.saved_reason = small(reason)
		tidal.session_destroy(d.session)
		d.session = nil
	}
}

data_reload :: proc(s: ^State, shell: ^platform.Shell) {
	d := &s.data
	d.wake = shell.request_redraw
	if d.fake {
		return
	}
	session_open(d)
	if d.saved_auth != nil {
		// partial: a login approved before the unload may not have loaded
		// its session yet. Its Login_Wait finishes it with these tokens.
		auth_restore(d.session, d.saved_auth, partial = true)
		delete(d.saved_auth, runtime.heap_allocator())
		d.saved_auth = nil
	}
	tidal.backoff_restore(d.session, d.saved_backoff, small_str(&d.saved_reason))
	d.saved_backoff = {}
	workers_start(d)
}

// data_shutdown stops the workers and frees everything Data owns but the
// cover textures, which render.destroy releases with the rest.
data_shutdown :: proc(s: ^State) {
	d := &s.data
	workers_stop(d)
	for {
		res, ok := jobs.try_pop(&d.results)
		if !ok {
			break
		}
		result_free(&res)
	}
	if d.session != nil {
		tidal.session_destroy(d.session)
		d.session = nil
	}
	delete(d.saved_auth, runtime.heap_allocator())
	sidebar_free(d)
	if d.view.has_arena {
		vmem.arena_destroy(&d.view.arena)
	}
}

// api_override returns TIDALFAST_API if the app may use it, else "". It
// sends every request, login and cover to that URL instead of TIDAL, for
// running against tests/mock_tidal. The login goes to that server too, so
// it's only honoured in debug builds and only for this machine: anywhere
// else could collect the tokens of whoever logs in.
api_override :: proc() -> string {
	api := os.get_env("TIDALFAST_API", context.temp_allocator)
	if api == "" {
		return ""
	}
	when !ODIN_DEBUG {
		fmt.eprintln("app: TIDALFAST_API is ignored in release builds")
		return ""
	} else {
		if !is_loopback_url(api) || len(api) > len(Small{}.buf) {
			fmt.eprintln("app: TIDALFAST_API must be an http(s) URL on 127.0.0.1, ::1 or localhost, ignoring it")
			return ""
		}
		return api
	}
}

// is_loopback_url says whether url is http or https on 127.0.0.1, [::1]
// or localhost, with an optional port and path.
is_loopback_url :: proc(url: string) -> bool {
	rest: string
	switch {
	case strings.has_prefix(url, "http://"):
		rest = url[len("http://"):]
	case strings.has_prefix(url, "https://"):
		rest = url[len("https://"):]
	case:
		return false
	}
	if end := strings.index_any(rest, "/?#"); end >= 0 {
		rest = rest[:end]
	}
	host, port := rest, ""
	if strings.has_prefix(rest, "[") {
		close := strings.index_byte(rest, ']')
		if close < 0 {
			return false
		}
		host, port = rest[1:close], rest[close + 1:]
	} else if colon := strings.index_byte(rest, ':'); colon >= 0 {
		host, port = rest[:colon], rest[colon:]
	}
	if port != "" {
		if len(port) < 2 || port[0] != ':' {
			return false
		}
		for c in port[1:] {
			if c < '0' || c > '9' {
				return false
			}
		}
	}
	return host == "127.0.0.1" || host == "::1" || strings.equal_fold(host, "localhost")
}

// session_open makes the session for this dylib, pointed at d.api if set.
session_open :: proc(d: ^Data) {
	s := tidal.session_create(allocator = runtime.heap_allocator())
	if api := small_str(&d.api); api != "" {
		a := vmem.arena_allocator(&s.arena)
		base := strings.concatenate({strings.trim_right(api, "/"), "/"}, a)
		s.config.api_v1_location = base
		s.config.api_v2_location = strings.concatenate({base, "v2/"}, a)
		s.config.api_oauth2_token = strings.concatenate({base, "oauth2/token"}, a)
		s.config.api_device_auth = strings.concatenate({base, "oauth2/device_authorization"}, a)
		s.config.image_url = strings.concatenate({base, "images/%s/%dx%d.jpg"}, a)
	}
	s.on_auth_change = auth_changed
	s.on_auth_change_data = d
	d.session = s
}

// keychain_service is where the login goes. Against a mock server,
// TIDALFAST_KEYCHAIN can name another item, so test runs of differently
// signed builds don't share one and the Keychain doesn't ask for access.
keychain_service :: proc(d: ^Data) -> string {
	return small_str(&d.keychain)
}

// Stored_Auth is what goes in the Keychain item, as JSON.
Stored_Auth :: struct {
	token_type:    string,
	access_token:  string,
	refresh_token: string,
	expiry:        i64, // unix seconds, 0 for none
	session_id:    string,
	country_code:  string,
	locale:        string,
	user_id:       i64,
	is_pkce:       bool,
}

auth_marshal :: proc(a: tidal.Auth, allocator: runtime.Allocator) -> []u8 {
	st := Stored_Auth {
		token_type    = a.token_type,
		access_token  = a.access_token,
		refresh_token = a.refresh_token,
		session_id    = a.session_id,
		country_code  = a.country_code,
		locale        = a.locale,
		user_id       = a.user_id,
		is_pkce       = a.is_pkce,
	}
	if t, ok := a.expiry_time.?; ok {
		st.expiry = time.to_unix_seconds(t)
	}
	data, _ := json.marshal(st, allocator = allocator)
	return data
}

// auth_restore puts stored login state into the session. False if it holds
// no usable login. With partial, tokens without a user are restored too
// (and true returned): a device login that got its tokens but hasn't loaded
// the session yet.
auth_restore :: proc(s: ^tidal.Session, data: []u8, partial := false) -> bool {
	st: Stored_Auth
	if json.unmarshal(data, &st, allocator = context.temp_allocator) != nil {
		return false
	}
	if st.access_token == "" && st.refresh_token == "" {
		return false
	}
	if st.user_id == 0 && (!partial || st.access_token == "") {
		return false
	}
	a := tidal.Auth {
		token_type    = st.token_type,
		access_token  = st.access_token,
		refresh_token = st.refresh_token,
		session_id    = st.session_id,
		country_code  = st.country_code,
		locale        = st.locale,
		is_pkce       = st.is_pkce,
		user_id       = st.user_id,
		user_kind     = .Logged_In_User,
	}
	if st.expiry != 0 {
		a.expiry_time = time.unix(st.expiry, 0)
	}
	tidal.session_restore(s, a)
	return true
}

// auth_load reads the Keychain item into the session. It runs on a worker:
// macOS may ask the user whether this build may read the item, and that
// blocks the caller until they answer.
auth_load :: proc(d: ^Data, res: ^Result) -> bool {
	data, status := mac.keychain_get(keychain_service(d), KEYCHAIN_ACCOUNT, context.temp_allocator)
	if status == mac.ERR_SEC_ITEM_NOT_FOUND {
		return false
	}
	if status != mac.ERR_SEC_SUCCESS {
		res.message = small(fmt.tprintf("Couldn't read the Keychain (error %d)", status))
		return false
	}
	return auth_restore(d.session, data)
}

// auth_changed is the session's on_auth_change: after a login or a token
// refresh, on whichever worker did it, the new tokens go to the Keychain.
// TIDAL may rotate the refresh token on refresh, and the old one stops
// working, so this happens every time. Tokens from a login that sign_out
// has cleared since are never saved: with keychain_mutex held, the epoch
// they were read in must still be the session's.
auth_changed :: proc(s: ^tidal.Session, data: rawptr) {
	d := (^Data)(data)
	sync.atomic_store(&d.refresh_errors, 0)
	a := tidal.session_auth(s, context.temp_allocator)
	if a.user_id == 0 || (a.access_token == "" && a.refresh_token == "") {
		return
	}
	sync.guard(&d.keychain_mutex)
	if a.epoch != tidal.session_epoch(s) {
		return
	}
	bytes := auth_marshal(a, context.temp_allocator)
	if status := mac.keychain_set(keychain_service(d), KEYCHAIN_ACCOUNT, bytes); status != mac.ERR_SEC_SUCCESS {
		fmt.eprintfln("app: couldn't save the login to the Keychain (error %d)", status)
	}
}

Held_Job :: struct {
	job:      Job,
	priority: u8,
}

// push_job queues job for the current login. If the queue is full the
// kind goes in d.retry, and data_update tries again next frame. A worker
// finishing a job frees a slot and asks for that frame.
push_job :: proc(d: ^Data, job: Job, priority: u8 = PRIORITY_DATA) -> bool {
	job := job
	job.auth = d.auth_gen
	if !jobs.push(&d.queue, job, priority) {
		if job.kind == .Stream || job.kind == .Artwork {
			hold_job(d, job, priority)
		} else {
			d.retry += {job.kind}
		}
		return false
	}
	return true
}

// hold_job keeps a refused playback job for the next frame. When the list is
// full the oldest goes, since its track has most likely moved on.
@(private = "file")
hold_job :: proc(d: ^Data, job: Job, priority: u8) {
	for &h in d.held {
		if h.job.kind == .None {
			h = {job, priority}
			return
		}
	}
	copy(d.held[:], d.held[1:])
	d.held[len(d.held) - 1] = {job, priority}
}

@(private = "file")
drop_account_job :: proc(job: ^Job, _: rawptr) -> bool {
	return job.kind != .Cover
}

// sign_out ends a login TIDAL no longer accepts. Results of jobs queued
// before it are dropped when they arrive, so however many requests fail,
// the login ends once and one new login starts. Queued jobs for the old
// login go, the ones in flight are cancelled (session_clear_auth), and the
// Keychain item is deleted. Playback stops and its queue goes.
sign_out :: proc(s: ^State, why: string) {
	d := &s.data
	d.auth_gen += 1
	d.retry = {}
	d.held = {}
	jobs.remove_if(&d.queue, drop_account_job, nil)
	tidal.session_clear_auth(d.session)
	{
		sync.guard(&d.keychain_mutex)
		mac.keychain_delete(keychain_service(d), KEYCHAIN_ACCOUNT)
	}
	d.account = .Signed_Out
	d.login = {
		note = small(why),
	}
	sidebar_free(d)
	view_close(d)
	playback_stop(s)
	s.library.playlist = 0
	request_login_code(d)
}

// request_login_code starts a device login. If an approved login still
// has its tokens, as after a failure loading the session, it loads the
// session with them instead: the code is spent, and the user approved.
request_login_code :: proc(d: ^Data) {
	if d.login.requested || d.login.waiting {
		return
	}
	if login_has_tokens(d) {
		d.login.note = small("Loading your account…")
		request_login_poll(d)
		return
	}
	d.login.requested = push_job(d, {kind = .Login_Start})
}

// login_has_tokens says whether the device login got its tokens but hasn't
// loaded the session yet. The code is spent then, and its expiry no longer
// matters: Login_Wait finishes with the tokens.
login_has_tokens :: proc(d: ^Data) -> bool {
	a := tidal.session_auth(d.session, context.temp_allocator)
	return a.access_token != "" && a.user_id == 0
}

// request_login_poll queues the poll for the code on screen.
request_login_poll :: proc(d: ^Data) {
	l := &d.login
	if l.waiting {
		return
	}
	l.waiting = push_job(d, {kind = .Login_Wait, id = l.link.device_code, interval = l.link.interval, deadline = l.deadline, not_before = l.poll_at, once = l.poll_once})
}

request_playlists :: proc(d: ^Data) {
	if d.sidebar.loading {
		return
	}
	d.sidebar.loading = push_job(d, {kind = .Playlists})
}

// data_retry pushes again what the queue refused last frame, if it's still
// wanted.
data_retry :: proc(d: ^Data) {
	held := d.held
	d.held = {}
	for h in held {
		if h.job.kind != .None && h.job.auth == d.auth_gen {
			push_job(d, h.job, h.priority)
		}
	}
	kinds := d.retry
	d.retry = {}
	for kind in kinds {
		#partial switch kind {
		case .Restore:
			if d.account == .Restoring {
				push_job(d, {kind = .Restore})
			}
		case .Login_Start:
			if d.account == .Signed_Out && d.login.error.len == 0 {
				request_login_code(d)
			}
		case .Login_Wait:
			if d.account == .Signed_Out && (d.login.link.device_code.len > 0 || login_has_tokens(d)) {
				request_login_poll(d)
			}
		case .Playlists:
			if d.account == .Signed_In {
				request_playlists(d)
			}
		case .Tracks:
			view_request_pages(d)
		}
	}
}

sidebar_free :: proc(d: ^Data) {
	if d.sidebar.arena != nil {
		vmem.arena_destroy(d.sidebar.arena)
		free(d.sidebar.arena, runtime.heap_allocator())
	}
	d.sidebar = {}
}

// data_update takes the workers' results. Cover uploads stop after
// UPLOAD_BUDGET; the rest wait for the next frame. Call it after
// ui.begin_frame, so it can ask for that frame.
data_update :: proc(s: ^State, now: f64) {
	d := &s.data
	if d.fake {
		return
	}
	begin := time.tick_now()
	for time.tick_since(begin) < UPLOAD_BUDGET {
		res, ok := jobs.try_pop(&d.results)
		if !ok {
			break
		}
		handle_result(s, &res, now)
		result_free(&res)
		ui.data_changed()
	}
	if queued, _ := jobs.pending(&d.results); queued > 0 {
		ui.request_frame()
	}
	data_retry(d)
	d.bench.upload_ms = f32(time.duration_milliseconds(time.tick_since(begin)))
}

handle_result :: proc(s: ^State, res: ^Result, now: f64) {
	d := &s.data
	// From a login sign_out has ended. Covers don't depend on the login.
	if res.job.kind != .Cover && res.job.auth != d.auth_gen {
		return
	}
	err, failed := res.err.?
	// Only jobs that sent the login's tokens can end it. A cover carries no
	// token, and a login job's .Authentication means the user denied it.
	if failed && err == .Authentication && res.job.kind != .Cover && res.job.kind != .Login_Start && res.job.kind != .Login_Wait {
		sign_out(s, "Your TIDAL session ended. Log in again.")
		return
	}
	switch res.job.kind {
	case .None:
	case .Restore:
		if res.message.len > 0 {
			d.message = res.message
		}
		if res.signed_in {
			d.account = .Signed_In
			request_playlists(d)
		} else {
			d.account = .Signed_Out
			request_login_code(d)
		}
	case .Login_Start:
		l := &d.login
		l.requested = false
		if failed {
			l^ = {
				error = login_error(err, res.message),
			}
			return
		}
		l^ = {
			link     = res.link,
			note     = l.note,
			deadline = time.tick_add(time.tick_now(), time.Duration(f64(res.link.expires) * f64(time.Second))),
		}
		request_login_poll(d)
	case .Login_Wait:
		login_wait_done(d, res, err, failed)
	case .Playlists:
		d.sidebar.loading = false
		if failed {
			d.message = res.message
			return
		}
		sidebar_free(d)
		d.sidebar = {
			arena       = res.arena,
			items       = res.playlists,
			liked_count = res.liked_count,
			loaded      = true,
		}
		res.arena = nil
		if d.view.source == .None {
			select_playlist(s, 0)
		}
	case .Tracks:
		v := &d.view
		if res.job.view != v.gen {
			return
		}
		v.in_flight -= 1
		if failed {
			v.error = res.message
			v.done = true
			return
		}
		view_add_rows(v, int(res.job.offset), res.rows, len(res.rows) < int(res.job.limit))
		view_request_pages(d)
	case .Stream, .Artwork:
		playback_result(s, res)
	case .Search:
		search_result(s, res)
	case .Cover:
		key := res.job.key
		if failed || res.pixels == nil {
			cover.set_failed(&d.covers, key, now)
			return
		}
		r := &s.renderer
		t := render.texture_create(r, res.w, res.h, .RGBA8, mipmapped = true)
		render.texture_update(r, t, res.pixels, 0, 0, res.w, res.h, converted = true)
		if !cover.set_ready(&d.covers, key, t, res.w, res.h, now) {
			render.texture_destroy(r, t)
		}
		d.bench.uploads += 1
		d.bench.frame_uploads += 1
	}
}

// login_wait_done handles the end of a Login_Wait. A code that expired is
// replaced. While TIDAL can't be reached (a network failure, a 5xx or a
// 408, see run_login_wait) and the code is still good, or the login has
// its tokens, the app checks again after 2, 4, 8 up to LOGIN_RETRY_MAX
// seconds, once per try, and goes back to polling as soon as TIDAL
// answers.
@(private = "file")
login_wait_done :: proc(d: ^Data, res: ^Result, err: tidal.Error_Kind, failed: bool) {
	l := &d.login
	l.waiting = false
	if res.link.interval > 0 {
		l.link.interval = res.link.interval
	}
	if !failed {
		d.login = {}
		d.account = .Signed_In
		request_playlists(d)
		return
	}
	expired := time.tick_diff(time.tick_now(), l.deadline) <= 0 && !login_has_tokens(d)
	#partial switch err {
	case .Timeout:
		if res.job.once && !expired {
			// TIDAL answered the check, which counts as a poll.
			l.note = {}
			l.retries = 0
			l.poll_at = time.tick_add(time.tick_now(), time.Duration(f64(l.link.interval) * f64(time.Second)))
			l.poll_once = false
			request_login_poll(d)
			return
		}
		d.login = {
			note = small("The code expired. Here's a new one."),
		}
		request_login_code(d)
	case .Network:
		if expired {
			d.login = {
				note = small("The code expired. Here's a new one."),
			}
			request_login_code(d)
			return
		}
		l.retries += 1
		// The poll may have reached TIDAL, so the next one waits at least
		// the interval.
		wait := max(min(1 << uint(min(l.retries, 5)), LOGIN_RETRY_MAX), int(math.ceil(l.link.interval)))
		l.poll_at = time.tick_add(time.tick_now(), time.Duration(wait) * time.Second)
		l.poll_once = true
		l.note = small(fmt.tprintf("Can't reach TIDAL. Trying again in %d s.", wait))
		request_login_poll(d)
	case:
		if err == .Authentication && login_has_tokens(d) {
			// TIDAL refused the tokens, so "Try again" needs a new code.
			tidal.session_clear_auth(d.session)
		}
		d.login = {
			error = login_error(err, res.message),
		}
	}
}

@(private = "file")
login_error :: proc(err: tidal.Error_Kind, message: Small) -> Small {
	#partial switch err {
	case .Network:
		return small("Can't reach TIDAL. Check your connection.")
	case .Authentication:
		return small("The login was denied.")
	}
	return message
}

// select_playlist opens sidebar entry i: Liked Songs first, then the
// playlists.
select_playlist :: proc(s: ^State, i: int) {
	lib := &s.library
	if search_leave(s) || lib.playlist != i {
		lib.selected = -1
		lib.playing = -1
		lib.status = .None
	}
	lib.playlist = i
	d := &s.data
	if d.fake {
		return
	}
	if i == 0 {
		view_open(d, .Liked, "", "Liked Songs", "", d.sidebar.liked_count)
	} else if i - 1 < len(d.sidebar.items) {
		pl := d.sidebar.items[i - 1]
		view_open(d, .Playlist, pl.id, pl.name, pl.image, pl.tracks)
	}
}

@(private = "file")
drop_track_jobs :: proc(job: ^Job, _: rawptr) -> bool {
	return job.kind == .Tracks
}

view_close :: proc(d: ^Data) {
	jobs.remove_if(&d.queue, drop_track_jobs, nil)
	v := &d.view
	if v.has_arena {
		vmem.arena_destroy(&v.arena)
	}
	v^ = {gen = v.gen + 1}
}

view_open :: proc(d: ^Data, source: Source, id, name, image: string, hint: int) {
	view_close(d)
	v := &d.view
	v.source = source
	v.id = small(id)
	v.name = small(name)
	v.image = small(image)
	v.hint = hint
	v.count = hint
	v.has_arena = vmem.arena_init_growing(&v.arena) == nil
	view_reserve(v, max(hint, PAGE_FIRST))
	view_request_pages(d)
}

// view_reserve makes room for n rows.
@(private = "file")
view_reserve :: proc(v: ^Track_View, n: int) {
	if n <= len(v.rows) || !v.has_arena {
		return
	}
	a := vmem.arena_allocator(&v.arena)
	rows := make([]Row, max(n, 2 * len(v.rows)), a)
	loaded := make([]bool, len(rows), a)
	copy(rows, v.rows)
	copy(loaded, v.loaded)
	v.rows, v.loaded = rows, loaded
}

// view_add_rows copies a page into the view. A short page ends the list,
// and the earliest end found stands: pages arrive out of order, and an
// empty page asked for past the end mustn't bring back rows a short page
// before it cut. Rows past the end are dropped. Until the end is known, a
// full page past the count TIDAL gave grows the list.
view_add_rows :: proc(v: ^Track_View, offset: int, rows: []Row, last: bool) {
	rows := rows
	end := offset + len(rows)
	if last && (!v.done || end < v.count) {
		v.done = true
		v.count = end
	}
	if v.done {
		rows = rows[:clamp(v.count - offset, 0, len(rows))]
	} else {
		v.count = max(v.count, end)
	}
	view_reserve(v, offset + len(rows))
	if !v.has_arena {
		return
	}
	a := vmem.arena_allocator(&v.arena)
	for r, i in rows {
		v.rows[offset + i] = {
			title    = strings.clone(r.title, a),
			artist   = strings.clone(r.artist, a),
			album    = strings.clone(r.album, a),
			added    = strings.clone(r.added, a),
			duration = strings.clone(r.duration, a),
			cover    = strings.clone(r.cover, a),
			seconds  = r.seconds,
			id       = r.id,
			album_id = r.album_id,
			artist_id = r.artist_id,
			track    = r.track,
		}
		v.loaded_rows += int(!v.loaded[offset + i])
		v.loaded[offset + i] = true
	}
}

// view_request_pages keeps PAGES_IN_FLIGHT pages loading until a short page
// says the list has ended. The first page is small so it shows sooner.
view_request_pages :: proc(d: ^Data) {
	v := &d.view
	for v.source != .None && !v.done && v.in_flight < PAGES_IN_FLIGHT && (v.next_offset < v.hint || v.in_flight == 0) {
		limit := PAGE_FIRST if v.next_offset == 0 else PAGE_SIZE
		job := Job {
			kind   = .Tracks,
			source = v.source,
			view   = v.gen,
			offset = i32(v.next_offset),
			limit  = i32(limit),
			id     = v.id,
		}
		if !push_job(d, job) {
			return // d.retry has it
		}
		v.next_offset += limit
		v.in_flight += 1
	}
}

// What the library screen shows, from the fake data or the live data.

Sidebar_Entry :: struct {
	name:     string,
	subtitle: string,
	image:    string, // playlist image id, "" for a placeholder
	seed:     u32, // the placeholder gradient's
}

sidebar_count :: proc(s: ^State) -> int {
	d := &s.data
	if d.fake {
		return len(PLAYLISTS)
	}
	if d.account != .Signed_In {
		return 0
	}
	return 1 + len(d.sidebar.items)
}

sidebar_entry :: proc(s: ^State, i: int) -> Sidebar_Entry {
	d := &s.data
	seed := u32(i) * 7919 + 13
	if d.fake {
		return {PLAYLISTS[i], fmt.tprintf("Playlist · %d songs", ROW_COUNT if i == 0 else 20 + i * 37 % 300), "", seed}
	}
	if i == 0 {
		songs := fmt.tprintf("Playlist · %d songs", d.sidebar.liked_count) if d.sidebar.loaded else "Playlist"
		return {"Liked Songs", songs, "", seed}
	}
	pl := d.sidebar.items[i - 1]
	return {pl.name, fmt.tprintf("Playlist · %d songs", pl.tracks), pl.image, seed}
}

view_title :: proc(s: ^State) -> string {
	d := &s.data
	if title, _, ok := browse_header(s); ok {
		return title
	}
	if d.fake {
		return PLAYLISTS[s.library.playlist]
	}
	if d.view.source == .None {
		return "Your Library" if d.sidebar.loaded else "Loading your library…"
	}
	return small_str(&d.view.name)
}

view_subtitle :: proc(s: ^State, main_w: f32) -> string {
	d := &s.data
	if _, subtitle, ok := browse_header(s); ok {
		return subtitle
	}
	if d.fake {
		lib := &s.library
		count := ROW_COUNT if lib.playlist == 0 else 20 + lib.playlist * 37 % 300
		return fmt.tprintf("Playlist · %d songs · %d px wide", count, int(main_w))
	}
	v := &d.view
	if d.account == .Restoring {
		return "Reading your login from the Keychain. If macOS asks, allow TIDALfast to use it."
	}
	if v.source == .None {
		return ""
	}
	if !v.done {
		return fmt.tprintf("Playlist · %d songs · loading, %d so far", v.count, v.loaded_rows)
	}
	return fmt.tprintf("Playlist · %d songs", v.count)
}

// data_status is a line for the header: rate limiting, errors, or "".
data_status :: proc(s: ^State) -> string {
	d := &s.data
	if d.fake || d.session == nil {
		return ""
	}
	if wait := tidal.backoff_remaining(d.session); wait > 0 {
		return fmt.tprintf("TIDAL asked us to slow down. Trying again in %d s.", int(wait + 0.5))
	}
	if d.view.error.len > 0 {
		return small_str(&d.view.error)
	}
	if status := search_status(s); status != "" {
		return status
	}
	return small_str(&d.message)
}

view_count :: proc(s: ^State) -> int {
	if s.data.fake {
		if n, listed := fake_count(s); listed {
			return n
		}
		return ROW_COUNT
	}
	return s.data.view.count
}

// view_row returns row i of the open list, or nil while it's loading.
view_row :: proc(s: ^State, i: int) -> ^Row {
	if s.data.fake {
		if row, listed := fake_row(s, i); listed {
			return row
		}
		return &s.rows[i] if i >= 0 && i < len(s.rows) else nil
	}
	v := &s.data.view
	if i < 0 || i >= len(v.loaded) || !v.loaded[i] {
		return nil
	}
	return &v.rows[i]
}

// show_login says whether the library screen should be the login screen.
show_login :: proc(s: ^State) -> bool {
	return s.data.account == .Signed_Out
}
