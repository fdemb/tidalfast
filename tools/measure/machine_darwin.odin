package measure

import "core:strings"
import "core:sys/unix"

OS_NAME :: "macOS"

machine :: proc() -> Machine {
	str :: proc(name: cstring) -> string {
		buf: [256]u8
		if !unix.sysctlbyname(name, &buf) {
			return ""
		}
		return strings.clone(string(cstring(&buf[0])))
	}
	mem: u64
	unix.sysctlbyname("hw.memsize", &mem)
	return {
		model = str("hw.model"),
		cpu = str("machdep.cpu.brand_string"),
		memory_gb = f64(mem) / (1 << 30),
		os = str("kern.osproductversion"),
		os_build = str("kern.osversion"),
	}
}
