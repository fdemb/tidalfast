package tidal_tests

import "core:fmt"
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

@(private = "file")
ui_destroy :: proc(u: ^ui.State) {
	delete(u.boxes)
	delete(u.table)
	delete(u.hits)
	free_all(context.temp_allocator)
}

// A scroll view filling a 300 by height window, with count rows of 10 pt
// built through virtual_rows. Returns the view and the rows built.
@(private = "file")
rows_frame :: proc(u: ^ui.State, now: ^f64, height: f32, count: int, events: ..platform.Event) -> (view: ^ui.Box, rows: ui.Virtual_Rows, animating: bool) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, height, now^)
	{
		view = ui.scroll_view("view", ui.fill(), ui.fill())
		rows = ui.virtual_rows(view, count, 10)
		for i in rows.first ..< rows.last {
			ui.box_make(fmt.tprintf("##row%d", i), {.Focusable, .Clickable}, ui.fill(), ui.px(10))
		}
	}
	animating = ui.end_frame()
	return
}

@(private = "file")
settle :: proc(u: ^ui.State, now: ^f64, height: f32, count: int) -> (view: ^ui.Box, rows: ui.Virtual_Rows, settled: bool) {
	animating: bool
	for _ in 0 ..< 300 {
		view, rows, animating = rows_frame(u, now, height, count)
		if !animating {
			return view, rows, true
		}
	}
	return
}

@(test)
test_ui_scroll_clamps_to_new_content :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	settle(&u, &now, 200, 100)
	view, _, _ := rows_frame(&u, &now, 200, 100, {kind = .Scroll, x = 50, y = 50, dy = -800, precise = true, phase = .Began})
	testing.expect_value(t, view.view_off.y, f32(800))
	settle(&u, &now, 200, 100)

	// The content shrinks to 100 pt. This frame was built at offset 800, so
	// it must clamp and ask for a frame that builds at 0.
	animating: bool
	view, _, animating = rows_frame(&u, &now, 200, 10)
	testing.expect_value(t, view.view_off.y, f32(0))
	testing.expect(t, animating, "a clamped offset asks for another frame")
	rows: ui.Virtual_Rows
	view, rows, animating = rows_frame(&u, &now, 200, 10)
	testing.expect_value(t, rows.first, 0)
	testing.expect_value(t, rows.last, 10)
	// The rows are new boxes, which ask for one frame of their own.
	_, _, animating = rows_frame(&u, &now, 200, 10)
	testing.expect(t, !animating, "and then settles")
}

@(test)
test_ui_virtual_rows_follow_new_size :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	_, rows, settled := settle(&u, &now, 100, 1000)
	testing.expect(t, settled)
	testing.expect_value(t, rows.last, 11) // 10 in view and one more

	// The view grows to 200 pt. This frame's rows were picked for 100, so
	// it asks for another, which builds the rest, then stops.
	animating: bool
	_, rows, animating = rows_frame(&u, &now, 200, 1000)
	testing.expect_value(t, rows.last, 11)
	testing.expect(t, animating, "a view whose size changed asks for another frame")
	_, rows, _ = rows_frame(&u, &now, 200, 1000)
	testing.expect_value(t, rows.last, 21)
	_, _, animating = rows_frame(&u, &now, 200, 1000)
	testing.expect(t, !animating, "then settles")
}

@(test)
test_ui_settle_frames_are_limited :: proc(t: ^testing.T) {
	// A view whose size depends on the frame count never settles; the extra
	// frames stop after a few.
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	asked := 0
	for i in 0 ..< 20 {
		now += 1.0 / 120
		ui.begin_frame(&u, {}, nil, nil, 300, 200, now)
		ui.scroll_view("view", ui.px(100 + f32(i)), ui.px(100))
		if ui.end_frame() {
			asked += 1
		}
	}
	testing.expectf(t, asked <= 4, "asked for %d frames", asked)
}

Menu_Frame :: struct {
	area, a, b: ui.Signal,
	animating:  bool,
}

// A focusable area that opens a menu with items A and B on a right click.
@(private = "file")
menu_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (f: Menu_Frame) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	ui.box_make("play", {.Clickable, .Focusable}, ui.px(100), ui.px(40))
	area := ui.box_make("area", {.Clickable, .Focusable}, ui.px(300), ui.px(100))
	f.area = ui.signal(area)
	if f.area.right_clicked {
		ui.open_menu("menu", ui.mouse())
	}
	if ui.menu("menu") {
		f.a = ui.menu_item("A##a")
		f.b = ui.menu_item("B##b")
	}
	f.animating = ui.end_frame()
	return
}

@(test)
test_ui_menu_keyboard :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	menu_frame(&u, &now)
	menu_frame(&u, &now)
	f := menu_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB}, {kind = .Key_Down, key_code = ui.KEY_TAB})
	testing.expect(t, ui.has_focus(f.area.box))

	// Opening the menu moves the focus to its first item.
	f = menu_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 60, button = .Right}, {kind = .Mouse_Up, x = 50, y = 60, button = .Right})
	testing.expect(t, f.a.box != nil && ui.has_focus(f.a.box), "the first item has the focus")

	// Tab and the arrows stay inside the menu.
	f = menu_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB})
	testing.expect(t, ui.has_focus(f.b.box))
	f = menu_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB})
	testing.expect(t, ui.has_focus(f.a.box), "Tab wraps within the menu")
	f = menu_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_DOWN})
	testing.expect(t, ui.has_focus(f.b.box))

	// Enter clicks the item, not the box focused behind the menu, then the
	// focus goes back to it.
	f = menu_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect(t, f.b.clicked && f.b.keyboard)
	testing.expect(t, !f.area.clicked, "the background box isn't clicked")
	testing.expect(t, ui.has_focus(f.area.box), "the focus is back on the area")

	// Escape closes it the same way, and Enter with the background focus
	// set from outside the menu does nothing while it's open.
	f = menu_frame(&u, &now)
	f = menu_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 60, button = .Right}, {kind = .Mouse_Up, x = 50, y = 60, button = .Right})
	ui.set_focus(f.area.box)
	f = menu_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_RETURN})
	testing.expect(t, !f.area.clicked && !f.a.clicked && !f.b.clicked)
	f = menu_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_ESCAPE})
	testing.expect(t, ui.has_focus(f.area.box))
	for _ in 0 ..< 100 {
		if f = menu_frame(&u, &now); !f.animating {
			break
		}
	}
	testing.expect(t, !f.animating, "the menu fades out and frames stop")
	testing.expect(t, f.a.box == nil)
}

// A target at the top and a virtual list of 100 draggable rows below it.
// Returns the payload dropped on the target this frame.
@(private = "file")
drag_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (dropped: u64, ok: bool) {
	return drag_frame_held(u, now, nil, ..events)
}

// drag_frame with the buttons the hardware reports, if given.
@(private = "file")
drag_frame_held :: proc(u: ^ui.State, now: ^f64, hardware: Maybe(ui.Mouse_Buttons), events: ..platform.Event) -> (dropped: u64, ok: bool) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, 200, now^, hardware)
	target := ui.box_make("target", {.Clickable}, ui.px(300), ui.px(40))
	dropped, ok = ui.dropped(target)
	{
		view := ui.scroll_view("view", ui.fill(), ui.fill())
		rows := ui.virtual_rows(view, 100, 20)
		for i in rows.first ..< rows.last {
			row := ui.box_make(fmt.tprintf("##row%d", i), {.Clickable}, ui.fill(), ui.px(20))
			if ui.signal(row).dragging {
				ui.drag_begin(u64(i) + 100)
			}
		}
	}
	ui.end_frame()
	return
}

@(test)
test_ui_drag_outlives_source :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	for _ in 0 ..< 3 {
		drag_frame(&u, &now)
	}

	// Drag row 0, scroll it out of the built range, release over nothing.
	drag_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1})
	drag_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 120})
	payload, dragging := ui.drag_payload()
	testing.expect(t, dragging && payload == 100)
	drag_frame(&u, &now, {kind = .Scroll, x = 50, y = 120, dy = -1000, precise = true, phase = .Began})
	drag_frame(&u, &now)
	drag_frame(&u, &now)
	_, dragging = ui.drag_payload()
	testing.expect(t, dragging, "the drag outlives its source")
	_, ok := drag_frame(&u, &now, {kind = .Mouse_Up, x = 50, y = 120})
	_, dragging = ui.drag_payload()
	testing.expect(t, !dragging && !ok, "a release anywhere ends it")

	// The same, released over the target.
	drag_frame(&u, &now, {kind = .Scroll, x = 50, y = 120, dy = 1000, precise = true, phase = .Began})
	drag_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1})
	drag_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 120})
	drag_frame(&u, &now, {kind = .Scroll, x = 50, y = 120, dy = -1000, precise = true, phase = .Began})
	drag_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 20})
	payload, ok = drag_frame(&u, &now, {kind = .Mouse_Up, x = 50, y = 20})
	testing.expect(t, ok && payload == 100, "dropped on the target")

	// Escape cancels, and moving on with the button held doesn't restart it.
	drag_frame(&u, &now, {kind = .Scroll, x = 50, y = 120, dy = 1000, precise = true, phase = .Began})
	drag_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1})
	drag_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 120})
	_, dragging = ui.drag_payload()
	testing.expect(t, dragging)
	drag_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_ESCAPE})
	drag_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 30})
	_, dragging = ui.drag_payload()
	testing.expect(t, !dragging, "Escape cancels")
	_, ok = drag_frame(&u, &now, {kind = .Mouse_Up, x = 50, y = 20})
	testing.expect(t, !ok, "a cancelled drag drops nothing")
}

// Three focusable boxes in a row.
@(private = "file")
three_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (boxes: [3]^ui.Box) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	ui.row("", {}, ui.fill(), ui.px(40))
	for &b, i in boxes {
		b = ui.box_make(fmt.tprintf("##b%d", i), {.Clickable, .Focusable}, ui.px(50), ui.fill())
	}
	ui.end_frame()
	return
}

@(test)
test_ui_tab_from_nothing :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	three_frame(&u, &now)
	boxes := three_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB})
	testing.expect(t, ui.has_focus(boxes[0]), "Tab starts at the first box")
	boxes = three_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_ESCAPE})
	testing.expect(t, !ui.has_focus(boxes[0]))
	boxes = three_frame(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB, modifiers = {.Shift}})
	testing.expect(t, ui.has_focus(boxes[2]), "Shift-Tab starts at the last box")
}

@(test)
test_ui_click_in_one_frame :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	slider :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> ui.Signal {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		b := ui.box_make("slider", {.Clickable}, ui.px(200), ui.px(20))
		sig := ui.signal(b)
		ui.end_frame()
		return sig
	}
	slider(&u, &now)
	slider(&u, &now)

	// Down and up in one frame, then the mouse moves on: the release is
	// where it was let go.
	sig := slider(&u, &now, {kind = .Mouse_Down, x = 150, y = 10, click_count = 1}, {kind = .Mouse_Up, x = 150, y = 10, click_count = 1}, {kind = .Mouse_Move, x = 10, y = 10})
	testing.expect(t, sig.pressed && sig.released && !sig.held)
	testing.expect_value(t, sig.mouse, [2]f32{150, 10})

	// A whole drag in one frame still reports how far it went.
	sig = slider(&u, &now, {kind = .Mouse_Down, x = 20, y = 10, click_count = 1}, {kind = .Mouse_Move, x = 80, y = 10}, {kind = .Mouse_Up, x = 80, y = 10, click_count = 1})
	testing.expect(t, sig.released)
	testing.expect_value(t, sig.drag_delta, [2]f32{60, 0})

	// While held, mouse follows the mouse.
	sig = slider(&u, &now, {kind = .Mouse_Down, x = 20, y = 10, click_count = 1}, {kind = .Mouse_Move, x = 90, y = 10})
	testing.expect(t, sig.held)
	testing.expect_value(t, sig.mouse, [2]f32{90, 10})
	slider(&u, &now, {kind = .Mouse_Up, x = 90, y = 10})
}

@(test)
test_ui_focus_scrolls_into_view :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0

	// A plain scroll view of ten 40 pt focusable boxes, 100 pt high.
	list :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (view: ^ui.Box, animating: bool) {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 100, now^)
		view = ui.scroll_view("list", ui.fill(), ui.fill())
		for i in 0 ..< 10 {
			ui.box_make(fmt.tprintf("##item%d", i), {.Clickable, .Focusable}, ui.fill(), ui.px(40))
		}
		animating = ui.end_frame()
		return
	}
	list(&u, &now)
	list(&u, &now)
	for _ in 0 ..< 4 {
		list(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB})
	}
	// Item 3 is 120 to 160, so the view scrolls to 60.
	view, _ := list(&u, &now)
	testing.expect_value(t, view.view_off_target.y, f32(60))
	list(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB, modifiers = {.Shift}})
	list(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB, modifiers = {.Shift}})
	list(&u, &now, {kind = .Key_Down, key_code = ui.KEY_TAB, modifiers = {.Shift}})
	view, _ = list(&u, &now)
	testing.expect_value(t, view.view_off_target.y, f32(0))

	// A virtual list: Down walks past the bottom edge, one row at a time,
	// and each step scrolls the row into view.
	v: ui.State
	ui.init(&v)
	defer ui_destroy(&v)
	now = 0
	settle(&v, &now, 100, 1000)
	rows_frame(&v, &now, 100, 1000, {kind = .Mouse_Down, x = 50, y = 5, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 5, click_count = 1})
	for _ in 0 ..< 25 {
		rows_frame(&v, &now, 100, 1000, {kind = .Key_Down, key_code = ui.KEY_DOWN})
		settle(&v, &now, 100, 1000)
	}
	view, _, _ = settle(&v, &now, 100, 1000)
	testing.expect_value(t, v.focus, ui.key_from_string(view.key, "##row25"))
	// Row 25 is 250 to 260, so the view ends at 260.
	testing.expect_value(t, view.view_off.y, f32(160))
}

@(test)
test_ui_pool_full :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	ui.begin_frame(&u, {}, nil, nil, 300, 200, 1)
	for i in 0 ..< ui.MAX_BOXES + 5 {
		ui.box_make(fmt.tprintf("##%d", i))
	}
	ui.end_frame()
	used, capacity, misses := ui.pool_stats(&u)
	testing.expect_value(t, used, ui.MAX_BOXES)
	testing.expect_value(t, capacity, ui.MAX_BOXES)
	testing.expect_value(t, misses, 5)
}

@(test)
test_ui_missed_release_cancels :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	down := ui.Mouse_Buttons{.Left}
	up := ui.Mouse_Buttons{}
	for _ in 0 ..< 3 {
		drag_frame_held(&u, &now, up)
	}

	// Drag row 0, then the window loses the mouse and the release goes to
	// another app. The first frame that sees the button up in hardware
	// waits for a release that may be on its way, and asks for a frame.
	drag_frame_held(&u, &now, down, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1})
	drag_frame_held(&u, &now, down, {kind = .Mouse_Move, x = 50, y = 120})
	_, dragging := ui.drag_payload()
	testing.expect(t, dragging)
	drag_frame_held(&u, &now, up, {kind = .Mouse_Leave})
	_, dragging = ui.drag_payload()
	testing.expect(t, dragging, "one frame up in hardware isn't enough")
	testing.expect(t, u.animating, "and it asks for the frame that decides")
	drag_frame_held(&u, &now, up)
	_, dragging = ui.drag_payload()
	testing.expect(t, !dragging, "a missed release cancels the drag")
	testing.expect_value(t, u.input.buttons, ui.Mouse_Buttons{})
	testing.expect_value(t, u.active[.Left], ui.Key(0))

	// Back in the window, a click on the target drops nothing.
	drag_frame_held(&u, &now, up, {kind = .Mouse_Move, x = 50, y = 20})
	_, ok := drag_frame_held(&u, &now, up, {kind = .Mouse_Down, x = 50, y = 20, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 20, click_count = 1})
	testing.expect(t, !ok, "the cancelled drag doesn't drop")
	_, ok = drag_frame_held(&u, &now, up)
	testing.expect(t, !ok)

	// A release that arrives a frame after the hardware went up still
	// counts: a quick tap.
	v: ui.State
	ui.init(&v)
	defer ui_destroy(&v)
	now = 0
	tap :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> ui.Signal {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^, ui.Mouse_Buttons{})
		sig := ui.signal(ui.box_make("button", {.Clickable}, ui.px(100), ui.px(40)))
		ui.end_frame()
		return sig
	}
	tap(&v, &now)
	tap(&v, &now)
	sig := tap(&v, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 1})
	testing.expect(t, sig.held)
	sig = tap(&v, &now)
	testing.expect(t, sig.held, "held for one frame up in hardware")
	sig = tap(&v, &now, {kind = .Mouse_Up, x = 20, y = 20, click_count = 1})
	testing.expect(t, sig.clicked, "the late release clicks")

	// A hot reload lets go of everything.
	drag_frame_held(&u, &now, down, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1})
	drag_frame_held(&u, &now, down, {kind = .Mouse_Move, x = 50, y = 120})
	_, dragging = ui.drag_payload()
	testing.expect(t, dragging)
	ui.cancel_pointer(&u)
	_, dragging = ui.drag_payload()
	testing.expect(t, !dragging && u.input.buttons == {})
}

@(test)
test_ui_settle_frames_reset_on_resize :: proc(t: ^testing.T) {
	// Each resize is new input, so the limit on extra frames starts over.
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	settle(&u, &now, 200, 1000)
	for h in ([]f32{190, 180, 170, 300}) {
		rows_frame(&u, &now, h, 1000)
	}
	testing.expect(t, u.animating, "the last resize gets its extra frame")
	_, rows, settled := settle(&u, &now, 300, 1000)
	testing.expect(t, settled)
	testing.expect_value(t, rows.last, 31) // 30 in view and one more
}

@(test)
test_ui_drag_in_one_frame :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	for _ in 0 ..< 3 {
		drag_frame(&u, &now)
	}

	// Down on row 0, past the threshold onto the target and up, all in one
	// frame. The target was built before the row, so the drop comes in the
	// next frame, which the release asks for.
	payload, ok := drag_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1}, {kind = .Mouse_Move, x = 50, y = 20}, {kind = .Mouse_Up, x = 50, y = 20, click_count = 1})
	testing.expect(t, !ok)
	testing.expect(t, u.animating, "the release asks for the frame that drops")
	payload, ok = drag_frame(&u, &now)
	testing.expect(t, ok && payload == 100, "dropped on the target a frame later")
	_, ok = drag_frame(&u, &now)
	testing.expect(t, !ok, "once")

	// A drag that began in an earlier frame drops in its release frame,
	// and only then.
	drag_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1})
	drag_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 20})
	payload, ok = drag_frame(&u, &now, {kind = .Mouse_Up, x = 50, y = 20, click_count = 1})
	testing.expect(t, ok && payload == 100)
	_, ok = drag_frame(&u, &now)
	testing.expect(t, !ok, "the release frame's dragging signal doesn't start another")

	// A click without moving isn't a drag.
	drag_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 50, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 50, click_count = 1})
	_, ok = drag_frame(&u, &now)
	testing.expect(t, !ok)
}

@(test)
test_ui_closed_menu_takes_no_click :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	menu_frame(&u, &now)
	menu_frame(&u, &now)
	f := menu_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 60, button = .Right}, {kind = .Mouse_Up, x = 50, y = 60, button = .Right})
	for _ in 0 ..< 100 {
		if f = menu_frame(&u, &now); !f.animating {
			break
		}
	}
	r := f.a.box.rect
	at := [2]f32{r.x + 10, r.y + r.h / 2}
	testing.expect(t, at.y > 40 && at.y < 140, "item A is over the area")

	// Clicking A closes the menu while it's being built. A click on the same
	// spot in the next frame goes to the area under it.
	f = menu_frame(&u, &now, {kind = .Mouse_Down, x = at.x, y = at.y, click_count = 1}, {kind = .Mouse_Up, x = at.x, y = at.y, click_count = 1})
	testing.expect(t, f.a.clicked)
	f = menu_frame(&u, &now, {kind = .Mouse_Down, x = at.x, y = at.y, click_count = 1}, {kind = .Mouse_Up, x = at.x, y = at.y, click_count = 1})
	testing.expect(t, f.area.clicked, "the closed menu doesn't swallow the click")
}
