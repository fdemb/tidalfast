package app

// Worker threads for everything that blocks: TIDAL requests, cover
// downloads and JPEG decoding. The UI thread pushes Jobs into data.queue; a
// worker runs one, pushes a Result into data.results and wakes the UI
// thread with the shell's request_redraw. Jobs and results are plain data
// with fixed-size text, so they reference nothing a view switch or a hot
// reload could free.
//
// Workers run this dylib's code, so unload stops them: it aborts requests
// in flight, and a worker whose job was cut short puts the job back in the
// queue. reload starts new workers, which pick those jobs up again.
//
// Memory: each job that returns data gets its own virtual-memory arena,
// which travels in the Result. The UI thread copies what it keeps into the
// view's arena, or adopts the whole arena, and frees the rest. Scratch
// memory is the worker's thread-local temp allocator, reset after each job.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../cover"
import "../jobs"
import "../tidal"

WORKERS :: 4
JOB_QUEUE :: 256
RESULT_QUEUE :: 256
PAGE_FIRST :: 50 // the first page of a track list, small so it shows fast
PAGE_SIZE :: 100
PLAYLIST_PAGE :: 50 // TIDAL's cap for playlistsAndFavoritePlaylists

// Small is text with a fixed buffer, for jobs and results.
Small :: struct {
	len: u8,
	buf: [119]u8,
}

small :: proc(s: string) -> (out: Small) {
	n := min(len(s), len(out.buf))
	copy(out.buf[:], s[:n])
	out.len = u8(n)
	return
}

small_str :: proc(s: ^Small) -> string {
	return string(s.buf[:s.len])
}

Job_Kind :: enum u8 {
	None,
	Restore, // read the tokens from the Keychain into the session
	Login_Start, // ask TIDAL for a device code
	Login_Wait, // poll until the user approves the device code
	Playlists, // the sidebar: liked songs count, playlists made or followed
	Tracks, // one page of a track list
	Cover, // download and decode one cover
	Stream, // resolve a track's stream URL, see player.odin
	Artwork, // a cover for Now Playing: download and decode, keep the pixels
	Search, // songs, albums, artists and playlists for a query, see search.odin
	Login_Pkce, // finish a PKCE login with the pasted address, see login.odin
	Save_Settings, // write the settings, see settings.odin
	Disk, // read or write a cache file, on the disk thread, see lists.odin
}

Source :: enum u8 {
	None,
	Liked,
	Playlist,
	Search,
	Album,
	Artist,
}

Job :: struct {
	kind:       Job_Kind,
	source:     Source,
	once:       bool, // Login_Wait: poll once, to see if TIDAL answers again
	auth:       u32, // the auth generation it was queued in, see sign_out
	view:       u32, // Tracks: the view generation it's for; Stream: the track's serial; Search: the query's generation; Login_Start, Login_Wait, Login_Pkce: the login attempt
	offset:     i32,
	limit:      i32,
	key:        u64, // Cover: the cache key; Stream: the track id; Artwork: the track's serial; Disk: the user id
	size:       u16, // Cover: pixels across on screen
	fetch:      u16, // Cover: the size to download
	interval:   f32, // Login_Wait: seconds between polls
	deadline:   time.Tick, // Login_Wait: when the code expires
	not_before: time.Tick, // Login_Wait: when to poll first, {} for now
	id:         Small, // playlist id, image id, device code, query, album or artist id
	op:         Disk_Op,
	blob:       []u8, // Disk writes: the file, heap, freed by the disk thread
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
}

Login_Link :: struct {
	user_code:   Small,
	uri:         Small,
	uri_full:    Small, // with the code in it
	device_code: Small,
	interval:    f32,
	expires:     f32,
}

Result :: struct {
	job:         Job,
	err:         Maybe(tidal.Error_Kind),
	message:     Small,
	arena:       ^vmem.Arena, // owns rows, playlists and their strings
	rows:        []Row,
	total:       int, // Tracks: the list's length TIDAL gave with the page, -1 if it didn't
	playlists:   []Sidebar_Item,
	liked_count: int,
	signed_in:   bool, // Restore found tokens
	link:        Login_Link,
	pixels:      []u8, // from cover.decode
	w, h:        int,
	stream:      tidal.Stream_Info, // strings in arena
	codec:       Small, // Stream: the manifest's codec, when that's why it failed
	found:       Found_Lists, // Search: in arena
	liked_newest: i64, // Playlists: the newest liked track's id
	hit:         bool, // Disk: the file was there and good
	version:     List_Version, // Disk: what the list was fetched at
	fetched:     i64, // Disk: when, unix seconds
}

workers_start :: proc(d: ^Data) {
	if d.running || d.session == nil {
		return
	}
	jobs.start(&d.queue)
	jobs.start(&d.results)
	tidal.session_abort(d.session, false)
	for &t in d.threads {
		posix.pthread_create(&t, nil, worker_main, d)
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
	for t in d.threads {
		posix.pthread_join(t)
	}
	disk_stop(d)
	d.running = false
}

@(private = "file")
worker_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	context.logger = app_logger()
	d := (^Data)(arg)
	temp_given := false
	for {
		job, ticket, ok := jobs.pop_wait(&d.queue)
		if !ok {
			break
		}
		// Every worker checks the session's backoff before it sends
		// anything, cover downloads included, so a 429 or an anti-abuse
		// 403 holds all of them back until TIDAL's Retry-After has passed.
		if wait := tidal.backoff_remaining(d.session); wait > 0 {
			jobs.requeue(&d.queue, job, ticket)
			d.wake()
			if jobs.sleep(&d.queue, time.Duration(wait * f64(time.Second))) {
				break
			}
			continue
		}
		temp_take_back(&temp_given)
		res := run_job(d, job)
		free_all(context.temp_allocator)
		if retry_later(d, res) {
			result_free(&res)
			jobs.requeue(&d.queue, requeued(job, res), ticket)
			continue
		}
		if e, failed := res.err.?; failed && e == .Refresh_Failed {
			// The tokens are kept, so the job goes back after a wait that
			// doubles with each failed refresh until one works.
			result_free(&res)
			n := sync.atomic_add(&d.refresh_errors, 1) + 1
			wait := min(1 << uint(min(n, 5)), LOGIN_RETRY_MAX)
			stopping := jobs.sleep(&d.queue, time.Duration(wait) * time.Second)
			jobs.requeue(&d.queue, job, ticket)
			if stopping {
				break
			}
			continue
		}
		if !jobs.push_wait(&d.results, res) {
			result_free(&res)
			jobs.requeue(&d.queue, requeued(job, res), ticket)
			continue
		}
		jobs.done(&d.queue)
		d.wake()
		if queued, _ := jobs.pending(&d.queue); queued == 0 {
			temp_give_back(&temp_given)
		}
	}
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
}

// A worker's temp arena is one 4 MB block, and parsing a page of tracks
// dirties about 750 KB of it. Rolling the arena back keeps those pages, so
// with nothing left to do a worker gives back all but TEMP_KEEP of the block
// to the system, and takes it back before its next job.
@(private = "file")
TEMP_KEEP :: 64 << 10

@(private = "file")
MADV_FREE_REUSABLE :: 7
@(private = "file")
MADV_FREE_REUSE :: 8

// temp_tail is the whole pages of a block at base, capacity bytes long,
// past its first keep bytes. Empty if there are none.
temp_tail :: proc(base: uintptr, capacity, keep: uint) -> (start: rawptr, size: uint) {
	PAGE :: 16 << 10 // arm64's page; a multiple of 4 KB pages too
	from := mem.align_forward_uintptr(base + uintptr(keep), PAGE)
	to := (base + uintptr(capacity)) &~ (PAGE - 1)
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
	return temp_tail(uintptr(b.base), b.capacity, TEMP_KEEP)
}

@(private = "file")
temp_give_back :: proc(given: ^bool) {
	if start, size := temp_range(); size > 0 && !given^ {
		posix.posix_madvise(start, size, transmute(posix.MAdvice)i32(MADV_FREE_REUSABLE))
		given^ = true
	}
}

@(private = "file")
temp_take_back :: proc(given: ^bool) {
	if start, size := temp_range(); size > 0 && given^ {
		posix.posix_madvise(start, size, transmute(posix.MAdvice)i32(MADV_FREE_REUSE))
	}
	given^ = false
}

// retry_later says whether a job should go back in the queue instead of
// failing: it was cut short by unload, held back by the backoff gate, or
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

// requeued is job as it goes back in the queue. A Login_Wait that polled
// keeps the interval TIDAL asked for, slow_down included, and polls again
// no sooner than that interval from now.
@(private = "file")
requeued :: proc(job: Job, res: Result) -> Job {
	job := job
	if job.kind == .Login_Wait && res.link.interval > 0 {
		job.interval = res.link.interval
		job.not_before = time.tick_add(time.tick_now(), time.Duration(f64(job.interval) * f64(time.Second)))
	}
	return job
}

result_free :: proc(res: ^Result) {
	if res.arena != nil {
		vmem.arena_destroy(res.arena)
		free(res.arena, runtime.heap_allocator())
		res.arena = nil
	}
	cover.free_pixels(res.pixels)
	res.pixels = nil
}

// fail records err for a job that sent the login's tokens. An expired
// session that couldn't be refreshed comes back as a plain 401 from some
// endpoints, so that ends the login too.
@(private = "file")
fail :: proc(res: ^Result, err: tidal.Error) {
	e, _ := err.?
	res.err = .Authentication if e.kind == .Http && e.status == 401 else e.kind
	res.message = small(tidal.error_string(err, context.temp_allocator))
}

// stream_error_line is the log line for a stream that didn't resolve, or
// "" when there's nothing to log. It holds only fields that can't carry
// server text (see tidal.error_summary): what the server said may hold a
// signed URL.
stream_error_line :: proc(track_id: u64, what: string, err: tidal.Error, allocator := context.allocator) -> string {
	e, _ := err.?
	if e.kind == .Cancelled || e.kind == .Backing_Off {
		return "" // the job goes back in the queue
	}
	return fmt.aprintf("app: stream for track %d %s: %s", track_id, what, tidal.error_summary(err, context.temp_allocator), allocator = allocator)
}

@(private = "file")
log_stream_error :: proc(track_id: u64, what: string, err: tidal.Error) {
	if line := stream_error_line(track_id, what, err, context.temp_allocator); line != "" {
		log.error(line)
	}
}

@(private = "file")
run_job :: proc(d: ^Data, job: Job) -> (res: Result) {
	res.job = job
	s := d.session
	if job.kind == .Cover || job.kind == .Artwork {
		run_cover(d, job, &res)
		return
	}
	res.arena = new(vmem.Arena, runtime.heap_allocator())
	if err := vmem.arena_init_growing(res.arena); err != nil {
		free(res.arena, runtime.heap_allocator())
		res.arena = nil
		res.err = .Io
		res.message = small("out of memory")
		return
	}
	alloc := vmem.arena_allocator(res.arena)
	id := job.id
	switch job.kind {
	case .None, .Cover, .Artwork, .Disk:
	case .Save_Settings:
		if !settings_flush(d) {
			res.err = .Io
			res.message = small("Couldn't save the settings")
		}
	case .Login_Pkce:
		run_login_pkce(d, job, &res)
	case .Stream:
		info, refused, err := tidal.resolve_stream_flac(s, i64(job.key), alloc)
		if refused != nil {
			log_stream_error(job.key, "at HI_RES_LOSSLESS failed, asking for LOSSLESS", refused)
		}
		if err != nil {
			log_stream_error(job.key, "failed", err)
			fail(&res, err)
			if e, _ := err.?; e.kind == .Lossy_Stream {
				res.codec = small(tidal.error_detail(&e))
			}
			return
		}
		res.stream = info
	case .Restore:
		res.signed_in = auth_load(d, &res)
	case .Login_Start:
		link, err := tidal.login_device_start(s, alloc)
		if err != nil {
			fail(&res, err)
			return
		}
		res.link = {
			user_code   = small(link.user_code),
			uri         = small(link.verification_uri),
			uri_full    = small(link.verification_uri_complete),
			device_code = small(link.device_code),
			interval    = f32(link.interval),
			expires     = f32(link.expires_in),
		}
	case .Login_Wait:
		run_login_wait(d, job, &res)
	case .Playlists:
		run_playlists(s, &res, alloc)
	case .Tracks:
		tracks: []tidal.Track
		err: tidal.Error
		res.total = -1
		#partial switch job.source {
		case .Liked:
			tracks, res.total, err = tidal.favorites_tracks(s, int(job.limit), int(job.offset), .Date, .Descending, alloc)
		case .Playlist:
			tracks, res.total, err = tidal.playlist_tracks(s, small_str(&id), int(job.limit), int(job.offset), allocator = alloc)
		case:
			tracks, err = more_tracks(s, job, alloc)
		}
		if err != nil {
			fail(&res, err)
			return
		}
		res.rows = make([]Row, len(tracks), alloc)
		for t, i in tracks {
			res.rows[i] = row_from_track(t, alloc)
		}
	case .Search:
		found, err := tidal.search(s, small_str(&id), {.Track, .Album, .Artist, .Playlist}, SEARCH_PAGE, 0, alloc)
		if err != nil {
			fail(&res, err)
			return
		}
		res.rows = make([]Row, len(found.tracks), alloc)
		for t, i in found.tracks {
			res.rows[i] = row_from_track(t, alloc)
		}
		res.found = found_lists(found, alloc)
	}
	return
}

// run_login_pkce trades the pasted address's code for tokens. If an
// earlier try already did, and then loading the account failed or a reload
// cut it short, the code is spent: it finishes with those tokens instead.
@(private = "file")
run_login_pkce :: proc(d: ^Data, job: Job, res: ^Result) {
	s := d.session
	attempt := u64(job.view)
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
	sync.guard(&d.pkce_mutex)
	if err := tidal.login_pkce_complete(s, string(d.pkce_redirect[:d.pkce_len]), attempt); err != nil {
		fail_login(res, err)
	}
}

@(private = "file")
run_login_wait :: proc(d: ^Data, job: Job, res: ^Result) {
	s := d.session
	attempt := u64(job.view)
	if attempt != tidal.session_login_attempt(s) {
		res.err = .Cancelled
		return
	}
	if job.not_before != {} {
		if wait := time.tick_diff(time.tick_now(), job.not_before); wait > 0 && jobs.sleep(&d.queue, wait) {
			// Stopping for a reload: retry_later puts the job back.
			res.err = .Cancelled
			return
		}
	}
	// An earlier poll got the tokens, then failed to load the session
	// (rate limited, the network dropped, or a reload cut it short). The
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
	id := job.id
	link := tidal.Link_Login {
		device_code = small_str(&id),
		interval    = f64(job.interval),
		expires_in  = left,
	}
	err := tidal.login_device_wait(s, &link, until_expiry = !job.once, cancel = &d.device_cancel, attempt = attempt)
	res.link.interval = f32(link.interval)
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
	// One liked track gives the count and the newest, which tell whether
	// Liked Songs changed.
	newest, count, err := tidal.favorites_tracks(s, 1, 0, .Date, .Descending, context.temp_allocator)
	if err != nil {
		fail(res, err)
		return
	}
	res.liked_count = count
	if len(newest) > 0 {
		res.liked_newest = newest[0].id
	}
	items := make([dynamic]Sidebar_Item, 0, 64, alloc)
	for offset := 0;; offset += PLAYLIST_PAGE {
		page, perr := tidal.user_playlist_and_favorite_playlists(s, offset, PLAYLIST_PAGE, alloc)
		if perr != nil {
			fail(res, perr)
			return
		}
		for pl in page {
			item := Sidebar_Item{id = pl.id, name = pl.name, image = pl.square_picture, tracks = pl.num_tracks}
			if t, ok := pl.last_updated.?; ok {
				item.updated = time.to_unix_nanoseconds(t) / 1e6
			}
			append(&items, item)
		}
		if len(page) < PLAYLIST_PAGE {
			break
		}
	}
	res.playlists = items[:]
}

// fetch_size is the size a Cover or Artwork job downloads. Artwork is shown
// at the size it's fetched, so it may leave fetch at 0.
fetch_size :: proc(job: Job) -> int {
	return int(job.fetch) if job.fetch != 0 else int(job.size)
}

@(private = "file")
run_cover :: proc(d: ^Data, job: Job, res: ^Result) {
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
	res.pixels, res.w, res.h = pixels, w, h
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

// row_from_track turns a track into the strings the table shows.
row_from_track :: proc(t: tidal.Track, alloc: mem.Allocator) -> (row: Row) {
	row.title = t.full_name if t.full_name != "" else t.title
	row.artist, row.artists = join_artists(t.artists, t.artist, alloc)
	if t.album != nil {
		row.album = t.album.name
		row.cover = t.album.cover
	}
	if added, ok := t.date_added.?; ok {
		y, m, day := time.date(added)
		row.added = fmt.aprintf("%s %d, %d", MONTHS[int(m) - 1], day, y, allocator = alloc)
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
