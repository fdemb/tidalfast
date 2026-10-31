package tidal_tests

import "core:testing"
import "core:unicode/utf8"

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
	ui.field_insert(f, "ab")
	// Typing that doesn't fit goes nowhere.
	ui.field_insert(f, "👍🏽cd")
	testing.expect_value(t, ui.field_text(f), "ab")
	// A paste is cut at a cluster boundary: the thumb and its tone are 8
	// bytes, which don't fit after "ab", so the cluster goes whole and the
	// rest after it too.
	ui.field_paste(f, "👍🏽cd")
	testing.expect_value(t, ui.field_text(f), "ab")
	ui.field_paste(f, "x\ny\tz\x01")
	testing.expect_value(t, ui.field_text(f), "abx y ")
}

// The field and the shell's mirror clean text the same way byte for byte.
// The outputs are what shell.m's field_sanitize printed for the same inputs
// (TIDALFAST_SHELL_TEST clean=...).
@(test)
test_edit_sanitize_table :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		input, out: string,
	}
	cases := []Case {
		{"CRLF", "a\r\nb", "a b"},
		{"lone CR", "a\rb", "a b"},
		{"tabs, leading dropped", "\ta\t\tb", "a b"},
		{"line break after a space", "a \nb", "a b"},
		{"U+2028 and U+2029", "a\u2028\u2029b", "a b"},
		{"NEL", "a\u0085b", "a b"},
		{"C1 controls", "a\u0080\u009fb", "ab"},
		{"C0 controls and DEL", "a\x01\x1b\x7fb", "ab"},
		{"U+FFFD", "a\ufffdb", "ab"},
		{"lone continuation byte", "a\x80b", "ab"},
		{"overlong NUL", "a\xc0\x80b", "ab"},
		{"encoded surrogate", "a\xed\xa0\x80b", "ab"},
		{"past U+10FFFF", "a\xf4\x90\x80\x80b", "ab"},
		{"F5", "a\xf5b", "ab"},
		{"lead byte then ASCII", "a\xe3ab", "aab"},
		{"cut short at the end", "a\xe3\x81", "a"},
		{"U+10FFFF", "a\U0010ffff", "a\U0010ffff"},
		{"ZWJ family", "👨‍👩‍👧", "👨‍👩‍👧"},
		{"combining acute", "Jo\u0301ga", "Jo\u0301ga"},
		{"a, ZWJ, woman", "a\u200d👩", "a\u200d👩"},
		{"bidi control stays", "\u202eabc", "\u202eabc"},
	}
	for c in cases {
		f := new(ui.Text_Field, context.temp_allocator)
		ui.field_paste(f, c.input)
		testing.expectf(t, ui.field_text(f) == c.out, "%s: %x became %x, want %x", c.name, transmute([]u8)c.input, transmute([]u8)ui.field_text(f), transmute([]u8)c.out)
	}
}

// The input method's edits go by rules the shell's mirror shares without
// segmenting text: a range by codepoint, and all or nothing at the limit.
@(test)
test_edit_ime_rules :: proc(t: ^testing.T) {
	// A range inside one codepoint is empty, and one end inside a cluster
	// stays there.
	f := field_with("x👍🏽y")
	ui.field_insert_at(f, 2, 3, "!")
	testing.expect_value(t, ui.field_text(f), "x!👍🏽y")
	f = field_with("x👍🏽y")
	ui.field_insert_at(f, len("x👍"), len("x👍🏽"), "!")
	testing.expect_value(t, ui.field_text(f), "x👍!y")
	testing.expect_value(t, f.cursor, len("x👍!"))
	// A range past the text is cut to it.
	f = field_with("ab")
	ui.field_insert_at(f, 1, 50, "c")
	testing.expect_value(t, ui.field_text(f), "ac")
	ui.field_set_marked(f, "d", 1, 1, 70, 90)
	testing.expect_value(t, ui.field_text(f), "acd")
	testing.expect_value(t, f.marked_start, 2)

	// The reviewer's case: 114 bytes and Z, the caret before Z, a limit of
	// 119. "a", ZWJ and 👩 are 8 bytes, which don't fit the 4 left, so none
	// of them goes in, and the next commit goes before Z.
	f = new(ui.Text_Field, context.temp_allocator)
	f.limit = 119
	head: [114]u8
	for &c in head {
		c = 'x'
	}
	ui.field_insert(f, string(head[:]))
	ui.field_insert(f, "Z")
	ui.field_move(f, -1, .Cluster, false)
	ui.field_set_marked(f, "a\u200d👩", 8, 8)
	testing.expect(t, !f.marked)
	testing.expect_value(t, f.len, 115)
	testing.expect_value(t, f.cursor, 114)
	// "ab👍" is 6 bytes: none of it, though "ab" would fit.
	ui.field_set_marked(f, "ab👍", 6, 6)
	testing.expect(t, !f.marked)
	testing.expect_value(t, f.len, 115)
	ui.field_insert(f, "Q")
	testing.expect_value(t, ui.field_text(f)[113:], "xQZ")
	// With 3 bytes left 👍 doesn't fit, 日 fits exactly, and then nothing.
	ui.field_insert(f, "👍")
	testing.expect_value(t, f.len, 116)
	ui.field_insert(f, "日")
	testing.expect_value(t, f.len, 119)
	ui.field_insert(f, "!")
	testing.expect_value(t, ui.field_text(f)[113:], "xQ日Z")

	// A commit that doesn't fit ends the composition as it was.
	f = new(ui.Text_Field, context.temp_allocator)
	f.limit = 4
	ui.field_set_marked(f, "あ", 3, 3)
	ui.field_insert(f, "日本")
	testing.expect_value(t, ui.field_text(f), "あ")
	testing.expect(t, !f.marked)
	testing.expect_value(t, f.cursor, 3)

	// The input method's selection is found in the text before cleaning,
	// so it's moved back to a codepoint of what's left.
	f = new(ui.Text_Field, context.temp_allocator)
	ui.field_set_marked(f, "\x01あい", 2, 2)
	testing.expect_value(t, ui.field_text(f), "あい")
	testing.expect_value(t, f.cursor, 0)
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
		sig := ui.text_field("search", f, "Search", ui.px(200), 30)
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
	sig = frame(&u, f, &now, bytes[:], text(bytes[:], 0, .Text, "日本語"), {kind = .Key_Down, key = .Left}, text(bytes[:], 16, .Text, "の"))
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
	sig = frame(&u, f, &now, bytes[:], {kind = .Key_Down, key = .Up}, {kind = .Key_Down, key = .Return})
	testing.expect(t, sig.submitted)
	testing.expect(t, sig.focused)
	testing.expect_value(t, f.cursor, 0)
	sig = frame(&u, f, &now, bytes[:], {kind = .Key_Down, key = .Escape})
	testing.expect_value(t, ui.field_text(f), "")
	sig = frame(&u, f, &now, bytes[:], {kind = .Key_Down, key = .Escape})
	testing.expect(t, sig.cancelled)
	sig = frame(&u, f, &now, bytes[:])
	testing.expect(t, !sig.focused)
	input, changed = ui.text_input(&u)
	testing.expect(t, changed)
	testing.expect(t, input.text == nil, "no field has the focus")
}

// Keys the focused field uses never reach the app. The rest wait for the
// app, matched on the exact modifiers, and each press goes to one caller.
@(test)
test_app_keys_after_text_field :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer field_ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	now := 0.0
	frame :: proc(u: ^ui.State, f: ^ui.Text_Field, now: ^f64, events: ..platform.Event) {
		now^ += 0.016
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		ui.text_field("search", f, "Search", ui.px(200), 30)
	}
	frame(&u, f, &now)
	ui.end_frame()
	frame(&u, f, &now, {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left})
	ui.end_frame()

	frame(&u, f, &now, {kind = .Key_Down, key = .Left}, {kind = .Key_Down, key = .Grave}, {kind = .Key_Down, key = .Digit_1, modifiers = {ui.PRIMARY}})
	testing.expect(t, !ui.take_key(.Left), "the field used Left")
	testing.expect(t, ui.take_key(.Grave))
	testing.expect(t, !ui.take_key(.Grave), "a press goes to one caller")
	testing.expect(t, !ui.take_key(.Digit_1), "modifiers must match")
	testing.expect(t, ui.take_key(.Digit_1, {ui.PRIMARY}))
	ui.end_frame()

	frame(&u, f, &now)
	testing.expect(t, !ui.take_key(.Digit_1, {ui.PRIMARY}), "presses last one frame")
	ui.end_frame()
}

// The shell's mirror applies text and marked text before the app sees
// them, so after the field takes any, the shell hears the field's state
// even when nothing changed: here a composition and a commit that don't
// fit a full field. The field's limit goes with it.
@(test)
test_text_field_resends_after_text :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer field_ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	f.limit = 119
	now := 0.0
	bytes: [64]u8
	frame :: proc(u: ^ui.State, f: ^ui.Text_Field, now: ^f64, bytes: []u8, events: ..platform.Event) {
		now^ += 0.016
		ui.begin_frame(u, events, nil, nil, 300, 200, now^, nil, bytes)
		b := ui.text_field("search", f, "Search", ui.px(200), 30)
		if !b.focused {
			ui.focus_text_field(b.box, f)
		}
		ui.end_frame()
	}
	frame(&u, f, &now, bytes[:])
	full_bytes: [119]u8
	for &c, i in full_bytes {
		c = '0' + u8(i % 10)
	}
	full := string(full_bytes[:])
	ui.field_set_text(f, full)
	frame(&u, f, &now, bytes[:])
	input, changed := ui.text_input(&u)
	testing.expect(t, changed)
	testing.expect_value(t, input.limit, u32(119))
	testing.expect_value(t, input.length, u32(119))

	copy(bytes[:], "に")
	frame(&u, f, &now, bytes[:], {kind = .Marked_Text, text_length = u32(len("に")), select_start = 3, select_end = 3})
	testing.expect_value(t, ui.field_text(f), full)
	testing.expect(t, !f.marked)
	input, changed = ui.text_input(&u)
	testing.expect(t, changed, "the shell hears the field after marked text it didn't take")
	testing.expect_value(t, input.marked_start, -1)
	testing.expect_value(t, input.selection_start, u32(119))
	testing.expect_value(t, input.selection_end, u32(119))

	frame(&u, f, &now, bytes[:], {kind = .Text, text_length = u32(len("に"))})
	_, changed = ui.text_input(&u)
	testing.expect(t, changed, "and after text it didn't take")
	frame(&u, f, &now, bytes[:])
	_, changed = ui.text_input(&u)
	testing.expect(t, !changed)
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
		b := ui.text_field("search", f, "Search", ui.px(200), 30)
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

@(test)
test_text_field_keeps_arrows_in_a_row :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer field_ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	ui.field_insert(f, "ab")
	now := 0.0
	frame :: proc(u: ^ui.State, f: ^ui.Text_Field, now: ^f64, events: ..platform.Event) -> ui.Field_Signal {
		now^ += 0.016
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		ui.row("bar", {}, ui.fill(), ui.px(30))
		sig := ui.text_field("search", f, "Search", ui.px(200), 30)
		ui.box_make("go", {.Clickable, .Focusable}, ui.px(40), ui.px(30))
		ui.end_frame()
		return sig
	}
	frame(&u, f, &now)
	frame(&u, f, &now)
	sig := frame(&u, f, &now, {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left})
	testing.expect(t, sig.focused)
	ui.field_move(f, 1, .Line, false)

	sig = frame(&u, f, &now, {kind = .Key_Down, key = .Left})
	testing.expect_value(t, f.cursor, 1)
	sig = frame(&u, f, &now, {kind = .Key_Down, key = .Right})
	testing.expect_value(t, f.cursor, 2)
	sig = frame(&u, f, &now, {kind = .Key_Down, key = .Right})
	sig = frame(&u, f, &now)
	testing.expect(t, sig.focused, "Right at the end stays in the field")
}

// A click after Cmd-F in the same frame places the caret: the field takes
// the shortcut's select-all and the press in the order they came.
@(test)
test_text_field_click_after_shortcut :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer field_ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	ui.field_insert(f, "hello world")
	now := 0.0
	frame :: proc(u: ^ui.State, f: ^ui.Text_Field, now: ^f64, events: ..platform.Event) {
		now^ += 0.016
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		b := ui.text_field("search", f, "Search", ui.px(200), 30)
		ui.focus_shortcut(b.box, .F, {ui.PRIMARY})
		ui.end_frame()
	}
	frame(&u, f, &now)
	frame(&u, f, &now)
	frame(&u, f, &now, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}}, {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left})
	lo, hi := ui.field_selection(f)
	testing.expectf(t, lo == hi && lo > 0, "the click placed the caret, selection [%d, %d)", lo, hi)

	// And the other way round, the shortcut after the click selects all.
	frame(&u, f, &now, {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left}, {kind = .Key_Down, key = .F, modifiers = {ui.PRIMARY}})
	lo, hi = ui.field_selection(f)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, len("hello world"))
}

// Escape in an empty field gives up the focus, and a click on the field
// later in the same frame takes it back. A click away after that still
// takes it away.
@(test)
test_text_field_click_after_escape :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer field_ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	now := 0.0
	frame :: proc(u: ^ui.State, f: ^ui.Text_Field, now: ^f64, events: ..platform.Event) -> ui.Field_Signal {
		now^ += 0.016
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		sig := ui.text_field("search", f, "Search", ui.px(200), 30)
		ui.end_frame()
		return sig
	}
	frame(&u, f, &now)
	frame(&u, f, &now)
	sig := frame(&u, f, &now, {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left})
	testing.expect(t, sig.focused)

	sig = frame(&u, f, &now, {kind = .Key_Down, key = .Escape}, {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left})
	testing.expect(t, sig.focused, "the click took the focus back")
	sig = frame(&u, f, &now)
	testing.expect(t, sig.focused, "and kept it")

	frame(&u, f, &now, {kind = .Key_Down, key = .Escape}, {kind = .Mouse_Down, x = 50, y = 15, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 15, button = .Left}, {kind = .Mouse_Down, x = 250, y = 100, button = .Left, click_count = 1}, {kind = .Mouse_Up, x = 250, y = 100, button = .Left})
	sig = frame(&u, f, &now)
	testing.expect(t, !sig.focused, "a click away after that took the focus")
}

// Word movement and double-click words land where a scan over every
// boundary does, from any byte offset, inside a cluster or past the end.
@(test)
test_edit_words_match_scan :: proc(t: ^testing.T) {
	is_word :: proc(s: string, at: int) -> bool {
		r, _ := utf8.decode_rune_in_string(s[at:])
		return ui.is_word_rune(r)
	}
	prev :: proc(bounds: []int, p: int) -> int {
		best := 0
		for b in bounds {
			if b >= p {
				break
			}
			best = b
		}
		return best
	}
	next :: proc(bounds: []int, p: int) -> int {
		for b in bounds {
			if b > p {
				return b
			}
		}
		return bounds[len(bounds) - 1]
	}
	for s in ([]string{"", "a", " ", "Paranoid Android, 1997", "a👨‍👩‍👧b, cé  d_e 12 ", "  夜に駆ける 밤편지", "عيونك حبيبي!", "e\u0301 yy", "\u1100\u1161 \u1100\u1161"}) {
		bounds := ui.cluster_bounds(s)
		for p in 0 ..= len(s) {
			left := p
			for left > 0 && !is_word(s, prev(bounds, left)) {
				left = prev(bounds, left)
			}
			for left > 0 && is_word(s, prev(bounds, left)) {
				left = prev(bounds, left)
			}
			testing.expectf(t, ui.word_left(s, bounds, p) == left, "%q word_left(%d) = %d, want %d", s, p, ui.word_left(s, bounds, p), left)

			at := 0
			for b in bounds[:len(bounds) - 1] {
				if b <= p {
					at = b
				}
			}
			right := at
			for right < len(s) && !is_word(s, right) {
				right = next(bounds, right)
			}
			for right < len(s) && is_word(s, right) {
				right = next(bounds, right)
			}
			testing.expectf(t, ui.word_right(s, bounds, p) == right, "%q word_right(%d) = %d, want %d", s, p, ui.word_right(s, bounds, p), right)

			if len(s) == 0 {
				continue
			}
			word := is_word(s, at)
			lo, hi := at, next(bounds, at)
			for lo > 0 && is_word(s, prev(bounds, lo)) == word {
				lo = prev(bounds, lo)
			}
			for hi < len(s) && is_word(s, hi) == word {
				hi = next(bounds, hi)
			}
			got_lo, got_hi := ui.word_at(s, bounds, p)
			testing.expectf(t, got_lo == lo && got_hi == hi, "%q word_at(%d) = [%d, %d), want [%d, %d)", s, p, got_lo, got_hi, lo, hi)
		}
	}
}
