package app

import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import "../render"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	@(private = "file")
	malloc_usable_size :: proc(ptr: rawptr) -> uint ---
}

// mincore's resident bit. Linux doesn't say whether a page is dirty, and
// for anonymous memory resident is what the footprint counts.
PAGE_COUNTS :: 0x1

// glibc's malloc takes anonymous memory like the arenas.
HEAP_POOL :: Mem_Pool.Anon

// process_start_ns reads when the kernel started this process: field 22 of
// /proc/self/stat, in clock ticks since boot, set against the boot-time
// clock now. Ticks are 10 ms on most kernels.
process_start_ns :: proc() -> i64 {
	buf: [1024]u8
	text := read_proc("/proc/self/stat", buf[:])
	// The command name (field 2) can hold spaces, so count from its ')'.
	at := -1
	for i := len(text) - 1; i >= 0; i -= 1 {
		if text[i] == ')' {
			at = i
			break
		}
	}
	now := time.to_unix_nanoseconds(time.now())
	if at < 0 {
		return now
	}
	field := 2
	start: i64
	for i := at + 1; i < len(text); i += 1 {
		if text[i] == ' ' {
			field += 1
			continue
		}
		if field == 22 {
			if text[i] < '0' || text[i] > '9' {
				break
			}
			start = start * 10 + i64(text[i] - '0')
		}
	}
	hz := i64(posix.sysconf(._CLK_TCK))
	boot, err := linux.clock_gettime(.BOOTTIME)
	if hz <= 0 || start == 0 || err != .NONE {
		return now
	}
	since_boot := i64(boot.time_sec) * 1e9 + i64(boot.time_nsec)
	return now - since_boot + start * (1e9 / hz)
}

@(private = "file")
footprint_peak: int

// process_memory reads /proc/self/status and the GPU's allocations. The
// footprint is RssAnon plus RssShmem, the memory that has nothing but swap
// behind it, which is the nearest thing to what macOS calls the footprint.
// Linux keeps no peak of it, so the peak is the highest this has seen.
// Safe from any thread.
process_memory :: proc "contextless" (r: ^render.Renderer) -> Process_Memory {
	buf: [4096]u8
	text := read_proc("/proc/self/status", buf[:])
	pm: Process_Memory
	pm.resident = status_kb(text, "VmRSS:") * 1024
	pm.resident_peak = status_kb(text, "VmHWM:") * 1024
	pm.footprint = (status_kb(text, "RssAnon:") + status_kb(text, "RssShmem:")) * 1024
	peak := sync.atomic_load(&footprint_peak)
	for pm.footprint > peak {
		old, ok := sync.atomic_compare_exchange_weak(&footprint_peak, peak, pm.footprint)
		if ok {
			break
		}
		peak = old
	}
	pm.footprint_peak = max(peak, pm.footprint)
	pm.gpu = render.gpu_allocated(r)
	return pm
}

@(private = "file")
read_proc :: proc "contextless" (path: cstring, buf: []u8) -> string {
	fd := posix.open(path, {})
	if fd < 0 {
		return ""
	}
	defer posix.close(fd)
	n: int
	for n < len(buf) {
		room := len(buf) - n
		got := int(posix.read(fd, &buf[n], uint(room)))
		if got <= 0 {
			break
		}
		n += got
	}
	return string(buf[:n])
}

// status_kb finds a "Name:   123 kB" line in /proc/self/status.
@(private = "file")
status_kb :: proc "contextless" (text, name: string) -> int {
	for i := 0; i + len(name) <= len(text); i += 1 {
		if (i == 0 || text[i - 1] == '\n') && text[i:][:len(name)] == name {
			v := 0
			for j := i + len(name); j < len(text) && text[j] != '\n'; j += 1 {
				if text[j] >= '0' && text[j] <= '9' {
					v = v * 10 + int(text[j] - '0')
				}
			}
			return v
		}
	}
	return 0
}

// os_memory has two pools on Linux: the footprint, all of it anonymous
// memory (process_memory), and the device memory the renderer holds, which
// a GPU keeps outside it. With a CPU device such as lavapipe the device
// memory is in the footprint too, so it counts twice.
os_memory :: proc(r: ^render.Renderer) -> Os_Memory {
	pm := process_memory(r)
	om := Os_Memory{footprint = pm.footprint}
	om.pools[.Anon] = pm.footprint
	om.pools[.Gpu] = pm.gpu
	return om
}

// process_counters and thread_counters have nothing on Linux yet:
// perf_event_open counters would have to be opened before the shell starts
// its threads.
process_counters :: proc "contextless" () -> Counters {
	return {}
}

thread_counters :: proc "contextless" () -> Counters {
	return {}
}


// heap_bytes is what malloc gave for ptr, 0 for nil.
heap_bytes :: proc(ptr: rawptr) -> int {
	return int(malloc_usable_size(ptr)) if ptr != nil else 0
}
