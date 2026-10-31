package measure

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

import "../../src/os_services"

// OS_LABEL goes before Machine.os when it is printed. On Linux the os
// field holds the distribution's name and version already.
OS_LABEL :: ""

// delete_keychain_item deletes the mock login the runs saved, made for
// this run alone, from the Secret Service.
delete_keychain_item :: proc(service: string) {
	status := os_services.secret_delete(service, "auth")
	if status != os_services.SECRET_OK && status != os_services.SECRET_NOT_FOUND {
		fmt.eprintfln("measure: couldn't delete the secret; secret-tool clear service %s account auth", service)
	}
}

machine :: proc() -> Machine {
	m: Machine
	cpuinfo, _ := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
	m.cpu = strings.clone(field(string(cpuinfo), "model name", ':'))
	model, _ := os.read_entire_file("/sys/devices/virtual/dmi/id/product_name", context.temp_allocator)
	m.model = strings.clone(strings.trim_space(string(model)))
	meminfo, _ := os.read_entire_file("/proc/meminfo", context.temp_allocator)
	kb := strings.trim_space(strings.trim_suffix(field(string(meminfo), "MemTotal", ':'), "kB"))
	n := 0
	for ch in kb {
		if ch >= '0' && ch <= '9' {
			n = n * 10 + int(ch - '0')
		}
	}
	m.memory_gb = f64(n) / (1 << 20)
	release, _ := os.read_entire_file("/etc/os-release", context.temp_allocator)
	m.os = strings.clone(strings.trim(field(string(release), "PRETTY_NAME", '='), `"`))
	uts: linux.UTS_Name
	if linux.uname(&uts) == .NONE {
		m.os_build = strings.clone(string(cstring(&uts.release[0])))
	}
	return m
}

// field finds the line "name<sep> value" in text and returns the value.
@(private = "file")
field :: proc(text, name: string, sep: byte) -> string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		at := strings.index_byte(line, sep)
		if at > 0 && strings.trim_space(line[:at]) == name {
			return strings.trim_space(line[at + 1:])
		}
	}
	return ""
}

// launch_log_default is where the app writes its launch log: the
// TIDALFAST_LAUNCH_LOG it would read, else next to its settings.
launch_log_default :: proc() -> string {
	if p := os.get_env("TIDALFAST_LAUNCH_LOG", context.allocator); p != "" && p != "off" {
		return p
	}
	if dir := os.get_env("XDG_CONFIG_HOME", context.allocator); dir != "" {
		return join(dir, "tidalfast", "launches.jsonl")
	}
	return join(os.get_env("HOME", context.allocator), ".config", "tidalfast", "launches.jsonl")
}

// snapshot_dir_default is where the app writes memory snapshots.
snapshot_dir_default :: proc() -> string {
	if dir := os.get_env("TIDALFAST_SNAPSHOTS", context.allocator); dir != "" {
		return dir
	}
	if dir := os.get_env("XDG_CONFIG_HOME", context.allocator); dir != "" {
		return join(dir, "tidalfast", "snapshots")
	}
	return join(os.get_env("HOME", context.allocator), ".config", "tidalfast", "snapshots")
}
