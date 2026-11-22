package app

// The library's data: the TIDAL session, the sidebar's playlists, the jobs
// held for room in the queue and the results coming back. Requests run on
// the workers in workers.odin; this file is the UI thread's side. The
// login is in login.odin and auth.odin, the track lists in track_view.odin.
//
// With TIDALFAST_FAKE=1 none of it runs and the library shows the fake
// data from titles.odin, for working on the UI without an account.

import "base:runtime"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import "../cover"
import "../jobs"
import "../os_services"
import "../platform"
import "../render"
import "../sys"
import "../tidal"
import "../ui"

COVER_BUDGET :: 8 << 20 // cover page bytes: a few screens of covers, see cover.place
UPLOAD_BUDGET :: 2 * time.Millisecond // cover uploads per frame

Account :: enum u8 {
	Fake,
	Restoring, // reading the Keychain
	Signed_Out,
	Signed_In,
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

Data :: struct {
	fake:           bool,
	mock:           bool, // api is set
	api:            Small, // TIDALFAST_API once checked, "" for TIDAL
	locale:         Small, // for the session, see session_locale; "" is en_US
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
	refresh_gate:   i64, // time.Tick until which jobs that talk to TIDAL wait after a failed refresh (atomic)
	keychain_mutex: sync.Mutex, // orders a sign-out's delete against the workers' saves
	keychain_saved: u64, // the auth epoch of the login last saved, under keychain_mutex
	session:        ^tidal.Session,
	wake:           proc "c" (), // the shell's request_redraw
	queue:          jobs.Queue(Job, JOB_QUEUE),
	results:        jobs.Queue(Result, RESULT_QUEUE),
	threads:        [WORKERS]sys.Thread,
	thread_count:   int, // of threads, those started
	worker_temps:   [WORKERS]Worker_Temp,
	worker_count:   int, // workers started, which picks each one's worker_temps (atomic)
	running:        bool,
	login:          Login,
	// The hi-res login's PKCE verifier and client key, kept until the login
	// finishes or fails, so every try of one login page uses the same ones.
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
	removing:       bool, // a Remove_Track job is out, see remove_from_list
	liked:          Liked_Set, // the liked track ids the hearts show, see liked.odin
	followed:       Followed_Set, // the followed artist ids the Follow buttons show, see followed.odin
	artists:        Artist_Cache, // artist pages, see artist_data.odin
	home:           Home, // the Home page's shelves, see home.odin
	profile:        Profile, // the signed-in user's name and picture, see user_menu.odin
	// The playlist being created, renamed or deleted on TIDAL, while its
	// job is out; one at a time, see playlist_edit.odin.
	playlist_out:   Maybe(Playlist_Job),
	fake_sidebar:   Fake_Sidebar, // the fake data's playlists, see fake_sidebar
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
	d.locale = small(session_locale(os.get_env("TIDALFAST_LOCALE", context.temp_allocator), d.mock, context.temp_allocator))
	log.infof("app: TIDAL locale %s", small_str(&d.locale))
	session_open(d)
	d.account = .Restoring
	push_job(d, {payload = Restore_Job{}})
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
	delete(d.settings_store.path, runtime.heap_allocator())
	d.settings_store.path = ""
	delete(d.launch_log_path, runtime.heap_allocator())
	d.launch_log_path = ""
	sidebar_free(d)
	lists_shutdown(d)
	liked_clear(d)
	followed_clear(d)
	artist_clear(d)
	home_clear(d)
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
// TIDALFAST_PKCE_REDIRECT. Only `./build.py measure` sets it, for
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

// session_locale is the locale the session asks TIDAL's text in:
// TIDALFAST_LOCALE if set, en_US against the mock, so runs there don't
// depend on the machine, and otherwise the system's.
session_locale :: proc(override: string, mock: bool, allocator := context.allocator) -> string {
	if override != "" {
		return sys.locale_normalize(override, allocator)
	}
	if mock {
		return strings.clone(sys.DEFAULT_LOCALE, allocator)
	}
	return sys.locale(allocator)
}

// session_open makes the session, pointed at d.api if set, in d.locale.
session_open :: proc(d: ^Data) {
	s := tidal.session_create(locale = small_str(&d.locale), allocator = runtime.heap_allocator())
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
	tidal.session_set_login_attempt(s, u64(d.login_attempt))
	s.on_auth_change = auth_changed
	s.on_auth_change_data = d
	d.session = s
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

// held_victim is the held job to drop for a new one: one no longer wanted,
// else the oldest that held_evictable lets go.
@(private = "file")
held_victim :: proc(d: ^Data) -> int {
	held := d.held[:d.held_count]
	for h, i in held {
		if !held_wanted(d, h.job) {
			return i
		}
	}
	for h, i in held {
		if held_evictable(h.job) {
			return i
		}
	}
	when ODIN_DEBUG || ODIN_TEST {
		panic("the hold list is full of jobs that wait behind a flag")
	}
	return 0
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

@(private = "file")
drop_account_job :: proc(job: ^Job, _: rawptr) -> bool {
	if !for_account(job^) {
		return false
	}
	job_free(job)
	return true
}

// sign_out ends a login TIDAL no longer accepts, or one the user logs out
// of. Results of jobs queued before it are dropped when they arrive, so
// however many requests fail, the login ends once and one new login starts. Queued jobs for the old
// login go, the ones in flight are cancelled (session_clear_auth), and the
// disk thread deletes the Keychain item (lists_forget). Playback stops and
// its queue goes.
sign_out :: proc(s: ^State, why: string) {
	d := &s.data
	account_end(s)
	lists_forget(d, tidal.session_epoch(d.session))
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
	refresh_gate_open(d)
	d.account = .Signed_Out
	d.device_login = false
	d.relogin = false
	sidebar_free(d)
	liked_clear(d)
	followed_clear(d)
	artist_clear(d)
	home_clear(d)
	d.profile = {}
	d.removing = false
	d.playlist_out = nil
	s.library.edit = {}
	view_close(d)
	queued_drop(d)
	lists_clear(d)
	playback_stop(s)
	search_forget(s)
	s.history = {}
	s.library.playlist = 0
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
	// From an account sign_out has ended.
	if for_account(res.job) && res.job.auth != d.auth_gen {
		return
	}
	err, failed := res.err.?
	if failed && err == .Authentication && ends_login(res.job) {
		sign_out(s, "Your TIDAL session ended. Log in again.")
		return
	}
	switch p in res.job.payload {
	case Restore_Job:
		restore_result(s, res)
	case Login_Start_Job:
		login_start_result(d, res, p)
	case Login_Wait_Job:
		login_wait_result(d, res, p)
	case Login_Pkce_Job:
		pkce_result(d, res, p)
	case Save_Settings_Job:
		save_settings_result(d, res)
	case Launch_Log_Job:
	case Playlists_Job:
		playlists_result(s, res)
	case Disk_Job:
		disk_result(s, res, p)
	case Add_Track_Job:
		add_result(s, res, p)
	case Remove_Track_Job:
		remove_result(s, res, p)
	case Liked_Ids_Job:
		liked_ids_result(d, res, failed)
		followed_ids_result(d, res, failed)
	case Follow_Job:
		follow_result(d, res, p, failed)
	case Artist_Job:
		artist_result(d, res, p)
	case Home_Job:
		home_result(d, res, failed)
	case Profile_Job:
		profile_result(d, res, failed)
	case Playlist_Job:
		playlist_result(s, res, p)
	case Tracks_Job:
		tracks_result(s, res, p)
	case Stream_Job:
		stream_result(s, res, p)
	case Artwork_Job:
		artwork_result(s, res, p)
	case Search_Job:
		search_result(s, res, p)
	case Cover_Job:
		cover_result(s, res, p, now)
	}
}

// playlists_result takes the sidebar from a Playlists job.
playlists_result :: proc(s: ^State, res: ^Result) {
	d := &s.data
	d.sidebar.loading = false
	if res.err != nil {
		d.message = res.message
		return
	}
	sidebar, _ := res.payload.(Sidebar_Result)
	sidebar_adopt(s, res, sidebar, false)
	sidebar_save(d)
}

// select_playlist opens sidebar entry i: Liked Songs first, then the
// playlists. One that's gone opens Liked Songs.
select_playlist :: proc(s: ^State, i: int) {
	lib := &s.library
	d := &s.data
	i := i
	if i < 0 || i >= (fake_sidebar(d).count if d.fake else 1 + len(d.sidebar.items)) {
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

Sidebar_Entry :: struct {
	name:     string,
	subtitle: string,
	image:    string, // playlist image id, "" for a placeholder
	seed:     u32, // the placeholder gradient's
}

sidebar_count :: proc(s: ^State) -> int {
	d := &s.data
	if d.fake {
		return fake_sidebar(d).count
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
		pl := &fake_sidebar(d).items[i]
		return {small_str(&pl.name), songs(fake_tracks(pl)), "", u32(pl.key) * 7919 + 13}
	}
	if i == 0 {
		return {"Liked Songs", songs(d.sidebar.liked_count) if d.sidebar.loaded else "", "", seed}
	}
	pl := d.sidebar.items[i - 1]
	return {pl.name, songs(pl.tracks), pl.image, seed}
}

// sidebar_image is sidebar_entry's image alone, for prefetching covers.
sidebar_image :: proc(s: ^State, i: int) -> string {
	if s.data.fake || i == 0 {
		return ""
	}
	return s.data.sidebar.items[i - 1].image
}

// songs is "1 song" or "n songs", in the frame's memory.
songs :: proc(n: int) -> string {
	return "1 song" if n == 1 else cat(num(n), " songs")
}

view_title :: proc(s: ^State) -> string {
	d := &s.data
	if title, _, ok := browse_header(s); ok {
		return title
	}
	if d.fake {
		return sidebar_entry(s, s.library.playlist).name
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
		return cat("Playlist · ", songs(fake_tracks(&fake_sidebar(d).items[s.library.playlist])))
	}
	v := &d.view
	if d.account == .Restoring {
		return "Reading your login from the Keychain. If macOS asks, allow TIDALfast to use it."
	}
	if v.source == .None {
		return ""
	}
	if view_loading(v) {
		return cat("Playlist · ", songs(v.count), " · loading, ", num(v.loaded_rows), " so far")
	}
	return cat("Playlist · ", songs(v.count))
}

// data_status is a line for the header: rate limiting, errors, or "".
data_status :: proc(s: ^State) -> string {
	if source, text := current_error(s); source != .None && source != .Add {
		return text
	}
	return search_status(s)
}

view_count :: proc(s: ^State) -> int {
	if s.data.fake {
		if n, listed := fake_count(s); listed {
			return n
		}
		// The fake playlists all list the fake rows, but one made here is
		// empty.
		return 0 if fake_made(&fake_sidebar(&s.data).items[s.library.playlist]) else ROW_COUNT
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
