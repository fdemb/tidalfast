package audio

import win "core:sys/windows"

// pages_release drops buf's pages from the working set. Its bytes are lost.
@(private)
pages_release :: proc(buf: []u8) -> bool {
	return win.DiscardVirtualMemory(raw_data(buf), uint(len(buf))) == 0
}

// pages_reuse takes back released pages before they're written again. The
// pages stayed committed, so a write does that by itself.
@(private)
pages_reuse :: proc(buf: []u8) -> bool {
	return true
}
