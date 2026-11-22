package tidal_tests

// The accessibility tree's rules, checked on every page and overlay of the
// fake library, so a control added without a name or out of the
// keyboard's reach fails here.

import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/ui"

// What assistive apps read as a control, or a container they step into:
// each needs a name of its own.
@(private = "file")
NAMED :: bit_set[platform.Access_Role]{.Button, .Text_Field, .Row, .Menu, .Menu_Item, .Slider, .List, .Table}

// What an assistive app presses: the shell sends the press to the node's
// box by its key.
@(private = "file")
PRESSABLE :: bit_set[platform.Access_Role]{.Button, .Row, .Menu_Item}

// What the keyboard has to reach: the control, or a focusable box it's
// in, such as a table its rows are in.
@(private = "file")
CONTROLS :: bit_set[platform.Access_Role]{.Button, .Row, .Menu_Item, .Slider, .Text_Field}

// The window's own buttons, drawn by the app on Linux and Windows, stay
// out of Tab order, as the system's title bar buttons do.
@(private = "file")
WINDOW_BUTTONS :: [?]string{"Minimize", "Maximize", "Restore", "Close"}

// check_tree checks the last frame's tree, saying where it is in each
// failure:
// - every named node's name is set, isn't an id or an icon's glyph, and has
//   no space around it, such as an unchecked mark's;
// - a pressable node is a keyed, clickable box;
// - a slider has a value;
// - a control is focusable or in a focusable box, unless it's disabled;
// - no node is in the tree twice, or has no size;
// - no two nodes under one parent share a role and name, except rows;
// - every focusable box on screen is in the tree.
@(private = "file")
check_tree :: proc(t: ^testing.T, s: ^app.State, where_: string, loc := #caller_location) {
	nodes, _ := ui.access_tree(&s.ui)
	testing.expectf(t, len(nodes) > 0, "%s: a tree", where_, loc = loc)
	ids := make(map[u64]bool, context.temp_allocator)
	siblings := make(map[string]bool, context.temp_allocator)
	for n in nodes {
		label := string(n.label)
		what := fmt.tprintf("%s: %v %q", where_, n.role, label)
		testing.expectf(t, !ids[n.id], "%s is in the tree twice", what, loc = loc)
		ids[n.id] = true
		testing.expectf(t, n.frame[2] > 0 && n.frame[3] > 0, "%s has no size: %v", what, n.frame, loc = loc)
		if n.role in NAMED {
			testing.expectf(t, label != "", "%s has no name", what, loc = loc)
			testing.expectf(t, !strings.contains(label, "##"), "%s is named by its id", what, loc = loc)
			testing.expectf(t, strings.trim_space(label) == label, "%s has space around its name", what, loc = loc)
			for r in label {
				testing.expectf(t, r < 0xe000 || r > 0xf8ff, "%s is named with an icon's glyph", what, loc = loc)
			}
		}
		box := ui.box_lookup(&s.ui, ui.Key(n.id))
		if n.role in PRESSABLE {
			testing.expectf(t, box != nil && .Clickable in box.flags, "%s can't be pressed", what, loc = loc)
		}
		if n.role == .Slider {
			testing.expectf(t, n.value != nil && string(n.value) != "", "%s has no value", what, loc = loc)
		}
		window_button := false
		for w in WINDOW_BUTTONS {
			window_button ||= label == w
		}
		if n.role in CONTROLS && .Disabled not_in n.flags && !window_button {
			reached := false
			for b := box; b != nil; b = b.parent {
				reached ||= .Focusable in b.flags
			}
			testing.expectf(t, reached, "%s is out of the keyboard's reach", what, loc = loc)
		}
		if n.role != .Row && label != "" {
			sibling := fmt.tprintf("%d %v %s", n.parent, n.role, label)
			testing.expectf(t, !siblings[sibling], "%s is there twice side by side", what, loc = loc)
			siblings[sibling] = true
		}
	}
	for h in s.ui.hits[:s.ui.hit_count] {
		b := ui.box_lookup(&s.ui, h.key)
		if .Focusable not_in h.flags || b == nil || h.rect.w <= 0 || h.rect.h <= 0 || hidden(b) {
			continue
		}
		testing.expectf(t, ids[u64(h.key)], "%s: a focusable box (%q) on screen isn't in the tree", where_, b.label, loc = loc)
	}
}

// hidden says whether b is drawn see-through, or inside a box that is.
@(private = "file")
hidden :: proc(b: ^ui.Box) -> bool {
	for p := b; p != nil; p = p.parent {
		if ui.drawn_opacity(p) <= 0 {
			return true
		}
	}
	return false
}

// settled draws frames until nothing is fading.
@(private = "file")
settled :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, events: ..platform.Event, dt := 0.016) {
	library_frame(t, s, f, ..events, dt = dt)
	for _ in 0 ..< 60 {
		library_frame(t, s, f, dt = 0.05)
		if !f.animating {
			return
		}
	}
}

@(test)
every_page_keeps_the_tree_rules :: proc(t: ^testing.T) {
	// Measured text, so the links, which are as wide as their text, show.
	heap := context.allocator
	fonts := new(Fonts)
	defer free(fonts, heap)
	if !testing.expect(t, fonts_init(fonts)) {
		return
	}
	defer fonts_destroy(fonts)
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{size = {1100, 700}, fonts = fonts}
	settled(t, s, &f)
	check_tree(t, s, "the library")

	// A song playing, with its links and heart in the player bar, and a
	// selected row with its heart and More.
	s.playback.items = []app.Queue_Item{{title = "Song", artist = "Someone", seconds = 200, row = 0}}
	s.playback.index = 0
	s.library.selected = 1
	settled(t, s, &f)
	check_tree(t, s, "a song playing")

	title := s.rows[1].title
	down, up := right_click(s, title)
	settled(t, s, &f, down, up)
	check_tree(t, s, "the track menu")
	settled(t, s, &f, press(s, "Add to playlist"))
	check_tree(t, s, "the playlist chooser")
	settled(t, s, &f, key(.Escape))

	for menu in ([]string{"Output", "Sleep timer", "Fake data"}) {
		settled(t, s, &f, press(s, menu))
		check_tree(t, s, menu)
		settled(t, s, &f, key(.Escape))
	}

	// One of the user's own playlists: its More menu, the question before
	// deleting it and the field that renames it.
	app.pending_set(s, app.Playlist_Place{index = 5})
	app.pending_apply(s)
	settled(t, s, &f)
	name := app.view_title(s)
	settled(t, s, &f, press(s, fmt.tprintf("More options for %s", name)))
	check_tree(t, s, "a playlist's menu")
	settled(t, s, &f, press(s, "Delete playlist"))
	check_tree(t, s, "the question before deleting")
	settled(t, s, &f, key(.Escape))
	settled(t, s, &f, press(s, fmt.tprintf("More options for %s", name)))
	settled(t, s, &f, press(s, "Rename"))
	check_tree(t, s, "renaming a playlist")
	settled(t, s, &f, key(.Escape))
	settled(t, s, &f, press(s, "New playlist"))
	check_tree(t, s, "a new playlist's row")
	settled(t, s, &f, key(.Escape))

	settled(t, s, &f, press(s, app.view_row(s, 0).album))
	check_tree(t, s, "an album")
	settled(t, s, &f, press(s, app.view_row(s, 0).artist))
	check_tree(t, s, "an artist's page")
	mid := [2]f32{f.size.x - 200, f.size.y / 2}
	library_frame(t, s, &f, {kind = .Mouse_Move, x = mid.x, y = mid.y})
	library_frame(t, s, &f, {kind = .Scroll, x = mid.x, y = mid.y, dy = -600, precise = true, phase = .Began})
	settled(t, s, &f, {kind = .Mouse_Leave})
	check_tree(t, s, "an artist's shelves")
	settled(t, s, &f, press(s, "View all Albums"))
	check_tree(t, s, "an artist's albums")

	settled(t, s, &f, press(s, "Home"))
	check_tree(t, s, "Home")
	app.pending_set(s, app.Settings_Place{})
	app.pending_apply(s)
	settled(t, s, &f)
	check_tree(t, s, "the settings page")

	settled(t, s, &f, key(.F, {ui.PRIMARY}))
	check_tree(t, s, "the empty search page")
	library_frame(t, s, &f, type_text(&f, "Queen"))
	settled(t, s, &f, dt = 1)
	check_tree(t, s, "the songs found")
	for tab in ([]string{"Albums", "Artists", "Playlists"}) {
		settled(t, s, &f, press(s, tab))
		check_tree(t, s, fmt.tprintf("the %s found", tab))
	}

	// A tooltip, and the toast.
	next, ok := access_node(s, "Next")
	testing.expect(t, ok)
	x, y := next.frame[0] + next.frame[2] / 2, next.frame[1] + next.frame[3] / 2
	library_frame(t, s, &f, {kind = .Mouse_Move, x = x, y = y})
	settled(t, s, &f)
	check_tree(t, s, "a tooltip")
	app.set_status(s, .Add_Failed, 0, 1)
	settled(t, s, &f)
	check_tree(t, s, "the toast")
	s.playback.items = nil
	s.playback.index = -1
}
