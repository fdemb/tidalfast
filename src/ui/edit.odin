// The editing model behind text_field: a single line of UTF-8 in a fixed
// buffer, a cursor and an anchor for the selection, the input method's
// marked text, and undo. It is plain data and does no drawing, so it lives
// in the app's State and the tests drive it directly.
//
// Every offset is in bytes and sits on a grapheme cluster boundary, from
// src/text's segmentation, so nothing here splits a cluster or a codepoint.
// The one exception is the input method's: the shell's mirror of the field
// applies its edits before the app does and can't segment text as the app
// does, so both take them by rules that need no segmentation. A
// replacement range is clamped to the text and its ends moved back to the
// start of a codepoint, and an edit that doesn't fit the limit is refused
// whole. An input method that replaces part of a cluster leaves the cursor
// inside one.
package ui

import "core:slice"
import "core:unicode"
import "core:unicode/utf8"

import "../text"

FIELD_CAPACITY :: 2048 // a TIDAL login redirect address fits
UNDO_DEPTH :: 32

Edit_Kind :: enum u8 {
	None, // the last change wasn't an edit, so the next one starts an undo step
	Typing,
	Delete_Backward,
	Delete_Forward,
	Other,
}

Field_Snapshot :: struct {
	buf:            [FIELD_CAPACITY]u8,
	len:            int,
	cursor, anchor: int,
}

Text_Field :: struct {
	buf:          [FIELD_CAPACITY]u8,
	len:          int,
	limit:        int, // most bytes the field takes, 0 for FIELD_CAPACITY
	cursor:       int, // where typing goes
	anchor:       int, // the other end of the selection, cursor when there is none
	marked:       bool,
	marked_start: int, // the marked text, while marked
	marked_end:   int,
	undo:         [UNDO_DEPTH]Field_Snapshot,
	undo_count:   int,
	redo:         [UNDO_DEPTH]Field_Snapshot,
	redo_count:   int,
	last_edit:    Edit_Kind,

	// The widget's, kept with the text.
	scroll:       f32, // points the text is moved left by
	blink_start:  f64, // the caret shows from here for half a blink
	had_focus:    bool,
	drag:         Drag_Mode,
	drag_origin:  [2]int, // the word a double-click drag started from
}

Drag_Mode :: enum u8 {
	Clusters,
	Words, // after a double-click
	None, // after a triple-click, which selected everything
}

Move_Unit :: enum u8 {
	Cluster,
	Word,
	Line,
}

field_text :: proc(f: ^Text_Field) -> string {
	return string(f.buf[:f.len])
}

field_limit :: proc(f: ^Text_Field) -> int {
	return f.limit if f.limit > 0 && f.limit < FIELD_CAPACITY else FIELD_CAPACITY
}

// field_selection is the selection in order. lo == hi when there is none.
field_selection :: proc(f: ^Text_Field) -> (lo, hi: int) {
	return min(f.cursor, f.anchor), max(f.cursor, f.anchor)
}

field_selected :: proc(f: ^Text_Field) -> string {
	lo, hi := field_selection(f)
	return string(f.buf[lo:hi])
}

// field_set_text replaces everything, with the cursor at the end, as one
// undo step.
field_set_text :: proc(f: ^Text_Field, s: string) {
	field_unmark(f)
	f.anchor, f.cursor = 0, f.len
	replace(f, 0, f.len, s, .Other)
}

// field_clear empties the field as one undo step.
field_clear :: proc(f: ^Text_Field) {
	if f.len > 0 || f.marked {
		field_set_text(f, "")
	}
}

// Boundaries

// cluster_bounds returns the byte offset of each grapheme cluster's start
// in s, then len(s).
cluster_bounds :: proc(s: string, allocator := context.temp_allocator) -> []int {
	runes := make([dynamic]rune, 0, len(s), context.temp_allocator)
	offsets := make([dynamic]int, 0, len(s) + 1, context.temp_allocator)
	for r, i in s {
		append(&runes, r)
		append(&offsets, i)
	}
	starts := text.grapheme_starts(runes[:])
	bounds := make([dynamic]int, 0, len(runes) + 1, allocator)
	for start, i in starts {
		if start == i {
			append(&bounds, offsets[i])
		}
	}
	append(&bounds, len(s))
	return bounds[:]
}

@(private)
prev_bound :: proc(bounds: []int, p: int) -> int {
	best := 0
	for b in bounds {
		if b >= p {
			break
		}
		best = b
	}
	return best
}

@(private)
next_bound :: proc(bounds: []int, p: int) -> int {
	for b in bounds {
		if b > p {
			return b
		}
	}
	return bounds[len(bounds) - 1]
}

// snap_down moves p back to the start of the cluster it's in.
@(private)
snap_down :: proc(bounds: []int, p: int) -> int {
	best := 0
	for b in bounds {
		if b > p {
			break
		}
		best = b
	}
	return best
}

// is_word_rune says whether r belongs to a word for word movement: letters
// and digits. A cluster counts by its first codepoint, so marks go with
// their base. Everything else separates words.
is_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || unicode.is_number(r) || r == '_'
}

@(private)
cluster_is_word :: proc(s: string, start: int) -> bool {
	r, _ := utf8.decode_rune_in_string(s[start:])
	return is_word_rune(r)
}

// word_left is where Option-Left goes from p: back over separators, then
// to the start of the word before them.
word_left :: proc(s: string, bounds: []int, p: int) -> int {
	i, _ := slice.binary_search(bounds, p)
	for i > 0 && !cluster_is_word(s, bounds[i - 1]) {
		i -= 1
	}
	for i > 0 && cluster_is_word(s, bounds[i - 1]) {
		i -= 1
	}
	return bounds[i]
}

// word_right is where Option-Right goes from p: over separators, then to
// the end of the word after them.
word_right :: proc(s: string, bounds: []int, p: int) -> int {
	i, found := slice.binary_search(bounds, p)
	if !found {
		i -= 1
	}
	last := len(bounds) - 1
	for i < last && !cluster_is_word(s, bounds[i]) {
		i += 1
	}
	for i < last && cluster_is_word(s, bounds[i]) {
		i += 1
	}
	return bounds[i]
}

// word_at is the run of word or separator clusters around p, for a
// double-click.
word_at :: proc(s: string, bounds: []int, p: int) -> (lo, hi: int) {
	if len(s) == 0 {
		return 0, 0
	}
	i, found := slice.binary_search(bounds, p)
	if !found {
		i -= 1
	}
	i = min(i, len(bounds) - 2)
	word := cluster_is_word(s, bounds[i])
	a, z := i, i + 1
	for a > 0 && cluster_is_word(s, bounds[a - 1]) == word {
		a -= 1
	}
	for bounds[z] < len(s) && cluster_is_word(s, bounds[z]) == word {
		z += 1
	}
	return bounds[a], bounds[z]
}

// Movement

// field_move moves the cursor by unit, left (dir < 0) or right, in logical
// order. extend keeps the anchor, as Shift does. Without extend, a
// selection collapses to the side moved toward.
field_move :: proc(f: ^Text_Field, dir: int, unit: Move_Unit, extend: bool) {
	if f.marked {
		return
	}
	s := field_text(f)
	bounds := cluster_bounds(s)
	lo, hi := field_selection(f)
	p := f.cursor
	switch unit {
	case .Cluster:
		if !extend && lo != hi {
			p = lo if dir < 0 else hi
		} else {
			p = prev_bound(bounds, p) if dir < 0 else next_bound(bounds, p)
		}
	case .Word:
		if !extend && lo != hi {
			p = lo if dir < 0 else hi
		}
		p = word_left(s, bounds, p) if dir < 0 else word_right(s, bounds, p)
	case .Line:
		p = 0 if dir < 0 else f.len
	}
	f.cursor = p
	if !extend {
		f.anchor = p
	}
	f.last_edit = .None
}

field_select_all :: proc(f: ^Text_Field) {
	if f.marked {
		return
	}
	f.anchor, f.cursor = 0, f.len
	f.last_edit = .None
}

// field_place puts the cursor at p, snapped to a cluster boundary, keeping
// the anchor if extend.
field_place :: proc(f: ^Text_Field, p: int, extend: bool) {
	bounds := cluster_bounds(field_text(f))
	f.cursor = snap_down(bounds, clamp(p, 0, f.len))
	if !extend {
		f.anchor = f.cursor
	}
	f.last_edit = .None
}

field_select_word :: proc(f: ^Text_Field, p: int) {
	s := field_text(f)
	f.anchor, f.cursor = word_at(s, cluster_bounds(s), p)
	f.last_edit = .None
}

// Editing

// field_insert types s, as from the input method: it replaces the marked
// text, or else the selection. Line breaks become spaces and other control
// characters go. If the text doesn't fit the limit nothing goes in, and a
// composition ends as it was.
field_insert :: proc(f: ^Text_Field, s: string) {
	lo, hi := field_selection(f)
	if f.marked {
		lo, hi = f.marked_start, f.marked_end
	}
	field_insert_at(f, lo, hi, s)
}

// field_insert_at types s in place of bytes [from, to), an input method's
// replacement range, as field_insert does. It ends any marked text.
field_insert_at :: proc(f: ^Text_Field, from, to: int, s: string) {
	lo, hi := ime_range(f, from, to)
	clean := sanitize(s)
	if len(clean) > field_limit(f) - (f.len - (hi - lo)) {
		field_unmark(f)
		return
	}
	was_marked := f.marked
	f.marked = false
	// Committing a composition finishes the typing step it started.
	kind := Edit_Kind.Typing
	if was_marked {
		f.last_edit = .Typing
	}
	replace(f, lo, hi, clean, kind)
}

// field_set_marked sets the input method's composition. It replaces the
// marked text, or else the selection, or [replace_lo, replace_hi) when
// given. select_lo and select_hi are the input method's selection inside s,
// in bytes of s as given. Empty s removes the marked text and ends the
// composition. If the text doesn't fit the limit nothing changes.
field_set_marked :: proc(f: ^Text_Field, s: string, select_lo, select_hi: int, replace_lo := -1, replace_hi := -1) {
	lo, hi := field_selection(f)
	if f.marked {
		lo, hi = f.marked_start, f.marked_end
	}
	if replace_lo >= 0 {
		lo, hi = ime_range(f, replace_lo, replace_hi)
	}
	clean := sanitize(s)
	if len(clean) > field_limit(f) - (f.len - (hi - lo)) {
		return
	}
	// A composition starts an undo step and stays in it until committed.
	if !f.marked && f.last_edit != .Typing {
		push_undo(f)
		f.redo_count = 0
	}
	splice(f, lo, hi, clean)
	f.last_edit = .Typing
	if len(clean) == 0 {
		f.marked = false
		f.cursor, f.anchor = lo, lo
		return
	}
	f.marked = true
	f.marked_start, f.marked_end = lo, lo + len(clean)
	// The selection was found in s before cleaning, so it may fall inside a
	// codepoint of what's left.
	sel_lo := clamp(select_lo, 0, len(clean))
	sel_hi := clamp(max(select_hi, select_lo), 0, len(clean))
	f.anchor = lo + rune_start(clean, sel_lo)
	f.cursor = lo + rune_start(clean, sel_hi)
}

// ime_range is an input method's replacement range [from, to) clamped to
// the text, with each end moved back to the start of its codepoint. The
// shell's mirror does the same.
@(private)
ime_range :: proc(f: ^Text_Field, from, to: int) -> (lo, hi: int) {
	s := field_text(f)
	lo = rune_start(s, clamp(from, 0, f.len))
	hi = rune_start(s, clamp(to, 0, f.len))
	return lo, max(lo, hi)
}

// rune_start moves p back to the start of the UTF-8 sequence it's in.
@(private)
rune_start :: proc(s: string, p: int) -> int {
	p := p
	for p > 0 && p < len(s) && s[p] & 0xc0 == 0x80 {
		p -= 1
	}
	return p
}

// field_unmark keeps the marked text as typed and ends the composition,
// with the cursor after it.
field_unmark :: proc(f: ^Text_Field) {
	if !f.marked {
		return
	}
	f.marked = false
	f.cursor, f.anchor = f.marked_end, f.marked_end
}

// field_delete deletes the selection, or else from the cursor back (dir <
// 0) or forward by one unit: a cluster, to the edge of a word, or to the
// start or end of the line.
field_delete :: proc(f: ^Text_Field, dir: int, unit: Move_Unit) {
	if f.marked {
		return
	}
	lo, hi := field_selection(f)
	kind := Edit_Kind.Delete_Backward if dir < 0 else .Delete_Forward
	if lo == hi {
		s := field_text(f)
		bounds := cluster_bounds(s)
		p := f.cursor
		switch unit {
		case .Cluster:
			if dir < 0 {
				lo = prev_bound(bounds, p)
			} else {
				hi = next_bound(bounds, p)
			}
		case .Word:
			if dir < 0 {
				lo = word_left(s, bounds, p)
			} else {
				hi = word_right(s, bounds, p)
			}
			kind = .Other
		case .Line:
			if dir < 0 {
				lo = 0
			} else {
				hi = f.len
			}
			kind = .Other
		}
	} else {
		kind = .Other
	}
	if lo == hi {
		return
	}
	replace(f, lo, hi, "", kind)
}

// field_cut deletes the selection and returns it, valid until the next
// edit's temp memory goes.
field_cut :: proc(f: ^Text_Field) -> string {
	if f.marked {
		return ""
	}
	lo, hi := field_selection(f)
	if lo == hi {
		return ""
	}
	cut := clone_temp(string(f.buf[lo:hi]))
	replace(f, lo, hi, "", .Other)
	return cut
}

// field_paste inserts s as one undo step of its own.
field_paste :: proc(f: ^Text_Field, s: string) {
	if f.marked {
		return
	}
	lo, hi := field_selection(f)
	replace(f, lo, hi, sanitize(s), .Other)
}

field_can_undo :: proc(f: ^Text_Field) -> bool {
	return f.undo_count > 0 && !f.marked
}

field_undo :: proc(f: ^Text_Field) -> bool {
	if !field_can_undo(f) {
		return false
	}
	f.undo_count -= 1
	push_snapshot(&f.redo, &f.redo_count, snapshot(f))
	restore(f, f.undo[f.undo_count])
	return true
}

field_redo :: proc(f: ^Text_Field) -> bool {
	if f.redo_count == 0 || f.marked {
		return false
	}
	f.redo_count -= 1
	push_snapshot(&f.undo, &f.undo_count, snapshot(f))
	restore(f, f.redo[f.redo_count])
	return true
}

// replace puts s in place of [lo, hi) as an edit of kind. Typing right
// after typing at the same place, or deleting after deleting, joins the
// undo step before it; anything else starts a new one.
@(private)
replace :: proc(f: ^Text_Field, lo, hi: int, with: string, kind: Edit_Kind) {
	room := field_limit(f) - (f.len - (hi - lo))
	s := fit(with, room)
	if lo == hi && len(s) == 0 {
		return
	}
	coalesce := kind != .Other && kind == f.last_edit
	if !coalesce {
		push_undo(f)
	}
	f.redo_count = 0
	splice(f, lo, hi, s)
	f.cursor = lo + len(s)
	f.anchor = f.cursor
	f.last_edit = kind
}

@(private)
splice :: proc(f: ^Text_Field, lo, hi: int, s: string) {
	tail := f.len - hi
	copy(f.buf[lo + len(s):], f.buf[hi:f.len])
	copy(f.buf[lo:], s)
	f.len = lo + len(s) + tail
}

// fit cuts s to at most room bytes on a cluster boundary.
@(private)
fit :: proc(s: string, room: int) -> string {
	if len(s) <= room {
		return s
	}
	if room <= 0 {
		return ""
	}
	return s[:snap_down(cluster_bounds(s), room)]
}

// sanitize makes s one line: a run of line breaks and tabs (LF, CR, tab,
// NEL, U+2028, U+2029) becomes one space, or none at the start, and the
// other C0 and C1 controls, DEL, U+FFFD and invalid UTF-8 go, an invalid
// byte at a time as utf8.decode_rune reads them. the shell's field_sanitize (common.c)
// does the same byte for byte.
@(private)
sanitize :: proc(s: string) -> string {
	drop :: proc(r: rune) -> bool {
		return r < 0x20 || (r >= 0x7f && r <= 0x9f) || r == utf8.RUNE_ERROR || r == 0x2028 || r == 0x2029
	}
	clean := true
	for r in s {
		if drop(r) {
			clean = false
			break
		}
	}
	if clean {
		return s
	}
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for r in s {
		switch {
		case r == '\n' || r == '\r' || r == '\t' || r == 0x85 || r == 0x2028 || r == 0x2029:
			if len(out) > 0 && out[len(out) - 1] != ' ' {
				append(&out, ' ')
			}
		case drop(r):
		case:
			bytes, n := utf8.encode_rune(r)
			append(&out, ..bytes[:n])
		}
	}
	return string(out[:])
}

@(private)
clone_temp :: proc(s: string) -> string {
	out := make([]u8, len(s), context.temp_allocator)
	copy(out, s)
	return string(out)
}

@(private)
snapshot :: proc(f: ^Text_Field) -> Field_Snapshot {
	return {buf = f.buf, len = f.len, cursor = f.cursor, anchor = f.anchor}
}

@(private)
restore :: proc(f: ^Text_Field, s: Field_Snapshot) {
	f.buf = s.buf
	f.len = s.len
	f.cursor, f.anchor = s.cursor, s.anchor
	f.marked = false
	f.last_edit = .None
}

@(private)
push_undo :: proc(f: ^Text_Field) {
	push_snapshot(&f.undo, &f.undo_count, snapshot(f))
}

// push_snapshot adds s to a stack, dropping the oldest when it's full.
@(private)
push_snapshot :: proc(stack: ^[UNDO_DEPTH]Field_Snapshot, count: ^int, s: Field_Snapshot) {
	if count^ == UNDO_DEPTH {
		copy(stack[:], stack[1:])
		count^ -= 1
	}
	stack[count^] = s
	count^ += 1
}
