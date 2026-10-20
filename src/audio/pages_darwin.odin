package audio

import "core:sys/posix"

// Darwin's madvise advice for memory a process gives back and takes again:
// pages marked reusable leave the process's footprint at once.
@(private = "file")
MADV_FREE_REUSABLE :: 7
@(private = "file")
MADV_FREE_REUSE :: 8

// pages_release gives buf's pages back to the system. Its bytes are lost.
@(private)
pages_release :: proc(buf: []u8) -> bool {
	return posix.posix_madvise(raw_data(buf), len(buf), transmute(posix.MAdvice)i32(MADV_FREE_REUSABLE)) == .NONE
}

// pages_reuse takes back released pages before they're written again.
@(private)
pages_reuse :: proc(buf: []u8) -> bool {
	return posix.posix_madvise(raw_data(buf), len(buf), transmute(posix.MAdvice)i32(MADV_FREE_REUSE)) == .NONE
}
