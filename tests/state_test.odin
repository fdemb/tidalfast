package tidal_tests

import "base:runtime"
import vmem "core:mem/virtual"
import "core:testing"

import app "../src/app"
import "../src/platform"

// The persistent arena never frees, so after start an allocation that
// forgot its allocator mustn't land there. Debug builds panic instead.
@(test)
app_context_keeps_the_persistent_arena_closed :: proc(t: ^testing.T) {
	when ODIN_DEBUG {
		return
	}
	persistent_size := uint(size_of(app.State) + 1 << 20)
	frame_size := uint(1 << 20)
	persistent, perr := vmem.reserve_and_commit(persistent_size)
	frame, ferr := vmem.reserve_and_commit(frame_size)
	if !testing.expect(t, perr == nil && ferr == nil) {
		return
	}
	defer vmem.release(raw_data(persistent), persistent_size)
	defer vmem.release(raw_data(frame), frame_size)
	m := platform.Memory{raw_data(persistent), persistent_size, raw_data(frame), frame_size}
	s := app.state_init(&m)
	context = app.app_context(s)

	used := s.arena.offset
	b := make([]u8, 4096)
	testing.expect(t, b != nil)
	testing.expect_value(t, s.arena.offset, used)
	delete(b, runtime.heap_allocator())

	p := make([]u8, 4096, app.persistent_allocator(s))
	testing.expect(t, p != nil)
	testing.expect_value(t, s.arena.offset, used + 4096)
}
