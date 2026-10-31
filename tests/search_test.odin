package tidal_tests

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import app "../src/app"
import "../src/audio"
import "../src/cover"
import "../src/jobs"
import "../src/tidal"
import "../src/ui"

@(private = "file")
search_jobs :: proc(s: ^app.State) -> int {
	return jobs.remove_if(&s.data.queue, proc(job: ^app.Job, _: rawptr) -> bool {
		_, search := job.payload.(app.Search_Job)
		return search
	}, nil)
}

// two_artists is a song's two artists, the first with a comma in its name.
@(private = "file")
two_artists :: proc() -> (string, []app.Artist_Ref) {
	return app.join_artists([]tidal.Artist{{id = 40, name = "Tyler, The Creator"}, {id = 41, name = "Kali Uchis"}}, nil, context.allocator)
}

@(private = "file")
open_test_list :: proc(s: ^app.State) {
	rows := make([]app.Row, 3, context.temp_allocator)
	titles := [3]string{"First song", "Second song", "Third song"}
	some := []app.Artist_Ref{{id = 20, start = 0, end = len("Some Artist")}}
	for &r, i in rows {
		r = {title = titles[i], artist = "Some Artist", album = "Some Album", duration = "3:00", id = i64(100 + i), album_id = 10, artists = some, seconds = 180}
	}
	rows[1].artist, rows[1].artists = two_artists()
	app.view_open(&s.data, .Playlist, "uuid", "A playlist", "", len(rows))
	app.view_add_rows(&s.data.view, 0, len(rows), rows, len(rows))
}

// Go to album and Go to artist from the track menu close the list the menu
// and the table were built from. That has to wait until the frame is done
// with its strings.
@(test)
go_to_album_waits_for_the_frame :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	open_test_list(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)

	down, up := right_click(s, "Second song")
	library_frame(t, s, &f, down, up)
	testing.expect(t, ui.menu_is_open("track_menu"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Go to album"))
	testing.expect_value(t, s.data.view.source, app.Source.Album)
	testing.expect_value(t, app.small_str(&s.data.view.id), "10")
	testing.expect_value(t, app.small_str(&s.data.view.name), "Some Album")
	testing.expect(t, s.search.browsing)
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Some Album")

	open_test_list(s)
	library_frame(t, s, &f)
	down, up = right_click(s, "Third song")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Go to artist"))
	testing.expect_value(t, s.data.view.source, app.Source.Artist)
	testing.expect_value(t, app.small_str(&s.data.view.id), "20")
}

// A row's artists and album are links, each artist its own, and so are
// the title and the artists in the player bar and an album's artists in
// the search results. The track menu offers each of a song's artists.
@(test)
artist_and_album_links :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(false)
	defer library_state_free(s)
	open_test_list(s)
	f := Frame{fonts = &fonts}
	library_frame(t, s, &f)
	library_frame(t, s, &f)

	down, up := left_click(s, "Some Artist")
	library_frame(t, s, &f, down, up)
	testing.expect_value(t, s.data.view.source, app.Source.Artist)
	testing.expect_value(t, app.small_str(&s.data.view.id), "20")

	for name, k in ([]string{"Tyler, The Creator", "Kali Uchis"}) {
		open_test_list(s)
		library_frame(t, s, &f)
		library_frame(t, s, &f)
		down, up = left_click(s, name)
		library_frame(t, s, &f, down, up)
		testing.expect_value(t, s.data.view.source, app.Source.Artist)
		testing.expect_value(t, app.small_str(&s.data.view.id), fmt.tprint(40 + k))
		testing.expect_value(t, app.small_str(&s.data.view.name), name)
	}

	open_test_list(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	down, up = right_click(s, "Second song")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	_, single := access_node(s, "Go to artist")
	testing.expect(t, !single)
	library_frame(t, s, &f, press(s, "Go to Kali Uchis"))
	testing.expect_value(t, app.small_str(&s.data.view.id), "41")

	open_test_list(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	down, up = left_click(s, "Some Album")
	library_frame(t, s, &f, down, up)
	testing.expect_value(t, s.data.view.source, app.Source.Album)
	testing.expect_value(t, app.small_str(&s.data.view.id), "10")

	items := []app.Queue_Item{{title = "Playing song", album_id = 11}}
	items[0].artist, items[0].artists = two_artists()
	s.playback.items = items
	s.playback.index = 0
	defer s.playback.items = nil
	library_frame(t, s, &f)
	down, up = left_click(s, "Playing song")
	library_frame(t, s, &f, down, up)
	testing.expect_value(t, s.data.view.source, app.Source.Album)
	testing.expect_value(t, app.small_str(&s.data.view.id), "11")
	library_frame(t, s, &f)
	down, up = left_click(s, "Kali Uchis")
	library_frame(t, s, &f, down, up)
	testing.expect_value(t, s.data.view.source, app.Source.Artist)
	testing.expect_value(t, app.small_str(&s.data.view.id), "41")

	// An album in the search results links to its artists.
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
	sr := &s.search
	albums := []app.Found{{id = 5, name = "An album", subtitle = "Album · Tyler, The Creator, Kali Uchis"}}
	albums[0].artist, albums[0].artists = two_artists()
	res := app.Result {
		job     = {payload = app.Search_Job{gen = sr.gen, query = app.small("abc")}},
		payload = app.Search_Result{rows = []app.Row{{title = "Found song", artist = "Someone", id = 1}}, found = {albums = albums}},
	}
	app.handle_result(s, &res, 0)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Albums"))
	library_frame(t, s, &f)
	down, up = left_click(s, "Tyler, The Creator")
	library_frame(t, s, &f, down, up)
	testing.expect_value(t, s.data.view.source, app.Source.Artist)
	testing.expect_value(t, app.small_str(&s.data.view.id), "40")
}

// A song with more artists than fit lists them up to the edge of its
// column: the one that crosses it is cut, and the rest are left out. This
// holds from the row's first frame.
@(test)
artist_links_stop_at_the_edge :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(false)
	defer library_state_free(s)
	artists := make([]tidal.Artist, 12)
	for &a, i in artists {
		a = {id = i64(500 + i), name = fmt.aprintf("Artist number %d", i)}
	}
	rows := make([]app.Row, 1)
	rows[0] = {title = "Crowded song", album = "Some Album", id = 1, album_id = 10}
	rows[0].artist, rows[0].artists = app.join_artists(artists, nil, context.allocator)
	app.view_open(&s.data, .Playlist, "uuid", "A playlist", "", 1)
	app.view_add_rows(&s.data.view, 0, 1, rows, 1)
	f := Frame{fonts = &fonts}
	for frame in 1 ..= 3 {
		library_frame(t, s, &f)
		first, ok := access_node(s, "Artist number 0")
		testing.expectf(t, ok, "frame %d: the first artist", frame)
		_, last := access_node(s, "Artist number 11")
		testing.expectf(t, !last, "frame %d: not the last artist", frame)
		title, _ := access_node(s, "Crowded song")
		right := title.frame[0] + title.frame[2]
		shown := 0
		nodes, _ := ui.access_tree(&s.ui)
		for n in nodes {
			if strings.has_prefix(string(n.label), "Artist number") {
				shown += 1
				testing.expectf(t, n.frame[0] + n.frame[2] <= right + 0.5, "frame %d: %s ends at %v, past %v", frame, n.label, n.frame[0] + n.frame[2], right)
			}
		}
		testing.expectf(t, shown > 1 && shown < 12, "frame %d: %d artists shown", frame, shown)
		testing.expect(t, first.frame[2] > 0)
	}
}

// A search the full queue held gives way to the next query, which goes out
// once there's room.
@(test)
held_search_gives_way_to_the_next_query :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	for jobs.push(&s.data.queue, app.Job{payload = app.Cover_Job{}}, app.PRIORITY_COVER) {}
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
	library_frame(t, s, &f, type_text(&f, "d"))
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
	testing.expect_value(t, search_jobs(s), 0)

	for _ in 0 ..< 4 {
		jobs.try_pop(&s.data.queue)
	}
	app.data_retry(&s.data)
	queries := make([dynamic]string, context.temp_allocator)
	for {
		job := jobs.try_pop(&s.data.queue) or_break
		if p, search := job.payload.(app.Search_Job); search {
			testing.expect_value(t, p.gen, s.search.gen)
			append(&queries, strings.clone(app.small_str(&p.query), context.temp_allocator))
		}
	}
	testing.expect_value(t, len(queries), 1)
	if len(queries) == 1 {
		testing.expect_value(t, queries[0], "abcd")
	}
}

// Picking a sidebar entry while a search waits for its debounce, or while
// its request is out, ends the search: its result mustn't bring the
// results back over the playlist.
@(test)
sidebar_pick_ends_the_search :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	sr := &s.search
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	testing.expect(t, sr.due > 0)

	// Still debouncing.
	library_frame(t, s, &f, press(s, "Liked Songs"))
	testing.expect_value(t, sr.due, 0.0)
	library_frame(t, s, &f, dt = 1)
	testing.expect(t, !sr.loading)
	testing.expect_value(t, search_jobs(s), 0)
	testing.expect_value(t, s.data.view.source, app.Source.Liked)

	// The request is out: the search page searches again for the text
	// left in the field.
	open_search(t, s, &f)
	testing.expect(t, sr.loading)
	sent := sr.gen
	library_frame(t, s, &f, press(s, "Liked Songs"))
	testing.expect(t, !sr.loading)
	testing.expect(t, sr.gen != sent)
	testing.expect_value(t, search_jobs(s), 0)
	res := app.Result {
		job     = {payload = app.Search_Job{gen = sent, query = app.small("abc")}},
		payload = app.Search_Result{rows = []app.Row{{title = "Late", id = 1}}},
	}
	app.handle_result(s, &res, 0)
	testing.expect(t, !app.search_showing(s))
	testing.expect_value(t, s.data.view.source, app.Source.Liked)
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Liked Songs")
}

// The fake search lists the albums and artists of the songs it found, not
// only those whose own names match.
@(test)
fake_search_lists_albums_and_artists :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	sr := &s.search
	f: Frame
	library_frame(t, s, &f)
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "Jóga"))
	library_frame(t, s, &f, dt = 1)
	testing.expect(t, app.search_showing(s))
	testing.expect(t, sr.fake_count > 0)
	testing.expectf(t, sr.fake_counts[0] > 0 && sr.fake_counts[1] > 0, "%d albums, %d artists", sr.fake_counts[0], sr.fake_counts[1])
	for kind in 0 ..< 2 {
		for at in sr.fake_found[kind][:sr.fake_counts[kind]] {
			testing.expectf(t, strings.contains(s.rows[at].title, "Jóga"), "row %d isn't a match", at)
		}
	}

	// Go to album from the menu lists the fake rows of that album.
	down, up := right_click(s, "Jóga")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	album := app.view_row(s, s.library.menu_row).album
	library_frame(t, s, &f, press(s, "Go to album"))
	testing.expect_value(t, sr.fake_source, app.Source.Album)
	testing.expect_value(t, app.view_title(s), album)
	for i in 0 ..< app.view_count(s) {
		testing.expect_value(t, app.view_row(s, i).album, album)
	}
}

// The fake library with "Jóga" searched for and the field focused.
@(private = "file")
searched_state :: proc(t: ^testing.T, f: ^Frame) -> ^app.State {
	s := library_state(true)
	library_frame(t, s, f)
	open_search(t, s, f)
	library_frame(t, s, f, type_text(f, "Jóga"))
	library_frame(t, s, f, dt = 1)
	assert(app.small_str(&s.search.query) == "Jóga")
	return s
}

// Shortcuts the app and the UI handle outside the field take effect at
// their place among the frame's events, with everything in one frame.
@(test)
field_shortcuts_keep_their_order :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	f: Frame
	s := searched_state(t, &f)
	defer library_state_free(s)
	sr := &s.search
	field := &sr.field

	// Cmd-F selects what's there, so typing after it replaces it.
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}), text_at(&f, 0, "Kino"))
	testing.expect_value(t, ui.field_text(field), "Kino")
	testing.expect_value(t, field.anchor, field.cursor)
	// And Cmd-L from another focus, here the next box after a Tab.
	library_frame(t, s, &f, key(.Tab))
	testing.expect(t, !ui.has_focus(node_box(s, app.SEARCH_PLACEHOLDER)))
	library_frame(t, s, &f, key(.L, {ui.PRIMARY}), text_at(&f, 0, "Jóga"))
	testing.expect_value(t, ui.field_text(field), "Jóga")
	testing.expect(t, ui.has_focus(node_box(s, app.SEARCH_PLACEHOLDER)))
	library_frame(t, s, &f, dt = 1)

	// Return searches for the text it was pressed on. The X after it
	// starts the debounce over.
	library_frame(t, s, &f, key(.Return), text_at(&f, 0, "X"))
	testing.expect_value(t, ui.field_text(field), "JógaX")
	testing.expect_value(t, app.small_str(&sr.query), "Jóga")
	testing.expect(t, sr.due > 0)
	library_frame(t, s, &f, dt = 1)
	testing.expect_value(t, app.small_str(&sr.query), "JógaX")

	// Typing, then Return, searches at once for all of it.
	library_frame(t, s, &f, text_at(&f, 0, "Y"), key(.Return))
	testing.expect_value(t, app.small_str(&sr.query), "JógaXY")
	testing.expect_value(t, sr.due, 0.0)

	// Escape clears the field before the text after it.
	library_frame(t, s, &f, key(.Escape), text_at(&f, 0, "Kino"))
	testing.expect_value(t, ui.field_text(field), "Kino")
	testing.expect(t, sr.due > 0)
	// Cmd-A, then typing.
	library_frame(t, s, &f, key(.A, {ui.PRIMARY}), text_at(&f, 0, "Jóga"))
	testing.expect_value(t, ui.field_text(field), "Jóga")

	// Text typed before a Tab goes in, though the field lost the focus.
	library_frame(t, s, &f, text_at(&f, 0, "!"), key(.Tab))
	testing.expect_value(t, ui.field_text(field), "Jóga!")
	testing.expect(t, !ui.has_focus(node_box(s, app.SEARCH_PLACEHOLDER)))

	// Once Escape in an empty field gives up the focus, text after it goes
	// nowhere, until Cmd-F gives the focus back.
	open_search(t, s, &f)
	library_frame(t, s, &f, key(.Escape), key(.Escape), text_at(&f, 0, "a"))
	testing.expect_value(t, ui.field_text(field), "")
	testing.expect(t, !ui.has_focus(node_box(s, app.SEARCH_PLACEHOLDER)))
	open_search(t, s, &f)
	library_frame(t, s, &f, text_at(&f, 0, "b"), key(.Escape), key(.Escape), key(.F, {ui.PRIMARY}), text_at(&f, 1, "c"))
	testing.expect_value(t, ui.field_text(field), "c")
	testing.expect(t, ui.has_focus(node_box(s, app.SEARCH_PLACEHOLDER)))
}

// The track menu belongs to the list and the track it opened on. When a
// search result replaces the list, the menu closes, and a click on it in
// the same frame does nothing, rather than act on the row with the same
// index in the new list.
@(test)
track_menu_closes_with_its_list :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	open_test_list(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	down, up := right_click(s, "Second song")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	testing.expect(t, ui.menu_is_open("track_menu"))

	// The same ids, other albums: only the list tells them apart.
	rows := make([]app.Row, 3, context.temp_allocator)
	for &r, i in rows {
		r = {title = "Found song", artist = "Other Artist", album = "Other Album", id = i64(100 + i), album_id = 22}
	}
	res := app.Result {
		job     = {payload = app.Search_Job{gen = s.search.gen, query = app.small("found")}},
		payload = app.Search_Result{rows = rows},
	}
	app.handle_result(s, &res, 0)
	library_frame(t, s, &f, press(s, "Go to album"))
	testing.expect(t, !ui.menu_is_open("track_menu"))
	testing.expect_value(t, s.data.view.source, app.Source.Search)
	library_frame(t, s, &f)
	testing.expect_value(t, s.data.view.source, app.Source.Search)

	// The fake data's lists, which aren't Track_Views.
	fs := library_state(true)
	defer library_state_free(fs)
	library_frame(t, fs, &f)
	open_search(t, fs, &f)
	library_frame(t, fs, &f, type_text(&f, "Jóga"))
	library_frame(t, fs, &f, dt = 1)
	// A new search waits for its debounce while the menu opens on the old
	// results. It ends in the frame of the click, and the search replaces
	// the list before the menu is built.
	library_frame(t, fs, &f, key(.A, {ui.PRIMARY}), text_at(&f, 0, "Kino"))
	down, up = right_click(fs, "Jóga")
	library_frame(t, fs, &f, down, up)
	library_frame(t, fs, &f)
	testing.expect(t, ui.menu_is_open("track_menu"))
	library_frame(t, fs, &f, press(fs, "Go to album"), dt = 1)
	testing.expect_value(t, app.small_str(&fs.search.query), "Kino")
	testing.expect_value(t, fs.search.fake_source, app.Source.Search)
	testing.expect(t, !ui.menu_is_open("track_menu"))
}

// Search results stay in memory for a few minutes: going back to the search
// page after opening another list searches for the same words again and
// shows them without asking TIDAL, tabs included. Older ones are asked for
// again.
@(test)
search_results_come_back_from_memory :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	s.data.lists.memory = true
	sr := &s.search
	f: Frame
	library_frame(t, s, &f)
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
	testing.expect_value(t, search_jobs(s), 1)
	albums := []app.Found{{id = 5, name = "An album", subtitle = "Album · Someone"}}
	res := app.Result {
		job     = {payload = app.Search_Job{gen = sr.gen, query = app.small("abc")}},
		payload = app.Search_Result{rows = []app.Row{{title = "Found song", artist = "Someone", id = 1}, {title = "Other song", artist = "Someone", id = 2}}, found = {albums = albums}},
	}
	app.handle_result(s, &res, 0)
	testing.expect(t, s.data.view.done)
	library_frame(t, s, &f)

	library_frame(t, s, &f, press(s, "Liked Songs"))
	testing.expect_value(t, s.data.view.source, app.Source.Liked)
	open_search(t, s, &f)
	testing.expect_value(t, search_jobs(s), 0)
	testing.expect(t, app.search_showing(s))
	testing.expect_value(t, app.view_count(s), 2)
	testing.expect_value(t, len(sr.found.albums), 1)
	library_frame(t, s, &f)
	_, ok := access_node(s, "Found song")
	testing.expect(t, ok)

	// Five minutes on, it's asked for again.
	library_frame(t, s, &f, press(s, "Liked Songs"))
	i := app.lru_find(&s.data, .Search, "abc")
	testing.expect(t, i >= 0)
	s.data.lists.entries[i].view.fetched -= app.SEARCH_MAX_AGE + 1
	open_search(t, s, &f)
	testing.expect_value(t, search_jobs(s), 1)
	testing.expect(t, app.lru_find(&s.data, .Search, "abc") < 0)
}

// go_to_first_album opens the album of the open list's first row from its
// track menu, and returns the album's name.
@(private = "file")
go_to_first_album :: proc(t: ^testing.T, s: ^app.State, f: ^Frame) -> string {
	row := app.view_row(s, 0)
	down, up := right_click(s, row.title)
	library_frame(t, s, f, down, up)
	library_frame(t, s, f)
	album := app.view_row(s, s.library.menu_row).album
	library_frame(t, s, f, press(s, "Go to album"))
	library_frame(t, s, f)
	return album
}

// Back and Forward go through the places visited, from the playlist the
// app started on. Going somewhere new drops the places Forward would have
// gone to.
@(test)
back_and_forward_go_through_the_places_visited :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, !enabled(s, "Back"))
	testing.expect(t, !enabled(s, "Forward"))
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Liked Songs")

	library_frame(t, s, &f, press(s, "Daily Mix 1,"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Daily Mix 1")
	album := go_to_first_album(t, s, &f)
	testing.expect_value(t, app.view_title(s), album)
	testing.expect(t, enabled(s, "Back"))
	testing.expect(t, !enabled(s, "Forward"))

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Daily Mix 1")
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Liked Songs")
	testing.expect_value(t, s.search.fake_source, app.Source.None)
	testing.expect(t, !enabled(s, "Back"))
	testing.expect(t, enabled(s, "Forward"))

	library_frame(t, s, &f, press(s, "Forward"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Daily Mix 1")
	testing.expect(t, enabled(s, "Forward"))

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f, press(s, "Release Radar,"))
	library_frame(t, s, &f)
	testing.expect(t, !enabled(s, "Forward"))
	library_frame(t, s, &f, press(s, "Forward"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Release Radar")
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Liked Songs")
}

// The history keeps the last HISTORY_MAX places and forgets older ones.
@(test)
history_forgets_the_oldest_places :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	visits := app.HISTORY_MAX + 10
	for i in 1 ..= visits {
		library_frame(t, s, &f, press(s, fmt.tprintf("%s,", app.PLAYLISTS[i % 3 + 1])))
	}
	library_frame(t, s, &f)
	for _ in 1 ..< app.HISTORY_MAX {
		testing.expect(t, enabled(s, "Back"))
		library_frame(t, s, &f, press(s, "Back"))
		library_frame(t, s, &f)
	}
	testing.expect(t, !enabled(s, "Back"))
	oldest := visits - app.HISTORY_MAX + 1
	testing.expect_value(t, app.view_title(s), app.PLAYLISTS[oldest % 3 + 1])
}

// A search typed a letter at a time is one place in the history, for the
// query as it ended. Back to it puts the query back in the field.
@(test)
back_returns_to_the_last_search :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	sr := &s.search
	f: Frame
	library_frame(t, s, &f)
	open_search(t, s, &f)
	for letter in ([]string{"J", "ó", "g", "a"}) {
		library_frame(t, s, &f, type_text(&f, letter))
		library_frame(t, s, &f, dt = 1)
	}
	testing.expect_value(t, app.small_str(&sr.query), "Jóga")
	album := go_to_first_album(t, s, &f)
	testing.expect_value(t, app.view_title(s), album)

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect(t, app.search_showing(s))
	testing.expect_value(t, app.view_title(s), "Results for “Jóga”")
	testing.expect_value(t, ui.field_text(&sr.field), "Jóga")
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Liked Songs")
	testing.expect(t, !enabled(s, "Back"))

	// Emptying the field leaves the search page empty in place of the
	// results, with the playlist open under it.
	library_frame(t, s, &f, press(s, "Forward"))
	open_search(t, s, &f)
	library_frame(t, s, &f, key(.Escape))
	library_frame(t, s, &f)
	testing.expect(t, !app.search_showing(s))
	testing.expect(t, app.search_page_showing(s))
	_, empty := access_node(s, "Search TIDAL")
	testing.expect(t, empty, "the empty search page")
	testing.expect(t, !enabled(s, "Forward"))
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect(t, !app.search_page_showing(s))
	testing.expect_value(t, app.view_title(s), "Liked Songs")
}

// With TIDAL's data a place is an album's or artist's id, opened again
// from TIDAL when Back or Forward comes to it.
@(test)
back_and_forward_reopen_tidal_lists :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	open_test_list(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	down, up := right_click(s, "Second song")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Go to album"))
	testing.expect_value(t, s.data.view.source, app.Source.Album)

	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Back"))
	testing.expect_value(t, s.data.view.source, app.Source.Liked)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Forward"))
	testing.expect_value(t, s.data.view.source, app.Source.Album)
	testing.expect_value(t, app.small_str(&s.data.view.id), "10")
	testing.expect_value(t, app.small_str(&s.data.view.name), "Some Album")
	library_frame(t, s, &f)
}


// Back to a sidebar playlist opens the same playlist after the sidebar
// changed order, and Liked Songs when the playlist is gone.
@(test)
back_finds_playlists_by_id :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	alpha := app.Sidebar_Item{id = "alpha-id", name = "Alpha", tracks = 1}
	beta := app.Sidebar_Item{id = "beta-id", name = "Beta", tracks = 2}
	s.data.sidebar.items = []app.Sidebar_Item{alpha, beta}
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Alpha,"))
	library_frame(t, s, &f, press(s, "Beta,"))
	testing.expect_value(t, app.small_str(&s.data.view.id), "beta-id")

	s.data.sidebar.items[0], s.data.sidebar.items[1] = beta, alpha
	library_frame(t, s, &f, press(s, "Back"))
	testing.expect_value(t, app.small_str(&s.data.view.id), "alpha-id")
	testing.expect_value(t, s.library.playlist, 2)

	library_frame(t, s, &f, press(s, "Beta,"))
	library_frame(t, s, &f, press(s, "Back"))
	testing.expect_value(t, app.small_str(&s.data.view.id), "alpha-id")

	s.data.sidebar.items = s.data.sidebar.items[1:]
	library_frame(t, s, &f, press(s, "Forward"))
	testing.expect_value(t, s.data.view.source, app.Source.Liked)
}

@(test)
small_cuts_at_a_character :: proc(t: ^testing.T) {
	cases := []struct {
		pad:  int,
		tail: string,
		want: int,
	} {
		{118, "żółw", 118},
		{117, "日本の歌", 117},
		{116, "🎵🎶", 116},
		{115, "🎵🎶", 119},
	}
	for c in cases {
		name := strings.concatenate({strings.repeat("a", c.pad, context.temp_allocator), c.tail}, context.temp_allocator)
		cut := app.small(name)
		got := app.small_str(&cut)
		testing.expect(t, utf8.valid_string(got))
		testing.expect(t, strings.has_prefix(name, got))
		testing.expect_value(t, len(got), c.want)
	}
}

// Signing out forgets the places visited and the search, so the next
// account's Back doesn't go to this one's lists.
@(test)
sign_out_forgets_history_and_search :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	sr := &s.search
	open_test_list(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	go_to_first_album(t, s, &f)
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, key(.Return))
	res := app.Result {
		job     = {payload = app.Search_Job{gen = sr.gen, query = app.small("abc")}},
		payload = app.Search_Result{rows = []app.Row{{title = "Found song", artist = "Someone", id = 1}}, found = {albums = []app.Found{{id = 5, name = "An album"}}}},
	}
	app.handle_result(s, &res, 0)
	library_frame(t, s, &f)
	testing.expect(t, enabled(s, "Back"))

	app.account_end(s)
	sign_in(s)
	library_frame(t, s, &f)
	testing.expect(t, !enabled(s, "Back"))
	testing.expect(t, !enabled(s, "Forward"))
	testing.expect(t, !app.search_showing(s))
	testing.expect_value(t, ui.field_text(&sr.field), "")
	testing.expect_value(t, app.small_str(&sr.query), "")
	testing.expect_value(t, len(sr.found.albums), 0)
}

// Return on an unchanged query while the queue is full, as when TIDAL
// answers 429, keeps one search waiting, and it goes out once there's room.
@(test)
return_on_a_full_queue_holds_one_search :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	d := &s.data
	f: Frame
	library_frame(t, s, &f)
	for jobs.push(&d.queue, app.Job{payload = app.Cover_Job{}}, app.PRIORITY_COVER) {}
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "abc"))
	for _ in 0 ..< app.HELD_JOBS + 4 {
		library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
		app.data_retry(d)
	}
	testing.expect_value(t, d.held_count, 1)

	jobs.try_pop(&d.queue)
	app.data_retry(d)
	searches := 0
	for {
		job, ok := jobs.try_pop(&d.queue)
		if !ok {
			break
		}
		if p, search := job.payload.(app.Search_Job); search {
			testing.expect_value(t, p.gen, s.search.gen)
			testing.expect_value(t, app.small_str(&p.query), "abc")
			searches += 1
		}
	}
	testing.expect_value(t, searches, 1)
	testing.expect_value(t, d.held_count, 0)
}

// A long sidebar asks only for the covers of the playlists that show.
@(test)
sidebar_wants_only_visible_covers :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	s.renderer.scale = 1
	items := make([]app.Sidebar_Item, 500)
	for &item, i in items {
		item = {id = fmt.aprintf("pl-%d", i), name = fmt.aprintf("Playlist %d", i), image = fmt.aprintf("img-%d", i), tracks = 1}
	}
	s.data.sidebar.items = items
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expectf(t, s.data.covers.used < 30, "%d covers wanted for a window of about 12 rows", s.data.covers.used)
	testing.expect(t, cover.lookup(&s.data.covers, cover.key_of("img-0", app.PLAYLIST_COVER)) != nil, "the first playlist's cover is wanted")
	testing.expect(t, cover.lookup(&s.data.covers, cover.key_of("img-499", app.PLAYLIST_COVER)) == nil, "the last playlist's cover isn't")
}

// A click on a sidebar playlist opens it; a double-click plays it from the
// top as well, and the row then shows it's what plays.
@(test)
double_click_plays_a_playlist :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	s.playback.player = audio.create(proc "c" () {}, 0, null_output = true)
	defer app.playback_shutdown(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	down, up := left_click(s, "Discover Weekly, ")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	testing.expect(t, app.playlist_showing(s, 1), "a click opens the playlist")
	testing.expect_value(t, s.playback.index, -1)
	visited := s.history.count

	down.click_count = 2
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	testing.expect(t, app.playlist_showing(s, 1), "the playlist stays open")
	testing.expect_value(t, s.playback.index, 0)
	testing.expect(t, app.sidebar_queued(s, 1), "the queue came from the playlist")
	testing.expect(t, !app.sidebar_queued(s, 0), "and not from Liked Songs")
	testing.expect_value(t, s.history.count, visited)
}

// A double-clicked playlist whose songs haven't come waits for them, and
// opening another list before they do drops the wait.
@(test)
double_click_waits_for_the_first_song :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	items := make([]app.Sidebar_Item, 3)
	for &item, i in items {
		item = {id = fmt.aprintf("pl-%d", i), name = fmt.aprintf("Playlist %d", i), tracks = 5}
	}
	s.data.sidebar.items = items
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	down, up := left_click(s, "Playlist 1, ")
	library_frame(t, s, &f, down, up)
	down.click_count = 2
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	testing.expect(t, app.playlist_showing(s, 2), "the playlist opens")
	testing.expect_value(t, s.playback.index, -1)
	testing.expect(t, s.library.play_waiting, "it waits for its songs")

	library_frame(t, s, &f, press(s, "Playlist 0, "))
	library_frame(t, s, &f)
	testing.expect(t, !s.library.play_waiting, "another list drops the wait")
	testing.expect_value(t, s.playback.index, -1)
}

// The sidebar's Search row opens the search page with the field focused
// and nothing searched for, and is lit while the page shows. The results
// show under the field, and Back leaves the page for the playlist.
@(test)
search_row_opens_the_search_page :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	s.titlebar_h = 28
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	row, _ := access_node(s, "Search")
	testing.expect(t, .Selected not_in row.flags)
	_, field := access_node(s, app.SEARCH_PLACEHOLDER)
	testing.expect(t, !field, "no field off the search page")

	library_frame(t, s, &f, press(s, "Search"))
	library_frame(t, s, &f)
	testing.expect(t, app.search_page_showing(s))
	testing.expect(t, ui.has_focus(node_box(s, app.SEARCH_PLACEHOLDER)))
	_, empty := access_node(s, "Search TIDAL")
	testing.expect(t, empty, "the empty search page")
	row, _ = access_node(s, "Search")
	testing.expect(t, .Selected in row.flags)
	// The field is in the room at the top, which moves the window, but a
	// press on it goes to the field.
	bar, _ := access_node(s, app.SEARCH_PLACEHOLDER)
	testing.expectf(t, bar.frame[1] + bar.frame[3] <= app.nav_h(s), "the field at %v, under the room at the top", bar.frame)
	mid := [2]f32{bar.frame[0] + bar.frame[2] / 2, bar.frame[1] + bar.frame[3] / 2}
	for r in ui.drag_regions(&s.ui) {
		inside := mid.x >= r.x && mid.x < r.x + r.w && mid.y >= r.y && mid.y < r.y + r.h
		testing.expectf(t, !inside, "the field's middle %v moves the window (%v)", mid, r)
	}
	_, liked := access_node(s, "Liked Songs, ")
	testing.expect(t, liked)
	testing.expect(t, enabled(s, "Back"))

	library_frame(t, s, &f, type_text(&f, "Jóga"))
	library_frame(t, s, &f, dt = 1)
	library_frame(t, s, &f)
	testing.expect(t, app.search_showing(s))
	_, results := access_node(s, "Results for “Jóga”")
	testing.expect(t, results, "the results under the field")
	testing.expect(t, ui.has_focus(node_box(s, app.SEARCH_PLACEHOLDER)))

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect(t, !app.search_page_showing(s))
	testing.expect_value(t, app.view_title(s), "Liked Songs")
	testing.expect(t, !enabled(s, "Back"))
	row, _ = access_node(s, "Search")
	testing.expect(t, .Selected not_in row.flags)
}

// Scrolled down, the search results' title goes under the room at the top
// and the tabs and headings pin there, under Back, Forward and the field.
// The albums found collapse the same way.
@(test)
search_header_collapses_as_the_results_scroll :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	f: Frame
	s := searched_state(t, &f)
	defer library_state_free(s)
	library_frame(t, s, &f)
	scroll_down :: proc(t: ^testing.T, s: ^app.State, f: ^Frame) {
		library_frame(t, s, f, {kind = .Mouse_Move, x = 600, y = 400})
		library_frame(t, s, f, {kind = .Scroll, x = 600, y = 400, dy = -600, precise = true, phase = .Began})
		library_frame(t, s, f)
	}
	title_shown :: proc(s: ^app.State) -> bool {
		nodes, _ := ui.access_tree(&s.ui)
		for n in nodes {
			if n.role == .Static_Text && string(n.label) == "Results for “Jóga”" {
				return true
			}
		}
		return false
	}
	tabs_at :: proc(s: ^app.State) -> f32 {
		n, ok := access_node(s, "Songs  ")
		return n.frame[1] if ok else -1
	}
	testing.expect(t, title_shown(s), "the title at the top")
	top := tabs_at(s)
	testing.expect(t, top > app.nav_h(s) + app.SEARCH_HEADER_H, "the tabs under the title")

	scroll_down(t, s, &f)
	testing.expect(t, !title_shown(s), "the title scrolled away")
	testing.expect_value(t, tabs_at(s), app.nav_h(s) + 4)
	_, field := access_node(s, app.SEARCH_PLACEHOLDER)
	testing.expect(t, field, "the field still over the bar")

	library_frame(t, s, &f, press(s, "Albums"))
	library_frame(t, s, &f)
	testing.expect_value(t, s.search.tab, app.Search_Tab.Albums)
	scroll_down(t, s, &f)
	testing.expect(t, !title_shown(s), "the albums' title scrolled away")
	testing.expect_value(t, tabs_at(s), app.nav_h(s) + 4)
	library_frame(t, s, &f, press(s, "Songs  "))
	library_frame(t, s, &f)
	testing.expect_value(t, s.search.tab, app.Search_Tab.Songs)
}
