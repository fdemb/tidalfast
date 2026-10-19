package tidal_tests

// The library screen drawn without a window, and driven by the events and
// accessibility presses a person or an assistive app would send.

import "core:strings"
import "core:testing"

import app "../src/app"
import "../src/cover"
import "../src/platform"
import "../src/text"
import "../src/ui"

// A State for drawing the library screen without a window: no renderer,
// text system or workers. Closed lists' arenas are poisoned, so a string
// the frame still borrows from one reads as POISON bytes. Like the app's,
// it allocates from an arena, given as context.allocator.
library_state :: proc(fake: bool) -> ^app.State {
	s := new(app.State)
	ui.init(&s.ui)
	app.library_init(&s.library)
	cover.init(&s.data.covers, 1 << 20)
	s.playback.index = -1
	s.data.poison = true
	s.data.fake = fake
	if fake {
		s.rows = app.make_rows()
	} else {
		sign_in(s)
	}
	app.search_init(s)
	return s
}

library_state_free :: proc(s: ^app.State) {
	app.search_shutdown(s)
	app.data_shutdown(s)
	test_state_free(s)
}

Frame :: struct {
	now:   f64,
	bytes: [256]u8,
	fonts: ^Fonts, // nil measures every label as empty
}

// library_frame builds and lays out one frame of the library screen with
// events, then does what the frame asked for, as the app does after
// drawing. It fails the test if the accessibility tree, which end_frame
// copies from the boxes' strings, holds a poisoned byte.
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

// access_node finds the first node in the last frame's tree whose label starts
// with label.
access_node :: proc(s: ^app.State, label: string) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if strings.has_prefix(string(n.label), label) {
			return n, true
		}
	}
	return {}, false
}

press :: proc(s: ^app.State, label: string) -> platform.Event {
	n, ok := access_node(s, label)
	assert(ok, label)
	return {kind = .Access_Press, target = n.id}
}

right_click :: proc(s: ^app.State, label: string) -> (down, up: platform.Event) {
	n, ok := access_node(s, label)
	assert(ok, label)
	x, y := n.frame[0] + n.frame[2] / 2, n.frame[1] + n.frame[3] / 2
	return {kind = .Mouse_Down, x = x, y = y, button = .Right, click_count = 1}, {kind = .Mouse_Up, x = x, y = y, button = .Right}
}

left_click :: proc(s: ^app.State, label: string) -> (down, up: platform.Event) {
	n, ok := access_node(s, label)
	assert(ok, label)
	x, y := n.frame[0] + n.frame[2] / 2, n.frame[1] + n.frame[3] / 2
	return {kind = .Mouse_Down, x = x, y = y, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = x, y = y, button = .Left}
}

type_text :: proc(f: ^Frame, s: string) -> platform.Event {
	copy(f.bytes[:], s)
	return {kind = .Text, text_length = u32(len(s))}
}

key :: proc(code: platform.Key, modifiers: platform.Modifiers = {}) -> platform.Event {
	return {kind = .Key_Down, key = code, modifiers = modifiers}
}

// text_at is a Text event for s, copied into the frame's bytes at offset.
text_at :: proc(f: ^Frame, at: int, s: string) -> platform.Event {
	copy(f.bytes[at:], s)
	return {kind = .Text, text_offset = u32(at), text_length = u32(len(s))}
}

// node_box is the box behind the first node whose label starts with label.
node_box :: proc(s: ^app.State, label: string) -> ^ui.Box {
	n, ok := access_node(s, label)
	assert(ok, label)
	return ui.box_lookup(&s.ui, ui.Key(n.id))
}

// enabled says whether the last frame's button labelled label takes input.
enabled :: proc(s: ^app.State, label: string) -> bool {
	n, ok := access_node(s, label)
	assert(ok, label)
	return .Disabled not_in n.flags
}
