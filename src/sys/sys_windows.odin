#+build windows
package sys

import "base:runtime"
import "core:c/libc"
import "core:sys/windows"

Thread :: windows.HANDLE

@(private)
Thread_Start :: struct {
	entry: Thread_Proc,
	arg:   rawptr,
}

// thread_start runs entry(arg) on a new thread. False if it couldn't.
thread_start :: proc(t: ^Thread, entry: Thread_Proc, arg: rawptr) -> bool {
	start := new(Thread_Start, runtime.heap_allocator())
	start^ = {entry, arg}
	t^ = windows.CreateThread(nil, 0, thread_main, start, 0, nil)
	if t^ == nil {
		free(start, runtime.heap_allocator())
		return false
	}
	return true
}

@(private)
thread_main :: proc "system" (arg: rawptr) -> windows.DWORD {
	start := (^Thread_Start)(arg)^
	context = runtime.default_context()
	free(arg, runtime.heap_allocator())
	start.entry(start.arg)
	return 0
}

// thread_join waits for t to return.
thread_join :: proc(t: Thread) {
	windows.WaitForSingleObject(t, windows.INFINITE)
	windows.CloseHandle(t)
}

// local_time is unix seconds in the user's time zone. ok is false if the
// OS couldn't say.
local_time :: proc(unix_seconds: i64) -> (lt: Local_Time, ok: bool) {
	// FILETIME counts 100 ns from 1601.
	ticks := u64(unix_seconds + 11_644_473_600) * 10_000_000
	ft := windows.FILETIME{windows.DWORD(ticks), windows.DWORD(ticks >> 32)}
	utc, local: windows.SYSTEMTIME
	if !windows.FileTimeToSystemTime(&ft, &utc) || !windows.SystemTimeToTzSpecificLocalTime(nil, &utc, &local) {
		return
	}
	return {
			year = int(local.year),
			month = int(local.month),
			day = int(local.day),
			hour = int(local.hour),
			minute = int(local.minute),
			second = int(local.second),
		},
		true
}

page_size :: proc "contextless" () -> int {
	info: windows.SYSTEM_INFO
	windows.GetSystemInfo(&info)
	return int(info.dwPageSize)
}

// map_file maps the file at path (UTF-8) read-only. Its bytes stay valid
// until unmap_file, after the file itself is closed.
map_file :: proc(path: cstring) -> ([]byte, bool) {
	wide := windows.utf8_to_wstring(string(path), context.temp_allocator)
	file := windows.CreateFileW(wide, windows.GENERIC_READ, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, nil)
	if file == windows.INVALID_HANDLE_VALUE {
		return nil, false
	}
	defer windows.CloseHandle(file)
	size: windows.LARGE_INTEGER
	if !windows.GetFileSizeEx(file, &size) || size <= 0 {
		return nil, false
	}
	mapping := windows.CreateFileMappingW(file, nil, windows.PAGE_READONLY, 0, 0, nil)
	if mapping == nil {
		return nil, false
	}
	defer windows.CloseHandle(mapping)
	p := windows.MapViewOfFile(mapping, windows.FILE_MAP_READ, 0, 0, 0)
	if p == nil {
		return nil, false
	}
	return ([^]byte)(p)[:size], true
}

unmap_file :: proc(data: []byte) {
	windows.UnmapViewOfFile(raw_data(data))
}

foreign import psapi "system:Psapi.lib"

@(private)
@(default_calling_convention = "system")
foreign psapi {
	QueryWorkingSetEx :: proc(process: windows.HANDLE, info: rawptr, size: u32) -> windows.BOOL ---
}

// PSAPI_WORKING_SET_EX_INFORMATION: an address and its page's flags, of
// which bit 0 says the page is in the working set.
@(private)
Working_Set_Ex :: struct {
	address: rawptr,
	flags:   uintptr,
}

// page_flags fills flags with a byte for each of the pages at start,
// page-aligned: bit 0 set for a page in RAM, as mincore does. False if it
// couldn't.
page_flags :: proc "contextless" (start: rawptr, flags: []u8) -> bool {
	page := uintptr(page_size())
	info: [1024]Working_Set_Ex
	for done := 0; done < len(flags); done += len(info) {
		n := min(len(flags) - done, len(info))
		for i in 0 ..< n {
			info[i] = {address = rawptr(uintptr(start) + uintptr(done + i) * page)}
		}
		if !QueryWorkingSetEx(windows.GetCurrentProcess(), &info[0], u32(n * size_of(Working_Set_Ex))) {
			return false
		}
		for i in 0 ..< n {
			flags[done + i] = u8(info[i].flags & 1)
		}
	}
	return true
}

// write_stderr writes b with one call, so lines written from different
// threads don't interleave.
write_stderr :: proc "contextless" (b: []byte) {
	written: windows.DWORD
	windows.WriteFile(windows.GetStdHandle(windows.STD_ERROR_HANDLE), raw_data(b), windows.DWORD(len(b)), &written, nil)
}

// quit asks the shell to quit the way Ctrl-C does, so the app's shutdown
// runs. The CRT runs the shell's SIGTERM handler on this thread, and the
// handler only wakes the shell's loop.
quit :: proc "contextless" () {
	libc.raise(libc.SIGTERM)
}
