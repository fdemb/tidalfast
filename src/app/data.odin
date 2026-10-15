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
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
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
KEYCHAIN_MOCK_SERVICE :: "tidalfast-mock" // when TIDALFAST_API points somewhere else
KEYCHAIN_ACCOUNT :: "auth"
COVER_BUDGET :: 48 << 20 // texture bytes
UPLOAD_BUDGET :: 2 * time.Millisecond // cover uploads per frame
PAGES_IN_FLIGHT :: 2

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
	error:     Small,
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
	fake:       bool,
	mock:       bool, // TIDALFAST_API is set
	account:    Account,
	session:    ^tidal.Session, // made by this dylib, so closed on unload
	wake:       proc "c" (), // the shell's request_redraw
	queue:      jobs.Queue(Job, JOB_QUEUE),
	results:    jobs.Queue(Result, RESULT_QUEUE),
	threads:    [WORKERS]posix.pthread_t,
	running:    bool,
	saved_auth: []u8, // heap; the login state from unload to reload
	login:      Login,
	sidebar:    Sidebar,
	view:       Track_View,
	covers:     cover.Cache,
	message:    Small, // the last error worth showing
	evicted:    [64]render.Texture,
	bench:      Cover_Bench,
}

data_start :: proc(s: ^State, shell: ^platform.Shell) {
	d := &s.data
	d.wake = shell.request_redraw
	cover.init(&d.covers, COVER_BUDGET)
	bench := os.get_env("TIDALFAST_BENCH", context.temp_allocator)
	d.fake = os.get_env("TIDALFAST_FAKE", context.temp_allocator) != "" || (bench != "" && bench != "covers")
	if d.fake {
		d.account = .Fake
		return
	}
	d.bench.running = bench == "covers"
	session_open(d)
	d.account = .Restoring
	push_job(d, {kind = .Restore})
	workers_start(d)
}

data_unload :: proc(s: ^State) {
	d := &s.data
	workers_stop(d)
	if d.session != nil {
		d.saved_auth = auth_marshal(d.session, runtime.heap_allocator())
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
		auth_restore(d.session, d.saved_auth)
		delete(d.saved_auth, runtime.heap_allocator())
		d.saved_auth = nil
	}
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

// session_open makes the session for this dylib. TIDALFAST_API=url sends
// every request, login and cover to url instead of TIDAL, for running
// against tests/mock_tidal.
@(private = "file")
session_open :: proc(d: ^Data) {
	s := tidal.session_create(allocator = runtime.heap_allocator())
	if api := os.get_env("TIDALFAST_API", context.temp_allocator); api != "" {
		a := vmem.arena_allocator(&s.arena)
		base := strings.concatenate({strings.trim_right(api, "/"), "/"}, a)
		s.config.api_v1_location = base
		s.config.api_v2_location = strings.concatenate({base, "v2/"}, a)
		s.config.api_oauth2_token = strings.concatenate({base, "oauth2/token"}, a)
		s.config.api_device_auth = strings.concatenate({base, "oauth2/device_authorization"}, a)
		s.config.image_url = strings.concatenate({base, "images/%s/%dx%d.jpg"}, a)
		d.mock = true
	}
	s.on_auth_change = auth_changed
	s.on_auth_change_data = d
	d.session = s
}

// keychain_service is where the login goes. Against a mock server,
// TIDALFAST_KEYCHAIN can name another item, so test runs of differently
// signed builds don't share one and the Keychain doesn't ask for access.
keychain_service :: proc(d: ^Data) -> string {
	if !d.mock {
		return KEYCHAIN_SERVICE
	}
	if name := os.get_env("TIDALFAST_KEYCHAIN", context.temp_allocator); name != "" && name != KEYCHAIN_SERVICE {
		return name
	}
	return KEYCHAIN_MOCK_SERVICE
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

auth_marshal :: proc(s: ^tidal.Session, allocator: runtime.Allocator) -> []u8 {
	a := tidal.session_auth(s, context.temp_allocator)
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
// no usable login.
auth_restore :: proc(s: ^tidal.Session, data: []u8) -> bool {
	st: Stored_Auth
	if json.unmarshal(data, &st, allocator = context.temp_allocator) != nil {
		return false
	}
	if st.user_id == 0 || (st.access_token == "" && st.refresh_token == "") {
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
// working, so this happens every time.
auth_changed :: proc(s: ^tidal.Session, data: rawptr) {
	d := (^Data)(data)
	bytes := auth_marshal(s, context.temp_allocator)
	if status := mac.keychain_set(keychain_service(d), KEYCHAIN_ACCOUNT, bytes); status != mac.ERR_SEC_SUCCESS {
		fmt.eprintfln("app: couldn't save the login to the Keychain (error %d)", status)
	}
}

push_job :: proc(d: ^Data, job: Job, priority: u8 = PRIORITY_DATA) -> bool {
	if !jobs.push(&d.queue, job, priority) {
		fmt.eprintfln("app: job queue full, dropped a %v job", job.kind)
		return false
	}
	return true
}

sign_out :: proc(s: ^State, why: string) {
	d := &s.data
	d.account = .Signed_Out
	d.login = {}
	d.login.error = small(why)
	mac.keychain_delete(keychain_service(d), KEYCHAIN_ACCOUNT)
	sidebar_free(d)
	view_close(d)
	s.library.playlist = 0
	request_login_code(d)
}

request_login_code :: proc(d: ^Data) {
	if d.login.requested || d.login.waiting {
		return
	}
	d.login.requested = push_job(d, {kind = .Login_Start})
}

request_playlists :: proc(d: ^Data) {
	if d.sidebar.loading {
		return
	}
	d.sidebar.loading = push_job(d, {kind = .Playlists})
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
	d.bench.upload_ms = f32(time.duration_milliseconds(time.tick_since(begin)))
}

@(private = "file")
handle_result :: proc(s: ^State, res: ^Result, now: f64) {
	d := &s.data
	err, failed := res.err.?
	if failed && err == .Authentication && res.job.kind != .Login_Wait && res.job.kind != .Login_Start {
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
		d.login.requested = false
		if failed {
			d.login.error = res.message
			return
		}
		d.login.link = res.link
		d.login.error = {}
		link := res.link
		d.login.waiting = push_job(d, {kind = .Login_Wait, id = link.device_code, interval = link.interval, expires = link.expires})
	case .Login_Wait:
		d.login.waiting = false
		if failed {
			if err == .Timeout {
				d.login = {error = small("The code expired. Here's a new one.")}
				request_login_code(d)
			} else {
				d.login.error = res.message
			}
			return
		}
		d.login = {}
		d.account = .Signed_In
		request_playlists(d)
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

// select_playlist opens sidebar entry i: Liked Songs first, then the
// playlists.
select_playlist :: proc(s: ^State, i: int) {
	lib := &s.library
	if lib.playlist != i {
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

// view_add_rows copies a page into the view. A short page is the last one.
@(private = "file")
view_add_rows :: proc(v: ^Track_View, offset: int, rows: []Row, last: bool) {
	end := offset + len(rows)
	view_reserve(v, end)
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
			track    = r.track,
		}
		v.loaded_rows += int(!v.loaded[offset + i])
		v.loaded[offset + i] = true
	}
	if last {
		v.done = true
		v.count = end
	} else {
		v.count = max(v.count, end)
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
			return
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
	return small_str(&d.message)
}

view_count :: proc(s: ^State) -> int {
	if s.data.fake {
		return ROW_COUNT
	}
	return s.data.view.count
}

// view_row returns row i of the open list, or nil while it's loading.
view_row :: proc(s: ^State, i: int) -> ^Row {
	if s.data.fake {
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
