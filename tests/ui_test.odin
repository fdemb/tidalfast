package tidal_tests

import "core:fmt"
import "core:log"
import "core:math"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/render"
import "../src/text"
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

// Shrink_From_End keeps the first children whole and cuts the one that
// crosses the edge, inside the padding, leaving none for the rest.
// Center_Children puts children where two fill() spacers around them
// would, and at the start when they don't fit.
@(test)
test_ui_layout_center_children :: proc(t: ^testing.T) {
	for height in ([]f32{56, 87, 30}) {
		spaced := node(ui.px(40), ui.px(height), .Y)
		before := node(ui.px(0), ui.fill())
		a := node(ui.px(36), ui.px(36))
		after := node(ui.px(0), ui.fill())
		ui.add_child(&spaced, &before)
		ui.add_child(&spaced, &a)
		ui.add_child(&spaced, &after)
		ui.layout(&spaced)

		centred := node(ui.px(40), ui.px(height), .Y)
		centred.flags = {.Center_Children}
		b := node(ui.px(36), ui.px(36))
		ui.add_child(&centred, &b)
		ui.layout(&centred)
		expect_rect(t, &b, a.rect)
	}
}

@(test)
test_ui_layout_shrink_from_end :: proc(t: ^testing.T) {
	root := node(ui.px(100), ui.px(20))
	root.flags = {.Shrink_From_End}
	root.pad.x = 5
	kids := [3]ui.Box{node(ui.px(50, 0), ui.px(20)), node(ui.px(30, 0), ui.px(20)), node(ui.px(30, 0), ui.px(20))}
	for &k in kids {
		ui.add_child(&root, &k)
	}
	ui.layout(&root)
	expect_rect(t, &kids[0], {5, 0, 50, 20})
	expect_rect(t, &kids[1], {55, 0, 30, 20})
	expect_rect(t, &kids[2], {85, 0, 10, 20})
	cut := node(ui.px(40, 0), ui.px(20))
	ui.add_child(&root, &cut)
	ui.layout(&root)
	testing.expect_value(t, cut.rect.w, f32(0))
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
	narrow := app.track_columns(560, .Playlist)
	testing.expect_value(t, narrow.album, f32(0))
	testing.expect_value(t, narrow.added, f32(0))
	testing.expect(t, narrow.number > 0 && narrow.cover > 0 && narrow.duration > 0)

	medium := app.track_columns(561, .Playlist)
	testing.expect_value(t, medium.album, f32(561 * 0.28))
	testing.expect_value(t, medium.added, f32(0))

	wide := app.track_columns(761, .Playlist)
	testing.expect(t, wide.album > 0)
	testing.expect_value(t, wide.added, f32(120))
	testing.expect_value(t, app.track_columns(760, .Playlist).added, f32(0))
	testing.expect_value(t, app.track_columns(2000, .Playlist).album, f32(360))

	// Only playlists have dates added.
	for kind in ([?]app.List_Kind{.Artist, .Search}) {
		undated := app.track_columns(2000, kind)
		testing.expect_value(t, undated.added, f32(0))
		testing.expect_value(t, undated.album, f32(360))
		testing.expect(t, undated.cover > 0)
	}

	// Every row of an album is the same album: no cover, no album column.
	album := app.track_columns(2000, .Album)
	testing.expect_value(t, album.cover, f32(0))
	testing.expect_value(t, album.album, f32(0))
	testing.expect_value(t, album.added, f32(0))
	testing.expect(t, album.number > 0 && album.heart > 0 && album.duration > 0 && album.more > 0)
}

// The header collapses as the list scrolls: the pinned bar's background
// fades in as the hero's bottom reaches it, its Play and title as the
// actions go under it, and the headings pin as they reach it. Search
// results have their title as the hero and pin their tabs with the
// headings once they reach the bar, which has nothing of its own.
@(test)
test_header_collapse :: proc(t: ^testing.T) {
	h := app.list_header(.Album, 1000, 0)
	testing.expect_value(t, h.hero, f32(200 + 2 * app.HERO_PAD))
	testing.expect_value(t, h.bar, f32(app.COMPACT_H))
	room := app.list_header(.Album, 1000, app.NAV_H)
	testing.expect_value(t, room.hero, h.hero + app.NAV_H - app.HERO_PAD / 2)
	table := app.header_table_y(h)
	testing.expect_value(t, app.header_rows_top(h), table + app.HEADER_H + 1 + app.LIST_PAD_Y)

	top := app.header_collapse(h, 0)
	testing.expect(t, top.bar == 0 && top.content == 0 && !top.pinned, "nothing at the top")
	half := app.header_collapse(h, h.hero - h.bar - app.BAR_FADE / 2)
	testing.expect_value(t, half.bar, f32(0.5))
	testing.expect_value(t, half.content, f32(0))
	under := app.header_collapse(h, h.hero - h.bar)
	testing.expect(t, under.bar == 1 && under.content == 0 && !under.pinned, "the bar is opaque once the hero is under it")
	at := app.header_collapse(h, table - h.bar)
	testing.expect(t, at.content == 1 && !at.pinned, "Play and the title show as the headings reach the bar")
	past := app.header_collapse(h, table - h.bar + 1)
	testing.expect(t, past.pinned && past.bar == 1 && past.content == 1, "then the headings pin")

	search := app.list_header(.Search, 1000, app.NAV_H)
	testing.expect_value(t, search.hero, f32(app.NAV_H + app.SEARCH_HEADER_H))
	testing.expect_value(t, app.header_pinned_h(search), f32(app.NAV_H + app.SEARCH_TABS_H + app.HEADER_H + 1))
	testing.expect_value(t, app.header_collapse(search, search.hero - search.bar - app.BAR_FADE / 2).bar, f32(0.5))
	testing.expect(t, !app.header_collapse(search, search.hero - search.bar).pinned)
	tabs := app.header_collapse(search, search.hero - search.bar + 1)
	testing.expect(t, tabs.pinned && tabs.bar == 1 && tabs.content == 0, "the tabs pin under an opaque bar with nothing on it")
	under_notice := app.list_header(.Search, 1000, 0)
	testing.expect(t, app.header_collapse(under_notice, app.SEARCH_HEADER_H + 1).pinned, "without the room the tabs pin at the top")
}

@(test)
test_list_duration :: proc(t: ^testing.T) {
	testing.expect_value(t, app.list_duration(51 * 60 + 2), "51 min 2 sec")
	testing.expect_value(t, app.list_duration(3 * 3600 + 20 * 60 + 59), "3 hr 20 min")
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

	// The press clicks, and the release doesn't click again.
	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 1})
	testing.expect(t, sig.held && sig.clicked && !sig.dragging)
	sig, _ = frame(&u, &now, {kind = .Mouse_Move, x = 200, y = 150})
	testing.expect(t, sig.dragging && !sig.clicked)
	testing.expect_value(t, sig.drag_delta, [2]f32{180, 130})
	testing.expect(t, !sig.hovering, "only hovering while over it")
	sig, _ = frame(&u, &now, {kind = .Mouse_Up, x = 200, y = 150})
	testing.expect(t, sig.released && !sig.clicked)

	// Right and control clicks. Control-click is a right click on macOS only.
	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, button = .Right})
	testing.expect(t, sig.right_clicked)
	frame(&u, &now, {kind = .Mouse_Up, x = 20, y = 20, button = .Right})
	sig, _ = frame(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, modifiers = {.Control}})
	if ui.CONTROL_CLICK_IS_RIGHT {
		testing.expect(t, sig.right_clicked && !sig.pressed)
	} else {
		testing.expect(t, sig.pressed && !sig.right_clicked)
	}
	frame(&u, &now, {kind = .Mouse_Up, x = 20, y = 20})
	testing.expect_value(t, u.input.buttons, platform.Mouse_Buttons{})

	// Tab focuses it, Enter clicks it, Escape drops the focus.
	frame(&u, &now, {kind = .Mouse_Down, x = 250, y = 150}, {kind = .Mouse_Up, x = 250, y = 150})
	sig, _ = frame(&u, &now, {kind = .Key_Down, key = .Tab})
	testing.expect(t, ui.has_focus(sig.box))
	sig, _ = frame(&u, &now, {kind = .Key_Down, key = .Return})
	testing.expect(t, sig.clicked && sig.keyboard)
	sig, _ = frame(&u, &now, {kind = .Key_Down, key = .Escape})
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

// A trackpad pulls a view past its ends against a spring, and the view
// goes back once the fingers lift. A wheel doesn't.
@(test)
test_ui_stretch :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer {
		delete(u.boxes)
		delete(u.table)
		delete(u.hits)
		free_all(context.temp_allocator)
	}
	list_frame :: proc(u: ^ui.State, time: f64, events: ..platform.Event) -> (list: ^ui.Box, row: ^ui.Box, animating: bool) {
		ui.begin_frame(u, events, nil, nil, 300, 200, time)
		list = ui.box_make("list", {.View_Scroll, .Allow_Overflow_Y, .Clip}, ui.px(300), ui.px(200))
		list.child_axis = .Y
		ui.push_parent(list)
		row = ui.box_make("row", {}, ui.fill(), ui.px(1000))
		ui.pop_parent()
		animating = ui.end_frame()
		return
	}
	settle :: proc(u: ^ui.State, now: ^f64) -> (list: ^ui.Box, row: ^ui.Box, animating: bool) {
		for _ in 0 ..< 300 {
			now^ += 1.0 / 120
			list, row, animating = list_frame(u, now^)
			if !animating {
				break
			}
		}
		return
	}
	scroll :: proc(dy: f32, time: f64, phase: platform.Scroll_Phase = .Changed, momentum: platform.Scroll_Phase = .None) -> platform.Event {
		return {kind = .Scroll, x = 50, y = 50, dy = dy, time = time, precise = true, phase = phase, momentum_phase = momentum}
	}
	now := 0.0
	list_frame(&u, now)
	now += 0.01
	list_frame(&u, now)

	// 200 points past the top stretch it by a twentieth of that, and the
	// row moves down with it while the offset stays at 0.
	now += 0.01
	list, row, _ := list_frame(&u, now, scroll(0, now, .Began))
	now += 0.01
	list, row, _ = list_frame(&u, now, scroll(200, now))
	testing.expect_value(t, list.view_off.y, f32(0))
	testing.expect_value(t, list.stretch.amount.y, f32(-10))
	now += 0.01
	list, row, _ = list_frame(&u, now)
	testing.expect_value(t, row.rect.y, f32(10))

	// Scrolling back takes the stretch in one to one before the view moves.
	now += 0.01
	list, row, _ = list_frame(&u, now, scroll(-4, now))
	testing.expect_value(t, list.stretch.amount.y, f32(-6))
	testing.expect_value(t, list.view_off.y, f32(0))
	now += 0.01
	list, row, _ = list_frame(&u, now, scroll(-26, now))
	testing.expect_value(t, list.stretch.amount.y, f32(0))
	testing.expect_value(t, list.view_off.y, f32(20))

	// Held there, it asks for no frames. Lifted, it goes back and stops.
	now += 0.01
	list, row, _ = list_frame(&u, now, scroll(220, now))
	testing.expect_value(t, list.stretch.amount.y, f32(-10))
	now += 0.01
	_, _, animating := list_frame(&u, now)
	testing.expect(t, !animating)
	now += 0.01
	list, row, animating = list_frame(&u, now, scroll(0, now, .Ended))
	testing.expect(t, animating)
	list, row, animating = settle(&u, &now)
	testing.expect(t, !animating)
	testing.expect_value(t, list.stretch, ui.Stretch{})
	testing.expect_value(t, row.rect.y, f32(0))

	// The momentum after a lift keeps pushing at the top long after the
	// bounce. It doesn't stretch the view again once the bounce is over.
	now += 0.01
	list_frame(&u, now, scroll(0, now, .Began))
	now += 0.01
	list_frame(&u, now, scroll(200, now))
	now += 0.01
	list_frame(&u, now, scroll(0, now, .Ended))
	now += 0.01
	list_frame(&u, now, scroll(20, now, .None, .Began))
	for _ in 0 ..< 120 {
		now += 1.0 / 120
		list, row, _ = list_frame(&u, now, scroll(60, now, .None, .Changed))
	}
	testing.expect_value(t, list.stretch.amount.y, f32(0))
	now += 1.0 / 120
	list, row, animating = list_frame(&u, now, scroll(0, now, .None, .Ended))
	testing.expect(t, !animating)
	testing.expect_value(t, list.stretch, ui.Stretch{})

	// A stray move under 10 points doesn't stretch it.
	now += 0.01
	list_frame(&u, now, scroll(0, now, .Began))
	now += 0.01
	list, row, _ = list_frame(&u, now, scroll(6, now))
	testing.expect_value(t, list.stretch.amount.y, f32(0))
	now += 0.01
	list_frame(&u, now, scroll(0, now, .Ended))

	// A wheel past the top doesn't stretch it.
	now += 0.01
	list, row, _ = list_frame(&u, now, {kind = .Scroll, x = 50, y = 50, dy = 20})
	testing.expect_value(t, list.stretch.amount.y, f32(0))
	settle(&u, &now)

	// Momentum that runs into the end carries the stretch on past where it
	// hit, then brings it back.
	now += 0.01
	list_frame(&u, now, scroll(0, now, .Began))
	now += 0.01
	list_frame(&u, now, scroll(-780, now))
	now += 0.01
	list_frame(&u, now, scroll(0, now, .Ended))
	now += 0.01
	list_frame(&u, now, scroll(-10, now, .None, .Began))
	for _ in 0 ..< 2 {
		now += 1.0 / 120
		list_frame(&u, now, scroll(-25, now, .None, .Changed))
	}
	now += 1.0 / 120
	list, row, _ = list_frame(&u, now, scroll(-25, now, .None, .Changed))
	testing.expect_value(t, list.view_off.y, f32(800))
	hit := list.stretch.amount.y
	testing.expect(t, hit > 0)
	peak := hit
	for _ in 0 ..< 300 {
		now += 1.0 / 120
		list, row, animating = list_frame(&u, now, scroll(-5, now, .None, .Changed))
		peak = max(peak, list.stretch.amount.y)
		if !animating {
			break
		}
	}
	testing.expect(t, peak > hit)
	testing.expect(t, !animating)
	testing.expect_value(t, list.stretch.amount.y, f32(0))
	testing.expect_value(t, list.view_off.y, f32(800))
}

// At a fractional scale a scroll moves content by whole pixels, so text,
// which lands on a whole pixel row, keeps its place against the rects
// around it. Moved by a fraction of a pixel it jumped a pixel against
// them at some offsets.
@(test)
test_ui_scroll_whole_pixels :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	r: render.Renderer
	r.scale = 1.6
	// Enough for end_frame to push the list's clip, without a GPU.
	r.clip_depth = 1
	r.clips[0] = {-1e9, -1e9, 1e9, 1e9}
	rows: [4]^ui.Box
	list_frame :: proc(u: ^ui.State, r: ^render.Renderer, rows: ^[4]^ui.Box, time: f64, events: ..platform.Event) -> ^ui.Box {
		ui.begin_frame(u, events, r, nil, 300, 200, time)
		list := ui.box_make("list", {.View_Scroll, .Allow_Overflow_Y, .Clip}, ui.px(300), ui.px(200))
		list.child_axis = .Y
		ui.push_parent(list)
		for &row, i in rows {
			row = ui.box_make(fmt.tprintf("##row%d", i), {}, ui.fill(), ui.px(56))
		}
		ui.box_make("", {}, ui.fill(), ui.px(1000))
		ui.pop_parent()
		ui.end_frame()
		return list
	}
	now := 0.0
	list_frame(&u, &r, &rows, now)
	for step in 0 ..< 20 {
		now += 0.01
		list := list_frame(&u, &r, &rows, now, {kind = .Scroll, x = 50, y = 50, dy = -0.37, precise = true, phase = .Changed})
		testing.expect(t, list.view_off.y > 0)
		for row, i in rows {
			moved := (f32(i) * 56 - (row.rect.y - list.rect.y)) * r.scale
			testing.expectf(t, abs(moved - math.round(moved)) < 1e-3, "step %d row %d moved %v px", step, i, moved)
		}
	}
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

// Rows after a 300 pt header that scrolls with them, inside a column of
// their own: none are built while the header fills the view, and once it
// has scrolled away they're the ones in view, each where it's drawn.
@(test)
test_virtual_rows_after_header :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	frame :: proc(u: ^ui.State, now: ^f64, offset: f32) -> (view: ^ui.Box, rows: ui.Virtual_Rows) {
		now^ += 1.0 / 120
		ui.begin_frame(u, nil, nil, nil, 300, 200, now^)
		{
			view = ui.scroll_view("view", ui.fill(), ui.fill())
			view.view_off.y, view.view_off_target.y = offset, offset
			ui.spacer(ui.px(300))
			ui.column("rows", {}, ui.fill(), ui.children_sum())
			rows = ui.virtual_rows(view, 100, 10, 300)
			for i in rows.first ..< rows.last {
				ui.box_make(fmt.tprintf("##row%d", i), {.Clickable}, ui.fill(), ui.px(10))
			}
		}
		ui.end_frame()
		return
	}
	frame(&u, &now, 0)
	_, rows := frame(&u, &now, 0)
	testing.expect_value(t, rows.last - rows.first, 0)
	_, rows = frame(&u, &now, 350)
	testing.expect_value(t, rows.first, 4)
	testing.expect_value(t, rows.last, 26)
	frame(&u, &now, 350)
	view, _ := frame(&u, &now, 350)
	row := ui.box_lookup(&u, ui.key_from_string(ui.key_from_string(view.key, "rows"), "##row5"))
	testing.expect(t, row != nil && row.rect.y == view.rect.y, "row 5 at the top of the view")
	testing.expect_value(t, view.view_bounds.y, f32(300 + 100 * 10))
}

// A vertical page in a 300 by 200 window: a 20 pt focusable item, then a
// 50 pt shelf that scrolls sideways through ten 100 pt focusable cards,
// then 1000 pt of space. right_taken says whether the app got a Right.
@(private = "file")
shelf_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (page, shelf: ^ui.Box, right_taken, animating: bool) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	{
		page = ui.scroll_view("page", ui.fill(), ui.fill())
		ui.box_make("##item", {.Focusable, .Clickable}, ui.fill(), ui.px(20))
		shelf = ui.box_make("shelf", {.View_Scroll, .Clip, .Allow_Overflow_X}, ui.fill(), ui.px(50))
		shelf.child_axis = .X
		ui.push_parent(shelf)
		for i in 0 ..< 10 {
			ui.box_make(fmt.tprintf("##card%d", i), {.Focusable, .Clickable}, ui.px(100), ui.px(50))
		}
		ui.pop_parent()
		ui.box_make("", {}, ui.fill(), ui.px(1000))
	}
	right_taken = ui.take_key(.Right)
	animating = ui.end_frame()
	return
}

@(private = "file")
shelf_settle :: proc(u: ^ui.State, now: ^f64) -> (page, shelf: ^ui.Box, settled: bool) {
	animating: bool
	for _ in 0 ..< 300 {
		page, shelf, _, animating = shelf_frame(u, now)
		if !animating {
			return page, shelf, true
		}
	}
	return
}

@(test)
test_ui_scroll_per_axis :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	shelf_settle(&u, &now)

	page, shelf, _, _ := shelf_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 40}, {kind = .Scroll, dx = -40, dy = -30, precise = true, phase = .Began})
	testing.expect_value(t, shelf.view_off.x, f32(40))
	testing.expect_value(t, page.view_off.y, f32(30))
	page, shelf, _, _ = shelf_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 150}, {kind = .Scroll, dx = -10, dy = -10, precise = true, momentum_phase = .Changed})
	testing.expect_value(t, shelf.view_off.x, f32(50))
	testing.expect_value(t, page.view_off.y, f32(40))
	shelf_settle(&u, &now)

	page, shelf, _, _ = shelf_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 20}, {kind = .Scroll, dy = -2})
	testing.expect_value(t, page.view_off_target.y, f32(40 + 2 * ui.SCROLL_LINE))
	testing.expect_value(t, shelf.view_off_target.x, f32(50))
}

@(test)
test_ui_focus_reveals_on_both_axes :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	shelf_settle(&u, &now)
	shelf_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 150}, {kind = .Scroll, dy = -500, precise = true, phase = .Began})
	page, shelf, _ := shelf_settle(&u, &now)
	testing.expect_value(t, page.view_off.y, f32(500))

	// Card 9 is 900 to 1000 across and 20 to 70 down, above the page's view.
	shelf_frame(&u, &now, {kind = .Access_Focus, target = u64(ui.key_from_string(shelf.key, "##card9"))})
	page, shelf, _ = shelf_settle(&u, &now)
	testing.expect_value(t, page.view_off.y, f32(20))
	testing.expect_value(t, shelf.view_off.x, 1000 - shelf.rect.w)
}

// A focusable table of 100 rows after a header, 1000 pt in a 200 pt view,
// the way the track list builds it. Tab into it keeps the view where it
// is while the table shows, at the header and in the middle of the rows,
// and brings its first rows in when it doesn't.
@(test)
test_ui_focus_keeps_a_table_taller_than_the_view :: proc(t: ^testing.T) {
	frame :: proc(u: ^ui.State, now: ^f64, header: f32, offset: Maybe(f32), events: ..platform.Event) -> (view, table: ^ui.Box, animating: bool) {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		{
			view = ui.scroll_view("view", ui.fill(), ui.fill())
			if y, ok := offset.?; ok {
				view.view_off.y, view.view_off_target.y = y, y
			}
			ui.spacer(ui.px(header))
			table = ui.column("rows", {.Focusable}, ui.fill(), ui.children_sum())
			rows := ui.virtual_rows(view, 100, 10, header)
			for i in rows.first ..< rows.last {
				ui.box_make(fmt.tprintf("##row%d", i), {.Clickable}, ui.fill(), ui.px(10))
			}
		}
		animating = ui.end_frame()
		return
	}
	Case :: struct {
		header, start, want: f32,
	}
	for c in ([]Case{{150, 0, 0}, {150, 600, 600}, {300, 0, 300}}) {
		u: ui.State
		ui.init(&u)
		defer ui_destroy(&u)
		now := 0.0
		frame(&u, &now, c.header, c.start)
		_, table, _ := frame(&u, &now, c.header, c.start)
		frame(&u, &now, c.header, nil, {kind = .Key_Down, key = .Tab})
		testing.expect_value(t, u.focus, table.key)
		view: ^ui.Box
		for _ in 0 ..< 300 {
			animating: bool
			view, _, animating = frame(&u, &now, c.header, nil)
			if !animating {
				break
			}
		}
		testing.expectf(t, view.view_off.y == c.want, "header %v, focus from %v scrolled to %v, want %v", c.header, c.start, view.view_off.y, c.want)
	}
}

@(test)
test_ui_left_right_in_a_row :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	page, shelf, _ := shelf_settle(&u, &now)
	card :: proc(shelf: ^ui.Box, i: int) -> ui.Key {
		return ui.key_from_string(shelf.key, fmt.tprintf("##card%d", i))
	}

	shelf_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 40, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 40, click_count = 1})
	testing.expect_value(t, u.focus, card(shelf, 0))
	_, _, taken, _ := shelf_frame(&u, &now, {kind = .Key_Down, key = .Right})
	testing.expect_value(t, u.focus, card(shelf, 1))
	testing.expect(t, !taken, "the row took Right")
	shelf_frame(&u, &now, {kind = .Key_Down, key = .Left})
	testing.expect_value(t, u.focus, card(shelf, 0))

	shelf_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 10, click_count = 1}, {kind = .Mouse_Up, x = 50, y = 10, click_count = 1})
	item := ui.key_from_string(page.key, "##item")
	testing.expect_value(t, u.focus, item)
	_, _, taken, _ = shelf_frame(&u, &now, {kind = .Key_Down, key = .Right})
	testing.expect_value(t, u.focus, item)
	testing.expect(t, taken, "the app sees Right")
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
		{
			ui.scroll_view("view", ui.px(100 + f32(i)), ui.px(100))
		}
		if ui.end_frame() {
			asked += 1
		}
	}
	testing.expectf(t, asked <= 4, "asked for %d frames", asked)
}

// A 300 by 200 window with 100 rows of 10 pt and the scrollbar in mode.
@(private = "file")
bar_frame :: proc(u: ^ui.State, now: ^f64, mode: ui.Scrollbars, events: ..platform.Event) -> (view, row: ^ui.Box, animating: bool) {
	now^ += 1.0 / 120
	u.scrollbars = mode
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	{
		view = ui.scroll_view("view", ui.fill(), ui.fill())
		rows := ui.virtual_rows(view, 100, 10)
		for i in rows.first ..< rows.last {
			b := ui.box_make(fmt.tprintf("##row%d", i), {.Clickable, .Focusable}, ui.fill(), ui.px(10))
			if i == rows.first {
				row = b
			}
		}
	}
	animating = ui.end_frame()
	return
}

@(private = "file")
bar_settle :: proc(u: ^ui.State, now: ^f64, mode: ui.Scrollbars) -> (view, row: ^ui.Box, settled: bool) {
	animating: bool
	for _ in 0 ..< 600 {
		view, row, animating = bar_frame(u, now, mode)
		if !animating {
			return view, row, true
		}
	}
	return
}

@(test)
test_ui_scrollbar_floating :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	view, row, settled := bar_settle(&u, &now, .Floating)
	testing.expect(t, settled)
	testing.expect_value(t, row.rect.w, f32(300))

	// Scrolling shows it, and then nothing asks for frames until it's
	// time to hide it.
	view, _, _ = bar_frame(&u, &now, .Floating, {kind = .Scroll, x = 50, y = 50, dy = -100, precise = true, phase = .Began})
	view, _, settled = bar_settle(&u, &now, .Floating)
	testing.expect(t, settled)
	testing.expect_value(t, view.bar_t, f32(1))
	testing.expect(t, u.wake > now, "it asks to wake up to hide")

	// It hides once the linger is over, then settles.
	now += ui.SCROLLBAR_LINGER
	view, _, settled = bar_settle(&u, &now, .Floating)
	testing.expect(t, settled)
	testing.expect_value(t, view.bar_t, f32(0))

	// The mouse coming into the view shows it for a moment, not for as
	// long as it stays.
	bar_frame(&u, &now, .Floating, {kind = .Mouse_Move, x = 50, y = 50})
	view, _, _ = bar_settle(&u, &now, .Floating)
	testing.expect_value(t, view.bar_t, f32(1))
	now += ui.SCROLLBAR_LINGER
	view, _, settled = bar_settle(&u, &now, .Floating)
	testing.expect(t, settled)
	testing.expect_value(t, view.bar_t, f32(0))

	// So does the focus moving into it.
	bar_frame(&u, &now, .Floating, {kind = .Key_Down, key = .Tab})
	view, _, _ = bar_settle(&u, &now, .Floating)
	testing.expect_value(t, view.bar_t, f32(1))
	now += ui.SCROLLBAR_LINGER
	view, _, _ = bar_settle(&u, &now, .Floating)
	testing.expect_value(t, view.bar_t, f32(0))
}

@(test)
test_ui_scrollbar_docked_and_never :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	// Docked takes a gutter from the rows and stays.
	view, row, settled := bar_settle(&u, &now, .Docked)
	testing.expect(t, settled)
	testing.expect_value(t, row.rect.w, f32(300 - ui.SCROLLBAR_TRACK))
	testing.expect_value(t, view.bar_t, f32(1))
	now += 10
	view, _, _ = bar_settle(&u, &now, .Docked)
	testing.expect_value(t, view.bar_t, f32(1))

	view, row, settled = bar_settle(&u, &now, .Never)
	testing.expect(t, settled)
	testing.expect_value(t, row.rect.w, f32(300))
	testing.expect_value(t, view.bar_t, f32(0))
}

// A header above a docked list leaves the list's gutter, so the right
// column of the header and of the rows line up.
@(test)
test_ui_scrollbar_header_gutter :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	u.scrollbars = .Docked
	now := 0.0
	head, cell: ^ui.Box
	for _ in 0 ..< 10 {
		now += 1.0 / 120
		ui.begin_frame(&u, {}, nil, nil, 300, 200, now)
		{
			ui.column("main", {}, ui.fill(), ui.fill())
			{
				ui.row("", {}, ui.fill(), ui.px(20))
				ui.spacer(ui.fill())
				head = ui.box_make("", {}, ui.px(40), ui.fill())
				ui.spacer(ui.px(ui.scroll_gutter("view")))
			}
			{
				view := ui.scroll_view("view", ui.fill(), ui.fill())
				rows := ui.virtual_rows(view, 100, 10)
				for i in rows.first ..< rows.last {
					ui.row(fmt.tprintf("##row%d", i), {}, ui.fill(), ui.px(10))
					ui.spacer(ui.fill())
					c := ui.box_make("", {}, ui.px(40), ui.fill())
					if i == rows.first {
						cell = c
					}
				}
			}
		}
		ui.end_frame()
	}
	testing.expect_value(t, cell.rect.x, f32(300 - ui.SCROLLBAR_TRACK - 40))
	testing.expect_value(t, head.rect.x, cell.rect.x)
}

// A list's pad keeps its rows off both sides, inside the gutter, and off
// the top and the bottom of its content. The scrollbar stays at the view's
// edge, and the rows built are still the ones in view when scrolled to the
// end. The pad is taller than a row, so rows missed at the top would show.
@(test)
test_ui_pad :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	u.scrollbars = .Docked
	now := 0.0
	view, first, last: ^ui.Box
	first_i, built: int
	frame :: proc(u: ^ui.State, now: ^f64, scroll: f32) -> (view, first, last: ^ui.Box, first_i, built: int) {
		now^ += 1.0 / 120
		ui.begin_frame(u, {}, nil, nil, 300, 200, now^)
		{
			ui.column("main", {}, ui.fill(), ui.fill())
			{
				view = ui.scroll_view("view", ui.fill(), ui.fill())
				view.pad = {16, 25}
				view.view_off.y = scroll
				rows := ui.virtual_rows(view, 100, 10)
				for i in rows.first ..< rows.last {
					r := ui.row(fmt.tprintf("##row%d", i), {}, ui.fill(), ui.px(10))
					if i == rows.first {
						first, first_i = r, i
					}
					last = r
					built = i
				}
			}
		}
		ui.end_frame()
		return
	}
	for _ in 0 ..< 10 {
		view, first, last, first_i, built = frame(&u, &now, 0)
	}
	testing.expect_value(t, first.rect.x, f32(16))
	testing.expect_value(t, first.rect.w, f32(300 - 32 - ui.SCROLLBAR_TRACK))
	testing.expect_value(t, first.rect.y, f32(25))
	testing.expect_value(t, view.last.rect.x, f32(300 - ui.SCROLLBAR_TRACK))
	testing.expect_value(t, view.view_bounds.y, f32(100 * 10 + 50))

	// Row 0 still shows from 25 to 35, under a view scrolled by 30.
	for _ in 0 ..< 2 {
		view, first, last, first_i, built = frame(&u, &now, 30)
	}
	testing.expect_value(t, first_i, 0)

	for _ in 0 ..< 2 {
		view, first, last, first_i, built = frame(&u, &now, 100 * 10 + 50 - 200)
	}
	testing.expect_value(t, built, 99)
	testing.expect_value(t, last.rect.y + last.rect.h, f32(200 - 25))
}

@(test)
test_ui_scrollbar_drag :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	bar_settle(&u, &now, .Docked)
	// The thumb is 196 * 200 / 1000 tall at the top of the track. A press
	// at the track's bottom centres it there: all the way down.
	x := f32(300 - ui.SCROLLBAR_TRACK / 2)
	bar_frame(&u, &now, .Docked, {kind = .Mouse_Move, x = x, y = 199})
	bar_frame(&u, &now, .Docked, {kind = .Mouse_Down, button = .Left, x = x, y = 199})
	view, _, _ := bar_frame(&u, &now, .Docked)
	testing.expect_value(t, view.view_off.y, f32(800))
	// Dragging back up moves the view with it.
	bar_frame(&u, &now, .Docked, {kind = .Mouse_Move, x = x, y = 2})
	view, _, _ = bar_frame(&u, &now, .Docked, {kind = .Mouse_Up, button = .Left, x = x, y = 2})
	testing.expect_value(t, view.view_off.y, f32(0))
}

Menu_Frame :: struct {
	area, a, b: ui.Signal,
	animating:  bool,
}

// A focusable area that opens a menu with items A and B on a right click
// or a key.
@(private = "file")
menu_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (f: Menu_Frame) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	ui.box_make("play", {.Clickable, .Focusable}, ui.px(100), ui.px(40))
	area := ui.box_make("area", {.Clickable, .Focusable}, ui.px(300), ui.px(100))
	f.area = ui.signal(area)
	if f.area.right_clicked || f.area.keyboard {
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
	f := menu_frame(&u, &now, {kind = .Key_Down, key = .Tab}, {kind = .Key_Down, key = .Tab})
	testing.expect(t, ui.has_focus(f.area.box))

	// Opening the menu with the mouse highlights nothing. Down highlights
	// the first item.
	f = menu_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 60, button = .Right}, {kind = .Mouse_Up, x = 50, y = 60, button = .Right})
	testing.expect(t, f.a.box != nil && !ui.has_focus(f.a.box) && !ui.has_focus(f.b.box), "no item has the focus")
	testing.expect(t, !ui.has_focus(f.area.box), "the area behind the menu loses the focus")
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Down})
	testing.expect(t, ui.has_focus(f.a.box), "Down highlights the first item")

	// Tab and the arrows stay inside the menu.
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Tab})
	testing.expect(t, ui.has_focus(f.b.box))
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Tab})
	testing.expect(t, ui.has_focus(f.a.box), "Tab wraps within the menu")
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Down})
	testing.expect(t, ui.has_focus(f.b.box))

	// Enter clicks the item, not the box focused behind the menu, then the
	// focus goes back to it.
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Return})
	testing.expect(t, f.b.clicked && f.b.keyboard)
	testing.expect(t, !f.area.clicked, "the background box isn't clicked")
	testing.expect(t, ui.has_focus(f.area.box), "the focus is back on the area")

	// Escape closes it the same way, and Enter with the background focus
	// set from outside the menu does nothing while it's open.
	f = menu_frame(&u, &now)
	f = menu_frame(&u, &now, {kind = .Mouse_Down, x = 50, y = 60, button = .Right}, {kind = .Mouse_Up, x = 50, y = 60, button = .Right})
	ui.set_focus(f.area.box)
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Return})
	testing.expect(t, !f.area.clicked && !f.a.clicked && !f.b.clicked)
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Escape})
	testing.expect(t, ui.has_focus(f.area.box))
	for _ in 0 ..< 100 {
		if f = menu_frame(&u, &now); !f.animating {
			break
		}
	}
	testing.expect(t, !f.animating, "the menu fades out and frames stop")
	testing.expect(t, f.a.box == nil)

	// Opening it from the keyboard highlights the first item.
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Return})
	f = menu_frame(&u, &now)
	testing.expect(t, f.a.box != nil && ui.has_focus(f.a.box), "the first item has the focus")
	testing.expect_value(t, f.a.box.focus_t, f32(0))
}

Space_Frame :: struct {
	button, area, item: ui.Signal,
	field:              ui.Field_Signal,
	field_box:          ^ui.Box,
	space, held, text:  bool, // what take_key and text_focused said after the views
}

// A button, a text field, and an area that opens a menu with one item on a
// right click. After building them it asks for Space as the app does.
@(private = "file")
space_frame :: proc(u: ^ui.State, field: ^ui.Text_Field, now: ^f64, events: ..platform.Event) -> (f: Space_Frame) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 600, 200, now^)
	f.button = ui.signal(ui.box_make("button", {.Clickable, .Focusable}, ui.px(100), ui.px(40)))
	f.field = ui.text_field("field", field, "Search", ui.px(200), 30)
	f.field_box = ui.find("field")
	f.area = ui.signal(ui.box_make("area", {.Clickable, .Focusable}, ui.px(200), ui.px(100)))
	if f.area.right_clicked {
		ui.open_menu("menu", ui.mouse())
	}
	if ui.menu("menu") {
		f.item = ui.menu_item("Item##item")
	}
	f.text = ui.text_focused()
	f.space = ui.take_key(.Space, repeats = false)
	f.held = ui.take_key(.Space)
	ui.end_frame()
	return
}

// Space clicks only in a menu. With a button focused by a click it goes to
// the app, which plays and pauses with it; a text field keeps it, and a
// held Space repeats only for a caller that asks for repeats.
@(test)
test_ui_space_goes_to_the_app :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	field := new(ui.Text_Field)
	defer free(field)
	now := 0.0
	space_frame(&u, field, &now)
	space_frame(&u, field, &now)

	f := space_frame(&u, field, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 1}, {kind = .Mouse_Up, x = 20, y = 20})
	testing.expect(t, ui.has_focus(f.button.box), "the click focuses the button")
	f = space_frame(&u, field, &now, {kind = .Key_Down, key = .Space})
	testing.expect(t, !f.button.clicked, "Space doesn't click the focused button")
	testing.expect(t, f.space && !f.text, "Space waits for the app")
	f = space_frame(&u, field, &now, {kind = .Key_Down, key = .Space, repeat = true})
	testing.expect(t, !f.space, "a repeated Space is skipped with repeats = false")
	testing.expect(t, f.held, "and taken with repeats")
	f = space_frame(&u, field, &now, {kind = .Key_Down, key = .Return})
	testing.expect(t, f.button.clicked && f.button.keyboard, "Enter still clicks it")

	r := f.field_box.rect
	f = space_frame(&u, field, &now, {kind = .Mouse_Down, x = r.x + 10, y = r.y + 10, click_count = 1}, {kind = .Mouse_Up, x = r.x + 10, y = r.y + 10})
	testing.expect(t, f.field.focused)
	f = space_frame(&u, field, &now, {kind = .Key_Down, key = .Space})
	testing.expect(t, f.text, "text_focused says the field has the focus")

	// A menu opened with the mouse and highlighted with Down: Space clicks
	// the item. With nothing highlighted it does nothing, not even play.
	a := f.area.box.rect
	space_frame(&u, field, &now, {kind = .Mouse_Down, x = a.x + 10, y = a.y + 10, button = .Right}, {kind = .Mouse_Up, x = a.x + 10, y = a.y + 10, button = .Right})
	f = space_frame(&u, field, &now, {kind = .Key_Down, key = .Space})
	testing.expect(t, !f.space && !f.item.clicked, "Space in a menu with nothing highlighted goes nowhere")
	space_frame(&u, field, &now, {kind = .Key_Down, key = .Down})
	f = space_frame(&u, field, &now, {kind = .Key_Down, key = .Space})
	testing.expect(t, f.item.clicked && f.item.keyboard, "Space clicks the highlighted item")
	testing.expect(t, !f.space)
}

// A hover that ends partway fades out from where it reached, at the fade's
// normal speed, and hot_t follows smoothstep of that progress both ways.
@(test)
test_ui_hover_fade_reverses_from_where_it_is :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	dt := 1.0 / 120
	now := 0.0
	step := f32(dt) / ui.FADE_OUT
	follows_curve :: proc(b: ^ui.Box) -> bool {
		f := b.hot_fade
		return abs(b.hot_t - f * f * (3 - 2 * f)) < 1e-5
	}

	sig: ui.Signal
	for _ in 0 ..< 3 {
		now += dt
		sig, _ = button_frame(&u, nil, now)
	}
	now += dt
	sig, _ = button_frame(&u, {{kind = .Mouse_Move, x = 20, y = 20}}, now)
	for _ in 0 ..< 200 {
		if sig.box.hot_fade >= 0.4 {
			break
		}
		now += dt
		sig, _ = button_frame(&u, nil, now)
	}
	testing.expect(t, sig.box.hot_fade >= 0.4 && sig.box.hot_fade < 1, "the hover stops partway")
	testing.expect(t, follows_curve(sig.box), "hot_t follows smoothstep on the way in")

	now += dt
	sig, _ = button_frame(&u, {{kind = .Mouse_Move, x = 250, y = 150}}, now)
	now += dt
	sig, _ = button_frame(&u, nil, now)
	start := sig.box.hot_fade
	testing.expect(t, start < 1)

	frames := 0
	animating := true
	for animating && frames < 200 {
		before := sig.box.hot_fade
		now += dt
		sig, animating = button_frame(&u, nil, now)
		frames += 1
		testing.expect(t, follows_curve(sig.box), "hot_t follows smoothstep on the way out")
		if sig.box.hot_fade > 0 {
			testing.expect(t, abs(before - sig.box.hot_fade - step) < 1e-3, "the fade keeps a constant speed")
		}
	}
	testing.expect(t, abs(f32(frames) - start / step) <= 1, "the way back is as long as the distance")
	testing.expect_value(t, sig.box.hot_t, f32(0))
}

// An Instant_Hover box lights and goes dark as the mouse moves on and off,
// and asks for no frames to do it.
@(test)
test_ui_instant_hover_has_no_fade :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (^ui.Box, bool) {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		b := ui.box_make("row", {.Clickable, .Instant_Hover}, ui.px(100), ui.px(40))
		ui.signal(b)
		return b, ui.end_frame()
	}

	frame(&u, &now)
	frame(&u, &now)
	b, animating := frame(&u, &now, {kind = .Mouse_Move, x = 20, y = 20})
	testing.expect_value(t, b.hot_t, f32(1))
	testing.expect(t, !animating, "lighting up takes no frames")
	b, animating = frame(&u, &now, {kind = .Mouse_Move, x = 250, y = 150})
	testing.expect_value(t, b.hot_t, f32(0))
	testing.expect(t, !animating, "going dark takes no frames")
}

// Ten 40 pt Instant_Hover rows in a 300 by 200 scroll view, each with a
// mark that shows while its row is lit, as a track row's buttons do.
@(private = "file")
Scrolled_Rows :: struct {
	rows:      [10]^ui.Box,
	marks:     [10]^ui.Box,
	animating: bool,
}

@(private = "file")
scrolled_rows_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (f: Scrolled_Rows) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	list := ui.box_make("list", {.View_Scroll, .Allow_Overflow_Y, .Clip}, ui.px(300), ui.px(200))
	list.child_axis = .Y
	ui.push_parent(list)
	for i in 0 ..< len(f.rows) {
		f.rows[i] = ui.box_make(fmt.tprintf("##row%d", i), {.Clickable, .Instant_Hover}, ui.fill(), ui.px(40))
		ui.signal(f.rows[i])
		ui.push_parent(f.rows[i])
		f.marks[i] = ui.box_make("", {}, ui.px(10), ui.px(10))
		f.marks[i].opacity = 0
		ui.show_on_hover(f.marks[i], f.rows[i])
		ui.pop_parent()
	}
	ui.pop_parent()
	f.animating = ui.end_frame()
	return
}

// only_lit says whether row lit is the only lit one, and its mark the
// only one showing.
@(private = "file")
only_lit :: proc(f: Scrolled_Rows, lit: int) -> bool {
	for i in 0 ..< len(f.rows) {
		want := f32(1 if i == lit else 0)
		if f.rows[i].hot_t != want || ui.drawn_opacity(f.marks[i]) != want {
			return false
		}
	}
	return true
}

// A row that scrolls under a still mouse is lit in the frame it gets
// there, and the lit row is the one under the mouse in that frame's
// layout, not the one that was there before. What shows with the row,
// though built before the layout, agrees with it.
@(test)
test_ui_instant_hover_follows_rows_scrolled_under_a_still_mouse :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	scrolled_rows_frame(&u, &now)
	scrolled_rows_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 60})
	f := scrolled_rows_frame(&u, &now)
	testing.expect(t, only_lit(f, 1), "row 1 is lit")
	testing.expect(t, !f.animating)

	// One row up, at once: row 2 is under the mouse now.
	f = scrolled_rows_frame(&u, &now, {kind = .Scroll, x = 50, y = 60, dy = -40, precise = true, phase = .Began})
	testing.expect_value(t, f.rows[2].rect.y, f32(40))
	testing.expect(t, only_lit(f, 2), "row 2 is lit in the frame it comes under the mouse")

	// The next frames agree, and nothing fades.
	for _ in 0 ..< 10 {
		if f = scrolled_rows_frame(&u, &now); !f.animating {
			break
		}
		testing.expect(t, only_lit(f, 2), "row 2 stays lit")
	}
	testing.expect(t, !f.animating, "the rows settle")
	testing.expect(t, only_lit(f, 2), "row 2 stays lit")

	// To the end, 200 pt down: row 6 is at 40.
	f = scrolled_rows_frame(&u, &now, {kind = .Scroll, x = 50, y = 60, dy = -160, precise = true, phase = .Changed})
	testing.expect_value(t, f.rows[6].rect.y, f32(40))
	testing.expect(t, only_lit(f, 6), "row 6 is lit in the frame it comes under the mouse")
}

// refresh_frame is button_frame on a display whose refresh interval the
// shell reports as refresh, 0 for unknown.
@(private = "file")
refresh_frame :: proc(u: ^ui.State, events: []platform.Event, time: f64, refresh: f32) -> (ui.Signal, bool) {
	ui.begin_frame(u, events, nil, nil, 300, 200, time, nil, nil, refresh)
	b := ui.box_make("button", {.Clickable, .Focusable}, ui.px(100), ui.px(40))
	sig := ui.signal(b)
	return sig, ui.end_frame()
}

// hover_run moves the mouse onto the button, or off it, and runs frames
// every interval seconds until the fade settles.
@(private = "file")
hover_run :: proc(u: ^ui.State, now: ^f64, on: bool, interval: f64, refresh: f32) {
	now^ += interval
	pos: [2]f32 = {20, 20} if on else {250, 150}
	_, animating := refresh_frame(u, {{kind = .Mouse_Move, x = pos.x, y = pos.y}}, now^, refresh)
	for _ in 0 ..< 400 {
		if !animating {
			break
		}
		now^ += interval
		_, animating = refresh_frame(u, nil, now^, refresh)
	}
}

// After an idle gap the first two frames each step one refresh of the
// display, as the shell reports it, or 1/60 s when it doesn't know,
// however late the second one comes and whatever the frames before the
// gap took. The third steps the time since the second.
@(test)
test_ui_frames_after_idle_step_a_normal_frame :: proc(t: ^testing.T) {
	for refresh in ([]f32{1.0 / 144, 1.0 / 60, 0}) {
		u: ui.State
		ui.init(&u)
		defer ui_destroy(&u)
		now := 0.0
		refresh_frame(&u, nil, now, refresh)
		// Frames twice as far apart as the display's, and one hitch.
		hover_run(&u, &now, true, 2 * f64(refresh if refresh > 0 else 1.0 / 60), refresh)
		now += 0.03
		refresh_frame(&u, nil, now, refresh)
		hover_run(&u, &now, false, 0.0005, refresh)
		step := (refresh if refresh > 0 else 1.0 / 60) / ui.FADE_IN

		now += 5
		sig, _ := refresh_frame(&u, {{kind = .Mouse_Move, x = 20, y = 20}}, now, refresh)
		testing.expectf(t, abs(sig.box.hot_fade - step) < 1e-4, "refresh %v: the first frame steps one refresh, not %v", refresh, sig.box.hot_fade)
		now += 1.0 / 30
		sig, _ = refresh_frame(&u, nil, now, refresh)
		testing.expectf(t, abs(sig.box.hot_fade - 2 * step) < 1e-4, "refresh %v: a late second frame steps no more", refresh)
		now += 1.0 / 240
		sig, _ = refresh_frame(&u, nil, now, refresh)
		testing.expectf(t, abs(sig.box.hot_fade - 2 * step - f32(1.0 / 240) / ui.FADE_IN) < 1e-4, "refresh %v: the third steps the time since the second", refresh)
	}
}

// The mouse and the keys move one highlight in a menu, and an item has no
// focus ring.
@(test)
test_ui_menu_hover_is_focus :: proc(t: ^testing.T) {
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
	ra, rb := f.a.box.rect, f.b.box.rect
	testing.expect(t, f.a.box.hot_t == 0 && f.b.box.hot_t == 0, "nothing is highlighted")

	// Moving over B highlights it.
	menu_frame(&u, &now, {kind = .Mouse_Move, x = rb.x + 10, y = rb.y + rb.h / 2})
	f = menu_frame(&u, &now)
	testing.expect(t, ui.has_focus(f.b.box), "the hovered item has the focus")
	testing.expect(t, f.b.box.hot_t > 0)

	// Up moves the highlight off B though the mouse is still over it.
	menu_frame(&u, &now, {kind = .Key_Down, key = .Up})
	f = menu_frame(&u, &now)
	testing.expect(t, ui.has_focus(f.a.box), "Up moves the highlight to A")
	for _ in 0 ..< 200 {
		if f = menu_frame(&u, &now); !f.animating {
			break
		}
	}
	testing.expect_value(t, f.a.box.hot_t, f32(1))
	testing.expect_value(t, f.b.box.hot_t, f32(0))
	testing.expect_value(t, f.a.box.focus_t, f32(0))

	// Moving back onto A keeps it. Moving out of the menu takes the
	// highlight off.
	menu_frame(&u, &now, {kind = .Mouse_Move, x = ra.x + 10, y = ra.y + ra.h / 2})
	f = menu_frame(&u, &now)
	testing.expect(t, ui.has_focus(f.a.box))
	menu_frame(&u, &now, {kind = .Mouse_Move, x = 290, y = 190})
	f = menu_frame(&u, &now)
	testing.expect(t, !ui.has_focus(f.a.box) && !ui.has_focus(f.b.box), "no item has the focus")
	testing.expect(t, ui.menu_is_open("menu"), "the menu stays open")

	// The highlight stays on while the menu fades out.
	menu_frame(&u, &now, {kind = .Mouse_Move, x = ra.x + 10, y = ra.y + ra.h / 2})
	f = menu_frame(&u, &now, {kind = .Key_Down, key = .Escape})
	testing.expect(t, !ui.menu_is_open("menu"))
	faded := 0
	for f.animating && f.a.box != nil && faded < 200 {
		testing.expect_value(t, f.a.box.hot_t, f32(1))
		faded += 1
		f = menu_frame(&u, &now)
	}
	testing.expect(t, faded > 1, "the menu takes frames to fade out")
}

// Two 40 pt buttons with tooltips at the bottom right of a 300 by 200
// window, shift points left of there, and an empty strip at the left.
@(private = "file")
tooltip_frame :: proc(u: ^ui.State, now: ^f64, shift: f32, events: ..platform.Event) -> (tip: ^ui.Box, animating: bool) {
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	ui.spacer(ui.px(160))
	{
		ui.row("row", {}, ui.fill(), ui.px(40))
		ui.spacer(ui.px(220 - shift))
		a := ui.box_make("a", {.Clickable}, ui.px(40), ui.px(40))
		ui.tooltip(ui.signal(a), "First")
		b := ui.box_make("b", {.Clickable}, ui.px(40), ui.px(40))
		ui.tooltip(ui.signal(b), "Second")
	}
	// find also returns last frame's box until it's pruned.
	if tip = ui.find("###tooltip"); tip != nil && tip.last_frame != u.frame {
		tip = nil
	}
	animating = ui.end_frame()
	return
}

// tooltip_text is the box with a tooltip's text, after the tooltip's padding.
@(private = "file")
tooltip_text :: proc(tip: ^ui.Box) -> ^ui.Box {
	return tip.first.next
}

// A tooltip near the window's edges is inside the window from its first
// frame, though it has no size before it's laid out.
@(test)
test_ui_tooltip_fits_from_first_frame :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0)
	tip, _ := tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 290, y = 180})
	testing.expect(t, tip == nil, "no tooltip before the delay")
	now += ui.TOOLTIP_DELAY + 0.1
	tip, _ = tooltip_frame(&u, &now, 0)
	testing.expect(t, tip != nil, "the tooltip shows after the delay")
	// Without a text state the label has no width, only the padding's height.
	r := tip.rect
	testing.expect(t, r.h > 0)
	testing.expect(t, r.y >= 8 && r.y + r.h <= 160 - 6, "above its button, with no room below")
}

// With room below its button, a tooltip goes under it.
@(test)
test_ui_tooltip_below :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	tip: ^ui.Box
	for i in 0 ..< 4 {
		events: []platform.Event
		if i == 1 {
			events = {{kind = .Mouse_Move, x = 120, y = 20}}
		}
		if i == 3 {
			now += ui.TOOLTIP_DELAY + 0.1
		}
		ui.begin_frame(&u, events, nil, nil, 300, 200, now)
		ui.spacer(ui.px(0))
		{
			ui.row("row", {}, ui.fill(), ui.px(40))
			ui.spacer(ui.px(100))
			a := ui.box_make("a", {.Clickable}, ui.px(40), ui.px(40))
			ui.tooltip(ui.signal(a), "First")
		}
		if tip = ui.find("###tooltip"); tip != nil && tip.last_frame != u.frame {
			tip = nil
		}
		ui.end_frame()
	}
	testing.expect(t, tip != nil, "the tooltip shows after the delay")
	if tip == nil {
		return
	}
	testing.expect_value(t, tip.rect.y, f32(40 + 6))
	testing.expect_value(t, tip.rect.x + tip.rect.w / 2, f32(120))
}

// Right after a tooltip, the next one shows at once and at full opacity.
// Once the warm time has passed it waits for the delay again.
@(test)
test_ui_tooltip_warm :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 240, y = 180})
	now += ui.TOOLTIP_DELAY + 0.1
	tip, _ := tooltip_frame(&u, &now, 0)
	testing.expect(t, tip != nil && tooltip_text(tip).label == "First")

	// Across the gap and onto the second button.
	now += 0.1
	tip, _ = tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 100, y = 180})
	testing.expect(t, tip == nil, "no tooltip over the gap")
	now += 0.2
	tip, _ = tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 280, y = 180})
	testing.expect(t, tip != nil && tooltip_text(tip).label == "Second", "the second tooltip shows at once")
	testing.expect_value(t, tip.opacity, f32(1))

	// Away for longer than the warm time.
	now += 0.1
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 100, y = 180})
	now += 1.5
	tip, _ = tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 240, y = 180})
	testing.expect(t, tip == nil, "the delay is back")
}

// Buttons moving under a still mouse, as in a list that scrolls, don't
// show their tooltips at once, however recent the last one was.
@(test)
test_ui_tooltip_waits_while_scrolling :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 240, y = 180})
	now += ui.TOOLTIP_DELAY + 0.1
	tip, _ := tooltip_frame(&u, &now, 0)
	testing.expect(t, tip != nil && tooltip_text(tip).label == "First")

	// The second button moves under the mouse. Hot follows a frame later.
	now += 0.05
	tooltip_frame(&u, &now, 40)
	now += 0.05
	tip, _ = tooltip_frame(&u, &now, 40)
	testing.expect(t, tip == nil, "no tooltip for the button that moved under the mouse")
	now += ui.TOOLTIP_DELAY + 0.1
	tip, _ = tooltip_frame(&u, &now, 40)
	testing.expect(t, tip != nil && tooltip_text(tip).label == "Second", "it shows after the delay")
}

// A tooltip is centred on its button, wherever the mouse is over it, and
// moves to the next button with the mouse.
@(test)
test_ui_tooltip_anchored :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 225, y = 180})
	now += ui.TOOLTIP_DELAY + 0.1
	tip, _ := tooltip_frame(&u, &now, 0)
	testing.expect(t, tip != nil)
	if tip == nil {
		return
	}
	testing.expect_value(t, tip.rect.x + tip.rect.w / 2, f32(240))
	now += 0.05
	tip, _ = tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 255, y = 195})
	testing.expect_value(t, tip.rect.x + tip.rect.w / 2, f32(240))
	now += 0.05
	tip, _ = tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 270, y = 165})
	testing.expect(t, tip != nil && tooltip_text(tip).label == "Second")
	testing.expect_value(t, tip.rect.x + tip.rect.w / 2, f32(280))
}

// A click hides the tooltip until the mouse leaves its button, so it
// doesn't come back over what the click did.
@(test)
test_ui_tooltip_hides_after_click :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0)
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 240, y = 180})
	now += ui.TOOLTIP_DELAY + 0.1
	tip, _ := tooltip_frame(&u, &now, 0)
	testing.expect(t, tip != nil, "the tooltip shows after the delay")

	now += 0.05
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Down, x = 240, y = 180, click_count = 1}, {kind = .Mouse_Up, x = 240, y = 180, click_count = 1})
	now += 0.05
	tip, _ = tooltip_frame(&u, &now, 0)
	testing.expect(t, tip == nil, "no tooltip after the click")
	now += ui.TOOLTIP_DELAY + 1
	tip, _ = tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 242, y = 181})
	testing.expect(t, tip == nil, "none while the mouse stays on the button")

	now += 0.05
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 100, y = 180})
	now += 0.05
	tooltip_frame(&u, &now, 0, {kind = .Mouse_Move, x = 240, y = 180})
	now += ui.TOOLTIP_DELAY + 0.1
	tip, _ = tooltip_frame(&u, &now, 0)
	testing.expect(t, tip != nil, "it shows again once the mouse has left and come back")
}

// A scroll view given its size in points builds the rows that fill it in
// its first frame, before any layout, and in the frame its size changes.
@(test)
test_ui_sized_view_builds_rows :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	frame :: proc(u: ^ui.State, now: ^f64, height: f32) -> (rows: ui.Virtual_Rows, animating: bool) {
		now^ += 1.0 / 120
		ui.begin_frame(u, nil, nil, nil, 300, height, now^)
		{
			view := ui.scroll_view("view", ui.px(300), ui.px(height))
			rows = ui.virtual_rows(view, 100, 10)
			for i in rows.first ..< rows.last {
				ui.box_make(fmt.tprintf("##row%d", i), {.Focusable, .Clickable}, ui.fill(), ui.px(10))
			}
		}
		animating = ui.end_frame()
		return
	}
	rows, _ := frame(&u, &now, 200)
	testing.expect(t, rows.last - rows.first >= 20, "the first frame fills the view")
	for _ in 0 ..< 10 {
		frame(&u, &now, 200)
	}
	rows, _ = frame(&u, &now, 400)
	testing.expect(t, rows.last - rows.first >= 40, "the frame after a resize fills the taller view")
}

// A frame that leaves a parent pushed, or pops one it didn't push, is
// counted, and the next frame starts with the stack empty.
@(test)
test_ui_unbalanced_parents_are_counted :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	frame :: proc(u: ^ui.State, push, pop: int) {
		ui.begin_frame(u, nil, nil, nil, 300, 200, 0)
		for _ in 0 ..< push {
			ui.push_parent(ui.box_make("p", {}, ui.px(10), ui.px(10)))
		}
		for _ in 0 ..< pop {
			ui.pop_parent()
		}
		ui.end_frame()
	}
	runner := context.logger
	context.logger = log.nil_logger() // the first leak is logged as an error
	defer context.logger = runner
	frame(&u, 1, 1)
	frame(&u, 0, 0)
	testing.expect_value(t, u.parent_leaks, 0)
	frame(&u, 1, 0)
	frame(&u, 0, 0)
	testing.expect_value(t, u.parent_leaks, 1)
	frame(&u, 0, 1)
	frame(&u, 0, 0)
	testing.expect_value(t, u.parent_leaks, 2)
}

// No_Focus_Ring set through the style stack works as it does on the box.
@(test)
test_ui_no_focus_ring_from_the_style :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (quiet: ^ui.Box) {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		{
			ui.flags({.No_Focus_Ring})
			quiet = ui.box_make("quiet", {.Focusable}, ui.px(100), ui.px(40))
		}
		ui.end_frame()
		return
	}
	frame(&u, &now)
	frame(&u, &now, {kind = .Key_Down, key = .Tab})
	quiet: ^ui.Box
	for _ in 0 ..< 10 {
		quiet = frame(&u, &now)
	}
	testing.expect(t, ui.has_focus(quiet))
	testing.expect_value(t, quiet.focus_t, f32(0))
}

// A box with No_Focus_Ring draws none when the keyboard focuses it.
@(test)
test_ui_no_focus_ring :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (plain, quiet: ^ui.Box) {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		plain = ui.box_make("plain", {.Focusable}, ui.px(100), ui.px(40))
		quiet = ui.box_make("quiet", {.Focusable, .No_Focus_Ring}, ui.px(100), ui.px(40))
		ui.end_frame()
		return
	}
	frame(&u, &now)
	frame(&u, &now, {kind = .Key_Down, key = .Tab})
	plain, quiet := frame(&u, &now)
	testing.expect(t, ui.has_focus(plain) && plain.focus_t > 0, "the plain box has a ring")
	frame(&u, &now, {kind = .Key_Down, key = .Tab})
	for _ in 0 ..< 10 {
		plain, quiet = frame(&u, &now)
	}
	testing.expect(t, ui.has_focus(quiet))
	testing.expect_value(t, quiet.focus_t, f32(0))
}

// A text field's placeholder is as wide as the field, less the padding,
// from the field's first frame.
@(test)
test_ui_placeholder_first_frame :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	f := new(ui.Text_Field)
	defer free(f)
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0)
	sig := ui.text_field("field", f, "Search", ui.px(200), 30)
	ui.end_frame()
	label: ^ui.Box
	for c := sig.box.first; c != nil; c = c.next {
		if c.label == "Search" {
			label = c
		}
	}
	testing.expect(t, label != nil)
	if label != nil {
		testing.expect_value(t, label.rect.w, f32(200))
		testing.expect_value(t, label.text_pad, f32(ui.FIELD_PAD))
	}
}

// A target at the top and a virtual list of 100 draggable rows below it.
// Returns the payload dropped on the target this frame.
@(private = "file")
drag_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (dropped: u64, ok: bool) {
	return drag_frame_held(u, now, nil, ..events)
}

// drag_frame with the buttons the hardware reports, if given.
@(private = "file")
drag_frame_held :: proc(u: ^ui.State, now: ^f64, hardware: Maybe(platform.Mouse_Buttons), events: ..platform.Event) -> (dropped: u64, ok: bool) {
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
	drag_frame(&u, &now, {kind = .Key_Down, key = .Escape})
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
	{
		ui.row("", {}, ui.fill(), ui.px(40))
		for &b, i in boxes {
			b = ui.box_make(fmt.tprintf("##b%d", i), {.Clickable, .Focusable}, ui.px(50), ui.fill())
		}
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
	boxes := three_frame(&u, &now, {kind = .Key_Down, key = .Tab})
	testing.expect(t, ui.has_focus(boxes[0]), "Tab starts at the first box")
	boxes = three_frame(&u, &now, {kind = .Key_Down, key = .Escape})
	testing.expect(t, !ui.has_focus(boxes[0]))
	boxes = three_frame(&u, &now, {kind = .Key_Down, key = .Tab, modifiers = {.Shift}})
	testing.expect(t, ui.has_focus(boxes[2]), "Shift-Tab starts at the last box")
}

@(test)
test_ui_click_on_release :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	link :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> ui.Signal {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		sig := ui.signal(ui.box_make("link", {.Clickable, .Click_On_Release}, ui.px(100), ui.px(40)))
		ui.end_frame()
		return sig
	}
	link(&u, &now)
	link(&u, &now)

	// A drag source clicks on the release over it.
	sig := link(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 1})
	testing.expect(t, sig.pressed && !sig.clicked)
	sig = link(&u, &now, {kind = .Mouse_Up, x = 20, y = 20, click_count = 1})
	testing.expect(t, sig.released && sig.clicked)

	// Dragged off it and let go elsewhere: no click.
	link(&u, &now, {kind = .Mouse_Down, x = 20, y = 20, click_count = 1})
	sig = link(&u, &now, {kind = .Mouse_Move, x = 200, y = 150})
	testing.expect(t, sig.dragging)
	sig = link(&u, &now, {kind = .Mouse_Up, x = 200, y = 150})
	testing.expect(t, sig.released && !sig.clicked)
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
		{
			view = ui.scroll_view("list", ui.fill(), ui.fill())
			for i in 0 ..< 10 {
				ui.box_make(fmt.tprintf("##item%d", i), {.Clickable, .Focusable}, ui.fill(), ui.px(40))
			}
		}
		animating = ui.end_frame()
		return
	}
	list(&u, &now)
	list(&u, &now)
	for _ in 0 ..< 4 {
		list(&u, &now, {kind = .Key_Down, key = .Tab})
	}
	// Item 3 is 120 to 160, so the view scrolls to 60.
	view, _ := list(&u, &now)
	testing.expect_value(t, view.view_off_target.y, f32(60))
	list(&u, &now, {kind = .Key_Down, key = .Tab, modifiers = {.Shift}})
	list(&u, &now, {kind = .Key_Down, key = .Tab, modifiers = {.Shift}})
	list(&u, &now, {kind = .Key_Down, key = .Tab, modifiers = {.Shift}})
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
		rows_frame(&v, &now, 100, 1000, {kind = .Key_Down, key = .Down})
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

// Boxes not built for a frame are freed and others keep their state, with
// more boxes than buckets so that chains share buckets. Freed boxes are
// taken again before the pool grows.
@(test)
test_ui_prune_keeps_built_boxes :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	N :: ui.BOX_TABLE + 1000
	build :: proc(u: ^ui.State, frame_time: f64, keep: proc(i: int) -> bool) {
		ui.begin_frame(u, {}, nil, nil, 300, 200, frame_time)
		for i in 0 ..< N {
			if keep(i) {
				b := ui.box_make(fmt.tprintf("##%d", i))
				b.view_off.x += 1
			}
		}
		ui.end_frame()
	}
	all :: proc(i: int) -> bool {return true}
	odd :: proc(i: int) -> bool {return i % 2 == 1}
	build(&u, 1, all)
	build(&u, 2, odd)
	build(&u, 3, odd)
	used, _, _ := ui.pool_stats(&u)
	testing.expect_value(t, used, N / 2)
	for i in 0 ..< N {
		b := ui.box_lookup(&u, ui.key_from_string(0, fmt.tprintf("##%d", i)))
		if i % 2 == 0 {
			testing.expectf(t, b == nil, "box %d was freed", i)
		} else if testing.expectf(t, b != nil, "box %d is kept", i) {
			testing.expect_value(t, b.view_off.x, 3)
		}
	}
	build(&u, 4, all)
	testing.expect_value(t, u.boxes_used, N)
}

@(test)
test_ui_missed_release_cancels :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	down := platform.Mouse_Buttons{.Left}
	up := platform.Mouse_Buttons{}
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
	testing.expect_value(t, u.input.buttons, platform.Mouse_Buttons{})
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
		ui.begin_frame(u, events, nil, nil, 300, 200, now^, platform.Mouse_Buttons{})
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
	testing.expect(t, sig.released, "the late release releases")
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

// A 300 by 200 window with two keyed groups. The panel, laid out like the
// sidebar: two 24 pt buttons at the top left, one at the right of the row
// below, and a full-width box under them. The grid: three 80 pt cards in a
// row, and a last row with one.
@(private = "file")
reach_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (panel, grid: ^ui.Box) {
	now^ += 1.0 / 120
	ui.begin_frame(u, events, nil, nil, 300, 200, now^)
	{
		ui.row("", {}, ui.fill(), ui.fill())
		{
			panel = ui.column("panel", {}, ui.px(200), ui.fill())
			{
				ui.row("", {}, ui.fill(), ui.px(32))
				ui.spacer(ui.px(10))
				ui.box_make("##back", {.Focusable, .Clickable}, ui.px(24), ui.px(24))
				ui.spacer(ui.px(2))
				ui.box_make("##forward", {.Focusable, .Clickable}, ui.px(24), ui.px(24))
			}
			{
				ui.row("", {}, ui.fill(), ui.px(40))
				ui.spacer(ui.fill())
				ui.box_make("##settings", {.Focusable, .Clickable}, ui.px(24), ui.px(24))
				ui.spacer(ui.px(10))
			}
			ui.box_make("##wide", {.Focusable, .Clickable}, ui.fill(), ui.px(32))
		}
		{
			grid = ui.column("grid", {}, ui.px(100), ui.fill())
			{
				ui.row("", {}, ui.fill(), ui.px(30))
				for i in 0 ..< 3 {
					ui.box_make(fmt.tprintf("##card%d", i), {.Focusable, .Clickable}, ui.px(30), ui.px(30))
				}
			}
			ui.row("", {}, ui.fill(), ui.px(30))
			ui.box_make("##card3", {.Focusable, .Clickable}, ui.px(30), ui.px(30))
		}
	}
	ui.end_frame()
	return
}

// Every focusable box in a group is reachable with the arrows. An arrow
// goes to the nearest box that way overlapping the focused one across,
// and with none overlapping to the nearest box that way at all: Right from
// Forward reaches Settings, and Down from a column the short last row of
// a grid doesn't fill reaches that row's last card.
@(test)
test_ui_arrows_reach_every_box :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	panel, grid := reach_frame(&u, &now)
	reach_frame(&u, &now)
	in_panel :: proc(panel: ^ui.Box, name: string) -> ui.Key {
		return ui.key_from_string(panel.key, name)
	}
	move :: proc(u: ^ui.State, now: ^f64, from: ui.Key, arrow: platform.Key) {
		reach_frame(u, now, {kind = .Access_Focus, target = u64(from)})
		reach_frame(u, now, {kind = .Key_Down, key = arrow})
	}

	move(&u, &now, in_panel(panel, "##forward"), .Right)
	testing.expect_value(t, u.focus, in_panel(panel, "##settings"))
	move(&u, &now, in_panel(panel, "##settings"), .Left)
	testing.expect_value(t, u.focus, in_panel(panel, "##forward"))
	move(&u, &now, in_panel(panel, "##back"), .Right)
	testing.expect_value(t, u.focus, in_panel(panel, "##forward"))
	move(&u, &now, in_panel(panel, "##forward"), .Down)
	testing.expect_value(t, u.focus, in_panel(panel, "##wide"))
	move(&u, &now, in_panel(panel, "##wide"), .Up)
	testing.expect_value(t, u.focus, in_panel(panel, "##settings"))

	move(&u, &now, in_panel(grid, "##card2"), .Down)
	testing.expect_value(t, u.focus, in_panel(grid, "##card3"))
	move(&u, &now, in_panel(grid, "##card1"), .Down)
	testing.expect_value(t, u.focus, in_panel(grid, "##card3"))
	move(&u, &now, in_panel(grid, "##card3"), .Up)
	testing.expect_value(t, u.focus, in_panel(grid, "##card0"))
	move(&u, &now, in_panel(grid, "##card3"), .Down)
	testing.expect_value(t, u.focus, in_panel(grid, "##card3"))
}

// A scroll view whose bottom 50 pt something covers, as the player bar
// covers the lists under it: the content scrolls up clear of it, scroll_to
// keeps a row above it, and the scrollbar stops above it.
@(test)
scroll_view_inset_end :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	frame :: proc(u: ^ui.State, now: ^f64, last: bool) -> (view: ^ui.Box, animating: bool) {
		now^ += 1.0 / 120
		ui.begin_frame(u, nil, nil, nil, 300, 200, now^)
		{
			view = ui.scroll_view("view", ui.fill(), ui.fill(), inset_end = 50)
			rows := ui.virtual_rows(view, 100, 10)
			for i in rows.first ..< rows.last {
				ui.box_make(fmt.tprintf("##row%d", i), {}, ui.fill(), ui.px(10))
			}
			if last {
				ui.scroll_to(view, 990, 1000)
			}
		}
		animating = ui.end_frame()
		return
	}
	now: f64
	view, _ := frame(&u, &now, false)
	testing.expect_value(t, view.view_bounds.y, f32(1050))
	view, _ = frame(&u, &now, true)
	testing.expect_value(t, view.view_off_target.y, f32(850))
	for _ in 0 ..< 300 {
		animating: bool
		view, animating = frame(&u, &now, false)
		if !animating {
			break
		}
	}
	testing.expect_value(t, view.view_off.y, f32(850))
	bar := view.last
	testing.expect(t, bar != nil && bar.rect.h == 150, "the scrollbar stops above the inset")
}

// Waiting for a tooltip asks for one frame at its deadline instead of
// drawing every frame until then, and the tooltip fades in once shown.
@(test)
test_ui_tooltip_waits_without_frames :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer {
		delete(u.boxes)
		delete(u.table)
		delete(u.hits)
		free_all(context.temp_allocator)
	}
	now := 0.0
	frame :: proc(u: ^ui.State, now: f64, events: ..platform.Event) -> bool {
		ui.begin_frame(u, events, nil, nil, 300, 200, now)
		b := ui.box_make("button", {.Clickable}, ui.px(100), ui.px(40))
		ui.tooltip(ui.signal(b), "Play")
		return ui.end_frame()
	}
	frame(&u, now)
	now += 1.0 / 120
	frame(&u, now, {kind = .Mouse_Move, x = 20, y = 20})
	hovered := u.hot_since

	settled := false
	for _ in 0 ..< 200 {
		now += 1.0 / 120
		if !frame(&u, now) {
			settled = true
			break
		}
	}
	testing.expect(t, settled, "frames stop while the tooltip waits")
	testing.expect(t, now < hovered + ui.TOOLTIP_DELAY, "before the deadline")
	testing.expectf(t, abs(f64(ui.wake_after(&u)) - (hovered + ui.TOOLTIP_DELAY - now)) < 0.001, "wakes at the deadline, in %v", ui.wake_after(&u))

	now = hovered + ui.TOOLTIP_DELAY
	testing.expect(t, frame(&u, now), "the tooltip fades in")
	faded := false
	for _ in 0 ..< 200 {
		now += 1.0 / 120
		if !frame(&u, now) {
			faded = true
			break
		}
	}
	testing.expect(t, faded, "the fade settles")
}

// A tooltip and a menu look the same wherever they're built: the style the
// code around them set doesn't reach the floating layer.
@(test)
test_ui_floating_layer_ignores_the_style_around_it :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	now := 0.0
	frame :: proc(u: ^ui.State, now: f64, events: ..platform.Event) {
		ui.begin_frame(u, events, nil, nil, 300, 200, now)
		ui.text_style(.Semibold, 20, {1, 0, 0, 1})
		ui.radius(9)
		b := ui.box_make("button", {.Clickable}, ui.px(100), ui.px(40))
		ui.tooltip(ui.signal(b), "Play")
		if ui.menu("menu") {
			ui.menu_item("Item")
		}
		ui.end_frame()
	}
	frame(&u, now)
	now += 1.0 / 120
	frame(&u, now, {kind = .Mouse_Move, x = 20, y = 20})
	now += ui.TOOLTIP_DELAY
	frame(&u, now)
	tip := ui.box_lookup(&u, ui.key_from_string(0, "###tooltip"))
	if testing.expect(t, tip != nil, "the tooltip shows") {
		testing.expect_value(t, tooltip_text(tip).font, text.Font.Regular)
		testing.expect_value(t, tooltip_text(tip).font_size, 12)
	}

	ui.open_menu("menu", {150, 100})
	now += 1.0 / 120
	frame(&u, now)
	item := ui.box_lookup(&u, ui.key_from_string(ui.key_from_string(0, "menu"), "Item"))
	if testing.expect(t, item != nil, "the menu item shows") {
		testing.expect_value(t, item.font, text.Font.Regular)
		testing.expect_value(t, item.font_size, 13)
		testing.expect_value(t, item.radius, 0)
	}

	ui.close_menu()
	for _ in 0 ..< 100 {
		now += 1.0 / 60
		frame(&u, now)
	}
	testing.expect(t, !ui.menu_is_open("menu"), "the menu closed")
	testing.expect_value(t, u.style_leaks, 0)
}

// set_next styles one box, over the scope's value; a scope styles every
// box until the end of its block and then gives back the style from before
// it. A flags scope replaces the one around it and adds to the flags a box
// is built with.
@(test)
test_ui_style_scopes_and_set_next :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	red := render.Color{1, 0, 0, 1}
	a, b, c, d, e, f: ^ui.Box
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0)
	{
		ui.radius(6)
		ui.set_next_radius(3)
		ui.set_next_background(red)
		a = ui.box_make("a", {.Draw_Background})
		b = ui.box_make("b", {.Draw_Background})
		{
			ui.radius(12)
			c = ui.box_make("c", {.Draw_Background})
		}
		ui.flags({.Draw_Border})
		{
			ui.flags({.Clip})
			ui.set_next_flags({})
			e = ui.box_make("e", {.Draw_Text})
			f = ui.box_make("f", {.Draw_Text})
		}
	}
	d = ui.box_make("d", {.Draw_Background})
	ui.end_frame()
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0.1)
	ui.end_frame()
	testing.expect_value(t, a.radius, 3)
	testing.expect_value(t, a.background, red)
	testing.expect_value(t, b.radius, 6)
	testing.expect_value(t, b.background, render.Color{})
	testing.expect_value(t, c.radius, 12)
	testing.expect_value(t, d.radius, 0)
	testing.expect_value(t, e.flags, ui.Box_Flags{.Draw_Text})
	testing.expect_value(t, f.flags, ui.Box_Flags{.Draw_Text, .Clip})
	testing.expect_value(t, u.style_leaks, 0)
}

// A frame that leaves a set_next unused, or opens or closes a scope
// between a set_next and its box, is reported once, when the next frame starts, and
// the next frame starts clean.
@(test)
test_ui_style_leak_is_reported :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	errors := 0
	// testing.expect reports through the logger, so it's put back first.
	logger := context.logger
	context.logger = {
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			if level >= .Error {
				(^int)(data)^ += 1
			}
		},
		data = &errors,
	}
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0)
	ui.set_next_radius(4)
	ui.end_frame()
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0.1)
	b := ui.box_make("b", {.Draw_Background})
	ui.end_frame()
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0.2)
	ui.set_next_text_pad(2)
	{
		ui.radius(2)
		ui.box_make("c", {.Draw_Text})
	}
	ui.end_frame()
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0.3)
	{
		ui.radius(2)
		ui.set_next_text_pad(2)
	}
	ui.box_make("d", {.Draw_Text})
	ui.end_frame()
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0.4)
	ui.set_next_text_pad(2)
	{
		ui.floating()
		ui.box_make("e", {.Floating_X, .Floating_Y})
	}
	ui.end_frame()
	ui.begin_frame(&u, nil, nil, nil, 300, 200, 0.5)
	ui.end_frame()
	context.logger = logger
	testing.expect_value(t, b.radius, 0)
	testing.expect_value(t, u.style_leaks, 4)
	testing.expect_value(t, errors, 1)
}

// A box that takes scrolls gets the scroll over it, wheel and trackpad,
// and the view behind it doesn't move. The glide after a trackpad scroll
// that started over it doesn't reach it, so a flick can't fling it. Over
// the rest of the view the view scrolls as before.
@(test)
test_ui_box_takes_scroll :: proc(t: ^testing.T) {
	u: ui.State
	ui.init(&u)
	defer ui_destroy(&u)
	knob_frame :: proc(u: ^ui.State, now: ^f64, events: ..platform.Event) -> (list: ^ui.Box, knob: ui.Signal) {
		now^ += 1.0 / 120
		ui.begin_frame(u, events, nil, nil, 300, 200, now^)
		list = ui.box_make("list", {.View_Scroll, .Allow_Overflow_Y, .Clip}, ui.px(300), ui.px(200))
		list.child_axis = .Y
		ui.push_parent(list)
		knob = ui.signal(ui.box_make("knob", {.Clickable, .Takes_Scroll}, ui.px(100), ui.px(40)))
		ui.box_make("", {}, ui.fill(), ui.px(1000))
		ui.pop_parent()
		ui.end_frame()
		return
	}
	now := 0.0
	knob_frame(&u, &now)
	knob_frame(&u, &now)

	list, knob := knob_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 20}, {kind = .Scroll, dy = -2})
	testing.expect_value(t, knob.scroll, [2]f32{0, -2 * ui.SCROLL_LINE})
	testing.expect_value(t, knob.scroll_precise, [2]f32{})
	testing.expect_value(t, list.view_off_target.y, f32(0))

	list, knob = knob_frame(&u, &now, {kind = .Scroll, dx = 3, dy = -30, precise = true, phase = .Began})
	testing.expect_value(t, knob.scroll, [2]f32{3, -30})
	testing.expect_value(t, knob.scroll_precise, [2]f32{3, -30})
	list, knob = knob_frame(&u, &now, {kind = .Scroll, phase = .Ended})
	list, knob = knob_frame(&u, &now, {kind = .Scroll, dy = -40, precise = true, momentum_phase = .Began})
	testing.expect_value(t, knob.scroll, [2]f32{})
	list, knob = knob_frame(&u, &now, {kind = .Scroll, dy = -40, precise = true, momentum_phase = .Changed})
	testing.expect_value(t, knob.scroll, [2]f32{})
	testing.expect_value(t, list.view_off, [2]f32{})
	list, knob = knob_frame(&u, &now, {kind = .Scroll, precise = true, momentum_phase = .Ended})

	list, knob = knob_frame(&u, &now, {kind = .Mouse_Move, x = 50, y = 120}, {kind = .Scroll, dy = -50, precise = true, phase = .Began})
	testing.expect_value(t, knob.scroll, [2]f32{})
	testing.expect_value(t, list.view_off.y, f32(50))
}
