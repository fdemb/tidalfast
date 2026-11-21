package app

// The window's minimise, maximise and close buttons, which the app draws
// where the shell asks it to (Frame_Input.window's Buttons), over
// everything.
//
// On Windows they look like Windows 11's own, at the view's top right, as
// tall as a system titlebar (titlebar_h): 46 points wide, thin glyphs, a
// faint light behind minimise and maximise under the mouse and red behind
// close.
//
// On Linux the shell asks for them unless the compositor draws the title
// bar, as a tiling one does or the settings ask (Title_Bar), and they look
// like GNOME's: round,
// in the room for Back and Forward and centred level with them, on the
// sides and in the order GNOME's button-layout setting gives (Button_Layout),
// which the portal reports, on GNOME and the desktops that keep that
// setting (gnome_desktop), and all three on the right elsewhere. GNOME's
// default is close alone; Ubuntu's has all three. Buttons on the left go in the sidebar's top, which keeps room
// for them as it does on macOS. The layout is read off the UI thread, which
// then waits for the portal to say it changed, and kept in the settings, so
// the next launch starts with it.
//
// The glyphs are drawn on whole pixels from a coverage texture made for
// the display's scale, so their lines stay sharp at any scale, as the
// system's are.

import "core:hash"
import "core:math"
import "core:mem"
import "core:strings"
import "core:sync"

import "../platform"
import "../render"
import "../sys"
import "../ui"

WINDOW_BUTTON_W :: 46
WINDOW_GLYPH :: 10 // points the glyphs fill

// Windows 11's caption button colours on a dark window. Windows lays
// white at 6% under the mouse and 4% pressed over the window in sRGB; the
// renderer blends in linear light, where these alphas give the same over
// the window's background. The glyphs are white, 79% pressed and 36%
// without the focus, here as the greys those give.
WINDOW_BUTTON_HOT :: render.Color{1, 1, 1, 0.0082}
WINDOW_BUTTON_PRESSED :: render.Color{1, 1, 1, 0.0052}
WINDOW_CLOSE_HOT :: render.Color{0xc4 / 255.0, 0x2b / 255.0, 0x1c / 255.0, 1}
WINDOW_CLOSE_PRESSED :: render.Color{0xc4 / 255.0, 0x2b / 255.0, 0x1c / 255.0, 0.9}
WINDOW_GLYPH_PRESSED :: 0.8
WINDOW_GLYPH_INACTIVE :: 0.4

// GNOME's round buttons: a circle with a small glyph, in a cell that
// takes the clicks around it, the cells side by side.
ROUND_BUTTON :: 24
ROUND_CELL :: 32
ROUND_EDGE :: 6 // between the window's edge and the outer cell
ROUND_GLYPH :: 8
ROUND_HOT :: SURFACE_ACTIVE
ROUND_PRESSED :: render.Color{0x40 / 255.0, 0x40 / 255.0, 0x40 / 255.0, 1}

Window_Style :: enum u8 {
	Windows,
	Round, // GNOME's
}

Window_Button :: enum u8 {
	Minimize,
	Maximize,
	Close,
}

// Button_Layout is which buttons go on each side of the title bar, and in
// what order from the left. The slots past left_n and right_n stay zero,
// so two layouts compare with ==.
Button_Layout :: struct {
	left, right:     [len(Window_Button)]Window_Button,
	left_n, right_n: int,
}

// Where GNOME's setting can't be read: all three on the right, as on
// Windows, KDE and Ubuntu.
BUTTON_LAYOUT_DEFAULT :: Button_Layout {
	right   = {.Minimize, .Maximize, .Close},
	right_n = 3,
}

// button_layout_parse reads GNOME's button-layout, such as
// "appmenu:minimize,maximize,close": the left side's buttons, a colon,
// the right side's. Names it doesn't draw (appmenu, icon, spacer) and a
// button named twice are left out. Without a colon all go on the left, as
// in GTK.
button_layout_parse :: proc(s: string) -> (l: Button_Layout) {
	seen: bit_set[Window_Button]
	left, right := s, ""
	if i := strings.index_byte(s, ':'); i >= 0 {
		left, right = s[:i], s[i + 1:]
	}
	for side, i in ([2]string{left, right}) {
		rest := side
		for name in strings.split_iterator(&rest, ",") {
			b: Window_Button
			switch strings.trim_space(name) {
			case "minimize":
				b = .Minimize
			case "maximize":
				b = .Maximize
			case "close":
				b = .Close
			case:
				continue
			}
			if b in seen {
				continue
			}
			seen += {b}
			if i == 0 {
				l.left[l.left_n] = b
				l.left_n += 1
			} else {
				l.right[l.right_n] = b
				l.right_n += 1
			}
		}
	}
	return l
}

// button_layout_string writes l as GNOME does, for the settings file.
button_layout_string :: proc(l: Button_Layout, allocator := context.temp_allocator) -> string {
	names := [Window_Button]string {
		.Minimize = "minimize",
		.Maximize = "maximize",
		.Close    = "close",
	}
	b := strings.builder_make(allocator)
	for i in 0 ..< l.left_n {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, names[l.left[i]])
	}
	strings.write_byte(&b, ':')
	for i in 0 ..< l.right_n {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, names[l.right[i]])
	}
	return strings.to_string(b)
}

@(private = "file")
button_layout_without :: proc(l: Button_Layout, drop: bit_set[Window_Button]) -> (out: Button_Layout) {
	for i in 0 ..< l.left_n {
		if l.left[i] not_in drop {
			out.left[out.left_n] = l.left[i]
			out.left_n += 1
		}
	}
	for i in 0 ..< l.right_n {
		if l.right[i] not_in drop {
			out.right[out.right_n] = l.right[i]
			out.right_n += 1
		}
	}
	return out
}

Window_Glyph :: enum {
	Minimize,
	Maximize,
	Restore,
	Close,
}

Placed_Window_Button :: struct {
	button: Window_Button,
	box:    ^ui.Box,
	rect:   [4]f32, // in view points
}

Window_Buttons :: struct {
	shown:       bool, // this frame's Frame_Input.window has Buttons
	maximized:   bool,
	no_minimize: bool,
	no_maximize: bool,
	decorations: bool, // the compositor can draw the title bar, so the settings offer the choice
	desktop:     string, // XDG_CURRENT_DESKTOP, for title_bar_own and gnome_desktop
	style:       Window_Style,
	placed:      [len(Window_Button)]Placed_Window_Button, // this frame's, left to right
	placed_n:    int,
	sent:        u64, // hash of the rects the shell has
	own_sent:    Maybe(bool), // the title bar last asked of the shell
	read:        Layout_Read,
	texture:     render.Texture, // the glyphs side by side, each with a pixel of room around it
	glyph_px:    int, // the texture's glyph size and line width in pixels
	stroke_px:   int,
	glyph_style: Window_Style,
}

// Layout_Read is the thread that reads GNOME's button layout and then
// waits for changes to it.
Layout_Read :: struct {
	thread:   sys.Thread,
	started:  bool,
	lock:     sync.Mutex,
	given:    u32, // atomic, the values the thread has given
	taken:    u32, // of those, how many the UI thread has taken
	text:     [128]u8,
	text_len: int,
	wake:     proc "c" (),
}

// layout_read_give hands the UI thread a new layout from the portal and
// wakes it. A value too long for any real layout is dropped.
layout_read_give :: proc(rd: ^Layout_Read, value: string) {
	if len(value) > len(rd.text) {
		return
	}
	sync.mutex_lock(&rd.lock)
	rd.text_len = copy(rd.text[:], value)
	sync.atomic_add(&rd.given, 1)
	sync.mutex_unlock(&rd.lock)
	if rd.wake != nil {
		rd.wake()
	}
}

// layout_read_take is the latest layout given since the last take, in
// buf.
layout_read_take :: proc(rd: ^Layout_Read, buf: []u8) -> (text: string, ok: bool) {
	if sync.atomic_load(&rd.given) == rd.taken {
		return "", false
	}
	sync.mutex_lock(&rd.lock)
	n := copy(buf, rd.text[:rd.text_len])
	rd.taken = rd.given
	sync.mutex_unlock(&rd.lock)
	return string(buf[:n]), true
}

// window_frame takes the window's state from the frame's input.
window_frame :: proc(s: ^State, input: ^platform.Frame_Input, shell: ^platform.Shell) {
	wb := &s.window
	wb.shown = .Buttons in input.window
	wb.maximized = .Maximized in input.window
	wb.no_minimize = .No_Minimize in input.window
	wb.no_maximize = .No_Maximize in input.window
	wb.decorations = .Decorations in input.window
	wb.style = .Round when ODIN_OS == .Linux else .Windows
	when ODIN_OS == .Linux {
		window_layout_poll(s, shell)
	}
}

// window_layout is this frame's buttons on each side, less those the
// window manager can't do.
window_layout :: proc(s: ^State) -> Button_Layout {
	wb := &s.window
	if !wb.shown {
		return {}
	}
	l := BUTTON_LAYOUT_DEFAULT
	if wb.style == .Round && gnome_desktop(wb.desktop) {
		l = s.settings.button_layout.? or_else BUTTON_LAYOUT_DEFAULT
	}
	drop: bit_set[Window_Button]
	if wb.no_minimize {
		drop += {.Minimize}
	}
	if wb.no_maximize {
		drop += {.Maximize}
	}
	return button_layout_without(l, drop)
}

// window_buttons_w is how much of the view's top right the buttons take.
window_buttons_w :: proc(s: ^State) -> f32 {
	if !s.window.shown {
		return 0
	}
	if s.window.style == .Windows {
		return 3 * WINDOW_BUTTON_W
	}
	n := window_layout(s).right_n
	return ROUND_EDGE + f32(n) * ROUND_CELL if n > 0 else 0
}

// window_buttons_left says whether buttons go at the top left, in the
// sidebar.
window_buttons_left :: proc(s: ^State) -> bool {
	return s.window.shown && s.window.style == .Round && window_layout(s).left_n > 0
}

// window_bar_top is how far down a main view's scrollbar starts: below the
// window's buttons when the view runs up under them.
window_bar_top :: proc(s: ^State) -> f32 {
	return s.titlebar_h if s.window.shown && nav_reserve(s) > 0 else 0
}

// build_window_buttons makes the buttons' boxes, w being the window's
// width. Built last, they're over everything else and take the clicks
// there. A button acts on the release over it, as the system's do.
build_window_buttons :: proc(s: ^State, shell: ^platform.Shell, w: f32) {
	wb := &s.window
	wb.placed_n = 0
	if !wb.shown {
		return
	}
	if wb.style == .Windows {
		for b, i in ([3]Window_Button{.Minimize, .Maximize, .Close}) {
			place_window_button(s, shell, b, {w - f32(3 - i) * WINDOW_BUTTON_W, 0, WINDOW_BUTTON_W, s.titlebar_h})
		}
		return
	}
	l := window_layout(s)
	y := nav_h(s) / 2 - ROUND_CELL / 2
	for i in 0 ..< l.left_n {
		place_window_button(s, shell, l.left[i], {ROUND_EDGE + f32(i) * ROUND_CELL, y, ROUND_CELL, ROUND_CELL})
	}
	for i in 0 ..< l.right_n {
		place_window_button(s, shell, l.right[i], {w - ROUND_EDGE - f32(l.right_n - i) * ROUND_CELL, y, ROUND_CELL, ROUND_CELL})
	}
}

@(private = "file")
place_window_button :: proc(s: ^State, shell: ^platform.Shell, button: Window_Button, rect: [4]f32) {
	wb := &s.window
	ids := [Window_Button]string {
		.Minimize = "###window_minimize",
		.Maximize = "###window_maximize",
		.Close    = "###window_close",
	}
	commands := [Window_Button]platform.Window_Command {
		.Minimize = .Minimize,
		.Maximize = .Toggle_Maximize,
		.Close    = .Close,
	}
	names := [Window_Button]string {
		.Minimize = "Minimize",
		.Maximize = "Restore" if wb.maximized else "Maximize",
		.Close    = "Close",
	}
	b := ui.box_make(ids[button], {.Floating_X, .Floating_Y, .Clickable, .Click_On_Release}, ui.px(rect[2]), ui.px(rect[3]))
	b.fixed_pos = {rect[0], rect[1]}
	ui.accessible(b, .Button, names[button])
	if ui.signal(b).clicked && shell.window_command != nil {
		shell.window_command(commands[button])
	}
	wb.placed[wb.placed_n] = {button, b, rect}
	wb.placed_n += 1
}

// send_window_buttons tells the shell where the buttons are when that
// changed, for Windows' snap layouts.
send_window_buttons :: proc(s: ^State, shell: ^platform.Shell) {
	wb := &s.window
	if !wb.shown || wb.style != .Windows || shell.set_window_buttons == nil || wb.placed_n != 3 {
		return
	}
	rects: [3][4]f32
	for p in wb.placed[:wb.placed_n] {
		rects[p.button] = p.rect
	}
	if h := hash.fnv64a(mem.slice_to_bytes(rects[:])); h != wb.sent {
		shell.set_window_buttons(raw_data(rects[:]), 3)
		wb.sent = h
	}
}

// send_decorations tells the shell whose title bar the settings want.
send_decorations :: proc(s: ^State, shell: ^platform.Shell) {
	own := title_bar_own(s.settings.title_bar, s.window.desktop)
	if shell.set_decorations != nil && s.window.own_sent != own {
		shell.set_decorations(b32(own))
		s.window.own_sent = own
	}
}

// draw_window_buttons draws the buttons over the finished frame. key is
// whether the window has the focus: without it the glyphs dim, as the
// system's do, unless the mouse is on them.
draw_window_buttons :: proc(s: ^State, key: bool) {
	wb := &s.window
	if !wb.shown || wb.placed_n == 0 {
		return
	}
	r := &s.renderer
	window_glyphs(s)
	scale := r.scale
	g := f32(wb.glyph_px)
	cell := g + 2
	for p in wb.placed[:wb.placed_n] {
		glyph: Window_Glyph
		switch p.button {
		case .Minimize:
			glyph = .Minimize
		case .Maximize:
			glyph = .Restore if wb.maximized else .Maximize
		case .Close:
			glyph = .Close
		}
		hot, pressed := p.box.hot_t, p.box.active_t
		src := render.Rect{f32(glyph) * cell, 0, cell, cell}
		if wb.style == .Windows {
			right := math.round(r.width * scale)
			bw := math.round(WINDOW_BUTTON_W * scale)
			bh := math.round(s.titlebar_h * scale)
			x0 := right - f32(3 - int(p.button)) * bw
			close := p.button == .Close
			bg := mix(WINDOW_CLOSE_HOT if close else WINDOW_BUTTON_HOT, WINDOW_CLOSE_PRESSED if close else WINDOW_BUTTON_PRESSED, pressed)
			bg.a *= max(hot, pressed)
			if bg.a > 0 {
				render.push_rect(r, {x0 / scale, 0, bw / scale, bh / scale}, bg)
			}
			grey: f32 = 1 if key else WINDOW_GLYPH_INACTIVE
			grey = grey + (1 - grey) * max(hot, pressed)
			if !close {
				grey = grey + (WINDOW_GLYPH_PRESSED - grey) * pressed
			}
			gx := x0 + math.floor((bw - g) / 2)
			gy := math.floor((bh - g) / 2)
			render.push_sprite(r, {gx - 1, gy - 1, gx + g + 1, gy + g + 1}, wb.texture, src, {grey, grey, grey, 1})
			continue
		}
		cx := p.rect[0] + p.rect[2] / 2
		cy := p.rect[1] + p.rect[3] / 2
		circle := render.Rect{cx - ROUND_BUTTON / 2, cy - ROUND_BUTTON / 2, ROUND_BUTTON, ROUND_BUTTON}
		render.push_rect(r, circle, mix(mix(SURFACE, ROUND_HOT, hot), ROUND_PRESSED, pressed), ROUND_BUTTON / 2)
		render.push_rect(r, circle, OUTLINE, ROUND_BUTTON / 2, 1)
		glyph_c := mix(TEXT if key else DIM, TEXT, max(hot, pressed))
		gx := math.round(cx * scale - g / 2)
		gy := math.round(cy * scale - g / 2)
		render.push_sprite(r, {gx - 1, gy - 1, gx + g + 1, gy + g + 1}, wb.texture, src, glyph_c)
	}
}

// window_glyphs makes the glyphs' texture when there's none, or the scale
// changed its size.
@(private = "file")
window_glyphs :: proc(s: ^State) {
	wb := &s.window
	r := &s.renderer
	g := max(int(math.round(WINDOW_GLYPH * r.scale)), 6)
	stroke := max(int(math.round(r.scale - 0.25)), 1)
	if wb.style == .Round {
		g = max(int(math.round(ROUND_GLYPH * r.scale)), 6)
		stroke = max(int(math.round(r.scale * 1.25)), 1)
	}
	if wb.texture != 0 && g == wb.glyph_px && stroke == wb.stroke_px && wb.style == wb.glyph_style {
		return
	}
	if wb.texture != 0 {
		render.texture_destroy(r, wb.texture)
	}
	cell := g + 2
	tw, th := cell * len(Window_Glyph), cell
	pixels := make([]u8, tw * th, context.temp_allocator)
	window_glyph_pixels(pixels, tw, g, stroke, wb.style)
	wb.texture = render.texture_create(r, tw, th, .R8)
	render.texture_update(r, wb.texture, pixels, 0, 0, tw, th)
	wb.glyph_px, wb.stroke_px, wb.glyph_style = g, stroke, wb.style
}

// window_glyph_pixels fills pixels, tw wide, with the glyphs as coverage,
// each g pixels square in a cell with a pixel of room around it, its lines
// stroke pixels wide, in style's shapes. Each pixel's coverage is the share
// of 8 by 8 samples inside the glyph.
window_glyph_pixels :: proc(pixels: []u8, tw, g, stroke: int, style: Window_Style) {
	N :: 8
	cell := g + 2
	for glyph in Window_Glyph {
		for py in 0 ..< cell {
			for px in 0 ..< cell {
				inside := 0
				for sy in 0 ..< N {
					for sx in 0 ..< N {
						x := f32(px - 1) + (f32(sx) + 0.5) / N
						y := f32(py - 1) + (f32(sy) + 0.5) / N
						if window_glyph_has(glyph, f32(g), f32(stroke), style, x, y) {
							inside += 1
						}
					}
				}
				pixels[py * tw + int(glyph) * cell + px] = u8((inside * 255 + N * N / 2) / (N * N))
			}
		}
	}
}

// window_glyph_has says whether the point x, y, in pixels from the glyph's
// top left, is inside the glyph, g pixels square with lines stroke wide.
// GNOME's minimise is a line along the bottom, Windows' across the middle.
@(private = "file")
window_glyph_has :: proc(glyph: Window_Glyph, g, stroke: f32, style: Window_Style, x, y: f32) -> bool {
	if x < 0 || y < 0 || x >= g || y >= g {
		return false
	}
	radius := max(g * 0.15, 1)
	switch glyph {
	case .Minimize:
		top := math.floor((g - stroke) / 2) if style == .Windows else g - stroke
		return y >= top && y < top + stroke
	case .Maximize:
		return outline_has({0, 0, g, g}, radius, stroke, x, y)
	case .Restore:
		// The window in front at the bottom left, and the top and right
		// edges of the one behind it.
		d := math.round(g * 0.2)
		front := [4]f32{0, d, g - d, g}
		if outline_has(front, radius, stroke, x, y) {
			return true
		}
		return !rounded_has(front, radius, x, y) && outline_has({d, 0, g, g - d}, radius, stroke, x, y)
	case .Close:
		// Two diagonals corner to corner, stroke wide across.
		half := stroke / 2 * math.SQRT_TWO
		return abs(x - y) <= half || abs(x + y - g) <= half
	}
	return false
}

// rounded_has says whether x, y is inside the rect x0 y0 x1 y1 with corners
// rounded by radius.
@(private = "file")
rounded_has :: proc(rect: [4]f32, radius, x, y: f32) -> bool {
	if x < rect[0] || y < rect[1] || x >= rect[2] || y >= rect[3] {
		return false
	}
	cx := clamp(x, rect[0] + radius, rect[2] - radius)
	cy := clamp(y, rect[1] + radius, rect[3] - radius)
	return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius
}

// outline_has says whether x, y is on the outline of a rounded rect, stroke
// wide inside its edge.
@(private = "file")
outline_has :: proc(rect: [4]f32, radius, stroke, x, y: f32) -> bool {
	inner := [4]f32{rect[0] + stroke, rect[1] + stroke, rect[2] - stroke, rect[3] - stroke}
	return rounded_has(rect, radius, x, y) && !rounded_has(inner, max(radius - stroke, 0), x, y)
}
