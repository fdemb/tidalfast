package tidal_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem/virtual"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/sys"
import measure "../tools/measure"

@(test)
test_measure_parse_line :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	l, ok := measure.parse_line(`measure: {"mark":"tracks","ms":557.2,"footprint":127205376,"gpu":49283072,"covers":12}`)
	testing.expect(t, ok)
	testing.expect_value(t, l.mark, "tracks")
	testing.expect_value(t, l.ms, 557.2)
	testing.expect_value(t, l.footprint, 127205376)
	testing.expect_value(t, l.covers, 12)

	// A shell mark has only a time.
	l, ok = measure.parse_line(`measure: {"mark":"main","ms":5.7}`)
	testing.expect(t, ok)
	testing.expect_value(t, l.footprint, 0)

	_, ok = measure.parse_line("render: 12 draw calls, 900 instances")
	testing.expect(t, !ok)
	_, ok = measure.parse_line(`measure: {"mark":`)
	testing.expect(t, !ok)

	log := "app: started\nmeasure: {\"mark\":\"init\",\"ms\":250}\nrender: 1 draw calls\nmeasure: {\"sample\":\"playing\",\"ms\":60000,\"resident\":1048576}\n"
	lines := measure.parse_log(log)
	testing.expect_value(t, len(lines), 2)
	s, found := measure.find_sample(lines, "playing")
	testing.expect(t, found)
	testing.expect_value(t, s.resident, 1048576)
}

@(test)
test_measure_stats :: proc(t: ^testing.T) {
	st := measure.stats({5, 1, 3})
	testing.expect_value(t, st, measure.Stats{3, 1, 5, 3})
	st = measure.stats({4, 1, 3, 2})
	testing.expect_value(t, st.median, 2.5)
	testing.expect_value(t, measure.stats(nil).count, 0)
}

@(test)
test_measure_startup_runs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	run :: proc(tracks: string) -> []measure.Line {
		return measure.parse_log(strings.concatenate({`measure: {"mark":"main","ms":5}` + "\n" + `measure: {"mark":"tracks","ms":`, tracks, `,"footprint":104857600}`}))
	}
	// Run 1 goes on its own; the third run never got to tracks.
	runs := [][]measure.Line{run("900"), run("300"), measure.parse_log(`measure: {"mark":"main","ms":6}`), run("320"), run("310")}
	r: measure.Results
	measure.add_startup(&r, "fake", runs)
	m := r.metrics[:]
	v, ok := measure.find_metric(m, "startup", "fake", "tracks", "first")
	testing.expect(t, ok)
	testing.expect_value(t, v, 900)
	v, _ = measure.find_metric(m, "startup", "fake", "tracks", "median")
	testing.expect_value(t, v, 310)
	v, _ = measure.find_metric(m, "startup", "fake", "tracks", "max")
	testing.expect_value(t, v, 320)
	v, _ = measure.find_metric(m, "startup", "fake", "main", "median")
	testing.expect_value(t, v, 5)
	v, _ = measure.find_metric(m, "startup", "fake", "memory", "footprint")
	testing.expect_value(t, v, 100)
	_, ok = measure.find_metric(m, "startup", "fake", "library", "first")
	testing.expect(t, !ok)
}

@(test)
test_measure_compare :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := measure.Results{version = 1, machine = {model = "MacBookAir10,1"}}
	append(&a.metrics, measure.Metric{"startup", "fake", "tracks", "median", "ms", 300})
	append(&a.metrics, measure.Metric{"memory", "mock", "scrolled", "footprint", "MB", 150})
	append(&a.metrics, measure.Metric{"memory", "mock", "scrolled", "covers", "", 500})
	append(&a.metrics, measure.Metric{"memory", "fake", "playing", "gpu", "MB", 40})

	// Through the file format and back.
	data, ok := measure.save_results(&a)
	testing.expect(t, ok)
	b, loaded := measure.load_results(data)
	testing.expect(t, loaded)
	testing.expect_value(t, len(b.metrics), 4)
	testing.expect_value(t, b.machine.model, "MacBookAir10,1")

	b.metrics[0].value = 360
	b.metrics[1].value = 130
	b.metrics[2].value = 700
	ordered_remove(&b.metrics, 3)
	deltas := measure.compare(a.metrics[:], b.metrics[:])
	testing.expect_value(t, len(deltas), 3)
	testing.expect_value(t, deltas[0].b, 360)

	sb := strings.builder_make()
	measure.write_compare(&sb, deltas)
	out := strings.to_string(sb)
	lines := strings.split_lines(strings.trim_space(out))
	testing.expect_value(t, len(lines), 4)
	testing.expect(t, strings.has_suffix(lines[1], "worse"), lines[1])
	testing.expect(t, strings.has_suffix(lines[2], "better"), lines[2])
	// A count changing isn't better or worse.
	testing.expect(t, !strings.has_suffix(lines[3], "worse"), lines[3])
}

// The frames scenario: a line per bench phase, the medians over the runs,
// and more fps is better where less of everything else is.
@(test)
test_measure_frames :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	run :: proc(fps, gpu: string) -> []measure.Line {
		return measure.parse_log(strings.concatenate({`measure: {"frames":"warm","count":240,"fps":`, fps, `,"interval_p95":9.1,"cpu_median":1.5,"cpu_p95":2.2,"gpu_median":`, gpu, `,"gpu_p95":6.0,"slot_wait_p95":0.1,"drawable_wait_p95":0.2}`}))
	}
	runs := [][]measure.Line{run("118", "4.0"), run("120", "5.0"), run("90", "4.5")}
	l, ok := measure.find_frames(runs[0], "warm")
	testing.expect(t, ok)
	testing.expect_value(t, l.count, 240)
	a: measure.Results
	measure.add_frames(&a, "fake", runs)
	fps, _ := measure.find_metric(a.metrics[:], "frames", "fake", "warm", "fps")
	testing.expect_value(t, fps, 118)
	gpu, _ := measure.find_metric(a.metrics[:], "frames", "fake", "warm", "gpu_median")
	testing.expect_value(t, gpu, 4.5)
	wait, _ := measure.find_metric(a.metrics[:], "frames", "fake", "warm", "drawable_wait_p95")
	testing.expect_value(t, wait, 0.2)
	_, has_cold := measure.find_metric(a.metrics[:], "frames", "fake", "cold", "fps")
	testing.expect(t, !has_cold)

	b: measure.Results
	measure.add_frames(&b, "fake", {run("100", "7.0")})
	sb := strings.builder_make()
	measure.write_compare(&sb, measure.compare(a.metrics[:], b.metrics[:]))
	// Fewer fps and more GPU time are both worse.
	marked := 0
	for line in strings.split_lines(strings.to_string(sb)) {
		cols := strings.fields(line)
		if len(cols) > 3 && (cols[3] == "fps" || cols[3] == "gpu_median") {
			testing.expect(t, strings.has_suffix(line, "worse"), line)
			marked += 1
		}
	}
	testing.expect_value(t, marked, 2)
}

@(test)
test_measure_counters :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	run :: proc(ui: string) -> []measure.Line {
		return measure.parse_log(strings.concatenate({`measure: {"mark":"tracks","ms":300,"ui_instructions":`, ui, `,"instructions":2000000000}`}))
	}
	r: measure.Results
	measure.add_startup(&r, "fake", {run("900000000"), run("800000000"), run("820000000"), run("810000000")})
	v, ok := measure.find_metric(r.metrics[:], "startup", "fake", "tracks", "ui_instructions")
	testing.expect(t, ok)
	testing.expect_value(t, v, 810) // millions, run 1 left out
	v, _ = measure.find_metric(r.metrics[:], "startup", "fake", "tracks", "instructions")
	testing.expect_value(t, v, 2000)

	// Counts are marked from 2%, times and sizes from 10% and 1 ms or MB.
	testing.expect(t, measure.significant("M", 800, 16))
	testing.expect(t, !measure.significant("M", 800, 15))
	testing.expect(t, !measure.significant("ms", 300, 29))
	testing.expect(t, measure.significant("ms", 300, -30))
	testing.expect(t, !measure.significant("ms", 5, 0.9))
	testing.expect(t, !measure.significant("", 500, 400))
}

@(test)
test_measure_paired :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runs :: proc(ms: ..string) -> [][]measure.Line {
		out := make([dynamic][]measure.Line)
		for m in ms {
			append(&out, measure.parse_log(strings.concatenate({`measure: {"mark":"tracks","ms":`, m, `,"ui_instructions":800000000}`})))
		}
		return out[:]
	}
	sorted := []f64{1, 2, 3, 4, 5}
	testing.expect_value(t, measure.quantile(sorted, 0.25), 2)
	testing.expect_value(t, measure.quantile(sorted, 0.5), 3)
	testing.expect_value(t, measure.quantile([]f64{1, 2}, 0.5), 1.5)

	testing.expect_value(t, measure.sign_test(9, 0), 2.0 / 512)
	testing.expect_value(t, measure.sign_test(8, 1), 20.0 / 512)
	testing.expect_value(t, measure.sign_test(2, 7), 92.0 / 512)
	testing.expect_value(t, measure.sign_test(0, 0), 1)

	// b is 10 ms slower in every pair: worse. Run 1 of each is left out.
	a := runs("900", "200", "210", "190", "205", "200", "195")
	b := runs("100", "210", "220", "200", "215", "210", "205")
	rows := measure.paired_startup("fake", a, b)
	p: measure.Paired
	found := false
	for r in rows {
		if r.row == "tracks" && r.field == "ms" {
			p, found = r, true
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, p.count, 6)
	testing.expect_value(t, p.higher, 6)
	testing.expect_value(t, p.a, 200)
	testing.expect_value(t, p.b, 210)
	testing.expect_value(t, p.diff, 10)
	testing.expect_value(t, measure.paired_verdict(p), "worse")
	// The same counts on both sides: no change.
	for r in rows {
		if r.field == "ui_instructions" {
			testing.expect_value(t, r.diff, 0)
			testing.expect_value(t, measure.paired_verdict(r), "")
		}
	}

	// Lower in 7 of 9 pairs, as an A/B of two builds with the same startup
	// code was on 17 October: the middle half of the differences was below
	// zero, but a split that even happens by chance 18% of the time.
	a = runs("747.2", "217.9", "247.2", "215.0", "205.0", "206.9", "206.8", "200.9", "205.7", "228.6")
	b = runs("441.2", "215.1", "209.8", "207.4", "199.7", "209.7", "196.4", "195.7", "209.3", "208.7")
	for r in measure.paired_startup("fake", a, b) {
		if r.row == "tracks" && r.field == "ms" {
			testing.expect_value(t, r.lower, 7)
			testing.expect(t, r.high < 0)
			testing.expect_value(t, measure.paired_verdict(r), "")
		}
	}
}

@(test)
test_measure_launches :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	log := `{"time":100,"commit":"aaaaaaaaaa","build":"release","first_frame":500,"tracks":700,"ui_instructions":900000000,"footprint":104857600}
{"time":200,"commit":"aaaaaaaaaa","build":"release","first_frame":520,"tracks":900,"ui_instructions":910000000,"footprint":104857600}
not json
{"time":300,"commit":"bbbbbbbbbb-dirty","build":"debug","first_frame":800,"tracks":1100,"ui_instructions":1500000000,"footprint":209715200}
{"time":400,"commit":"aaaaaaaaaa","build":"release","first_frame":510,"tracks":800,"ui_instructions":905000000,"footprint":104857600}
`
	groups := measure.group_launches(log)
	testing.expect_value(t, len(groups), 2)
	testing.expect_value(t, groups[0].commit, "aaaaaaaaaa")
	testing.expect_value(t, len(groups[0].launches), 3)
	testing.expect_value(t, groups[0].first, 100)
	testing.expect_value(t, groups[0].last, 400)
	testing.expect_value(t, groups[1].build, "debug")
	values := []f64{700, 900, 800}
	m, lo, hi := measure.spread(values)
	testing.expect_value(t, m, 800)
	testing.expect_value(t, lo, 750)
	testing.expect_value(t, hi, 850)

	sb := strings.builder_make()
	measure.write_launches(&sb, groups)
	out := strings.to_string(sb)
	testing.expect(t, strings.contains(out, "aaaaaaa        release        3  800 (750 to 850)"), out)
	testing.expect(t, strings.contains(out, "bbbbbbb-dirty"), out)
}

@(test)
test_launch_log_append :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/tidalfast-launches-%d", temp_base(), time.now()._nsec)
	path := fmt.tprintf("%s/nested/launches.jsonl", dir)
	defer os.remove_all(dir)

	testing.expect(t, app.launch_log_append(path, transmute([]u8)string("{\"n\":1}\n")))
	testing.expect(t, app.launch_log_append(path, transmute([]u8)string("{\"n\":2}\n")))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "{\"n\":1}\n{\"n\":2}\n")

	// Past the limit the file keeps its newer half, from a line's start.
	line := strings.concatenate({"{\"pad\":\"", strings.repeat("x", 990, context.temp_allocator), "\"}\n"}, context.temp_allocator)
	big := strings.builder_make(context.temp_allocator)
	for i in 0 ..< app.LAUNCH_LOG_LIMIT / len(line) + 2 {
		fmt.sbprintf(&big, "{{\"i\":%04d,%s", i, line[1:])
	}
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(big))
	testing.expect(t, app.launch_log_append(path, transmute([]u8)string("{\"n\":3}\n")))
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, len(data) <= strings.builder_len(big) / 2 + 8, fmt.tprint(len(data)))
	testing.expect(t, strings.has_prefix(string(data), "{\"i\":"))
	testing.expect(t, strings.has_suffix(string(data), "{\"n\":3}\n"))
	last := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	testing.expect_value(t, last[len(last) - 2][:10], fmt.tprintf("{{\"i\":%04d,", app.LAUNCH_LOG_LIMIT / len(line) + 1))
}

// What's left of each pool goes in as an item, and a pool the app's items
// already fill gets none.
@(test)
test_breakdown_settle :: proc(t: ^testing.T) {
	b: app.Breakdown
	app.breakdown_add(&b, .Api, .Anon, "open list", 3)
	app.breakdown_add(&b, .Ui, .Malloc, "font tables", 6)
	app.breakdown_add(&b, .Gpu, .Gpu, "glyph atlas", 5)
	om := app.Os_Memory{footprint = 40}
	om.pools = {.Anon = 4, .Malloc = 20, .Gpu = 4, .Surfaces = 9, .Other = 3}
	om.other = {{"thread stacks", 1}, {"binaries' data", 2}, {}, {}}
	app.breakdown_settle(&b, om)
	rest :: proc(b: ^app.Breakdown, name: string) -> (app.Mem_Item, bool) {
		for item in b.items[:b.count] {
			if item.name == name {
				return item, true
			}
		}
		return {}, false
	}
	item, ok := rest(&b, "other anonymous memory")
	testing.expect(t, ok)
	testing.expect_value(t, item.bytes, 1)
	testing.expect_value(t, item.group, app.Mem_Group.System)
	item, _ = rest(&b, "malloc outside the app's buffers")
	testing.expect_value(t, item.bytes, 14)
	item, _ = rest(&b, "drawables and window surfaces")
	testing.expect_value(t, item.bytes, 9)
	testing.expect_value(t, item.group, app.Mem_Group.Gpu)
	_, ok = rest(&b, "other GPU memory (driver, pipelines)")
	testing.expect(t, !ok)
	item, _ = rest(&b, "binaries' data")
	testing.expect_value(t, item.pool, app.Mem_Pool.Other)
	total := 0
	for item in b.items[:b.count] {
		total += item.bytes
	}
	// One over the footprint: the glyph atlas came out bigger than its pool.
	testing.expect_value(t, total, 41)
}

// pages_counted counts the pages written, and only pages whose first byte
// is in the range.
@(test)
test_pages_counted :: proc(t: ^testing.T) {
	page := sys.page_size()
	n := 8 * page
	mem, merr := virtual.reserve_and_commit(uint(n))
	testing.expect(t, merr == nil)
	defer virtual.release(raw_data(mem), uint(n))
	p := rawptr(raw_data(mem))
	bytes := ([^]u8)(p)
	testing.expect_value(t, app.pages_counted(p, n), 0)
	for i in 0 ..< 3 {
		bytes[i * page] = 1
	}
	testing.expect_value(t, app.pages_counted(p, n), 3 * page)
	// From the middle of page 0: pages 1 and 2 start in the range.
	testing.expect_value(t, app.pages_counted(&bytes[page / 2], n - page / 2), 2 * page)
	testing.expect_value(t, app.pages_counted(&bytes[1], page - 1), 0)
	testing.expect_value(t, app.pages_counted(nil, n), 0)
}

// The memory scenario waits for the longest list to load. On an account
// whose Liked Songs is the longest that list is .Liked, not .Playlist, and
// the scenario waited for it forever.
@(test)
test_measure_list_loaded :: proc(t: ^testing.T) {
	d := new(app.Data)
	defer free(d)
	d.view.source = .Liked
	d.view.load = app.List_Ended{}
	testing.expect(t, app.measure_list_loaded(d, 0))
	testing.expect(t, !app.measure_list_loaded(d, 3))
	d.view.source = .Playlist
	testing.expect(t, app.measure_list_loaded(d, 3))
	testing.expect(t, !app.measure_list_loaded(d, 0))
	d.view.load = app.List_Paging{}
	testing.expect(t, !app.measure_list_loaded(d, 3))
	d.fake = true
	testing.expect(t, app.measure_list_loaded(d, 0))
}

// measure html reads every snapshot in the folder, oldest first, and leaves
// out files that aren't snapshots.
@(test)
test_measure_snapshots_page :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fmt.tprintf("%s/tidalfast-snapshots-%d", temp_base(), time.now()._nsec)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	write :: proc(dir, name, list: string) {
		_ = os.write_entire_file(fmt.tprintf("%s/%s.json", dir, name), transmute([]u8)strings.concatenate({
			`{"snapshot":"`, name, `","time":1793441700,"commit":"0123456789abcdef-dirty","build":"release","uptime_s":3725.1,`,
			`"window":"1100x700@2","footprint_peak":314572800,"gpu":73400320,"kept_lists":3,"footprint":209715200,"items":[`,
			`{"group":"api","pool":"anon","name":"open list","bytes":`, list, `}]}`,
		}))
	}
	write(dir, "20261031-121500", "3145728")
	write(dir, "20261031-101500", "1048576")
	_ = os.write_entire_file(fmt.tprintf("%s/settings.json", dir), transmute([]u8)string(`{"volume":1}`))

	snaps := measure.load_snapshots(dir)
	testing.expect_value(t, len(snaps), 2)
	testing.expect_value(t, snaps[0].snapshot, "20261031-101500")
	testing.expect_value(t, snaps[1].items[0].bytes, 3 << 20)
	testing.expect_value(t, snaps[0].uptime_s, 3725.1)

	page := measure.snapshots_page(snaps, "MacBookAir10,1", dir)
	testing.expect(t, !strings.contains(page, "/*DATA*/"))
	testing.expect(t, strings.contains(page, `"name":"20261031-121500","build":"release 0123456-dirty","uptime":"1h 02m","window":"1100x700@2","footprint":200.0,"peak":300.0`), page[:300])
	testing.expect(t, strings.contains(page, `{"group":"api","name":"open list","mb":3.00}`))
	testing.expect_value(t, len(measure.load_snapshots(fmt.tprintf("%s/none", dir))), 0)
}
