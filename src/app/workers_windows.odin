package app

import win "core:sys/windows"

// pages_give_back drops the pages from the working set, and their contents
// with them. They stay committed, so touching them again needs no call and
// can't fault: they read as zeros or as they were.
pages_give_back :: proc(start: rawptr, size: uint) -> bool {
	return win.DiscardVirtualMemory(start, size) == 0
}

pages_take_back :: proc(start: rawptr, size: uint) {}
