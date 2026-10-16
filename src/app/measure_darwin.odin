package app

import "base:intrinsics"
import "core:sys/darwin"
import "core:sys/posix"
import "core:sys/unix"
import "core:time"

import "../render"

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
