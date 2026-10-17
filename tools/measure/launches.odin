package measure

// `measure launches` sums up the app's launch log (src/app/launch_log.odin):
// the launches someone actually had, per build, in the order the builds
// first showed up.

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// Launch is one line of the launch log.
Launch :: struct {
	time:            i64,
	commit:          string,
	build:           string,
	init:            f64,
	first_frame:     f64,
	library:         f64,
	tracks:          f64,
	ui_instructions: f64,
	instructions:    f64,
	footprint:       f64,
}

// Launch_Group is the launches of one build: commit and debug or release.
Launch_Group :: struct {
	commit, build: string,
	first, last:   i64, // unix seconds
	launches:      [dynamic]Launch,
}

// group_launches reads the log's lines, skipping any that don't parse.
group_launches :: proc(log: string, allocator := context.allocator) -> []Launch_Group {
	groups := make([dynamic]Launch_Group, allocator)
	rest := log
	for text in strings.split_lines_iterator(&rest) {
		l: Launch
		if strings.trim_space(text) == "" || json.unmarshal_string(text, &l, allocator = allocator) != nil {
			continue
		}
		g: ^Launch_Group
		for &x in groups {
			if x.commit == l.commit && x.build == l.build {
				g = &x
			}
		}
		if g == nil {
			append(&groups, Launch_Group{commit = l.commit, build = l.build, first = l.time, launches = make([dynamic]Launch, allocator)})
			g = &groups[len(groups) - 1]
		}
		g.last = l.time
		append(&g.launches, l)
	}
	return groups[:]
}

// spread is the median and middle half of values, in that order.
spread :: proc(values: []f64) -> (median, low, high: f64) {
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	return quantile(sorted, 0.5), quantile(sorted, 0.25), quantile(sorted, 0.75)
}

write_launches :: proc(sb: ^strings.Builder, groups: []Launch_Group) {
	fmt.sbprintfln(sb, "%-14s %-7s %8s  %-22s %-22s %-20s %s", "commit", "build", "launches", "tracks ms", "first frame ms", "UI thread M instr", "footprint MB")
	for &g in groups {
		field :: proc(g: ^Launch_Group, get: proc(l: Launch) -> f64) -> string {
			values := make([dynamic]f64, context.temp_allocator)
			for l in g.launches {
				append(&values, get(l))
			}
			m, lo, hi := spread(values[:])
			return fmt.tprintf("%.0f (%.0f to %.0f)", m, lo, hi)
		}
		commit := g.commit[:min(len(g.commit), 7)]
		if strings.has_suffix(g.commit, "-dirty") {
			commit = fmt.tprintf("%s-dirty", commit)
		}
		fmt.sbprintfln(sb, "%-14s %-7s %8s  %-22s %-22s %-20s %s", commit, g.build, fmt.tprint(len(g.launches)),
			field(&g, proc(l: Launch) -> f64 {return l.tracks}),
			field(&g, proc(l: Launch) -> f64 {return l.first_frame}),
			field(&g, proc(l: Launch) -> f64 {return l.ui_instructions / 1e6}),
			field(&g, proc(l: Launch) -> f64 {return l.footprint / MB}))
	}
	fmt.sbprintln(sb, "\nmedian (middle half) of each build's launches")
}
