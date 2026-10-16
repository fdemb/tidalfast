package measure

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/unix"
import "core:time"

// OS_LABEL goes before Machine.os when it is printed.
OS_LABEL :: "macOS "

// delete_keychain_item deletes the mock login the runs saved, made for
// this run alone. SecItemDelete from this program gets -25244, since the
// item's access list names the app; the security tool may delete it.
delete_keychain_item :: proc(service: string) {
	p, err := os.process_start({command = {"/usr/bin/security", "delete-generic-password", "-s", service, "-a", "auth"}})
	if err == nil {
		if state, werr := os.process_wait(p, 10 * time.Second); werr == nil && state.exit_code == 0 {
			return
		}
	}
	fmt.eprintfln("measure: couldn't delete the Keychain item; security delete-generic-password -s %s", service)
}

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
