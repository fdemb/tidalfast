package tidal_tests

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "../src/os_services"

// The shell blocks SIGTERM, SIGINT and SIGHUP for its signalfd and ignores
// SIGPIPE. A program the app starts, like xdg-open and the browser behind
// it, must get neither, or kill and Ctrl-C can't stop it.
@(test)
spawned_programs_get_default_signals :: proc(t: ^testing.T) {
	quit, old: posix.sigset_t
	posix.sigemptyset(&quit)
	posix.sigaddset(&quit, .SIGTERM)
	posix.sigaddset(&quit, .SIGINT)
	posix.sigaddset(&quit, .SIGHUP)
	posix.pthread_sigmask(.BLOCK, &quit, &old)
	defer posix.pthread_sigmask(.SETMASK, &old, nil)
	old_pipe := posix.signal(.SIGPIPE, auto_cast rawptr(uintptr(1))) // SIG_IGN
	defer posix.signal(.SIGPIPE, old_pipe)

	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" {
		dir = "/tmp"
	}
	path := fmt.tprintf("%s/tidalfast-spawn-test-%d.txt", dir, posix.getpid())
	defer os.remove(path)
	script := strings.concatenate({"grep -E '^Sig(Blk|Ign)' /proc/self/status > ", path, ".tmp && mv ", path, ".tmp ", path}, context.temp_allocator)
	// bash, not sh: dash clears the signal mask when it starts.
	argv := [4]cstring{"bash", "-c", strings.clone_to_cstring(script, context.temp_allocator), nil}
	testing.expect(t, os_services.spawn_detached(argv[:]))

	data: []byte
	for _ in 0 ..< 200 {
		if d, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			data = d
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	text := string(data)
	blocked, ignored: u64 = max(u64), max(u64)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "SigBlk:") {
			blocked, _ = strconv.parse_u64_of_base(strings.trim_space(line[7:]), 16)
		} else if strings.has_prefix(line, "SigIgn:") {
			ignored, _ = strconv.parse_u64_of_base(strings.trim_space(line[7:]), 16)
		}
	}
	testing.expect_value(t, blocked, 0)
	// Bit n - 1 is signal n.
	testing.expect_value(t, ignored & (1 << (u64(posix.Signal.SIGPIPE) - 1)), 0)
}
