package audio

import "core:time"
import win "core:sys/windows"

@(private = "file")
qpc_frequency: i64

// clock_ticks reads the performance counter, which the audio callback can
// call: no lock, and on current Windows no switch to the kernel.
@(private)
clock_ticks :: proc "contextless" () -> u64 {
	now: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&now)
	return u64(now)
}

// ticks_duration converts a difference of clock_ticks values.
@(private)
ticks_duration :: proc(ticks: u64) -> time.Duration {
	if qpc_frequency == 0 {
		f: win.LARGE_INTEGER
		win.QueryPerformanceFrequency(&f)
		qpc_frequency = i64(f)
	}
	return time.Duration(i128(ticks) * 1_000_000_000 / i128(qpc_frequency))
}
