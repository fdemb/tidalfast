package audio

import "core:sys/linux"

// pages_release gives buf's pages back to the system. Its bytes are lost.
@(private)
pages_release :: proc(buf: []u8) -> bool {
	return linux.madvise(raw_data(buf), uint(len(buf)), .DONTNEED) == .NONE
}

// pages_reuse takes back released pages before they're written again. On
// Linux a write does that by itself, with a zeroed page.
@(private)
pages_reuse :: proc(buf: []u8) -> bool {
	return true
}
