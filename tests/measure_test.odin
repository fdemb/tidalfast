package tidal_tests

import "core:strings"
import "core:testing"

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
