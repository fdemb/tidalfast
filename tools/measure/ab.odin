package measure

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"

// run_ab measures base (a), a git ref built with ./build.sh measure in a
// worktree of its own, against this checkout's measure build (b). The two
// take turns, a then b, then b then a, so a machine that gets busier or
// hotter over the run weighs on both alike. Startup is judged on the
// differences between runs next to each other (paired_startup); the memory
// scenario runs once each and is compared as `measure compare` does, and
// with the fake data the frames scenario runs three times each, taking
// turns, compared by its medians. Each build gets a mock of its own, both
// this checkout's.
run_ab :: proc(cfg: ^Config, base, stamp: string) -> int {
	for setup in cfg.setups {
		if setup != "fake" && setup != "mock" {
			fmt.eprintfln("measure: ab runs fake and mock, not %s", setup)
			return 1
		}
	}
	worktree := join(cfg.out_dir, fmt.tprintf("ab-%s", stamp))
	build_log := join(cfg.log_dir, "build-a.log")
	fmt.printfln("building %s in %s, log in %s", base, worktree, build_log)
	if !run_command({"git", "-C", cfg.root, "worktree", "add", "--detach", worktree, base}, build_log) {
		fmt.eprintfln("measure: can't check out %s, see %s", base, build_log)
		return 1
	}
	defer run_command({"git", "-C", cfg.root, "worktree", "remove", "--force", worktree}, build_log)
	if !run_command({"sh", join(worktree, "build.sh"), "measure"}, build_log) {
		fmt.eprintfln("measure: building %s failed, see %s", base, build_log)
		return 1
	}

	sides := [2]Side {
		{name = "a", app = join(worktree, "build", "measure", "app", "tidalfast"), log_dir = join(cfg.log_dir, "a")},
		{name = "b", app = cfg.app, log_dir = join(cfg.log_dir, "b")},
	}
	results: [2]Results
	for &side, k in sides {
		os.make_directory_all(side.log_dir)
		results[k] = {version = 1, time = stamp, machine = machine(), app = side.app}
	}
	fmt.printfln("a: %s, b: this checkout\n", base)

	has_mock := slice.contains(cfg.setups, "mock")
	if has_mock {
		if !os.exists(cfg.mock) {
			fmt.eprintfln("measure: no mock at %s; run ./build.sh measure", cfg.mock)
			return 1
		}
		for &side, k in sides {
			if !start_side_mock(cfg, &side) {
				if k == 1 {
					stop_side_mock(&sides[0])
				}
				return 1
			}
		}
	}

	paired := make([dynamic]Paired)
	for setup in cfg.setups {
		n := startup_runs(cfg)
		runs: [2][dynamic][]Line
		for i in 0 ..< n {
			for k in turns(i) {
				append(&runs[k], run_once(cfg, &sides[k], setup, "startup", i, n))
			}
		}
		for k in 0 ..< 2 {
			add_startup(&results[k], setup, runs[k][:])
		}
		append(&paired, ..paired_startup(setup, runs[0][:], runs[1][:]))
		for k in turns(n) {
			lines := run_once(cfg, &sides[k], setup, "memory", 0, 1)
			add_memory(&results[k], setup, {lines})
		}
		if setup == "fake" {
			nf := frames_runs(cfg)
			frames: [2][dynamic][]Line
			for i in 0 ..< nf {
				for k in turns(i) {
					append(&frames[k], run_once(cfg, &sides[k], setup, "frames", i, nf))
				}
			}
			for k in 0 ..< 2 {
				add_frames(&results[k], setup, frames[k][:])
			}
		}
	}

	if has_mock {
		for &side in sides {
			stop_side_mock(&side)
		}
	}

	b := strings.builder_make()
	fmt.sbprintln(&b, "\nstartup, b against a: medians of each, then of the differences between runs next to each other")
	write_paired(&b, paired[:])
	// Builds of the same code came out 12 MB apart on one memory run each, so
	// one run doesn't get marked.
	fmt.sbprintln(&b, "\nmemory, one run each, not marked: compare `measure memory -runs=N` of each build for that")
	write_compare(&b, compare(scenario_metrics(results[0].metrics[:], "memory"), results[1].metrics[:]), marks = false)
	if frames := scenario_metrics(results[0].metrics[:], "frames"); len(frames) > 0 {
		fmt.sbprintln(&b, "\nframes, the fake data's library bench, medians over the runs; more fps is better")
		write_compare(&b, compare(frames, results[1].metrics[:]))
	}
	fmt.print(strings.to_string(b))
	stem := strings.trim_suffix(cfg.out, ".json")
	for k in 0 ..< 2 {
		path := fmt.tprintf("%s-%s.json", stem, sides[k].name)
		if data, ok := save_results(&results[k]); ok && os.write_entire_file(path, data) == nil {
			fmt.printfln("%s in %s", sides[k].name, path)
		}
	}
	if cfg.failed > 0 {
		fmt.eprintfln("measure: %d runs failed, see the logs", cfg.failed)
		return 1
	}
	return 0
}

// turns is the order the two builds go in for round i.
turns :: proc(i: int) -> [2]int {
	return {0, 1} if i % 2 == 0 else {1, 0}
}

@(private = "file")
scenario_metrics :: proc(metrics: []Metric, scenario: string) -> []Metric {
	out := make([dynamic]Metric, context.temp_allocator)
	for m in metrics {
		if m.scenario == scenario {
			append(&out, m)
		}
	}
	return out[:]
}

new_keychain_name :: proc() -> string {
	return fmt.aprintf("tidalfast-measure-%08x", rand.uint32())
}

// run_command runs command with its output added to log_path and says
// whether it exited with 0.
run_command :: proc(command: []string, log_path: string) -> bool {
	f, err := os.open(log_path, {.Write, .Create, .Append})
	if err != nil {
		return false
	}
	defer os.close(f)
	p, perr := os.process_start({command = command, stdout = f, stderr = f})
	if perr != nil {
		return false
	}
	state, werr := os.process_wait(p)
	return werr == nil && state.exited && state.exit_code == 0
}
