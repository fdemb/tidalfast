// The hot-reloaded app. The shell loads this package as a dylib and calls the
// procs in `api` through app_get_api.
//
// What survives a reload: everything in State, which lives at the start of
// the shell's persistent memory block. What doesn't: Odin globals in this
// package, procedure pointers and anything allocated by the dylib's own
// runtime. So State holds plain data only. Allocators carry a procedure
// pointer, so they are rebuilt from the arenas on every call instead of being
// stored. The header's version is STATE_VERSION mixed with a hash of State's
// layout (state_version), so a moved or retyped field resets State by
// itself. Bump STATE_VERSION when a reload must not reuse old state for
// another reason. On a size or version mismatch the new code calls the old
// code's release proc from the header, then resets State. State from a build without this header (no magic) is
// reset without calling anything.
package app

import "base:runtime"
import "core:fmt"
import "core:log"
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

CLEAR_COLOR :: render.Color{0.063, 0.063, 0.063, 1}

STATE_VERSION :: 27

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
	bench:        Bench,
	measure:      Measure,
	dev:          Dev,
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
		log.warn("app: state from a build without a state header, resetting without releasing it")
		s = state_reset(m)
		context = app_context(s)
		start(s, shell)
		return
	}
	if version := state_version(); s.version != version || s.size != size_of(State) {
		log.warnf("app: state changed (version %x, %d bytes) -> (version %x, %d bytes), resetting", s.version, s.size, version, size_of(State))
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
		log.error("app: shader rebuild failed, drawing with the previous shaders")
	}
	text.reload(&s.text, shell.request_redraw)
	// The old dylib may have missed a release.
	ui.cancel_pointer(&s.ui)
	data_reload(s, shell)
	playback_reload(s, shell)
	measure_reload(s, shell)
	log.infof("app: reloaded at frame %d, clear colour %v", s.frame_count, CLEAR_COLOR)
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
	s.version = state_version()
	s.size = size_of(State)
	s.release = app_shutdown
	used := mem.align_forward_int(size_of(State), 64)
	mem.arena_init(&s.arena, m.persistent[used:m.persistent_size])
	mem.arena_init(&s.frame_arena, m.frame[:m.frame_size])
	return s
}

// state_version is STATE_VERSION and State's layout in one number: every
// field's name, offset and type, through nested structs and arrays and what
// pointers and slices point to, since that is in the persistent arena too.
// The size check alone misses a field that moved and kept the size.
state_version :: proc() -> u32 {
	h := hash_add(layout_hash(type_info_of(State)), STATE_VERSION)
	return u32(h ~ (h >> 32))
}

// layout_hash is the hash of ti's layout that state_version uses.
layout_hash :: proc(ti: ^runtime.Type_Info) -> u64 {
	seen := make(map[^runtime.Type_Info]bool, runtime.heap_allocator())
	defer delete(seen)
	return hash_type(14695981039346656037, ti, &seen)
}

@(private = "file")
hash_add :: proc(h: u64, v: $T) -> u64 {
	h, v := h, v
	for b in mem.ptr_to_bytes(&v) {
		h = (h ~ u64(b)) * 1099511628211
	}
	return h
}

@(private = "file")
hash_string :: proc(h: u64, s: string) -> u64 {
	h := h
	h = hash_add(h, len(s))
	for b in transmute([]u8)s {
		h = (h ~ u64(b)) * 1099511628211
	}
	return h
}

@(private = "file")
hash_type :: proc(h: u64, ti: ^runtime.Type_Info, seen: ^map[^runtime.Type_Info]bool) -> u64 {
	if ti == nil {
		return hash_add(h, u8(0))
	}
	h := h
	h = hash_add(h, ti.size)
	h = hash_add(h, ti.align)
	switch v in ti.variant {
	case runtime.Type_Info_Named:
		h = hash_string(h, v.name)
		if ti in seen {
			return h
		}
		seen[ti] = true
		h = hash_type(h, v.base, seen)
	case runtime.Type_Info_Integer:
		h = hash_add(h, u8(1))
		h = hash_add(h, v.signed)
	case runtime.Type_Info_Float:
		h = hash_add(h, u8(2))
	case runtime.Type_Info_Boolean:
		h = hash_add(h, u8(3))
	case runtime.Type_Info_String:
		h = hash_add(h, u8(4))
		h = hash_add(h, v.is_cstring)
	case runtime.Type_Info_Pointer:
		h = hash_type(hash_add(h, u8(5)), v.elem, seen)
	case runtime.Type_Info_Multi_Pointer:
		h = hash_type(hash_add(h, u8(6)), v.elem, seen)
	case runtime.Type_Info_Procedure:
		h = hash_add(h, u8(7))
	case runtime.Type_Info_Array:
		h = hash_add(hash_add(h, u8(8)), v.count)
		h = hash_type(h, v.elem, seen)
	case runtime.Type_Info_Enumerated_Array:
		h = hash_add(hash_add(h, u8(9)), v.count)
		h = hash_type(h, v.elem, seen)
		h = hash_type(h, v.index, seen)
	case runtime.Type_Info_Dynamic_Array:
		h = hash_type(hash_add(h, u8(10)), v.elem, seen)
	case runtime.Type_Info_Slice:
		h = hash_type(hash_add(h, u8(11)), v.elem, seen)
	case runtime.Type_Info_Struct:
		h = hash_add(hash_add(h, u8(12)), v.field_count)
		for i in 0 ..< int(v.field_count) {
			h = hash_string(h, v.names[i])
			h = hash_add(h, v.offsets[i])
			h = hash_type(h, v.types[i], seen)
		}
	case runtime.Type_Info_Union:
		h = hash_add(hash_add(h, u8(13)), v.tag_offset)
		for t in v.variants {
			h = hash_type(h, t, seen)
		}
	case runtime.Type_Info_Enum:
		h = hash_type(hash_add(h, u8(14)), v.base, seen)
	case runtime.Type_Info_Map:
		h = hash_type(hash_add(h, u8(15)), v.key, seen)
		h = hash_type(h, v.value, seen)
	case runtime.Type_Info_Bit_Set:
		h = hash_add(hash_add(h, u8(16)), v.lower)
		h = hash_type(h, v.underlying, seen)
	case runtime.Type_Info_Simd_Vector:
		h = hash_type(hash_add(hash_add(h, u8(17)), v.count), v.elem, seen)
	case runtime.Type_Info_Matrix:
		h = hash_add(hash_add(hash_add(h, u8(18)), v.row_count), v.column_count)
		h = hash_type(h, v.elem, seen)
	case runtime.Type_Info_Bit_Field:
		h = hash_add(hash_add(h, u8(19)), v.field_count)
		for i in 0 ..< v.field_count {
			h = hash_string(h, v.names[i])
			h = hash_add(hash_add(h, v.bit_offsets[i]), v.bit_sizes[i])
			h = hash_type(h, v.types[i], seen)
		}
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		h = hash_add(hash_add(h, u8(20)), v.capacity)
		h = hash_type(h, v.elem, seen)
	case runtime.Type_Info_Rune, runtime.Type_Info_Complex, runtime.Type_Info_Quaternion, runtime.Type_Info_Any, runtime.Type_Info_Type_Id, runtime.Type_Info_Parameters, runtime.Type_Info_Soa_Pointer:
		h = hash_add(h, u8(21))
	}
	return h
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
// state_reset maps fresh pages over the block, so zeroing would only touch
// every page of the caches made at init, most of which are never written,
// and make them count against the app's memory.
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
	}
	if !text.init(&s.text, shell.request_redraw) {
		log.error("app: text init failed")
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
	log.infof("app: started, clear colour %v", CLEAR_COLOR)
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
	r := &s.renderer
	render.begin_frame(r, w, h, input.scale, CLEAR_COLOR)
	ui_begin := time.tick_now()
	measure_frame_begin(s)
	text.begin_frame(&s.text, r)
	ui.begin_frame(&s.ui, events, r, &s.text, w, h, input.time, input.mouse_buttons, input.text[:input.text_length])
	ui.set_window_key(&s.ui, bool(input.key_window))
	ui.set_clipboard(&s.ui, shell.get_clipboard, shell.set_clipboard)
	data_update(s, input.time)
	lists_window_key(s, bool(input.key_window))
	playback_update(s, events)
	s.ui.scrollbars = s.settings.scrollbars

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
	animating := ui.end_frame()
	shell_update(s, shell)
	covers_schedule(s)
	dev_draw_over(s, input.time, w, h)

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
	return {animating = b32(animating || acted || s.dev.sliding || s.text.needs_redraw), wake_after = ui.wake_after(&s.ui)}
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
