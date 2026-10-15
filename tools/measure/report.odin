package measure

// Reading the app's `measure:` lines, summing up runs into metrics, the
// results file and comparing two of them. No processes here, so the tests
// can use all of it.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

LINE_PREFIX :: "measure: "

// Line is one `measure:` line. A shell mark has only mark and ms.
Line :: struct {
	mark:               string,
	sample:             string,
	tick:               int,
	error:              string,
	ms:                 f64,
	footprint:          f64,
	footprint_peak:     f64,
	resident:           f64,
	resident_peak:      f64,
	gpu:                f64,
	arena:              f64,
	frame_peak:         f64,
	atlas_pages:        f64,
	runs:               f64,
	covers:             f64,
	cover_bytes:        f64,
	rows:               f64,
	view_bytes:         f64,
	fonts_mapped:       f64,
	fonts_mapped_bytes: f64,
	fonts_resident:     f64,
}

// The marks in the order they happen. The shell prints main, launched,
// dylib and window; the app the rest.
MARKS := [?]string{"main", "launched", "dylib", "init", "window", "first_frame", "library", "tracks"}

// The memory scenario's samples in order.
STAGES := [?]string{"startup_idle", "list_open", "scrolled", "playing", "idle_after"}

// Memory fields kept per sample: name in the line, and whether it's bytes
// (reported in MB) or a count.
Field :: struct {
	name:  string,
	bytes: bool,
}

MEMORY_FIELDS := [?]Field {
	{"footprint", true},
	{"resident", true},
	{"gpu", true},
	{"footprint_peak", true},
	{"arena", true},
	{"frame_peak", true},
	{"atlas_pages", false},
	{"runs", false},
	{"covers", false},
	{"cover_bytes", true},
	{"rows", false},
	{"view_bytes", true},
	{"fonts_mapped", false},
	{"fonts_mapped_bytes", true},
	{"fonts_resident", true},
}

line_field :: proc(l: ^Line, name: string) -> f64 {
	switch name {
	case "footprint":          return l.footprint
	case "footprint_peak":     return l.footprint_peak
	case "resident":           return l.resident
	case "resident_peak":      return l.resident_peak
	case "gpu":                return l.gpu
	case "arena":              return l.arena
	case "frame_peak":         return l.frame_peak
	case "atlas_pages":        return l.atlas_pages
	case "runs":               return l.runs
	case "covers":             return l.covers
	case "cover_bytes":        return l.cover_bytes
	case "rows":               return l.rows
	case "view_bytes":         return l.view_bytes
	case "fonts_mapped":       return l.fonts_mapped
	case "fonts_mapped_bytes": return l.fonts_mapped_bytes
	case "fonts_resident":     return l.fonts_resident
	}
	return 0
}

// parse_line reads one line of the app's stderr. Lines that aren't
// measure lines, or don't parse, give ok false.
parse_line :: proc(text: string, allocator := context.allocator) -> (l: Line, ok: bool) {
	start := strings.index(text, LINE_PREFIX)
	if start < 0 {
		return
	}
	body := strings.trim_space(text[start + len(LINE_PREFIX):])
	if json.unmarshal_string(body, &l, allocator = allocator) != nil {
		return {}, false
	}
	return l, true
}

// parse_log reads every measure line in a run's stderr.
parse_log :: proc(log: string, allocator := context.allocator) -> []Line {
	lines := make([dynamic]Line, allocator)
	rest := log
	for text in strings.split_lines_iterator(&rest) {
		if l, ok := parse_line(text, allocator); ok {
			append(&lines, l)
		}
	}
	return lines[:]
}

find_mark :: proc(lines: []Line, name: string) -> (^Line, bool) {
	for &l in lines {
		if l.mark == name {
			return &l, true
		}
	}
	return nil, false
}

find_sample :: proc(lines: []Line, name: string) -> (^Line, bool) {
	for &l in lines {
		if l.sample == name {
			return &l, true
		}
	}
	return nil, false
}

Stats :: struct {
	median, min, max: f64,
	count:            int,
}

stats :: proc(values: []f64) -> Stats {
	if len(values) == 0 {
		return {}
	}
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	n := len(sorted)
	median := sorted[n / 2] if n % 2 == 1 else (sorted[n / 2 - 1] + sorted[n / 2]) / 2
	return {median, sorted[0], sorted[n - 1], n}
}

// Metric is one number in a results file: scenario (startup or memory),
// setup (fake, mock or real), row (a mark or stage), field and unit.
Metric :: struct {
	scenario: string,
	setup:    string,
	row:      string,
	field:    string,
	unit:     string,
	value:    f64,
}

Machine :: struct {
	model:     string,
	cpu:       string,
	memory_gb: f64,
	os:        string,
	os_build:  string,
}

Results :: struct {
	version: int,
	time:    string,
	machine: Machine,
	app:     string,
	metrics: [dynamic]Metric,
}

MB :: 1 << 20

// add_startup sums up a setup's startup runs: for each mark, run 1 by
// itself, since the first run after a build also pays for the font cache
// and code signing checks, then the median, min and max of the rest. Runs
// that never reached a mark leave it out. Memory at the tracks mark goes in
// as row "memory".
add_startup :: proc(r: ^Results, setup: string, runs: [][]Line) {
	if len(runs) == 0 {
		return
	}
	for mark in MARKS {
		later := make([dynamic]f64, context.temp_allocator)
		for run, i in runs {
			l, ok := find_mark(run, mark)
			if !ok {
				continue
			}
			if i == 0 {
				append(&r.metrics, Metric{"startup", setup, mark, "first", "ms", l.ms})
			} else {
				append(&later, l.ms)
			}
		}
		if len(later) > 0 {
			st := stats(later[:])
			append(&r.metrics, Metric{"startup", setup, mark, "median", "ms", st.median})
			append(&r.metrics, Metric{"startup", setup, mark, "min", "ms", st.min})
			append(&r.metrics, Metric{"startup", setup, mark, "max", "ms", st.max})
		}
	}
	later := runs[1:] if len(runs) > 1 else runs
	for field in ([?]string{"footprint", "resident", "gpu"}) {
		values := make([dynamic]f64, context.temp_allocator)
		for run in later {
			if l, ok := find_mark(run, "tracks"); ok {
				append(&values, line_field(l, field))
			}
		}
		if len(values) > 0 {
			append(&r.metrics, Metric{"startup", setup, "memory", field, "MB", stats(values[:]).median / MB})
		}
	}
}

// add_memory sums up a setup's memory runs: each stage's fields, the
// median over the runs.
add_memory :: proc(r: ^Results, setup: string, runs: [][]Line) {
	for stage in STAGES {
		for field in MEMORY_FIELDS {
			values := make([dynamic]f64, context.temp_allocator)
			for run in runs {
				if l, ok := find_sample(run, stage); ok {
					append(&values, line_field(l, field.name))
				}
			}
			if len(values) == 0 {
				continue
			}
			v := stats(values[:]).median
			if field.bytes {
				append(&r.metrics, Metric{"memory", setup, stage, field.name, "MB", v / MB})
			} else {
				append(&r.metrics, Metric{"memory", setup, stage, field.name, "", v})
			}
		}
	}
}

find_metric :: proc(metrics: []Metric, scenario, setup, row, field: string) -> (f64, bool) {
	for m in metrics {
		if m.scenario == scenario && m.setup == setup && m.row == row && m.field == field {
			return m.value, true
		}
	}
	return 0, false
}

// setups lists the setups a scenario has results for, in order of first
// appearance.
setups :: proc(metrics: []Metric, scenario: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for m in metrics {
		if m.scenario == scenario && !slice.contains(out[:], m.setup) {
			append(&out, m.setup)
		}
	}
	return out[:]
}

// write_tables prints the startup and memory tables.
write_tables :: proc(b: ^strings.Builder, r: ^Results) {
	for setup in setups(r.metrics[:], "startup") {
		fmt.sbprintfln(b, "startup, %s: ms since the process started; run 1, then median/min/max of the later runs", setup)
		fmt.sbprintfln(b, "  %-12s %9s %9s %9s %9s", "mark", "run 1", "median", "min", "max")
		for mark in MARKS {
			first, has_first := find_metric(r.metrics[:], "startup", setup, mark, "first")
			median, has_median := find_metric(r.metrics[:], "startup", setup, mark, "median")
			if !has_first && !has_median {
				continue
			}
			lo, _ := find_metric(r.metrics[:], "startup", setup, mark, "min")
			hi, _ := find_metric(r.metrics[:], "startup", setup, mark, "max")
			fmt.sbprintfln(b, "  %-12s %9s %9s %9s %9s", mark, num(first, has_first), num(median, has_median), num(lo, has_median), num(hi, has_median))
		}
		fp, has := find_metric(r.metrics[:], "startup", setup, "memory", "footprint")
		res, _ := find_metric(r.metrics[:], "startup", setup, "memory", "resident")
		gpu, _ := find_metric(r.metrics[:], "startup", setup, "memory", "gpu")
		if has {
			fmt.sbprintfln(b, "  at tracks: footprint %.1f MB, resident %.1f MB, gpu %.1f MB", fp, res, gpu)
		}
		fmt.sbprintln(b)
	}
	for setup in setups(r.metrics[:], "memory") {
		fmt.sbprintfln(b, "memory, %s: MB unless a count", setup)
		fmt.sbprintfln(b, "  %-13s %9s %9s %9s %8s %9s %7s %9s %9s", "stage", "footprint", "resident", "gpu", "covers", "cover MB", "runs", "fonts map", "fonts res")
		for stage in STAGES {
			fp, has := find_metric(r.metrics[:], "memory", setup, stage, "footprint")
			if !has {
				continue
			}
			v :: proc(r: ^Results, setup, stage, field: string) -> f64 {
				x, _ := find_metric(r.metrics[:], "memory", setup, stage, field)
				return x
			}
			fmt.sbprintfln(b, "  %-13s %9s %9s %9s %8s %9s %7s %9s %9s", stage, num(fp, true), num(v(r, setup, stage, "resident"), true), num(v(r, setup, stage, "gpu"), true),
				fmt.tprint(int(v(r, setup, stage, "covers"))), num(v(r, setup, stage, "cover_bytes"), true), fmt.tprint(int(v(r, setup, stage, "runs"))), num(v(r, setup, stage, "fonts_mapped_bytes"), true), num(v(r, setup, stage, "fonts_resident"), true))
		}
		if peak, has := find_metric(r.metrics[:], "memory", setup, "idle_after", "footprint_peak"); has {
			fmt.sbprintfln(b, "  peak footprint %.1f MB", peak)
		}
		fmt.sbprintln(b)
	}
}

@(private = "file")
num :: proc(v: f64, has: bool) -> string {
	return fmt.tprintf("%.1f", v) if has else "-"
}

// Delta is one metric in both results files.
Delta :: struct {
	using metric: Metric, // value is a's
	b:            f64,
}

// compare pairs up the metrics in a and b, in a's order. Metrics only one
// side has are left out.
compare :: proc(a, b: []Metric, allocator := context.allocator) -> []Delta {
	out := make([dynamic]Delta, allocator)
	for m in a {
		if v, ok := find_metric(b, m.scenario, m.setup, m.row, m.field); ok {
			append(&out, Delta{m, v})
		}
	}
	return out[:]
}

// write_compare prints each pair with its change. Times and sizes are
// better lower, so a change in one of 10% and at least 1 ms or MB is marked
// worse or better; smaller ones are within what startup times vary from run
// to run.
write_compare :: proc(sb: ^strings.Builder, deltas: []Delta) {
	fmt.sbprintfln(sb, "%-8s %-5s %-13s %-18s %10s %10s %10s %8s", "scenario", "setup", "row", "field", "a", "b", "delta", "change")
	for d in deltas {
		diff := d.b - d.value
		change := "-"
		flag := ""
		if d.value != 0 {
			pct := diff / math.abs(d.value) * 100
			change = fmt.tprintf("%+.1f%%", pct)
			if math.abs(pct) >= 10 && math.abs(diff) >= 1 && d.unit != "" {
				flag = " worse" if diff > 0 else " better"
			}
		}
		line := fmt.tprintf("%-8s %-5s %-13s %-18s %10s %10s %10s %8s %s%s", d.scenario, d.setup, d.row, d.field, num(d.value, true), num(d.b, true), fmt.tprintf("%+.1f", diff), change, d.unit, flag)
		fmt.sbprintln(sb, strings.trim_right_space(line))
	}
}

load_results :: proc(data: []u8, allocator := context.allocator) -> (r: Results, ok: bool) {
	return r, json.unmarshal(data, &r, allocator = allocator) == nil
}

// save_results writes one metric a line, values to 0.1, so two results
// files diff well.
save_results :: proc(r: ^Results, allocator := context.allocator) -> ([]u8, bool) {
	b := strings.builder_make(allocator)
	m := r.machine
	fmt.sbprintfln(&b, `{{"version": %d, "time": %q, "app": %q,`, r.version, r.time, r.app)
	fmt.sbprintfln(&b, `"machine": {{"model": %q, "cpu": %q, "memory_gb": %.0f, "os": %q, "os_build": %q}},`, m.model, m.cpu, m.memory_gb, m.os, m.os_build)
	fmt.sbprintln(&b, `"metrics": [`)
	for x, i in r.metrics {
		fmt.sbprintf(&b, `  {{"scenario": %q, "setup": %q, "row": %q, "field": %q, "unit": %q, "value": %.1f}}`, x.scenario, x.setup, x.row, x.field, x.unit, x.value)
		fmt.sbprintln(&b, "," if i + 1 < len(r.metrics) else "")
	}
	fmt.sbprintln(&b, "]}")
	return b.buf[:], true
}
