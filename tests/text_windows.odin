#+build windows
package tidal_tests

import "core:log"
import win "core:sys/windows"
import "core:testing"
import "core:time"

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

// Every glyph of Latin, CJK, Arabic, Hebrew and emoji text ends up in the
// atlas, the emoji in a colour page, and each takes DirectWrite well under
// the frame's raster budget.
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
	r := new(render.Renderer)
	defer free(r)
	if !testing.expect(t, render.init(r, &surface), "no Direct3D 11 device") {
		return
	}
	defer render.destroy(r)
	s := new(text.State)
	defer free(s)
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
	testing.expect(t, done, "every glyph is in the atlas")
	testing.expect(t, glyphs > 60, "the lines' glyphs were rasterized")
	color := false
	for page in s.atlas.pages[:s.atlas.page_count] {
		color ||= page.color && page.size > 0
	}
	testing.expect(t, color, "the emoji are in a colour page")
	each := time.duration_microseconds(spent) / f64(max(glyphs, 1))
	log.infof("dwrite: %d glyphs in %.1f ms, %.0f us each", glyphs, time.duration_milliseconds(spent), each)
	{ // TEMP
		ra := &s.atlas.raster
		log.infof("dwrite cold: analyses %d %.1f ms, bounds %.1f ms, texture %.1f ms, color %.1f ms", ra.n_analysis, time.duration_milliseconds(ra.t_analysis), time.duration_milliseconds(ra.t_bounds), time.duration_milliseconds(ra.t_texture), time.duration_milliseconds(ra.t_color))
		ra.t_analysis, ra.t_bounds, ra.t_texture, ra.t_color, ra.n_analysis = 0, 0, 0, 0, 0
		warm, warm_spent := 0, time.Duration(0)
		for size: f32 = 14; size < 30; size += 1 {
			for frame := 0; frame < 200; frame += 1 {
				free_all(context.temp_allocator)
				render.begin_frame(r, 400, 300, 1, {})
				text.begin_frame(s, r)
				text.draw(s, r, .Regular, size, {0, 0}, render.WHITE, LINES[0])
				warm += s.stats.rasterized
				warm_spent += s.atlas.raster_time
				render.end_frame(r)
				if !s.needs_redraw {
					break
				}
			}
		}
		log.infof("dwrite warm: %d glyphs in %.1f ms, %.0f us each; analyses %d %.1f ms, bounds %.1f ms, texture %.1f ms", warm, time.duration_milliseconds(warm_spent), time.duration_microseconds(warm_spent) / f64(max(warm, 1)), ra.n_analysis, time.duration_milliseconds(ra.t_analysis), time.duration_milliseconds(ra.t_bounds), time.duration_milliseconds(ra.t_texture))
	}
	testing.expectf(t, each < 500, "a glyph takes %.0f us", each)
}
