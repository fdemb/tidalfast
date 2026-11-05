package app

// Memory snapshots: the app menu's Take Memory Snapshot, or SIGUSR1 from
// anywhere, makes the app write the memory breakdown (breakdown.odin) of
// that moment to a file, in any build. Each goes to its own file, named by
// the UTC time, in snapshots/ next to the settings file or in the folder
// TIDALFAST_SNAPSHOTS names. `measure html` shows them on a page. They
// hold sizes and counts, nothing about the account.
//
// The signal handler writes a byte to a pipe. A thread blocked on the pipe
// wakes the UI, whose next frame builds the snapshot into Measure.snapshot
// and hands it back over the pipe for the thread to write, so the UI thread
// never waits on the disk and nothing runs while nobody asks.
//
//   {"snapshot":"20261031-101500","time":1793441700,"commit":"...","build":"release",
//    "uptime_s":3725.1,"window":"1100x700@2","footprint":...,"footprint_peak":...,
//    "resident":...,"gpu":...,"covers":257,"rows":1422,"kept_lists":3,"items":[...]}

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

import "../os_services"
import "../sys"

// What the snapshot thread is woken for, flags in Measure.snap_asks.
Snapshot_Ask :: enum u32 {
	Ask, // from the signal handler
	Write, // Measure.snapshot is ready
	Quit,
}

// The Measure the signal handler wakes, a global so it can reach it.
@(private = "file")
snapshot_measure: ^Measure

snapshot_start :: proc(m: ^Measure) {
	if m.snap_running {
		return
	}
	if !sys.thread_start(&m.snap_thread, snapshot_main, m) {
		return
	}
	m.snap_running = true
	sync.atomic_store(&snapshot_measure, m)
	snapshot_signal_start()
}

// snapshot_stop stops the signal before the thread, so no handler wakes a
// thread that's gone.
snapshot_stop :: proc(m: ^Measure) {
	if !m.snap_running {
		return
	}
	snapshot_signal_stop()
	sync.atomic_store(&snapshot_measure, nil)
	snapshot_send(m, .Quit)
	sys.thread_join(m.snap_thread)
	m.snap_running = false
	m.snap_wanted = false
	m.snap_busy = false
	m.snap_asks = 0
	m.snap_sema = {}
}

// snapshot_send wakes the snapshot thread for ask. Only atomics and a
// futex wake, so the signal handler may call it.
snapshot_send :: proc "contextless" (m: ^Measure, ask: Snapshot_Ask) {
	sync.atomic_or(&m.snap_asks, 1 << u32(ask))
	sync.sema_post(&m.snap_sema)
}

// snapshot_asked is what the signal handler calls.
snapshot_asked :: proc "contextless" () {
	if m := sync.atomic_load(&snapshot_measure); m != nil {
		snapshot_send(m, .Ask)
	}
}

@(private = "file")
snapshot_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	context.logger = app_logger()
	m := (^Measure)(arg)
	for {
		sync.sema_wait(&m.snap_sema)
		asks := sync.atomic_exchange(&m.snap_asks, 0)
		if asks & (1 << u32(Snapshot_Ask.Ask)) != 0 {
			sync.atomic_store(&m.snap_wanted, true)
			m.wake()
		}
		if asks & (1 << u32(Snapshot_Ask.Write)) != 0 {
			snapshot_save(string(m.snapshot[:m.snap_len]))
			free_all(context.temp_allocator)
			sync.atomic_store(&m.snap_busy, false)
		}
		if asks & (1 << u32(Snapshot_Ask.Quit)) != 0 {
			break
		}
	}
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
}

// snapshot_frame takes a snapshot if one was asked for and the last one is
// written. Runs after every frame.
snapshot_frame :: proc(s: ^State) {
	m := &s.measure
	if !sync.atomic_load(&m.snap_wanted) || sync.atomic_load(&m.snap_busy) {
		return
	}
	sync.atomic_store(&m.snap_wanted, false)
	m.snap_len = len(snapshot_json(s, m.snapshot[:]))
	sync.atomic_store(&m.snap_busy, true)
	snapshot_send(m, .Write)
}

// snapshot_json writes the snapshot into buf and returns it.
snapshot_json :: proc(s: ^State, buf: []u8) -> string {
	now := time.now()
	y, mon, d := time.date(now)
	h, min, sec := time.clock(now)
	pm := process_memory(&s.renderer)
	r := &s.renderer
	sb := strings.builder_from_bytes(buf)
	fmt.sbprintf(&sb, `{{"snapshot":"%04d%02d%02d-%02d%02d%02d","time":%d,"commit":%q,"build":"%s","uptime_s":%.1f,"window":"%.0fx%.0f@%.0f",`,
		y, int(mon), d, h, min, sec, time.to_unix_seconds(now), TIDALFAST_COMMIT, "debug" when ODIN_DEBUG else "release",
		measure_ms(&s.measure) / 1000, r.width, r.height, r.scale)
	fmt.sbprintf(&sb, `"footprint_peak":%d,"resident":%d,"gpu":%d,"covers":%d,"cover_bytes":%d,"rows":%d,"kept_lists":%d,"runs":%d,`,
		pm.footprint_peak, pm.resident, pm.gpu, s.data.covers.used, s.data.covers.bytes, view_count(s), s.data.lists.count, s.text.run_count)
	breakdown_json(s, &sb)
	strings.write_byte(&sb, '}')
	return strings.to_string(sb)
}

// snapshot_dir is where snapshots go, "" for nowhere.
snapshot_dir :: proc(allocator: runtime.Allocator) -> string {
	if dir := os.get_env("TIDALFAST_SNAPSHOTS", allocator); dir != "" {
		return dir
	}
	dir := os_services.config_dir(context.temp_allocator)
	if dir == "" {
		return ""
	}
	return strings.concatenate({dir, "/tidalfast/snapshots"}, allocator)
}

// snapshot_save writes json to its own file in snapshot_dir. Runs on the
// snapshot thread.
@(private = "file")
snapshot_save :: proc(json: string) {
	dir := snapshot_dir(context.temp_allocator)
	name_start := strings.index(json, `"snapshot":"`)
	if dir == "" || name_start < 0 {
		return
	}
	name := json[name_start + len(`"snapshot":"`):][:len("20261031-101500")]
	_ = os.make_directory_all(dir)
	path := strings.concatenate({dir, "/", name, ".json"}, context.temp_allocator)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]u8)json) != nil || os.rename(tmp, path) != nil {
		log.errorf("snapshot: couldn't write %s", path)
		return
	}
	log.infof("snapshot: wrote %s", path)
}
