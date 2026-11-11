#+build linux, darwin
package sys

import "core:os"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

@(default_calling_convention = "c")
foreign libc {
	@(private)
	mincore :: proc(addr: rawptr, length: uint, vec: [^]u8) -> i32 ---
}

Thread :: posix.pthread_t

// thread_start runs entry(arg) on a new thread. False if it couldn't.
thread_start :: proc(t: ^Thread, entry: Thread_Proc, arg: rawptr) -> bool {
	return posix.pthread_create(t, nil, entry, arg) == .NONE
}

// thread_join waits for t to return.
thread_join :: proc(t: Thread) {
	posix.pthread_join(t)
}

// local_time is unix seconds in the user's time zone. ok is false if the
// OS couldn't say.
local_time :: proc(unix_seconds: i64) -> (lt: Local_Time, ok: bool) {
	secs := posix.time_t(unix_seconds)
	tm: posix.tm
	if posix.localtime_r(&secs, &tm) == nil {
		return
	}
	return {
			year = int(tm.tm_year) + 1900,
			month = int(tm.tm_mon) + 1,
			day = int(tm.tm_mday),
			hour = int(tm.tm_hour),
			minute = int(tm.tm_min),
			second = int(tm.tm_sec),
		},
		true
}

page_size :: proc "contextless" () -> int {
	return int(posix.sysconf(._PAGESIZE))
}

// map_file maps the file at path read-only. Its bytes stay valid until
// unmap_file, after the file itself is closed.
map_file :: proc(path: cstring) -> ([]byte, bool) {
	fd := posix.open(path, {})
	if fd < 0 {
		return nil, false
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size <= 0 {
		return nil, false
	}
	size := uint(st.st_size)
	p := posix.mmap(nil, size, {.READ}, {.PRIVATE}, fd, 0)
	if p == posix.MAP_FAILED {
		return nil, false
	}
	return ([^]byte)(p)[:size], true
}

// page_flags fills flags with mincore's byte for each of the pages at
// start, page-aligned. Bit 0 is set for a page in RAM on every OS; the rest
// are the OS's own. False if it couldn't.
page_flags :: proc "contextless" (start: rawptr, flags: []u8) -> bool {
	return mincore(start, uint(len(flags)) * uint(page_size()), raw_data(flags)) == 0
}

unmap_file :: proc(data: []byte) {
	posix.munmap(raw_data(data), uint(len(data)))
}

// replace_file renames from over to in one step. False if it couldn't.
replace_file :: proc(from, to: string) -> bool {
	return os.rename(from, to) == nil
}

// write_stderr writes b with one call, so lines written from different
// threads don't interleave.
write_stderr :: proc "contextless" (b: []byte) {
	posix.write(posix.STDERR_FILENO, raw_data(b), uint(len(b)))
}

// quit asks the shell to quit the way Ctrl-C does, so the app's shutdown runs.
quit :: proc "contextless" () {
	posix.kill(posix.getpid(), .SIGTERM)
}
