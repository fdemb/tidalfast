package tidal_tests

// The track list's header scrolls with the rows and collapses into a bar
// pinned over them, which takes the clicks there.

import "core:fmt"
import "core:mem"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/ui"

@(private = "file")
exact_node :: proc(s: ^app.State, label: string, role: platform.Access_Role) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == role && string(n.label) == label {
			return n, true
		}
	}
	return {}, false
}

// list_view is the scroll view around the table labelled title.
@(private = "file")
list_view :: proc(t: ^testing.T, s: ^app.State, title: string) -> (view: ^ui.Box, table: platform.Access_Node) {
	ok: bool
	table, ok = exact_node(s, title, .Table)
	testing.expectf(t, ok, "no table %q", title)
	box := ui.box_lookup(&s.ui, ui.Key(table.id))
	return box.parent.parent, table
}

@(private = "file")
scroll_to :: proc(view: ^ui.Box, y: f32) {
	view.view_off.y, view.view_off_target.y = y, y
}

@(private = "file")
click_at :: proc(x, y: f32) -> (down, up: platform.Event) {
	return {kind = .Mouse_Down, x = x, y = y, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = x, y = y, button = .Left}
}

@(test)
list_header_collapses_over_the_rows :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	title := app.view_title(s)
	_, hero := exact_node(s, fmt.tprintf("Shuffle %s", title), .Button)
	testing.expect(t, hero, "the hero's actions at the top")

	main_w := f32(1000 - app.SIDEBAR_DEFAULT - app.HANDLE_W)
	h := app.list_header(.Playlist, main_w, 0)
	rows_top := app.header_rows_top(h)
	view, _ := list_view(t, s, title)
	scroll_to(view, rows_top + 50 * app.TRACK_ROW_H)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	_, hero = exact_node(s, fmt.tprintf("Shuffle %s", title), .Button)
	testing.expect(t, !hero, "the hero isn't built once it's scrolled away")
	_, pinned := exact_node(s, fmt.tprintf("Play %s", title), .Button)
	testing.expect(t, pinned, "Play in the pinned bar")
	row := app.view_row(s, 50)
	_, top := exact_node(s, fmt.tprintf("%s, %s, %s", row.title, row.artist, row.album), .Row)
	testing.expect(t, top, "row 50 is at the top")
	testing.expect_value(t, s.library.top_row, 50)

	// A row is under the pinned headings: the click stops there.
	view, _ = list_view(t, s, title)
	down, up := click_at(view.rect.x + 200, view.rect.y + h.bar + app.HEADER_H / 2)
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.selected, -1)
	down, up = click_at(view.rect.x + 200, view.rect.y + app.header_pinned_h(h) + app.TRACK_ROW_H * 2)
	library_frame(t, s, &f, down, up)
	testing.expect(t, s.library.selected > 50, "a row below the pinned header takes the click")

	// Home scrolls row 0 to just under the pinned bar and headings.
	_, table := list_view(t, s, title)
	library_frame(t, s, &f, {kind = .Access_Focus, target = table.id})
	library_frame(t, s, &f, key(.Home))
	testing.expect_value(t, s.library.selected, 0)
	view, _ = list_view(t, s, title)
	testing.expect_value(t, view.view_off_target.y, rows_top - app.header_pinned_h(h) - app.LIST_PAD_Y)
}

// An album's rows have no cover or album column, and after its last row it
// says how long it is and shows more by its artist, but not itself.
@(test)
album_ends_in_more_by_its_artist :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	library_frame(t, s, &f)
	app.open_album(s, 0, s.rows[0].album, "", 0)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	album := app.view_title(s)
	testing.expect_value(t, album, s.rows[0].album)
	testing.expect_value(t, app.list_kind(s), app.List_Kind.Album)
	artist := app.view_row(s, 0).artist

	view, _ := list_view(t, s, album)
	scroll_to(view, 1e6)
	for _ in 0 ..< 4 {
		library_frame(t, s, &f)
	}
	nodes, _ := ui.access_tree(&s.ui)
	shelf := -1
	for n, i in nodes {
		if n.role == .List && string(n.label) == fmt.tprintf("More by %s", artist) {
			shelf = i
		}
	}
	testing.expect(t, shelf >= 0, "More by the artist after the last row")
	cards := 0
	for n in nodes {
		if n.role != .Button || int(n.parent) != shelf {
			continue
		}
		label := string(n.label)
		if len(label) > len(album) && label[:len(album)] == album && label[len(album)] == ',' {
			testing.expectf(t, false, "the open album is a card: %q", label)
		}
		cards += 1
	}
	testing.expect(t, cards > 0, "the shelf has cards")
}

@(private = "file")
timed_rows :: proc(seconds: ..int) -> []app.Row {
	rows := make([]app.Row, len(seconds), context.temp_allocator)
	for &r, i in rows {
		r.id = i64(i + 1)
		r.title = fmt.tprint(i)
		r.seconds = seconds[i]
	}
	return rows
}

// The header says how many songs the list has and how long they play, and
// keeps up as rows come, go and another list opens, without reading every
// row on every frame it's drawn.
@(test)
list_songs_follows_the_list :: proc(t: ^testing.T) {
	s := new(app.State)
	defer free(s)
	d := &s.data
	defer app.view_close(d)
	app.view_open(d, .Playlist, "pl", "pl", "", 3)
	v := &d.view
	app.view_add_rows(v, 0, 100, timed_rows(60, 120, 180))
	testing.expect_value(t, app.list_songs(s, .Playlist), "3 songs, 6 min 0 sec")
	testing.expect(t, app.view_edit(v, true, {id = 9, seconds = 30}))
	testing.expect_value(t, app.list_songs(s, .Playlist), "4 songs, 6 min 30 sec")
	testing.expect(t, app.view_edit(v, false, {id = 2}))
	testing.expect_value(t, app.list_songs(s, .Playlist), "3 songs, 4 min 30 sec")

	app.view_open(d, .Playlist, "pl2", "pl2", "", 3)
	app.view_add_rows(v, 0, 100, timed_rows(3600, 60, 60))
	testing.expect_value(t, app.list_songs(s, .Playlist), "3 songs, 1 hr 2 min")

	// Nothing in the app changes a loaded row's length in place, so a
	// header that still reads 1 hr 2 min didn't sum the rows again.
	v.rows[0].seconds = 0
	testing.expect_value(t, app.list_songs(s, .Playlist), "3 songs, 1 hr 2 min")
}

// The More button's menu opens by the button, with its items inside it.
@(test)
list_menu_opens_by_more :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f: Frame
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	more, ok := exact_node(s, fmt.tprintf("More options for %s", app.view_title(s)), .Button)
	testing.expect(t, ok, "the hero's More button")
	library_frame(t, s, &f, {kind = .Access_Press, target = more.id})
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	testing.expect(t, ui.menu_is_open("list_menu"), "More opens the menu")
	nodes, _ := ui.access_tree(&s.ui)
	menu := -1
	for n, i in nodes {
		if n.role == .Menu {
			menu = i
		}
	}
	testing.expect(t, menu >= 0, "a menu in the tree")
	item, found := exact_node(s, "Shuffle", .Menu_Item)
	testing.expect(t, found, "Shuffle in the menu")
	if menu < 0 || !found {
		return
	}
	testing.expect_value(t, int(item.parent), menu)
	m := nodes[menu].frame
	testing.expect(t, item.frame[1] >= m[1] && item.frame[1] + item.frame[3] <= m[1] + m[3], "Shuffle inside the menu's frame")
	testing.expect(t, m[1] < more.frame[1] + more.frame[3] + 20, "the menu opens by the button, not at the window's bottom")
}
