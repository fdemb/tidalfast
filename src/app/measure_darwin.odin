package app

import "base:intrinsics"
import "core:sys/darwin"
import "core:sys/posix"
import "core:sys/unix"
import "core:time"

import "../render"

foreign import libc "system:System"

@(default_calling_convention = "c")
foreign libc {
	proc_pid_rusage :: proc(pid: i32, flavor: i32, buffer: rawptr) -> i32 ---
	// Through libc rather than intrinsics.syscall, whose registers an
	// optimized build trusts across the call: that crashed.
	syscall :: proc(number: i32, #c_vararg args: ..any) -> i32 ---
	@(private = "file")
	malloc_size :: proc(ptr: rawptr) -> uint ---
	mach_vm_region_recurse :: proc(task: darwin.task_t, address: ^u64, size: ^u64, depth: ^u32, info: rawptr, count: ^u32) -> darwin.Kern_Return ---
}

// mincore's MINCORE_MODIFIED and MINCORE_PAGED_OUT: a page that counts
// toward the footprint. An anonymous page that was only read is modified
// too, and one given back with MADV_FREE_REUSABLE isn't, just as the
// footprint counts them.
PAGE_COUNTS :: 0x4 | 0x20

HEAP_POOL :: Mem_Pool.Malloc

// process_start_ns reads when the kernel started this process, from
// kinfo_proc's p_starttime, a timeval at offset 0.
process_start_ns :: proc() -> i64 {
	CTL_KERN :: 1
	KERN_PROC :: 14
	KERN_PROC_PID :: 1
	info: [648]u8 // struct kinfo_proc
	mib := [4]i32{CTL_KERN, KERN_PROC, KERN_PROC_PID, i32(posix.getpid())}
	if !unix.sysctl(mib[:], &info) {
		return time.to_unix_nanoseconds(time.now())
	}
	sec := intrinsics.unaligned_load((^i64)(&info[0]))
	usec := intrinsics.unaligned_load((^i32)(&info[8]))
	return sec * 1e9 + i64(usec) * 1e3
}

// process_memory reads task_info's TASK_VM_INFO and the GPU's allocations.
// Safe from any thread.
process_memory :: proc "contextless" (r: ^render.Renderer) -> Process_Memory {
	TASK_VM_INFO :: 22
	info: [93]u32 // task_vm_info_data_t, 4-byte packed, TASK_VM_INFO_COUNT
	count := u32(len(info))
	pm: Process_Memory
	if darwin.task_info(darwin.mach_task_self(), TASK_VM_INFO, darwin.task_info_t(&info[0]), &count) == .Success {
		at :: proc "contextless" (info: ^[93]u32, offset: int) -> int {
			return int(intrinsics.unaligned_load((^u64)(&info[offset / 4])))
		}
		pm.resident = at(&info, 16)
		pm.resident_peak = at(&info, 24)
		pm.footprint = at(&info, 144)
		pm.footprint_peak = at(&info, 168)
	}
	pm.gpu = render.gpu_allocated(r)
	return pm
}

// process_counters reads the instructions and cycles every thread of this
// process has run so far, dyld included, from proc_pid_rusage's
// rusage_info_v4. Load, clock speed and heat barely move them, unlike
// times. Safe from any thread.
process_counters :: proc "contextless" () -> Counters {
	RUSAGE_INFO_V4 :: 4
	info: [296]u8 // struct rusage_info_v4
	if proc_pid_rusage(i32(posix.getpid()), RUSAGE_INFO_V4, &info) != 0 {
		return {}
	}
	return {
		instructions = intrinsics.unaligned_load((^u64)(&info[248])),
		cycles       = intrinsics.unaligned_load((^u64)(&info[256])),
	}
}

// thread_counters is process_counters for the calling thread alone, from
// the thread_selfcounts system call. The UI thread's count at a mark leaves
// out how far the workers and the font loader happened to get. The call
// isn't public API, so a kernel without it gives zeros.
thread_counters :: proc "contextless" () -> Counters {
	SYS_THREAD_SELFCOUNTS :: 186
	THSC_CPI :: 1 // instructions, then cycles
	c: [2]u64
	if syscall(SYS_THREAD_SELFCOUNTS, i32(THSC_CPI), rawptr(&c), uint(size_of(c))) != 0 {
		return {}
	}
	return {instructions = c[0], cycles = c[1]}
}

// os_memory splits the footprint into pools by walking the address space
// the way footprint(1) does: each region's dirty and compressed pages, by
// the tag its maker gave it. Metal's memory comes from the task's graphics
// ledger, since some of it is mapped nowhere. What the walk can't place,
// the page tables among it, goes in as one part.
os_memory :: proc(r: ^render.Renderer) -> Os_Memory {
	TASK_VM_INFO :: 22
	info: [93]u32
	count := u32(len(info))
	om: Os_Memory
	graphics := 0
	if darwin.task_info(darwin.mach_task_self(), TASK_VM_INFO, darwin.task_info_t(&info[0]), &count) == .Success {
		at :: proc(info: ^[93]u32, offset: int) -> int {
			return int(intrinsics.unaligned_load((^u64)(&info[offset / 4])))
		}
		om.footprint = at(&info, 144)
		// ledger_tag_graphics_footprint and its compressed part
		graphics = at(&info, 272) + at(&info, 280)
	}

	VM_MEMORY_MALLOC_LAST :: 13
	VM_MEMORY_ANALYSIS_TOOL :: 10
	VM_MEMORY_STACK :: 30
	VM_MEMORY_IOSURFACE :: 88
	VM_MEMORY_IOACCELERATOR :: 100
	page := int(posix.sysconf(._PAGESIZE))
	surfaces, accelerator, binaries, stacks, tagged := 0, 0, 0, 0, 0
	address: u64
	depth: u32
	for {
		size: u64
		region: [21]u32 // vm_region_submap_info_64
		n := u32(len(region))
		if mach_vm_region_recurse(darwin.mach_task_self(), &address, &size, &depth, &region[0], &n) != .Success {
			break
		}
		bytes := ([^]u8)(&region[0])
		if intrinsics.unaligned_load((^i32)(&bytes[48])) != 0 { // is_submap
			depth += 1
			continue
		}
		tag := int(region[5])
		dirty := (int(region[9]) + int(region[8])) * page // pages_dirtied, pages_swapped_out
		external := bytes[46] != 0
		switch {
		case tag >= 1 && tag <= VM_MEMORY_MALLOC_LAST && tag != VM_MEMORY_ANALYSIS_TOOL:
			om.pools[.Malloc] += max(dirty - int(region[16]) * page, 0) // less pages_reusable
		case tag == VM_MEMORY_IOSURFACE:
			surfaces += dirty
		case tag == VM_MEMORY_IOACCELERATOR:
			accelerator += dirty
		case tag == 0 && !external:
			om.pools[.Anon] += dirty
		case tag == 0:
			binaries += dirty
		case tag == VM_MEMORY_STACK:
			stacks += dirty
		case:
			tagged += dirty
		}
		address += size
	}
	// The ledger has the IOAccelerator regions' memory and the graphics
	// memory mapped nowhere, less what Metal marked purgeable.
	om.pools[.Gpu] = graphics if graphics > 0 else accelerator
	om.pools[.Surfaces] = surfaces
	counted := om.pools[.Anon] + om.pools[.Malloc] + om.pools[.Gpu] + om.pools[.Surfaces] + binaries + stacks + tagged
	om.other = {
		{"binaries' data", binaries},
		{"thread stacks", stacks},
		{"other tagged regions", tagged},
		{"page tables and unaccounted", max(om.footprint - counted, 0)},
	}
	for part in om.other {
		om.pools[.Other] += part.bytes
	}
	return om
}


// heap_bytes is what malloc gave for ptr, 0 for nil.
heap_bytes :: proc(ptr: rawptr) -> int {
	return int(malloc_size(ptr)) if ptr != nil else 0
}
