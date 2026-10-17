package tidal_tests

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/cover"
import "../src/jobs"
import "../src/platform"
import "../src/text"
import "../src/tidal"
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
	fonts: ^Fonts, // nil measures every label as empty
}

// library_frame builds and lays out one frame of the library screen with
// events, then does what the frame asked for, as the app does after
// drawing. It fails the test if the accessibility tree, which end_frame
// copies from the boxes' strings, holds a poisoned byte.
@(private = "file")
library_frame :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, events: ..platform.Event, dt := 0.016, loc := #caller_location) {
	f.now += dt
	free_all(context.temp_allocator)
	texts: ^text.State
	if f.fonts != nil {
		texts = f.fonts.state
		text.begin_frame(texts, &f.fonts.r)
	}
	ui.begin_frame(&s.ui, events, nil, texts, 1000, 700, f.now, nil, f.bytes[:])
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
left_click :: proc(s: ^app.State, label: string) -> (down, up: platform.Event) {
	n, ok := node(s, label)
	assert(ok, label)
	x, y := n.frame[0] + n.frame[2] / 2, n.frame[1] + n.frame[3] / 2
	return {kind = .Mouse_Down, x = x, y = y, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = x, y = y, button = .Left}
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
	_, single := node(s, "Go to artist")
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
	library_frame(t, s, &f, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
	sr := &s.search
	albums := []app.Found{{id = 5, name = "An album", subtitle = "Album · Tyler, The Creator, Kali Uchis"}}
	albums[0].artist, albums[0].artists = two_artists()
	res := app.Result {
		job   = {kind = .Search, view = sr.gen, id = app.small("abc")},
		rows  = []app.Row{{title = "Found song", artist = "Someone", id = 1}},
		found = {albums = albums},
	}
	app.search_result(s, &res)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Albums"))
	library_frame(t, s, &f)
	down, up = left_click(s, "Tyler, The Creator")
	library_frame(t, s, &f, down, up)
	testing.expect_value(t, s.data.view.source, app.Source.Artist)
	testing.expect_value(t, app.small_str(&s.data.view.id), "40")
}

// A song with more artists than fit lists them up to the edge of its
// column: the one that crosses it is cut, and the rest are left out.
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
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}

	first, ok := node(s, "Artist number 0")
	testing.expect(t, ok)
	_, last := node(s, "Artist number 11")
	testing.expect(t, !last)
	title, _ := node(s, "Crowded song")
	right := title.frame[0] + title.frame[2]
	shown := 0
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if strings.has_prefix(string(n.label), "Artist number") {
			shown += 1
			testing.expectf(t, n.frame[0] + n.frame[2] <= right + 0.5, "%s ends at %v, past %v", n.label, n.frame[0] + n.frame[2], right)
		}
	}
	testing.expect(t, shown > 1 && shown < 12)
	testing.expect(t, first.frame[2] > 0)
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
	library_frame(t, s, &f, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}})
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
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
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
	library_frame(t, s, &f, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}})
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
key :: proc(code: platform.Key, modifiers: platform.Modifiers = {}) -> platform.Event {
	return {kind = .Key_Down, key = code, modifiers = modifiers}
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
	library_frame(t, s, f, key(.F, {ui.PRIMARY}))
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
	testing.expect(t, !ui.has_focus(node_box(s, "Search")))
	library_frame(t, s, &f, key(.L, {ui.PRIMARY}), text_at(&f, 0, "Jóga"))
	testing.expect_value(t, ui.field_text(field), "Jóga")
	testing.expect(t, ui.has_focus(node_box(s, "Search")))
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
	testing.expect(t, !ui.has_focus(node_box(s, "Search")))

	// Once Escape in an empty field gives up the focus, text after it goes
	// nowhere, until Cmd-F gives the focus back.
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
	library_frame(t, s, &f, key(.Escape), key(.Escape), text_at(&f, 0, "a"))
	testing.expect_value(t, ui.field_text(field), "")
	testing.expect(t, !ui.has_focus(node_box(s, "Search")))
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
	library_frame(t, s, &f, text_at(&f, 0, "b"), key(.Escape), key(.Escape), key(.F, {ui.PRIMARY}), text_at(&f, 1, "c"))
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
		r = {title = "Found song", artist = "Other Artist", album = "Other Album", id = i64(100 + i), album_id = 22}
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
	library_frame(t, fs, &f, key(.F, {ui.PRIMARY}))
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
	library_frame(t, s, &f, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
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
	library_frame(t, s, &f, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
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
	library_frame(t, s, &f, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}})
	library_frame(t, s, &f, {kind = .Key_Down, key = .Return})
	testing.expect_value(t, search_jobs(s), 1)
	testing.expect(t, app.lru_find(&s.data, .Search, "abc") < 0)
}

// enabled says whether the last frame's button labelled label takes input.
@(private = "file")
enabled :: proc(s: ^app.State, label: string) -> bool {
	n, ok := node(s, label)
	assert(ok, label)
	return .Disabled not_in n.flags
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
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
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

	// Emptying the field goes back to the playlist, which is a place too.
	library_frame(t, s, &f, press(s, "Forward"))
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
	library_frame(t, s, &f, key(.Escape))
	library_frame(t, s, &f)
	testing.expect(t, !app.search_showing(s))
	testing.expect_value(t, app.view_title(s), "Liked Songs")
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect_value(t, app.view_title(s), "Results for “Jóga”")
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
	app.session_open(&s.data)
	sr := &s.search
	open_test_list(s)
	f: Frame
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	go_to_first_album(t, s, &f)
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
	library_frame(t, s, &f, type_text(&f, "abc"))
	library_frame(t, s, &f, key(.Return))
	res := app.Result {
		job   = {kind = .Search, view = sr.gen, id = app.small("abc")},
		rows  = []app.Row{{title = "Found song", artist = "Someone", id = 1}},
		found = {albums = []app.Found{{id = 5, name = "An album"}}},
	}
	app.search_result(s, &res)
	library_frame(t, s, &f)
	testing.expect(t, enabled(s, "Back"))

	app.account_end(s)
	s.data.account = .Signed_In
	library_frame(t, s, &f)
	testing.expect(t, !enabled(s, "Back"))
	testing.expect(t, !enabled(s, "Forward"))
	testing.expect(t, !app.search_showing(s))
	testing.expect_value(t, ui.field_text(&sr.field), "")
	testing.expect_value(t, app.small_str(&sr.query), "")
	testing.expect_value(t, len(sr.found.albums), 0)
}
