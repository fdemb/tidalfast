package tidal_tests

import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/render"
import "../src/ui"

@(test)
test_ui_keys :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.key_from_string(0, ""), ui.Key(0))
	a := ui.key_from_string(0, "Play##a")
	testing.expect(t, a != 0)
	testing.expect_value(t, ui.key_from_string(0, "Play##a"), a)
	testing.expect(t, ui.key_from_string(0, "Play##b") != a, "## keeps the whole string in the hash")
	testing.expect(t, ui.key_from_string(1234, "Play##a") != a, "the parent's key seeds the hash")
	testing.expect_value(t, ui.key_from_string(7, "Play###x"), ui.key_from_string(7, "Pause###x"))
	testing.expect_value(t, ui.label_from_string("Play##a"), "Play")
	testing.expect_value(t, ui.label_from_string("Pause###x"), "Pause")
	testing.expect_value(t, ui.label_from_string("Plain"), "Plain")
}

@(private = "file")
node :: proc(w, h: ui.Size, axis: ui.Axis = .X) -> ui.Box {
	b: ui.Box
	b.pref_size = {.X = w, .Y = h}
	b.child_axis = axis
	return b
}

@(private = "file")
expect_rect :: proc(t: ^testing.T, b: ^ui.Box, want: render.Rect, loc := #caller_location) {
	testing.expectf(t, b.rect == want, "rect %v, want %v", b.rect, want, loc = loc)
}

@(test)
test_ui_layout_size_kinds :: proc(t: ^testing.T) {
	root := node(ui.px(400), ui.px(100), .X)
	fixed := node(ui.px(50), ui.pct(0.5))
	label := node(ui.text_size(4), ui.text_size())
	label.text_size = {60, 16}
	group := node(ui.children_sum(), ui.children_sum(), .Y)
	g1 := node(ui.px(30), ui.px(20))
	g2 := node(ui.px(70), ui.px(25))
	ui.add_child(&root, &fixed)
	ui.add_child(&root, &label)
	ui.add_child(&root, &group)
	ui.add_child(&group, &g1)
	ui.add_child(&group, &g2)
	ui.layout(&root)

	expect_rect(t, &root, {0, 0, 400, 100})
	expect_rect(t, &fixed, {0, 0, 50, 50})
	expect_rect(t, &label, {50, 0, 64, 16})
	// Children_Sum: along its axis (Y) the sum, across it the largest.
	expect_rect(t, &group, {114, 0, 70, 45})
	expect_rect(t, &g1, {114, 0, 30, 20})
	expect_rect(t, &g2, {114, 20, 70, 25})
	testing.expect_value(t, root.view_bounds, [2]f32{184, 50})
}

@(test)
test_ui_layout_pct_skips_children_sum :: proc(t: ^testing.T) {
	// A percentage resolves against the nearest ancestor with its own size,
	// past one sized by its children.
	root := node(ui.px(300), ui.px(200), .Y)
	mid := node(ui.children_sum(), ui.children_sum(), .Y)
	leaf := node(ui.pct(0.5), ui.px(10))
	ui.add_child(&root, &mid)
	ui.add_child(&mid, &leaf)
	ui.layout(&root)
	expect_rect(t, &leaf, {0, 0, 150, 10})
	expect_rect(t, &mid, {0, 0, 150, 10})
}

@(test)
test_ui_layout_violations :: proc(t: ^testing.T) {
	// A fill child between two fixed ones gives up exactly the overflow.
	{
		root := node(ui.px(300), ui.px(50), .X)
		a := node(ui.px(100), ui.fill())
		fill := node(ui.fill(), ui.fill())
		b := node(ui.px(80), ui.fill())
		ui.add_child(&root, &a)
		ui.add_child(&root, &fill)
		ui.add_child(&root, &b)
		ui.layout(&root)
		expect_rect(t, &a, {0, 0, 100, 50})
		expect_rect(t, &fill, {100, 0, 120, 50})
		expect_rect(t, &b, {220, 0, 80, 50})
	}
	// Two flexible children give up in proportion to size * (1 - strictness).
	// Overflow 100: a can give 200 * 0.5 = 100, b 100 * 1 = 100, so each
	// gives half of that.
	{
		root := node(ui.px(200), ui.px(10), .X)
		a := node(ui.px(200, 0.5), ui.px(10))
		b := node(ui.px(100, 0), ui.px(10))
		ui.add_child(&root, &a)
		ui.add_child(&root, &b)
		ui.layout(&root)
		expect_rect(t, &a, {0, 0, 150, 10})
		expect_rect(t, &b, {150, 0, 50, 10})
	}
	// Strict children don't shrink, so they overflow.
	{
		root := node(ui.px(100), ui.px(10), .X)
		a := node(ui.px(80), ui.px(10))
		b := node(ui.px(80), ui.px(10))
		ui.add_child(&root, &a)
		ui.add_child(&root, &b)
		ui.layout(&root)
		expect_rect(t, &b, {80, 0, 80, 10})
	}
	// Not enough to give: the flexible child goes to 0 and the rest overflow.
	{
		root := node(ui.px(60), ui.px(10), .X)
		a := node(ui.px(90), ui.px(10))
		b := node(ui.px(50, 0), ui.px(10))
		ui.add_child(&root, &a)
		ui.add_child(&root, &b)
		ui.layout(&root)
		expect_rect(t, &b, {90, 0, 0, 10})
	}
	// Across the child axis, a child taller than its parent is cut down
	// whatever its strictness.
	{
		root := node(ui.px(100), ui.px(40), .X)
		a := node(ui.px(10), ui.px(90))
		ui.add_child(&root, &a)
		ui.layout(&root)
		expect_rect(t, &a, {0, 0, 10, 40})
	}
}

@(test)
test_ui_layout_scroll_and_floating :: proc(t: ^testing.T) {
	root := node(ui.px(200), ui.px(100), .Y)
	root.flags = {.Allow_Overflow_Y}
	root.view_off = {0, 30}
	rows: [5]ui.Box
	for &r in rows {
		r = node(ui.fill(), ui.px(40))
		ui.add_child(&root, &r)
	}
	float := node(ui.px(20), ui.px(20))
	float.flags = {.Floating_X, .Floating_Y}
	float.fixed_pos = {150, 5}
	ui.add_child(&root, &float)
	ui.layout(&root)
	// Overflow is allowed, so rows keep their height, shifted up by view_off.
	expect_rect(t, &rows[0], {0, -30, 200, 40})
	expect_rect(t, &rows[4], {0, 130, 200, 40})
	testing.expect_value(t, root.view_bounds.y, f32(200))
	// The floating box sits at fixed_pos, outside the flow.
	testing.expect_value(t, float.rect.x, f32(150))
	testing.expect_value(t, float.rect.w, f32(20))
}

@(test)
test_ui_virtual_range :: proc(t: ^testing.T) {
	Case :: struct {
		offset, view, row: f32,
		count:             int,
		first, last:       int,
	}
	cases := []Case {
		{0, 560, 56, 10_000, 0, 10},
		{1, 560, 56, 10_000, 0, 11},
		{56, 560, 56, 10_000, 1, 11},
		{100, 300, 56, 10_000, 1, 8},
		{559_500, 600, 56, 10_000, 9991, 10_000},
		{0, 600, 56, 3, 0, 3},
		{-20, 100, 56, 10, 0, 2},
		{0, 0, 56, 10, 0, 0},
		{0, 100, 56, 0, 0, 0},
	}
	for c in cases {
		first, last := ui.virtual_range(c.offset, c.view, c.row, c.count)
		testing.expectf(t, first == c.first && last == c.last, "virtual_range(%v, %v, %v, %v) = %v, %v, want %v, %v", c.offset, c.view, c.row, c.count, first, last, c.first, c.last)
	}
}

@(test)
test_track_columns :: proc(t: ^testing.T) {
	narrow := app.track_columns(560)
	testing.expect_value(t, narrow.album, f32(0))
	testing.expect_value(t, narrow.added, f32(0))
	testing.expect_value(t, narrow.added_by, f32(0))
	testing.expect(t, narrow.number > 0 && narrow.duration > 0)

	medium := app.track_columns(561)
	testing.expect_value(t, medium.album, f32(561 * 0.28))
	testing.expect_value(t, medium.added, f32(0))

	wide := app.track_columns(761)
	testing.expect(t, wide.album > 0 && wide.added > 0)
	testing.expect_value(t, wide.added_by, f32(0))
	testing.expect_value(t, app.track_columns(760).added, f32(0))

	extra := app.track_columns(921)
	testing.expect(t, extra.album > 0 && extra.added > 0 && extra.added_by > 0)
	testing.expect_value(t, app.track_columns(920).added_by, f32(0))
	testing.expect_value(t, app.track_columns(2000).album, f32(360))
}

// Builds a frame with one clickable box at the top left, the way an app
// would, without a renderer or text.
@(private = "file")
button_frame :: proc(u: ^ui.State, events: []platform.Event, time: f64) -> (ui.Signal, bool) {
	ui.begin_frame(u, events, nil, nil, 300, 200, time)
	b := ui.box_make("button", {.Clickable, .Focusable}, ui.px(100), ui.px(40))
	sig := ui.signal(b)
	return sig, ui.end_frame()
}

@(test)
test_ui_interaction :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer {
		delete(u.boxes)
		delete(u.table)
		delete(u.hits)
		free_all(context.temp_allocator)
	}
	now := 0.0
	frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (ui.Signal, bool) {
		now^ += 1.0 / 120
		return button_frame(u, events, now^)
	}

	// The first frame has no rects yet, so it asks for another.
	_, animating := frame(&u, &now)
	testing.expect(t, animating, "a new box asks for a frame")
	sig: ui.Signal
	sig, animating = frame(&u, &now, {kind = .Mouse_Move, x = 20, y = 20})
	testing.expect(t, sig.hovering)
	testing.expect(t, animating, "hot_t is fading in")

	// Hover settles and frames stop.
	settled := false
	for _ in 0 ..< 200 {
		sig, animating = frame(&u, &now)
		if !animating {
			settled = true
			break
		}
	}
	testing.expect(t, settled, "hot_t settles")
	testing.expect_value(t, sig.box.hot_t, f32(1))

	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 1}, {kind = .Mouse_Up, x = 20, y = 20, click_count = 1})
	testing.expect(t, sig.pressed && sig.released && sig.clicked)
	testing.expect(t, !sig.double_clicked)
	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 2}, {kind = .Mouse_Up, x = 20, y = 20, click_count = 2})
	testing.expect(t, sig.double_clicked)

	// Pressed inside, released outside: no click.
	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 1})
	testing.expect(t, sig.held && !sig.dragging)
	sig, _ = frame(&u, &now, {kind = .Mouse_Move, x = 200, y = 150})
	testing.expect(t, sig.dragging)
	testing.expect_value(t, sig.drag_delta, [2]f32{180, 130})
	testing.expect(t, !sig.hovering, "only hovering while over it")
	sig, _ = frame(&u, &now, {kind = .Mouse_Up, x = 200, y = 150})
	testing.expect(t, sig.released && !sig.clicked)

	// Right and control clicks.
	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, button = .Right})
	testing.expect(t, sig.right_clicked)
	frame(&u, &now, {kind = .Mouse_Up, x = 20, y = 20, button = .Right})
	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, modifiers = {.Control}})
	testing.expect(t, sig.right_clicked && !sig.pressed)
	frame(&u, &now, {kind = .Mouse_Up, x = 20, y = 20})
	testing.expect_value(t, u.input.buttons, ui.Mouse_Buttons{})

	// Tab focuses it, Enter clicks it, Escape drops the focus.
	frame(&u, &now, {kind = .Mouse_Down, x = 250, y = 150}, {kind = .Mouse_Up, x = 250, y = 150})
	sig, _ = frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB})
	testing.expect(t, ui.has_focus(sig.box))
	sig, _ = frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect(t, sig.clicked && sig.keyboard)
	sig, _ = frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_ESCAPE})
	testing.expect(t, !ui.has_focus(sig.box))

	// A box not built for a frame is freed.
	ui.begin_frame(&u, {}, nil, nil, 300, 200, now + 0.01)
	ui.end_frame()
	ui.begin_frame(&u, {}, nil, nil, 300, 200, now + 0.02)
	ui.end_frame()
	testing.expect_value(t, u.box_count, 0)
}

@(test)
test_ui_scroll :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer {
		delete(u.boxes)
		delete(u.table)
		delete(u.hits)
		free_all(context.temp_allocator)
	}
	list_frame :: proc(u: ^ui.State, time: f64, events: ..platform.Event) -> (^ui.Box, bool) {
		ui.begin_frame(u, events, nil, nil, 300, 200, time)
		list := ui.box_make("list", {.View_Scroll, .Allow_Overflow_Y, .Clip}, ui.px(300), ui.px(200))
		list.child_axis = .Y
		ui.push_parent(list)
		ui.box_make("", {}, ui.fill(), ui.px(1000))
		ui.pop_parent()
		return list, ui.end_frame()
	}
	now := 0.0
	list_frame(&u, now)
	now += 0.01
	list_frame(&u, now)

	// Trackpad deltas move the view at once, momentum included.
	now += 0.01
	list, _ := list_frame(&u, now, {kind = .Scroll, x = 50, y = 50, dy = -120, precise = true, phase = .Began})
	testing.expect_value(t, list.view_off.y, f32(120))
	now += 0.01
	list, _ = list_frame(&u, now, {kind = .Scroll, x = 50, y = 50, dy = -30, precise = true, momentum_phase = .Changed})
	testing.expect_value(t, list.view_off.y, f32(150))

	// Clamped to the content: 1000 - 200.
	now += 0.01
	list, _ = list_frame(&u, now, {kind = .Scroll, x = 50, y = 50, dy = -5000, precise = true, phase = .Changed})
	testing.expect_value(t, list.view_off.y, f32(800))

	// Wheel lines ease toward the target and then stop asking for frames.
	now += 0.01
	animating: bool
	list, animating = list_frame(&u, now, {kind = .Scroll, x = 50, y = 50, dy = 2})
	testing.expect_value(t, list.view_off_target.y, f32(800 - 2 * ui.SCROLL_LINE))
	testing.expect(t, animating && list.view_off.y > list.view_off_target.y)
	for _ in 0 ..< 300 {
		now += 1.0 / 120
		list, animating = list_frame(&u, now)
		if !animating {
			break
		}
	}
	testing.expect(t, !animating)
	testing.expect_value(t, list.view_off.y, list.view_off_target.y)
}
