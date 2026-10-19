package app

import "../platform"
import "../render"
import "../ui"

// The test screens. MOCK_API builds keep them so TIDALFAST_BENCH=text can run
// optimized; release builds never show them.
DEV :: ODIN_DEBUG || MOCK_API

Dev :: struct {
	screen:      Screen,
	checker:     render.Texture,
	half_white:  render.Texture, // RGBA8, one texel {128, 128, 128, 128}
	half_cover:  render.Texture, // R8, one texel 128
	scroll:      [2]f32,
	slide_start: f64,
	sliding:     bool,
}

Screen :: enum u8 {
	Library,
	Text,
	Shapes,
}

SLIDE_SECONDS :: 0.6

dev_start :: proc(s: ^State) {
	when !DEV {
		return
	}
	s.dev.checker = make_checker(&s.renderer)
	s.dev.half_white = render.texture_create(&s.renderer, 1, 1, .RGBA8)
	render.texture_update(&s.renderer, s.dev.half_white, {128, 128, 128, 128}, 0, 0, 1, 1)
	s.dev.half_cover = render.texture_create(&s.renderer, 1, 1, .R8)
	render.texture_update(&s.renderer, s.dev.half_cover, {128}, 0, 0, 1, 1)
}

// Cmd-1, 2 and 3 switch between the library and the text and renderer test
// screens.
dev_input :: proc(s: ^State, time: f64) {
	when !DEV {
		return
	}
	for key, screen in ([Screen]platform.Key{.Library = .Digit_1, .Text = .Digit_2, .Shapes = .Digit_3}) {
		if ui.take_key(key, {ui.PRIMARY}) {
			s.dev.screen = screen
		}
	}
	ui_input := &s.ui.input
	if s.dev.screen == .Shapes && .Left in ui_input.pressed {
		s.dev.slide_start = time
		s.dev.sliding = true
	}
	s.dev.scroll += ui_input.scroll
}

dev_draw_screen :: proc(s: ^State, w, h: f32) -> (drawn: bool) {
	when !DEV {
		return false
	}
	switch s.dev.screen {
	case .Library:
	case .Text:
		draw_text_screen(s, w, h)
		return true
	case .Shapes:
		draw_test_screen(s, w, h)
		return true
	}
	return false
}

// dev_draw_over draws over everything else: the slide animation and, on a
// test screen, a dot at the mouse.
dev_draw_over :: proc(s: ^State, time: f64, w, h: f32) {
	when !DEV {
		return
	}
	r := &s.renderer
	if s.dev.sliding {
		t := f32((time - s.dev.slide_start) / SLIDE_SECONDS)
		if t >= 1 {
			s.dev.sliding = false
		} else {
			ease := 1 - (1 - t) * (1 - t)
			box := render.Rect{24 + ease * (w - 88), h - 52, 40, 40}
			render.push_shadow(r, box, 20, 12)
			render.push_rect(r, box, {0.95, 0.80, 0.30, 1}, 20)
		}
	}

	ui_input := &s.ui.input
	if s.dev.screen != .Library && ui_input.mouse_inside {
		size: f32 = 14 if ui.mouse_down(ui_input^) else 10
		m := ui_input.mouse
		render.push_rect(r, {m.x - size / 2, m.y - size / 2, size, size}, {1, 1, 1, 0.8}, size / 2)
	}
}

// draw_test_screen exercises the renderer: a grid of shadowed gradient cards
// with assorted radii and borders, a scrolling clipped list, and textured
// quads sampled with mipmaps, tinted, rounded and unfiltered.
draw_test_screen :: proc(s: ^State, w, h: f32) {
	r := &s.renderer
	render.push_gradient(r, {0, 0, w, h}, CLEAR_COLOR, {0.04, 0.04, 0.05, 1})

	COLS :: 14
	ROWS :: 13
	CARD :: 36
	STEP :: 46
	radii := [5]f32{0, 4, 8, 12, 18}
	for i in 0 ..< COLS * ROWS {
		rect := render.Rect{24 + f32(i % COLS) * STEP, 24 + f32(i / COLS) * STEP, CARD, CARD}
		hue := f32(i) * 0.618
		style := render.Style{
			colors = {
				.Top_Left = hsv(hue, 0.6, 0.95),
				.Top_Right = hsv(hue, 0.6, 0.95),
				.Bottom_Left = hsv(hue + 0.08, 0.75, 0.55),
				.Bottom_Right = hsv(hue + 0.08, 0.75, 0.55),
			},
			radii = render.corners(radii[i % 5]),
		}
		if i % 7 == 3 {
			style.radii = {.Top_Left = 18, .Top_Right = 2, .Bottom_Left = 2, .Bottom_Right = 18}
		}
		if i % 5 == 2 {
			for c in render.Corner {
				style.colors[c] = hsv(hue + f32(c) * 0.25, 0.7, 0.9)
			}
		}
		render.push_shadow(r, rect, style.radii[.Top_Left], 10, {0, 3}, 0, {0, 0, 0, 0.6})
		render.push(r, rect, style)
		if i % 3 == 0 {
			ring := style
			ring.colors = render.corners(render.Color{1, 1, 1, 0.85})
			ring.border = 1
			render.push(r, rect, ring)
		}
	}

	// A panel whose list scrolls with the wheel and is clipped to the panel.
	panel := render.Rect{700, 130, 376, 270}
	render.push_shadow(r, panel, 12, 24, {0, 8}, 0, {0, 0, 0, 0.7})
	render.push_rect(r, panel, {0.16, 0.17, 0.20, 1}, 12)
	render.push_rect(r, panel, {1, 1, 1, 0.12}, 12, 1)
	render.push_clip(r, {panel.x + 8, panel.y + 8, panel.w - 16, panel.h - 16})
	for i in 0 ..< 30 {
		row := render.Rect{panel.x + 16, panel.y + 16 + f32(i) * 34 + s.dev.scroll.y, 200 + f32(i % 4) * 90, 26}
		render.push_shadow(r, row, 13, 8, {0, 2})
		render.push_gradient(r, row, hsv(f32(i) * 0.05, 0.5, 0.9), hsv(f32(i) * 0.05 + 0.15, 0.7, 0.6), true, 13)
	}
	render.push_shadow(r, {panel.x + panel.w - 70, panel.y + 150, 120, 120}, 60, 30, {}, 0, {0.3, 0.6, 1, 0.9})
	render.pop_clip(r)

	// Textured quads.
	big := render.Rect{716, 430, 160, 160}
	render.push_shadow(r, big, 20, 20, {0, 6})
	render.push_image(r, big, s.dev.checker, radius = 20)
	render.push_image(r, {900, 430, 20, 20}, s.dev.checker) // minified: mips blend the checks
	render.push_image(r, {960, 430, 100, 100}, s.dev.checker, src = {0, 0, 64, 64}, tint = {1, 0.6, 0.6, 1}, radius = 50)
	render.push_image(r, {900, 550, 40, 40}, s.dev.checker, src = {0, 0, 32, 32}, nearest = true)
	render.push_rect(r, {960, 550, 100, 40}, {1, 1, 1, 1}, 8, 2)

	// 50% white over black three ways: a premultiplied sRGB texel, R8
	// coverage and a solid colour. All three should come out the same grey.
	strip := render.Rect{716, 610, 120, 40}
	render.push_rect(r, strip, {0, 0, 0, 1})
	render.push_image(r, {strip.x + 5, strip.y + 5, 30, 30}, s.dev.half_white)
	render.push_image(r, {strip.x + 45, strip.y + 5, 30, 30}, s.dev.half_cover)
	render.push_rect(r, {strip.x + 85, strip.y + 5, 30, 30}, {1, 1, 1, 128.0 / 255})
}

// make_checker makes a 256x256 checkerboard with mipmaps.
make_checker :: proc(r: ^render.Renderer) -> render.Texture {
	SIZE :: 256
	CELL :: 16
	pixels := make([]u8, SIZE * SIZE * 4, context.temp_allocator)
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			c := [4]u8{242, 140, 40, 255} if (x / CELL + y / CELL) % 2 == 0 else [4]u8{240, 240, 240, 255}
			copy(pixels[(y * SIZE + x) * 4:], c[:])
		}
	}
	t := render.texture_create(r, SIZE, SIZE, .RGBA8, mipmapped = true)
	render.texture_update(r, t, pixels, 0, 0, SIZE, SIZE)
	return t
}
