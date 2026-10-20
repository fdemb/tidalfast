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
import "core:log"
import "core:math"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../cover"
import "../jobs"
import "../os_services"
import "../platform"
import "../render"
import "../tidal"
import "../ui"

KEYCHAIN_SERVICE :: "tidalfast"
KEYCHAIN_MOCK_SERVICE :: "tidalfast-mock" // with TIDALFAST_API
KEYCHAIN_ACCOUNT :: "auth"
COVER_BUDGET :: 8 << 20 // cover page bytes: a few screens of covers, see cover.place
UPLOAD_BUDGET :: 2 * time.Millisecond // cover uploads per frame
PAGES_IN_FLIGHT :: 2
LOGIN_RETRY_MAX :: 30 // seconds between polls while TIDAL can't be reached
PKCE_REDIRECT_MAX :: 2048 // bytes of a pasted redirect address

Account :: enum u8 {
	Fake,
	Restoring, // reading the Keychain
	Signed_Out,
	Signed_In,
}

// Login is the login screen: the card it shows, and how far the
// device-code login got. That one keeps its step while the PKCE card
// shows, so going back to it polls the same code, or waits for the job
// still out before it asks for another.
Login :: struct {
	card:        Login_Card,
	code:        Code_Step,
	field:       ui.Text_Field, // the pasted redirect address
	focus_field: bool, // the field takes the focus next frame
	note:        Small, // shown on the card while the login goes on
}

// Login_Card is the card on the login screen. The PKCE login is the main
// one, so it's the zero value.
Login_Card :: union #no_nil {
	Login_Paste,
	Login_Exchanging,
	Login_Code,
}

// Login_Paste is the PKCE login waiting for the redirect address.
Login_Paste :: struct {
	note: Small, // why the last paste didn't work
}

// Login_Exchanging is the PKCE login with its Login_Pkce job out.
Login_Exchanging :: struct {}

// Login_Code is the device-code login, see Login.code.
Login_Code :: struct {}

// Code_Step is how far the device-code login got. nil before it asks for a
// code.
Code_Step :: union {
	Code_Asked,
	Code_Polling,
	Code_Failed,
}

// Code_Asked has a Login_Start job out.
Code_Asked :: struct {
	attempt: u32, // the login attempt it's for
}

// Code_Polling waits for the user to approve the code on screen. A login
// that has its tokens polls with no code, to load the session with them.
Code_Polling :: struct {
	link:     Login_Link,
	deadline: time.Tick, // when the code expires
	poll_at:  time.Tick, // the next Login_Wait polls no sooner
	once:     bool, // it checks once whether TIDAL can be reached again
	retries:  int, // polls in a row that couldn't reach TIDAL
	out:      bool, // a Login_Wait job is out
}

// Code_Failed is a stopped login; the card offers "Try again".
Code_Failed :: struct {
	error: Small,
}

Sidebar :: struct {
	arena:        ^vmem.Arena, // adopted from the Playlists result, or the file's
	items:        []Sidebar_Item,
	liked_count:  int,
	liked_newest: i64, // the newest liked track's id
	loading:      bool,
	loaded:       bool,
	fresh:        bool, // from TIDAL, not from disk
	fetched:      time.Tick, // when TIDAL's came
}

// Track_View is a track list: the open one, one kept in memory after it
// closed (see lists.odin), or the open one being fetched again. Its rows,
// their loaded flags and its gaps live in space, their strings in its arena.
// gen tells its pages from those of other lists.
Track_View :: struct {
	gen:         u32,
	source:      Source,
	id:          Small,
	name:        Small,
	image:       Small,
	hint:        int, // tracks TIDAL said the list has
	arena:       vmem.Arena,
	has_arena:   bool, // arena and space are there
	space:       []u8, // reserved, see ROWS_MAX
	rows:        []Row, // in space
	loaded:      []bool, // in space
	loaded_rows: int,
	count:       int, // rows shown, loaded or not
	next_offset: int, // in TIDAL's offsets, which count the gaps
	in_flight:   int,
	done:        bool,
	error:       Small,
	gaps:        []Gap, // in space, by offset
	longest:     int, // seconds, of the longest track loaded
	version:     List_Version, // what TIDAL said the list was at when it was fetched
	fetched:     i64, // unix seconds the rows came from TIDAL; 0 until they all have
	reading:     bool, // waiting for its file
	found:       Found_Lists, // .Search: the albums, artists and playlists found, in arena
}

// Gap is where a page came back short before the end of its list: TIDAL
// leaves out tracks that can't be played but still counts them. The rows
// after it move up, so row i is at TIDAL's offset i plus the gaps before it.
Gap :: struct {
	offset:  int, // the page's
	missing: int,
}

Data :: struct {
	fake:           bool,
	mock:           bool, // api is set
	api:            Small, // TIDALFAST_API once checked, "" for TIDAL
	keychain:       Keychain, // where the login goes
	account:        Account,
	// Goes up with every sign_out. Jobs carry the one they were queued in,
	// and results from an older one are dropped.
	auth_gen:       u32,
	// Jobs the queue refused, oldest first, pushed again next frame while
	// they're still wanted. See hold_job.
	held:           [HELD_JOBS]Held_Job,
	held_count:     int,
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
	// The hi-res login's PKCE verifier and client key. A new session on
	// reload takes them, so a login page opened before it still works.
	pkce_verifier:  Small,
	pkce_key:       Small,
	// The pasted redirect address, for the Login_Pkce job. The UI writes
	// it only while no such job is out.
	pkce_mutex:     sync.Mutex,
	pkce_redirect:  [PKCE_REDIRECT_MAX]u8,
	pkce_len:       int,
	// Goes up when a login starts or the user switches between the device
	// and hi-res logins. Login jobs carry it (their attempt) and the session
	// drops tokens from an older one, so a late answer to an abandoned login
	// can't replace the one the user finished.
	login_attempt:  u32,
	// The signed-in login is the device-code client's, which TIDAL gives
	// only AAC. The library says so until the user hides the notice.
	device_login:   bool,
	notice_hidden:  bool,
	relogin:        bool, // the login screen shows over a signed-in account
	settings_store: Settings_Store,
	launch_log_path: string, // heap, "" for no launch log
	sidebar:        Sidebar,
	view:           Track_View,
	refresh:        Track_View, // the open list fetched again, see refresh_start
	// The list the play queue follows, still loading after it closed, see
	// view_close. queue_view is that list's gen, open or not.
	queued:         Track_View,
	queue_view:     u32,
	next_gen:       u32, // the last Track_View.gen handed out
	lists:          Lists, // closed lists and the disk cache, see lists.odin
	liked:          Liked_Set, // the liked track ids the hearts show, see liked.odin
	followed:       Followed_Set, // the followed artist ids the Follow buttons show, see followed.odin
	artists:        Artist_Cache, // artist pages, see artist_data.odin
	window_key:     bool, // the window had the keyboard last frame
	// Debug builds and tests keep the last list freed (view_free) filled
	// with POISON until the next one is, so a string or row still borrowed
	// from it reads as garbage instead of whatever the next list put there.
	poison:         bool,
	retired:        Track_View,
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
	d.poison = ODIN_DEBUG
	// Checked even with fake data, so a refused TIDALFAST_API is always
	// logged.
	api := api_override()
	_, wants_api := os.lookup_env("TIDALFAST_API", context.temp_allocator)
	_, wants_keychain := os.lookup_env("TIDALFAST_KEYCHAIN", context.temp_allocator)
	_, wants_pkce := os.lookup_env("TIDALFAST_PKCE_REDIRECT", context.temp_allocator)
	run := run_decide(
		{
			fake = os.get_env("TIDALFAST_FAKE", context.temp_allocator),
			bench = bench,
			api = api,
			wants_mock = wants_api || wants_keychain || wants_pkce,
			keychain = os.get_env("TIDALFAST_KEYCHAIN", context.temp_allocator),
			settings = os.get_env("TIDALFAST_SETTINGS", context.temp_allocator),
			config_dir = os_services.config_dir(context.temp_allocator),
		},
		runtime.heap_allocator(),
	)
	if run.fallback {
		log.warn("app: TIDALFAST_API, TIDALFAST_KEYCHAIN or TIDALFAST_PKCE_REDIRECT is set without a mock URL the app takes, showing the fake data instead of TIDAL")
	}
	d.settings_store.path = run.settings
	s.settings, _ = settings_load(d.settings_store.path)
	d.fake = run.mode == .Fake
	if d.fake {
		d.account = .Fake
		return
	}
	d.mock = run.mode == .Mock
	d.lists.memory = true
	d.lists.root = lists_root(d.mock)
	d.bench.running = bench == "covers"
	d.api = small(api)
	d.keychain = Os_Keychain{small(run.keychain)}
	session_open(d)
	d.account = .Restoring
	push_job(d, {payload = Restore_Job{}})
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
	delete(d.settings_store.path, runtime.heap_allocator())
	d.settings_store.path = ""
	delete(d.launch_log_path, runtime.heap_allocator())
	d.launch_log_path = ""
	sidebar_free(d)
	lists_shutdown(d)
	liked_clear(d)
	followed_clear(d)
	artist_clear(d)
	view_release(&d.view)
	view_release(&d.queued)
	view_release(&d.refresh)
	view_release(&d.retired)
}

Run_Mode :: enum {
	Real,
	Mock,
	Fake,
}

// Run_Env is what data_start reads from the environment to pick the run.
Run_Env :: struct {
	fake, bench: string, // TIDALFAST_FAKE, TIDALFAST_BENCH
	api:         string, // api_override, "" for no mock URL
	wants_mock:  bool, // TIDALFAST_API, TIDALFAST_KEYCHAIN or TIDALFAST_PKCE_REDIRECT is set, even empty
	keychain:    string, // TIDALFAST_KEYCHAIN
	settings:    string, // TIDALFAST_SETTINGS
	config_dir:  string, // os_services.config_dir
}

Run :: struct {
	mode:     Run_Mode,
	fallback: bool, // Fake because the mock was asked for without a mock URL
	keychain: string, // the Keychain service, "" for fake data
	settings: string, // the settings file, "" for none, allocated with allocator
}

// run_decide picks fake data, the mock or TIDAL. A run that asks for the
// mock without a mock URL the app takes gets the fake data, as falling back
// to TIDAL would use the user's login. Fake data gets no settings file
// unless TIDALFAST_SETTINGS names one, and none after that fallback, as
// the user's could turn on bit-perfect output for the loud test tones.
run_decide :: proc(env: Run_Env, allocator: runtime.Allocator) -> (run: Run) {
	fake := env.fake != "" || (env.bench != "" && env.bench != "covers")
	switch {
	case fake:
		run.mode = .Fake
	case env.api == "" && env.wants_mock:
		run.mode = .Fake
		run.fallback = true
		return
	case env.api != "":
		run.mode = .Mock
		run.keychain = KEYCHAIN_MOCK_SERVICE
		if env.keychain != "" && env.keychain != KEYCHAIN_SERVICE {
			run.keychain = env.keychain
		}
	case:
		run.mode = .Real
		run.keychain = KEYCHAIN_SERVICE
	}
	if env.settings != "" {
		run.settings = strings.clone(env.settings, allocator)
	} else if run.mode != .Fake && env.config_dir != "" {
		run.settings = strings.concatenate({env.config_dir, "/tidalfast/settings.json"}, allocator)
	}
	return
}

// MOCK_API lets an optimized build read TIDALFAST_API and
// TIDALFAST_PKCE_REDIRECT. Only `./build.sh measure` sets it, for
// tools/measure's runs against tests/mock_tidal; the release build never does.
MOCK_API :: #config(TIDALFAST_MOCK_API, false)

// api_override returns TIDALFAST_API if the app may use it, else "". It
// sends every request, login and cover to that URL instead of TIDAL, for
// running against tests/mock_tidal. The login goes to that server too, so
// it's only honoured in debug builds (and MOCK_API ones) and only for this
// machine: anywhere else could collect the tokens of whoever logs in.
api_override :: proc() -> string {
	api := os.get_env("TIDALFAST_API", context.temp_allocator)
	if api == "" {
		return ""
	}
	when !ODIN_DEBUG && !MOCK_API {
		log.warn("app: release builds don't take TIDALFAST_API")
		return ""
	} else {
		if !is_loopback_url(api) || len(api) > len(Small{}.buf) {
			log.warn("app: TIDALFAST_API must be an http(s) URL on 127.0.0.1, ::1 or localhost")
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
		s.config.api_pkce_auth = strings.concatenate({base, "authorize"}, a)
		s.config.pkce_uri_redirect = strings.concatenate({base, "android/login/auth"}, a)
	}
	if d.pkce_verifier.len > 0 {
		tidal.session_set_pkce_state(s, small_str(&d.pkce_verifier), small_str(&d.pkce_key))
	}
	tidal.session_set_login_attempt(s, u64(d.login_attempt))
	s.on_auth_change = auth_changed
	s.on_auth_change_data = d
	d.session = s
}

// Keychain is where the login is kept between runs: the OS Keychain item
// for a service, or, in tests, an item in memory.
Keychain :: union {
	Os_Keychain,
	^Memory_Keychain,
}

// Os_Keychain is the item (service, KEYCHAIN_ACCOUNT). Against a mock
// server, TIDALFAST_KEYCHAIN can name another service, so test runs of
// differently signed builds don't share one and the Keychain doesn't ask
// for access.
Os_Keychain :: struct {
	service: Small,
}

// Memory_Keychain holds the item on the heap, nil for none. Workers read
// and write it, so it has a lock of its own.
Memory_Keychain :: struct {
	mutex: sync.Mutex,
	item:  []u8,
}

keychain_get :: proc(k: ^Keychain, allocator := context.allocator) -> ([]u8, os_services.Status) {
	switch &k in k {
	case Os_Keychain:
		return os_services.secret_get(small_str(&k.service), KEYCHAIN_ACCOUNT, allocator)
	case ^Memory_Keychain:
		sync.guard(&k.mutex)
		if k.item == nil {
			return nil, os_services.SECRET_NOT_FOUND
		}
		return slice.clone(k.item, allocator), os_services.SECRET_OK
	}
	return nil, os_services.SECRET_NOT_FOUND
}

keychain_set :: proc(k: ^Keychain, data: []u8) -> os_services.Status {
	switch &k in k {
	case Os_Keychain:
		return os_services.secret_set(small_str(&k.service), KEYCHAIN_ACCOUNT, data)
	case ^Memory_Keychain:
		sync.guard(&k.mutex)
		delete(k.item, runtime.heap_allocator())
		k.item = slice.clone(data, runtime.heap_allocator())
	}
	return os_services.SECRET_OK
}

keychain_delete :: proc(k: ^Keychain) -> os_services.Status {
	switch &k in k {
	case Os_Keychain:
		return os_services.secret_delete(small_str(&k.service), KEYCHAIN_ACCOUNT)
	case ^Memory_Keychain:
		sync.guard(&k.mutex)
		delete(k.item, runtime.heap_allocator())
		k.item = nil
	}
	return os_services.SECRET_OK
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
	client_id:     string, // the client the tokens belong to; refreshes must use it
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
		client_id     = a.client_id,
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
	// Items from before the client id was stored go by is_pkce alone. A
	// client this build doesn't know can't refresh; the first request finds
	// out and the login starts over.
	if st.client_id != "" {
		pkce := st.client_id == s.config.client_id_pkce
		if !pkce && st.client_id != s.config.client_id && st.client_id != s.device_client_id {
			log.warn("app: the saved login is for a client this build doesn't know")
		}
		st.is_pkce = pkce
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
	data, status := keychain_get(&d.keychain, context.temp_allocator)
	if status == os_services.SECRET_NOT_FOUND {
		return false
	}
	if status != os_services.SECRET_OK {
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
	if status := keychain_set(&d.keychain, bytes); status != os_services.SECRET_OK {
		log.errorf("app: couldn't save the login to the Keychain (error %d)", status)
	}
}

Held_Job :: struct {
	job:      Job,
	priority: u8,
}

HELD_JOBS :: 16

// push_job queues job for the current login. If the queue is full it's
// held, and data_retry pushes it again next frame, so to its caller it's
// out either way. A worker finishing a job frees a slot and asks for that
// frame.
push_job :: proc(d: ^Data, job: Job, priority: u8 = PRIORITY_DATA) {
	job := job
	job.auth = d.auth_gen
	if !jobs.push(&d.queue, job, priority) {
		hold_job(d, job, priority)
	}
}

// hold_job keeps a job the queue refused. A job that asks for what a held
// one does takes its place, so its caller's flag stays set. When the list
// is full one goes to make room, see held_victim.
@(private = "file")
hold_job :: proc(d: ^Data, job: Job, priority: u8) {
	for &h in d.held[:d.held_count] {
		if same_request(h.job, job) {
			job_free(&h.job)
			h = {job, priority}
			return
		}
	}
	if d.held_count == len(d.held) {
		i := held_victim(d)
		held_drop(d, &d.held[i].job)
		copy(d.held[i:], d.held[i + 1:])
		d.held_count -= 1
	}
	d.held[d.held_count] = {job, priority}
	d.held_count += 1
}

// same_request says whether two jobs ask for the same thing. The kinds that
// wait behind a flag or are sent one at a time each ask for one thing, and
// an Artwork asks for its track's serial. A Stream's serial and a page's
// offset are never asked for twice, and every add is its own. Only one
// follow change per artist is out, see Toggle_Out.
@(private = "file")
same_request :: proc(held, job: Job) -> bool {
	#partial switch p in job.payload {
	case Restore_Job, Login_Start_Job, Login_Wait_Job, Login_Pkce_Job, Playlists_Job, Liked_Ids_Job, Search_Job, Save_Settings_Job:
		return reflect.union_variant_typeid(held.payload) == reflect.union_variant_typeid(job.payload)
	case Artwork_Job:
		h, art := held.payload.(Artwork_Job)
		return art && h.serial == p.serial
	case Artist_Job:
		h, artist := held.payload.(Artist_Job)
		return artist && h == p
	}
	return false
}

// held_victim is the held job to drop for a new one: one no longer wanted,
// else the oldest Stream, Artwork or Add_Track, whose track has most likely
// moved on, Artist, whose page asks again, or Follow, whose button goes
// back. hold_job keeps one of each other kind and view_pages one page per
// list, so they never fill the list.
@(private = "file")
held_victim :: proc(d: ^Data) -> int {
	held := d.held[:d.held_count]
	for h, i in held {
		if !held_wanted(d, h.job) {
			return i
		}
	}
	for h, i in held {
		#partial switch _ in h.job.payload {
		case Stream_Job, Artwork_Job, Add_Track_Job, Artist_Job, Follow_Job:
			return i
		}
	}
	when ODIN_DEBUG || ODIN_TEST {
		panic("the hold list is full of jobs that wait behind a flag")
	}
	return 0
}

// held_drop lets go of a held job that won't be pushed. Its caller counted
// it as out, so the flag holding back the next one is cleared. A like,
// unlike or follow change never reached TIDAL, so its button goes back.
@(private = "file")
held_drop :: proc(d: ^Data, job: ^Job) {
	l := &d.login
	#partial switch p in job.payload {
	case Login_Start_Job:
		if asked, ok := l.code.(Code_Asked); ok && asked.attempt == p.attempt {
			l.code = nil
		}
	case Login_Wait_Job:
		if poll, ok := &l.code.(Code_Polling); ok {
			poll.out = false
		}
	case Playlists_Job:
		d.sidebar.loading = false
	case Liked_Ids_Job:
		d.liked.loading = false
		clear(&d.liked.edits)
		clear(&d.followed.edits)
	case Add_Track_Job:
		if p.source == .Liked {
			liked_answer(d, p.track, false)
		}
	case Follow_Job:
		follow_answer(d, p.artist, false)
	case Artist_Job:
		artist_job_dropped(d, p)
	}
	job_free(job)
}

// held_remove_if drops the held jobs pred picks, as jobs.remove_if does the
// queued ones, and returns how many went.
held_remove_if :: proc(d: ^Data, pred: proc(job: ^Job, data: rawptr) -> bool, data: rawptr) -> int {
	n := 0
	for &h in d.held[:d.held_count] {
		if pred(&h.job, data) {
			held_drop(d, &h.job)
		} else {
			d.held[n] = h
			n += 1
		}
	}
	removed := d.held_count - n
	d.held_count = n
	return removed
}

// page_of picks the pages of the list gen names, queued or held.
@(private = "file")
page_of :: proc(job: ^Job, gen: rawptr) -> bool {
	p, page := job.payload.(Tracks_Job)
	return page && p.view == (^u32)(gen)^
}

@(private = "file")
page_held :: proc(d: ^Data, gen: u32) -> bool {
	for h in d.held[:d.held_count] {
		if p, page := h.job.payload.(Tracks_Job); page && p.view == gen {
			return true
		}
	}
	return false
}

// job_free frees what a job owns, once it has run for good or won't run.
job_free :: proc(job: ^Job) {
	#partial switch &p in job.payload {
	case Disk_Job:
		delete(p.blob, runtime.heap_allocator())
		p.blob = nil
	}
}

@(private = "file")
drop_account_job :: proc(job: ^Job, _: rawptr) -> bool {
	if _, cover := job.payload.(Cover_Job); cover {
		return false
	}
	job_free(job)
	return true
}

// sign_out ends a login TIDAL no longer accepts. Results of jobs queued
// before it are dropped when they arrive, so however many requests fail,
// the login ends once and one new login starts. Queued jobs for the old
// login go, the ones in flight are cancelled (session_clear_auth), and the
// Keychain item is deleted. Playback stops and its queue goes.
sign_out :: proc(s: ^State, why: string) {
	d := &s.data
	account_end(s)
	{
		sync.guard(&d.keychain_mutex)
		keychain_delete(&d.keychain)
	}
	lists_forget(d)
	d.login = {
		note = small(why),
	}
	login_next_attempt(d)
	pkce_prepare(d)
}

// account_end drops the signed-in account but not its Keychain item:
// queued jobs for it go, the ones in flight are cancelled, and so are
// their results. Playback stops and its queue goes, and so do the search
// and the places Back goes to.
account_end :: proc(s: ^State) {
	d := &s.data
	sync.atomic_add(&d.auth_gen, 1) // the disk thread reads it
	for &h in d.held[:d.held_count] {
		held_drop(d, &h.job)
	}
	d.held_count = 0
	jobs.remove_if(&d.queue, drop_account_job, nil)
	tidal.session_clear_auth(d.session)
	d.account = .Signed_Out
	d.device_login = false
	d.relogin = false
	sidebar_free(d)
	liked_clear(d)
	followed_clear(d)
	artist_clear(d)
	view_close(d)
	queued_drop(d)
	lists_clear(d)
	playback_stop(s)
	search_forget(s)
	s.history = {}
	s.library.playlist = 0
}

// code_login_next asks for what the device login waits on, unless its job
// is out: the poll for the code on screen, or a new code. If an approved
// login still has its tokens, as after a failure loading the session, it
// loads the session with them instead: the code is spent, and the user
// approved.
code_login_next :: proc(d: ^Data) {
	l := &d.login
	#partial switch c in l.code {
	case Code_Asked:
		return
	case Code_Polling:
		if c.out {
			return
		}
		if c.link.device_code.len > 0 {
			request_login_poll(d)
			return
		}
	}
	if login_has_tokens(d) {
		if _, polling := l.code.(Code_Polling); !polling {
			l.code = Code_Polling{}
		}
		l.note = small("Loading your account…")
		request_login_poll(d)
		return
	}
	push_job(d, {payload = Login_Start_Job{attempt = d.login_attempt}})
	l.code = Code_Asked{d.login_attempt}
}

// login_has_tokens says whether the device login got its tokens but hasn't
// loaded the session yet. The code is spent then, and its expiry no longer
// matters: Login_Wait finishes with the tokens.
login_has_tokens :: proc(d: ^Data) -> bool {
	a := tidal.session_auth(d.session, context.temp_allocator)
	return a.access_token != "" && a.user_id == 0
}

// request_login_poll queues the poll for the code on screen, or with no
// code, the one that loads the session with the login's tokens.
request_login_poll :: proc(d: ^Data) {
	p := &d.login.code.(Code_Polling)
	if p.out {
		return
	}
	p.out = true
	push_job(d, {payload = Login_Wait_Job{attempt = d.login_attempt, device_code = p.link.device_code, interval = p.link.interval, deadline = p.deadline, not_before = p.poll_at, once = p.once}})
}

// login_next_attempt starts a new login attempt. Tokens that arrive for an
// older one are dropped before they reach the session, and its results
// are ignored.
login_next_attempt :: proc(d: ^Data) {
	d.login_attempt += 1
	tidal.session_set_login_attempt(d.session, u64(d.login_attempt))
}

request_playlists :: proc(d: ^Data) {
	if d.sidebar.loading {
		return
	}
	d.sidebar.loading = true
	push_job(d, {payload = Playlists_Job{}})
}

// data_retry pushes again the jobs the queue refused, if they're still
// wanted. A list's later pages wait behind its held one, so they're asked
// for once it's out.
data_retry :: proc(d: ^Data) {
	n := d.held_count
	if n == 0 {
		return
	}
	held := d.held
	d.held_count = 0
	pages := false
	for &h in held[:n] {
		_, page := h.job.payload.(Tracks_Job)
		pages ||= page
		if held_wanted(d, h.job) {
			push_job(d, h.job, h.priority)
		} else {
			held_drop(d, &h.job)
		}
	}
	if pages {
		view_request_pages(d)
	}
}

// held_wanted says whether a held job is still wanted: its login hasn't
// ended and what it's for still waits for it. Kinds whose answer is checked
// when it comes, as Stream's track serial is, always are, and so is Search:
// search_stop drops the held one with the queued one.
@(private = "file")
held_wanted :: proc(d: ^Data, job: Job) -> bool {
	l := &d.login
	if job.auth != d.auth_gen {
		return false
	}
	_, code_shown := l.card.(Login_Code)
	#partial switch p in job.payload {
	case Restore_Job:
		return d.account == .Restoring
	case Login_Start_Job:
		asked, ok := l.code.(Code_Asked)
		return code_shown && ok && asked.attempt == p.attempt
	case Login_Wait_Job:
		_, polling := l.code.(Code_Polling)
		return code_shown && polling
	case Login_Pkce_Job:
		_, exchanging := l.card.(Login_Exchanging)
		return exchanging
	case Playlists_Job:
		return d.account == .Signed_In
	case Tracks_Job:
		return track_view(d, p.view) != nil
	case Artist_Job:
		return artist_waiting(d, p) != nil
	}
	return true
}

// track_view is the list, open, fetched again or followed by the play
// queue, that gen names, or nil.
track_view :: proc(d: ^Data, gen: u32) -> ^Track_View {
	for v in ([]^Track_View{&d.refresh, &d.queued, &d.view}) {
		if v.gen == gen && v.source != .None {
			return v
		}
	}
	return nil
}

sidebar_free :: proc(d: ^Data) {
	arena_release(d.sidebar.arena)
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
	_, is_cover := res.job.payload.(Cover_Job)
	// From a login sign_out has ended. Covers don't depend on the login.
	if !is_cover && res.job.auth != d.auth_gen {
		return
	}
	err, failed := res.err.?
	// Only jobs that sent the login's tokens can end it. A cover carries no
	// token, and a login job's .Authentication means the user denied it.
	if failed && err == .Authentication {
		#partial switch _ in res.job.payload {
		case Cover_Job, Login_Start_Job, Login_Wait_Job, Login_Pkce_Job:
		case:
			sign_out(s, "Your TIDAL session ended. Log in again.")
			return
		}
	}
	switch p in res.job.payload {
	case Restore_Job:
		if res.message.len > 0 {
			d.message = res.message
		}
		if restored, _ := res.payload.(Restore_Result); restored.signed_in {
			signed_in(d)
		} else {
			d.account = .Signed_Out
			pkce_prepare(d)
			if redirect := pkce_redirect_env(); redirect != "" {
				pkce_submit(s, redirect)
			}
		}
	case Login_Start_Job:
		l := &d.login
		if p.attempt != d.login_attempt {
			// The user went on to another login. If that's the device login
			// again, it waited for this answer to ask for a code of its own.
			// A Login_Start from before the login started over is no one's.
			if asked, ok := l.code.(Code_Asked); ok && asked.attempt == p.attempt {
				l.code = nil
				if _, shown := l.card.(Login_Code); shown {
					code_login_next(d)
				}
			}
			return
		}
		if failed {
			l^ = {
				card = Login_Code{},
				code = Code_Failed{login_error(err, res.message)},
			}
			return
		}
		link, _ := res.payload.(Login_Link)
		l^ = {
			card = Login_Code{},
			code = Code_Polling{link = link, deadline = time.tick_add(time.tick_now(), time.Duration(f64(link.expires) * f64(time.Second)))},
			note = l.note,
		}
		request_login_poll(d)
	case Login_Wait_Job:
		if p.attempt != d.login_attempt {
			// The user went on to another login. If that's the device login
			// again, its poll waited for this one to end.
			l := &d.login
			if poll, ok := &l.code.(Code_Polling); ok {
				poll.out = false
				if _, shown := l.card.(Login_Code); shown {
					code_login_next(d)
				}
			}
			return
		}
		login_wait_done(d, res, p, err, failed)
	case Login_Pkce_Job:
		if p.attempt != d.login_attempt {
			return
		}
		pkce_done(d, res, failed)
	case Save_Settings_Job:
		if failed {
			d.message = res.message
		}
	case Launch_Log_Job:
	case Playlists_Job:
		d.sidebar.loading = false
		if failed {
			d.message = res.message
			return
		}
		sidebar, _ := res.payload.(Sidebar_Result)
		sidebar_adopt(s, res, sidebar, false)
		sidebar_save(d)
	case Disk_Job:
		disk_result(s, res, p)
	case Add_Track_Job:
		add_result(s, res, p)
	case Liked_Ids_Job:
		liked_ids_result(d, res, failed)
		followed_ids_result(d, res, failed)
	case Follow_Job:
		follow_result(d, res, p, failed)
	case Artist_Job:
		artist_result(d, res, p)
	case Tracks_Job:
		r := &d.refresh
		v := track_view(d, p.view)
		if v == nil {
			return
		}
		v.in_flight -= 1
		if failed {
			if v == r {
				refresh_drop(d) // the rows on screen stay
				return
			}
			v.error = res.message
			v.done = true
			v.in_flight -= held_remove_if(d, page_of, &v.gen)
			return
		}
		page, _ := res.payload.(Tracks_Result)
		view_add_rows(v, int(p.offset), int(p.limit), page.rows, page.total)
		if v.done {
			v.in_flight -= held_remove_if(d, page_of, &v.gen)
		}
		view_pages(d, v)
		if v != r {
			list_loaded(d, v)
		} else if view_complete(r) {
			refresh_land(s)
		}
	case Stream_Job:
		stream_result(s, res, p)
	case Artwork_Job:
		artwork_result(s, res, p)
	case Search_Job:
		search_result(s, res, p)
	case Cover_Job:
		key := p.key
		img, _ := res.payload.(Image_Result)
		if failed || img.pixels == nil {
			cover.set_failed(&d.covers, key, now)
			return
		}
		// The worker scaled it to the entry's size. Nil from place: the
		// entry is gone or every page is in use; failed covers are retried.
		e := cover.lookup(&d.covers, key)
		page: ^cover.Page
		if e != nil && img.w == int(e.px) && img.h == int(e.px) {
			e, page = cover.place(&d.covers, key, s.frame_count, now)
		}
		if page == nil {
			cover.set_failed(&d.covers, key, now)
			return
		}
		r := &s.renderer
		if page.texture == 0 {
			_, side := cover.page_layout(int(page.px))
			page.texture = render.texture_create(r, side, side, .RGBA8)
		}
		src := cover.src(&d.covers, e)
		render.texture_update(r, page.texture, img.pixels, int(src.x), int(src.y), img.w, img.h, converted = true)
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
login_wait_done :: proc(d: ^Data, res: ^Result, job: Login_Wait_Job, err: tidal.Error_Kind, failed: bool) {
	l := &d.login
	poll, polling := &l.code.(Code_Polling)
	if !polling {
		return // the login started over
	}
	poll.out = false
	if wait, _ := res.payload.(Login_Wait_Result); wait.interval > 0 {
		poll.link.interval = wait.interval
	}
	if !failed {
		signed_in(d)
		return
	}
	expired := time.tick_diff(time.tick_now(), poll.deadline) <= 0 && !login_has_tokens(d)
	#partial switch err {
	case .Timeout:
		if job.once && !expired {
			// TIDAL answered the check, which counts as a poll.
			l.note = {}
			poll.retries = 0
			poll.poll_at = time.tick_add(time.tick_now(), time.Duration(f64(poll.link.interval) * f64(time.Second)))
			poll.once = false
			request_login_poll(d)
			return
		}
		d.login = {
			card = Login_Code{},
			note = small("The code expired. Here's a new one."),
		}
		code_login_next(d)
	case .Network:
		if expired {
			d.login = {
				card = Login_Code{},
				note = small("The code expired. Here's a new one."),
			}
			code_login_next(d)
			return
		}
		poll.retries += 1
		// The poll may have reached TIDAL, so the next one waits at least
		// the interval.
		wait := max(min(1 << uint(min(poll.retries, 5)), LOGIN_RETRY_MAX), int(math.ceil(poll.link.interval)))
		poll.poll_at = time.tick_add(time.tick_now(), time.Duration(wait) * time.Second)
		poll.once = true
		l.note = small(fmt.tprintf("Can't reach TIDAL. Trying again in %d s.", wait))
		request_login_poll(d)
	case:
		if err == .Authentication && login_has_tokens(d) {
			// TIDAL refused the tokens, so "Try again" needs a new code.
			tidal.session_clear_auth(d.session)
		}
		d.login = {
			card = Login_Code{},
			code = Code_Failed{login_error(err, res.message)},
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
// playlists. One that's gone opens Liked Songs.
select_playlist :: proc(s: ^State, i: int) {
	lib := &s.library
	d := &s.data
	i := i
	if !d.fake && (i < 0 || i > len(d.sidebar.items)) {
		i = 0
	}
	if search_leave(s) || lib.playlist != i {
		lib.selected = -1
		lib.playing = -1
		lib.status = .None
	}
	lib.playlist = i
	lib.list_gen += 1
	if d.fake {
		return
	}
	if i == 0 {
		list_open(d, .Liked, "", "Liked Songs", "", d.sidebar.liked_count)
	} else {
		pl := d.sidebar.items[i - 1]
		list_open(d, .Playlist, pl.id, pl.name, pl.image, pl.tracks)
	}
	sidebar_check(d)
}

// drop_track_jobs drops the pages asked for but the ones for keep.
@(private = "file")
drop_track_jobs :: proc(job: ^Job, keep: rawptr) -> bool {
	q := (^Track_View)(keep)
	p, tracks := job.payload.(Tracks_Job)
	return tracks && (q.source == .None || p.view != q.gen)
}

POISON :: 0xdb

view_gen :: proc(d: ^Data) -> u32 {
	d.next_gen += 1
	return d.next_gen
}

// view_close closes the open list. A list that loaded whole is kept in
// memory (list_keep). One the play queue follows that's still loading goes
// on loading in d.queued, so the queue gets the rest of it. The rest is
// freed. A refresh of it stops.
view_close :: proc(d: ^Data) {
	v := &d.view
	if v.has_arena && v.gen == d.queue_view && !view_complete(v) && v.error.len == 0 && !v.reading {
		queued_drop(d)
		d.queued = v^
		v.has_arena = false
	}
	jobs.remove_if(&d.queue, drop_track_jobs, &d.queued)
	refresh_drop(d)
	if v.has_arena {
		if d.lists.memory && view_complete(v) && v.fetched != 0 {
			list_keep(d, v^)
		} else {
			view_free(d, v)
		}
	}
	v^ = {gen = view_gen(d)}
}

// queued_drop stops loading the list the play queue followed. One that
// loaded whole is kept like a closed list.
queued_drop :: proc(d: ^Data) {
	q := &d.queued
	if q.source == .None {
		return
	}
	jobs.remove_if(&d.queue, page_of, &q.gen)
	if q.has_arena {
		if d.lists.memory && view_complete(q) && q.fetched != 0 {
			list_keep(d, q^)
		} else {
			view_free(d, q)
		}
	}
	q^ = {}
}

// queue_list is the list the play queue follows while it loads, open or
// in d.queued, or nil.
queue_list :: proc(d: ^Data) -> ^Track_View {
	if d.view.source != .None && d.view.gen == d.queue_view {
		return &d.view
	}
	if d.queued.source != .None && d.queued.gen == d.queue_view {
		return &d.queued
	}
	return nil
}

// view_open opens a list from TIDAL, whatever is kept of it. list_open
// looks in the cache first.
view_open :: proc(d: ^Data, source: Source, id, name, image: string, hint: int) {
	view_close(d)
	view_fetch(d, source, id, name, image, hint)
}

// view_fetch has TIDAL fill the open list, just closed or read from a file
// that wasn't there.
view_fetch :: proc(d: ^Data, source: Source, id, name, image: string, hint: int) {
	v := &d.view
	sid, sname, simage := small(id), small(name), small(image)
	v^ = {gen = v.gen}
	v.source = source
	v.id, v.name, v.image = sid, sname, simage
	v.hint = hint
	v.count = hint
	v.version = list_version_now(d, source, id).? or_else {}
	view_init(v)
	view_reserve(v, max(hint, PAGE_FIRST))
	view_request_pages(d)
}

// A list's rows, their loaded flags and its gaps each have a range of one
// reservation, committed as the list grows. So rows never move, a longer
// list leaves no old copy behind, and a view can be moved by value. Pages
// the list hasn't reached cost nothing.
ROWS_MAX :: 1 << 18
GAPS_MAX :: ROWS_MAX / PAGE_FIRST + 1 // a gap is a short page

@(private = "file")
SPACE_PAGE :: 1 << 16
@(private = "file")
LOADED_AT :: (ROWS_MAX * size_of(Row) + SPACE_PAGE - 1) / SPACE_PAGE * SPACE_PAGE
@(private = "file")
GAPS_AT :: LOADED_AT + (ROWS_MAX + SPACE_PAGE - 1) / SPACE_PAGE * SPACE_PAGE
@(private = "file")
SPACE_SIZE :: GAPS_AT + GAPS_MAX * size_of(Gap)

// space_reserve reserves a list's space, with no rows yet.
space_reserve :: proc() -> (space: []u8, ok: bool) {
	err: mem.Allocator_Error
	if space, err = vmem.reserve(SPACE_SIZE); err != nil {
		return nil, false
	}
	if vmem.commit(&space[GAPS_AT], GAPS_MAX * size_of(Gap)) != nil {
		space_release(space)
		return nil, false
	}
	return space, true
}

space_release :: proc(space: []u8) {
	if space != nil {
		vmem.release(raw_data(space), len(space))
	}
}

// space_rows commits room for n rows in space, up to ROWS_MAX, and returns
// them and their loaded flags.
space_rows :: proc(space: []u8, n: int) -> (rows: []Row, loaded: []bool, ok: bool) {
	count := min(n, ROWS_MAX)
	if count == 0 {
		return nil, nil, true
	}
	if vmem.commit(&space[0], uint(count * size_of(Row))) != nil || vmem.commit(&space[LOADED_AT], uint(count)) != nil {
		return nil, nil, false
	}
	return ([^]Row)(&space[0])[:count], ([^]bool)(&space[LOADED_AT])[:count], true
}

// view_init makes v's arena and space, with no rows yet. has_arena says
// whether both are there.
view_init :: proc(v: ^Track_View) {
	v.has_arena = false
	if vmem.arena_init_growing(&v.arena) != nil {
		return
	}
	space, ok := space_reserve()
	if !ok {
		vmem.arena_destroy(&v.arena)
		return
	}
	v.space = space
	v.rows, v.loaded, v.gaps = nil, nil, nil
	v.has_arena = true
}

// view_release frees v's arena and space.
view_release :: proc(v: ^Track_View) {
	if !v.has_arena {
		return
	}
	vmem.arena_destroy(&v.arena)
	space_release(v.space)
	v.has_arena = false
	v.space, v.rows, v.loaded, v.gaps = nil, nil, nil, nil
}

// view_free frees a list's memory. Debug builds and tests poison it and
// keep it until the next one goes, see Data.poison.
view_free :: proc(d: ^Data, v: ^Track_View) {
	if !d.poison {
		view_release(v)
		return
	}
	for b := v.arena.curr_block; b != nil; b = b.prev {
		mem.set(b.base, POISON, int(b.used))
	}
	mem.set(raw_data(v.rows), POISON, len(v.rows) * size_of(Row))
	mem.set(raw_data(v.loaded), POISON, len(v.loaded))
	mem.set(raw_data(v.gaps), POISON, len(v.gaps) * size_of(Gap))
	view_release(&d.retired)
	d.retired = v^
	v.has_arena = false
}

// view_bytes is about what a list holds in memory.
view_bytes :: proc(v: ^Track_View) -> int {
	if !v.has_arena {
		return 0
	}
	return arena_bytes(&v.arena) + int(mem.align_forward_uint(uint(len(v.rows) * size_of(Row) + len(v.loaded)), 16 << 10))
}

// view_reserve makes room for n rows, up to ROWS_MAX.
view_reserve :: proc(v: ^Track_View, n: int) {
	if n <= len(v.rows) || !v.has_arena || len(v.rows) == ROWS_MAX {
		return
	}
	size := max(n, 2 * len(v.rows))
	rows, loaded, ok := space_rows(v.space, size)
	if !ok {
		log.errorf("lists: no memory for %d rows", size)
		return
	}
	v.rows, v.loaded = rows, loaded
}

// view_add_rows copies the page asked for at offset with limit into the
// view. total is the list's length TIDAL gave with the page, or -1.
//
// With a total, the page that reaches it ends the list, and a short page
// before that is a gap (see Gap): the rows after it move up. Without one, a
// short page ends the list. Pages arrive out of order either way, so the
// earliest end found stands: an empty page asked for past the end mustn't
// bring back rows a short page before it cut. Rows past the end are
// dropped. Until the end is known, a full page past the count TIDAL gave
// grows the list.
view_add_rows :: proc(v: ^Track_View, offset, limit: int, rows: []Row, total := -1) {
	rows := rows
	last := len(rows) < limit
	if total >= 0 {
		last = offset + limit >= total || len(rows) == 0
		v.hint = total
	}
	start := view_row_at(v, offset)
	if !last && len(rows) < limit {
		view_close_gap(v, offset, start, limit, len(rows))
	}
	end := start + len(rows)
	if last && (!v.done || end < v.count) {
		v.done = true
		v.count = end
	}
	if v.done {
		rows = rows[:clamp(v.count - start, 0, len(rows))]
	} else {
		v.count = max(v.count, end)
	}
	view_reserve(v, start + len(rows))
	if !v.has_arena {
		return
	}
	rows = rows[:clamp(len(v.rows) - start, 0, len(rows))]
	a := vmem.arena_allocator(&v.arena)
	for r, i in rows {
		v.rows[start + i] = row_clone(r, a)
		v.loaded_rows += int(!v.loaded[start + i])
		v.loaded[start + i] = true
		v.longest = max(v.longest, r.seconds)
	}
}

// view_row_at is the row that TIDAL's offset lands on, past the gaps
// before it.
view_row_at :: proc(v: ^Track_View, offset: int) -> int {
	row := offset
	for g in v.gaps {
		if g.offset >= offset {
			break
		}
		row -= g.missing
	}
	return row
}

// view_close_gap records that the page at offset, whose rows start at row,
// came back with got of the limit rows asked for, and moves the rows of
// later pages up to close the gap. It's rare, so it counts the loaded rows
// again.
@(private = "file")
view_close_gap :: proc(v: ^Track_View, offset, row, limit, got: int) {
	missing := limit - got
	from := row + limit
	to := row + got
	used := min(v.count, len(v.rows))
	if from < used {
		copy(v.rows[to:], v.rows[from:used])
		copy(v.loaded[to:], v.loaded[from:used])
	}
	v.count = max(v.count - missing, to)
	for i in v.count ..< used {
		v.loaded[i] = false
	}
	v.loaded_rows = 0
	for l in v.loaded[:min(v.count, len(v.loaded))] {
		v.loaded_rows += int(l)
	}
	if !v.has_arena || len(v.gaps) == GAPS_MAX {
		return
	}
	i := 0
	for i < len(v.gaps) && v.gaps[i].offset < offset {
		i += 1
	}
	n := len(v.gaps)
	v.gaps = ([^]Gap)(&v.space[GAPS_AT])[:n + 1]
	copy(v.gaps[i + 1:], v.gaps[i:n])
	v.gaps[i] = {offset, missing}
}

// view_request_pages keeps PAGES_IN_FLIGHT pages loading, for the open list
// and its refresh, until a short page says the list has ended. The first
// page is small so it shows sooner.
view_request_pages :: proc(d: ^Data) {
	view_pages(d, &d.view)
	view_pages(d, &d.refresh)
	view_pages(d, &d.queued)
}

// view_pages asks for v's next pages. It stops at a held one, so no page
// goes out ahead of an earlier one, and a page that ends the list leaves
// only later ones held.
view_pages :: proc(d: ^Data, v: ^Track_View) {
	for v.source != .None && !v.done && !v.reading && v.in_flight < PAGES_IN_FLIGHT && (v.next_offset < v.hint || v.in_flight == 0) && !page_held(d, v.gen) {
		limit := PAGE_FIRST if v.next_offset == 0 else PAGE_SIZE
		push_job(d, {payload = Tracks_Job{view = v.gen, source = v.source, id = v.id, offset = i32(v.next_offset), limit = i32(limit)}})
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

view_subtitle :: proc(s: ^State) -> string {
	d := &s.data
	if _, subtitle, ok := browse_header(s); ok {
		return subtitle
	}
	if d.fake {
		lib := &s.library
		count := ROW_COUNT if lib.playlist == 0 else 20 + lib.playlist * 37 % 300
		return fmt.tprintf("Playlist · %d songs", count)
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
	return list_row(&s.data.view, i)
}

// list_row returns row i of v, or nil while it's loading.
list_row :: proc(v: ^Track_View, i: int) -> ^Row {
	if i < 0 || i >= len(v.loaded) || !v.loaded[i] {
		return nil
	}
	return &v.rows[i]
}

// show_login says whether the library screen should be the login screen.
show_login :: proc(s: ^State) -> bool {
	return s.data.account == .Signed_Out || (s.data.account == .Signed_In && s.data.relogin)
}

// signed_in starts loading a login's account. The login screen starts
// over, and a login from the device-code client gets the notice that it
// only streams AAC.
signed_in :: proc(d: ^Data) {
	d.account = .Signed_In
	d.login = {}
	d.device_login = !tidal.session_is_pkce(d.session)
	d.notice_hidden = false
	lists_signed_in(d, tidal.session_auth(d.session, context.temp_allocator).user_id)
	request_playlists(d)
}
