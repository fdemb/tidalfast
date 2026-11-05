package measure

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"

import "../../src/os_services"

// OS_LABEL goes before Machine.os when it is printed.
OS_LABEL :: "Windows "

EXE_SUFFIX :: ".exe"

// delete_keychain_item deletes the mock login the runs saved, made for
// this run alone, from the Credential Manager.
delete_keychain_item :: proc(service: string) {
	status := os_services.secret_delete(service, "auth")
	if status != os_services.SECRET_OK && status != os_services.SECRET_NOT_FOUND {
		fmt.eprintfln("measure: couldn't delete the credential; cmdkey /delete:%s/auth", service)
	}
}

// stop_windows posts WM_CLOSE to p's windows, which the app's shell turns
// into a clean quit, and kills a process without one, such as the mock.
stop_windows :: proc(p: os.Process) {
	Find :: struct {
		pid:   u32,
		found: bool,
	}
	f := Find{pid = u32(p.pid)}
	win.EnumWindows(proc "system" (hwnd: win.HWND, data: win.LPARAM) -> win.BOOL {
		f := (^Find)(rawptr(uintptr(data)))
		pid: win.DWORD
		win.GetWindowThreadProcessId(hwnd, &pid)
		if pid == f.pid {
			win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0)
			f.found = true
		}
		return true
	}, win.LPARAM(uintptr(&f)))
	if !f.found {
		_ = os.process_kill(p)
	}
}

machine :: proc() -> Machine {
	reg :: proc(key, value: string) -> string {
		buf: [256]u16
		size := win.DWORD(size_of(buf))
		k := win.utf8_to_wstring(key, context.temp_allocator)
		v := win.utf8_to_wstring(value, context.temp_allocator)
		if win.RegGetValueW(win.HKEY_LOCAL_MACHINE, k, v, win.RRF_RT_REG_SZ, nil, &buf[0], &size) != 0 {
			return ""
		}
		s, _ := win.wstring_to_utf8(cstring16(&buf[0]), -1, context.allocator)
		return strings.trim_space(s)
	}
	m: Machine
	m.cpu = reg(`HARDWARE\DESCRIPTION\System\CentralProcessor\0`, "ProcessorNameString")
	m.model = reg(`HARDWARE\DESCRIPTION\System\BIOS`, "SystemProductName")
	mem := win.MEMORYSTATUSEX{dwLength = size_of(win.MEMORYSTATUSEX)}
	if win.GlobalMemoryStatusEx(&mem) {
		m.memory_gb = f64(mem.ullTotalPhys) / (1 << 30)
	}
	NT :: `SOFTWARE\Microsoft\Windows NT\CurrentVersion`
	m.os = reg(NT, "DisplayVersion")
	m.os_build = reg(NT, "CurrentBuild")
	return m
}

// launch_log_default is where the app writes its launch log: the
// TIDALFAST_LAUNCH_LOG it would read, else next to its settings.
launch_log_default :: proc() -> string {
	if p := os.get_env("TIDALFAST_LAUNCH_LOG", context.allocator); p != "" && p != "off" {
		return p
	}
	return join(os.get_env("APPDATA", context.allocator), "tidalfast", "launches.jsonl")
}

// snapshot_dir_default is where the app writes memory snapshots.
snapshot_dir_default :: proc() -> string {
	if dir := os.get_env("TIDALFAST_SNAPSHOTS", context.allocator); dir != "" {
		return dir
	}
	return join(os.get_env("APPDATA", context.allocator), "tidalfast", "snapshots")
}
