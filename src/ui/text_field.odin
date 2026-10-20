package ui

import "core:slice"
import "core:unicode/utf8"

import "../platform"
import "../render"
import "../text"

BLINK_SECONDS :: 0.53
FIELD_PAD :: 8
CLIPBOARD_MAX :: 64 << 10

Field_Signal :: struct {
	box:            ^Box,
	focused:        bool,
	changed:        bool, // the text changed this frame
	submitted:      bool, // Return
	submitted_text: string, // the text when Return was pressed, this frame's
	cancelled:      bool, // Escape in an empty field, which gave up the focus
}

// Field_Layout is where each grapheme cluster of a field's text is drawn.
Field_Layout :: struct {
	bounds: []int, // byte offset of each cluster's start, then the length
	x0, x1: []f32, // each cluster's left and right edge, points from the run's left
	rtl:    []bool, // the cluster reads right to left
	width:  f32,
}

// text_field is a single-line text field editing f. It takes the focus
// when clicked; with the focus it takes typing and the input method's
// marked text from the shell, the editing keys, the clipboard and undo, and
// draws the caret, which blinks with a timer while the window has the
// keyboard. The text scrolls sideways to keep the caret in view.
text_field :: proc(id: string, f: ^Text_Field, placeholder: string, width, height: Size) -> (sig: Field_Signal) {
	u := ctx
	b := box_make(id, {.Clickable, .Focusable, .Text_Input, .Draw_Background, .Draw_Border, .Clip}, width, height)
	b.text_pad = FIELD_PAD
	b.radius = 6
	s := signal(b)
	sig.box = b
	focused := b.key != 0 && u.focus == b.key
	sig.focused = focused
	old := clone_temp(field_text(f))
	font, size := u.font, u.font_size

	if focused && !f.had_focus {
		f.blink_start = u.time
		// Tabbing in selects everything, as in a Mac text field.
		if u.focus_visible {
			field_select_all(f)
		}
	}
	f.had_focus = focused

	// The mouse goes by where the text was drawn.
	origin := b.rect.x + FIELD_PAD - f.scroll

	// The frame's edits for this field, in order. They were queued while it
	// had the focus, so text typed before a Tab still goes in. After Escape
	// gives up the focus, the rest are dropped until a focus or a click for
	// this field.
	live := true
	for e in u.edits[:u.edit_count] {
		if e.target != b.key || b.key == 0 {
			continue
		}
		if !live {
			if e.op != .Focus && e.op != .Press {
				continue
			}
			live = true
		}
		switch e.op {
		case .Focus:
			if e.select_all {
				field_select_all(f)
			}
		case .Blur:
			field_unmark(f)
		case .Key:
			used, gave_up := field_key(u, f, e.key, &sig)
			if used {
				take_key(e.key.code, e.key.modifiers)
			}
			live = !gave_up
		case .Text:
			u.text_resend = true
			if e.replace {
				field_insert_at(f, e.replace_lo, e.replace_hi, e.text)
			} else {
				field_insert(f, e.text)
			}
		case .Marked_Text:
			u.text_resend = true
			if e.replace {
				field_set_marked(f, e.text, e.select_lo, e.select_hi, e.replace_lo, e.replace_hi)
			} else {
				field_set_marked(f, e.text, e.select_lo, e.select_hi)
			}
		case .Unmark_Text:
			u.text_resend = true
			field_unmark(f)
		case .Press:
			field_unmark(f)
			// This hit-tests the text as the batch's earlier edits left it, at
			// last frame's scroll. Typing and a click rarely share a frame.
			// When they do, the caret still lands near the click.
			p := field_hit(field_layout(u.texts, font, size, field_text(f)), e.pos.x - origin)
			switch {
			case e.click_count >= 3:
				field_select_all(f)
				f.drag = .None
			case e.click_count == 2:
				field_select_word(f, p)
				f.drag = .Words
				f.drag_origin = {f.anchor, f.cursor}
			case:
				field_place(f, p, e.extend)
				f.drag = .Clusters
			}
		}
		f.blink_start = u.time
	}
	if !live && u.focus == b.key {
		u.focus = 0
	}
	focused = b.key != 0 && u.focus == b.key
	sig.focused = focused
	if !focused {
		field_unmark(f)
	}
	f.had_focus = focused
	t := field_text(f)
	sig.changed = t != old

	lay := field_layout(u.texts, font, size, t)
	if focused && s.held {
		if s.dragging && !s.pressed {
			p := field_hit(lay, u.input.mouse.x - origin)
			switch f.drag {
			case .Clusters:
				field_place(f, p, true)
			case .Words:
				lo, hi := word_at(t, lay.bounds, p)
				a, z := min(lo, f.drag_origin[0]), max(hi, f.drag_origin[1])
				f.anchor, f.cursor = a, z
				if p < f.drag_origin[0] {
					f.anchor, f.cursor = z, a
				}
			case .None:
			}
		}
		f.blink_start = u.time
	}
	avail := b.rect.w - 2 * FIELD_PAD
	caret := field_caret_x(lay, f.cursor)
	if !focused {
		f.scroll = 0
	} else if avail > 0 {
		if caret - f.scroll > avail - 1 {
			f.scroll = caret - avail + 1
		}
		if caret < f.scroll {
			f.scroll = caret
		}
	}
	f.scroll = clamp(f.scroll, 0, max(lay.width + 1 - avail, 0))

	shown := clone_temp(t)
	accessible(b, .Text_Field, placeholder, shown)
	field_draw(u, b, f, lay, placeholder, shown, focused, caret)

	if focused {
		line_h := field_line_height(u, font, size)
		ty := (field_height(b) - line_h) / 2
		cx, cw := caret, f32(0)
		if f.marked {
			spans := field_spans(lay, f.marked_start, f.marked_end)
			if len(spans) > 0 {
				cx = spans[0].x
				cw = spans[len(spans) - 1].y - cx
			}
		}
		lo, hi := field_selection(f)
		bytes := make([]u8, max(len(t), 1), context.temp_allocator)
		copy(bytes, t)
		u.text_claimed = true
		u.text_input = {
			text            = raw_data(bytes),
			length          = u32(len(t)),
			selection_start = u32(lo),
			selection_end   = u32(hi),
			marked_start    = i32(f.marked_start) if f.marked else -1,
			marked_end      = i32(f.marked_end) if f.marked else -1,
			limit           = u32(field_limit(f)),
			caret           = {b.rect.x + FIELD_PAD - f.scroll + cx, b.rect.y + ty, cw, line_h},
		}
	}
	return
}

// focus_shortcut makes the key code with modifiers give the text field b
// the focus with its text selected, as Cmd-F does. It takes effect at its
// place among the next frame's events, so keys and text after it go to the
// field. Call it every frame, after text_field.
focus_shortcut :: proc(b: ^Box, code: platform.Key, modifiers: platform.Modifiers) {
	u := ctx
	if b.key != 0 && u.shortcut_count < MAX_SHORTCUTS {
		u.shortcuts[u.shortcut_count] = {{code, modifiers}, b.key}
		u.shortcut_count += 1
	}
}

// focus_text_field gives b, a text field built for f, the focus with all
// of its text selected, right away.
focus_text_field :: proc(b: ^Box, f: ^Text_Field) {
	u := ctx
	if b.key == 0 {
		return
	}
	u.focus = b.key
	u.focus_visible = false
	field_select_all(f)
	f.blink_start = u.time
	f.had_focus = true
	u.animating = true
}

// field_key applies one key press, reporting whether the field used it and
// whether it gave up the focus. On macOS Control-A and Control-E also go
// to the line's ends (CONTROL_LINE_KEYS).
@(private)
field_key :: proc(u: ^State, f: ^Text_Field, k: Key_Press, sig: ^Field_Signal) -> (used, gave_up: bool) {
	shift := .Shift in k.modifiers
	base := k.modifiers - {.Shift}
	#partial switch k.code {
	case .Left, .Right:
		dir := -1 if k.code == .Left else 1
		switch base {
		case {}:
			field_move(f, dir, .Cluster, shift)
		case {WORD}:
			field_move(f, dir, .Word, shift)
		case {LINE}:
			field_move(f, dir, .Line, shift)
		case:
			return
		}
	case .Up, .Home, .Down, .End:
		if base != {} && base != {LINE} {
			return
		}
		field_move(f, -1 if k.code == .Up || k.code == .Home else 1, .Line, shift)
	case .Backspace, .Delete:
		dir := -1 if k.code == .Backspace else 1
		switch k.modifiers {
		case {}, {.Shift}:
			field_delete(f, dir, .Cluster)
		case {WORD}:
			field_delete(f, dir, .Word)
		case {LINE}:
			field_delete(f, dir, .Line)
		case:
			return
		}
	case .A:
		switch {
		case k.modifiers == {PRIMARY}:
			field_select_all(f)
		case CONTROL_LINE_KEYS && base == {.Control}:
			field_move(f, -1, .Line, shift)
		case:
			return
		}
	case .E:
		if !CONTROL_LINE_KEYS || base != {.Control} {
			return
		}
		field_move(f, 1, .Line, shift)
	case .C, .X:
		if k.modifiers != {PRIMARY} {
			return
		}
		sel := field_selected(f) if k.code == .C else field_cut(f)
		if sel != "" && u.clipboard_set != nil && !f.marked {
			u.clipboard_set(raw_data(sel), uint(len(sel)))
		}
	case .V:
		if k.modifiers != {PRIMARY} {
			return
		}
		if u.clipboard_get != nil {
			n := min(int(u.clipboard_get(nil, 0)), CLIPBOARD_MAX)
			if n > 0 {
				buf := make([]u8, n, context.temp_allocator)
				n = min(int(u.clipboard_get(raw_data(buf), uint(n))), n)
				field_paste(f, string(buf[:n]))
			}
		}
	case .Z:
		switch k.modifiers {
		case {PRIMARY}:
			field_undo(f)
		case {PRIMARY, .Shift}:
			field_redo(f)
		case:
			return
		}
	case .Return, .Keypad_Enter:
		if k.modifiers != {} {
			return
		}
		sig.submitted = true
		sig.submitted_text = clone_temp(field_text(f))
	case .Escape:
		if k.modifiers != {} {
			return
		}
		if f.len > 0 || f.marked {
			field_clear(f)
		} else {
			sig.cancelled = true
			gave_up = true
		}
	case:
		return
	}
	used = true
	return
}

@(private)
field_line_height :: proc(u: ^State, font: text.Font, size: f32) -> f32 {
	return text.line_height(u.texts, font, size) if u.texts != nil else size * 1.25
}

// field_height is the field's height this frame: its own size if it has
// one, else last frame's.
@(private)
field_height :: proc(b: ^Box) -> f32 {
	return b.pref_size[.Y].value if b.pref_size[.Y].kind == .Pixels else b.rect.h
}

// field_draw builds the field's insides as floating boxes: the selection,
// the text or the placeholder, the marked text's underline and the caret.
@(private)
field_draw :: proc(u: ^State, b: ^Box, f: ^Text_Field, lay: Field_Layout, placeholder, shown: string, focused: bool, caret: f32) {
	push_parent(b)
	defer pop_parent()
	line_h := field_line_height(u, b.font, b.font_size)
	ty := (field_height(b) - line_h) / 2
	x := FIELD_PAD - f.scroll
	piece :: proc(pos, size: [2]f32, color: render.Color) -> ^Box {
		p := box_make("", {.Floating_X, .Floating_Y, .Draw_Background}, px(size.x), px(size.y))
		p.fixed_pos = pos
		p.background = color
		return p
	}

	lo, hi := field_selection(f)
	if focused && lo != hi && !f.marked {
		color := render.Color{ACCENT.r, ACCENT.g, ACCENT.b, 0.35} if !u.window_inactive else render.Color{1, 1, 1, 0.16}
		for span in field_spans(lay, lo, hi) {
			piece({x + span.x, ty}, {span.y - span.x, line_h}, color)
		}
	}

	label := box_make("", {.Floating_X, .Floating_Y, .Draw_Text}, px(lay.width + 2), px(line_h))
	label.fixed_pos = {x, ty}
	if shown == "" {
		label.label = placeholder
		label.fixed_pos.x = FIELD_PAD
		label.pref_size[.X] = px(max(b.rect.w - 2 * FIELD_PAD, 0))
		label.text_color.a *= 0.45
	} else {
		label.label = shown
	}
	label.id = label.label

	if f.marked {
		// A thin line under the composition and a thick one under the part
		// the input method has selected, as AppKit draws them.
		for span in field_spans(lay, f.marked_start, f.marked_end) {
			piece({x + span.x, ty + line_h - 1}, {span.y - span.x, 1}, b.text_color)
		}
		if lo != hi {
			for span in field_spans(lay, lo, hi) {
				piece({x + span.x, ty + line_h - 2}, {span.y - span.x, 2}, b.text_color)
			}
		}
	}

	if focused && !u.window_inactive {
		since := max(u.time - f.blink_start, 0)
		phase := int(since / BLINK_SECONDS)
		if phase % 2 == 0 {
			piece({x + caret - 0.75, ty - 1}, {1.5, line_h + 2}, ACCENT)
		}
		wake_at(f.blink_start + f64(phase + 1) * BLINK_SECONDS)
	}
}

// Geometry

// field_layout finds where each grapheme cluster of s is drawn. A cluster
// with no glyph of its own, as inside a ligature, shares the glyph before
// it in equal parts. Without a text system (in tests) every x is 0.
field_layout :: proc(t: ^text.State, font: text.Font, size: f32, s: string) -> (lay: Field_Layout) {
	lay.bounds = cluster_bounds(s)
	n := len(lay.bounds) - 1
	lay.x0 = make([]f32, n, context.temp_allocator)
	lay.x1 = make([]f32, n, context.temp_allocator)
	lay.rtl = make([]bool, n, context.temp_allocator)
	if t == nil || n == 0 {
		return
	}
	run := text.shape(t, font, size, s)
	lay.width = run.width
	cp_cluster := make([]int, utf8.rune_count_in_string(s), context.temp_allocator)
	{
		k, ci := 0, 0
		for _, off in s {
			for k + 1 < n && lay.bounds[k + 1] <= off {
				k += 1
			}
			cp_cluster[ci] = k
			ci += 1
		}
	}
	has := make([]bool, n, context.temp_allocator)
	order := make([dynamic]int, 0, n, context.temp_allocator) // clusters with a glyph, left to right
	for g in run.glyphs {
		c := int(g.cluster)
		if c >= len(cp_cluster) {
			continue
		}
		j := cp_cluster[c]
		if !has[j] {
			lay.x0[j], lay.x1[j] = g.pen, g.pen + g.advance
			has[j] = true
			append(&order, j)
		} else {
			lay.x0[j] = min(lay.x0[j], g.pen)
			lay.x1[j] = max(lay.x1[j], g.pen + g.advance)
		}
	}
	// A letter reads in its script's direction. Any other cluster reads
	// the way of its neighbours on screen: left to right when the next
	// cluster in the text is drawn just to its right, right to left when
	// just to its left, and else the paragraph's way.
	next := make([]int, n, context.temp_allocator)
	following := -1
	for k := n - 1; k >= 0; k -= 1 {
		next[k] = following
		if has[k] {
			following = k
		}
	}
	strong := make([]bool, n, context.temp_allocator)
	for k in 0 ..< n {
		lay.rtl[k] = run.rtl
		r, _ := utf8.decode_rune_in_string(s[lay.bounds[k]:])
		#partial switch text.bidi_class(r) {
		case .L:
			lay.rtl[k], strong[k] = false, true
		case .R, .AL:
			lay.rtl[k], strong[k] = true, true
		}
	}
	for i in 1 ..< len(order) {
		l, r := order[i - 1], order[i]
		rtl: bool
		switch {
		case next[l] == r:
			rtl = false
		case next[r] == l:
			rtl = true
		case:
			continue
		}
		if !strong[l] {
			lay.rtl[l] = rtl
		}
		if !strong[r] {
			lay.rtl[r] = rtl
		}
	}
	for k := 0; k < n; {
		if !has[k] {
			lay.rtl[k] = run.rtl
			k += 1
			continue
		}
		m := k + 1
		for m < n && !has[m] {
			m += 1
		}
		parts := f32(m - k)
		x0, w := lay.x0[k], (lay.x1[k] - lay.x0[k]) / parts
		for j in k ..< m {
			i := f32(j - k)
			if lay.rtl[k] {
				i = parts - 1 - i
			}
			lay.x0[j], lay.x1[j] = x0 + i * w, x0 + (i + 1) * w
			lay.rtl[j] = lay.rtl[k]
		}
		k = m
	}
	return
}

@(private)
cluster_of :: proc(lay: Field_Layout, p: int) -> int {
	k := 0
	for b, i in lay.bounds[:len(lay.bounds) - 1] {
		if b > p {
			break
		}
		k = i
	}
	return k
}

// field_caret_x is the caret's x for byte offset p, from the run's left:
// the leading edge of the cluster at p, or the trailing edge of the last.
field_caret_x :: proc(lay: Field_Layout, p: int) -> f32 {
	n := len(lay.bounds) - 1
	if n <= 0 {
		return 0
	}
	if p >= lay.bounds[n] {
		k := n - 1
		return lay.x0[k] if lay.rtl[k] else lay.x1[k]
	}
	k := cluster_of(lay, p)
	return lay.x1[k] if lay.rtl[k] else lay.x0[k]
}

// field_hit is the byte offset nearest x: the side of the nearest cluster
// that x is on.
field_hit :: proc(lay: Field_Layout, x: f32) -> int {
	n := len(lay.bounds) - 1
	if n <= 0 {
		return 0
	}
	best, best_d := 0, max(f32)
	for k in 0 ..< n {
		d := f32(0)
		if x < lay.x0[k] {
			d = lay.x0[k] - x
		} else if x > lay.x1[k] {
			d = x - lay.x1[k]
		}
		if d < best_d {
			best, best_d = k, d
		}
	}
	left := x < (lay.x0[best] + lay.x1[best]) / 2
	if left != lay.rtl[best] {
		return lay.bounds[best]
	}
	return lay.bounds[best + 1]
}

// field_spans returns the x ranges, left to right and merged where they
// touch, of the clusters in bytes [lo, hi). In mixed-direction text a
// logical range can be several pieces on screen.
field_spans :: proc(lay: Field_Layout, lo, hi: int) -> [][2]f32 {
	spans := make([dynamic][2]f32, 0, 4, context.temp_allocator)
	n := len(lay.bounds) - 1
	for k in 0 ..< n {
		if lay.bounds[k] >= lo && lay.bounds[k + 1] <= hi {
			append(&spans, [2]f32{lay.x0[k], lay.x1[k]})
		}
	}
	slice.sort_by(spans[:], proc(a, b: [2]f32) -> bool {
		return a.x < b.x
	})
	out := make([dynamic][2]f32, 0, len(spans), context.temp_allocator)
	for sp in spans {
		if len(out) > 0 && sp.x <= out[len(out) - 1].y + 0.5 {
			out[len(out) - 1].y = max(out[len(out) - 1].y, sp.y)
		} else {
			append(&out, sp)
		}
	}
	return out[:]
}
