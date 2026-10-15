package ui

import "core:math"

import "../render"

MENU_BACKGROUND :: render.Color{0.13, 0.15, 0.18, 1}
MENU_BORDER :: render.Color{1, 1, 1, 0.08}

// label is a text box without a key: no state, no input. s must live until
// end_frame.
label :: proc(s: string, width: Size = {}, height: Size = {}) -> ^Box {
	b := box_make("", {.Draw_Text}, width if width.kind != .Null else text_size(), height if height.kind != .Null else text_size())
	b.id = s
	b.label = s
	return b
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
	b.text_pad = 10
	b.text_align = .Center
	b.radius = 6
	return signal(b)
}

// scroll_view is a clipped box that scrolls its children vertically, and
// the parent until the end of the scope.
@(deferred_out = pop_parent_box)
scroll_view :: proc(id: string, width, height: Size, flags: Box_Flags = {}) -> ^Box {
	b := box_make(id, {.View_Scroll, .Clip, .Allow_Overflow_Y} + flags, width, height)
	b.child_axis = .Y
	push_parent(b)
	return b
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
// onto it and scroll it into view.
@(deferred_out = virtual_rows_end)
virtual_rows :: proc(view: ^Box, count: int, row_h: f32) -> Virtual_Rows {
	first, last := virtual_range(view.view_off.y, view.rect.h, row_h, count)
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
	if y0 < t^ {
		t^ = y0
	} else if y1 > t^ + view.rect.h {
		t^ = y1 - view.rect.h
	}
	t^ = clamp(t^, 0, max(view.view_bounds.y - view.rect.h, 0))
	ctx.animating = true
}

// floating makes the floating layer the parent until the end of the scope.
// It is laid out and drawn after the main tree, ignores every clip in it
// and comes first for input. Its boxes need Floating_X and Floating_Y and
// a fixed_pos in window coordinates.
@(deferred_none = pop_parent)
floating :: proc() {
	push_parent(ctx.floating_root)
}

// Menus. One context menu is open at a time. open_menu opens it at pos;
// menu builds it while it's open or fading out. A click outside it or
// Escape closes it, and so does clicking an item. While it's open the focus
// is inside it, starting on the first item, and the keyboard reaches
// nothing else. Closing it puts the focus back where it was.

open_menu :: proc(id: string, pos: [2]f32) {
	u := ctx
	if !u.menu_open {
		u.menu_saved = u.focus
		u.menu_saved_vis = u.focus_visible
	}
	u.menu = key_from_string(0, id)
	u.menu_open = true
	u.menu_pos = pos
	u.menu_focus_new = true
}

close_menu :: proc() {
	u := ctx
	if u.menu_open {
		u.focus = u.menu_saved
		u.focus_visible = u.menu_saved_vis && u.focus != 0
		u.menu_saved = 0
	}
	u.menu_open = false
	u.menu_focus_new = false
	// It may close after it was built this frame, so the fade starts next.
	u.animating = true
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
		pop_parent()
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
	// A menu fading out takes no input.
	flags := Box_Flags{.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Floating_X, .Floating_Y}
	if !u.menu_open {
		flags += {.Disabled}
	}
	b := box_make(id, flags, px(width), children_sum())
	b.child_axis = .Y
	b.open_t = approach(u, b.open_t, 1 if u.menu_open else 0, 1 - math.exp(-u.dt * 24), 0.01)
	u.menu_built = true
	if !u.menu_open && b.open_t == 0 {
		u.menu = 0
		pop_parent()
		return false
	}
	// Keep it in the window, above the mouse if there's no room below.
	pos := u.menu_pos
	pos.x = max(min(pos.x, u.width - width - 8), 8)
	if pos.y + b.rect.h > u.height - 8 {
		pos.y = pos.y - b.rect.h
	}
	pos.y = max(pos.y, 8)
	b.fixed_pos = pos + {0, (1 - b.open_t) * -6}
	b.opacity = b.open_t
	b.background = MENU_BACKGROUND
	b.border_color = MENU_BORDER
	b.radius = 8
	push_parent(b)
	spacer(px(6))
	return true
}

menu_item :: proc(id: string) -> Signal {
	u := ctx
	flags := Box_Flags{.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects}
	if !u.menu_open {
		flags += {.Disabled}
	}
	b := box_make(id, flags, fill(), px(30))
	b.text_pad = 14
	b.hover_color = {1, 1, 1, 0.08}
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
	b := box_make("", {.Draw_Background}, fill(), px(1))
	b.background = MENU_BORDER
	spacer(px(4))
}

// tooltip shows label next to the mouse once sig's box has been hovered
// for TOOLTIP_DELAY. Until then it keeps frames coming so it can appear
// without input.
tooltip :: proc(sig: Signal, label: string) {
	u := ctx
	if !sig.hovering || u.input.buttons != {} || (u.menu != 0 && u.menu_open) {
		return
	}
	if u.time - u.hot_since < TOOLTIP_DELAY {
		u.animating = true
		return
	}
	push_parent(u.floating_root)
	defer pop_parent()
	b := box_make("###tooltip", {.Floating_X, .Floating_Y, .Draw_Background, .Draw_Border, .Draw_Text})
	b.label = label
	b.pref_size = {.X = text_size(), .Y = text_size(10)}
	b.font_size = 12
	b.text_pad = 8
	b.background = MENU_BACKGROUND
	b.border_color = MENU_BORDER
	b.text_color = {0.95, 0.96, 0.97, 1}
	b.radius = 5
	b.open_t = approach(u, b.open_t, 1, 1 - math.exp(-u.dt * 20), 0.01)
	b.opacity = b.open_t
	pos := u.input.mouse + {10, 20}
	pos.x = max(min(pos.x, u.width - b.rect.w - 8), 8)
	if pos.y + b.rect.h > u.height - 8 {
		pos.y = u.input.mouse.y - b.rect.h - 8
	}
	b.fixed_pos = pos
}
