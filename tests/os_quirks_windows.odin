package tidal_tests

import "base:intrinsics"
import "core:testing"

import win32 "core:sys/windows"

// local_time asks Windows for the system's time zone, which only an
// administrator can change, so TZ doesn't reach it.
CAN_SET_TIME_ZONE :: false

// SetEnvironmentVariableW with "" deletes the variable.
CAN_SET_EMPTY_ENV :: false

reset_time_zone :: proc() {}

// hold_on_assert keeps the calling test's thread on an assert until the
// runner stops it, as the runner's own handler does on POSIX. On Windows
// the runner's exception handler notes the assert and lets the exception
// go on, and Windows ends the process unless the runner stops the thread
// first, which it often doesn't with every core busy. This handler, added
// after the runner's, is called after it.
hold_on_assert :: proc(t: ^testing.T) {
	intrinsics.atomic_store(&held_thread, win32.GetCurrentThreadId())
	handler := win32.AddVectoredExceptionHandler(0, hold_thread)
	testing.cleanup(t, proc(handler: rawptr) {
		win32.RemoveVectoredExceptionHandler(handler)
		intrinsics.atomic_store(&held_thread, 0)
	}, handler)
}

@(private = "file")
held_thread: win32.DWORD

@(private = "file")
hold_thread :: proc "system" (info: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
	if info.ExceptionRecord.ExceptionCode == win32.EXCEPTION_ILLEGAL_INSTRUCTION && win32.GetCurrentThreadId() == intrinsics.atomic_load(&held_thread) {
		for {
			win32.Sleep(win32.INFINITE)
		}
	}
	return win32.EXCEPTION_CONTINUE_SEARCH
}
