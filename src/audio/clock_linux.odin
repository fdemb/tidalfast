package audio

import "core:sys/posix"
import "core:time"

// clock_ticks reads the monotonic clock in nanoseconds. libc answers
// clock_gettime from the vDSO, so the audio callback can call it: no
// system call, no lock. (core:sys/linux would make the system call.)
@(private)
clock_ticks :: proc "contextless" () -> u64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return u64(ts.tv_sec) * 1_000_000_000 + u64(ts.tv_nsec)
}

// ticks_duration converts a difference of clock_ticks values.
@(private)
ticks_duration :: proc(ticks: u64) -> time.Duration {
	return time.Duration(ticks)
}
