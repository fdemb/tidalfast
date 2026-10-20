package app

import "core:sys/linux"

// pages_give_back lets the system take the pages, whose contents no longer
// matter. They read as zeros when touched again, so taking them back needs
// no call.
pages_give_back :: proc(start: rawptr, size: uint) -> bool {
	return linux.madvise(start, size, .DONTNEED) == .NONE
}

pages_take_back :: proc(start: rawptr, size: uint) {}
