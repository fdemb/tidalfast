package app

// Linux has no Metal or AppKit, so only the headless build in tools/linux
// runs here, with Metal simulated in plain memory. Its numbers are for
// comparing builds with each other on Linux, not with macOS.

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../render"

@(private = "file")
footprint_peak_seen: int

// process_start_ns reads when the kernel started this process: its start
// in clock ticks after boot, from /proc/self/stat, and the boot time from
// /proc/stat. Ticks are 10 ms.
process_start_ns :: proc() -> i64 {
	now := time.to_unix_nanoseconds(time.now())
	stat_buf, boot_buf: [4096]u8
	stat := read_proc_file("/proc/self/stat", stat_buf[:])
	boot := read_proc_file("/proc/stat", boot_buf[:])
	// The command name can hold spaces, so fields count from its closing bracket.
	close := -1
	for i := len(stat) - 1; i >= 0; i -= 1 {
		if stat[i] == ')' {
			close = i
			break
		}
	}
	if close < 0 {
		return now
	}
	field := 2
	start_ticks := -1
	for word in strings.fields(stat[close + 1:], context.temp_allocator) {
		field += 1
		if field == 22 {
			start_ticks, _ = strconv.parse_int(word)
			break
		}
	}
	btime := proc_field(boot, "btime")
	if start_ticks < 0 || btime <= 0 {
		return now
	}
	ticks := int(posix.sysconf(._CLK_TCK))
	return i64(btime) * 1e9 + i64(start_ticks) * 1e9 / i64(max(ticks, 1))
}

// process_memory reads /proc/self/status. footprint is the anonymous memory
// in RAM or swap, which is what the app dirtied itself, and in this build
// includes the simulated GPU memory, as macOS's footprint does on Apple
// silicon. resident adds the clean pages of files: code and mapped fonts.
// Safe from any thread.
process_memory :: proc "contextless" (r: ^render.Renderer) -> Process_Memory {
	buf: [4096]u8
	status := read_proc_file("/proc/self/status", buf[:])
	pm: Process_Memory
	pm.resident = proc_field(status, "VmRSS:") * 1024
	pm.resident_peak = proc_field(status, "VmHWM:") * 1024
	pm.footprint = (proc_field(status, "RssAnon:") + proc_field(status, "VmSwap:")) * 1024
	for {
		peak := sync.atomic_load(&footprint_peak_seen)
		if pm.footprint <= peak {
			pm.footprint_peak = peak
			break
		}
		if _, ok := sync.atomic_compare_exchange_strong(&footprint_peak_seen, peak, pm.footprint); ok {
			pm.footprint_peak = pm.footprint
			break
		}
	}
	pm.gpu = render.gpu_allocated(r)
	return pm
}

@(private = "file")
read_proc_file :: proc "contextless" (path: cstring, buf: []u8) -> string {
	fd := posix.open(path, {})
	if fd < 0 {
		return ""
	}
	defer posix.close(fd)
	n := 0
	for n < len(buf) {
		got := int(posix.read(fd, &buf[n], uint(len(buf)) - uint(n)))
		if got <= 0 {
			break
		}
		n += got
	}
	return string(buf[:n])
}

// proc_field returns the number after name at the start of a line, or 0.
@(private = "file")
proc_field :: proc "contextless" (text, name: string) -> int {
	for at := 0; at + len(name) <= len(text); {
		if text[at:][:len(name)] == name {
			v := 0
			i := at + len(name)
			for i < len(text) && (text[i] == ' ' || text[i] == '\t') {
				i += 1
			}
			for i < len(text) && text[i] >= '0' && text[i] <= '9' {
				v = v * 10 + int(text[i] - '0')
				i += 1
			}
			return v
		}
		for at < len(text) && text[at] != '\n' {
			at += 1
		}
		at += 1
	}
	return 0
}
