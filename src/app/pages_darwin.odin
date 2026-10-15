package app

import "core:sys/posix"

// Darwin's madvise advice for memory a process gives back and takes again:
// pages marked reusable leave the process's footprint at once.
@(private = "file")
MADV_FREE_REUSABLE :: 7
@(private = "file")
MADV_FREE_REUSE :: 8

pages_give_back :: proc "contextless" (start: rawptr, size: uint) {
	posix.posix_madvise(start, size, transmute(posix.MAdvice)i32(MADV_FREE_REUSABLE))
}

pages_take_back :: proc "contextless" (start: rawptr, size: uint) {
	posix.posix_madvise(start, size, transmute(posix.MAdvice)i32(MADV_FREE_REUSE))
}
