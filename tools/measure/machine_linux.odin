package measure

import "core:os"
import "core:strings"
import "core:sys/posix"

OS_NAME :: "Linux"

// machine reads the CPU from /proc/cpuinfo, the memory from /proc/meminfo
// and the kernel from uname. Linux has no model name, so model is the
// architecture.
machine :: proc() -> Machine {
	field :: proc(path, name: string) -> string {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return ""
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			key, _, value := strings.partition(line, ":")
			if strings.trim_space(key) == name {
				return strings.clone(strings.trim_space(value))
			}
		}
		return ""
	}
	kb := field("/proc/meminfo", "MemTotal")
	mem_kb := 0
	for c in kb {
		if c < '0' || c > '9' {
			break
		}
		mem_kb = mem_kb * 10 + int(c - '0')
	}
	u: posix.utsname
	posix.uname(&u)
	return {
		model = strings.clone(string(cstring(&u.machine[0]))),
		cpu = field("/proc/cpuinfo", "model name"),
		memory_gb = f64(mem_kb) / (1 << 20),
		os = strings.clone(string(cstring(&u.release[0]))),
		os_build = strings.clone(string(cstring(&u.version[0]))),
	}
}
