package tidal_tests

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/cover"
import "../src/jobs"
import "../src/render"
import "../src/text"
import tidal "../src/tidal"
import "../src/ui"

@(private = "file")
no_wake :: proc "c" () {}

// The ids the mock's liked tracks should end up as: track i is id i + 1,
// newest first, with the unavailable ones left out.
@(private = "file")
liked_ids :: proc() -> []i64 {
	ids := make([dynamic]i64, 0, MOCK_LIKED, context.temp_allocator)
	outer: for i in 0 ..< MOCK_LIKED {
		for u in MOCK_UNAVAILABLE {
			if i == u {
				continue outer
			}
		}
		append(&ids, i64(i + 1))
	}
	return ids[:]
}

@(private = "file")
view_ids :: proc(v: ^app.Track_View) -> []i64 {
	ids := make([]i64, v.count, context.temp_allocator)
	for i in 0 ..< v.count {
		ids[i] = v.rows[i].id if v.loaded[i] else -1
	}
	return ids
}

// Liked Songs against a server that acts like TIDAL: 1433 tracks, 100 a
// page at most, and three that can't be played left out of their pages
// while totalNumberOfItems still counts them. A short page used to end the
// list, so only the first 149 rows loaded. The pages are fetched the way
// the app asks for them, then handed to the view in order and backwards.
@(test)
liked_songs_load_past_short_pages :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	s.config.api_v1_location = m.base_url
	s.config.api_v2_location = m.base_url
	s.config.api_oauth2_token = "http://127.0.0.1:1/token"
	testing.expect_value(t, tidal.load_oauth_session(s, "Bearer", "access", "refresh", time.time_add(time.now(), time.Hour)), nil)

	count, cerr := tidal.favorites_tracks_count(s)
	testing.expect_value(t, cerr, nil)
	testing.expect_value(t, count, MOCK_LIKED)

	Page :: struct {
		offset, limit: int,
		rows:          []app.Row,
		total:         int,
	}
	pages: [dynamic]Page
	pages.allocator = context.temp_allocator
	d := new(app.Data)
	defer free(d)
	app.view_open(d, .Liked, "", "Liked Songs", "", count)
	defer app.view_close(d)
	// What the workers would do with the jobs view_open and
	// view_request_pages queue, one page at a time.
	for !d.view.done {
		job, ok := jobs.try_pop(&d.queue)
		if !testing.expect(t, ok, "the view stopped asking for pages before the end") {
			return
		}
		tracks, total, err := tidal.favorites_tracks(s, int(job.limit), int(job.offset), allocator = context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, total, MOCK_LIKED)
		rows := make([]app.Row, len(tracks), context.temp_allocator)
		for tr, i in tracks {
			rows[i] = {id = tr.id, title = tr.title, seconds = tr.duration}
		}
		append(&pages, Page{int(job.offset), int(job.limit), rows, total})
		d.view.in_flight -= 1
		app.view_add_rows(&d.view, int(job.offset), int(job.limit), rows, total)
		app.view_request_pages(d)
	}
	want := liked_ids()
	testing.expect_value(t, len(want), MOCK_LIKED - len(MOCK_UNAVAILABLE))
	testing.expect_value(t, d.view.count, len(want))
	testing.expect_value(t, d.view.loaded_rows, len(want))
	testing.expect(t, slice.equal(view_ids(&d.view), want), "the rows aren't the liked tracks in order")
	_, more := jobs.try_pop(&d.queue)
	testing.expect(t, !more, "pages were asked for past the end")

	// The same pages arriving last first: the end comes before the gaps,
	// and each gap moves the rows already placed after it.
	app.view_open(d, .Liked, "", "Liked Songs", "", count)
	for i := len(pages) - 1; i >= 0; i -= 1 {
		p := pages[i]
		app.view_add_rows(&d.view, p.offset, p.limit, p.rows, p.total)
	}
	testing.expect(t, d.view.done)
	testing.expect_value(t, d.view.count, len(want))
	testing.expect_value(t, d.view.loaded_rows, len(want))
	testing.expect(t, slice.equal(view_ids(&d.view), want), "out of order pages put rows in the wrong place")

	// Without a total, a short page still ends the list.
	app.view_open(d, .Search, "q", "Results", "", 0)
	app.view_add_rows(&d.view, 0, 50, pages[0].rows[:20])
	testing.expect(t, d.view.done)
	testing.expect_value(t, d.view.count, 20)
}

// open_with_ids opens a list whose rows have these track ids.
@(private = "file")
open_with_ids :: proc(s: ^app.State, source: app.Source, id: string, ids: []i64) {
	rows := make([]app.Row, len(ids), context.temp_allocator)
	for &r, i in rows {
		r = {title = fmt.tprintf("Song %d", ids[i]), artist = "A", duration = "3:00", seconds = 180, id = ids[i]}
	}
	app.view_open(&s.data, source, id, id, "", len(rows))
	app.view_add_rows(&s.data.view, 0, len(rows), rows, len(rows))
}

// The playing row follows the track and the list it was played from, not
// the open view: it's lit again after going to another list and back, and
// the same track in another list isn't lit.
@(test)
playing_row_survives_reopening_its_list :: proc(t: ^testing.T) {
	s := new(app.State)
	defer free(s)
	s.data.account = .Signed_In
	s.library.selected = -1
	s.playback.index = -1
	s.playback.player = audio.create(no_wake, 0, null_output = true)
	defer app.data_shutdown(s)
	defer app.playback_shutdown(s)

	open_with_ids(s, .Playlist, "list-a", {100, 101, 102})
	app.playback_play_row(s, 1)
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, 1)

	// B has the same track at the same row. It isn't the queue's list.
	open_with_ids(s, .Playlist, "list-b", {200, 101, 202})
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, -1)
	open_with_ids(s, .Liked, "", {101, 300})
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, -1)

	open_with_ids(s, .Playlist, "list-a", {100, 101, 102})
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, 1)

	// A changed since: the queue's row holds another track, so the first
	// row with the playing track's id is lit.
	open_with_ids(s, .Playlist, "list-a", {102, 100, 103, 101})
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, 3)

	// Search results are a list of their own, named by the query.
	open_with_ids(s, .Search, "quiet", {500, 501})
	app.playback_play_row(s, 0)
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, 0)
	open_with_ids(s, .Search, "loud", {500, 501})
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, -1)
	open_with_ids(s, .Search, "quiet", {500, 501})
	app.playback_update(s, nil)
	testing.expect_value(t, s.library.playing, 0)
}

// Position and length are both in seconds at the track's own rate: the
// file's once the player knows it, TIDAL's until then.
@(test)
progress_uses_the_tracks_own_rate :: proc(t: ^testing.T) {
	s := new(app.State)
	defer free(s)
	pb := &s.playback
	items := []app.Queue_Item{{title = "Hi-res", seconds = 10}}
	pb.items = items
	pb.index = 0
	pb.cur = {serial = 5, rate = 96000, at = 96000 * 2}

	// Before the player has the track: TIDAL's length and rate.
	testing.expect_value(t, app.playback_duration(s), 10.0)
	testing.expect_value(t, app.playback_position(s), 2.0)

	// 24/96: the stream is 6 s long, not the 10 TIDAL said.
	pb.status = {serial = 5, rate = 96000, total = 96000 * 6, sample = 96000 * 3}
	testing.expect_value(t, app.playback_duration(s), 6.0)
	testing.expect_value(t, app.playback_position(s), 3.0)
	testing.expect_value(t, app.progress_fraction(app.playback_position(s), app.playback_duration(s)), f32(0.5))

	// The next track is 16/44.1.
	pb.cur = {serial = 6, rate = 44100}
	pb.status = {serial = 6, rate = 44100, total = 44100 * 10, sample = 44100 * 5}
	testing.expect_value(t, app.progress_fraction(app.playback_position(s), app.playback_duration(s)), f32(0.5))

	testing.expect_value(t, app.progress_fraction(12, 10), f32(1))
	testing.expect_value(t, app.progress_fraction(-1, 10), f32(0))
	testing.expect_value(t, app.progress_fraction(5, 0), f32(0))
}

@(private = "file")
Fonts :: struct {
	backing: []byte,
	arena:   mem.Arena,
	state:   ^text.State,
	r:       render.Renderer,
}

// fonts_init loads Inter for measuring. Nothing is drawn.
@(private = "file")
fonts_init :: proc(f: ^Fonts) -> bool {
	f.backing = make([]byte, 64 << 20)
	mem.arena_init(&f.arena, f.backing)
	context.allocator = mem.arena_allocator(&f.arena)
	f.state = new(text.State)
	if !text.init(f.state) {
		return false
	}
	text.begin_frame(f.state, &f.r)
	return true
}

@(private = "file")
fonts_destroy :: proc(f: ^Fonts) {
	text.destroy(f.state, &f.r)
	delete(f.backing)
}

// The times beside the progress bar are as wide as the widest value their
// pattern can take, so none is cut off: every position of tracks up to 99
// minutes, and around an hour.
@(test)
time_counters_fit_every_value :: proc(t: ^testing.T) {
	f: Fonts
	if !testing.expect(t, fonts_init(&f)) {
		return
	}
	defer fonts_destroy(&f)
	u: ui.State
	{
		context.allocator = mem.arena_allocator(&f.arena)
		ui.init(&u)
	}
	ui.begin_frame(&u, nil, nil, f.state, 800, 600, 0)
	defer ui.end_frame()

	for duration in ([]int{59, 599, 5999, 3600 + 125}) {
		long := app.clock(f64(duration))
		elapsed_w := ui.counter_width(.Regular, 11, long)
		left_w := ui.counter_width(.Regular, 11, fmt.tprintf("-%s", long))
		for p in 0 ..= duration {
			at := app.clock(f64(p))
			left := fmt.tprintf("-%s", app.clock(f64(duration - p)))
			if w := ui.text_width(.Regular, 11, at); w > elapsed_w {
				testing.expectf(t, false, "%s is %v wide, the counter %v", at, w, elapsed_w)
				return
			}
			if w := ui.text_width(.Regular, 11, left); w > left_w {
				testing.expectf(t, false, "%s is %v wide, the counter %v", left, w, left_w)
				return
			}
		}
	}
	vol := ui.counter_width(.Regular, 12, "Volume 100%")
	for v in 0 ..= 100 {
		label := fmt.tprintf("Volume %d%%", v)
		testing.expectf(t, ui.text_width(.Regular, 12, label) <= vol, "%s doesn't fit", label)
	}
}

@(private = "file")
find_box :: proc(b: ^ui.Box, id: string) -> ^ui.Box {
	if b.id == id {
		return b
	}
	for c := b.first; c != nil; c = c.next {
		if found := find_box(c, id); found != nil {
			return found
		}
	}
	return nil
}

// The player bar at narrow to wide windows, with a long hi-res track most
// of the way through. The progress fill stays inside its rail, the rail
// between the times, nothing past the window's right edge, and neither
// time is cut off. The fill was a share of the window's width, not the
// rail's, so it ran off the rail about a quarter of the way in at 820 pt.
@(test)
player_bar_fits_at_every_width :: proc(t: ^testing.T) {
	f: Fonts
	if !testing.expect(t, fonts_init(&f)) {
		return
	}
	defer fonts_destroy(&f)
	context.allocator = mem.arena_allocator(&f.arena)
	s := new(app.State)
	ui.init(&s.ui)
	app.library_init(&s.library)
	cover.init(&s.data.covers, 1 << 20)
	app.search_init(s)
	defer app.search_shutdown(s)
	s.data.account = .Signed_In
	pb := &s.playback
	items := []app.Queue_Item{{title = "Quiet Noise 24/96", artist = "Mock", seconds = 3725}}
	pb.items = items
	pb.index = 0
	pb.cur = {serial = 1, rate = 96000, resolved = true}
	pb.status = {serial = 1, rate = 96000, total = 96000 * 3725, sample = 96000 * 3500, state = .Playing}
	s.library.volume = 1

	for w in ([]f32{575, 820, 1100, 1600}) {
		free_all(context.temp_allocator)
		text.begin_frame(f.state, &f.r)
		ui.begin_frame(&s.ui, nil, nil, f.state, w, 700, 0)
		app.draw_library(s, w, 700)
		ui.end_frame()
		root := s.ui.root
		bar := find_box(root, "player")
		progress := find_box(root, "progress")
		volume := find_box(root, "volume")
		if !testing.expect(t, bar != nil && progress != nil && volume != nil) {
			return
		}
		rail := progress.first.next
		fill := rail.first
		at := find_box(root, app.clock(3500))
		left := find_box(root, fmt.tprintf("-%s", app.clock(225)))
		if !testing.expect(t, at != nil && left != nil) {
			return
		}
		right :: proc(r: render.Rect) -> f32 {return r.x + r.w}
		testing.expectf(t, fill.rect.w > 0 && right(fill.rect) <= right(rail.rect) + 0.01, "%v: the fill ends at %v, the rail at %v", w, right(fill.rect), right(rail.rect))
		testing.expectf(t, abs(fill.rect.w - rail.rect.w * 3500 / 3725) < 0.5, "%v: the fill is %v of a %v rail", w, fill.rect.w, rail.rect.w)
		testing.expectf(t, right(at.rect) <= progress.rect.x + 0.01 && right(progress.rect) <= left.rect.x + 0.01, "%v: the rail overlaps the times", w)
		testing.expectf(t, right(volume.rect) <= w + 0.01 && right(left.rect) <= w + 0.01, "%v: the bar runs off the window", w)
		for label in ([]^ui.Box{at, left}) {
			need := ui.text_width(.Regular, 11, label.label)
			testing.expectf(t, label.rect.w - 2 * label.text_pad >= need, "%v: %q has %v for %v", w, label.label, label.rect.w - 2 * label.text_pad, need)
		}
	}
	free_all(context.temp_allocator)
}
