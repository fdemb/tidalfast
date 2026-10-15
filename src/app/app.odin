// The hot-reloaded app. The shell loads this package as a dylib and calls the
// procs in `api` through app_get_api.
//
// What survives a reload: everything in State, which lives at the start of
// the shell's persistent memory block. What doesn't: Odin globals in this
// package, procedure pointers and anything allocated by the dylib's own
// runtime. So State holds plain data only. Allocators carry a procedure
// pointer, so they are rebuilt from the arenas on every call instead of being
// stored. If State changes layout, bump STATE_VERSION. On a size or version
// mismatch the new code calls the old code's release proc from the header,
// then resets State. State from a build without this header (no magic) is
// reset without calling anything.
package app

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:prof/spall"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../platform"
import "../render"
import "../text"
import "../ui"

CLEAR_COLOR :: render.Color{0.10, 0.11, 0.13, 1}

STATE_VERSION :: 14

FRAME_HISTORY :: 120

// "TFSTATE1". Builds before it had a different header or none, so anything
// else at the start of State is unreadable and its release isn't trusted.
STATE_MAGIC :: 0x3145_5441_5453_4654

// State_Header starts State in every version of the app, so a new version
// can read an old one's header. Never change it.
State_Header :: struct {
	magic:   u64,
	version: u32,
	size:    int,
	// Frees everything the State behind this header owns, using the code that
	// knows its layout. The shell never unloads an old dylib, so this stays
	// callable after the dylib that set it has been replaced. It is the one
	// procedure pointer allowed across a reload.
	release: proc "c" (m: ^platform.Memory),
}

State :: struct {
	using header: State_Header,
	arena:        mem.Arena, // the rest of the persistent block
	frame_arena:  mem.Arena, // reset at the start of every frame
	renderer:     render.Renderer,
	text:         text.State,
	rows:         []Row,
	screen:       Screen,
	checker:      render.Texture,
	half_white:   render.Texture, // RGBA8, one texel {128, 128, 128, 128}
	half_cover:   render.Texture, // R8, one texel 128
	last_stats:   render.Stats,
	frame_count:  u64,
	frame_ms:     [FRAME_HISTORY]f32,
	ui_ms:        f32, // last frame's time building the frame, before end_frame
	show_overlay: bool,
	log_events:   bool,
	ui:           ui.State,
	library:      Library,
	data:         Data,
	playback:     Playback,
	search:       Search,
	pending:      Pending, // what the frame being built asked for, done after it
	access_sent:  u64, // hash of the accessibility tree the shell has
	scroll:       [2]f32, // the test screens' scroll offset
	bench:        Bench,
	measure:      Measure,
	slide_start:  f64,
	sliding:      bool,
	profiling:    bool,
	spall_ctx:    spall.Context,
	spall_buf:    spall.Buffer,
}

@(private = "file")
api := platform.App_API {
	abi_version = platform.ABI_VERSION,
	init        = app_init,
	reload      = app_reload,
	unload      = app_unload,
	shutdown    = app_shutdown,
	frame       = app_frame,
}

@(export)
app_get_api :: proc "c" () -> ^platform.App_API {
	return &api
}

app_init :: proc "c" (m: ^platform.Memory, shell: ^platform.Shell) {
	context = runtime.default_context()
	s := state_reset(m)
	context = app_context(s)
	start(s, shell)
}

app_reload :: proc "c" (m: ^platform.Memory, shell: ^platform.Shell) {
	context = runtime.default_context()
	s := (^State)(m.persistent)
	if s.magic != STATE_MAGIC {
		// Whatever is there may hold pointers where release would be. Leak it.
		fmt.eprintln("app: state from a build without a state header, resetting without releasing it")
		s = state_reset(m)
		context = app_context(s)
		start(s, shell)
		return
	}
	if s.version != STATE_VERSION || s.size != size_of(State) {
		fmt.eprintfln("app: state changed (version %d, %d bytes) -> (version %d, %d bytes), resetting", s.version, s.size, STATE_VERSION, size_of(State))
		if s.release != nil {
			s.release(m)
		}
		s = state_reset(m)
		context = app_context(s)
		start(s, shell)
		return
	}
	context = app_context(s)
	s.release = app_shutdown
	if !render.reload(&s.renderer) {
		fmt.eprintln("app: shader rebuild failed, drawing with the previous shaders")
	}
	text.reload(&s.text, shell.request_redraw)
	// The old dylib may have missed a release.
	ui.cancel_pointer(&s.ui)
	data_reload(s, shell)
	playback_reload(s, shell)
	measure_reload(s, shell)
	fmt.eprintfln("app: reloaded at frame %d, clear colour %v", s.frame_count, CLEAR_COLOR)
}

app_unload :: proc "c" (m: ^platform.Memory) {
	context = runtime.default_context()
	s := (^State)(m.persistent)
	context = app_context(s)
	text.unload(&s.text)
	measure_unload(s)
	playback_unload(s)
	data_unload(s)
	if s.profiling {
		spall.buffer_flush(&s.spall_ctx, &s.spall_buf)
	}
}

app_shutdown :: proc "c" (m: ^platform.Memory) {
	context = runtime.default_context()
	s := (^State)(m.persistent)
	context = app_context(s)
	if s.profiling {
		spall.buffer_destroy(&s.spall_ctx, &s.spall_buf)
		posix.close(posix.FD(s.spall_ctx.fd))
	}
	measure_unload(s)
	playback_shutdown(s)
	data_shutdown(s)
	search_shutdown(s)
	text.destroy(&s.text, &s.renderer)
	render.destroy(&s.renderer)
}

app_frame :: proc "c" (m: ^platform.Memory, shell: ^platform.Shell, input: ^platform.Frame_Input) -> platform.Frame_Result {
	context = runtime.default_context()
	s := (^State)(m.persistent)
	context = app_context(s)
	free_all(context.temp_allocator)

	begin := time.tick_now()
	result: platform.Frame_Result
	{
		prof_scope(s, "frame")
		result = update_and_draw(s, input, shell)
	}
	frame_ms := f32(time.duration_milliseconds(time.tick_since(begin)))
	s.frame_ms[s.frame_count % FRAME_HISTORY] = frame_ms
	s.frame_count += 1
	measure_frame(s)
	if s.text.needs_redraw {
		// Glyphs left over from the raster budget or a full atlas. The
		// display link may be paused (window covered), so ask directly.
		shell.request_redraw()
	}
	if s.data.bench.running {
		cover_bench_record(s, frame_ms)
		shell.request_redraw()
		result.animating = true
	}
	if s.bench.running {
		bench_record(s, frame_ms)
		// Draw again straight away even if the window is covered and the
		// display link is paused.
		shell.request_redraw()
		result.animating = true
	}
	return result
}

state_reset :: proc(m: ^platform.Memory) -> ^State {
	// Fresh zero pages over the whole block, so an old State's pages go back
	// to the system and nothing here or in the arena needs zeroing, see
	// persistent_allocator_proc.
	if posix.mmap(m.persistent, m.persistent_size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .FIXED}) == posix.MAP_FAILED {
		mem.zero(m.persistent, int(m.persistent_size))
	}
	s := (^State)(m.persistent)
	s.magic = STATE_MAGIC
	s.version = STATE_VERSION
	s.size = size_of(State)
	s.release = app_shutdown
	used := mem.align_forward_int(size_of(State), 64)
	mem.arena_init(&s.arena, m.persistent[used:m.persistent_size])
	mem.arena_init(&s.frame_arena, m.frame[:m.frame_size])
	return s
}

app_context :: proc(s: ^State) -> runtime.Context {
	c := runtime.default_context()
	c.allocator = {persistent_allocator_proc, &s.arena}
	c.temp_allocator = mem.arena_allocator(&s.frame_arena)
	return c
}

// persistent_allocator_proc is the persistent arena without zeroing. The
// arena only ever moves forward through memory that is still zero, since
// state_reset maps fresh pages over the block, so zeroing would only touch
// every page of the caches made at init, most of which are never written,
// and make them count against the app's memory.
persistent_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	return mem.arena_allocator_proc(data, .Alloc_Non_Zeroed if mode == .Alloc else mode, size, alignment, old_memory, old_size, loc)
}

start :: proc(s: ^State, shell: ^platform.Shell) {
	measure_start(s, shell)
	// Off unless asked for. The benches draw it, so their numbers include it.
	bench := os.get_env("TIDALFAST_BENCH", context.temp_allocator)
	s.show_overlay = os.get_env("TIDALFAST_OVERLAY", context.temp_allocator) != "" || bench != ""
	s.log_events = os.get_env("TIDALFAST_LOG_EVENTS", context.temp_allocator) != ""

	// TIDALFAST_SPALL=path writes a spall trace of every frame to path. Only
	// the fd is used after this; the os.File it came from is dropped so State
	// holds no pointer into this dylib's runtime.
	if path := os.get_env("TIDALFAST_SPALL", context.temp_allocator); path != "" {
		ctx, ok := spall.context_create_with_scale(path, false, 1)
		if ok {
			ctx.file = nil
			s.spall_ctx = ctx
			s.spall_buf = spall.buffer_create(make([]u8, spall.BUFFER_DEFAULT_SIZE), u32(sync.current_thread_id()))
			s.profiling = true
			fmt.eprintln("app: writing spall trace to", path)
		}
	}

	// TIDALFAST_CAPTURE=path writes every presented frame to path as a TGA,
	// for checking output without screen recording permission.
	if path := os.get_env("TIDALFAST_CAPTURE", context.allocator); path != "" {
		s.renderer.capture_path = path
	}

	if !render.init(&s.renderer, shell.metal_device, shell.metal_layer) {
		fmt.eprintln("app: renderer init failed")
	}
	if !text.init(&s.text, shell.request_redraw) {
		fmt.eprintln("app: text init failed")
	}
	ui.init(&s.ui)
	library_init(&s.library)
	data_start(s, shell)
	if s.data.fake {
		s.rows = make_rows()
	}
	playback_start(s, shell)
	search_init(s)
	// TIDALFAST_BENCH=1 scrolls the library's track table, =text the text
	// test screen's list.
	switch bench {
	case "", "covers":
	case "text":
		s.bench.running = true
		s.screen = .Text
	case:
		s.bench.running = true
		s.bench.ui = true
	}
	s.checker = make_checker(&s.renderer)
	s.half_white = render.texture_create(&s.renderer, 1, 1, .RGBA8)
	render.texture_update(&s.renderer, s.half_white, {128, 128, 128, 128}, 0, 0, 1, 1)
	s.half_cover = render.texture_create(&s.renderer, 1, 1, .R8)
	render.texture_update(&s.renderer, s.half_cover, {128}, 0, 0, 1, 1)
	fmt.eprintfln("app: started, clear colour %v", CLEAR_COLOR)
	measure_mark(s, .Init)
}

@(deferred_in = prof_end)
prof_scope :: proc(s: ^State, name: string, loc := #caller_location) {
	if s.profiling {
		spall._buffer_begin(&s.spall_ctx, &s.spall_buf, name, "", loc)
	}
}

prof_end :: proc(s: ^State, _: string, _ := #caller_location) {
	if s.profiling {
		spall._buffer_end(&s.spall_ctx, &s.spall_buf)
	}
}

Screen :: enum u8 {
	Library,
	Text,
	Shapes,
}

SLIDE_SECONDS :: 0.6

update_and_draw :: proc(s: ^State, input: ^platform.Frame_Input, shell: ^platform.Shell) -> platform.Frame_Result {
	events := input.events[:input.event_count]
	if s.log_events {
		for e in events {
			fmt.eprintfln("event: %v", e)
		}
	}
	w, h := input.width, input.height
	r := &s.renderer
	render.begin_frame(r, w, h, input.scale, CLEAR_COLOR)
	ui_begin := time.tick_now()
	measure_frame_begin(s)
	text.begin_frame(&s.text, r)
	ui.begin_frame(&s.ui, events, r, &s.text, w, h, input.time, ui.hardware_buttons(), input.text[:input.text_length])
	ui.set_window_key(&s.ui, bool(input.key_window))
	ui.set_clipboard(&s.ui, shell.get_clipboard, shell.set_clipboard)
	data_update(s, input.time)
	playback_update(s, events)

	// Backtick toggles the frame-time overlay. Cmd-1, 2 and 3 switch between
	// the library and the phase 2 and phase 1 test screens.
	if ui.key_pressed(ui.KEY_GRAVE) {
		s.show_overlay = !s.show_overlay
	}
	for key, screen in ([Screen]u32{.Library = ui.KEY_1, .Text = ui.KEY_2, .Shapes = ui.KEY_3}) {
		if ui.key_pressed(key, {.Command}) {
			s.screen = screen
		}
	}
	ui_input := &s.ui.input
	if s.screen == .Shapes && .Left in ui_input.pressed {
		s.slide_start = input.time
		s.sliding = true
	}
	s.scroll += ui_input.scroll

	switch s.screen {
	case .Library:
		if show_login(s) {
			draw_login(s)
		} else {
			draw_library(s, w, h)
		}
	case .Text:
		draw_text_screen(s, w, h)
	case .Shapes:
		draw_test_screen(s, w, h)
	}
	animating := ui.end_frame()
	shell_update(s, shell)
	covers_schedule(s)

	if s.sliding {
		t := f32((input.time - s.slide_start) / SLIDE_SECONDS)
		if t >= 1 {
			s.sliding = false
		} else {
			ease := 1 - (1 - t) * (1 - t)
			box := render.Rect{24 + ease * (w - 88), h - 52, 40, 40}
			render.push_shadow(r, box, 20, 12)
			render.push_rect(r, box, {0.95, 0.80, 0.30, 1}, 20)
		}
	}

	if s.screen != .Library && ui_input.mouse_inside {
		size: f32 = 14 if ui.mouse_down(ui_input^) else 10
		m := ui_input.mouse
		render.push_rect(r, {m.x - size / 2, m.y - size / 2, size, size}, {1, 1, 1, 0.8}, size / 2)
	}

	if s.show_overlay {
		draw_frame_overlay(s, w)
	}
	s.ui_ms = f32(time.duration_milliseconds(time.tick_since(ui_begin)))

	{
		prof_scope(s, "end_frame")
		render.end_frame(r)
	}
	// The frame is done with the strings it borrowed, so a list can close.
	acted := pending_apply(s)
	if r.stats != s.last_stats {
		fmt.eprintfln("render: %d draw calls, %d instances", r.stats.draw_calls, r.stats.instances)
		s.last_stats = r.stats
	}
	return {animating = b32(animating || acted || s.sliding || s.text.needs_redraw), wake_after = ui.wake_after(&s.ui)}
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
		row := render.Rect{panel.x + 16, panel.y + 16 + f32(i) * 34 + s.scroll.y, 200 + f32(i % 4) * 90, 26}
		render.push_shadow(r, row, 13, 8, {0, 2})
		render.push_gradient(r, row, hsv(f32(i) * 0.05, 0.5, 0.9), hsv(f32(i) * 0.05 + 0.15, 0.7, 0.6), true, 13)
	}
	render.push_shadow(r, {panel.x + panel.w - 70, panel.y + 150, 120, 120}, 60, 30, {}, 0, {0.3, 0.6, 1, 0.9})
	render.pop_clip(r)

	// Textured quads.
	big := render.Rect{716, 430, 160, 160}
	render.push_shadow(r, big, 20, 20, {0, 6})
	render.push_image(r, big, s.checker, radius = 20)
	render.push_image(r, {900, 430, 20, 20}, s.checker) // minified: mips blend the checks
	render.push_image(r, {960, 430, 100, 100}, s.checker, src = {0, 0, 64, 64}, tint = {1, 0.6, 0.6, 1}, radius = 50)
	render.push_image(r, {900, 550, 40, 40}, s.checker, src = {0, 0, 32, 32}, nearest = true)
	render.push_rect(r, {960, 550, 100, 40}, {1, 1, 1, 1}, 8, 2)

	// 50% white over black three ways: a premultiplied sRGB texel, R8
	// coverage and a solid colour. All three should come out the same grey.
	strip := render.Rect{716, 610, 120, 40}
	render.push_rect(r, strip, {0, 0, 0, 1})
	render.push_image(r, {strip.x + 5, strip.y + 5, 30, 30}, s.half_white)
	render.push_image(r, {strip.x + 45, strip.y + 5, 30, 30}, s.half_cover)
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

// hsv returns an opaque sRGB colour. Hue wraps, so any value works.
hsv :: proc(h, s, v: f32) -> render.Color {
	h6 := (h - math.floor(h)) * 6
	k := [3]f32{math.mod(5 + h6, 6), math.mod(3 + h6, 6), math.mod(1 + h6, 6)}
	c: render.Color = 1
	for i in 0 ..< 3 {
		c[i] = v - v * s * max(0, min(k[i], 4 - k[i], 1))
	}
	return c
}

// draw_frame_overlay draws the CPU time of the last FRAME_HISTORY frames as
// bars, newest on the right, with lines at 120 Hz and 60 Hz budgets. Under
// the bars: the last frame's CPU time in total and building the frame (the
// UI, before end_frame), then its draw calls (blue), instances (green), and
// the text cache's runs and atlas pages, then the keyed boxes in use, in red
// when the pool ran out this frame, then the process's memory footprint (as
// Activity Monitor shows it) and what Metal has allocated on the GPU.
draw_frame_overlay :: proc(s: ^State, view_width: f32) {
	BAR_W :: 2
	PX_PER_MS :: 4
	PANEL_H :: 80
	panel_w := f32(FRAME_HISTORY * BAR_W) + 16
	x0 := view_width - panel_w - 12
	y0 := f32(12)
	r := &s.renderer

	render.push_rect(r, {x0, y0, panel_w, PANEL_H + 74}, {0, 0, 0, 0.6}, 6)
	for i in 0 ..< FRAME_HISTORY {
		// Oldest first, starting just after the newest entry.
		ms := s.frame_ms[(s.frame_count + u64(i)) % FRAME_HISTORY]
		bar_h := min(ms * PX_PER_MS, PANEL_H)
		color := render.Color{0.30, 0.85, 0.40, 1}
		if ms > 1000.0 / 60 {
			color = {0.95, 0.30, 0.25, 1}
		} else if ms > 1000.0 / 120 {
			color = {0.95, 0.80, 0.25, 1}
		}
		render.push_rect(r, {x0 + 8 + f32(i * BAR_W), y0 + PANEL_H - bar_h, BAR_W - 0.5, bar_h}, color)
	}
	for budget_ms in ([2]f32{1000.0 / 120, 1000.0 / 60}) {
		render.push_rect(r, {x0, y0 + PANEL_H - budget_ms * PX_PER_MS, panel_w, 1}, {1, 1, 1, 0.35})
	}

	t := &s.text
	y := y0 + PANEL_H + 6
	ms := s.frame_ms[(s.frame_count + FRAME_HISTORY - 1) % FRAME_HISTORY]
	line := fmt.tprintf("frame %.2f ms   ui %.2f ms", ms, s.ui_ms)
	text.draw(t, r, .Medium, 11, {x0 + 8, y}, {1, 1, 1, 0.9}, line)
	y += 16
	render.push_rect(r, {x0 + 8, y + 4, 6, 6}, {0.35, 0.60, 1, 1}, 3)
	text.draw(t, r, .Regular, 11, {x0 + 18, y}, {1, 1, 1, 0.9}, fmt.tprint(s.last_stats.draw_calls))
	render.push_rect(r, {x0 + 60, y + 4, 6, 6}, {0.30, 0.85, 0.40, 1}, 3)
	text.draw(t, r, .Regular, 11, {x0 + 70, y}, {1, 1, 1, 0.9}, fmt.tprint(s.last_stats.instances))
	runs := fmt.tprintf("%d runs, %d pages", t.stats.runs, t.stats.pages)
	text.draw(t, r, .Regular, 11, {x0 + panel_w - 8 - text.measure(t, .Regular, 11, runs).width, y}, {1, 1, 1, 0.6}, runs)
	y += 16
	used, capacity, misses := ui.pool_stats(&s.ui)
	if misses > 0 {
		text.draw(t, r, .Medium, 11, {x0 + 8, y}, {0.95, 0.30, 0.25, 1}, fmt.tprintf("boxes %d/%d full, %d without state", used, capacity, misses))
	} else {
		text.draw(t, r, .Regular, 11, {x0 + 8, y}, {1, 1, 1, 0.6}, fmt.tprintf("boxes %d/%d", used, capacity))
	}
	y += 16
	pm := process_memory(r)
	text.draw(t, r, .Regular, 11, {x0 + 8, y}, {1, 1, 1, 0.9}, fmt.tprintf("ram %.1f MB   gpu %.1f MB", f64(pm.footprint) / (1 << 20), f64(pm.gpu) / (1 << 20)))
}
