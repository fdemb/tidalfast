// Launches the app again and again with TIDALFAST_MEASURE set, reads its
// `measure:` lines and prints what it found. See "Measuring RAM and
// startup" in docs/measuring.md.
//
//     ./build.py measure
//     ./build/measure/measure startup            fake and mock, 10 runs each
//     ./build/measure/measure memory             fake and mock, 1 run each
//     ./build/measure/measure all
//     ./build/measure/measure frames             fake, 3 runs
//     ./build/measure/measure compare a.json b.json
//     ./build/measure/measure ab <app a> <app b>          two builds, taking turns
//     ./build/measure/measure ab <app a> <app b> -memory  the same, with a memory run of each
//     ./build/measure/measure launches           the app's own log of real launches
//     ./build/measure/measure html               the app's memory snapshots as a page
//
// Flags: -runs=N, -setup=fake,mock, -app=path, -timeout=seconds, -out=path,
// and -real, which runs against your own account and Keychain item with
// build/tidalfast instead of the fake data and the mock.
package measure

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

Config :: struct {
	root:     string, // the checkout
	out_dir:  string, // build/measure
	app:      string,
	mock:     string,
	setups:   []string,
	runs:     int, // 0: the scenario's default
	timeout:  time.Duration, // 0: the scenario's default
	out:      string,
	real:     bool,
	memory:   bool, // ab: run the memory scenario too
	log_dir:  string,
	failed:   int,
}

// Side is one build being measured: its app, and its own logs, settings,
// list cache, mock and Keychain item, so two builds never share state. A
// shared mock would revoke one build's login whenever the other refreshed
// its own, since the mock keeps one refresh token per user.
Side :: struct {
	name:     string, // "" outside ab, else "a" or "b"
	app:      string,
	log_dir:  string,
	keychain: string,
	mock:     os.Process,
	mock_url: string,
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
	}
	if args[0] == "compare" {
		if len(args) != 3 {
			usage()
		}
		os.exit(compare_files(args[1], args[2]))
	}
	if args[0] == "html" {
		if len(args) > 3 {
			usage()
		}
		exe_dir, _ := os.get_executable_directory(context.allocator)
		dir := args[1] if len(args) > 1 else snapshot_dir_default()
		page := args[2] if len(args) > 2 else join(exe_dir, "snapshots.html")
		os.exit(snapshots_html(dir, page))
	}
	if args[0] == "launches" {
		if len(args) > 2 {
			usage()
		}
		os.exit(show_launches(args[1] if len(args) == 2 else launch_log_default()))
	}
	scenario := args[0]
	ab := scenario == "ab"
	ab_apps: [2]string
	if ab {
		if len(args) < 3 || strings.has_prefix(args[1], "-") || strings.has_prefix(args[2], "-") {
			usage()
		}
		ab_apps = {args[1], args[2]}
		args = args[2:]
	} else if scenario != "startup" && scenario != "memory" && scenario != "all" && scenario != "frames" {
		usage()
	}

	exe_dir, _ := os.get_executable_directory(context.allocator)
	cfg := Config {
		out_dir = exe_dir,
		root    = clean(join(exe_dir, "..", "..")),
	}
	// The frames scenario scrolls the fake data only.
	setups_flag := "fake" if scenario == "frames" else "fake,mock"
	for arg in args[1:] {
		name, _, value := strings.partition(arg, "=")
		switch name {
		case "-runs":
			cfg.runs, _ = strconv.parse_int(value)
		case "-setup":
			setups_flag = value
		case "-app":
			if ab {
				usage()
			}
			cfg.app = value
		case "-timeout":
			secs, _ := strconv.parse_int(value)
			cfg.timeout = time.Duration(secs) * time.Second
		case "-out":
			cfg.out = value
		case "-real":
			cfg.real = true
		case "-memory":
			if !ab {
				usage()
			}
			cfg.memory = true
		case:
			usage()
		}
	}
	if cfg.real {
		if ab {
			usage()
		}
		setups_flag = "real"
	}
	cfg.setups = strings.split(setups_flag, ",")
	if cfg.app == "" {
		// The measure build reads TIDALFAST_API; a release build doesn't. The
		// real account's Keychain item belongs to build/tidalfast.
		cfg.app = join(cfg.root, "build", "tidalfast" + EXE_SUFFIX) if cfg.real else join(cfg.out_dir, "app", "tidalfast" + EXE_SUFFIX)
	}
	cfg.mock = join(cfg.out_dir, "mock_tidal" + EXE_SUFFIX)
	if !ab && !os.exists(cfg.app) {
		fmt.eprintfln("measure: no app at %s; run ./build.py measure (or ./build.py release for -real)", cfg.app)
		os.exit(1)
	}

	stamp := timestamp()
	if cfg.out == "" {
		cfg.out = join(cfg.out_dir, fmt.tprintf("%s.json", stamp))
	}
	cfg.log_dir = join(cfg.out_dir, fmt.tprintf("logs-%s", stamp))
	os.make_directory_all(cfg.log_dir)
	if ab {
		os.exit(run_ab(&cfg, ab_apps, stamp))
	}
	side := Side{app = cfg.app, log_dir = cfg.log_dir}

	results := Results {
		version = 1,
		time    = stamp,
		machine = machine(),
		app     = strings.trim_prefix(cfg.app, strings.concatenate({cfg.root, "/"})),
	}
	fmt.printfln("%s, %s, %s%s (%s), %.0f GB", results.machine.model, results.machine.cpu, OS_LABEL, results.machine.os, results.machine.os_build, results.machine.memory_gb)
	fmt.printfln("app %s, logs in %s\n", cfg.app, cfg.log_dir)

	has_mock := false
	for setup in cfg.setups {
		switch setup {
		case "fake", "real":
		case "mock":
			if !os.exists(cfg.mock) {
				fmt.eprintfln("measure: no mock at %s; run ./build.py measure", cfg.mock)
				os.exit(1)
			}
			if !start_side_mock(&cfg, &side) {
				os.exit(1)
			}
			has_mock = true
		case:
			fmt.eprintfln("measure: unknown setup %s", setup)
			os.exit(1)
		}
	}

	for setup in cfg.setups {
		if scenario == "startup" || scenario == "all" {
			runs := make([dynamic][]Line)
			for i in 0 ..< startup_runs(&cfg) {
				append(&runs, run_once(&cfg, &side, setup, "startup", i, startup_runs(&cfg)))
			}
			add_startup(&results, setup, runs[:])
		}
		if scenario == "memory" || scenario == "all" {
			n := cfg.runs if cfg.runs > 0 && scenario == "memory" else 1
			runs := make([dynamic][]Line)
			for i in 0 ..< n {
				append(&runs, run_once(&cfg, &side, setup, "memory", i, n))
			}
			add_memory(&results, setup, runs[:])
		}
		if scenario == "frames" {
			if setup != "fake" {
				fmt.printfln("frames runs with the fake data only, not %s", setup)
				continue
			}
			n := frames_runs(&cfg)
			runs := make([dynamic][]Line)
			for i in 0 ..< n {
				append(&runs, run_once(&cfg, &side, setup, "frames", i, n))
			}
			add_frames(&results, setup, runs[:])
		}
	}

	if has_mock {
		stop_side_mock(&side)
	}

	b := strings.builder_make()
	write_tables(&b, &results)
	fmt.print(strings.to_string(b))
	if data, ok := save_results(&results); ok {
		if os.write_entire_file(cfg.out, data) == nil {
			fmt.printfln("results in %s", cfg.out)
		}
	}
	if cfg.failed > 0 {
		fmt.eprintfln("measure: %d runs failed, see the logs", cfg.failed)
		os.exit(1)
	}
}

usage :: proc() {
	fmt.eprintln(`usage: measure startup|memory|all|frames [-runs=N] [-setup=fake,mock] [-app=path] [-timeout=s] [-out=path] [-real]
       measure ab <app a> <app b> [-runs=N] [-setup=fake,mock] [-timeout=s] [-out=path] [-memory]
       measure compare a.json b.json
       measure launches [launches.jsonl]
       measure html [snapshots folder] [page.html]`)
	os.exit(2)
}

startup_runs :: proc(cfg: ^Config) -> int {
	return cfg.runs if cfg.runs > 0 else 10
}

frames_runs :: proc(cfg: ^Config) -> int {
	return cfg.runs if cfg.runs > 0 else 3
}

// run_once launches side's app once, run i of n, and returns its lines. A
// run that times out or never gets to its last line still counts what it
// printed, and counts as failed.
run_once :: proc(cfg: ^Config, side: ^Side, setup, scenario: string, i, n: int) -> []Line {
	timeout := cfg.timeout
	if timeout == 0 {
		timeout = 60 * time.Second if scenario == "startup" else 240 * time.Second
	}
	label := fmt.tprintf("%s-%s", side.name, setup) if side.name != "" else setup
	fmt.printf("%s %s run %d/%d ", scenario, label, i + 1, n)
	log_path := join(side.log_dir, fmt.tprintf("%s-%s-%d.log", scenario, setup, i + 1))
	env := app_env(cfg, side, setup, scenario)
	log, finished := run_app(side.app, env, log_path, timeout)
	lines := parse_log(log)
	last := "tracks" if scenario == "startup" else "idle_after"
	reached: bool
	switch scenario {
	case "startup":
		_, reached = find_mark(lines, last)
	case "frames":
		last = FRAME_PHASES[len(FRAME_PHASES) - 1]
		_, reached = find_frames(lines, last)
	case:
		_, reached = find_sample(lines, last)
	}
	for &l in lines {
		if l.error != "" {
			fmt.printf("(%s) ", l.error)
		}
	}
	if !finished || !reached {
		cfg.failed += 1
		fmt.printfln("failed: %s, see %s", "timed out" if !finished else fmt.tprintf("no %s line", last), log_path)
	} else if l, ok := find_mark(lines, "tracks"); ok && scenario == "startup" {
		if l.ui_instructions > 0 {
			fmt.printfln("tracks at %.1f ms, UI thread %.0f M instructions", l.ms, l.ui_instructions / 1e6)
		} else {
			fmt.printfln("tracks at %.1f ms", l.ms)
		}
	} else {
		fmt.println("done")
	}
	return lines
}

// app_env is this process's environment without TIDALFAST_ and Metal
// variables someone left set, plus what the setup needs. Settings go to a
// file of their own that doesn't exist, so bit-perfect output is off and
// your settings stay as they are, and the list cache to a folder of its own.
app_env :: proc(cfg: ^Config, side: ^Side, setup, scenario: string) -> []string {
	env := make([dynamic]string)
	base, _ := os.environ(context.allocator)
	for kv in base {
		if !strings.has_prefix(kv, "TIDALFAST_") && !strings.has_prefix(kv, "MTL_") && !strings.has_prefix(kv, "METAL_") {
			append(&env, kv)
		}
	}
	append(&env, fmt.tprintf("TIDALFAST_MEASURE=%s", scenario))
	append(&env, "TIDALFAST_AUDIO_NULL=1")
	if setup != "real" {
		append(&env, fmt.tprintf("TIDALFAST_SETTINGS=%s", join(side.log_dir, "settings.json")))
		// The list cache too, shared by the runs: the first starts with none.
		append(&env, fmt.tprintf("TIDALFAST_CACHE=%s", join(side.log_dir, "cache")))
	}
	switch setup {
	case "fake":
		append(&env, "TIDALFAST_FAKE=1")
	case "mock":
		append(&env, fmt.tprintf("TIDALFAST_API=%s", side.mock_url))
		append(&env, fmt.tprintf("TIDALFAST_KEYCHAIN=%s", side.keychain))
		append(&env, fmt.tprintf("TIDALFAST_PKCE_REDIRECT=%s/android/login/auth?code=mock-pkce-code-1", side.mock_url))
	}
	return env[:]
}

// run_app runs the app with its stdout and stderr in log_path until it
// quits, or stops it after timeout. It returns the log and whether the app
// quit by itself.
run_app :: proc(app: string, env: []string, log_path: string, timeout: time.Duration) -> (log: string, finished: bool) {
	f, err := child_log(log_path)
	if err != nil {
		fmt.eprintfln("measure: can't write %s: %v", log_path, err)
		return "", false
	}
	p, perr := os.process_start({command = {app}, env = env, stdout = f, stderr = f})
	if perr != nil {
		os.close(f)
		fmt.eprintfln("measure: can't start %s: %v", app, perr)
		return "", false
	}
	st, werr := os.process_wait(p, timeout)
	finished = werr == nil && st.exited
	if !finished {
		stop(p)
	}
	os.close(f)
	data, _ := os.read_entire_file(log_path, context.allocator)
	return string(data), finished
}

// stop asks a process we started to quit, and kills it after 5 s. On
// Windows, Odin's process_terminate sends a console Ctrl-C, which reaches
// every process on the console, this tool and whatever started it too, so
// there the mock, which has no shutdown to run, is killed outright, and an
// app gets WM_CLOSE through stop_windows.
stop :: proc(p: os.Process) {
	when ODIN_OS == .Windows {
		stop_windows(p)
	} else {
		_ = os.process_terminate(p)
	}
	if _, err := os.process_wait(p, 5 * time.Second); err != nil {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
	}
}

// start_side_mock starts side's mock and names its Keychain item.
start_side_mock :: proc(cfg: ^Config, side: ^Side) -> bool {
	p, url, ok := start_mock(cfg, side.log_dir)
	if !ok {
		return false
	}
	side.mock, side.mock_url = p, url
	side.keychain = new_keychain_name()
	return true
}

// stop_side_mock stops side's mock and deletes the login its runs saved.
stop_side_mock :: proc(side: ^Side) {
	stop(side.mock)
	delete_keychain_item(side.keychain)
}

// start_mock starts tests/mock_tidal on a free loopback port and waits
// until it listens. The first start of a new mock binary makes its audio
// files first, which takes a few seconds; later ones read them back.
start_mock :: proc(cfg: ^Config, log_dir: string) -> (p: os.Process, url: string, ok: bool) {
	log_path := join(log_dir, "mock.log")
	f, err := child_log(log_path)
	if err != nil {
		return
	}
	defer os.close(f)
	// Shared by every run of this mock binary, which reads back the files
	// an earlier run encoded.
	audio := fmt.tprintf("-audio-dir=%s", join(cfg.out_dir, "mock-audio"))
	perr: os.Error
	p, perr = os.process_start({command = {cfg.mock, "-port=0", audio}, stdout = f, stderr = f})
	if perr != nil {
		fmt.eprintfln("measure: can't start the mock: %v", perr)
		return
	}
	PREFIX :: "mock: listening on "
	for _ in 0 ..< 1200 {
		data, _ := os.read_entire_file(log_path, context.temp_allocator)
		if at := strings.index(string(data), PREFIX); at >= 0 {
			rest := string(data)[at + len(PREFIX):]
			if end := strings.index_byte(rest, '\n'); end >= 0 {
				return p, strings.clone(rest[:end]), true
			}
		}
		time.sleep(100 * time.Millisecond)
	}
	fmt.eprintfln("measure: the mock didn't start listening, see %s", log_path)
	stop(p)
	return
}

// child_log creates the file at path, empty, for a child process's output.
// Windows passes a child only handles marked inheritable, which os.create's
// aren't.
child_log :: proc(path: string) -> (^os.File, os.Error) {
	return os.open(path, {.Write, .Create, .Trunc, .Inheritable})
}

join :: proc(elems: ..string) -> string {
	p, _ := filepath.join(elems)
	return p
}

clean :: proc(p: string) -> string {
	c, _ := filepath.clean(p)
	return c
}

timestamp :: proc() -> string {
	now := time.now()
	y, mon, d := time.date(now)
	h, min, s := time.clock(now)
	return fmt.aprintf("%04d%02d%02d-%02d%02d%02d", y, int(mon), d, h, min, s)
}

compare_files :: proc(a_path, b_path: string) -> int {
	a_data, aerr := os.read_entire_file(a_path, context.allocator)
	b_data, berr := os.read_entire_file(b_path, context.allocator)
	if aerr != nil || berr != nil {
		fmt.eprintln("measure: can't read", a_path if aerr != nil else b_path)
		return 1
	}
	a, aok := load_results(a_data)
	b, bok := load_results(b_data)
	if !aok || !bok {
		fmt.eprintln("measure: not a results file:", a_path if !aok else b_path)
		return 1
	}
	fmt.printfln("a: %s, %s, %s%s", a_path, a.machine.model, OS_LABEL, a.machine.os)
	fmt.printfln("b: %s, %s, %s%s", b_path, b.machine.model, OS_LABEL, b.machine.os)
	if a.machine.model != b.machine.model {
		fmt.println("different machines, so the times aren't comparable")
	}
	fmt.println()
	sb := strings.builder_make()
	write_compare(&sb, compare(a.metrics[:], b.metrics[:]))
	fmt.print(strings.to_string(sb))
	return 0
}

show_launches :: proc(path: string) -> int {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("measure: can't read %s: %v", path, err)
		return 1
	}
	groups := group_launches(string(data))
	if len(groups) == 0 {
		fmt.eprintfln("measure: no launches in %s", path)
		return 1
	}
	b := strings.builder_make()
	fmt.sbprintfln(&b, "%s\n", path)
	write_launches(&b, groups)
	fmt.print(strings.to_string(b))
	return 0
}
