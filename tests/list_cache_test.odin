package tidal_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/jobs"
import "../src/tidal"

@(private = "file")
no_wake :: proc "c" () {}

// cache_dir is a new directory under /tmp for one test's cache files.
@(private = "file")
cache_dir :: proc(name: string) -> string {
	dir := fmt.aprintf("/tmp/tidalfast-test-%s-%x", name, rand.uint64(), allocator = runtime.heap_allocator())
	os.make_directory_all(dir)
	return dir
}

// cache_state is a signed-in State with the memory cache on and, with dir,
// the disk cache in dir for user 7. No workers: tests run the jobs.
@(private = "file")
cache_state :: proc(dir := "") -> ^app.State {
	s := new(app.State)
	app.library_init(&s.library)
	s.playback.index = -1
	s.data.account = .Signed_In
	s.data.poison = true
	s.data.lists.memory = true
	if dir != "" {
		s.data.lists.root = strings.clone(dir, runtime.heap_allocator())
		s.data.lists.user = 7
	}
	return s
}

@(private = "file")
cache_state_free :: proc(s: ^app.State) {
	app.data_shutdown(s)
	free(s)
}

@(private = "file")
rows_of :: proc(ids: []i64) -> []app.Row {
	rows := make([]app.Row, len(ids), context.temp_allocator)
	artists := slice.clone([]app.Artist_Ref{{id = 42, start = 0, end = len("Björk")}, {id = 43, start = len("Björk, "), end = len("Björk, فيروز")}}, context.temp_allocator)
	for &r, i in rows {
		r = {
			title     = fmt.tprintf("Song %d 夜に駆ける", ids[i]),
			artist    = "Björk, فيروز",
			album     = fmt.tprintf("Album %d", ids[i] % 7),
			added     = "Jan 5, 2026",
			duration  = "3:05",
			cover     = "0f1e2d3c-0000-4000-8000-000000000001",
			seconds   = 185 + int(ids[i] % 3),
			id        = ids[i],
			album_id  = ids[i] % 7 + 1,
			artists   = artists,
			track     = int(ids[i] % 12) + 1,
		}
	}
	return rows
}

@(private = "file")
ids_from :: proc(from, to: i64) -> []i64 {
	ids := make([]i64, to - from, context.temp_allocator)
	for &id, i in ids {
		id = from + i64(i)
	}
	return ids
}

@(private = "file")
view_ids :: proc(v: ^app.Track_View) -> []i64 {
	ids := make([]i64, v.count, context.temp_allocator)
	for i in 0 ..< v.count {
		ids[i] = v.rows[i].id if v.loaded[i] else -1
	}
	return ids
}

// serve answers the queued Tracks jobs with pages of rows, as the workers
// would, until none are left. It returns how many it answered.
@(private = "file")
serve :: proc(s: ^app.State, rows: []app.Row) -> int {
	n := 0
	for {
		job, ok := jobs.try_pop(&s.data.queue)
		if !ok {
			return n
		}
		if job.kind != .Tracks {
			continue
		}
		lo := min(int(job.offset), len(rows))
		hi := min(lo + int(job.limit), len(rows))
		res := app.Result {
			job   = job,
			rows  = rows[lo:hi],
			total = len(rows),
		}
		app.handle_result(s, &res, 0)
		n += 1
	}
}

// track_jobs counts the queued Tracks jobs and drops them.
@(private = "file")
track_jobs :: proc(s: ^app.State) -> int {
	return jobs.remove_if(&s.data.queue, proc(job: ^app.Job, _: rawptr) -> bool {return job.kind == .Tracks}, nil)
}

// run_disk runs the queued disk jobs and hands reads to the app. It
// returns how many it ran.
@(private = "file")
run_disk :: proc(s: ^app.State) -> int {
	n := 0
	for {
		job, ok := jobs.try_pop(&s.data.lists.queue)
		if !ok {
			return n
		}
		res, reply := app.disk_run(&s.data, job)
		if reply {
			app.handle_result(s, &res, 0)
		}
		app.result_free(&res)
		n += 1
	}
}

// sidebar gives the app a sidebar from TIDAL with one playlist "pl" at
// version (updated, count), and Liked Songs at (liked, newest).
@(private = "file")
sidebar :: proc(s: ^app.State, updated: i64, count: int, liked := 3, newest: i64 = 900) {
	items := make([]app.Sidebar_Item, 2, context.temp_allocator)
	items[0] = {id = "other", name = "Other", tracks = 2, updated = 1}
	items[1] = {id = "pl", name = "A playlist", tracks = count, updated = updated}
	res := app.Result {
		job          = {kind = .Playlists},
		playlists    = items,
		liked_count  = liked,
		liked_newest = newest,
	}
	app.handle_result(s, &res, 0)
}

LIKED_IDS :: []i64{900, 901, 902}

// A list written to a file and read back gives the same rows, strings in
// the file's own memory, and the header's version and time.
@(test)
list_file_round_trip :: proc(t: ^testing.T) {
	d := new(app.Data)
	defer free(d)
	app.view_open(d, .Playlist, "uuid-1", "Name", "", 3)
	defer app.view_close(d)
	rows := rows_of({5, 6, 7})
	rows[1].title = ""
	rows[2].added_by = "someone"
	app.view_add_rows(&d.view, 0, 3, rows, 3)
	d.view.version = {updated = 1700000000123, count = 3}
	d.view.fetched = 1760000000

	file := app.list_encode(&d.view, context.temp_allocator)
	data, _ := mem.alloc_bytes_non_zeroed(len(file), 16, context.temp_allocator)
	copy(data, file)
	h, back, err := app.list_decode(data, .Playlist, "uuid-1", context.temp_allocator)
	testing.expect_value(t, err, app.File_Error.None)
	testing.expect_value(t, h.version, d.view.version)
	testing.expect_value(t, h.fetched, i64(1760000000))
	testing.expect_value(t, h.hint, i64(3))
	testing.expect_value(t, len(back), 3)
	for r, i in back {
		want := rows[i]
		testing.expect(t, slice.equal(r.artists, want.artists), "the artists differ")
		got_text := [7]string{r.title, r.artist, r.album, r.added, r.added_by, r.duration, r.cover}
		want_text := [7]string{want.title, want.artist, want.album, want.added, want.added_by, want.duration, want.cover}
		testing.expect_value(t, got_text, want_text)
		testing.expect_value(t, [4]i64{r.id, r.album_id, i64(r.seconds), i64(r.track)}, [4]i64{want.id, want.album_id, i64(want.seconds), i64(want.track)})
		lo := uintptr(raw_data(data))
		if len(r.artist) > 0 {
			p := uintptr(raw_data(r.artist))
			testing.expect(t, p >= lo && p < lo + uintptr(len(data)), "a string doesn't point into the file")
		}
	}

	// Another list's file, or a damaged one, isn't taken.
	_, _, err = app.list_decode(data, .Playlist, "uuid-2", context.temp_allocator)
	testing.expect_value(t, err, app.File_Error.Other)
	_, _, err = app.list_decode(data, .Album, "uuid-1", context.temp_allocator)
	testing.expect_value(t, err, app.File_Error.Other)
	data[len(data) - 1] ~= 1
	_, _, err = app.list_decode(data, .Playlist, "uuid-1", context.temp_allocator)
	testing.expect_value(t, err, app.File_Error.Damaged)

	// An artist whose name runs past the row's artist string isn't taken,
	// even with the sum right.
	long := rows_of({5})
	long[0].artists = slice.clone([]app.Artist_Ref{{id = 42, start = 0, end = i32(len(long[0].artist) + 1)}}, context.temp_allocator)
	app.view_close(d)
	app.view_open(d, .Playlist, "uuid-1", "Name", "", 1)
	app.view_add_rows(&d.view, 0, 1, long, 1)
	file = app.list_encode(&d.view, context.temp_allocator)
	data, _ = mem.alloc_bytes_non_zeroed(len(file), 16, context.temp_allocator)
	copy(data, file)
	_, _, err = app.list_decode(data, .Playlist, "uuid-1", context.temp_allocator)
	testing.expect_value(t, err, app.File_Error.Damaged)
	_, _, err = app.list_decode(data[:len(data) - 1], .Playlist, "uuid-1", context.temp_allocator)
	testing.expect_value(t, err, app.File_Error.Short)

	sb := app.Sidebar {
		items        = []app.Sidebar_Item{{id = "a", name = "Polskie hity", image = "img", tracks = 85, updated = 99}, {id = "b", name = "", tracks = 0}},
		liked_count  = 1433,
		liked_newest = 77,
	}
	sfile := app.sidebar_encode(&sb, 5, context.temp_allocator)
	sdata, _ := mem.alloc_bytes_non_zeroed(len(sfile), 16, context.temp_allocator)
	copy(sdata, sfile)
	sh, items, serr := app.sidebar_decode(sdata, context.temp_allocator)
	testing.expect_value(t, serr, app.File_Error.None)
	testing.expect_value(t, sh.version, app.List_Version{count = 1433, newest = 77})
	testing.expect(t, slice.equal(items, sb.items))
}

// A file of another format, or a damaged one, is deleted when it's read,
// and the list loads from TIDAL.
@(test)
list_file_of_another_format_is_deleted :: proc(t: ^testing.T) {
	dir := cache_dir("format")
	defer delete(dir, runtime.heap_allocator())
	defer os.remove_all(dir)
	s := cache_state(dir)
	defer cache_state_free(s)
	d := &s.data

	app.view_open(d, .Album, "12", "Album", "", 3)
	serve(s, rows_of({1, 2, 3}))
	testing.expect(t, d.view.fetched != 0)
	testing.expect_value(t, run_disk(s), 1)
	path := app.disk_path(fmt.tprintf("%s/7", dir), .Album, "12", context.temp_allocator)
	testing.expect(t, os.exists(path))

	for damage in ([2]int{4, -1}) {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		if damage >= 0 {
			data[damage] += 1 // the format
		} else {
			data[len(data) - 1] ~= 0xff
		}
		testing.expect(t, os.write_entire_file(path, data) == nil)
		app.view_close(d)
		app.lists_clear(d)
		app.list_open(d, .Album, "12", "Album", "", 3)
		testing.expect(t, d.view.reading)
		testing.expect_value(t, track_jobs(s), 0)
		run_disk(s)
		testing.expect(t, !d.view.reading)
		testing.expect(t, !os.exists(path))
		testing.expect(t, serve(s, rows_of({1, 2, 3})) > 0)
		testing.expect_value(t, run_disk(s), 1)
		testing.expect(t, os.exists(path))
	}
}

// Past the budget, the files opened longest ago go. The sidebar and files
// opened since stay.
@(test)
disk_cache_evicts_the_oldest :: proc(t: ^testing.T) {
	dir := cache_dir("evict")
	defer delete(dir, runtime.heap_allocator())
	defer os.remove_all(dir)
	blob := make([]u8, 1000, context.temp_allocator)
	base := time.now()
	for i in 0 ..< 5 {
		path := fmt.tprintf("%s/album-%d.tfl", dir, i)
		testing.expect(t, os.write_entire_file(path, blob) == nil)
		at := time.time_add(base, time.Duration(i - 10) * time.Hour)
		testing.expect(t, os.change_times(path, at, at) == nil)
	}
	old := time.time_add(base, -100 * time.Hour)
	sidebar := fmt.tprintf("%s/sidebar.tfl", dir)
	testing.expect(t, os.write_entire_file(sidebar, blob[:100]) == nil)
	testing.expect(t, os.change_times(sidebar, old, old) == nil)
	tmp := fmt.tprintf("%s/album-9.tfl.tmp-1", dir)
	testing.expect(t, os.write_entire_file(tmp, blob) == nil)
	testing.expect(t, os.change_times(tmp, old, old) == nil)

	testing.expect_value(t, app.disk_evict(dir, 10_000, ".tfl"), 1) // the temp file only
	testing.expect_value(t, app.disk_evict(dir, 2500, ".tfl"), 3)
	for i in 0 ..< 5 {
		testing.expectf(t, os.exists(fmt.tprintf("%s/album-%d.tfl", dir, i)) == (i >= 3), "album-%d", i)
	}
	testing.expect(t, os.exists(sidebar))
	testing.expect(t, !os.exists(tmp))
}

@(test)
list_stale_rules :: proc(t: ^testing.T) {
	NOW :: 1_760_000_000
	DAY :: 86400
	v := app.List_Version{updated = 5, count = 10}
	Case :: struct {
		source:  app.Source,
		version: app.List_Version,
		age:     i64,
		current: Maybe(app.List_Version),
		stale:   bool,
	}
	cases := []Case {
		{.Playlist, v, 100 * DAY, v, false}, // unchanged, however old
		{.Playlist, v, 0, app.List_Version{updated = 6, count = 10}, true},
		{.Playlist, v, 0, app.List_Version{updated = 5, count = 11}, true},
		{.Playlist, v, DAY - 1, nil, false}, // not in the sidebar: by age
		{.Playlist, v, DAY + 1, nil, true},
		{.Liked, {count = 3, newest = 9}, 0, app.List_Version{count = 3, newest = 9}, false},
		{.Liked, {count = 3, newest = 9}, 0, app.List_Version{count = 4, newest = 9}, true},
		{.Liked, {count = 3, newest = 9}, 0, app.List_Version{count = 3, newest = 8}, true},
		{.Liked, {count = 3, newest = 9}, 0, app.List_Version{}, true}, // emptied
		{.Liked, {count = 3, newest = 9}, 0, nil, false},
		{.Liked, {count = 3, newest = 9}, 3 * DAY + 1, app.List_Version{count = 3, newest = 9}, true},
		{.Album, {}, 29 * DAY, nil, false},
		{.Album, {}, 31 * DAY, nil, true},
		{.Artist, {}, DAY - 1, nil, false},
		{.Artist, {}, DAY + 1, nil, true},
		{.Search, {}, 299, nil, false},
		{.Search, {}, 301, nil, true},
		{.Album, {}, -120, nil, true}, // the clock went back
	}
	for c in cases {
		got := app.list_stale(c.source, c.version, NOW - c.age, c.current, NOW)
		testing.expectf(t, got == c.stale, "%v at %v, %d s old, now %v: stale %v", c.source, c.version, c.age, c.current, got)
	}
	testing.expect(t, app.list_stale(.Album, {}, 0, nil, NOW), "a list never fetched is stale")
}

// Going back to a list that hasn't changed shows it without a request.
// Once the sidebar says it changed, it's fetched again in the background
// while the old rows stay.
@(test)
unchanged_list_opens_without_requests :: proc(t: ^testing.T) {
	s := cache_state()
	defer cache_state_free(s)
	d := &s.data
	sidebar(s, updated = 1, count = 3)
	testing.expect_value(t, d.view.source, app.Source.Liked)
	serve(s, rows_of(LIKED_IDS))
	app.select_playlist(s, 2)
	testing.expect(t, serve(s, rows_of({1, 2, 3})) > 0)
	testing.expect_value(t, d.view.version, app.List_Version{updated = 1, count = 3})

	app.select_playlist(s, 0)
	testing.expect_value(t, track_jobs(s), 0)
	testing.expect(t, slice.equal(view_ids(&d.view), LIKED_IDS))
	app.select_playlist(s, 2)
	testing.expect_value(t, track_jobs(s), 0)
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{1, 2, 3}))
	testing.expect(t, d.view.done)
	testing.expect_value(t, d.lists.count, 1)

	// Changed on TIDAL while it's open.
	sidebar(s, updated = 2, count = 4)
	testing.expect_value(t, d.refresh.source, app.Source.Playlist)
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{1, 2, 3}))
	serve(s, rows_of({1, 2, 3, 4}))
	testing.expect_value(t, d.refresh.source, app.Source.None)
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{1, 2, 3, 4}))
	testing.expect_value(t, d.view.version, app.List_Version{updated = 2, count = 4})

	// Liked Songs changed while closed: it shows, and is fetched again.
	sidebar(s, updated = 2, count = 4, liked = 4, newest = 950)
	app.select_playlist(s, 0)
	testing.expect(t, slice.equal(view_ids(&d.view), LIKED_IDS))
	testing.expect(t, track_jobs(s) > 0)
	testing.expect_value(t, d.refresh.source, app.Source.Liked)
}

// The memory cache stays under its byte budget, the least recently used
// lists going first.
@(test)
memory_cache_keeps_to_its_budget :: proc(t: ^testing.T) {
	s := cache_state()
	defer cache_state_free(s)
	d := &s.data
	big := strings.repeat("x", 4000, context.temp_allocator)
	for n in 0 ..< 30 {
		rows := rows_of(ids_from(i64(n) * 1000, i64(n) * 1000 + 300))
		for &r in rows {
			r.album = big
		}
		app.view_open(d, .Album, fmt.tprint(n), "Album", "", len(rows))
		serve(s, rows)
		if n == 3 {
			// Used again, so it outlives older lists.
			app.list_open(d, .Album, "0", "Album", "", 300)
			testing.expect_value(t, track_jobs(s), 0)
		}
	}
	app.view_close(d)
	l := &d.lists
	testing.expect(t, l.bytes <= app.LIST_MEMORY_BUDGET)
	testing.expectf(t, l.count > 4 && l.count < 30, "%d lists kept", l.count)
	testing.expect(t, app.lru_find(d, .Album, "29") >= 0)
	testing.expect(t, app.lru_find(d, .Album, "1") < 0)
	sum := 0
	for e in l.entries[:l.count] {
		sum += e.bytes
	}
	testing.expect_value(t, sum, l.bytes)
}

// A background refresh lands on the open list: the selection, the track
// menu and the first row in view follow their tracks, not their indices,
// and the play queue goes on as it was.
@(test)
refresh_finds_rows_by_track_id :: proc(t: ^testing.T) {
	s := cache_state()
	defer cache_state_free(s)
	s.playback.player = audio.create(no_wake, 0, null_output = true)
	defer app.playback_shutdown(s)
	d := &s.data
	lib := &s.library
	sidebar(s, updated = 1, count = 100)
	serve(s, rows_of(LIKED_IDS))
	app.select_playlist(s, 2)
	serve(s, rows_of(ids_from(100, 200)))
	testing.expect(t, d.view.fetched != 0)

	app.playback_play_row(s, 50)
	app.playback_update(s, nil)
	testing.expect_value(t, lib.playing, 50)
	lib.selected = 50
	lib.top_row, lib.top_offset = 40, 10
	lib.menu_row, lib.menu_track, lib.menu_list = 60, 160, app.list_gen(s)
	queue := slice.clone(s.playback.entries, context.temp_allocator)

	// Five new tracks at the top, and 120 gone.
	sidebar(s, updated = 2, count = 104)
	ids := make([dynamic]i64, context.temp_allocator)
	append(&ids, 1, 2, 3, 4, 5)
	for id in 100 ..< 200 {
		if id != 120 {
			append(&ids, i64(id))
		}
	}
	serve(s, rows_of(ids[:]))
	testing.expect_value(t, d.refresh.source, app.Source.None)
	testing.expect(t, slice.equal(view_ids(&d.view), ids[:]))
	testing.expect_value(t, lib.selected, 54)
	testing.expect_value(t, lib.anchor_row, 44)
	testing.expect_value(t, lib.anchor_offset, f32(10))
	testing.expect_value(t, lib.menu_row, 64)
	testing.expect_value(t, app.track_menu_row(s), 64)

	app.playback_update(s, nil)
	testing.expect_value(t, lib.playing, 54)
	testing.expect_value(t, s.playback.index, 50)
	testing.expect(t, slice.equal(s.playback.entries, queue), "the play queue changed")
}

// The app's own edits go into the kept copies and their files, with the
// version TIDAL gave, so nothing is fetched again for them.
@(test)
own_edits_write_through :: proc(t: ^testing.T) {
	dir := cache_dir("edits")
	defer delete(dir, runtime.heap_allocator())
	defer os.remove_all(dir)
	s := cache_state(dir)
	defer cache_state_free(s)
	d := &s.data
	sidebar(s, updated = 1, count = 3)
	run_disk(s) // no file yet
	serve(s, rows_of(LIKED_IDS))
	app.select_playlist(s, 2)
	run_disk(s)
	serve(s, rows_of({1, 2, 3}))
	run_disk(s)
	s.library.selected = 2 // track 3

	added := rows_of({77})[0]
	app.list_edited(s, .Playlist, "pl", true, added, {updated = 2, count = 4})
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{1, 2, 3, 77}))
	testing.expect_value(t, d.view.version, app.List_Version{updated = 2, count = 4})
	testing.expect_value(t, d.sidebar.items[1].tracks, 4)
	testing.expect_value(t, d.sidebar.items[1].updated, i64(2))
	app.list_edited(s, .Playlist, "pl", false, {id = 1}, {updated = 3, count = 3})
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{2, 3, 77}))
	testing.expect_value(t, s.library.selected, 1)
	run_disk(s)

	// Liked Songs, closed and in memory: a like goes on top.
	app.list_edited(s, .Liked, "", true, rows_of({999})[0], {count = 4, newest = 999})
	testing.expect_value(t, d.sidebar.liked_count, 4)
	run_disk(s)

	// Next launch: from disk, at the edited versions, nothing fetched.
	sidebar_now := d.sidebar.items[1]
	app.view_close(d)
	app.lists_clear(d)
	app.sidebar_free(d)
	d.sidebar = {}
	app.lists_signed_in(d, 7)
	run_disk(s) // the sidebar, which opens Liked Songs from disk
	testing.expect(t, !d.sidebar.fresh)
	testing.expect_value(t, d.sidebar.items[1], sidebar_now)
	testing.expect_value(t, d.view.source, app.Source.Liked)
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{999, 900, 901, 902}))
	sidebar(s, updated = 3, count = 3, liked = 4, newest = 999)
	testing.expect_value(t, d.refresh.source, app.Source.None)
	app.select_playlist(s, 2)
	run_disk(s)
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{2, 3, 77}))
	testing.expect_value(t, track_jobs(s), 0)
	testing.expect_value(t, d.refresh.source, app.Source.None)

	// A list only on disk loses its file, so it's fetched when it opens.
	app.list_edited(s, .Album, "5", true, added, {})
	job, ok := jobs.try_pop(&d.lists.queue)
	for ok && job.op != .Delete {
		job, ok = jobs.try_pop(&d.lists.queue)
	}
	testing.expect(t, ok && job.op == .Delete && app.small_str(&job.id) == "5")
}

// add_job takes the Add_Track the app queued.
@(private = "file")
add_job :: proc(s: ^app.State) -> (job: app.Job, ok: bool) {
	for {
		job = jobs.try_pop(&s.data.queue) or_return
		if job.kind == .Add_Track {
			return job, true
		}
	}
}

// Dropping a row on a playlist adds it on TIDAL, and the kept copies take
// it at the version TIDAL answers, so the list isn't fetched again. Before
// this, the drop only said it was added and the playlist's cache went
// stale.
@(test)
adding_a_track_updates_the_cache :: proc(t: ^testing.T) {
	dir := cache_dir("add")
	defer delete(dir, runtime.heap_allocator())
	defer os.remove_all(dir)
	s := cache_state(dir)
	defer cache_state_free(s)
	d := &s.data
	lib := &s.library
	sidebar(s, updated = 1, count = 3)
	run_disk(s)
	serve(s, rows_of(LIKED_IDS))
	app.select_playlist(s, 2)
	run_disk(s)
	serve(s, rows_of({1, 2, 3}))
	run_disk(s)
	app.select_playlist(s, 0) // the playlist goes to memory
	run_disk(s)
	track_jobs(s)

	// Track 900 onto the playlist.
	app.add_to_list(s, 0, 2)
	testing.expect_value(t, app.status_text(s), "Adding Song 900 夜に駆ける to A playlist…")
	job, ok := add_job(s)
	testing.expect(t, ok && job.source == .Playlist && app.small_str(&job.id) == "pl" && job.key == 900)
	res := app.Result {
		job     = job,
		added   = true,
		rows    = rows_of({900}),
		version = {updated = 2, count = 4},
	}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, app.status_text(s), "Added Song 900 夜に駆ける to A playlist")
	testing.expect_value(t, d.sidebar.items[1].tracks, 4)
	testing.expect_value(t, d.sidebar.items[1].updated, i64(2))
	run_disk(s)

	// It opens with the track at the end and asks TIDAL for nothing.
	app.select_playlist(s, 2)
	run_disk(s)
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{1, 2, 3, 900}))
	testing.expect_value(t, d.view.version, app.List_Version{updated = 2, count = 4})
	testing.expect_value(t, track_jobs(s), 0)
	testing.expect_value(t, d.refresh.source, app.Source.None)

	// TIDAL already had it: nothing changes.
	app.add_to_list(s, 3, 2)
	job, _ = add_job(s)
	res = {job = job, added = false}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, app.status_text(s), "Song 900 夜に駆ける is already in A playlist")
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{1, 2, 3, 900}))

	// A like goes on top of Liked Songs. Liking it again adds nothing,
	// which only the count tells.
	app.add_to_list(s, 0, 0)
	job, _ = add_job(s)
	testing.expect_value(t, job.source, app.Source.Liked)
	res = {job = job, added = true, rows = rows_of({1}), version = {count = 4, newest = 1}}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, app.status_text(s), "Added Song 1 夜に駆ける to Liked Songs")
	testing.expect_value(t, d.sidebar.liked_count, 4)
	app.add_to_list(s, 0, 0)
	job, _ = add_job(s)
	res = {job = job, added = true, rows = rows_of({1}), version = {count = 4, newest = 1}}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, app.status_text(s), "Song 1 夜に駆ける is already in Liked Songs")
	app.select_playlist(s, 0)
	run_disk(s)
	testing.expect(t, slice.equal(view_ids(&d.view), []i64{1, 900, 901, 902}))
	testing.expect_value(t, track_jobs(s), 0)

	// A failed add changes nothing and says so.
	app.add_to_list(s, 1, 2)
	job, _ = add_job(s)
	res = {job = job, err = tidal.Error_Kind.Http}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, app.status_text(s), "Couldn't add Song 900 夜に駆ける to A playlist")
	testing.expect_value(t, d.sidebar.items[1].tracks, 4)

	// Added, but without the row TIDAL lists now: the open list is fetched
	// again and its file goes.
	app.select_playlist(s, 2)
	run_disk(s)
	app.add_to_list(s, 0, 2)
	job, _ = add_job(s)
	res = {job = job, added = true}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, d.refresh.source, app.Source.Playlist)
	testing.expect(t, track_jobs(s) > 0)
	deleted := false
	for disk in jobs.try_pop(&d.lists.queue) {
		id := disk.id
		deleted ||= disk.op == .Delete && app.small_str(&id) == "pl"
	}
	testing.expect(t, deleted, "the playlist's file is deleted")
}

// Signing out deletes the user's cache folder and what's in memory.
@(test)
sign_out_deletes_the_cache :: proc(t: ^testing.T) {
	dir := cache_dir("signout")
	defer delete(dir, runtime.heap_allocator())
	defer os.remove_all(dir)
	s := cache_state(dir)
	defer cache_state_free(s)
	d := &s.data
	app.session_open(d)
	sidebar(s, updated = 1, count = 3)
	run_disk(s)
	serve(s, rows_of(LIKED_IDS))
	run_disk(s)
	user_dir := fmt.tprintf("%s/7", dir)
	testing.expect(t, os.exists(fmt.tprintf("%s/liked.tfl", user_dir)))
	app.select_playlist(s, 1)
	testing.expect_value(t, d.lists.count, 1)

	// A write queued before the sign-out doesn't bring the folder back.
	app.sidebar_save(d)
	job, _ := jobs.try_pop(&d.lists.queue)
	// sign_out without the Keychain.
	app.account_end(s)
	app.lists_forget(d)
	testing.expect(t, !os.exists(user_dir))
	testing.expect_value(t, d.lists.count, 0)
	res, _ := app.disk_run(d, job)
	app.result_free(&res)
	testing.expect(t, !os.exists(user_dir))
}

// The sidebar is fetched again when the window becomes key once it's old,
// and not while the window just stays key.
@(test)
sidebar_refreshes_when_the_window_becomes_key :: proc(t: ^testing.T) {
	s := cache_state()
	defer cache_state_free(s)
	d := &s.data
	sidebar(s, updated = 1, count = 3)
	playlists :: proc(s: ^app.State) -> int {
		return jobs.remove_if(&s.data.queue, proc(job: ^app.Job, _: rawptr) -> bool {return job.kind == .Playlists}, nil)
	}
	app.lists_window_key(s, true)
	testing.expect_value(t, playlists(s), 0) // just fetched
	d.sidebar.fetched = time.tick_add(time.tick_now(), -app.SIDEBAR_MAX_AGE - time.Second)
	app.lists_window_key(s, true)
	testing.expect_value(t, playlists(s), 0) // still key
	app.lists_window_key(s, false)
	app.lists_window_key(s, true)
	testing.expect_value(t, playlists(s), 1)
	testing.expect(t, d.sidebar.loading)
}

// "Added ... to <playlist>" names the sidebar entry by its place, which a
// refreshed sidebar may not have. It used to index past the new sidebar.
@(test)
added_status_goes_with_the_old_sidebar :: proc(t: ^testing.T) {
	s := cache_state()
	defer cache_state_free(s)
	sidebar(s, updated = 1, count = 3)
	serve(s, rows_of(LIKED_IDS))
	app.set_status(s, .Added, 0, 2)
	testing.expect_value(t, app.status_text(s), "Added Song 900 夜に駆ける to A playlist")
	res := app.Result {
		job       = {kind = .Playlists},
		playlists = []app.Sidebar_Item{{id = "other", name = "Other", tracks = 2, updated = 1}},
	}
	app.handle_result(s, &res, 0)
	testing.expect_value(t, app.status_text(s), "")
}

// Covers go to disk under the user's folder, come back from it, and go
// with it at sign-out. A download that finishes after the sign-out isn't
// written.
@(test)
covers_on_disk :: proc(t: ^testing.T) {
	dir := cache_dir("covers")
	defer delete(dir, runtime.heap_allocator())
	defer os.remove_all(dir)
	s := cache_state(dir)
	defer cache_state_free(s)
	d := &s.data
	app.session_open(d)

	cdir, path := app.cover_file(d, "0f1e2d3c-0000-4000-8000-000000000001", 80)
	testing.expect_value(t, path, fmt.tprintf("%s/7/covers/0f1e2d3c-0000-4000-8000-000000000001-80.jpg", dir))
	_, odd := app.cover_file(d, "../x", 80)
	testing.expect_value(t, odd, "")
	_, cached := app.cover_read(path)
	testing.expect(t, !cached)
	jpeg := []u8{0xff, 0xd8, 0xff, 0xe0, 1, 2, 3}
	app.cover_write(d, cdir, path, jpeg)
	back, ok := app.cover_read(path)
	defer delete(back, runtime.heap_allocator())
	testing.expect(t, ok && slice.equal(back, jpeg))

	app.account_end(s)
	app.lists_forget(d)
	testing.expect(t, !os.exists(cdir))
	app.cover_write(d, cdir, path, jpeg) // from before the sign-out
	testing.expect(t, !os.exists(cdir))
	_, none := app.cover_file(d, "0f1e2d3c-0000-4000-8000-000000000001", 80)
	testing.expect_value(t, none, "")
}

// An empty Liked Songs or a sidebar without playlists is a header and its
// id only. Encoding them used to index past the buffer.
@(test)
empty_lists_go_to_disk :: proc(t: ^testing.T) {
	d := new(app.Data)
	defer free(d)
	app.view_open(d, .Liked, "", "Liked Songs", "", 0)
	defer app.view_close(d)
	d.view.fetched = 1760000000
	file := app.list_encode(&d.view, context.temp_allocator)
	data, _ := mem.alloc_bytes_non_zeroed(len(file), 16, context.temp_allocator)
	copy(data, file)
	h, rows, err := app.list_decode(data, .Liked, "", context.temp_allocator)
	testing.expect_value(t, err, app.File_Error.None)
	testing.expect_value(t, len(rows), 0)
	testing.expect_value(t, h.fetched, i64(1760000000))

	sb := app.Sidebar{}
	sfile := app.sidebar_encode(&sb, 5, context.temp_allocator)
	sdata, _ := mem.alloc_bytes_non_zeroed(len(sfile), 16, context.temp_allocator)
	copy(sdata, sfile)
	_, items, serr := app.sidebar_decode(sdata, context.temp_allocator)
	testing.expect_value(t, serr, app.File_Error.None)
	testing.expect_value(t, len(items), 0)
}

// A sidebar from disk whose fetch from TIDAL failed at launch is fetched
// again when the window becomes key or a sidebar entry opens.
@(test)
sidebar_from_disk_is_fetched_again_after_a_failure :: proc(t: ^testing.T) {
	dir := cache_dir("sidebar-retry")
	defer delete(dir, runtime.heap_allocator())
	defer os.remove_all(dir)
	playlists :: proc(s: ^app.State) -> int {
		return jobs.remove_if(&s.data.queue, proc(job: ^app.Job, _: rawptr) -> bool {return job.kind == .Playlists}, nil)
	}
	{
		s := cache_state(dir)
		defer cache_state_free(s)
		sidebar(s, updated = 1, count = 3)
		run_disk(s)
	}
	s := cache_state(dir)
	defer cache_state_free(s)
	d := &s.data
	app.lists_signed_in(d, 7)
	app.request_playlists(d)
	testing.expect_value(t, playlists(s), 1)
	run_disk(s)
	testing.expect(t, d.sidebar.loaded && !d.sidebar.fresh)
	failed := app.Result {
		job = {kind = .Playlists},
		err = .Network,
	}
	app.handle_result(s, &failed, 0)
	testing.expect(t, !d.sidebar.loading)

	app.lists_window_key(s, true)
	testing.expect_value(t, playlists(s), 1)
	d.sidebar.loading = false
	app.select_playlist(s, 2)
	testing.expect_value(t, playlists(s), 1)
}

// Liked Songs emptied on TIDAL is at count 0 and no newest track, which
// used to read as not knowing, so the old rows stayed for three days.
@(test)
emptied_liked_songs_are_fetched_again :: proc(t: ^testing.T) {
	s := cache_state()
	defer cache_state_free(s)
	d := &s.data
	sidebar(s, updated = 1, count = 3)
	serve(s, rows_of(LIKED_IDS))
	app.select_playlist(s, 2)
	serve(s, rows_of({1, 2, 3}))
	sidebar(s, updated = 1, count = 3, liked = 0, newest = 0)
	app.select_playlist(s, 0)
	testing.expect_value(t, d.refresh.source, app.Source.Liked)
	serve(s, nil)
	testing.expect_value(t, d.view.count, 0)
}

// Search results past their five minutes aren't fetched again in the
// background: that brought back the songs without the albums, artists and
// playlists.
@(test)
old_search_results_are_not_refreshed :: proc(t: ^testing.T) {
	s := cache_state()
	defer cache_state_free(s)
	d := &s.data
	sidebar(s, updated = 1, count = 3)
	serve(s, rows_of(LIKED_IDS))
	res := app.Result {
		job   = {kind = .Search, view = s.search.gen, id = app.small("abc")},
		rows  = rows_of({1, 2}),
		found = {albums = []app.Found{{id = 5, name = "An album"}}},
	}
	app.search_result(s, &res)
	testing.expect_value(t, d.view.source, app.Source.Search)
	testing.expect(t, d.view.fetched != 0)
	d.view.fetched -= app.SEARCH_MAX_AGE + 1
	sidebar(s, updated = 2, count = 3)
	testing.expect_value(t, d.refresh.source, app.Source.None)
	testing.expect_value(t, len(d.view.found.albums), 1)
}
