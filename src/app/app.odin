// The hot-reloaded app. The shell loads this package as a dylib and calls the
// procs in `api` through app_get_api.
//
// What survives a reload: everything in State, which lives at the start of
// the shell's persistent memory block. What doesn't: Odin globals in this
// package, procedure pointers and anything allocated by the dylib's own
// runtime. So State holds plain data only. Allocators carry a procedure
// pointer, so they are rebuilt from the arenas on every call instead of being
// stored. If State changes layout, bump STATE_VERSION; a size or version
// mismatch on reload resets State and leaks the old Metal objects.
package app

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:prof/spall"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../platform"
import "../render"

CLEAR_COLOR :: render.Color{0.10, 0.11, 0.13, 1}

STATE_VERSION :: 1

FRAME_HISTORY :: 120

State :: struct {
	version:      u32,
	size:         int,
	arena:        mem.Arena, // the rest of the persistent block
	frame_arena:  mem.Arena, // reset at the start of every frame
	renderer:     render.Renderer,
	frame_count:  u64,
	frame_ms:     [FRAME_HISTORY]f32,
	show_overlay: bool,
	log_events:   bool,
	mouse:        [2]f32,
	mouse_inside: bool,
	mouse_down:   bool,
	scroll:       [2]f32,
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
	if s.version != STATE_VERSION || s.size != size_of(State) {
		fmt.eprintfln("app: state changed (version %d, %d bytes) -> (version %d, %d bytes), resetting", s.version, s.size, STATE_VERSION, size_of(State))
		s = state_reset(m)
		context = app_context(s)
		start(s, shell)
		return
	}
	context = app_context(s)
	if !render.reload(&s.renderer) {
		fmt.eprintln("app: shader rebuild failed, drawing with the previous shaders")
	}
	fmt.eprintfln("app: reloaded at frame %d, clear colour %v", s.frame_count, CLEAR_COLOR)
}

app_unload :: proc "c" (m: ^platform.Memory) {
	context = runtime.default_context()
	s := (^State)(m.persistent)
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
		result = update_and_draw(s, input)
	}
	s.frame_ms[s.frame_count % FRAME_HISTORY] = f32(time.duration_milliseconds(time.tick_since(begin)))
	s.frame_count += 1
	return result
}

state_reset :: proc(m: ^platform.Memory) -> ^State {
	s := (^State)(m.persistent)
	s^ = {}
	s.version = STATE_VERSION
	s.size = size_of(State)
	used := mem.align_forward_int(size_of(State), 64)
	mem.arena_init(&s.arena, m.persistent[used:m.persistent_size])
	mem.arena_init(&s.frame_arena, m.frame[:m.frame_size])
	return s
}

app_context :: proc(s: ^State) -> runtime.Context {
	c := runtime.default_context()
	c.allocator = mem.arena_allocator(&s.arena)
	c.temp_allocator = mem.arena_allocator(&s.frame_arena)
	return c
}

start :: proc(s: ^State, shell: ^platform.Shell) {
	s.show_overlay = true
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
	fmt.eprintfln("app: started, clear colour %v", CLEAR_COLOR)
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

KEY_GRAVE :: 50 // kVK_ANSI_Grave

SLIDE_SECONDS :: 0.6

update_and_draw :: proc(s: ^State, input: ^platform.Frame_Input) -> platform.Frame_Result {
	for e in input.events[:input.event_count] {
		if s.log_events {
			fmt.eprintfln("event: %v", e)
		}
		#partial switch e.kind {
		case .Mouse_Move:
			s.mouse = {e.x, e.y}
			s.mouse_inside = true
		case .Mouse_Leave:
			s.mouse_inside = false
		case .Mouse_Down:
			s.mouse = {e.x, e.y}
			s.mouse_down = true
			if e.button == .Left {
				s.slide_start = input.time
				s.sliding = true
			}
		case .Mouse_Up:
			s.mouse_down = false
		case .Scroll:
			delta := [2]f32{e.dx, e.dy}
			if !e.precise {
				delta *= 16
			}
			s.scroll += delta
		case .Key_Down:
			if e.key_code == KEY_GRAVE && !e.repeat {
				s.show_overlay = !s.show_overlay
			}
		}
	}

	w, h := input.width, input.height
	r := &s.renderer
	render.begin_frame(r, w, h, CLEAR_COLOR)

	render.push_rect(r, {0, 0, 220, h}, {0.14, 0.15, 0.18, 1})
	render.push_rect(r, {0, h - 88, w, 88}, {0.07, 0.08, 0.09, 1})
	render.push_rect(r, {260, 40 + s.scroll.y, 320, 180}, {0.20, 0.45, 0.85, 1})
	render.push_rect(r, {260 + s.scroll.x, 240 + s.scroll.y, 320, 60}, {0.85, 0.35, 0.30, 1})

	if s.sliding {
		t := f32((input.time - s.slide_start) / SLIDE_SECONDS)
		if t >= 1 {
			s.sliding = false
		} else {
			ease := 1 - (1 - t) * (1 - t)
			render.push_rect(r, {240 + ease * (w - 300), h - 70, 40, 40}, {0.95, 0.80, 0.30, 1})
		}
	}

	if s.mouse_inside {
		size: f32 = 14 if s.mouse_down else 10
		render.push_rect(r, {s.mouse.x - size / 2, s.mouse.y - size / 2, size, size}, {1, 1, 1, 0.8})
	}

	if s.show_overlay {
		draw_frame_overlay(s, w)
	}

	{
		prof_scope(s, "end_frame")
		render.end_frame(r)
	}
	return {animating = b32(s.sliding)}
}

// draw_frame_overlay draws the CPU time of the last FRAME_HISTORY frames as
// bars, newest on the right, with lines at 120 Hz and 60 Hz budgets.
draw_frame_overlay :: proc(s: ^State, view_width: f32) {
	BAR_W :: 2
	PX_PER_MS :: 4
	PANEL_H :: 80
	panel_w := f32(FRAME_HISTORY * BAR_W)
	x0 := view_width - panel_w - 12
	y0 := f32(12)
	r := &s.renderer

	render.push_rect(r, {x0, y0, panel_w, PANEL_H}, {0, 0, 0, 0.6})
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
		render.push_rect(r, {x0 + f32(i * BAR_W), y0 + PANEL_H - bar_h, BAR_W - 0.5, bar_h}, color)
	}
	for budget_ms in ([2]f32{1000.0 / 120, 1000.0 / 60}) {
		render.push_rect(r, {x0, y0 + PANEL_H - budget_ms * PX_PER_MS, panel_w, 1}, {1, 1, 1, 0.35})
	}
}
