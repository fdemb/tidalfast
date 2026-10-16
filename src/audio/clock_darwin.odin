package audio

import "core:c"
import "core:time"

foreign import libsystem "system:System"

@(private = "file")
Timebase :: struct {
	numer, denom: u32,
}

@(private = "file", default_calling_convention = "c")
foreign libsystem {
	mach_absolute_time :: proc() -> u64 ---
	mach_timebase_info :: proc(info: ^Timebase) -> c.int ---
}

// clock_ticks reads the monotonic clock. mach_absolute_time reads the
// commpage, so the audio callback can call it: no system call, no lock.
@(private)
clock_ticks :: proc "contextless" () -> u64 {
	return mach_absolute_time()
}

// ticks_duration converts a difference of clock_ticks values.
@(private)
ticks_duration :: proc(ticks: u64) -> time.Duration {
	tb: Timebase
	mach_timebase_info(&tb)
	return time.Duration(ticks * u64(tb.numer) / u64(tb.denom))
}
