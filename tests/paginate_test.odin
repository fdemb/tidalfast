package tidal_tests

import "base:runtime"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import tidal "../src/tidal"

@(private = "file")
Thread_Check :: struct {
	backing: runtime.Allocator,
	owner:   int,
	others:  int, // allocations from threads other than owner
}

@(private = "file")
thread_check_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	c := (^Thread_Check)(data)
	if os.get_current_thread_id() != c.owner {
		sync.atomic_add(&c.others, 1)
	}
	return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// The paging threads have temp allocators of their own, which the thread
// package frees when they end. Given the caller's, they'd share it across
// threads, and the arena they'd make in it would outlive them.
@(test)
paging_threads_keep_their_own_temp_allocator :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	s.config.api_v1_location = m.base_url
	s.config.api_v2_location = m.base_url
	s.config.api_oauth2_token = "http://127.0.0.1:1/token"
	testing.expect_value(t, tidal.load_oauth_session(s, "Bearer", "access", "refresh", time.time_add(time.now(), time.Hour)), nil)

	check := Thread_Check {
		backing = context.temp_allocator,
		owner   = os.get_current_thread_id(),
	}
	context.temp_allocator = {thread_check_proc, &check}
	tracks, err := tidal.favorites_tracks_paginated(s, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(tracks), MOCK_LIKED - len(MOCK_UNAVAILABLE))
	testing.expect_value(t, sync.atomic_load(&check.others), 0)
}

@(private = "file")
Temp_Count :: struct {
	backing: runtime.Allocator,
	owner:   int,
	bytes:   int, // allocated by owner
}

@(private = "file")
temp_count_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	c := (^Temp_Count)(data)
	if os.get_current_thread_id() == c.owner && (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		c.bytes += size
	}
	return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Pages are parsed one at a time, so the caller's scratch memory doesn't
// hold every page's JSON until the list is done.
@(test)
paging_scratch_does_not_grow_with_the_list :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	s.config.api_v1_location = m.base_url
	s.config.api_v2_location = m.base_url
	s.config.api_oauth2_token = "http://127.0.0.1:1/token"
	testing.expect_value(t, tidal.load_oauth_session(s, "Bearer", "access", "refresh", time.time_add(time.now(), time.Hour)), nil)

	results: vmem.Arena
	defer vmem.arena_destroy(&results)
	count := Temp_Count {
		backing = context.temp_allocator,
		owner   = os.get_current_thread_id(),
	}
	context.temp_allocator = {temp_count_proc, &count}
	tracks, err := tidal.favorites_tracks_paginated(s, allocator = vmem.arena_allocator(&results))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(tracks), MOCK_LIKED - len(MOCK_UNAVAILABLE))
	testing.expectf(t, count.bytes < 64 * mem.Kilobyte, "%d bytes of scratch for %d tracks", count.bytes, len(tracks))
}
