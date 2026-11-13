package ui

import "core:math"

import "../render"
import "../text"

MENU_BACKGROUND :: render.Color{0.13, 0.13, 0.13, 1}
MENU_BORDER :: render.Color{1, 1, 1, 0.08}

// label is a text box without a key: no state, no input. s must live until
// end_frame.
label :: proc(s: string, width: Size = {}, height: Size = {}) -> ^Box {
	b := box_make("", {.Draw_Text}, width if width.kind != .Null else text_size(), height if height.kind != .Null else text_size())
	b.id = s
	b.label = s
	return b
}

// text_width is how wide s is in font at size. Without a text system
// (headless tests) it guesses from the length.
text_width :: proc(font: text.Font, size: f32, s: string) -> f32 {
	u := ctx
	if u == nil || u.texts == nil {
		return f32(len(s)) * size * 0.6
	}
	return text.measure(u.texts, font, size, s).width
}

// cluster_widths is how wide each grapheme cluster of s is in font at
// size, between the offsets bounds from cluster_bounds, from one shaping
// of s. Without a text system it guesses from the length.
cluster_widths :: proc(font: text.Font, size: f32, s: string, bounds: []int, allocator := context.temp_allocator) -> []f32 {
	widths := make([]f32, len(bounds) - 1, allocator)
	u := ctx
	if u == nil || u.texts == nil {
		for &w, i in widths {
			w = f32(bounds[i + 1] - bounds[i]) * size * 0.6
		}
		return widths
	}
	// A glyph's cluster is a codepoint index; of_rune maps it to its
	// grapheme cluster.
	of_rune := make([dynamic]int, 0, len(s), context.temp_allocator)
	c := 0
	for _, i in s {
		for i >= bounds[c + 1] {
			c += 1
		}
		append(&of_rune, c)
	}
	for g in text.shape(u.texts, font, size, s).glyphs {
		if int(g.cluster) < len(of_rune) {
			widths[of_rune[g.cluster]] += g.advance
		}
	}
	return widths
}

// counter_width is how wide a counter in the shape of pattern can get, such
// as "-3:45" for a time left: every digit is taken as the widest digit.
// SF Pro's digits differ in width, so a label this wide never cuts off any
// value with the same pattern.
counter_width :: proc(font: text.Font, size: f32, pattern: string) -> f32 {
	widest := u8('0')
	best: f32
	for d in u8('0') ..= '9' {
		digit := [1]u8{d}
		if w := text_width(font, size, string(digit[:])); w > best {
			best, widest = w, d
		}
	}
	buf: [64]u8
	n := copy(buf[:], pattern)
	for &c in buf[:n] {
		if c >= '0' && c <= '9' {
			c = widest
		}
	}
	return math.ceil(text_width(font, size, string(buf[:n])))
}

// spacer takes size along the parent's child axis and nothing across it.
spacer :: proc(size: Size) -> ^Box {
	p := top_parent()
	if p != nil && p.child_axis == .X {
		return box_make("", {}, size, px(0))
	}
	return box_make("", {}, px(0), size)
}

button :: proc(id: string, width: Size = {}, height: Size = {}) -> Signal {
	b := box_make(id, {.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, width, height)
	accessible(b, .Button, b.label)
	return signal(b)
}

// link is text that does something when clicked, underlined while the
// mouse is over it. It's as wide as its text and gives way to an ellipsis
// when there's less room, so only the text takes the click. The text goes
// from the text colour to hot_color as it lights. A label given apart from
// id is the text, and id only the key, as label###id would be without
// joining them.
link :: proc(id: string, hot_color: render.Color, height: Size = {}, label := "") -> Signal {
	b := box_make(id, {.Clickable, .Draw_Text, .Draw_Hot_Underline}, text_size(0, 0), height)
	if label != "" {
		b.label = label
	}
	b.text_color += (hot_color - b.text_color) * b.hot_t
	accessible(b, .Button, b.label)
	return signal(b)
}

// scroll_view is a clipped box that scrolls its children vertically, and
// the parent until the end of the scope. It has a scrollbar while its
// content is taller than it, drawn as State.scrollbars says. inset_end is
// how much of its bottom something else covers: the content can scroll up
// clear of it, and the scrollbar and scroll_to keep above it. bar_top is
// how much of its top right something else covers, such as the window's
// buttons: the scrollbar starts below it.
@(deferred_out = scroll_view_end)
scroll_view :: proc(id: string, width, height: Size, flags: Box_Flags = {}, inset_end: f32 = 0, bar_top: f32 = 0) -> ^Box {
	b := box_make(id, {.View_Scroll, .Clip, .Allow_Overflow_Y} + flags, width, height)
	b.child_axis = .Y
	b.inset_end = inset_end
	b.bar_top = bar_top
	if b.key != 0 {
		scrollbar_drag(b)
		b.gutter = gutter_of(b)
	}
	push_parent(b)
	return b
}

// scroll_gutter is the room the scroll view id, built next under the
// current parent, takes from its rows' right this frame for a docked
// scrollbar. A header above the list leaves the same, so its columns line
// up with the rows'.
scroll_gutter :: proc(id: string) -> f32 {
	b := find(id)
	return gutter_of(b) if b != nil else 0
}

// gutter_of goes by the last layout, like the rest of the scrollbar.
@(private)
gutter_of :: proc(view: ^Box) -> f32 {
	return SCROLLBAR_TRACK if ctx.scrollbars == .Docked && view.view_bounds.y > build_size(view).y else 0
}

@(private)
scroll_view_end :: proc(b: ^Box) {
	scrollbar(b)
	pop_parent()
}

Scrollbars :: enum u8 {
	Floating, // shows for a moment when the view scrolls, the mouse enters it or it gets the focus
	Docked, // always shows, in a gutter of its own
	Never,
}

SCROLLBAR_W :: 6
SCROLLBAR_INSET :: 2
SCROLLBAR_TRACK :: SCROLLBAR_W + 2 * SCROLLBAR_INSET
SCROLLBAR_MIN_THUMB :: 24
SCROLLBAR_LINGER :: 1.0 // seconds a floating scrollbar stays after the view stops

@(private)
Thumb :: struct {
	y, h, travel, range: f32, // y from the top of the track
}

@(private)
thumb_of :: proc(view: ^Box) -> (t: Thumb, ok: bool) {
	content, h := view.view_bounds.y - view.inset_end, build_size(view).y - view.inset_end
	if content <= h || h - view.bar_top <= 2 * SCROLLBAR_INSET {
		return {}, false
	}
	track := h - view.bar_top - 2 * SCROLLBAR_INSET
	t.h = clamp(track * h / content, min(SCROLLBAR_MIN_THUMB, track), track)
	t.travel = track - t.h
	t.range = content - h
	t.y = SCROLLBAR_INSET + t.travel * clamp(view.view_off.y / t.range, 0, 1)
	return t, true
}

// scrollbar_drag moves the view with last frame's scrollbar, before the
// view's children are built for the offset. A press on the thumb drags it
// from where it was taken; a press beside it centres it on the mouse.
@(private)
scrollbar_drag :: proc(view: ^Box) {
	u := ctx
	bar := box_lookup(u, key_from_string(view.key, "###scrollbar"))
	if bar == nil {
		return
	}
	t, ok := thumb_of(view)
	if !ok {
		return
	}
	sig := signal(bar)
	if sig.pressed {
		y := sig.mouse.y - bar.rect.y
		view.bar_grab = y - t.y if y >= t.y && y < t.y + t.h else t.h / 2
	}
	if (sig.held || sig.released) && t.travel > 0 {
		f := clamp((sig.mouse.y - bar.rect.y - SCROLLBAR_INSET - view.bar_grab) / t.travel, 0, 1)
		view.view_off.y = f * t.range
		view.view_off_target.y = view.view_off.y
	}
}

// scrollbar builds the view's scrollbar over its right edge, last so it's
// on top of the rows. A floating one shows when the view moves, the mouse
// enters it or the focus moves into it, and hides SCROLLBAR_LINGER seconds
// after, unless the mouse is on the scrollbar.
// focus_within says whether the focus is on b or a box built inside it
// this frame.
@(private)
focus_within :: proc(u: ^State, b: ^Box) -> bool {
	f := box_lookup(u, u.focus)
	if f == nil || f.last_frame != u.frame {
		return false
	}
	for p := f; p != nil; p = p.parent {
		if p == b {
			return true
		}
	}
	return false
}

@(private)
scrollbar :: proc(view: ^Box) {
	u := ctx
	if view.key == 0 {
		return
	}
	hovered := u.input.mouse_inside && rect_contains(view.clip, u.input.mouse)
	focused := focus_within(u, view)
	if view.view_off.y != view.bar_seen || (hovered && !view.bar_hovered) || (focused && !view.bar_focused) {
		view.bar_time = u.time
	}
	view.bar_seen = view.view_off.y
	view.bar_hovered = hovered
	view.bar_focused = focused
	t, ok := thumb_of(view)
	if !ok || u.scrollbars == .Never {
		view.bar_t = 0
		return
	}
	key := key_from_string(view.key, "###scrollbar")
	held := u.hot == key || u.active[.Left] == key
	recent := u.time - view.bar_time < SCROLLBAR_LINGER
	show := u.scrollbars == .Docked || held || recent
	if show && !held && u.scrollbars == .Floating {
		wake_at(view.bar_time + SCROLLBAR_LINGER)
	}
	view.bar_t = approach(u, view.bar_t, 1 if show else 0, 1 - math.exp(-u.dt * 12), 0.01)

	flags := Box_Flags{.Floating_X, .Floating_Y}
	if view.bar_t > 0 {
		flags += {.Clickable}
	}
	set_next_flags({})
	size := build_size(view)
	bar := box_make("###scrollbar", flags, px(SCROLLBAR_TRACK), px(size.y - view.inset_end - view.bar_top))
	bar.fixed_pos = {size.x - SCROLLBAR_TRACK, view_offset(view).y + view.bar_top}
	bar.opacity = view.bar_t
	push_parent(bar)
	defer pop_parent()
	set_next_flags({})
	set_next_background({1, 1, 1, 0.22 + 0.2 * max(bar.hot_t, bar.active_t)})
	set_next_radius(SCROLLBAR_W / 2)
	thumb := box_make("", {.Floating_X, .Floating_Y, .Draw_Background}, px(SCROLLBAR_W), px(t.h))
	thumb.fixed_pos = {SCROLLBAR_INSET, t.y}
}

Virtual_Rows :: struct {
	first, last: int, // the rows to build, [first, last)
	count:       int,
	row_h:       f32,
}

@(private)
virtual_rows_end :: proc(v: Virtual_Rows) {
	if v.last < v.count {
		spacer(px(f32(v.count - v.last) * v.row_h))
	}
}

// virtual_rows works out which of count rows of height row_h show in the
// scroll view, which is the current parent, and stands in for the rest with
// spacers. Build exactly the rows in [first, last) before the scope ends.
// One row past each edge is built too, so the keyboard can move the focus
// onto it and scroll it into view. start is where row 0 is in the view's
// content past its pad, for rows under a header that scrolls with them;
// the parent can then be a box inside the view that starts there. Give
// the view its height in points (see build_size): with a fill it goes by
// the last layout, so a new view's first frame builds no rows.
@(deferred_out = virtual_rows_end)
virtual_rows :: proc(view: ^Box, count: int, row_h: f32, start: f32 = 0) -> Virtual_Rows {
	first, last := virtual_range(view.view_off.y - view.pad.y - start, build_size(view).y, row_h, count)
	if last > first {
		first, last = max(first - 1, 0), min(last + 1, count)
	}
	if first > 0 {
		spacer(px(f32(first) * row_h))
	}
	return {first, last, count, row_h}
}

// scroll_to moves the view the least it takes to show y0 to y1 of its
// content.
scroll_to :: proc(view: ^Box, y0, y1: f32) {
	t := &view.view_off_target.y
	size := build_size(view)
	h := size.y - view.inset_end
	if y0 < t^ {
		t^ = y0
	} else if y1 > t^ + h {
		t^ = y1 - h
	}
	t^ = clamp(t^, 0, max(view.view_bounds.y - size.y, 0))
	ctx.animating = true
}

// slide eases keyed box b's open_t toward 1 while on and toward 0 while
// not, and returns it, for a switch's knob. A box on its first frame starts
// where it's going.
slide :: proc(b: ^Box, on: bool) -> f32 {
	u := ctx
	target: f32 = 1 if on else 0
	if b.first_frame == u.frame {
		b.open_t = target
	}
	b.open_t = approach(u, b.open_t, target, 1 - math.exp(-u.dt * 24), 0.01)
	return b.open_t
}

// floating makes the floating layer the parent until the end of the scope.
// It is laid out and drawn after the main tree, ignores every clip in it
// and comes first for input. Its boxes need Floating_X and Floating_Y and
// a fixed_pos in window coordinates. It starts from the default style,
// whatever the scopes around it set.
@(deferred_none = floating_end)
floating :: proc() {
	push_parent(ctx.floating_root)
	style_push()^ = STYLE_DEFAULT
}

@(private)
floating_end :: proc() {
	pop_style()
	pop_parent()
}

// Menus. One context menu is open at a time. open_menu opens it at pos,
// or with up its bottom at pos, as for a button at the window's bottom;
// menu builds it while it's open or fading out. A click outside it or
// Escape closes it, and so does clicking an item. While it's open the
// keyboard reaches nothing else. The focus is its highlighted item, which
// the mouse and the keys both move, and which starts on the first item
// only when the keyboard opened the menu. Closing it puts the focus back
// where it was.

open_menu :: proc(id: string, pos: [2]f32, up := false) {
	u := ctx
	if !u.menu_open {
		u.menu_saved = u.focus
		u.menu_saved_vis = u.focus_visible
	}
	u.menu = key_from_string(0, id)
	u.menu_open = true
	u.menu_pos = pos
	u.menu_up = up
	u.menu_focus_new = u.key_click != 0
	u.menu_lit = 0
	u.focus = 0
}

close_menu :: proc() {
	u := ctx
	if u.menu_open {
		u.menu_lit = u.focus
		u.focus = u.menu_saved
		u.focus_visible = u.menu_saved_vis && u.focus != 0
		u.menu_saved = 0
	}
	u.menu_open = false
	u.menu_focus_new = false
	// It may close after it was built this frame, so the fade starts next.
	u.animating = true
}

// menu_highlight is the menu item drawn lit: the focus while the menu is
// open, and while it fades out the item that had the focus when it closed,
// though the focus has gone back to where it was.
@(private)
menu_highlight :: proc(u: ^State) -> Key {
	return u.focus if u.menu_open else u.menu_lit
}

menu_is_open :: proc(id: string) -> bool {
	u := ctx
	return u.menu_open && u.menu == key_from_string(0, id)
}

@(private)
menu_end :: proc(open: bool) {
	if open {
		spacer(px(6))
		pop_parent()
		floating_end()
	}
}

// menu returns true while the menu id is open or closing, with its panel
// as the parent until the end of the scope. Use it as `if ui.menu(id) {}`.
@(deferred_out = menu_end)
menu :: proc(id: string, width: f32 = 220) -> bool {
	u := ctx
	if u.menu == 0 || u.menu != key_from_string(0, id) {
		return false
	}
	push_parent(u.floating_root)
	style_push()^ = STYLE_DEFAULT
	// A menu fading out takes no input.
	flags := Box_Flags{.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y}
	if !u.menu_open {
		flags += {.Disabled}
	}
	set_next_background(MENU_BACKGROUND)
	set_next_border_color(MENU_BORDER)
	set_next_radius(8)
	b := box_make(id, flags, px(width), children_sum())
	b.child_axis = .Y
	accessible(b, .Menu, "")
	b.open_t = approach(u, b.open_t, 1 if u.menu_open else 0, 1 - math.exp(-u.dt * 24), 0.01)
	u.menu_built = true
	if !u.menu_open && b.open_t == 0 {
		u.menu = 0
		floating_end()
		return false
	}
	// Above pos if there's no room below, or if it opened up. It slides
	// in from pos.
	b.fixed_pos = u.menu_pos + {0, (1 - b.open_t) * (6 if u.menu_up else -6)}
	b.keep_in_window = true
	b.above = u.menu_up
	b.flip_y = b.fixed_pos.y
	b.opacity = b.open_t
	push_parent(b)
	spacer(px(6))
	return true
}

menu_item :: proc(id: string) -> Signal {
	u := ctx
	flags := Box_Flags{.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects, .Focus_Is_Hot, .No_Focus_Ring, .Instant_Hover}
	if !u.menu_open {
		flags += {.Disabled}
	}
	set_next_text_pad(14)
	set_next_hover_color({1, 1, 1, 0.08})
	b := box_make(id, flags, fill(), px(30))
	accessible(b, .Menu_Item, b.label)
	if u.menu_focus_new && u.menu_open && b.key != 0 {
		u.menu_focus_new = false
		u.focus = b.key
		u.focus_visible = true
	}
	sig := signal(b)
	if sig.clicked {
		close_menu()
	}
	return sig
}

menu_separator :: proc() {
	spacer(px(4))
	set_next_background(MENU_BORDER)
	box_make("", {.Draw_Background}, fill(), px(1))
	spacer(px(4))
}

// tooltip shows label next to the mouse once sig's box has been hovered
// for TOOLTIP_DELAY. Until then it asks for a frame at the deadline so it
// can appear without input. Within TOOLTIP_WARM of the last tooltip it
// shows at once without fading in, so moving the mouse along a row of
// buttons shows each one's. Boxes scrolling under a still mouse wait for
// the delay. It stays where it showed while the mouse moves over the box.
tooltip :: proc(sig: Signal, label: string) {
	u := ctx
	if !sig.hovering || u.input.buttons != {} || u.menu_open {
		return
	}
	warm := u.hot_by_mouse && u.time - u.tooltip_seen < TOOLTIP_WARM
	if shows := u.hot_since + TOOLTIP_DELAY; u.time < shows && !warm {
		wake_at(shows)
		return
	}
	u.tooltip_seen = u.time
	floating()
	set_next_font_size(12)
	set_next_text_pad(8)
	set_next_text_color({0.95, 0.95, 0.95, 1})
	set_next_background(MENU_BACKGROUND)
	set_next_border_color(MENU_BORDER)
	set_next_radius(5)
	b := box_make("###tooltip", {.Floating_X, .Floating_Y, .Draw_Background, .Draw_Border, .Draw_Text})
	b.label = label
	b.pref_size = {.X = text_size(), .Y = text_size(10)}
	if warm && b.first_frame == u.frame {
		b.open_t = 1
	}
	b.open_t = approach(u, b.open_t, 1, 1 - math.exp(-u.dt * 20), 0.01)
	b.opacity = b.open_t
	if b.first_frame == u.frame || u.tooltip_owner != sig.box.key {
		u.tooltip_owner = sig.box.key
		u.tooltip_pos = u.input.mouse
	}
	b.fixed_pos = u.tooltip_pos + {10, 20}
	b.keep_in_window = true
	b.flip_y = u.tooltip_pos.y - 8
}
