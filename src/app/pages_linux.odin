package app

import "core:sys/linux"

// For the Linux build in tools/linux. MADV_DONTNEED gives the pages back at
// once, and they come back zeroed when next written, so taking them back
// is nothing.
pages_give_back :: proc "contextless" (start: rawptr, size: uint) {
	linux.madvise(start, size, .DONTNEED)
}

pages_take_back :: proc "contextless" (start: rawptr, size: uint) {
}
