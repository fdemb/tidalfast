package tidal_tests

import "core:fmt"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/audio"
import "../src/jobs"
import "../src/platform"
import "../src/ui"

// The track menu's library actions: the heart, Add to playlist and its
// chooser, and Remove from this playlist.

// menu_sidebar gives s a sidebar of the user's own playlist "pl" (Mine),
// someone else's (Theirs), and extra more of the user's own, in
// context.allocator, which must outlive the frames.
@(private = "file")
menu_sidebar :: proc(s: ^app.State, tracks := 3, extra := 0) {
	items := make([]app.Sidebar_Item, 2 + extra)
	items[0] = {id = "pl", name = "Mine", tracks = tracks, updated = 1, own = true}
	items[1] = {id = "theirs", name = "Theirs", tracks = 2, updated = 1}
	for k in 0 ..< extra {
		items[2 + k] = {id = fmt.aprintf("x%d", k), name = fmt.aprintf("Mix %d", k), tracks = 1, own = true}
	}
	res := app.Result {
		job     = {auth = s.data.auth_gen, payload = app.Playlists_Job{}},
		payload = app.Sidebar_Result{playlists = items, liked_count = 3},
	}
	app.handle_result(s, &res, 0)
	drain(s)
}

// drain drops the queued jobs.
@(private = "file")
drain :: proc(s: ^app.State) {
	for job in jobs.try_pop(&s.data.queue) {
		job := job
		app.job_free(&job)
	}
}

// menu_list opens three songs as a list of kind source with id, all there.
@(private = "file")
menu_list :: proc(s: ^app.State, source: app.Source, id: string) {
	rows := make([]app.Row, 3, context.temp_allocator)
	titles := [3]string{"First song", "Second song", "Third song"}
	some := []app.Artist_Ref{{id = 20, start = 0, end = len("Some Artist")}}
	for &r, i in rows {
		r = {title = titles[i], artist = "Some Artist", album = "Some Album", duration = "3:00", id = i64(100 + i), album_id = 10, artists = some, seconds = 180}
	}
	app.view_open(&s.data, source, id, "A list", "", len(rows))
	app.view_add_rows(&s.data.view, 0, len(rows), rows, len(rows))
	drain(s)
	s.data.view.in_flight = 0
	s.data.view.fetched = 1
	s.library.list_gen += 1
}

// menu_labels is the open menu's items in the last frame, in order.
@(private = "file")
menu_labels :: proc(s: ^app.State) -> []string {
	out := make([dynamic]string)
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Menu_Item {
			append(&out, strings.clone(string(n.label)))
		}
	}
	return out[:]
}

// menu_press presses the menu item labelled label.
@(private = "file")
menu_press :: proc(s: ^app.State, label: string) -> platform.Event {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Menu_Item && string(n.label) == label {
			return {kind = .Access_Press, target = n.id}
		}
	}
	panic(label)
}

@(private = "file")
open_menu_on :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, title: string, loc := #caller_location) {
	library_frame(t, s, f, loc = loc)
	down, up := right_click(s, title)
	library_frame(t, s, f, down, up, loc = loc)
	library_frame(t, s, f, loc = loc)
	testing.expect(t, ui.menu_is_open("track_menu"), "the menu opens", loc = loc)
}

@(private = "file")
close_menu :: proc(t: ^testing.T, s: ^app.State, f: ^Frame) {
	library_frame(t, s, f, key(.Escape))
	for _ in 0 ..< 30 {
		library_frame(t, s, f)
	}
}

@(private = "file")
has :: proc(labels: []string, label: string) -> bool {
	return slice.contains(labels, label)
}

// queued_jobs takes the queued jobs of type T, in context.allocator, since
// a frame frees the temp allocator.
@(private = "file")
queued_jobs :: proc(s: ^app.State, $T: typeid) -> []T {
	out := make([dynamic]T)
	for job in jobs.try_pop(&s.data.queue) {
		job := job
		if p, ok := job.payload.(T); ok {
			append(&out, p)
		}
		app.job_free(&job)
	}
	return out[:]
}

// The menu offers the heart and Add to playlist on any TIDAL track, and
// Remove from this playlist only on the user's own playlists, grouped
// after Play and before Go to.
@(test)
track_menu_items_per_list :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	menu_sidebar(s)
	f: Frame

	menu_list(s, .Playlist, "pl")
	open_menu_on(t, s, &f, "Second song")
	labels := menu_labels(s)
	want := []string{"Play", "Play next", "Add to queue", "Save to Liked Songs", "Add to playlist", "Remove from this playlist", "Go to album", "Go to artist", "Copy song link"}
	testing.expectf(t, slice.equal(labels, want), "own playlist: %v", labels)
	close_menu(t, s, &f)

	cases := []struct {
		source: app.Source,
		id:     string,
	}{{.Playlist, "theirs"}, {.Album, "10"}, {.Search, ""}, {.Liked, ""}}
	for c in cases {
		menu_list(s, c.source, c.id)
		open_menu_on(t, s, &f, "Second song")
		labels = menu_labels(s)
		testing.expectf(t, has(labels, "Save to Liked Songs") && has(labels, "Add to playlist"), "%v: %v", c.source, labels)
		testing.expectf(t, !has(labels, "Remove from this playlist"), "%v offers Remove: %v", c.source, labels)
		close_menu(t, s, &f)
	}

	// No playlist of the user's own: nothing to add to.
	menu_list(s, .Album, "10")
	s.data.sidebar.items[0].own = false
	open_menu_on(t, s, &f, "Second song")
	testing.expect(t, !has(menu_labels(s), "Add to playlist"))
}

// Save to Liked Songs and Remove from Liked Songs go the heart's way: the
// set changes at once and the same Add_Track job goes out, so the row's
// heart shows it in the next frame.
@(test)
like_from_the_track_menu :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	menu_sidebar(s)
	menu_list(s, .Album, "10")
	f: Frame

	open_menu_on(t, s, &f, "First song")
	library_frame(t, s, &f, menu_press(s, "Save to Liked Songs"))
	testing.expect(t, app.liked_has(&s.data, 100))
	from_menu := queued_jobs(s, app.Add_Track_Job)
	library_frame(t, s, &f)
	_, hearted := access_node(s, "Unlike First song")
	testing.expect(t, hearted, "the row's heart is on")
	for _ in 0 ..< 30 {
		library_frame(t, s, &f)
	}
	testing.expect(t, !ui.menu_is_open("track_menu"))

	// The heart on the second row sends the same job. It shows on the
	// selected row.
	down, up := left_click(s, "Second song")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Like Second song"))
	from_heart := queued_jobs(s, app.Add_Track_Job)
	if testing.expect_value(t, len(from_menu), 1) && testing.expect_value(t, len(from_heart), 1) {
		testing.expect_value(t, from_menu[0], app.Add_Track_Job{track = 100, source = .Liked})
		testing.expect_value(t, from_heart[0], app.Add_Track_Job{track = 101, source = .Liked})
	}

	open_menu_on(t, s, &f, "First song")
	testing.expect(t, has(menu_labels(s), "Remove from Liked Songs"))
	library_frame(t, s, &f, menu_press(s, "Remove from Liked Songs"))
	testing.expect(t, !app.liked_has(&s.data, 100))
	// One change per track is out at a time: the unlike waits for the
	// like's answer, as a second click on the heart does.
	testing.expect_value(t, len(queued_jobs(s, app.Add_Track_Job)), 0)
	res := app.Result{job = {auth = s.data.auth_gen, payload = from_menu[0]}}
	app.handle_result(s, &res, 0)
	unlike := queued_jobs(s, app.Add_Track_Job)
	testing.expect(t, len(unlike) == 1 && unlike[0] == app.Add_Track_Job{track = 100, source = .Liked, remove = true})
}

// Add to playlist turns the menu into the user's own playlists with Back
// on top, and a playlist there adds the row as a drop on it does.
@(test)
add_to_playlist_from_the_track_menu :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	menu_sidebar(s, extra = 2)
	menu_list(s, .Album, "10")
	f: Frame

	open_menu_on(t, s, &f, "First song")
	library_frame(t, s, &f, menu_press(s, "Add to playlist"))
	library_frame(t, s, &f)
	testing.expect(t, ui.menu_is_open("track_menu"), "the menu stays open")
	labels := menu_labels(s)
	testing.expectf(t, slice.equal(labels, []string{"Back", "Mine", "Mix 0", "Mix 1"}), "the chooser: %v", labels)
	// A press from the keyboard or an assistive app lands on Back.
	back := menu_press(s, "Back")
	testing.expect_value(t, s.ui.focus, ui.Key(back.target))

	library_frame(t, s, &f, back)
	library_frame(t, s, &f)
	testing.expect(t, has(menu_labels(s), "Add to playlist"), "Back shows the actions again")
	testing.expect_value(t, len(queued_jobs(s, app.Add_Track_Job)), 0)

	// Down from Back to the first playlist, then Enter.
	library_frame(t, s, &f, menu_press(s, "Add to playlist"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, key(.Down))
	library_frame(t, s, &f, key(.Return))
	testing.expect_value(t, app.status_text(s), "Adding First song to Mine…")
	from_menu := queued_jobs(s, app.Add_Track_Job)
	for _ in 0 ..< 30 {
		library_frame(t, s, &f)
	}
	testing.expect(t, !ui.menu_is_open("track_menu"))

	// The same job as a drop of the row on Mine.
	app.add_to_list(s, 0, 1)
	from_drop := queued_jobs(s, app.Add_Track_Job)
	if testing.expect_value(t, len(from_menu), 1) && testing.expect_value(t, len(from_drop), 1) {
		testing.expect_value(t, from_menu[0], from_drop[0])
		testing.expect_value(t, from_menu[0].source, app.Source.Playlist)
		testing.expect_value(t, from_menu[0].track, 100)
	}
	testing.expect(t, !app.playlist_editable(s, 2), "someone else's playlist takes no drop")
}

// A hundred playlists scroll inside the menu, twelve at a time, and the
// menu stays in the window.
@(test)
playlist_chooser_stays_in_the_window :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	menu_sidebar(s, extra = 100)
	menu_list(s, .Album, "10")
	f := Frame{size = {820, 700}}

	open_menu_on(t, s, &f, "First song")
	down, up := left_click(s, "Add to playlist")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	menu := ui.box_lookup(&s.ui, ui.key_from_string(0, "track_menu"))
	view := ui.box_lookup(&s.ui, ui.key_from_string(menu.key, "track_menu_playlists"))
	if testing.expect(t, view != nil) {
		testing.expectf(t, view.rect.h == 12 * ui.MENU_ITEM_H, "twelve show: %v", view.rect)
	}
	testing.expectf(t, menu.rect.y >= 8 && menu.rect.y + menu.rect.h <= 700 - 8, "the menu at %v", menu.rect)

	// A window too short for twelve, with the menu opened near its bottom.
	close_menu(t, s, &f)
	f.size = {820, 400}
	library_frame(t, s, &f)
	app.open_track_menu(s, 0, {300, 380})
	library_frame(t, s, &f)
	down, up = left_click(s, "Add to playlist")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	menu = ui.box_lookup(&s.ui, ui.key_from_string(0, "track_menu"))
	testing.expectf(t, menu.rect.y >= 8 && menu.rect.y + menu.rect.h <= 400 - 8, "the menu at %v", menu.rect)
	labels := menu_labels(s)
	testing.expectf(t, len(labels) < 102 && labels[0] == "Back" && labels[1] == "Mine", "the chooser shows its top: %v", labels)
	testing.expect_value(t, s.ui.focus, 0) // the mouse lights nothing

	// Up lights the last one, and the list scrolls to it.
	library_frame(t, s, &f, key(.Up))
	for _ in 0 ..< 60 {
		library_frame(t, s, &f)
	}
	last := node_box(s, "Mix 99")
	view = ui.box_lookup(&s.ui, ui.key_from_string(menu.key, "track_menu_playlists"))
	if view != nil {
		testing.expectf(t, last.rect.y >= view.rect.y && last.rect.y + last.rect.h <= view.rect.y + view.rect.h + 0.5, "Mix 99 at %v in %v", last.rect, view.rect)
	}
	// The scrollbar fades out, then nothing asks for frames.
	for _ in 0 ..< 200 {
		library_frame(t, s, &f)
	}
	testing.expect(t, !f.animating, "it settles")
}

// mock_menu_state signs in against m with the sidebar of menu_sidebar,
// and opens the playlist "pl" whole from the mock.
@(private = "file")
mock_menu_state :: proc(m: ^Mock) -> ^app.State {
	s := library_state(false, m)
	drain(s)
	menu_sidebar(s, tracks = len(m.items))
	app.select_playlist(s, 1)
	for run_queued(s, app.Tracks_Job) > 0 {}
	return s
}

// requested says whether m had a request starting with line.
@(private = "file")
requested :: proc(m: ^Mock, line: string) -> bool {
	for r in m.requests {
		if strings.has_prefix(r, line) {
			return true
		}
	}
	return false
}

@(private = "file")
view_track_ids :: proc(s: ^app.State) -> []i64 {
	v := &s.data.view
	ids := make([]i64, v.count, context.temp_allocator)
	for i in 0 ..< v.count {
		ids[i] = v.rows[i].id if v.loaded[i] else -1
	}
	return ids
}

// Remove from this playlist takes the row off on TIDAL, then out of the
// list and the sidebar's count without fetching the list again. A removal
// that fails leaves both and says so.
@(test)
remove_from_playlist :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	m: Mock
	mock_start(&m, {{"track", 11}, {"track", 22}, {"track", 33}, {"track", 44}})
	defer mock_stop(&m)
	s := mock_menu_state(&m)
	defer library_state_free(s)
	d := &s.data
	testing.expect(t, slice.equal(view_track_ids(s), []i64{11, 22, 33, 44}))
	f: Frame

	open_menu_on(t, s, &f, "t22")
	library_frame(t, s, &f, menu_press(s, "Remove from this playlist"))
	testing.expect_value(t, app.status_text(s), "Removing t22 from Mine…")
	testing.expect_value(t, run_queued(s, app.Remove_Track_Job), 1)
	testing.expect(t, slice.equal(mock_item_ids(&m, context.temp_allocator), []i64{11, 33, 44}))
	testing.expect(t, slice.equal(view_track_ids(s), []i64{11, 33, 44}))
	testing.expect_value(t, d.sidebar.items[0].tracks, 3)
	testing.expect_value(t, d.view.version.count, 3)
	testing.expect_value(t, d.refresh.source, app.Source.None)
	testing.expect_value(t, app.status_text(s), "Removed t22 from Mine")
	library_frame(t, s, &f)
	_, gone := access_node(s, "t22")
	testing.expect(t, !gone, "the row is gone")
	_, sidebar := access_node(s, "Mine, 3 songs")
	testing.expect(t, sidebar, "the sidebar counts 3 songs")
	for _ in 0 ..< 30 {
		library_frame(t, s, &f)
	}

	// TIDAL refuses: the list stays and the toast says so.
	m.answers["/playlists/pl/items/1"] = {status = 500, body = `{"status":500}`}
	open_menu_on(t, s, &f, "t33")
	library_frame(t, s, &f, menu_press(s, "Remove from this playlist"))
	run_queued(s, app.Remove_Track_Job)
	testing.expect(t, slice.equal(view_track_ids(s), []i64{11, 33, 44}))
	testing.expect_value(t, d.sidebar.items[0].tracks, 3)
	testing.expect_value(t, d.refresh.source, app.Source.None)
	library_frame(t, s, &f)
	_, toast := access_node(s, "Couldn't remove t33 from Mine")
	testing.expect(t, toast, "the toast says it failed")
	delete_key(&m.answers, "/playlists/pl/items/1")

	// The list changed on TIDAL since it was fetched: nothing is removed,
	// and the list is fetched again.
	mock_set_items(&m, {{"track", 11}, {"track", 44}, {"track", 33}})
	for _ in 0 ..< 30 {
		library_frame(t, s, &f)
	}
	open_menu_on(t, s, &f, "t33")
	library_frame(t, s, &f, menu_press(s, "Remove from this playlist"))
	run_queued(s, app.Remove_Track_Job)
	testing.expect(t, slice.equal(mock_item_ids(&m, context.temp_allocator), []i64{11, 44, 33}))
	testing.expect_value(t, app.status_text(s), "Couldn't remove t33 from Mine")
	testing.expect_value(t, d.refresh.source, app.Source.Playlist)
}

// With a song TIDAL leaves out before the row, the row's index on TIDAL
// is one past its row, and that's the index removed. In a page with a
// gap, which song is missing isn't known, so the worker asks.
@(test)
remove_past_a_gap :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	items := make([]Mock_Item, 60)
	for &it, k in items {
		it = {"track", i64(1000 + k)}
	}
	items[10].kind = "gone"
	m: Mock
	mock_start(&m, items)
	defer mock_stop(&m)
	s := mock_menu_state(&m)
	defer library_state_free(s)
	d := &s.data
	testing.expect_value(t, d.view.count, 59)

	// Row 55 is track 1056, item 56 on TIDAL.
	lo, hi, ok := app.remove_place(s, 55)
	testing.expect(t, ok && lo == 56 && hi == 56)
	app.remove_from_list(s, 55)
	run_queued(s, app.Remove_Track_Job)
	testing.expect(t, requested(&m, "DELETE /playlists/pl/items/56?"), "item 56 is removed")
	ids := mock_item_ids(&m, context.temp_allocator)
	testing.expect(t, len(ids) == 59 && !slice.contains(ids, 1056))
	testing.expect_value(t, d.view.count, 58)
	testing.expect(t, !slice.contains(view_track_ids(s), 1056))

	// Row 20, track 1021, is in the page with the gap: item 20 or 21.
	lo, hi, ok = app.remove_place(s, 20)
	testing.expect(t, ok && lo == 20 && hi == 21)
	app.remove_from_list(s, 20)
	run_queued(s, app.Remove_Track_Job)
	testing.expect(t, requested(&m, "DELETE /playlists/pl/items/21?"), "item 21 is removed")
	testing.expect(t, !slice.contains(mock_item_ids(&m, context.temp_allocator), 1021))

	// The gaps moved with the rows: the last row is still found.
	last := d.view.count - 1
	lo, hi, ok = app.remove_place(s, last)
	testing.expect(t, ok && lo == last + 1 && hi == last + 1)
}

// Removing a row of the list the queue plays from keeps the queue in
// step: the playing song plays on and the one after it comes next.
@(test)
remove_from_the_queues_list :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	m: Mock
	mock_start(&m, {{"track", 11}, {"track", 22}, {"track", 33}, {"track", 44}, {"track", 55}})
	defer mock_stop(&m)
	s := mock_menu_state(&m)
	defer library_state_free(s)
	s.playback.player = audio.create(proc "c" () {}, 0, null_output = true)
	pb := &s.playback

	app.playback_play_row(s, 1) // 22
	drain(s)
	app.remove_from_list(s, 2) // 33, next after it
	run_queued(s, app.Remove_Track_Job)
	app.playback_update(s, nil)
	testing.expect_value(t, pb.entries[pb.index].id, 22)
	app.playback_next(s)
	testing.expect_value(t, pb.entries[pb.index].id, 44)
	drain(s)

	// The playing song itself: the queue keeps its copy, so the song stays
	// current and the one after it comes next. Before this, the song after
	// took its place and the next skipped it.
	app.remove_from_list(s, 2) // 44, playing
	run_queued(s, app.Remove_Track_Job)
	testing.expect(t, slice.equal(view_track_ids(s), []i64{11, 22, 55}))
	app.playback_update(s, nil)
	testing.expect_value(t, pb.entries[pb.index].id, 44)
	app.playback_next(s)
	testing.expect_value(t, pb.entries[pb.index].id, 55)
	drain(s)
	app.playback_shutdown(s)
}
