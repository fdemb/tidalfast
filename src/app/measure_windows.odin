package app

import "core:sync"
import "core:time"
import win "core:sys/windows"

import "../render"

foreign import kernel32 "system:Kernel32.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign kernel32 {
	HeapSize :: proc(heap: win.HANDLE, flags: u32, mem: rawptr) -> uint ---
	HeapValidate :: proc(heap: win.HANDLE, flags: u32, mem: rawptr) -> win.BOOL ---
	GetCurrentThread :: proc() -> win.HANDLE ---
	QueryThreadCycleTime :: proc(thread: win.HANDLE, cycles: ^u64) -> win.BOOL ---
	QueryProcessCycleTime :: proc(process: win.HANDLE, cycles: ^u64) -> win.BOOL ---
}

// sys.page_flags' bit for a page in the working set. Windows doesn't say
// whether a private page is dirty, so as on Linux a page in RAM counts.
PAGE_COUNTS :: 0x1

// The Odin heap is the process heap, private memory like the arenas.
HEAP_POOL :: Mem_Pool.Anon

// process_start_ns reads when Windows started this process.
process_start_ns :: proc() -> i64 {
	created, exited, kernel, user: win.FILETIME
	if !win.GetProcessTimes(win.GetCurrentProcess(), &created, &exited, &kernel, &user) {
		return time.to_unix_nanoseconds(time.now())
	}
	ticks := i64(created.dwHighDateTime) << 32 | i64(created.dwLowDateTime)
	// FILETIME counts 100 ns from 1601.
	return (ticks - 116_444_736_000_000_000) * 100
}

@(private = "file")
footprint_peak: int

// process_memory reads the process's private bytes and working set. The
// footprint is the private working set: the private memory in RAM, which
// is what Task Manager's Memory column shows. Windows keeps no peak of it,
// so the peak is the highest this has seen. Safe from any thread.
process_memory :: proc "contextless" (r: ^render.Renderer) -> Process_Memory {
	c: win.PROCESS_MEMORY_COUNTERS_EX2
	c.cb = size_of(c)
	pm: Process_Memory
	if win.GetProcessMemoryInfo(win.GetCurrentProcess(), &c.counter, c.cb) {
		pm.resident = int(c.WorkingSetSize)
		pm.resident_peak = int(c.PeakWorkingSetSize)
		pm.footprint = int(c.PrivateWorkingSetSize)
	}
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

// os_memory has two pools on Windows, as on Linux: the footprint and the
// device memory the renderer holds. With an integrated GPU the device
// memory may be in the footprint too, so it counts twice.
os_memory :: proc(r: ^render.Renderer) -> Os_Memory {
	pm := process_memory(r)
	om := Os_Memory{footprint = pm.footprint}
	om.pools[.Anon] = pm.footprint
	om.pools[.Gpu] = pm.gpu
	return om
}

// process_counters has the cycles every thread has run so far. Windows
// doesn't count instructions for a process.
process_counters :: proc "contextless" () -> Counters {
	cycles: u64
	if !QueryProcessCycleTime(win.GetCurrentProcess(), &cycles) {
		return {}
	}
	return {cycles = cycles}
}

thread_counters :: proc "contextless" () -> Counters {
	cycles: u64
	if !QueryThreadCycleTime(GetCurrentThread(), &cycles) {
		return {}
	}
	return {cycles = cycles}
}


// heap_bytes is what the heap gave for ptr, 0 for nil. The pointers come
// from libc's malloc, which is HeapAlloc on the process heap, or from the
// Odin heap allocator, which hands out a pointer past the block and keeps
// the block's address just before it. HeapValidate tells the two apart
// without touching an address that isn't a block.
heap_bytes :: proc(ptr: rawptr) -> int {
	if ptr == nil {
		return 0
	}
	heap := win.GetProcessHeap()
	if HeapValidate(heap, 0, ptr) {
		return int(HeapSize(heap, 0, ptr))
	}
	block := ([^]rawptr)(ptr)[-1]
	if HeapValidate(heap, 0, block) {
		return int(HeapSize(heap, 0, block))
	}
	return 0
}
