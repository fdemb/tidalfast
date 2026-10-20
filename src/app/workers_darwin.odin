package app

import "core:sys/posix"

@(private = "file")
MADV_FREE_REUSABLE :: 7
@(private = "file")
MADV_FREE_REUSE :: 8

// pages_give_back lets the system take the pages, whose contents no longer
// matter, and drops them from the footprint. Darwin keeps counting them
// until pages_take_back says they're in use again.
pages_give_back :: proc(start: rawptr, size: uint) -> bool {
	return posix.posix_madvise(start, size, transmute(posix.MAdvice)i32(MADV_FREE_REUSABLE)) == .NONE
}

pages_take_back :: proc(start: rawptr, size: uint) {
	posix.posix_madvise(start, size, transmute(posix.MAdvice)i32(MADV_FREE_REUSE))
}
