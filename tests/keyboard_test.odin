package tidal_tests

// The library walked from the keyboard alone: what Tab, the arrows, Enter
// and Escape reach, and where the focus goes after what they do.

import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/audio"
import "../src/platform"
import "../src/ui"

// focused_node is the node with the focus in the last frame's tree.
focused_node :: proc(s: ^app.State) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if .Focused in n.flags {
			return n, true
		}
	}
	return {}, false
}

// focused_label is the focused node's label, "" for none.
focused_label :: proc(s: ^app.State) -> string {
	n, ok := focused_node(s)
	return strings.clone(string(n.label)) if ok else ""
}

// keys sends each key in a frame of its own, and one more frame after.
keys :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, codes: ..platform.Key, modifiers: platform.Modifiers = {}, loc := #caller_location) {
	for c in codes {
		library_frame(t, s, f, key(c, modifiers), loc = loc)
	}
	library_frame(t, s, f, loc = loc)
}

// From the search field Tab goes to the results' tabs, which come next in
// the layout, though the field is drawn after them; Shift-Tab from the
// field goes to Back. On another tab than Songs, Tab goes on from the tabs
// to what was found.
@(test)
tab_from_the_search_field_reaches_the_results :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	f := Frame{size = {1100, 700}}
	s := searched_state_for(t, &f, "Queen")
	defer library_state_free(s)
	testing.expect(t, strings.has_prefix(focused_label(s), "What do you want"), "the field has the focus")
	keys(t, s, &f, .Tab)
	testing.expectf(t, strings.has_prefix(focused_label(s), "Songs"), "Tab from the field reached %q", focused_label(s))
	keys(t, s, &f, .Tab, .Return)
	testing.expectf(t, strings.has_prefix(focused_label(s), "Albums"), "on %q", focused_label(s))
	testing.expect_value(t, s.search.tab, app.Search_Tab.Albums)
	albums, _ := access_node(s, "Albums")
	songs, _ := access_node(s, "Songs")
	testing.expect(t, .Selected in albums.flags && .Selected not_in songs.flags, "the chosen tab reads as selected")
	keys(t, s, &f, .Tab, .Tab, .Tab)
	label := focused_label(s)
	testing.expectf(t, strings.has_suffix(label, "Album · Queen"), "Tab after the tabs reached %q", label)
	keys(t, s, &f, .Down)
	testing.expectf(t, focused_label(s) != label && strings.has_suffix(focused_label(s), "Album · Queen"), "Down moved to %q", focused_label(s))
	keys(t, s, &f, .Return)
	testing.expect_value(t, s.search.fake_source, app.Source.Album)

	keys(t, s, &f, .Escape)
	open_search(t, s, &f)
	keys(t, s, &f, .Tab, modifiers = {.Shift})
	testing.expectf(t, focused_label(s) == "Back", "Shift-Tab from the field reached %q", focused_label(s))
}

// The fake library with q searched for and the field focused.
searched_state_for :: proc(t: ^testing.T, f: ^Frame, q: string) -> ^app.State {
	s := library_state(true)
	library_frame(t, s, f)
	open_search(t, s, f)
	library_frame(t, s, f, type_text(f, q))
	library_frame(t, s, f, dt = 1)
	library_frame(t, s, f)
	return s
}

// tab_to presses Tab until the focus is on a node whose label starts with
// label, at most limit times, and says whether it got there.
tab_to :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, label: string, limit := 120, loc := #caller_location) -> bool {
	for _ in 0 ..< limit {
		if strings.has_prefix(focused_label(s), label) {
			return true
		}
		keys(t, s, f, .Tab, loc = loc)
	}
	testing.expectf(t, false, "Tab never reached %q", label, loc = loc)
	return false
}

// value_of is the value of the node whose label starts with label.
value_of :: proc(s: ^app.State, label: string) -> string {
	n, ok := access_node(s, label)
	return strings.clone(string(n.value)) if ok else ""
}

// Tab reaches the volume and the sidebar's width, and the arrows, Home
// and End move them rather than the focus.
@(test)
sliders_move_with_the_keys :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	s.settings.volume = 0.5
	f := Frame{size = {1100, 700}}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	if !tab_to(t, s, &f, "Volume") {
		return
	}
	keys(t, s, &f, .Right)
	testing.expect_value(t, value_of(s, "Volume"), "55%")
	testing.expect_value(t, focused_label(s), "Volume")
	keys(t, s, &f, .Down, .Down)
	testing.expect_value(t, value_of(s, "Volume"), "45%")
	keys(t, s, &f, .End)
	testing.expect_value(t, value_of(s, "Volume"), "100%")
	keys(t, s, &f, .Home)
	testing.expect_value(t, value_of(s, "Volume"), "0%")
	testing.expect_value(t, focused_label(s), "Volume")

	if !tab_to(t, s, &f, "Sidebar width") {
		return
	}
	testing.expect_value(t, value_of(s, "Sidebar width"), "250 pt")
	keys(t, s, &f, .Right)
	testing.expect_value(t, value_of(s, "Sidebar width"), "260 pt")
	testing.expect_value(t, s.settings.sidebar_w, f32(260))
	keys(t, s, &f, .Home)
	testing.expect_value(t, value_of(s, "Sidebar width"), "210 pt")
	testing.expect_value(t, focused_label(s), "Sidebar width")
}

// With the table focused, Tab goes on to the selected row's heart and
// More, which opens the track menu on its first item. Escape gives the
// focus back to More.
@(test)
the_track_menu_opens_from_the_keyboard :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1100, 700}}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	title := s.rows[0].title
	if !tab_to(t, s, &f, "Liked Songs", 200) || !tab_to(t, s, &f, fmt.aprintf("Like %s", title)) {
		return
	}
	keys(t, s, &f, .Return)
	testing.expect(t, app.liked_has(&s.data, 0), "Enter on the heart likes the song")
	keys(t, s, &f, .Tab)
	more := fmt.aprintf("More options for %s", title)
	testing.expect_value(t, focused_label(s), more)
	keys(t, s, &f, .Return)
	testing.expect(t, ui.menu_is_open("track_menu"))
	testing.expect_value(t, focused_label(s), "Play")
	keys(t, s, &f, .Escape)
	testing.expect_value(t, focused_label(s), more)
}

// While a menu is open the keys it doesn't use go nowhere: M doesn't mute
// behind it.
@(test)
keys_stop_at_an_open_menu :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	s.settings.volume = 0.5
	f := Frame{size = {1100, 700}}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	if !tab_to(t, s, &f, "Sleep timer") {
		return
	}
	keys(t, s, &f, .Return)
	testing.expect(t, ui.menu_is_open("sleep_menu"))
	keys(t, s, &f, .M)
	testing.expect(t, !s.settings.muted, "M behind the menu doesn't mute")
	testing.expect(t, ui.menu_is_open("sleep_menu"))
	keys(t, s, &f, .Escape)
	keys(t, s, &f, .M)
	testing.expect(t, s.settings.muted, "M mutes once the menu is closed")
}

// Return or Escape in the field that names a new playlist, or renames
// one, gives the focus back to the + or the More button that opened it.
@(test)
playlist_name_fields_give_the_focus_back :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1100, 700}}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	if !tab_to(t, s, &f, "New playlist") {
		return
	}
	keys(t, s, &f, .Return)
	testing.expect_value(t, focused_label(s), "Playlist name")
	keys(t, s, &f, .Escape)
	testing.expect_value(t, focused_label(s), "New playlist")
	testing.expect(t, ui.focus_visible(), "with its ring")
	keys(t, s, &f, .Return)
	library_frame(t, s, &f, type_text(&f, "Mine"))
	keys(t, s, &f, .Return)
	testing.expect_value(t, app.sidebar_entry(s, 1).name, "Mine")
	testing.expect_value(t, focused_label(s), "New playlist")

	app.pending_set(s, app.Playlist_Place{index = 6})
	app.pending_apply(s)
	library_frame(t, s, &f)
	more := fmt.aprintf("More options for %s", app.view_title(s))
	if !tab_to(t, s, &f, more) {
		return
	}
	keys(t, s, &f, .Return, .Down, .Down)
	testing.expect_value(t, focused_label(s), "Rename")
	keys(t, s, &f, .Return)
	testing.expect_value(t, focused_label(s), "Playlist name")
	keys(t, s, &f, .Escape)
	testing.expect_value(t, focused_label(s), more)
}

// The output menu's switch reads as its name, chosen or not, without the
// mark drawn before it.
@(test)
the_output_menu_reads_without_marks :: proc(t: ^testing.T) {
	when !audio.BIT_PERFECT {
		return
	}
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1100, 700}}
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Output"))
	library_frame(t, s, &f)
	item, ok := access_node(s, "Bit-perfect output")
	testing.expect(t, ok, "the item is named Bit-perfect output")
	testing.expect(t, .Selected not_in item.flags)
	menu, _ := access_node(s, "Output")
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == .Menu {
			testing.expect_value(t, string(n.label), "Output")
		}
	}
	_ = menu
}

// A backtick typed in a text field goes into it and leaves the overlay be.
@(test)
backtick_in_a_field_is_text :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1100, 700}}
	library_frame(t, s, &f)
	open_search(t, s, &f)
	grave := [?]platform.Event{key(.Grave), type_text(&f, "`")}
	ui.begin_frame(&s.ui, grave[:], nil, nil, f.size.x, f.size.y, f.now + 0.016, nil, f.bytes[:])
	app.overlay_key(s)
	app.draw_library(s, f.size.x, f.size.y)
	ui.end_frame()
	testing.expect(t, !s.show_overlay, "the overlay stays off")
	testing.expect_value(t, ui.field_text(&s.search.field), "`")

	library_frame(t, s, &f, key(.Escape))
	library_frame(t, s, &f, key(.Escape))
	ui.begin_frame(&s.ui, {key(.Grave)}, nil, nil, f.size.x, f.size.y, f.now + 0.032, nil, f.bytes[:])
	app.overlay_key(s)
	app.draw_library(s, f.size.x, f.size.y)
	ui.end_frame()
	testing.expect(t, s.show_overlay, "outside a field the backtick shows it")
}
