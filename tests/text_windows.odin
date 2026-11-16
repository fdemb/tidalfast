#+build windows
package tidal_tests

import "core:log"
import "core:mem"
import win "core:sys/windows"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

import "../src/platform"
import "../src/render"
import "../src/text"

// DirectWrite drawing text into the atlas, through the Direct3D 11
// renderer on a window that's never shown.

@(private = "file")
LINES := [?]string {
	"The quick brown fox jumps over the lazy dog 0123456789",
	"Hamburg Sinfonietta, Björk, Łódź",
	"千本桜 밤편지",
	"عيونك שלום",
	"😀🎵🔥",
}

// Every line comes out whole: each character shaped from a font that has
// it, every glyph with ink drawn from the atlas, the emoji from a colour
// face. The time DirectWrite takes for each glyph is logged.
@(test)
dwrite_draws_text_into_the_atlas :: proc(t: ^testing.T) {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		lpfnWndProc   = win.DefWindowProcW,
		hInstance     = instance,
		lpszClassName = win.L("tidalfast-text-test"),
	}
	win.RegisterClassExW(&class)
	hwnd := win.CreateWindowExW(0, win.L("tidalfast-text-test"), win.L("text test"), win.WS_OVERLAPPEDWINDOW, 0, 0, 400, 300, nil, nil, instance, nil)
	if !testing.expect(t, hwnd != nil, "no window") {
		return
	}
	defer win.DestroyWindow(hwnd)
	surface := platform.Win32_Surface {
		instance = rawptr(instance),
		window   = rawptr(hwnd),
	}
	backing := make([]byte, 64 << 20)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	context.allocator = mem.arena_allocator(&arena)
	r := new(render.Renderer)
	if !testing.expect(t, render.init(r, &surface), "no Direct3D 11 device") {
		return
	}
	defer render.destroy(r)
	s := new(text.State)
	if !testing.expect(t, text.init(s), "no text") {
		return
	}
	defer text.destroy(s, r)

	glyphs := 0
	spent: time.Duration
	done := false
	for frame := 0; frame < 2000 && !done; frame += 1 {
		free_all(context.temp_allocator)
		render.begin_frame(r, 400, 300, 1, {})
		text.begin_frame(s, r)
		for line, i in LINES {
			text.draw(s, r, .Regular, 13, {0, f32(i) * 20}, render.WHITE, line)
		}
		glyphs += s.stats.rasterized
		spent += s.atlas.raster_time
		done = !s.needs_redraw && !text.loading(s)
		render.end_frame(r)
		if !done && text.loading(s) {
			time.sleep(time.Millisecond)
		}
	}
	if !testing.expect(t, done, "the fonts load and the atlas settles") {
		return
	}

	// A frame with everything in the atlas: each glyph with ink is one
	// sprite, and a character no font has is glyph 0.
	free_all(context.temp_allocator)
	render.begin_frame(r, 400, 300, 1, {})
	text.begin_frame(s, r)
	for line, i in LINES {
		run := text.shape(s, .Regular, 13, line)
		testing.expectf(t, !run.pending, "%q still waits for a font", line)
		runes := utf8.string_to_runes(line, context.temp_allocator)
		inked := 0
		for g in run.glyphs {
			c := runes[g.cluster]
			testing.expectf(t, g.id != 0, "%q: no font has %c", line, c)
			if i == len(LINES) - 1 {
				testing.expectf(t, s.faces[g.face].color, "%q: %c isn't from a colour face", line, c)
			}
			inked += int(!g.space)
		}
		before := r.instance_count
		text.draw_run(s, r, run, {0, f32(i) * 20}, render.WHITE)
		testing.expectf(t, r.instance_count - before == inked, "%q: %d of %d glyphs drawn", line, r.instance_count - before, inked)
	}
	render.end_frame(r)

	each := time.duration_microseconds(spent) / f64(max(glyphs, 1))
	log.infof("dwrite: %d glyphs in %.1f ms, %.0f us each", glyphs, time.duration_milliseconds(spent), each)
}
