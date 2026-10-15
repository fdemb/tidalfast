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
import "core:mem"
import vmem "core:mem/virtual"
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
}

Source :: enum u8 {
	None,
	Liked,
	Playlist,
}

Job :: struct {
	kind:       Job_Kind,
	source:     Source,
	once:       bool, // Login_Wait: poll once, to see if TIDAL answers again
	auth:       u32, // the auth generation it was queued in, see sign_out
	view:       u32, // Tracks: the view generation it's for
	offset:     i32,
	limit:      i32,
	key:        u64, // Cover: the cache key
	size:       u16, // Cover: pixels across
	interval:   f32, // Login_Wait: seconds between polls
	deadline:   time.Tick, // Login_Wait: when the code expires
	not_before: time.Tick, // Login_Wait: when to poll first, {} for now
	id:         Small, // playlist id, image id or device code
}

// Priorities: lower runs first.
PRIORITY_DATA :: 0
PRIORITY_COVER :: 1 // visible
PRIORITY_COVER_NEAR :: 2 // just outside the view

Sidebar_Item :: struct {
	id:     string,
	name:   string,
	image:  string, // square image id, "" for none
	tracks: int,
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
	playlists:   []Sidebar_Item,
	liked_count: int,
	signed_in:   bool, // Restore found tokens
	link:        Login_Link,
	pixels:      []u8, // from cover.decode
	w, h:        int,
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
	d.running = false
}

@(private = "file")
worker_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	d := (^Data)(arg)
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
		res := run_job(d, job)
		free_all(context.temp_allocator)
		if retry_later(d, res) {
			result_free(&res)
			jobs.requeue(&d.queue, job, ticket)
			continue
		}
		if !jobs.push_wait(&d.results, res) {
			result_free(&res)
			jobs.requeue(&d.queue, job, ticket)
			continue
		}
		jobs.done(&d.queue)
		d.wake()
	}
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
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

result_free :: proc(res: ^Result) {
	if res.arena != nil {
		vmem.arena_destroy(res.arena)
		free(res.arena, runtime.heap_allocator())
		res.arena = nil
	}
	cover.free_pixels(res.pixels)
	res.pixels = nil
}

@(private = "file")
fail :: proc(res: ^Result, err: tidal.Error) {
	e, _ := err.?
	// An expired session that couldn't be refreshed comes back as a plain
	// 401 from some endpoints.
	res.err = .Authentication if e.status == 401 else e.kind
	res.message = small(tidal.error_string(err, context.temp_allocator))
}

@(private = "file")
run_job :: proc(d: ^Data, job: Job) -> (res: Result) {
	res.job = job
	s := d.session
	if job.kind == .Cover {
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
	case .None, .Cover:
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
		if job.source == .Liked {
			tracks, err = tidal.favorites_tracks(s, int(job.limit), int(job.offset), .Date, .Descending, alloc)
		} else {
			tracks, err = tidal.playlist_tracks(s, small_str(&id), int(job.limit), int(job.offset), allocator = alloc)
		}
		if err != nil {
			fail(&res, err)
			return
		}
		res.rows = make([]Row, len(tracks), alloc)
		for t, i in tracks {
			res.rows[i] = row_from_track(t, alloc)
		}
	}
	return
}

@(private = "file")
run_login_wait :: proc(d: ^Data, job: Job, res: ^Result) {
	s := d.session
	if job.not_before != {} {
		if wait := time.tick_diff(time.tick_now(), job.not_before); wait > 0 && jobs.sleep(&d.queue, wait) {
			// Stopping for a reload: retry_later puts the job back.
			res.err = .Cancelled
			return
		}
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
	err: tidal.Error
	// An earlier poll got the tokens, then failed to load the session
	// (rate limited, or the network dropped). The device code is spent, so
	// finish with the tokens.
	if a := tidal.session_auth(s, context.temp_allocator); a.access_token != "" && a.user_id == 0 {
		err = tidal.load_oauth_session(s, a.token_type, a.access_token, a.refresh_token, a.expiry_time)
		if err == nil {
			auth_changed(s, d)
		}
	} else {
		err = tidal.login_device_wait(s, &link, until_expiry = !job.once)
	}
	res.link.interval = f32(link.interval)
	if err != nil {
		fail(res, err)
	}
}

@(private = "file")
run_playlists :: proc(s: ^tidal.Session, res: ^Result, alloc: mem.Allocator) {
	count, err := tidal.favorites_tracks_count(s)
	if err != nil {
		fail(res, err)
		return
	}
	res.liked_count = count
	items := make([dynamic]Sidebar_Item, 0, 64, alloc)
	for offset := 0;; offset += PLAYLIST_PAGE {
		page, perr := tidal.user_playlist_and_favorite_playlists(s, offset, PLAYLIST_PAGE, alloc)
		if perr != nil {
			fail(res, perr)
			return
		}
		for pl in page {
			append(&items, Sidebar_Item{id = pl.id, name = pl.name, image = pl.square_picture, tracks = pl.num_tracks})
		}
		if len(page) < PLAYLIST_PAGE {
			break
		}
	}
	res.playlists = items[:]
}

@(private = "file")
run_cover :: proc(d: ^Data, job: Job, res: ^Result) {
	s := d.session
	id := job.id
	url := cover.url(s.config.image_url, small_str(&id), int(job.size), context.temp_allocator)
	heap := runtime.heap_allocator()
	body, err := tidal.resource_get(s, url, heap)
	if err != nil {
		fail(res, err)
		return
	}
	defer delete(body, heap)
	pixels, w, h, ok := cover.decode(body)
	if !ok {
		res.err = .Bad_Response
		res.message = small("not an image")
		return
	}
	res.pixels, res.w, res.h = pixels, w, h
}

MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// row_from_track turns a track into the strings the table shows.
row_from_track :: proc(t: tidal.Track, alloc: mem.Allocator) -> (row: Row) {
	row.title = t.full_name if t.full_name != "" else t.title
	if len(t.artists) > 0 {
		b := strings.builder_make(alloc)
		for a, i in t.artists {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, a.name)
		}
		row.artist = strings.to_string(b)
	} else if t.artist != nil {
		row.artist = t.artist.name
	}
	if t.album != nil {
		row.album = t.album.name
		row.cover = t.album.cover
	}
	if added, ok := t.date_added.?; ok {
		y, m, day := time.date(added)
		row.added = fmt.aprintf("%s %d, %d", MONTHS[int(m) - 1], day, y, allocator = alloc)
	}
	row.seconds = t.duration
	row.duration = fmt.aprintf("%d:%02d", t.duration / 60, t.duration % 60, allocator = alloc)
	return
}
