package app

// The window's minimise, maximise and close buttons, which the app draws
// where the shell asks it to (Frame_Input.window's Buttons), as Windows
// does: at the view's top right, over everything, as tall as a system
// titlebar (titlebar_h). They look like Windows 11's own: 46 points wide, thin
// glyphs, a faint light behind minimise and maximise under the mouse and
// red behind close. The glyphs are drawn on whole pixels from a coverage
// texture made for the display's scale, so their lines stay one pixel
// sharp at any scale, as the system's are.

import "core:hash"
import "core:math"
import "core:mem"

import "../platform"
import "../render"
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

Window_Glyph :: enum {
	Minimize,
	Maximize,
	Restore,
	Close,
}

Window_Buttons :: struct {
	shown:     bool, // this frame's Frame_Input.window has Buttons
	maximized: bool,
	boxes:     [3]^ui.Box, // this frame's minimise, maximise and close
	rects:     [3][4]f32, // where they are, in view points
	sent:      u64, // hash of the rects the shell has
	texture:   render.Texture, // the glyphs side by side, each with a pixel of room around it
	glyph_px:  int, // the texture's glyph size and line width in pixels
	stroke_px: int,
}

// window_buttons_w is how much of the view's top right the buttons take.
window_buttons_w :: proc(s: ^State) -> f32 {
	return 3 * WINDOW_BUTTON_W if s.window.shown else 0
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
	if !wb.shown {
		return
	}
	ids := [3]string{"###window_minimize", "###window_maximize", "###window_close"}
	commands := [3]platform.Window_Command{.Minimize, .Toggle_Maximize, .Close}
	names := [3]string{"Minimize", "Restore" if wb.maximized else "Maximize", "Close"}
	h := s.titlebar_h
	for i in 0 ..< 3 {
		x := w - f32(3 - i) * WINDOW_BUTTON_W
		b := ui.box_make(ids[i], {.Floating_X, .Floating_Y, .Clickable, .Click_On_Release}, ui.px(WINDOW_BUTTON_W), ui.px(h))
		b.fixed_pos = {x, 0}
		ui.accessible(b, .Button, names[i])
		if ui.signal(b).clicked && shell.window_command != nil {
			shell.window_command(commands[i])
		}
		wb.boxes[i] = b
		wb.rects[i] = {x, 0, WINDOW_BUTTON_W, h}
	}
}

// send_window_buttons tells the shell where the buttons are when that
// changed.
send_window_buttons :: proc(s: ^State, shell: ^platform.Shell) {
	wb := &s.window
	if !wb.shown || shell.set_window_buttons == nil {
		return
	}
	if h := hash.fnv64a(mem.slice_to_bytes(wb.rects[:])); h != wb.sent {
		shell.set_window_buttons(raw_data(wb.rects[:]), 3)
		wb.sent = h
	}
}

// draw_window_buttons draws the buttons over the finished frame. key is
// whether the window has the focus: without it the glyphs dim, as the
// system's do, unless the mouse is on them.
draw_window_buttons :: proc(s: ^State, key: bool) {
	wb := &s.window
	if !wb.shown {
		return
	}
	r := &s.renderer
	window_glyphs(s)
	scale := r.scale
	right := math.round(r.width * scale)
	bw := math.round(WINDOW_BUTTON_W * scale)
	bh := math.round(s.titlebar_h * scale)
	g := f32(wb.glyph_px)
	cell := g + 2
	glyphs := [3]Window_Glyph{.Minimize, .Restore if wb.maximized else .Maximize, .Close}
	for i in 0 ..< 3 {
		b := wb.boxes[i]
		x0 := right - f32(3 - i) * bw
		hot, pressed := b.hot_t, b.active_t
		close := i == 2
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
		src := render.Rect{f32(glyphs[i]) * cell, 0, cell, cell}
		render.push_sprite(r, {gx - 1, gy - 1, gx + g + 1, gy + g + 1}, wb.texture, src, {grey, grey, grey, 1})
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
	if wb.texture != 0 && g == wb.glyph_px && stroke == wb.stroke_px {
		return
	}
	if wb.texture != 0 {
		render.texture_destroy(r, wb.texture)
	}
	cell := g + 2
	tw, th := cell * len(Window_Glyph), cell
	pixels := make([]u8, tw * th, context.temp_allocator)
	window_glyph_pixels(pixels, tw, g, stroke)
	wb.texture = render.texture_create(r, tw, th, .R8)
	render.texture_update(r, wb.texture, pixels, 0, 0, tw, th)
	wb.glyph_px, wb.stroke_px = g, stroke
}

// window_glyph_pixels fills pixels, tw wide, with the glyphs as coverage,
// each g pixels square in a cell with a pixel of room around it, its lines
// stroke pixels wide. Each pixel's coverage is the share of 8 by 8 samples
// inside the glyph.
window_glyph_pixels :: proc(pixels: []u8, tw, g, stroke: int) {
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
						if window_glyph_has(glyph, f32(g), f32(stroke), x, y) {
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
@(private = "file")
window_glyph_has :: proc(glyph: Window_Glyph, g, stroke, x, y: f32) -> bool {
	if x < 0 || y < 0 || x >= g || y >= g {
		return false
	}
	radius := max(g * 0.15, 1)
	switch glyph {
	case .Minimize:
		top := math.floor((g - stroke) / 2)
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
