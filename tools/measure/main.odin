// Launches the app again and again with TIDALFAST_MEASURE set, reads its
// `measure:` lines and prints what it found. See "Measuring RAM and
// startup" in the README.
//
//     ./build.sh measure
//     ./build/measure/measure startup            fake and mock, 10 runs each
//     ./build/measure/measure memory             fake and mock, 1 run each
//     ./build/measure/measure all
//     ./build/measure/measure compare a.json b.json
//
// Flags: -runs=N, -setup=fake,mock, -app=path, -timeout=seconds, -out=path,
// and -real, which runs against your own account and Keychain item with
// build/tidalfast instead of the fake data and the mock.
package measure

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

Config :: struct {
	root:      string, // the checkout
	out_dir:   string, // build/measure
	app:       string,
	mock:      string,
	setups:    []string,
	runs:      int, // 0: the scenario's default
	timeout:   time.Duration, // 0: the scenario's default
	out:       string,
	real:      bool,
	log_dir:   string,
	mock_url:  string,
	keychain:  string,
	failed:    int,
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
	scenario := args[0]
	if scenario != "startup" && scenario != "memory" && scenario != "all" {
		usage()
	}

	exe_dir, _ := os.get_executable_directory(context.allocator)
	cfg := Config {
		out_dir = exe_dir,
		root    = clean(join(exe_dir, "..", "..")),
	}
	setups_flag := "fake,mock"
	for arg in args[1:] {
		name, _, value := strings.partition(arg, "=")
		switch name {
		case "-runs":
			cfg.runs, _ = strconv.parse_int(value)
		case "-setup":
			setups_flag = value
		case "-app":
			cfg.app = value
		case "-timeout":
			secs, _ := strconv.parse_int(value)
			cfg.timeout = time.Duration(secs) * time.Second
		case "-out":
			cfg.out = value
		case "-real":
			cfg.real = true
		case:
			usage()
		}
	}
	if cfg.real {
		setups_flag = "real"
	}
	cfg.setups = strings.split(setups_flag, ",")
	if cfg.app == "" {
		// The measure build reads TIDALFAST_API; a release build doesn't. The
		// real account's Keychain item belongs to build/tidalfast.
		cfg.app = join(cfg.root, "build", "tidalfast") if cfg.real else join(cfg.out_dir, "app", "tidalfast")
	}
	cfg.mock = join(cfg.out_dir, "mock_tidal")
	if !os.exists(cfg.app) {
		fmt.eprintfln("measure: no app at %s; run ./build.sh measure (or ./build.sh release for -real)", cfg.app)
		os.exit(1)
	}

	stamp := timestamp()
	if cfg.out == "" {
		cfg.out = join(cfg.out_dir, fmt.tprintf("%s.json", stamp))
	}
	cfg.log_dir = join(cfg.out_dir, fmt.tprintf("logs-%s", stamp))
	os.make_directory_all(cfg.log_dir)

	results := Results {
		version = 1,
		time    = stamp,
		machine = machine(),
		app     = strings.trim_prefix(cfg.app, strings.concatenate({cfg.root, "/"})),
	}
	fmt.printfln("%s, %s, %s %s (%s), %.0f GB", results.machine.model, results.machine.cpu, OS_NAME, results.machine.os, results.machine.os_build, results.machine.memory_gb)
	fmt.printfln("app %s, logs in %s\n", cfg.app, cfg.log_dir)

	mock_process: os.Process
	has_mock := false
	for setup in cfg.setups {
		switch setup {
		case "fake", "real":
		case "mock":
			if !os.exists(cfg.mock) {
				fmt.eprintfln("measure: no mock at %s; run ./build.sh measure", cfg.mock)
				os.exit(1)
			}
			p, url, ok := start_mock(&cfg)
			if !ok {
				os.exit(1)
			}
			mock_process, cfg.mock_url, has_mock = p, url, true
			cfg.keychain = fmt.tprintf("tidalfast-measure-%08x", rand.uint32())
		case:
			fmt.eprintfln("measure: unknown setup %s", setup)
			os.exit(1)
		}
	}

	for setup in cfg.setups {
		if scenario == "startup" || scenario == "all" {
			runs := run_scenario(&cfg, setup, "startup", cfg.runs if cfg.runs > 0 else 10, cfg.timeout if cfg.timeout > 0 else 60 * time.Second)
			add_startup(&results, setup, runs)
		}
		if scenario == "memory" || scenario == "all" {
			runs := run_scenario(&cfg, setup, "memory", cfg.runs if cfg.runs > 0 && scenario == "memory" else 1, cfg.timeout if cfg.timeout > 0 else 240 * time.Second)
			add_memory(&results, setup, runs)
		}
	}

	if has_mock {
		stop(mock_process)
		delete_keychain_item(cfg.keychain)
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
	fmt.eprintln(`usage: measure startup|memory|all [-runs=N] [-setup=fake,mock] [-app=path] [-timeout=s] [-out=path] [-real]
       measure compare a.json b.json`)
	os.exit(2)
}

// run_scenario launches the app runs times and returns each run's lines.
// A run that times out or never gets to its last line still counts what it
// printed, and counts as failed.
run_scenario :: proc(cfg: ^Config, setup, scenario: string, runs: int, timeout: time.Duration) -> [][]Line {
	out := make([dynamic][]Line)
	for i in 0 ..< runs {
		fmt.printf("%s %s run %d/%d ", scenario, setup, i + 1, runs)
		log_path := join(cfg.log_dir, fmt.tprintf("%s-%s-%d.log", scenario, setup, i + 1))
		env := app_env(cfg, setup, scenario)
		log, finished := run_app(cfg.app, env, log_path, timeout)
		lines := parse_log(log)
		last := "tracks" if scenario == "startup" else "idle_after"
		reached: bool
		if scenario == "startup" {
			_, reached = find_mark(lines, last)
		} else {
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
			fmt.printfln("tracks at %.1f ms", l.ms)
		} else {
			fmt.println("done")
		}
		append(&out, lines)
	}
	return out[:]
}

// app_env is this process's environment without TIDALFAST_ and Metal
// variables someone left set, plus what the setup needs. Settings go to a
// file of their own that doesn't exist, so bit-perfect output is off and
// your settings stay as they are, and the list cache to a folder of its own.
app_env :: proc(cfg: ^Config, setup, scenario: string) -> []string {
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
		append(&env, fmt.tprintf("TIDALFAST_SETTINGS=%s", join(cfg.log_dir, "settings.json")))
		// The list cache too, shared by the runs: the first starts with none.
		append(&env, fmt.tprintf("TIDALFAST_CACHE=%s", join(cfg.log_dir, "cache")))
	}
	switch setup {
	case "fake":
		append(&env, "TIDALFAST_FAKE=1")
	case "mock":
		append(&env, fmt.tprintf("TIDALFAST_API=%s", cfg.mock_url))
		append(&env, fmt.tprintf("TIDALFAST_KEYCHAIN=%s", cfg.keychain))
		append(&env, fmt.tprintf("TIDALFAST_PKCE_REDIRECT=%s/android/login/auth?code=mock-pkce-code-1", cfg.mock_url))
	}
	return env[:]
}

// run_app runs the app with its stdout and stderr in log_path until it
// quits, or stops it after timeout. It returns the log and whether the app
// quit by itself.
run_app :: proc(app: string, env: []string, log_path: string, timeout: time.Duration) -> (log: string, finished: bool) {
	f, err := os.create(log_path)
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
	_, werr := os.process_wait(p, timeout)
	finished = werr == nil
	if !finished {
		stop(p)
	}
	os.close(f)
	data, _ := os.read_entire_file(log_path, context.allocator)
	return string(data), finished
}

// stop asks a process we started to quit, and kills it after 5 s.
stop :: proc(p: os.Process) {
	_ = os.process_terminate(p)
	if _, err := os.process_wait(p, 5 * time.Second); err != nil {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
	}
}

// start_mock starts tests/mock_tidal on a free loopback port and waits
// until it listens. It makes its audio files first, which takes a while.
start_mock :: proc(cfg: ^Config) -> (p: os.Process, url: string, ok: bool) {
	log_path := join(cfg.log_dir, "mock.log")
	f, err := os.create(log_path)
	if err != nil {
		return
	}
	defer os.close(f)
	audio := fmt.tprintf("-audio-dir=%s", join(cfg.log_dir, "mock-audio"))
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

// delete_keychain_item deletes the mock login the runs saved, made for
// this run alone. SecItemDelete from this program gets -25244, since the
// item's access list names the app; the security tool may delete it.
delete_keychain_item :: proc(service: string) {
	when ODIN_OS != .Darwin {
		return // the Linux build's Keychain lives in the app's memory
	}
	p, err := os.process_start({command = {"/usr/bin/security", "delete-generic-password", "-s", service, "-a", "auth"}})
	if err == nil {
		if state, werr := os.process_wait(p, 10 * time.Second); werr == nil && state.exit_code == 0 {
			return
		}
	}
	fmt.eprintfln("measure: couldn't delete the Keychain item; security delete-generic-password -s %s", service)
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
	fmt.printfln("a: %s, %s, %s", a_path, a.machine.model, a.machine.os)
	fmt.printfln("b: %s, %s, %s", b_path, b.machine.model, b.machine.os)
	if a.machine.model != b.machine.model {
		fmt.println("different machines, so the times aren't comparable")
	}
	fmt.println()
	sb := strings.builder_make()
	write_compare(&sb, compare(a.metrics[:], b.metrics[:]))
	fmt.print(strings.to_string(sb))
	return 0
}
