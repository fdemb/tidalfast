package tidal_tests

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/cover"
import "../src/jobs"
import "../src/platform"
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
	for app.view_loading(&d.view) {
		queued, ok := jobs.try_pop(&d.queue)
		if !testing.expect(t, ok, "the view stopped asking for pages before the end") {
			return
		}
		job := queued.payload.(app.Tracks_Job)
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
	testing.expect(t, !app.view_loading(&d.view))
	testing.expect_value(t, d.view.count, len(want))
	testing.expect_value(t, d.view.loaded_rows, len(want))
	testing.expect(t, slice.equal(view_ids(&d.view), want), "out of order pages put rows in the wrong place")

	// Without a total, a short page still ends the list.
	app.view_open(d, .Search, "q", "Results", "", 0)
	app.view_add_rows(&d.view, 0, 50, pages[0].rows[:20])
	testing.expect(t, !app.view_loading(&d.view))
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
	defer test_state_free(s)
	sign_in(s)
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

Fonts :: struct {
	backing: []byte,
	arena:   mem.Arena,
	state:   ^text.State,
	r:       render.Renderer,
}

// fonts_init loads the system font for measuring. Nothing is drawn.
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
	sign_in(s)
	defer {
		app.data_shutdown(s)
		test_state_free(s)
	}
	pb := &s.playback
	items := []app.Queue_Item{{title = "Quiet Noise 24/96", artist = "Mock", seconds = 3725}}
	pb.items = items
	pb.index = 0
	pb.cur = {serial = 1, rate = 96000, resolved = true}
	pb.status = {serial = 1, rate = 96000, total = 96000 * 3725, sample = 96000 * 3500, state = .Playing}
	s.settings.volume = 1
	// The longest output button there is, next to the speaker.
	pb.output_seen.name_len = copy(pb.output_seen.name[:], "Built-in Audio Analog Stereo Headphones")

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
		left := find_box(root, "###bar_time")
		if !testing.expect(t, at != nil && left != nil) {
			return
		}
		testing.expect_value(t, left.label, fmt.tprintf("-%s", app.clock(225)))
		right :: proc(r: render.Rect) -> f32 {return r.x + r.w}
		testing.expectf(t, fill.rect.w > 0 && right(fill.rect) <= right(rail.rect) + 0.01, "%v: the fill ends at %v, the rail at %v", w, right(fill.rect), right(rail.rect))
		testing.expectf(t, abs(fill.rect.w - rail.rect.w * 3500 / 3725) < 0.5, "%v: the fill is %v of a %v rail", w, fill.rect.w, rail.rect.w)
		testing.expectf(t, right(at.rect) <= progress.rect.x + 0.01 && right(progress.rect) <= left.rect.x + 0.01, "%v: the rail overlaps the times", w)
		testing.expectf(t, right(volume.rect) <= w + 0.01 && right(left.rect) <= w + 0.01, "%v: the bar runs off the window", w)
		speaker := find_box(root, "###speaker")
		output := find_box(root, "###output")
		if testing.expect(t, speaker != nil && output != nil) {
			testing.expectf(t, speaker.rect.w == app.SPEAKER_SIZE && right(output.rect) <= speaker.rect.x + 0.01 && right(speaker.rect) <= volume.rect.x + 0.01, "%v: the output button, the speaker and the slider overlap", w)
			testing.expectf(t, right(left.rect) <= output.rect.x + 0.01, "%v: the time left runs into the output button", w)
		}
		for label in ([]^ui.Box{at, left}) {
			need := ui.text_width(.Regular, 11, label.label)
			testing.expectf(t, label.rect.w - 2 * label.text_pad >= need, "%v: %q has %v for %v", w, label.label, label.rect.w - 2 * label.text_pad, need)
		}
	}
	free_all(context.temp_allocator)
}

// A list still loading when it closes goes on loading in d.queued. Gaps
// that come in after that belong to it, not to the list opened next, so
// they survive that list being freed.
@(test)
queued_list_keeps_its_gaps :: proc(t: ^testing.T) {
	d := new(app.Data)
	defer free(d)
	d.poison = true
	defer app.view_release(&d.retired)
	defer app.queued_drop(d)
	defer app.view_close(d)
	rows := make([]app.Row, 90, context.temp_allocator)
	for &r in rows {
		r.title = "x"
	}
	// Every page of 100 comes back with 90: a gap of 10 each.
	app.view_open(d, .Playlist, "a", "a", "", 2000)
	d.queue_view = d.view.gen
	for i in 0 ..< 8 {
		app.view_add_rows(&d.view, i * 100, 100, rows, 2000)
	}
	app.view_close(d)
	testing.expect_value(t, d.queued.gen, d.queue_view)

	app.view_open(d, .Playlist, "b", "b", "", 100)
	app.view_add_rows(&d.queued, 800, 100, rows, 2000)
	app.view_close(d)
	testing.expect_value(t, app.view_row_at(&d.queued, 900), 810)
}

// A freed list's gaps read as POISON, like its rows, so a late borrow of
// them shows.
@(test)
freed_list_poisons_its_gaps :: proc(t: ^testing.T) {
	d := new(app.Data)
	defer free(d)
	d.poison = true
	defer app.view_release(&d.retired)
	rows := make([]app.Row, 90, context.temp_allocator)
	app.view_open(d, .Playlist, "a", "a", "", 300)
	app.view_add_rows(&d.view, 0, 100, rows, 300)
	gaps := d.view.gaps
	if !testing.expect_value(t, len(gaps), 1) {
		return
	}
	app.view_close(d)
	testing.expect_value(t, u64(gaps[0].offset), u64(0xdbdb_dbdb_dbdb_dbdb))
}

// The track table has no focus ring: its selected row shows the focus. So
// the keyboard coming into it with nothing selected selects the first row
// in view.
@(test)
keyboard_focus_selects_the_first_row_in_view :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	testing.expect_value(t, s.library.selected, -1)
	library_frame(t, s, &f, {kind = .Mouse_Move, x = 600, y = 400})
	library_frame(t, s, &f, {kind = .Scroll, x = 600, y = 400, dy = -3000, precise = true, phase = .Began})
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}

	table: platform.Access_Node
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Table {
			table = n
		}
	}
	testing.expect(t, table.id != 0, "the track table")
	library_frame(t, s, &f, {kind = .Access_Focus, target = table.id})
	library_frame(t, s, &f)
	testing.expect(t, s.library.selected > 0, "a row past the top is selected")
	shown := false
	nodes, _ = ui.access_tree(&s.ui)
	for n in nodes {
		shown ||= n.role == .Row && .Selected in n.flags
	}
	testing.expect(t, shown, "the selected row is in view")
}
