package app

// Worker threads for everything that blocks: TIDAL requests, cover
// downloads and JPEG decoding. The UI thread pushes Jobs into data.queue; a
// worker runs one, pushes a Result into data.results and wakes the UI
// thread with the shell's request_redraw. Jobs and results are plain data
// with fixed-size text, so they reference nothing a view switch could
// free.
//
// Memory: each job that returns data gets its own virtual-memory arena,
// which travels in the Result. The UI thread copies what it keeps into the
// view's arena, or adopts the whole arena, and frees the rest. Scratch
// memory is the worker's thread-local temp allocator, reset after each job.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

import "../cover"
import "../jobs"
import "../sys"
import "../tidal"

WORKERS :: 4
JOB_QUEUE :: 256
RESULT_QUEUE :: 256
PAGE_FIRST :: 50 // the first page of a track list, small so it shows fast
PAGE_SIZE :: 100
PLAYLIST_PAGE :: 50 // TIDAL's cap for playlistsAndFavoritePlaylists
PLAYLIST_PAGES_MAX :: 100 // the sidebar asks for no more, in case TIDAL ignores the offset

// Small is text with a fixed buffer, for jobs and results.
Small :: struct {
	len: u8,
	buf: [119]u8,
}

small :: proc(s: string) -> (out: Small) {
	n := min(len(s), len(out.buf))
	for n > 0 && n < len(s) && !utf8.rune_start(s[n]) {
		n -= 1
	}
	copy(out.buf[:], s[:n])
	out.len = u8(n)
	return
}

small_str :: proc(s: ^Small) -> string {
	return string(s.buf[:s.len])
}

Source :: enum u8 {
	None,
	Liked,
	Playlist,
	Search,
	Album,
	Artist,
}

// Job is work for a worker, or for the disk thread. Its payload says what
// to do and holds only what that kind needs.
Job :: struct {
	auth:    u32, // the auth generation it was queued in, see sign_out
	payload: Job_Payload,
}

Job_Payload :: union {
	Restore_Job,
	Login_Start_Job,
	Login_Wait_Job,
	Login_Pkce_Job,
	Playlists_Job,
	Tracks_Job,
	Cover_Job,
	Stream_Job,
	Artwork_Job,
	Search_Job,
	Save_Settings_Job,
	Disk_Job,
	Add_Track_Job,
	Remove_Track_Job,
	Liked_Ids_Job,
	Follow_Job,
	Launch_Log_Job,
	Artist_Job,
	Home_Job,
	Profile_Job,
}

// Profile_Job is the signed-in user's name and picture, for the sidebar's
// user menu.
Profile_Job :: struct {}

// Restore_Job reads the tokens from the Keychain into the session.
Restore_Job :: struct {}

// Login_Start_Job asks TIDAL for a device code.
Login_Start_Job :: struct {
	attempt: u32, // the login attempt, see Data.login_attempt
}

// Login_Wait_Job polls until the user approves the device code.
Login_Wait_Job :: struct {
	attempt:     u32,
	device_code: Small,
	interval:    f32, // seconds between polls
	deadline:    time.Tick, // when the code expires
	not_before:  time.Tick, // when to poll first, {} for now
	once:        bool, // poll once, to see if TIDAL answers again
}

// Login_Pkce_Job finishes a PKCE login with the pasted address, see
// login.odin.
Login_Pkce_Job :: struct {
	attempt: u32,
}

// Playlists_Job is the sidebar: the liked songs count and the playlists
// made or followed.
Playlists_Job :: struct {}

// Tracks_Job is one page of a track list.
Tracks_Job :: struct {
	view:   u32, // the Track_View.gen it's for
	source: Source,
	id:     Small, // the playlist, album or artist id, or the query
	offset: i32,
	limit:  i32,
}

// Image_Job is an image to read from disk or download, and decode.
Image_Job :: struct {
	id:     Small, // TIDAL's image id
	size:   u16, // pixels across to decode to
	fetch:  u16, // the size to download, 0 for size
	remote: bool, // not on disk, so it waits out a backoff
}

Cover_Job :: struct {
	key:   u64, // the cover cache's
	image: Image_Job,
}

// Artwork_Job is a cover for Now Playing, kept as pixels.
Artwork_Job :: struct {
	serial: u64, // the track's, see player.odin
	image:  Image_Job,
}

// Stream_Job resolves a track's stream URL, see player.odin.
Stream_Job :: struct {
	track:  i64,
	serial: u64,
}

// Search_Job asks for songs, albums, artists and playlists, see search.odin.
Search_Job :: struct {
	gen:   u32, // the query's, see Search.gen
	query: Small,
}

// Save_Settings_Job writes the settings, see settings.odin.
Save_Settings_Job :: struct {}

// Disk_Job reads or writes a cache file, on the disk thread, see lists.odin.
Disk_Job :: struct {
	op:     Disk_Op,
	user:   i64, // whose folder
	source: Source, // .None for the sidebar
	id:     Small,
	view:   u32, // reading a list: the Track_View.gen it's for
	epoch:  u64, // .Forget: the session's auth epoch after the sign-out
	blob:   []u8, // writes: the file, heap, freed by the disk thread
}

// Add_Track_Job likes a track, unlikes one, or adds it to a playlist, see
// add_to_list.
Add_Track_Job :: struct {
	track:  i64,
	source: Source, // .Liked or .Playlist
	id:     Small, // the playlist's
	remove: bool, // .Liked only: unlike it
}

// Remove_Track_Job takes a track off one of the user's playlists, see
// remove_from_list. TIDAL removes by item index, so the job carries the
// indices the row can be at, lo to hi (see view_item_index), and the
// worker removes the first of them that holds the track. One is out at a
// time (Data.removing): each moves the indices after it.
Remove_Track_Job :: struct {
	track:  i64,
	id:     Small, // the playlist's
	row:    i32, // the row it was in when the job went out
	lo, hi: i32,
	serial: u32, // the status line's, see remove_result
}

// Liked_Ids_Job reads every liked track's id for the hearts, and every
// followed artist's for the Follow buttons, see liked.odin.
Liked_Ids_Job :: struct {
	version: List_Version, // the sidebar's Liked Songs version when it went out
}

// Launch_Log_Job appends this launch to the launch log, see launch_log.odin.
Launch_Log_Job :: struct {
	launch: Launch,
}

// Priorities: lower runs first.
PRIORITY_DATA :: 0
PRIORITY_COVER :: 1 // visible
PRIORITY_COVER_NEAR :: 2 // just outside the view

Sidebar_Item :: struct {
	id:      string,
	name:    string,
	image:   string, // square image id, "" for none
	tracks:  int,
	updated: i64, // lastUpdated, unix ms, 0 if TIDAL didn't say
	own:     bool, // the user made it, so it takes adds and removals
}

Login_Link :: struct {
	user_code:   Small,
	uri:         Small,
	uri_full:    Small, // with the code in it
	device_code: Small,
	interval:    f32,
	expires:     f32,
}

// Result is a job's answer. err and message say why it failed. arena, when
// the job made one, owns the strings and rows payload points to.
Result :: struct {
	job:     Job,
	err:     Maybe(tidal.Error_Kind),
	message: Small,
	arena:   ^vmem.Arena,
	payload: Result_Payload, // nil when the job's kind answers nothing more
}

// Result_Payload is what a job of one kind brings back, besides err.
Result_Payload :: union {
	Restore_Result,
	Login_Link, // Login_Start
	Login_Wait_Result,
	Sidebar_Result,
	Tracks_Result,
	Image_Result,
	Stream_Result,
	Search_Result,
	List_File_Result,
	Queue_File_Result,
	Add_Track_Result,
	Remove_Track_Result,
	Liked_Ids_Result,
	Artist_Result,
	Home_Result,
	Profile_Result,
}

Profile_Result :: struct {
	name:    Small,
	picture: Small, // TIDAL's image id, "" for none
}

Restore_Result :: struct {
	signed_in: bool, // the Keychain had tokens
}

Login_Wait_Result :: struct {
	interval: f32, // seconds between polls, as TIDAL last asked
}

// Sidebar_Result is the sidebar from a Playlists job, or from its file.
Sidebar_Result :: struct {
	playlists:    []Sidebar_Item, // in arena
	liked_count:  int,
	liked_newest: i64, // the newest liked track's id
}

Tracks_Result :: struct {
	rows:  []Row, // in arena
	total: int, // the list's length TIDAL gave with the page, -1 if it didn't
}

// Image_Result is a Cover's or an Artwork's pixels, from cover.decode.
Image_Result :: struct {
	pixels: []u8,
	w, h:   int,
}

Stream_Result :: struct {
	info:  tidal.Stream_Info, // strings in arena
	codec: Small, // the manifest's codec, when that's why it failed
}

Search_Result :: struct {
	rows:  []Row, // in arena
	found: Found_Lists, // in arena
}

// List_File_Result is a list read from its file, there and good. The rows
// are in space, their strings in arena.
List_File_Result :: struct {
	space:   []u8, // see space_reserve
	rows:    []Row,
	loaded:  []bool, // in space
	total:   int,
	version: List_Version, // what the list was fetched at
	fetched: i64, // when, unix seconds
}

// Queue_File_Result is the play queue read from its file, there and good.
Queue_File_Result :: struct {
	header: Queue_Header, // the queue's place
	rows:   []Row, // in arena
	after:  []i64, // in arena: the anchors of the extras, the last len(after) rows
}

// Add_Track_Result is what an add, like or unlike changed. version and row
// are what TIDAL lists after it, when the second ask got them.
Add_Track_Result :: struct {
	added:   bool, // TIDAL added it rather than finding it there
	version: List_Version,
	row:     Maybe(Row), // the track as the list now has it, in arena
}

// Remove_Track_Result is where a removal found the track, and with read
// the playlist's version after it. missing says, with an error, that none
// of the indices held the track: the list changed since it was fetched.
Remove_Track_Result :: struct {
	index:   int,
	version: List_Version,
	read:    bool, // the playlist was read again after the removal
	missing: bool,
}

Liked_Ids_Result :: struct {
	tracks:  []i64, // every liked track's id, sorted
	artists: []i64, // every followed artist's id, sorted
	version: List_Version, // the sidebar's when the job went out
}

Artist_Result :: struct {
	content: Artist_Content, // strings in arena
}

workers_start :: proc(d: ^Data) {
	if d.running || d.session == nil {
		return
	}
	jobs.start(&d.queue)
	jobs.start(&d.results)
	tidal.session_abort(d.session, false)
	d.thread_count = 0
	for _ in d.threads {
		if !sys.thread_start(&d.threads[d.thread_count], worker_main, d) {
			log.error("app: couldn't start a worker thread")
			continue
		}
		d.thread_count += 1
	}
	disk_start(d)
	d.running = true
}

// workers_stop aborts requests in flight and joins the workers. Jobs they
// were running go back in the queue; queued jobs and unread results stay.
workers_stop :: proc(d: ^Data) {
	if !d.running {
		return
	}
	tidal.session_abort(d.session, true)
	jobs.stop(&d.queue)
	jobs.stop(&d.results)
	for t in d.threads[:d.thread_count] {
		sys.thread_join(t)
	}
	d.thread_count = 0
	disk_stop(d)
	d.running = false
}

@(private = "file")
worker_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	context.logger = app_logger()
	d := (^Data)(arg)
	temp_given := false
	temp := &d.worker_temps[sync.atomic_add(&d.worker_count, 1) % WORKERS]
	for {
		job: Job
		ticket: jobs.Ticket
		// A 429 or an anti-abuse 403 holds back everything that would talk
		// to TIDAL, cover downloads included, until its Retry-After has
		// passed. A failed token refresh holds back the jobs that send the
		// tokens. Other jobs still run. A worker that may wait gives its
		// scratch pages back first.
		gate, can_run := gate_remaining(d)
		if queued, _ := jobs.pending(&d.queue); queued == 0 || gate > 0 {
			temp_give_back(&temp_given)
		}
		if gate > 0 {
			ok, stopped: bool
			job, ticket, ok, stopped = jobs.pop_wait_where(&d.queue, can_run, gate)
			if stopped {
				break
			}
			if !ok {
				d.wake()
				continue
			}
		} else {
			ok: bool
			job, ticket, ok = jobs.pop_wait(&d.queue)
			if !ok {
				break
			}
			if again, can := gate_remaining(d); again > 0 && !can(&job) {
				// The gate closed while this worker waited.
				jobs.requeue(&d.queue, job, ticket)
				continue
			}
		}
		temp_take_back(&temp_given)
		res := run_job(d, job)
		free_all(context.temp_allocator)
		temp_publish(temp)
		if retry_later(d, res) {
			again := requeued(job, res)
			result_free(&res)
			jobs.requeue(&d.queue, again, ticket)
			continue
		}
		if e, failed := res.err.?; failed && e == .Refresh_Failed {
			// The tokens are kept, so the job goes back and waits behind
			// the gate.
			result_free(&res)
			refresh_failed(d)
			jobs.requeue(&d.queue, job, ticket)
			continue
		}
		if !jobs.push_wait(&d.results, res) {
			again := requeued(job, res)
			result_free(&res)
			jobs.requeue(&d.queue, again, ticket)
			continue
		}
		job_free(&job)
		jobs.done(&d.queue)
		d.wake()
	}
	sync.atomic_store(&temp.base, 0)
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
}

// gate_remaining is how long until the gate opens, 0 if it's open, and
// which jobs can run until then. A backoff holds every job that talks to
// TIDAL; after a failed token refresh only those that send the tokens wait.
@(private = "file")
gate_remaining :: proc(d: ^Data) -> (wait: time.Duration, can_run: proc(job: ^Job) -> bool) {
	if backoff := tidal.backoff_remaining(d.session); backoff > 0 {
		return time.Duration(backoff * f64(time.Second)), is_local
	}
	refresh := time.tick_diff(time.tick_now(), time.Tick{sync.atomic_load(&d.refresh_gate)})
	return max(refresh, 0), sends_no_token
}

@(private = "file")
sends_no_token :: proc(job: ^Job) -> bool {
	return !ends_login(job^)
}

// refresh_gate_open opens the gate a failed refresh closed, after a refresh
// worked or the account ended, and wakes the workers waiting behind it.
refresh_gate_open :: proc(d: ^Data) {
	sync.atomic_store(&d.refresh_errors, 0)
	if sync.atomic_exchange(&d.refresh_gate, 0) != 0 {
		jobs.kick(&d.queue)
	}
}

// refresh_failed closes the gate for a wait that doubles with each failed
// refresh, until one works. Jobs that fail while it's closed, such as
// those that waited on the same refresh, don't count again.
@(private = "file")
refresh_failed :: proc(d: ^Data) {
	now := time.tick_now()
	gate := sync.atomic_load(&d.refresh_gate)
	if time.tick_diff(now, time.Tick{gate}) > 0 {
		return
	}
	n := sync.atomic_load(&d.refresh_errors) + 1
	wait := time.Duration(min(1 << uint(min(n, 5)), LOGIN_RETRY_MAX)) * time.Second
	if _, ok := sync.atomic_compare_exchange_strong(&d.refresh_gate, gate, time.tick_add(now, wait)._nsec); ok {
		sync.atomic_add(&d.refresh_errors, 1)
	}
}

// A worker's temp arena is one 4 MB block, and parsing a page of tracks
// dirties about 750 KB of it. Rolling the arena back keeps those pages, so
// with nothing left to do a worker gives back all but TEMP_KEEP of the block
// to the system, and takes it back before its next job.
@(private = "file")
TEMP_KEEP :: 64 << 10

// temp_tail is the whole pages, page bytes each, of a block at base,
// capacity bytes long, past its first keep bytes. Empty if there are none.
temp_tail :: proc(base: uintptr, capacity, keep, page: uint) -> (start: rawptr, size: uint) {
	from := mem.align_forward_uintptr(base + uintptr(keep), uintptr(page))
	to := (base + uintptr(capacity)) &~ (uintptr(page) - 1)
	if to <= from {
		return nil, 0
	}
	return rawptr(from), uint(to - from)
}

@(private = "file")
temp_range :: proc() -> (start: rawptr, size: uint) {
	b := runtime.global_default_temp_allocator_data.arena.curr_block
	if b == nil {
		return nil, 0
	}
	return temp_tail(uintptr(b.base), b.capacity, TEMP_KEEP, uint(sys.page_size()))
}

// Worker_Temp is where a worker's temp block is, for the memory breakdown
// to count its pages. base is 0 for none (atomic).
Worker_Temp :: struct {
	base: uintptr,
	size: uint,
}

@(private = "file")
temp_publish :: proc(t: ^Worker_Temp) {
	b := runtime.global_default_temp_allocator_data.arena.curr_block
	if b == nil {
		return
	}
	sync.atomic_store(&t.size, b.capacity)
	sync.atomic_store(&t.base, uintptr(b.base))
}

@(private = "file")
temp_give_back :: proc(given: ^bool) {
	if start, size := temp_range(); size > 0 && !given^ {
		given^ = pages_give_back(start, size)
	}
}

@(private = "file")
temp_take_back :: proc(given: ^bool) {
	if start, size := temp_range(); size > 0 && given^ {
		pages_take_back(start, size)
	}
	given^ = false
}

// retry_later says whether a job should go back in the queue instead of
// failing: it was cut short by workers_stop, held back by the backoff gate, or
// was the request that started a backoff. A job cancelled because its
// login was cleared isn't retried; sign_out drops its result.
@(private = "file")
retry_later :: proc(d: ^Data, res: Result) -> bool {
	e := res.err.? or_return
	#partial switch e {
	case .Backing_Off, .Too_Many_Requests, .Abuse_Detected:
		return true
	case .Cancelled:
		return sync.atomic_load(&d.session.abort)
	}
	return false
}

// arena_new makes a growing arena that lives in its own first block, so a
// result can hand it on by pointer without a header on the heap. Free it
// with arena_release: vmem.arena_destroy would write to it after unmapping
// it, and vmem.arena_free_all would zero it.
arena_new :: proc() -> ^vmem.Arena {
	a, _ := vmem.arena_growing_bootstrap_new_by_offset(vmem.Arena, 0)
	return a
}

arena_release :: proc(a: ^vmem.Arena) {
	if a != nil {
		home := a^
		vmem.arena_destroy(&home)
	}
}

// take moves what p holds to the caller and leaves p empty, so of the two
// only the caller's copy owns the memory it points to.
take :: proc(p: ^$T) -> T {
	v := p^
	p^ = {}
	return v
}

result_free :: proc(res: ^Result) {
	arena_release(res.arena)
	res.arena = nil
	#partial switch &p in res.payload {
	case List_File_Result:
		space_release(p.space)
	case Image_Result:
		cover.free_pixels(p.pixels)
	}
	res.payload = nil
}

// fail records err for a job that sent the login's tokens. An expired
// session that couldn't be refreshed comes back as a plain 401 from some
// endpoints, so that ends the login too.
fail :: proc(res: ^Result, err: tidal.Error) {
	e, _ := err.?
	res.err = .Authentication if e.kind == .Http && e.status == 401 else e.kind
	res.message = small(tidal.error_string(err, context.temp_allocator))
}

// stream_error_line is the log line for a stream that didn't resolve, or
// "" when there's nothing to log. It holds only fields that can't carry
// server text (see tidal.error_summary): what the server said may hold a
// signed URL.
stream_error_line :: proc(track_id: i64, what: string, err: tidal.Error, allocator := context.allocator) -> string {
	e, _ := err.?
	if e.kind == .Cancelled || e.kind == .Backing_Off {
		return "" // the job goes back in the queue
	}
	return fmt.aprintf("app: stream for track %d %s: %s", track_id, what, tidal.error_summary(err, context.temp_allocator), allocator = allocator)
}

@(private = "file")
log_stream_error :: proc(track_id: i64, what: string, err: tidal.Error) {
	if line := stream_error_line(track_id, what, err, context.temp_allocator); line != "" {
		log.error(line)
	}
}

run_job :: proc(d: ^Data, job: Job) -> (res: Result) {
	res.job = job
	s := d.session
	#partial switch p in job.payload {
	case Cover_Job:
		run_cover(d, p.image, &res)
		return
	case Artwork_Job:
		run_cover(d, p.image, &res)
		return
	}
	res.arena = arena_new()
	if res.arena == nil {
		res.err = .Io
		res.message = small("out of memory")
		return
	}
	alloc := vmem.arena_allocator(res.arena)
	switch p in job.payload {
	case Cover_Job, Artwork_Job, Disk_Job:
	case Launch_Log_Job:
		if !launch_log_append(d.launch_log_path, launch_log_line(p.launch, context.temp_allocator)) {
			res.err = .Io
		}
	case Save_Settings_Job:
		if !settings_flush(&d.settings_store) {
			res.err = .Io
			res.message = small("Couldn't save the settings")
		}
	case Login_Pkce_Job:
		run_login_pkce(d, p, &res)
	case Stream_Job:
		info, refused, err := tidal.resolve_stream_flac(s, p.track, alloc)
		if refused != nil {
			log_stream_error(p.track, "at HI_RES_LOSSLESS failed, asking for LOSSLESS", refused)
		}
		if err != nil {
			log_stream_error(p.track, "failed", err)
			fail(&res, err)
			if e, _ := err.?; e.kind == .Lossy_Stream {
				res.payload = Stream_Result{codec = small(tidal.error_detail(&e))}
			}
			return
		}
		res.payload = Stream_Result{info = info}
	case Restore_Job:
		res.payload = Restore_Result{auth_load(d, &res)}
	case Login_Start_Job:
		link, err := tidal.login_device_start(s, alloc)
		if err != nil {
			fail(&res, err)
			return
		}
		res.payload = Login_Link {
			user_code   = small(link.user_code),
			uri         = small(link.verification_uri),
			uri_full    = small(link.verification_uri_complete),
			device_code = small(link.device_code),
			interval    = f32(link.interval),
			expires     = f32(link.expires_in),
		}
	case Login_Wait_Job:
		run_login_wait(d, p, &res)
	case Playlists_Job:
		run_playlists(s, &res, alloc)
	case Tracks_Job:
		tracks: []tidal.Track
		err: tidal.Error
		total := -1
		id := p.id
		#partial switch p.source {
		case .Liked:
			tracks, total, err = tidal.favorites_tracks(s, int(p.limit), int(p.offset), .Date, .Descending, alloc)
		case .Playlist:
			tracks, total, err = tidal.playlist_tracks(s, small_str(&id), int(p.limit), int(p.offset), allocator = alloc)
		case:
			tracks, err = more_tracks(s, p, alloc)
		}
		if err != nil {
			fail(&res, err)
			return
		}
		res.payload = Tracks_Result{rows_from_tracks(tracks, alloc), total}
	case Add_Track_Job:
		run_add_track(s, p, &res, alloc)
	case Remove_Track_Job:
		run_remove_track(s, p, &res)
	case Liked_Ids_Job:
		run_liked_ids(s, p, &res, alloc)
	case Follow_Job:
		artist := fmt.tprint(p.artist)
		err: tidal.Error
		if p.on {
			err = tidal.favorites_add_artist(s, {artist})
		} else {
			err = tidal.favorites_remove_artist(s, artist)
		}
		if err != nil {
			fail(&res, err)
		}
	case Artist_Job:
		content, err := artist_part_spec(p.part).load(s, p.artist, {&d.artists, p.slot, p.gen}, alloc)
		if err != nil {
			fail(&res, err)
			return
		}
		res.payload = Artist_Result{content}
	case Home_Job:
		run_home(s, &res, alloc)
	case Profile_Job:
		run_profile(s, &res)
	case Search_Job:
		query := p.query
		found, err := tidal.search(s, small_str(&query), {.Track, .Album, .Artist, .Playlist}, SEARCH_PAGE, 0, alloc)
		if err != nil {
			fail(&res, err)
			return
		}
		res.payload = Search_Result{rows_from_tracks(found.tracks, alloc), found_lists(found, alloc)}
	}
	return
}

@(private = "file")
rows_from_tracks :: proc(tracks: []tidal.Track, alloc: mem.Allocator) -> []Row {
	rows := make([]Row, len(tracks), alloc)
	for t, i in tracks {
		rows[i] = row_from_track(t, alloc)
	}
	return rows
}

// run_login_pkce trades the pasted address's code for tokens. If an
// earlier try already did, and then loading the account failed, the code
// is spent: it finishes with those tokens instead.
@(private = "file")
run_login_pkce :: proc(d: ^Data, job: Login_Pkce_Job, res: ^Result) {
	s := d.session
	attempt := u64(job.attempt)
	if attempt != tidal.session_login_attempt(s) {
		res.err = .Cancelled
		return
	}
	a := tidal.session_auth(s, context.temp_allocator)
	if a.access_token != "" && a.user_id == 0 && a.is_pkce {
		if err := tidal.load_oauth_session(s, a.token_type, a.access_token, a.refresh_token, a.expiry_time, true); err != nil {
			fail_login(res, err)
			return
		}
		auth_changed(s, d)
		return
	}
	sync.lock(&d.pkce_mutex)
	redirect := strings.clone(string(d.pkce_redirect[:d.pkce_len]), context.temp_allocator)
	sync.unlock(&d.pkce_mutex)
	if err := tidal.login_pkce_complete(s, redirect, attempt); err != nil {
		fail_login(res, err)
	}
}

@(private = "file")
run_login_wait :: proc(d: ^Data, job: Login_Wait_Job, res: ^Result) {
	s := d.session
	attempt := u64(job.attempt)
	if attempt != tidal.session_login_attempt(s) {
		res.err = .Cancelled
		return
	}
	if job.not_before != {} {
		if wait := time.tick_diff(time.tick_now(), job.not_before); wait > 0 && jobs.sleep(&d.queue, wait) {
			// Stopping: retry_later puts the job back.
			res.err = .Cancelled
			return
		}
	}
	// An earlier poll got the tokens, then failed to load the session
	// (rate limited or the network dropped). The
	// device code is spent, so finish with the tokens, however long ago the
	// code expired.
	a := tidal.session_auth(s, context.temp_allocator)
	if a.user_id != 0 {
		return
	}
	if a.access_token != "" {
		err := tidal.load_oauth_session(s, a.token_type, a.access_token, a.refresh_token, a.expiry_time, a.is_pkce)
		if err != nil {
			fail_login(res, err)
			return
		}
		auth_changed(s, d)
		return
	}
	left := time.duration_seconds(time.tick_diff(time.tick_now(), job.deadline))
	if left <= 0 {
		res.err = .Timeout
		res.message = small("The code expired")
		return
	}
	code := job.device_code
	link := tidal.Link_Login {
		device_code = small_str(&code),
		interval    = f64(job.interval),
		expires_in  = left,
	}
	err := tidal.login_device_wait(s, &link, until_expiry = !job.once, attempt = attempt)
	res.payload = Login_Wait_Result{f32(link.interval)}
	if err != nil {
		fail_login(res, err)
	}
}

// fail_login is fail for a Login_Wait. A 5xx or a 408 says as much about
// the login as a network failure, so it's reported as .Network and the
// login tries again with what it has: the code, or the tokens.
@(private = "file")
fail_login :: proc(res: ^Result, err: tidal.Error) {
	fail(res, err)
	if e, _ := err.?; e.kind == .Http && (e.status >= 500 || e.status == 408) {
		res.err = .Network
	}
}

@(private = "file")
run_playlists :: proc(s: ^tidal.Session, res: ^Result, alloc: mem.Allocator) {
	liked, _, err := liked_version(s, context.temp_allocator)
	if err != nil {
		fail(res, err)
		return
	}
	sidebar := Sidebar_Result{liked_count = int(liked.count), liked_newest = liked.newest}
	// The pages go on to TIDAL's count of them. A page that came back
	// short or empty, a page that starts as the one before it did, or the
	// page cap ends them early.
	items := make([dynamic]Sidebar_Item, 0, 64, alloc)
	first_id := ""
	for offset := 0; offset < PLAYLIST_PAGE * PLAYLIST_PAGES_MAX; offset += PLAYLIST_PAGE {
		page, listed, total, perr := tidal.user_playlist_and_favorite_playlists(s, offset, PLAYLIST_PAGE, alloc)
		if perr != nil {
			fail(res, perr)
			return
		}
		if len(page) > 0 && offset > 0 && page[0].id == first_id {
			break // the same page again: TIDAL ignored the offset
		}
		if len(page) > 0 {
			first_id = page[0].id
		}
		for pl in page {
			item := Sidebar_Item{id = pl.id, name = pl.name, image = pl.square_picture, tracks = pl.num_tracks, own = pl.is_user_playlist}
			if t, ok := pl.last_updated.?; ok {
				item.updated = time.to_unix_nanoseconds(t) / 1e6
			}
			append(&items, item)
		}
		if listed < PLAYLIST_PAGE || (total >= 0 && offset + listed >= total) {
			break
		}
	}
	sidebar.playlists = items[:]
	res.payload = sidebar
}

// liked_version asks for one liked track, which gives Liked Songs' count
// and its newest track: together they tell whether it changed. A failed ask
// gives a zero version.
@(private = "file")
liked_version :: proc(s: ^tidal.Session, alloc: mem.Allocator) -> (version: List_Version, newest: Maybe(tidal.Track), err: tidal.Error) {
	tracks: []tidal.Track
	count: int
	tracks, count, err = tidal.favorites_tracks(s, 1, 0, .Date, .Descending, alloc)
	if err != nil {
		return
	}
	version.count = i64(count)
	if len(tracks) > 0 {
		version.newest = tracks[0].id
		newest = tracks[0]
	}
	return
}

// run_profile reads the signed-in user's name, its first and last name or
// else its username, and picture.
@(private = "file")
run_profile :: proc(s: ^tidal.Session, res: ^Result) {
	u, err := tidal.user_me(s, context.temp_allocator)
	if err != nil {
		fail(res, err)
		return
	}
	name := strings.trim_space(strings.join({u.first_name, u.last_name}, " ", context.temp_allocator))
	res.payload = Profile_Result{small(name if name != "" else u.username), small(u.picture_id)}
}

// run_liked_ids reads every liked track's id and followed artist's in one
// request and sorts them for the binary searches. The version is the
// sidebar's from when the job went out, since the ids don't say one.
@(private = "file")
run_liked_ids :: proc(s: ^tidal.Session, job: Liked_Ids_Job, res: ^Result, alloc: mem.Allocator) {
	ids, err := tidal.favorites_ids(s, alloc)
	if err != nil {
		fail(res, err)
		return
	}
	slice.sort(ids.tracks)
	slice.sort(ids.artists)
	res.payload = Liked_Ids_Result{slice.unique(ids.tracks), slice.unique(ids.artists), job.version}
}

// run_add_track likes, unlikes or adds a track to the end of a playlist,
// then asks for the list's version and the track as the list now has it,
// so the kept copies can take it in place. If that second ask fails, the
// add still stands and the result has no row.
@(private = "file")
run_add_track :: proc(s: ^tidal.Session, job: Add_Track_Job, res: ^Result, alloc: mem.Allocator) {
	track := fmt.tprint(job.track)
	id := job.id
	if job.source == .Liked {
		if job.remove {
			if err := tidal.favorites_remove_track(s, track); err != nil {
				fail(res, err)
				return
			}
			// list_edited takes the version; the set holds the truth about
			// the track itself.
			version, _, _ := liked_version(s, context.temp_allocator)
			res.payload = Add_Track_Result{version = version}
			return
		}
		if err := tidal.favorites_add_track(s, {track}); err != nil {
			fail(res, err)
			return
		}
		out := Add_Track_Result{added = true} // add_result tells from the count whether it was there
		version, newest, err := liked_version(s, alloc)
		if t, ok := newest.?; ok && err == nil && t.id == job.track {
			out.version = version
			out.row = row_from_track(t, alloc)
		}
		res.payload = out
		return
	}
	pl, err := tidal.playlist_get(s, small_str(&id), context.temp_allocator)
	if err != nil {
		fail(res, err)
		return
	}
	added: []i64
	added, err = tidal.user_playlist_add(s, &pl, {track}, allocator = context.temp_allocator)
	if err != nil {
		fail(res, err)
		return
	}
	out := Add_Track_Result{added = len(added) > 0}
	// Without an ETag the playlist wasn't read again after the add, so pl
	// is as it was before.
	if out.added && pl.num_tracks > 0 && pl.etag != "" {
		version := List_Version{count = i64(pl.num_tracks)}
		if t, ok := pl.last_updated.?; ok {
			version.updated = time.to_unix_nanoseconds(t) / 1e6
		}
		last, total, lerr := tidal.playlist_tracks(s, small_str(&id), 1, pl.num_tracks - 1, allocator = alloc)
		if lerr == nil && total == pl.num_tracks && len(last) == 1 && last[0].id == job.track {
			out.version = version
			out.row = row_from_track(last[0], alloc)
		}
	}
	res.payload = out
}

// run_remove_track finds the track at one of the job's indices, asking
// TIDAL for the one item at each, and removes it there with the playlist's
// ETag. A row whose place the list got wrong is never removed: if no index
// holds the track, the job fails and says so. The playlist is read again
// after the removal for its new count and version; if that read fails the
// removal still counts.
@(private = "file")
run_remove_track :: proc(s: ^tidal.Session, job: Remove_Track_Job, res: ^Result) {
	id := job.id
	playlist := small_str(&id)
	pl, err := tidal.playlist_get(s, playlist, context.temp_allocator)
	if err != nil {
		fail(res, err)
		return
	}
	at := -1
	for k in job.lo ..= job.hi {
		items, ierr := tidal.playlist_items(s, playlist, limit = 1, offset = int(k), allocator = context.temp_allocator)
		if ierr != nil {
			fail(res, ierr)
			return
		}
		if len(items) == 1 {
			if t, ok := items[0].(tidal.Track); ok && t.id == job.track {
				at = int(k)
				break
			}
		}
	}
	if at < 0 {
		res.err = .Object_Not_Found
		res.payload = Remove_Track_Result{missing = true}
		return
	}
	if err = tidal.user_playlist_remove_by_index(s, &pl, at, context.temp_allocator); err != nil {
		fail(res, err)
		return
	}
	out := Remove_Track_Result{index = at}
	// Without an ETag the playlist wasn't read again after the removal.
	if pl.etag != "" {
		out.read = true
		out.version.count = i64(pl.num_tracks)
		if t, ok := pl.last_updated.?; ok {
			out.version.updated = time.to_unix_nanoseconds(t) / 1e6
		}
	}
	res.payload = out
}

// fetch_size is the size an image job downloads. Artwork is shown at the
// size it's fetched, so it may leave fetch at 0.
fetch_size :: proc(job: Image_Job) -> int {
	return int(job.fetch) if job.fetch != 0 else int(job.size)
}

@(private = "file")
run_cover :: proc(d: ^Data, job: Image_Job, res: ^Result) {
	s := d.session
	id := job.id
	heap := runtime.heap_allocator()
	dir, path := cover_file(d, small_str(&id), fetch_size(job))
	body, cached := cover_read(path)
	if !cached {
		url := cover.url(s.config.image_url, small_str(&id), fetch_size(job), context.temp_allocator)
		err: tidal.Error
		body, err = tidal.resource_get(s, url, heap)
		if err != nil {
			// Not fail: covers carry no token, so a 401 here says nothing
			// about the login. The cover is marked failed and tried again
			// later.
			e, _ := err.?
			res.err = e.kind
			res.message = small(tidal.error_string(err, context.temp_allocator))
			return
		}
	}
	defer delete(body, heap)
	pixels, w, h, ok := cover.decode(body, int(job.size))
	if !ok {
		if cached {
			os.remove(path)
		}
		res.err = .Bad_Response
		res.message = small("not an image")
		return
	}
	if !cached {
		cover_write(d, dir, path, body)
	}
	res.payload = Image_Result{pixels, w, h}
}

MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// join_artists joins artists' names with commas, and says where each one
// is. Without artists it takes artist, which may be nil.
join_artists :: proc(artists: []tidal.Artist, artist: ^tidal.Artist, alloc: mem.Allocator) -> (joined: string, refs: []Artist_Ref) {
	if len(artists) == 0 {
		if artist == nil {
			return
		}
		refs = make([]Artist_Ref, 1, alloc)
		refs[0] = {id = artist.id, start = 0, end = i32(len(artist.name))}
		return artist.name, refs
	}
	refs = make([]Artist_Ref, len(artists), alloc)
	b := strings.builder_make(alloc)
	for a, i in artists {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		start := strings.builder_len(b)
		strings.write_string(&b, a.name)
		refs[i] = {id = a.id, start = i32(start), end = i32(strings.builder_len(b))}
	}
	return strings.to_string(b), refs
}

// local_date is t's date in the user's time zone, month 1 for January.
local_date :: proc(t: time.Time) -> (year, month, day: int) {
	lt, ok := sys.local_time(time.to_unix_seconds(t))
	if !ok {
		y, m, d := time.date(t)
		return y, int(m), d
	}
	return lt.year, lt.month, lt.day
}

// row_from_track turns a track into the strings the table shows.
row_from_track :: proc(t: tidal.Track, alloc: mem.Allocator) -> (row: Row) {
	row.title = t.full_name if t.full_name != "" else t.title
	row.artist, row.artists = join_artists(t.artists, t.artist, alloc)
	if t.album != nil {
		row.album = t.album.name
		row.cover = t.album.cover
	}
	if added, ok := t.date_added.?; ok {
		y, m, day := local_date(added)
		row.added = fmt.aprintf("%s %d, %d", MONTHS[m - 1], day, y, allocator = alloc)
	}
	row.seconds = t.duration
	row.id = t.id
	row.track = t.track_num
	if t.album != nil {
		row.album_id = t.album.id
	}
	row.duration = fmt.aprintf("%d:%02d", t.duration / 60, t.duration % 60, allocator = alloc)
	return
}
