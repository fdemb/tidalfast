// The app. main hands the process to the shell, which calls app_init,
// app_frame and app_shutdown (platform.h). State lives at the start of the
// shell's persistent memory block, and the rest of the block is its arena.
package app

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:prof/spall"
import "core:sync"
import "core:time"

import "../platform"
import "../render"
import "../text"
import "../ui"

CLEAR_COLOR :: render.Color{0.063, 0.063, 0.063, 1}

FRAME_HISTORY :: 120

State :: struct {
	arena:        mem.Arena, // the rest of the persistent block
	frame_arena:  mem.Arena, // reset at the start of every frame
	renderer:     render.Renderer,
	gpu_resets:   u32, // the renderer's device_resets the textures were made for
	text:         text.State,
	rows:         []Row,
	last_stats:   render.Stats,
	frame_count:  u64,
	frame_ms:     [FRAME_HISTORY]f32,
	ui_ms:        f32, // last frame's time building the frame, before end_frame
	show_overlay: bool,
	log_events:   bool,
	log_render:   bool, // print draw calls and instances when they change
	ui:           ui.State,
	library:      Library,
	data:         Data,
	settings:     Settings,
	volume_before_override: Maybe(f32),
	playback:     Playback,
	search:       Search,
	pending:      Pending, // what the frame being built asked for, done after it
	history:      History,
	access_sent:  u64, // hash of the accessibility tree the shell has
	// The views run under the player bar, which covers their bottoms with a
	// blur of them, where the renderer has backdrops (render.BACKDROPS) and
	// Settings.bar says so.
	bar_over_content: bool,
	// TIDALFAST_BLUR_REFERENCE: the bar is left out, and the shell blurs
	// where it goes, to compare the renderer's blur with.
	blur_reference:   bool,
	// TIDALFAST_STATUS_BAR: a line under the player bar says what's playing
	// and the status (status_text). Nothing else shows the status.
	status_bar:       bool,
	toast:            Toast,
	drag_sent:    u64, // hash of the drag regions the shell has
	titlebar_h:   f32, // this frame's Frame_Input.titlebar_height
	window:       Window_Buttons,
	bench:        Bench,
	measure:      Measure,
	dev:          Dev,
	profiling:    bool,
	spall_ctx:    spall.Context,
	spall_buf:    spall.Buffer,
}

main :: proc() {
	os.exit(int(shell_main(i32(len(runtime.args__)), raw_data(runtime.args__))))
}

// Linked in by build.sh: shell/shell.m on macOS, shell/shell_wayland.c on
// Linux and shell/shell_win32.c on Windows.
foreign {
	shell_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 ---
}

@(export)
app_init :: proc "c" (m: ^platform.Memory, shell: ^platform.Shell) {
	context = runtime.default_context()
	s := state_init(m)
	context = app_context(s)
	start(s, shell)
}

@(export)
app_shutdown :: proc "c" (m: ^platform.Memory) {
	context = runtime.default_context()
	s := (^State)(m.persistent)
	context = app_context(s)
	if s.profiling {
		spall.buffer_destroy(&s.spall_ctx, &s.spall_buf)
		spall.context_destroy(&s.spall_ctx)
	}
	measure_stop(s)
	workers_stop(&s.data)
	if !settings_flush(&s.data.settings_store) {
		log.errorf("app: couldn't save the settings to %s", s.data.settings_store.path)
	}
	playback_shutdown(s)
	data_shutdown(s)
	search_shutdown(s)
	text.destroy(&s.text, &s.renderer)
	render.destroy(&s.renderer)
}

@(export)
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
	s.measure.frame_time = input.time
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

// state_init places State at the start of the persistent block. The shell
// maps the block fresh, so it starts zeroed, see persistent_allocator_proc.
state_init :: proc(m: ^platform.Memory) -> ^State {
	s := (^State)(m.persistent)
	used := mem.align_forward_int(size_of(State), 64)
	mem.arena_init(&s.arena, m.persistent[used:m.persistent_size])
	mem.arena_init(&s.frame_arena, m.frame[:m.frame_size])
	return s
}

// app_context is the context for every call into the app. Its allocator
// isn't the persistent arena: that never frees, so a make or clone that
// forgot its allocator would grow it for good. start takes the arena by
// name, see persistent_allocator.
app_context :: proc(s: ^State) -> runtime.Context {
	c := runtime.default_context()
	c.logger = app_logger()
	c.allocator = {closed_allocator_proc, nil}
	c.temp_allocator = mem.arena_allocator(&s.frame_arena)
	return c
}

persistent_allocator :: proc(s: ^State) -> runtime.Allocator {
	return {persistent_allocator_proc, &s.arena}
}

@(private = "file")
closed_logged: bool

// closed_allocator_proc is context.allocator outside start. Debug builds
// stop at an allocation that forgot its allocator. Release builds log the
// first one and leak it to the heap, which unlike the persistent arena has
// no fixed size to run out of.
closed_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free_All:
		when ODIN_DEBUG {
			log.panicf("app: %v of %d bytes from context.allocator at %v, pass an allocator", mode, size, loc)
		}
		if !closed_logged {
			closed_logged = true
			log.errorf("app: %v of %d bytes from context.allocator at %v, pass an allocator", mode, size, loc)
		}
		if mode == .Free_All {
			return nil, .Mode_Not_Implemented
		}
	case .Free:
		return nil, nil
	}
	return runtime.heap_allocator_proc(nil, mode, size, alignment, old_memory, old_size, loc)
}

// persistent_allocator_proc is the persistent arena without zeroing. The
// arena only ever moves forward through memory that is still zero, since
// the shell maps the block fresh, so zeroing would only touch every page of
// the caches made at init, most of which are never written, and make them
// count against the app's memory.
persistent_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	return mem.arena_allocator_proc(data, .Alloc_Non_Zeroed if mode == .Alloc else mode, size, alignment, old_memory, old_size, loc)
}

start :: proc(s: ^State, shell: ^platform.Shell) {
	// The caches and pools made here last as long as State.
	context.allocator = persistent_allocator(s)
	measure_start(s, shell)
	// Off unless asked for. The benches draw it, so their numbers include it.
	bench := os.get_env("TIDALFAST_BENCH", context.temp_allocator)
	s.show_overlay = os.get_env("TIDALFAST_OVERLAY", context.temp_allocator) != "" || bench != ""
	s.log_events = os.get_env("TIDALFAST_LOG_EVENTS", context.temp_allocator) != ""
	s.log_render = os.get_env("TIDALFAST_LOG_RENDER", context.temp_allocator) != ""
	s.blur_reference = os.get_env("TIDALFAST_BLUR_REFERENCE", context.temp_allocator) != ""
	s.status_bar = os.get_env("TIDALFAST_STATUS_BAR", context.temp_allocator) != ""

	// TIDALFAST_SPALL=path writes a spall trace of every frame to path. Only
	// the fd is used after this.
	if path := os.get_env("TIDALFAST_SPALL", context.temp_allocator); path != "" {
		ctx, ok := spall.context_create_with_scale(path, false, 1)
		if ok {
			ctx.file = nil
			s.spall_ctx = ctx
			s.spall_buf = spall.buffer_create(make([]u8, spall.BUFFER_DEFAULT_SIZE), u32(sync.current_thread_id()))
			s.profiling = true
			log.info("app: writing spall trace to", path)
		}
	}

	// TIDALFAST_CAPTURE=path writes every presented frame to path as a TGA,
	// for checking output without screen recording permission.
	if path := os.get_env("TIDALFAST_CAPTURE", context.allocator); path != "" {
		s.renderer.capture_path = path
	}

	if !render.init(&s.renderer, shell.surface) {
		log.error("app: renderer init failed")
		show_fatal("TIDALfast couldn't start drawing, so its window will stay empty.")
	}
	measure_init_part(s, .Render)
	if !text.init(&s.text, shell.request_redraw) {
		log.error("app: text init failed")
		show_fatal("TIDALfast couldn't load its fonts, so it can't show any text.")
	}
	measure_init_part(s, .Text)
	ui.init(&s.ui)
	measure_init_part(s, .Ui)
	library_init(&s.library)
	measure_init_part(s, .Library)
	data_start(s, shell)
	measure_init_part(s, .Data)
	if s.data.fake {
		s.rows = make_rows()
	}
	measure_init_part(s, .Rows)
	playback_start(s, shell)
	measure_init_part(s, .Playback)
	search_init(s)
	measure_init_part(s, .Search)
	// TIDALFAST_BENCH=1 scrolls the library's track table, =text the text
	// test screen's list.
	switch bench {
	case "", "covers":
	case "text":
		when DEV {
			s.bench.running = true
			s.dev.screen = .Text
		} else {
			log.warn("app: TIDALFAST_BENCH=text is ignored in release builds")
		}
	case:
		s.bench.running = true
		s.bench.ui = true
	}
	dev_start(s)
	log.info("app: started")
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

update_and_draw :: proc(s: ^State, input: ^platform.Frame_Input, shell: ^platform.Shell) -> platform.Frame_Result {
	events := input.events[:input.event_count]
	if s.log_events {
		for e in events {
			log.infof("event: %v", e)
		}
	}
	w, h := input.width, input.height
	s.titlebar_h = input.titlebar_height
	s.window.shown = .Buttons in input.window
	s.window.maximized = .Maximized in input.window
	r := &s.renderer
	render.begin_frame(r, w, h, input.scale, CLEAR_COLOR)
	if r.device_resets != s.gpu_resets {
		// The renderer lost its GPU device and every texture with it.
		s.gpu_resets = r.device_resets
		text.forget_glyphs(&s.text, r)
		covers_forget(s)
		dev_start(s)
		if s.window.texture != 0 {
			render.texture_destroy(r, s.window.texture)
			s.window.texture = 0
		}
	}
	ui_begin := time.tick_now()
	measure_frame_begin(s)
	text.begin_frame(&s.text, r)
	ui.begin_frame(&s.ui, events, r, &s.text, w, h, input.time, input.mouse_buttons, input.text[:input.text_length], input.frame_interval)
	ui.set_window_key(&s.ui, bool(input.key_window))
	ui.set_clipboard(&s.ui, shell.get_clipboard, shell.set_clipboard)
	data_update(s, input.time)
	lists_window_key(s, bool(input.key_window))
	playback_update(s, events)
	s.ui.scrollbars = s.settings.scrollbars
	s.bar_over_content = s.blur_reference || (render.BACKDROPS && s.settings.bar == .Blurred)

	// Backtick toggles the frame-time overlay.
	if ui.take_key(.Grave) {
		s.show_overlay = !s.show_overlay
	}
	dev_input(s, input.time)

	if !dev_draw_screen(s, w, h) {
		if show_login(s) {
			draw_login(s)
		} else {
			draw_library(s, w, h)
		}
	}
	build_window_buttons(s, shell, w)
	animating := ui.end_frame()
	shell_update(s, shell)
	send_window_buttons(s, shell)
	covers_schedule(s)
	dev_draw_over(s, input.time, w, h)
	draw_window_buttons(s, bool(input.key_window))

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
		if s.log_render {
			log.infof("render: %d draw calls, %d instances", r.stats.draw_calls, r.stats.instances)
		}
		s.last_stats = r.stats
	}
	return frame_result(r, animating || acted || s.dev.sliding || s.text.needs_redraw, ui.wake_after(&s.ui))
}

// frame_result is what the shell is told after a frame. While the renderer
// can't show frames, nothing paces them, so the app doesn't animate: a
// frame it wanted comes after render.HIDDEN_POLL instead, and one the
// renderer asks for after poll_after.
frame_result :: proc(r: ^render.Renderer, animating: bool, wake_after: f32) -> platform.Frame_Result {
	result := platform.Frame_Result{animating = b32(animating), wake_after = wake_after}
	if !r.hidden {
		return result
	}
	wake := r.poll_after
	if animating && (wake <= 0 || wake > render.HIDDEN_POLL) {
		wake = render.HIDDEN_POLL
	}
	if wake > 0 && (result.wake_after <= 0 || wake < result.wake_after) {
		result.wake_after = wake
	}
	result.animating = false
	return result
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
// UI, before end_frame), and on macOS the GPU's time on the newest frame it
// has finished, then its draw calls (blue), instances (green), and
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
	if r.gpu_ms > 0 {
		line = fmt.tprintf("%s   gpu %.2f ms", line, r.gpu_ms)
	}
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
