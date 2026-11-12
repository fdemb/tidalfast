package tidal_tests

import vmem "core:mem/virtual"
import "core:testing"

import app "../src/app"
import "../src/platform"
import "../src/ui"

@(private = "file")
commands: [dynamic]platform.Window_Command

@(private = "file")
buttons_sent: [3][4]f32

@(private = "file")
buttons_sent_count: u32

@(private = "file")
record_command :: proc "c" (command: platform.Window_Command) {
	context = {}
	append(&commands, command)
}

@(private = "file")
record_buttons :: proc "c" (rects: [^][4]f32, count: u32) {
	buttons_sent_count = count
	for i in 0 ..< min(count, 3) {
		buttons_sent[i] = rects[i]
	}
}

// buttons_frame is library_frame with the window's buttons, as the app
// builds them when the shell asks for them.
@(private = "file")
buttons_frame :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, shell: ^platform.Shell, events: ..platform.Event) {
	f.now += 0.016
	free_all(context.temp_allocator)
	size := f.size if f.size != {} else {1000, 700}
	ui.begin_frame(&s.ui, events, nil, nil, size.x, size.y, f.now, nil, f.bytes[:])
	app.draw_library(s, size.x, size.y)
	app.build_window_buttons(s, shell, size.x)
	f.animating = ui.end_frame()
	app.send_window_buttons(s, shell)
	f.animating |= app.pending_apply(s)
}

@(private = "file")
center :: proc(s: ^app.State, label: string) -> [2]f32 {
	n, ok := access_node(s, label)
	assert(ok, label)
	return {n.frame[0] + n.frame[2] / 2, n.frame[1] + n.frame[3] / 2}
}

// Minimise, maximise and close sit at the window's top right, as tall as
// a system titlebar, and the shell learns where. Each acts on
// a release over it, as Windows' own buttons do, and not on one after the
// mouse left it.
@(test)
window_buttons_act_on_release :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	commands = make([dynamic]platform.Window_Command)
	buttons_sent_count = 0
	s := library_state(false)
	defer library_state_free(s)
	s.window.shown = true
	s.titlebar_h = 31
	shell := platform.Shell {
		window_command     = record_command,
		set_window_buttons = record_buttons,
	}
	f: Frame
	buttons_frame(t, s, &f, &shell)
	buttons_frame(t, s, &f, &shell)

	h := s.titlebar_h
	for label, i in ([3]string{"Minimize", "Maximize", "Close"}) {
		n, ok := access_node(s, label)
		if !testing.expectf(t, ok, "%s is in the tree", label) {
			return
		}
		want := [4]f32{1000 - f32(3 - i) * app.WINDOW_BUTTON_W, 0, app.WINDOW_BUTTON_W, h}
		testing.expect_value(t, n.frame, want)
		testing.expect_value(t, buttons_sent[i], want)
	}
	testing.expect_value(t, buttons_sent_count, 3)

	close := center(s, "Close")
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Move, x = close.x, y = close.y})
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Down, x = close.x, y = close.y, button = .Left, click_count = 1})
	testing.expect_value(t, len(commands), 0)
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Up, x = close.x, y = close.y, button = .Left})
	testing.expect_value(t, len(commands), 1)
	if len(commands) == 1 {
		testing.expect_value(t, commands[0], platform.Window_Command.Close)
	}

	clear(&commands)
	maximize := center(s, "Maximize")
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Move, x = maximize.x, y = maximize.y})
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Down, x = maximize.x, y = maximize.y, button = .Left, click_count = 1})
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Move, x = 500, y = 300})
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Up, x = 500, y = 300, button = .Left})
	testing.expect_value(t, len(commands), 0)

	minimize := center(s, "Minimize")
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Move, x = minimize.x, y = minimize.y})
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Down, x = minimize.x, y = minimize.y, button = .Left, click_count = 1})
	buttons_frame(t, s, &f, &shell, {kind = .Mouse_Up, x = minimize.x, y = minimize.y, button = .Left})
	testing.expect_value(t, len(commands), 1)
	if len(commands) == 1 {
		testing.expect_value(t, commands[0], platform.Window_Command.Minimize)
	}

	// Maximised, the middle one restores.
	clear(&commands)
	s.window.maximized = true
	buttons_frame(t, s, &f, &shell)
	_, has_maximize := access_node(s, "Maximize")
	testing.expect(t, !has_maximize, "no Maximize while maximised")
	buttons_frame(t, s, &f, &shell, press(s, "Restore"))
	testing.expect_value(t, len(commands), 1)
	if len(commands) == 1 {
		testing.expect_value(t, commands[0], platform.Window_Command.Toggle_Maximize)
	}
	delete(commands)
}

// The search field stops short of the buttons; without them it reaches as
// far as before.
@(test)
window_buttons_keep_the_top_clear :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := library_state(false)
	defer library_state_free(s)
	shell: platform.Shell
	// Narrow enough that the field would reach the window's edge.
	f := Frame{size = {760, 600}}
	open_search(t, s, &f)
	field_end :: proc(s: ^app.State) -> f32 {
		nodes, _ := ui.access_tree(&s.ui)
		for n in nodes {
			if n.role == .Text_Field {
				return n.frame[0] + n.frame[2]
			}
		}
		return -1
	}
	without := field_end(s)

	s.window.shown = true
	s.titlebar_h = 31
	buttons_frame(t, s, &f, &shell)
	buttons_frame(t, s, &f, &shell)
	with := field_end(s)
	testing.expectf(t, with <= 760 - 3 * app.WINDOW_BUTTON_W, "the field ends at %v, under the buttons", with)
	testing.expect_value(t, without - with, 3 * app.WINDOW_BUTTON_W)
}

// GNOME's button-layout: the left side, a colon, the right side, in order.
// Names the app doesn't draw and repeats are left out, and without a colon
// every button goes on the left, as in GTK.
@(test)
button_layout_reads_gnomes_setting :: proc(t: ^testing.T) {
	Case :: struct {
		layout:      string,
		left, right: []app.Window_Button,
	}
	cases := []Case {
		{"appmenu:close", {}, {.Close}},
		{":minimize,maximize,close", {}, {.Minimize, .Maximize, .Close}},
		{"close,minimize,maximize:", {.Close, .Minimize, .Maximize}, {}},
		{"close:maximize", {.Close}, {.Maximize}},
		{"icon,close , spacer:appmenu, minimize", {.Close}, {.Minimize}},
		{"close,close:close,maximize", {.Close}, {.Maximize}},
		{"close,minimize", {.Close, .Minimize}, {}},
		{"appmenu:", {}, {}},
		{"", {}, {}},
	}
	for c in cases {
		l := app.button_layout_parse(c.layout)
		testing.expectf(t, slice_equal(l.left[:l.left_n], c.left) && slice_equal(l.right[:l.right_n], c.right), "%q gives %v and %v", c.layout, l.left[:l.left_n], l.right[:l.right_n])
		testing.expectf(t, app.button_layout_parse(app.button_layout_string(l)) == l, "%q goes through the settings file", c.layout)
	}
}

@(private = "file")
slice_equal :: proc(a, b: []app.Window_Button) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

// Tests run on several threads, so this one records its own commands.
@(private = "file")
round_commands: [dynamic]platform.Window_Command

@(private = "file")
record_round_command :: proc "c" (command: platform.Window_Command) {
	context = {}
	append(&round_commands, command)
}

// GNOME's round buttons go where the layout says: on the right in the
// room for Back and Forward, centred level with them, and on the left in
// the sidebar's top, which keeps room for them and moves Home down. A
// button the window manager can't do is left out.
@(test)
round_window_buttons_follow_the_layout :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	round_commands = make([dynamic]platform.Window_Command)
	defer delete(round_commands)
	s := library_state(false)
	defer library_state_free(s)
	shell := platform.Shell {
		window_command = record_round_command,
	}
	f: Frame
	buttons_frame(t, s, &f, &shell)
	buttons_frame(t, s, &f, &shell)
	home_before, _ := access_node(s, "Home")

	s.window.shown = true
	s.window.style = .Round
	s.titlebar_h = 46
	s.settings.button_layout = app.button_layout_parse("appmenu:close")
	buttons_frame(t, s, &f, &shell)
	buttons_frame(t, s, &f, &shell)
	close, has_close := access_node(s, "Close")
	_, has_minimize := access_node(s, "Minimize")
	testing.expect(t, has_close && !has_minimize, "close alone with GNOME's default")
	nav_mid := app.nav_h(s) / 2
	want := [4]f32{1000 - app.ROUND_EDGE - app.ROUND_CELL, nav_mid - app.ROUND_CELL / 2, app.ROUND_CELL, app.ROUND_CELL}
	testing.expect_value(t, close.frame, want)
	testing.expect_value(t, app.window_buttons_w(s), app.ROUND_EDGE + app.ROUND_CELL)
	home, _ := access_node(s, "Home")
	testing.expect_value(t, home.frame[1], home_before.frame[1])

	buttons_frame(t, s, &f, &shell, press(s, "Close"))
	testing.expect_value(t, len(round_commands), 1)
	if len(round_commands) == 1 {
		testing.expect_value(t, round_commands[0], platform.Window_Command.Close)
	}

	s.settings.button_layout = app.button_layout_parse("close,minimize:maximize")
	buttons_frame(t, s, &f, &shell)
	buttons_frame(t, s, &f, &shell)
	close, _ = access_node(s, "Close")
	minimize, _ := access_node(s, "Minimize")
	maximize, _ := access_node(s, "Maximize")
	testing.expect_value(t, close.frame[0], app.ROUND_EDGE)
	testing.expect_value(t, minimize.frame[0], app.ROUND_EDGE + app.ROUND_CELL)
	testing.expect_value(t, maximize.frame[0], 1000 - app.ROUND_EDGE - app.ROUND_CELL)
	home, _ = access_node(s, "Home")
	testing.expectf(t, home.frame[1] >= app.nav_h(s), "Home at %v is below the buttons", home.frame[1])

	// A window manager that can't minimise.
	s.window.no_minimize = true
	buttons_frame(t, s, &f, &shell)
	buttons_frame(t, s, &f, &shell)
	_, has_minimize = access_node(s, "Minimize")
	testing.expect(t, !has_minimize, "no Minimize the window manager can't do")
	close, _ = access_node(s, "Close")
	testing.expect_value(t, close.frame[0], app.ROUND_EDGE)
}

// The settings file keeps the title bar choice and the last layout read.
@(test)
settings_keep_the_title_bar :: proc(t: ^testing.T) {
	st, ok := app.settings_decode_json(transmute([]u8)string(`{"title_bar": "Own", "button_layout": "close:minimize"}`))
	testing.expect(t, ok)
	testing.expect_value(t, st.title_bar, app.Title_Bar.Own)
	l, has := st.button_layout.?
	testing.expect(t, has)
	testing.expect_value(t, l, app.button_layout_parse("close:minimize"))
	st, ok = app.settings_decode_json(transmute([]u8)string(`{"volume": 0.5}`))
	testing.expect(t, ok)
	testing.expect_value(t, st.title_bar, app.Title_Bar.System)
	_, has = st.button_layout.?
	testing.expect(t, !has, "no layout until the portal gives one")
}
