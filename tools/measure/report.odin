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
	// Instructions and cycles since the process started, all threads, and
	// the UI thread's alone. Zero where the OS doesn't say.
	instructions:       f64,
	cycles:             f64,
	ui_instructions:    f64,
	ui_cycles:          f64,
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
	case "instructions":       return l.instructions
	case "cycles":             return l.cycles
	case "ui_instructions":    return l.ui_instructions
	case "ui_cycles":          return l.ui_cycles
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

// COUNTERS are the instruction counts kept per startup mark, in millions.
// The UI thread's is the steadier: about 1% from run to run, where the
// whole process's also holds however far the workers got by the mark.
COUNTERS := [?]string{"ui_instructions", "instructions"}

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
		for field in COUNTERS {
			values := make([dynamic]f64, context.temp_allocator)
			for run in runs[1:] {
				if l, ok := find_mark(run, mark); ok && line_field(l, field) > 0 {
					append(&values, line_field(l, field))
				}
			}
			if len(values) > 0 {
				append(&r.metrics, Metric{"startup", setup, mark, field, "M", stats(values[:]).median / 1e6})
			}
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

// significant says whether a change between two medians is more than runs
// vary: 10% and at least 1 ms or MB for times and sizes, 2% for
// instruction counts. Counts without a unit are never marked.
significant :: proc(unit: string, a, diff: f64) -> bool {
	if a == 0 {
		return false
	}
	pct := math.abs(diff / a) * 100
	switch unit {
	case "M":
		return pct >= 2
	case "ms", "MB":
		return pct >= 10 && math.abs(diff) >= 1
	}
	return false
}

// write_compare prints each pair with its change. Lower is better for every
// unit, so a significant change is marked worse or better, if marks is set.
write_compare :: proc(sb: ^strings.Builder, deltas: []Delta, marks := true) {
	fmt.sbprintfln(sb, "%-8s %-5s %-13s %-18s %10s %10s %10s %8s", "scenario", "setup", "row", "field", "a", "b", "delta", "change")
	for d in deltas {
		diff := d.b - d.value
		change := "-"
		flag := ""
		if d.value != 0 {
			change = fmt.tprintf("%+.1f%%", diff / math.abs(d.value) * 100)
			if marks && significant(d.unit, d.value, diff) {
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

// Paired is one startup number from an A/B run, where the two builds took
// turns: the medians of each, the median and middle half (25th to 75th
// percentile) of the differences between runs next to each other, and in
// how many pairs b was higher and lower.
Paired :: struct {
	setup, row, field, unit: string,
	a, b:                    f64,
	diff, low, high:         f64,
	count:                   int,
	higher, lower:           int,
}

// PAIRED_FIELDS are what paired_startup compares at each mark, with the
// unit and scale they're reported in.
PAIRED_FIELDS := [?]struct {
	name, unit: string,
	scale:      f64,
} {
	{"ms", "ms", 1},
	{"ui_instructions", "M", 1e6},
	{"instructions", "M", 1e6},
}

// paired_startup pairs run i of a with run i of b, leaving out run 1 of
// each, which pays for checks on a new binary, and runs that didn't reach
// a mark.
paired_startup :: proc(setup: string, a, b: [][]Line, allocator := context.allocator) -> []Paired {
	out := make([dynamic]Paired, allocator)
	for mark in MARKS {
		for f in PAIRED_FIELDS {
			as := make([dynamic]f64, context.temp_allocator)
			bs := make([dynamic]f64, context.temp_allocator)
			diffs := make([dynamic]f64, context.temp_allocator)
			for i in 1 ..< min(len(a), len(b)) {
				la, oka := find_mark(a[i], mark)
				lb, okb := find_mark(b[i], mark)
				if !oka || !okb {
					continue
				}
				va, vb := paired_value(la, f.name) / f.scale, paired_value(lb, f.name) / f.scale
				if f.name != "ms" && (va == 0 || vb == 0) {
					continue
				}
				append(&as, va)
				append(&bs, vb)
				append(&diffs, vb - va)
			}
			if len(diffs) == 0 {
				continue
			}
			higher, lower := 0, 0
			for d in diffs {
				higher += int(d > 0)
				lower += int(d < 0)
			}
			slice.sort(diffs[:])
			append(&out, Paired{
				setup = setup, row = mark, field = f.name, unit = f.unit,
				a = stats(as[:]).median, b = stats(bs[:]).median,
				diff = stats(diffs[:]).median, low = quantile(diffs[:], 0.25), high = quantile(diffs[:], 0.75),
				count = len(diffs), higher = higher, lower = lower,
			})
		}
	}
	return out[:]
}

@(private = "file")
paired_value :: proc(l: ^Line, name: string) -> f64 {
	return l.ms if name == "ms" else line_field(l, name)
}

// quantile reads sorted at q (0 to 1), between its two nearest values.
quantile :: proc(sorted: []f64, q: f64) -> f64 {
	if len(sorted) == 0 {
		return 0
	}
	at := q * f64(len(sorted) - 1)
	lo := int(at)
	hi := min(lo + 1, len(sorted) - 1)
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (at - f64(lo))
}

// sign_test is the two-sided p-value of a sign test: the chance that pairs
// with no real difference split at least this unevenly between higher and
// lower. Ties don't count.
sign_test :: proc(higher, lower: int) -> f64 {
	n := higher + lower
	if n == 0 {
		return 1
	}
	tail := 0.0
	choose := 1.0 // n choose i
	for i in 0 ..= min(higher, lower) {
		tail += choose
		choose = choose * f64(n - i) / f64(i + 1)
	}
	return min(1, 2 * tail / math.pow(2, f64(n)))
}

// paired_verdict marks a change worse or better when the sign test says
// the pairs lean one way (p < 0.05; with 9 pairs, 8 of them) and the median
// difference is at least 1% (and 1 ms for times), else "". A rule that only
// needed most pairs to agree marked builds with the same startup code apart.
paired_verdict :: proc(p: Paired) -> string {
	if p.a == 0 || sign_test(p.higher, p.lower) >= 0.05 {
		return ""
	}
	if math.abs(p.diff / p.a) < 0.01 || (p.unit == "ms" && math.abs(p.diff) < 1) {
		return ""
	}
	if (p.diff > 0) != (p.higher > p.lower) {
		return ""
	}
	return "worse" if p.diff > 0 else "better"
}

write_paired :: proc(sb: ^strings.Builder, rows: []Paired) {
	fmt.sbprintfln(sb, "%-5s %-12s %-16s %10s %10s %10s %8s  %-19s %-12s %5s", "setup", "mark", "field", "a", "b", "delta", "change", "middle half", "b higher", "p")
	for p in rows {
		change := fmt.tprintf("%+.1f%%", p.diff / p.a * 100) if p.a != 0 else "-"
		half := fmt.tprintf("%+.1f to %+.1f", p.low, p.high)
		higher := fmt.tprintf("%d of %d", p.higher, p.count)
		line := fmt.tprintf("%-5s %-12s %-16s %10s %10s %10s %8s  %-19s %-12s %5s %s %s", p.setup, p.row, p.field,
			fmt.tprintf("%.1f", p.a), fmt.tprintf("%.1f", p.b), fmt.tprintf("%+.1f", p.diff), change, half, higher,
			fmt.tprintf("%.2f", sign_test(p.higher, p.lower)), p.unit, paired_verdict(p))
		fmt.sbprintln(sb, strings.trim_right_space(line))
	}
}
