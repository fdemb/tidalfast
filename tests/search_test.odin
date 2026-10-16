package tidal_tests

import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/cover"
import "../src/jobs"
import "../src/platform"
import "../src/ui"

// A State for drawing the library screen without a window: no renderer,
// text system or workers. Closed lists' arenas are poisoned, so a string
// the frame still borrows from one reads as POISON bytes. Like the app's,
// it allocates from an arena, given as context.allocator.
@(private = "file")
library_state :: proc(fake: bool) -> ^app.State {
	s := new(app.State)
	ui.init(&s.ui)
	app.library_init(&s.library)
	cover.init(&s.data.covers, 1 << 20)
	s.playback.index = -1
	s.data.poison = true
	s.data.fake = fake
	s.data.account = .Fake if fake else .Signed_In
	if fake {
		s.rows = app.make_rows()
	}
	app.search_init(s)
	return s
}

@(private = "file")
library_state_free :: proc(s: ^app.State) {
	app.search_shutdown(s)
	app.data_shutdown(s)
}

@(private = "file")
Frame :: struct {
	now:   f64,
	bytes: [256]u8,
}

// library_frame builds and lays out one frame of the library screen with
// events, then does what the frame asked for, as the app does after
// drawing. It fails the test if the accessibility tree, which end_frame
// copies from the boxes' strings, holds a poisoned byte.
@(private = "file")
library_frame :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, events: ..platform.Event, dt := 0.016, loc := #caller_location) {
	f.now += dt
	free_all(context.temp_allocator)
	ui.begin_frame(&s.ui, events, nil, nil, 1000, 700, f.now, nil, f.bytes[:])
	app.draw_library(s, 1000, 700)
	ui.end_frame()
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		for c in ([2]cstring{n.label, n.value}) {
			testing.expectf(t, strings.index_byte(string(c), app.POISON) < 0, "node %v reads freed memory: %q", n.role, string(c), loc = loc)
		}
	}
	app.pending_apply(s)
}

// node finds the first node in the last frame's tree whose label starts
// with label.
@(private = "file")
node :: proc(s: ^app.State, label: string) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if strings.has_prefix(string(n.label), label) {
			return n, true
		}
	}
	return {}, false
}

@(private = "file")
press :: proc(s: ^app.State, label: string) -> platform.Event {
	n, ok := node(s, label)
	assert(ok, label)
	return {kind = .Access_Press, target = n.id}
}

@(private = "file")
right_click :: proc(s: ^app.State, label: string) -> (down, up: platform.Event) {
	n, ok := node(s, label)
	assert(ok, label)
	x, y := n.frame[0] + n.frame[2] / 2, n.frame[1] + n.frame[3] / 2
	return {kind = .Mouse_Down, x = x, y = y, button = .Right, click_count = 1}, {kind = .Mouse_Up, x = x, y = y, button = .Right}
}

@(private = "file")
type_text :: proc(f: ^Frame, s: string) -> platform.Event {
	copy(f.bytes[:], s)
	return {kind = .Text, text_length = u32(len(s))}
}

@(private = "file")
search_jobs :: proc(s: ^app.State) -> int {
	return jobs.remove_if(&s.data.queue, proc(job: ^app.Job, _: rawptr) -> bool {return job.kind == .Search}, nil)
}

@(private = "file")
open_test_list :: proc(s: ^app.State) {
	rows := make([]app.Row, 3, context.temp_allocator)
	titles := [3]string{"First song", "Second song", "Third song"}
	for &r, i in rows {
		r = {title = titles[i], artist = "Some Artist", album = "Some Album", duration = "3:00", id = i64(100 + i), album_id = 10, artist_id = 20, seconds = 180}
	}
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
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, type_text(&f, "abc"))
	testing.expect(t, sr.due > 0)

	// Still debouncing.
	library_frame(t, s, &f, press(s, "Liked Songs"))
	testing.expect_value(t, sr.due, 0.0)
	library_frame(t, s, &f, dt = 1)
	testing.expect(t, !sr.loading)
	testing.expect_value(t, search_jobs(s), 0)
	testing.expect_value(t, s.data.view.source, app.Source.Liked)

	// The request is out.
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect(t, sr.loading)
	sent := sr.gen
	library_frame(t, s, &f, press(s, "Liked Songs"))
	testing.expect(t, !sr.loading)
	testing.expect(t, sr.gen != sent)
	testing.expect_value(t, search_jobs(s), 0)
	res := app.Result {
		job  = {kind = .Search, view = sent, id = app.small("abc")},
		rows = []app.Row{{title = "Late", id = 1}},
	}
	app.search_result(s, &res)
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
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_F, modifiers = {ui.PRIMARY}})
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

@(private = "file")
key :: proc(code: u32, modifiers: platform.Modifiers = {}) -> platform.Event {
	return {kind = .Key_Down, key_code = code, modifiers = modifiers}
}

// text_at is a Text event for s, copied into the frame's bytes at offset.
@(private = "file")
text_at :: proc(f: ^Frame, at: int, s: string) -> platform.Event {
	copy(f.bytes[at:], s)
	return {kind = .Text, text_offset = u32(at), text_length = u32(len(s))}
}

// The fake library with "Jóga" searched for and the field focused.
@(private = "file")
searched_state :: proc(t: ^testing.T, f: ^Frame) -> ^app.State {
	s := library_state(true)
	library_frame(t, s, f)
	library_frame(t, s, f, key(ui.KEY_F, {ui.PRIMARY}))
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
	library_frame(t, s, &f, key(ui.KEY_F, {ui.PRIMARY}), text_at(&f, 0, "Kino"))
	testing.expect_value(t, ui.field_text(field), "Kino")
	testing.expect_value(t, field.anchor, field.cursor)
	// And Cmd-L from another focus, here the next box after a Tab.
	library_frame(t, s, &f, key(ui.KEY_TAB))
	testing.expect(t, !ui.has_focus(node_box(s, "Search")))
	library_frame(t, s, &f, key(ui.KEY_L, {ui.PRIMARY}), text_at(&f, 0, "Jóga"))
	testing.expect_value(t, ui.field_text(field), "Jóga")
	testing.expect(t, ui.has_focus(node_box(s, "Search")))
	library_frame(t, s, &f, dt = 1)

	// Return searches for the text it was pressed on. The X after it
	// starts the debounce over.
	library_frame(t, s, &f, key(ui.KEY_RETURN), text_at(&f, 0, "X"))
	testing.expect_value(t, ui.field_text(field), "JógaX")
	testing.expect_value(t, app.small_str(&sr.query), "Jóga")
	testing.expect(t, sr.due > 0)
	library_frame(t, s, &f, dt = 1)
	testing.expect_value(t, app.small_str(&sr.query), "JógaX")

	// Typing, then Return, searches at once for all of it.
	library_frame(t, s, &f, text_at(&f, 0, "Y"), key(ui.KEY_RETURN))
	testing.expect_value(t, app.small_str(&sr.query), "JógaXY")
	testing.expect_value(t, sr.due, 0.0)

	// Escape clears the field before the text after it.
	library_frame(t, s, &f, key(ui.KEY_ESCAPE), text_at(&f, 0, "Kino"))
	testing.expect_value(t, ui.field_text(field), "Kino")
	testing.expect(t, sr.due > 0)
	// Cmd-A, then typing.
	library_frame(t, s, &f, key(ui.KEY_A, {ui.PRIMARY}), text_at(&f, 0, "Jóga"))
	testing.expect_value(t, ui.field_text(field), "Jóga")

	// Text typed before a Tab goes in, though the field lost the focus.
	library_frame(t, s, &f, text_at(&f, 0, "!"), key(ui.KEY_TAB))
	testing.expect_value(t, ui.field_text(field), "Jóga!")
	testing.expect(t, !ui.has_focus(node_box(s, "Search")))

	// Once Escape in an empty field gives up the focus, text after it goes
	// nowhere, until Cmd-F gives the focus back.
	library_frame(t, s, &f, key(ui.KEY_F, {ui.PRIMARY}))
	library_frame(t, s, &f, key(ui.KEY_ESCAPE), key(ui.KEY_ESCAPE), text_at(&f, 0, "a"))
	testing.expect_value(t, ui.field_text(field), "")
	testing.expect(t, !ui.has_focus(node_box(s, "Search")))
	library_frame(t, s, &f, key(ui.KEY_F, {ui.PRIMARY}))
	library_frame(t, s, &f, text_at(&f, 0, "b"), key(ui.KEY_ESCAPE), key(ui.KEY_ESCAPE), key(ui.KEY_F, {ui.PRIMARY}), text_at(&f, 1, "c"))
	testing.expect_value(t, ui.field_text(field), "c")
	testing.expect(t, ui.has_focus(node_box(s, "Search")))
}

// node_box is the box behind the first node whose label starts with label.
@(private = "file")
node_box :: proc(s: ^app.State, label: string) -> ^ui.Box {
	n, ok := node(s, label)
	assert(ok, label)
	return ui.box_lookup(&s.ui, ui.Key(n.id))
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
		r = {title = "Found song", artist = "Other Artist", album = "Other Album", id = i64(100 + i), album_id = 22, artist_id = 33}
	}
	res := app.Result {
		job  = {kind = .Search, view = s.search.gen, id = app.small("found")},
		rows = rows,
	}
	app.search_result(s, &res)
	library_frame(t, s, &f, press(s, "Go to album"))
	testing.expect(t, !ui.menu_is_open("track_menu"))
	testing.expect_value(t, s.data.view.source, app.Source.Search)
	library_frame(t, s, &f)
	testing.expect_value(t, s.data.view.source, app.Source.Search)

	// The fake data's lists, which aren't Track_Views.
	fs := library_state(true)
	defer library_state_free(fs)
	library_frame(t, fs, &f)
	library_frame(t, fs, &f, key(ui.KEY_F, {ui.PRIMARY}))
	library_frame(t, fs, &f, type_text(&f, "Jóga"))
	library_frame(t, fs, &f, dt = 1)
	// A new search waits for its debounce while the menu opens on the old
	// results. It ends in the frame of the click, and the search replaces
	// the list before the menu is built.
	library_frame(t, fs, &f, key(ui.KEY_A, {ui.PRIMARY}), text_at(&f, 0, "Kino"))
	down, up = right_click(fs, "Jóga")
	library_frame(t, fs, &f, down, up)
	library_frame(t, fs, &f)
	testing.expect(t, ui.menu_is_open("track_menu"))
	library_frame(t, fs, &f, press(fs, "Go to album"), dt = 1)
	testing.expect_value(t, app.small_str(&fs.search.query), "Kino")
	testing.expect_value(t, fs.search.fake_source, app.Source.Search)
	testing.expect(t, !ui.menu_is_open("track_menu"))
}

// Search results stay in memory for a few minutes: searching for the same
// words again after opening another list shows them without asking TIDAL,
// tabs included. Older ones are asked for again.
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
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect_value(t, search_jobs(s), 1)
	albums := []app.Found{{id = 5, name = "An album", subtitle = "Album · Someone"}}
	res := app.Result {
		job   = {kind = .Search, view = sr.gen, id = app.small("abc")},
		rows  = []app.Row{{title = "Found song", artist = "Someone", id = 1}, {title = "Other song", artist = "Someone", id = 2}},
		found = {albums = albums},
	}
	app.search_result(s, &res)
	testing.expect(t, s.data.view.done)
	library_frame(t, s, &f)

	library_frame(t, s, &f, press(s, "Liked Songs"))
	testing.expect_value(t, s.data.view.source, app.Source.Liked)
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect_value(t, search_jobs(s), 0)
	testing.expect(t, app.search_showing(s))
	testing.expect_value(t, app.view_count(s), 2)
	testing.expect_value(t, len(sr.found.albums), 1)
	library_frame(t, s, &f)
	_, ok := node(s, "Found song")
	testing.expect(t, ok)

	// Five minutes on, it's asked for again.
	library_frame(t, s, &f, press(s, "Liked Songs"))
	i := app.lru_find(&s.data, .Search, "abc")
	testing.expect(t, i >= 0)
	s.data.lists.entries[i].view.fetched -= app.SEARCH_MAX_AGE + 1
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect_value(t, search_jobs(s), 1)
	testing.expect(t, app.lru_find(&s.data, .Search, "abc") < 0)
}
