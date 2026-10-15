package tidal_tests

import "core:testing"

import "../src/platform"
import "../src/ui"

@(private = "file")
field_with :: proc(s: string) -> ^ui.Text_Field {
	f := new(ui.Text_Field, context.temp_allocator)
	ui.field_insert(f, s)
	return f
}

@(private = "file")
backspaces :: proc(f: ^ui.Text_Field, n: int) {
	for _ in 0 ..< n {
		ui.field_delete(f, -1, .Cluster)
	}
}

@(test)
test_edit_insert_and_delete_latin :: proc(t: ^testing.T) {
	f := field_with("Blue in Green")
	testing.expect_value(t, ui.field_text(f), "Blue in Green")
	testing.expect_value(t, f.cursor, 13)
	backspaces(f, 6)
	testing.expect_value(t, ui.field_text(f), "Blue in")
	ui.field_move(f, -1, .Line, false)
	ui.field_delete(f, 1, .Cluster)
	testing.expect_value(t, ui.field_text(f), "lue in")
	testing.expect_value(t, f.cursor, 0)
	// A combining acute stays with its o.
	f = field_with("Jo\u0301ga")
	ui.field_move(f, -1, .Cluster, false)
	ui.field_move(f, -1, .Cluster, false)
	testing.expect_value(t, f.cursor, len("Jo\u0301"))
	backspaces(f, 1)
	testing.expect_value(t, ui.field_text(f), "Jga")
}

@(test)
test_edit_clusters :: proc(t: ^testing.T) {
	Case :: struct {
		text:   string,
		after:  [3]string, // after one, two and three backspaces
	}
	cases := []Case {
		// Precomposed Hangul syllables are a cluster each.
		{"가나다", {"가나", "가", ""}},
		// Conjoining jamo: ᄒ ᅡ ᆫ and ᄀ ᅳ ᆯ make two clusters of three codepoints.
		{"한글", {"한", "", ""}},
		// A ZWJ family, a flag and a skin tone each go in one press.
		{"a👨‍👩‍👧b", {"a👨‍👩‍👧", "a", ""}},
		{"🇵🇱👍🏽", {"🇵🇱", "", ""}},
		// Arabic letters one at a time, a mark with its letter.
		{"سلام", {"سلا", "سل", "س"}},
		{"بَتَ", {"بَ", "", ""}},
	}
	for c in cases {
		f := field_with(c.text)
		for want, i in c.after {
			backspaces(f, 1)
			testing.expectf(t, ui.field_text(f) == want, "%q after %d backspaces: %q, want %q", c.text, i + 1, ui.field_text(f), want)
		}
	}

	// Moving never stops inside a cluster, and forward delete takes the
	// whole family.
	f := field_with("a👨‍👩‍👧b")
	ui.field_move(f, -1, .Line, false)
	ui.field_move(f, 1, .Cluster, false)
	testing.expect_value(t, f.cursor, 1)
	ui.field_move(f, 1, .Cluster, false)
	testing.expect_value(t, f.cursor, len("a👨‍👩‍👧"))
	ui.field_move(f, -1, .Cluster, false)
	ui.field_delete(f, 1, .Cluster)
	testing.expect_value(t, ui.field_text(f), "ab")

	// A replacement range inside a cluster widens to the whole cluster.
	f = field_with("x👍🏽y")
	ui.field_insert_at(f, 2, 3, "!")
	testing.expect_value(t, ui.field_text(f), "x!y")
}

@(test)
test_edit_selection_and_words :: proc(t: ^testing.T) {
	f := field_with("Paranoid Android, 1997")
	ui.field_move(f, -1, .Word, false)
	testing.expect_value(t, f.cursor, len("Paranoid Android, "))
	ui.field_move(f, -1, .Word, false)
	testing.expect_value(t, f.cursor, len("Paranoid "))
	ui.field_move(f, -1, .Word, true)
	testing.expect_value(t, ui.field_selected(f), "Paranoid ")
	// Without Shift a selection collapses to the side moved toward.
	ui.field_move(f, 1, .Cluster, false)
	testing.expect_value(t, f.cursor, len("Paranoid "))
	testing.expect_value(t, f.anchor, f.cursor)
	ui.field_move(f, 1, .Word, false)
	testing.expect_value(t, f.cursor, len("Paranoid Android"))
	ui.field_move(f, 1, .Word, true)
	testing.expect_value(t, ui.field_selected(f), ", 1997")
	// Typing replaces the selection.
	ui.field_insert(f, "!")
	testing.expect_value(t, ui.field_text(f), "Paranoid Android!")

	ui.field_select_word(f, 3)
	testing.expect_value(t, ui.field_selected(f), "Paranoid")
	ui.field_select_word(f, len("Paranoid"))
	testing.expect_value(t, ui.field_selected(f), " ")
	ui.field_select_all(f)
	testing.expect_value(t, ui.field_selected(f), "Paranoid Android!")

	ui.field_move(f, 1, .Line, false)
	ui.field_delete(f, -1, .Word)
	testing.expect_value(t, ui.field_text(f), "Paranoid ")
	ui.field_delete(f, -1, .Line)
	testing.expect_value(t, ui.field_text(f), "")

	// Words in other scripts.
	f = field_with("夜に駆ける 밤편지")
	ui.field_move(f, -1, .Word, false)
	testing.expect_value(t, f.cursor, len("夜に駆ける "))
	f = field_with("عيونك حبيبي")
	ui.field_delete(f, -1, .Word)
	testing.expect_value(t, ui.field_text(f), "عيونك ")
}

@(test)
test_edit_undo_coalescing :: proc(t: ^testing.T) {
	f := new(ui.Text_Field)
	defer free(f)
	for r in "Hello" {
		buf: [4]u8
		buf[0] = u8(r)
		ui.field_insert(f, string(buf[:1]))
	}
	ui.field_insert(f, " world")
	testing.expect_value(t, ui.field_text(f), "Hello world")
	// One typed run, one undo step.
	testing.expect(t, ui.field_undo(f))
	testing.expect_value(t, ui.field_text(f), "")
	testing.expect(t, ui.field_redo(f))
	testing.expect_value(t, ui.field_text(f), "Hello world")
	testing.expect_value(t, f.cursor, 11)

	// Moving the cursor ends the run; backspaces join each other.
	ui.field_move(f, -1, .Word, false)
	ui.field_insert(f, "big ")
	backspaces(f, 2)
	testing.expect_value(t, ui.field_text(f), "Hello biworld")
	testing.expect(t, ui.field_undo(f))
	testing.expect_value(t, ui.field_text(f), "Hello big world")
	testing.expect(t, ui.field_undo(f))
	testing.expect_value(t, ui.field_text(f), "Hello world")
	testing.expect(t, ui.field_undo(f))
	testing.expect_value(t, ui.field_text(f), "")
	testing.expect(t, !ui.field_undo(f))
	// A new edit drops the redo steps.
	ui.field_insert(f, "x")
	testing.expect(t, !ui.field_redo(f))

	// Paste and cut are steps of their own.
	ui.field_paste(f, "yz")
	ui.field_select_all(f)
	cut := ui.field_cut(f)
	testing.expect_value(t, cut, "xyz")
	testing.expect(t, ui.field_undo(f))
	testing.expect_value(t, ui.field_text(f), "xyz")
	testing.expect(t, ui.field_undo(f))
	testing.expect_value(t, ui.field_text(f), "x")
}

@(test)
test_edit_marked_text :: proc(t: ^testing.T) {
	f := field_with("search ")
	// Kana as the input method composes it, then the kanji it commits.
	ui.field_set_marked(f, "に", 3, 3)
	ui.field_set_marked(f, "にほ", 6, 6)
	ui.field_set_marked(f, "にほんご", 12, 12)
	testing.expect_value(t, ui.field_text(f), "search にほんご")
	testing.expect(t, f.marked)
	testing.expect_value(t, f.marked_start, 7)
	testing.expect_value(t, f.marked_end, 7 + len("にほんご"))
	testing.expect_value(t, f.cursor, f.marked_end)
	// Conversion selects a clause inside the marked text.
	ui.field_set_marked(f, "日本語", 0, len("日本"))
	testing.expect_value(t, ui.field_selected(f), "日本")
	// Keys that move or delete wait while composing.
	ui.field_move(f, -1, .Cluster, false)
	ui.field_delete(f, -1, .Cluster)
	testing.expect_value(t, ui.field_text(f), "search 日本語")
	ui.field_insert(f, "日本語")
	testing.expect(t, !f.marked)
	testing.expect_value(t, ui.field_text(f), "search 日本語")
	testing.expect_value(t, f.cursor, len("search 日本語"))
	// The composition and the typing before it undo together.
	testing.expect(t, ui.field_undo(f))
	testing.expect_value(t, ui.field_text(f), "")

	// An empty composition cancels it; unmark keeps what's there.
	f = field_with("ab")
	ui.field_move(f, -1, .Cluster, false)
	ui.field_set_marked(f, "x", 1, 1)
	testing.expect_value(t, ui.field_text(f), "axb")
	ui.field_set_marked(f, "", 0, 0)
	testing.expect_value(t, ui.field_text(f), "ab")
	testing.expect(t, !f.marked)
	testing.expect_value(t, f.cursor, 1)
	ui.field_set_marked(f, "한", 3, 3)
	ui.field_unmark(f)
	testing.expect_value(t, ui.field_text(f), "a한b")
	testing.expect_value(t, f.cursor, len("a한"))

	// Composition replaces the selection.
	f = field_with("abc")
	ui.field_select_all(f)
	ui.field_set_marked(f, "あ", 3, 3)
	testing.expect_value(t, ui.field_text(f), "あ")
	ui.field_insert(f, "亜")
	testing.expect_value(t, ui.field_text(f), "亜")
}

@(test)
test_edit_limit_and_sanitize :: proc(t: ^testing.T) {
	f := new(ui.Text_Field)
	defer free(f)
	f.limit = 6
	ui.field_insert(f, "ab👍🏽cd")
	// The thumb and its tone are 8 bytes, which don't fit after "ab", so the
	// cluster goes whole and the rest after it too.
	testing.expect_value(t, ui.field_text(f), "ab")
	ui.field_paste(f, "x\ny\tz\x01")
	testing.expect_value(t, ui.field_text(f), "abx y ")
}

// The widget: text and marked text events from the shell reach the focused
// field in order with the keys, and the field tells the shell its state.
@(test)
test_text_field_events :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer field_ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	now := 0.0
	bytes: [64]u8
	frame :: proc(u: ^ui.State, f: ^ui.Text_Field, now: ^f64, bytes: []u8, events: ..platform.Event) -> ui.Field_Signal {
		now^ += 0.016
		ui.begin_frame(u, events, nil, nil, 300, 200, now^, nil, bytes)
		sig := ui.text_field("search", f, "Search", ui.px(200), ui.px(30))
		ui.end_frame()
		return sig
	}
	text :: proc(bytes: []u8, at: int, kind: platform.Event_Kind, s: string, sel: i32 = 0) -> platform.Event {
		copy(bytes[at:], s)
		return {kind = kind, text_offset = u32(at), text_length = u32(len(s)), select_start = sel, select_end = sel}
	}
	frame(&u, f, &now, bytes[:])
	frame(&u, f, &now, bytes[:])
	sig := frame(&u, f, &now, bytes[:], {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left})
	testing.expect(t, sig.focused)

	marked := len("にほんご")
	sig = frame(&u, f, &now, bytes[:], text(bytes[:], 0, .Marked_Text, "にほんご", i32(marked)))
	testing.expect_value(t, ui.field_text(f), "にほんご")
	testing.expect(t, f.marked)
	input, changed := ui.text_input(&u)
	testing.expect(t, changed)
	testing.expect_value(t, input.marked_start, 0)
	testing.expect_value(t, input.marked_end, i32(marked))
	testing.expect_value(t, string(input.text[:input.length]), "にほんご")

	// The commit, then a key and more text in the same frame, in order.
	sig = frame(&u, f, &now, bytes[:], text(bytes[:], 0, .Text, "日本語"), {kind = .Key_Down, key_code = ui.KEY_LEFT}, text(bytes[:], 16, .Text, "の"))
	testing.expect(t, sig.changed)
	testing.expect_value(t, ui.field_text(f), "日本の語")
	input, changed = ui.text_input(&u)
	testing.expect(t, changed)
	testing.expect_value(t, input.marked_start, -1)
	testing.expect_value(t, input.selection_start, u32(len("日本の")))
	_, changed = ui.text_input(&u)
	testing.expect(t, !changed, "the same state again isn't a change")

	// Space and the arrows stay in the field rather than clicking or moving
	// the focus, and Escape clears it, then gives up the focus.
	sig = frame(&u, f, &now, bytes[:], {kind = .Key_Down, key_code = ui.KEY_UP}, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect(t, sig.submitted)
	testing.expect(t, sig.focused)
	testing.expect_value(t, f.cursor, 0)
	sig = frame(&u, f, &now, bytes[:], {kind = .Key_Down, key_code = ui.KEY_ESCAPE})
	testing.expect_value(t, ui.field_text(f), "")
	sig = frame(&u, f, &now, bytes[:], {kind = .Key_Down, key_code = ui.KEY_ESCAPE})
	testing.expect(t, sig.cancelled)
	sig = frame(&u, f, &now, bytes[:])
	testing.expect(t, !sig.focused)
	input, changed = ui.text_input(&u)
	testing.expect(t, changed)
	testing.expect(t, input.text == nil, "no field has the focus")
}

// The caret blinks by asking for a frame at its next change, not by
// animating, and not at all without the keyboard.
@(test)
test_text_field_blink :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer field_ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	run :: proc(u: ^ui.State, f: ^ui.Text_Field, now: f64, events: ..platform.Event) -> (animating: bool) {
		ui.begin_frame(u, events, nil, nil, 300, 200, now)
		b := ui.text_field("search", f, "Search", ui.px(200), ui.px(30))
		if len(events) == 0 && !ui.has_focus(b.box) {
			ui.focus_text_field(b.box, f)
		}
		return ui.end_frame()
	}
	run(&u, f, 1)
	run(&u, f, 1.1)
	run(&u, f, 1.2)
	animating := run(&u, f, 1.3)
	testing.expect(t, !animating, "a focused field doesn't animate")
	wait := ui.wake_after(&u)
	testing.expectf(t, wait > 0 && wait <= ui.BLINK_SECONDS, "the next blink is %v s away", wait)
	ui.set_window_key(&u, false)
	run(&u, f, 1.4)
	testing.expect_value(t, ui.wake_after(&u), f32(0))
}

@(private = "file")
field_ui_destroy :: proc(u: ^ui.State) {
	delete(u.boxes)
	delete(u.table)
	delete(u.hits)
	free_all(context.temp_allocator)
}
