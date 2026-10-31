package app

// TIDALFAST_MEASURE prints startup marks and memory samples to stderr, one
// line each, as `measure: {json}`, for tools/measure to read. Times are
// milliseconds since the process started, read from the kernel, so dyld and
// everything before main count. The shell prints its own marks (main,
// launched, dylib, window) the same way.
//
//   1        marks and a sample at each mark, nothing else
//   startup  the same, then quit once the first track rows and their covers are drawn
//   memory   after startup, run the memory scenario (measure_step) and quit
//   frames   after startup, scroll the fake data's list with the library
//            bench, print each phase's frame rate and frame times, and quit
//
// With it off the marks are still kept, quietly, until the first track
// rows show, for the launch log (launch_log.odin); after that nothing here
// runs except two counters per drawn row. Marks and samples come from
// frames that happen anyway. Only the memory and frames scenarios start a
// thread, which samples once a second and wakes the UI when a stage's wait
// is over, since an idle window draws no frame to see it.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../platform"
import "../render"
import "../text"
import "../ui"

Measure_Mode :: enum u8 {
	Off,
	On,
	Startup,
	Memory,
	Frames,
}

Mark :: enum u8 {
	Init,
	First_Frame,
	Library, // the sidebar's playlists drawn
	Tracks, // track rows drawn, with every cover on screen
}

MARK_NAMES := [Mark]string {
	.Init        = "init",
	.First_Frame = "first_frame",
	.Library     = "library",
	.Tracks      = "tracks",
}

Memory_Stage :: enum u8 {
	Startup,
	Startup_Idle,
	Open_List,
	List_Open,
	Scroll,
	Scrolled,
	Play,
	Playing,
	Idle_After,
	Done,
}

IDLE_WAIT :: 5 * time.Second
SETTLE_WAIT :: 3 * time.Second
PLAY_WAIT :: 30 * time.Second
PLAY_START_LIMIT :: 20 * time.Second
IDLE_AFTER_WAIT :: 10 * time.Second

Measure :: struct {
	mode:         Measure_Mode,
	start_ns:     i64, // when the process started, Unix nanoseconds
	marks:        bit_set[Mark],
	mark_ms:      [Mark]f64,
	// The frame being built: track rows drawn, and covers asked for and
	// ready. A frame with every cover ready is one with nothing left to fill in.
	rows:         int,
	covers:       int,
	covers_ready: int,
	bio_wraps:    int, // artist biographies broken into lines, which caches
	stage:        Memory_Stage,
	deadline:     time.Tick, // the stage's wait ends; zero for none
	wake_at:      i64, // the deadline for the thread, which wakes the UI at it (atomic)
	wake:         proc "c" (),
	renderer:     ^render.Renderer,
	thread:       posix.pthread_t,
	running:      bool,
	stop:         bool, // atomic
	sema:         sync.Sema, // posted to stop the thread early
	frame_time:   f64, // the frame being measured's Frame_Input.time
	frames:       Frame_Samples,
}

MAX_FRAME_SAMPLES :: 1024

// Frame_Samples is one bench phase's frames, for the frames scenario.
Frame_Samples :: struct {
	phase:    int, // the bench phase they're from, -1 before the first
	last:     f64, // the frame before's time, 0 for none in the phase
	count:    int,
	interval: [MAX_FRAME_SAMPLES]f32, // ms since the frame before
	cpu:      [MAX_FRAME_SAMPLES]f32, // ms building and encoding the frame, not counting the waits
	gpu:      [MAX_FRAME_SAMPLES]f32, // ms the GPU took, render.Renderer.gpu_ms
	// ms the frame spent waiting for the GPU to finish with its slot and for
	// a drawable
	slot_wait:     [MAX_FRAME_SAMPLES]f32,
	drawable_wait: [MAX_FRAME_SAMPLES]f32,
}

Process_Memory :: struct {
	footprint:      int, // what Activity Monitor's Memory column shows
	footprint_peak: int,
	resident:       int,
	resident_peak:  int,
	gpu:            int, // Metal's currentAllocatedSize
}

// Counters is CPU work done since a process or thread started, zero where
// the OS doesn't say.
Counters :: struct {
	instructions: u64,
	cycles:       u64,
}

measure_mode :: proc(value: string) -> Measure_Mode {
	switch value {
	case "":
		return .Off
	case "startup":
		return .Startup
	case "memory":
		return .Memory
	case "frames":
		return .Frames
	}
	return .On
}

measure_start :: proc(s: ^State, shell: ^platform.Shell) {
	m := &s.measure
	m.mode = measure_mode(os.get_env("TIDALFAST_MEASURE", context.temp_allocator))
	m.wake = shell.request_redraw
	m.renderer = &s.renderer
	m.start_ns = process_start_ns()
	measure_thread_start(m)
}

measure_reload :: proc(s: ^State, shell: ^platform.Shell) {
	m := &s.measure
	m.wake = shell.request_redraw
	m.renderer = &s.renderer
	measure_thread_start(m)
}

measure_unload :: proc(s: ^State) {
	m := &s.measure
	if !m.running {
		return
	}
	sync.atomic_store(&m.stop, true)
	sync.sema_post(&m.sema)
	posix.pthread_join(m.thread, nil)
	m.running = false
	m.stop = false
	m.sema = {}
}

@(private = "file")
measure_thread_start :: proc(m: ^Measure) {
	if (m.mode == .Memory || m.mode == .Frames) && m.stage != .Done && !m.running {
		m.running = posix.pthread_create(&m.thread, nil, measure_thread, m) == .NONE
	}
}

// measure_thread samples once a second and wakes the UI when a stage's
// wait is over, since an idle window draws no frames.
@(private = "file")
measure_thread :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	m := (^Measure)(arg)
	for tick := 1; !sync.atomic_load(&m.stop); tick += 1 {
		if sync.sema_wait_with_timeout(&m.sema, time.Second) {
			break
		}
		pm := process_memory(m.renderer)
		buf: [512]u8
		measure_write(fmt.bprintf(buf[:], `{{"tick":%d,"ms":%.1f,"footprint":%d,"footprint_peak":%d,"resident":%d,"resident_peak":%d,"gpu":%d}}`,
			tick, measure_ms(m), pm.footprint, pm.footprint_peak, pm.resident, pm.resident_peak, pm.gpu))
		at := sync.atomic_load(&m.wake_at)
		if at != 0 && time.tick_now()._nsec >= at {
			if _, ok := sync.atomic_compare_exchange_strong(&m.wake_at, at, 0); ok {
				m.wake()
			}
		}
	}
	return nil
}

// measure_frame_begin clears the counts the frame's drawing makes.
measure_frame_begin :: proc(s: ^State) {
	m := &s.measure
	m.rows = 0
	m.covers = 0
	m.covers_ready = 0
	m.bio_wraps = 0
}

// measure_count_cover is for cover_art: a cover drawn this frame, and
// whether its texture is there.
measure_count_cover :: #force_inline proc(s: ^State, ready: bool) {
	s.measure.covers += 1
	s.measure.covers_ready += int(ready)
}

// measure_frame runs after a frame is presented: it prints the marks that
// frame reached and moves the memory scenario on.
measure_frame :: proc(s: ^State) {
	m := &s.measure
	if m.mode == .Off && .Tracks in m.marks {
		return
	}
	measure_mark(s, .First_Frame)
	if s.dev.screen == .Library && !show_login(s) && (s.data.fake || (s.data.sidebar.loaded && len(s.data.sidebar.items) > 0)) {
		measure_mark(s, .Library)
		if m.rows > 0 && m.covers_ready == m.covers {
			measure_mark(s, .Tracks)
		}
	}
	switch m.mode {
	case .Off, .On:
	case .Startup:
		if .Tracks in m.marks && m.stage == .Startup {
			measure_sample(s, "startup")
			m.stage = .Done
			measure_quit()
		}
	case .Memory:
		measure_step(s)
	case .Frames:
		measure_frames_step(s)
	}
}

measure_mark :: proc(s: ^State, mark: Mark) {
	m := &s.measure
	if mark in m.marks {
		return
	}
	m.marks += {mark}
	m.mark_ms[mark] = measure_ms(m)
	if m.mode != .Off {
		measure_line(s, "mark", MARK_NAMES[mark], m.mark_ms[mark], false)
	}
	if mark == .Tracks {
		launch_log_push(s)
	}
}

// A sample also counts the mapped fonts' resident pages, which takes a few
// milliseconds, so marks leave that out.
measure_sample :: proc(s: ^State, name: string) {
	measure_line(s, "sample", name, measure_ms(&s.measure), true)
}

// The memory scenario: idle after startup, open the longest list, scroll
// through it with the bench's auto-scroll while covers load, play for
// PLAY_WAIT, stop, idle again, quit. Each stage ends in a sample.
@(private = "file")
measure_step :: proc(s: ^State) {
	m := &s.measure
	d := &s.data
	due := m.deadline != {} && time.tick_since(m.deadline) >= 0
	switch m.stage {
	case .Startup:
		if .Tracks in m.marks {
			measure_wait(m, .Startup_Idle, IDLE_WAIT)
		}
	case .Startup_Idle:
		if due {
			measure_sample(s, "startup_idle")
			pending_set(s, Playlist_Place{index = longest_list(s)})
			measure_wait(m, .Open_List, 0)
		}
	case .Open_List:
		if measure_list_loaded(d, longest_list(s)) && m.rows > 0 && m.covers_ready == m.covers {
			measure_wait(m, .List_Open, SETTLE_WAIT)
		}
	case .List_Open:
		if due {
			measure_sample(s, "list_open")
			if d.fake {
				s.bench = {running = true, ui = true}
			} else {
				d.bench = {running = true, phase = 1}
			}
			measure_wait(m, .Scroll, 0)
		}
	case .Scroll:
		if !s.bench.running && !d.bench.running {
			measure_wait(m, .Scrolled, SETTLE_WAIT)
		}
	case .Scrolled:
		if due {
			measure_sample(s, "scrolled")
			pending_set(s, Play_Row{index = first_playable(s)})
			measure_wait(m, .Play, PLAY_START_LIMIT)
		}
	case .Play:
		if playback_playing(s) {
			measure_wait(m, .Playing, PLAY_WAIT)
		} else if due {
			measure_write(`{"error":"playback didn't start"}`)
			measure_wait(m, .Playing, 0)
		}
	case .Playing:
		if due {
			measure_sample(s, "playing")
			playback_stop(s)
			ui.data_changed()
			measure_wait(m, .Idle_After, IDLE_AFTER_WAIT)
		}
	case .Idle_After:
		if due {
			measure_sample(s, "idle_after")
			m.stage = .Done
			measure_quit()
		}
	case .Done:
	}
}

// The frames scenario: once the first track rows show and settle, scroll
// the fake data's list with the library bench, and for each phase it
// measures print the frame rate and the CPU and GPU time a frame took. The
// bench asks for the next frame as soon as one is done, so the frame rate
// is what the display and the GPU let through. The CPU time leaves out the
// waits for the GPU and for a drawable, which go with the window and the
// display more than with the frame. The GPU time is of a frame or two
// before (render.Renderer.gpu_ms).
@(private = "file")
measure_frames_step :: proc(s: ^State) {
	m := &s.measure
	switch m.stage {
	case .Startup:
		if .Tracks in m.marks {
			measure_wait(m, .Startup_Idle, SETTLE_WAIT)
		}
	case .Startup_Idle:
		if m.deadline != {} && time.tick_since(m.deadline) >= 0 {
			s.bench = {running = true, ui = true}
			m.frames = {phase = -1}
			measure_wait(m, .Scroll, 0)
		}
	case .Scroll:
		// The frame just drawn, before bench_record moves the bench on.
		b := &s.bench
		phases := bench_phases(b)
		if !b.running || b.phase >= len(phases) {
			return
		}
		f := &m.frames
		if b.phase != f.phase {
			frames_flush(s)
			f^ = {phase = b.phase}
		}
		phase := phases[b.phase]
		if phase.name != "settle" && b.frame >= phase.skip && f.count < MAX_FRAME_SAMPLES {
			if f.last > 0 {
				f.interval[f.count] = f32((m.frame_time - f.last) * 1000)
				r := &s.renderer
				waited := r.slot_wait_ms + r.drawable_wait_ms
				f.cpu[f.count] = max(s.frame_ms[(s.frame_count + FRAME_HISTORY - 1) % FRAME_HISTORY] - waited, 0)
				f.gpu[f.count] = r.gpu_ms
				f.slot_wait[f.count] = r.slot_wait_ms
				f.drawable_wait[f.count] = r.drawable_wait_ms
				f.count += 1
			}
			f.last = m.frame_time
		}
		if b.phase == len(phases) - 1 && b.frame == phase.frames - 1 {
			frames_flush(s)
			m.stage = .Done
			measure_quit()
		}
	case .Open_List, .List_Open, .Scrolled, .Play, .Playing, .Idle_After, .Done:
	}
}

// frames_flush prints the frames recorded for a phase: their count, the
// frame rate, the 95th percentile of the time between frames, and the
// median and 95th percentile of the CPU time spent working on a frame, of
// the GPU's time, and of the two waits left out of the CPU time.
@(private = "file")
frames_flush :: proc(s: ^State) {
	f := &s.measure.frames
	if f.phase < 0 || f.count == 0 {
		return
	}
	pct :: proc(values: []f32, q: f32) -> f32 {
		sorted := slice.clone(values, context.temp_allocator)
		slice.sort(sorted)
		return sorted[min(int(q * f32(len(sorted) - 1) + 0.5), len(sorted) - 1)]
	}
	n := f.count
	total: f64
	for v in f.interval[:n] {
		total += f64(v)
	}
	buf: [768]u8
	measure_write(fmt.bprintf(buf[:], `{{"frames":"%s","count":%d,"fps":%.1f,"interval_p95":%.2f,"cpu_median":%.3f,"cpu_p95":%.3f,"gpu_median":%.3f,"gpu_p95":%.3f,` +
		`"slot_wait_median":%.3f,"slot_wait_p95":%.3f,"drawable_wait_median":%.3f,"drawable_wait_p95":%.3f}}`,
		bench_phases(&s.bench)[f.phase].name, n, f64(n) * 1000 / max(total, 1e-6), pct(f.interval[:n], 0.95),
		pct(f.cpu[:n], 0.5), pct(f.cpu[:n], 0.95), pct(f.gpu[:n], 0.5), pct(f.gpu[:n], 0.95),
		pct(f.slot_wait[:n], 0.5), pct(f.slot_wait[:n], 0.95), pct(f.drawable_wait[:n], 0.5), pct(f.drawable_wait[:n], 0.95)))
}

// measure_wait moves to stage, whose wait ends after wait (none for 0).
// The UI is woken now, so the stage sees a frame, and by the thread at the
// deadline.
@(private = "file")
measure_wait :: proc(m: ^Measure, stage: Memory_Stage, wait: time.Duration) {
	m.stage = stage
	m.deadline = {}
	if wait > 0 {
		m.deadline = time.tick_add(time.tick_now(), wait)
	}
	sync.atomic_store(&m.wake_at, m.deadline._nsec)
	m.wake()
}

// measure_list_loaded says whether sidebar entry index is the open list
// and all its rows are in. Entry 0 is Liked Songs, which is the longest
// list on many accounts.
measure_list_loaded :: proc(d: ^Data, index: int) -> bool {
	if d.fake {
		return true
	}
	return d.view.source == (Source.Liked if index == 0 else Source.Playlist) && d.view.done
}

// longest_list is the sidebar entry with the most tracks. The fake data's
// first entry has all ROW_COUNT rows.
@(private = "file")
longest_list :: proc(s: ^State) -> int {
	if s.data.fake {
		return 0
	}
	longest, most := 0, s.data.sidebar.liked_count
	for item, i in s.data.sidebar.items {
		if item.tracks > most {
			longest, most = i + 1, item.tracks
		}
	}
	return longest
}

// first_playable is the first loaded row with a track id. The mock's long
// playlist starts with track 0, which the player takes for no track.
@(private = "file")
first_playable :: proc(s: ^State) -> int {
	for i in 0 ..< view_count(s) {
		if row := view_row(s, i); row != nil && (s.data.fake || row.id != 0) {
			return i
		}
	}
	return 0
}

// measure_quit quits the way Ctrl-C does, through the shell, so the app's
// shutdown runs.
@(private = "file")
measure_quit :: proc() {
	posix.kill(posix.getpid(), .SIGTERM)
}

@(private = "file")
measure_line :: proc(s: ^State, kind, name: string, ms: f64, fonts_resident: bool) {
	pm := process_memory(&s.renderer)
	pc := process_counters()
	tc := thread_counters()
	view_bytes := view_bytes(&s.data.view)
	buf: [1024]u8
	b := strings.builder_from_bytes(buf[:])
	fmt.sbprintf(&b,
		`{{"%s":"%s","ms":%.1f,"footprint":%d,"footprint_peak":%d,"resident":%d,"resident_peak":%d,"gpu":%d,` +
		`"arena":%d,"frame_peak":%d,"atlas_pages":%d,"runs":%d,"covers":%d,"cover_bytes":%d,"rows":%d,"view_bytes":%d,` +
		`"instructions":%d,"cycles":%d,"ui_instructions":%d,"ui_cycles":%d`,
		kind, name, ms, pm.footprint, pm.footprint_peak, pm.resident, pm.resident_peak, pm.gpu,
		s.arena.offset, s.frame_arena.peak_used, text.atlas_pages(&s.text), s.text.run_count, s.data.covers.used, s.data.covers.bytes, view_count(s), view_bytes, pc.instructions, pc.cycles, tc.instructions, tc.cycles)
	if fonts_resident {
		fonts, mapped, resident := text.mapped_fonts(&s.text)
		fmt.sbprintf(&b, `,"fonts_mapped":%d,"fonts_mapped_bytes":%d,"fonts_resident":%d`, fonts, mapped, resident)
	}
	strings.write_byte(&b, '}')
	measure_write(strings.to_string(b))
}

// measure_write writes one line with one write, so lines from the UI and
// the sampler thread don't interleave.
@(private = "file")
measure_write :: proc(json: string) {
	buf: [1100]u8
	n := copy(buf[:], "measure: ")
	n += copy(buf[n:], json)
	if n < len(buf) {
		buf[n] = '\n'
		n += 1
	}
	posix.write(posix.STDERR_FILENO, raw_data(buf[:]), uint(n))
}

@(private = "file")
measure_ms :: proc "contextless" (m: ^Measure) -> f64 {
	return f64(time.to_unix_nanoseconds(time.now()) - m.start_ns) / 1e6
}
