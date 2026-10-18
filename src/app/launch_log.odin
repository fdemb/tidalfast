package app

// The launch log: every real launch that gets to its first track rows
// appends one JSON line to launches.jsonl next to the settings file, so
// startup can be read off the launches the app actually has, on this
// machine, with this account and cache. `measure launches` sums it up per
// build. Nothing leaves the machine.
//
//   {"time":1792241056,"commit":"5011dde","build":"release","init":512.3,"first_frame":630.1,
//    "library":641.0,"tracks":702.4,"ui_instructions":901234567,"instructions":1712345678,
//    "footprint":98765432}
//
// Times are ms since the process started, as in TIDALFAST_MEASURE's marks.
// TIDALFAST_LAUNCH_LOG names another file, or turns the log off with "off".
// Launches against the mock (TIDALFAST_API) go only to a file named that
// way; the fake data's and TIDALFAST_MEASURE's never do. A worker appends
// the line; past LAUNCH_LOG_LIMIT bytes the file keeps its newest half.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../jobs"
import "../os_services"

TIDALFAST_COMMIT :: #config(TIDALFAST_COMMIT, "")
LAUNCH_LOG_LIMIT :: 512 * 1024

// launch_log_path is where launches go, "" for nowhere.
launch_log_path :: proc(allocator: runtime.Allocator) -> string {
	switch p := os.get_env("TIDALFAST_LAUNCH_LOG", context.temp_allocator); p {
	case "off":
		return ""
	case "":
	case:
		return strings.clone(p, allocator)
	}
	dir := os_services.config_dir(context.temp_allocator)
	if dir == "" {
		return ""
	}
	return strings.concatenate({dir, "/tidalfast/launches.jsonl"}, allocator)
}

// launch_log_push hands this launch's line to a worker. A queue too full to
// take it drops it.
launch_log_push :: proc(s: ^State) {
	d := &s.data
	// The fake data starts no workers to write it.
	if d.launch_log_path == "" || d.fake || s.measure.mode != .Off {
		return
	}
	if d.mock && os.get_env("TIDALFAST_LAUNCH_LOG", context.temp_allocator) == "" {
		return
	}
	m := &s.measure
	launch := Launch {
		time            = time.to_unix_seconds(time.now()),
		mark_ms         = m.mark_ms,
		ui_instructions = thread_counters().instructions,
		instructions    = process_counters().instructions,
		footprint       = process_memory(&s.renderer).footprint,
	}
	jobs.push(&d.queue, Job{auth = d.auth_gen, payload = Launch_Log_Job{launch}}, PRIORITY_DATA)
}

// Launch is what the launch log keeps of one launch.
Launch :: struct {
	time:            i64, // unix seconds
	mark_ms:         [Mark]f64,
	ui_instructions: u64,
	instructions:    u64,
	footprint:       int,
}

// launch_log_line is l as a line of the launch log.
launch_log_line :: proc(l: Launch, allocator: runtime.Allocator) -> []u8 {
	line := fmt.aprintf(
		`{{"time":%d,"commit":%q,"build":"%s","init":%.1f,"first_frame":%.1f,"library":%.1f,"tracks":%.1f,` +
		`"ui_instructions":%d,"instructions":%d,"footprint":%d}}` + "\n",
		l.time, TIDALFAST_COMMIT, "debug" when ODIN_DEBUG else "release",
		l.mark_ms[.Init], l.mark_ms[.First_Frame], l.mark_ms[.Library], l.mark_ms[.Tracks],
		l.ui_instructions, l.instructions, l.footprint, allocator = allocator)
	return transmute([]u8)line
}

// launch_log_append adds line to the file at path, first cutting the file
// to its newest half if it's grown past LAUNCH_LOG_LIMIT. Runs on a worker.
launch_log_append :: proc(path: string, line: []u8) -> bool {
	if info, err := os.stat(path, context.temp_allocator); err == nil && info.size > LAUNCH_LOG_LIMIT {
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr == nil {
			keep := data[len(data) / 2:]
			if nl := strings.index_byte(string(keep), '\n'); nl >= 0 {
				keep = keep[nl + 1:]
			}
			tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
			if os.write_entire_file(tmp, keep) != nil || os.rename(tmp, path) != nil {
				return false
			}
		}
	}
	dir, _ := os.split_path(path)
	_ = os.make_directory_all(dir)
	f, err := os.open(path, {.Write, .Create, .Append})
	if err != nil {
		return false
	}
	defer os.close(f)
	_, werr := os.write(f, line)
	return werr == nil
}
