// The few OS services the app needs that aren't windows, drawing or audio:
// a secret store, opening a URL in the default browser and where settings
// and caches go. Each OS has its own file. On Linux the secret store is the
// Secret Service (GNOME Keyring, KWallet) through libsecret, which is opened
// with dlopen the first time it's needed, so neither it nor GLib is loaded
// at startup or required to run. Its sync calls are safe on any thread.
package os_services

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"

Status :: i32

SECRET_OK :: 0
SECRET_NOT_FOUND :: -25300 // the same number as on macOS
SECRET_UNAVAILABLE :: -1 // no libsecret, or no Secret Service running
SECRET_FAILED :: -2 // the Secret Service answered with an error

@(private)
Schema_Attribute :: struct {
	name: cstring,
	type: c.int, // SECRET_SCHEMA_ATTRIBUTE_STRING is 0
}

@(private)
Schema :: struct {
	name:       cstring,
	flags:      c.int,
	attributes: [32]Schema_Attribute,
	reserved:   c.int,
	reserved1:  [7]rawptr,
}

@(private)
GError :: struct {
	domain:  u32,
	code:    c.int,
	message: cstring,
}

@(private)
Libsecret :: struct {
	store:          proc "c" (schema: ^Schema, attributes: rawptr, collection, label: cstring, value: rawptr, cancellable: rawptr, err: ^^GError) -> b32,
	lookup:         proc "c" (schema: ^Schema, attributes: rawptr, cancellable: rawptr, err: ^^GError) -> rawptr,
	clear:          proc "c" (schema: ^Schema, attributes: rawptr, cancellable: rawptr, err: ^^GError) -> b32,
	value_new:      proc "c" (secret: [^]u8, length: int, content_type: cstring) -> rawptr,
	value_get:      proc "c" (value: rawptr, length: ^uint) -> [^]u8,
	value_unref:    proc "c" (value: rawptr),
	hash_table_new: proc "c" (hash, equal: rawptr) -> rawptr,
	hash_insert:    proc "c" (table, key, value: rawptr) -> b32,
	hash_unref:     proc "c" (table: rawptr),
	str_hash:       rawptr,
	str_equal:      rawptr,
	error_free:     proc "c" (err: ^GError),
	ok:             bool,
}

@(private)
libsecret: Libsecret
@(private)
libsecret_once: sync.Once

@(private)
schema := Schema {
	name = "com.tidalfast.Login",
	attributes = {0 = {"service", 0}, 1 = {"account", 0}},
}

@(private)
libsecret_open :: proc() {
	lib := posix.dlopen("libsecret-1.so.0", {.NOW})
	if lib == nil {
		log.warn("os_services: no libsecret, logins won't be saved")
		return
	}
	// GLib is loaded with libsecret, so its symbols come from the same handle.
	sym :: proc(lib: posix.Symbol_Table, name: cstring, ok: ^bool) -> rawptr {
		p := posix.dlsym(lib, name)
		if p == nil {
			ok^ = false
		}
		return p
	}
	ok := true
	l := &libsecret
	l.store = auto_cast sym(lib, "secret_password_storev_binary_sync", &ok)
	l.lookup = auto_cast sym(lib, "secret_password_lookupv_binary_sync", &ok)
	l.clear = auto_cast sym(lib, "secret_password_clearv_sync", &ok)
	l.value_new = auto_cast sym(lib, "secret_value_new", &ok)
	l.value_get = auto_cast sym(lib, "secret_value_get", &ok)
	l.value_unref = auto_cast sym(lib, "secret_value_unref", &ok)
	l.hash_table_new = auto_cast sym(lib, "g_hash_table_new", &ok)
	l.hash_insert = auto_cast sym(lib, "g_hash_table_insert", &ok)
	l.hash_unref = auto_cast sym(lib, "g_hash_table_unref", &ok)
	l.str_hash = sym(lib, "g_str_hash", &ok)
	l.str_equal = sym(lib, "g_str_equal", &ok)
	l.error_free = auto_cast sym(lib, "g_error_free", &ok)
	l.ok = ok
	if !ok {
		log.warn("os_services: libsecret is too old (before 0.19), logins won't be saved")
	}
}

@(private)
attributes :: proc(service, account: string) -> rawptr {
	l := &libsecret
	table := l.hash_table_new(l.str_hash, l.str_equal)
	l.hash_insert(table, rawptr(strings.clone_to_cstring("service", context.temp_allocator)), rawptr(strings.clone_to_cstring(service, context.temp_allocator)))
	l.hash_insert(table, rawptr(strings.clone_to_cstring("account", context.temp_allocator)), rawptr(strings.clone_to_cstring(account, context.temp_allocator)))
	return table
}

// error_status frees err and says what kind of failure it was. A Secret
// Service that isn't running shows up as a D-Bus error, which is logged by
// kind only: the message can carry the item's attributes.
@(private)
error_status :: proc(err: ^GError) -> Status {
	if err == nil {
		return SECRET_FAILED
	}
	log.warnf("os_services: Secret Service error, code %d", err.code)
	libsecret.error_free(err)
	return SECRET_FAILED
}

// secret_set stores data as the item (service, account), replacing the
// item's data if it exists. Returns SECRET_OK on success.
secret_set :: proc(service, account: string, data: []u8) -> Status {
	sync.once_do(&libsecret_once, libsecret_open)
	l := &libsecret
	if !l.ok {
		return SECRET_UNAVAILABLE
	}
	table := attributes(service, account)
	defer l.hash_unref(table)
	value := l.value_new(raw_data(data), len(data), "application/octet-stream")
	defer l.value_unref(value)
	err: ^GError
	if !l.store(&schema, table, nil, "TIDALfast", value, nil, &err) {
		return error_status(err)
	}
	return SECRET_OK
}

// secret_get reads the data of the item (service, account) into
// allocator. Status is SECRET_NOT_FOUND when there is no such item.
secret_get :: proc(service, account: string, allocator := context.allocator) -> (data: []u8, status: Status) {
	sync.once_do(&libsecret_once, libsecret_open)
	l := &libsecret
	if !l.ok {
		return nil, SECRET_UNAVAILABLE
	}
	table := attributes(service, account)
	defer l.hash_unref(table)
	err: ^GError
	value := l.lookup(&schema, table, nil, &err)
	if err != nil {
		return nil, error_status(err)
	}
	if value == nil {
		return nil, SECRET_NOT_FOUND
	}
	defer l.value_unref(value)
	n: uint
	bytes := l.value_get(value, &n)
	data = make([]u8, n, allocator)
	copy(data, bytes[:n])
	return data, SECRET_OK
}

// secret_delete removes the item (service, account). Deleting an item that
// doesn't exist returns SECRET_NOT_FOUND.
secret_delete :: proc(service, account: string) -> Status {
	sync.once_do(&libsecret_once, libsecret_open)
	l := &libsecret
	if !l.ok {
		return SECRET_UNAVAILABLE
	}
	table := attributes(service, account)
	defer l.hash_unref(table)
	err: ^GError
	if !l.clear(&schema, table, nil, &err) {
		return SECRET_NOT_FOUND if err == nil else error_status(err)
	}
	return SECRET_OK
}

// open_url opens url in the default browser with xdg-open. A URL without a
// scheme gets https://, and any scheme but http and https is refused.
open_url :: proc(url: string) -> bool {
	full := url if strings.contains(url, "://") else strings.concatenate({"https://", url}, context.temp_allocator)
	if !strings.has_prefix(full, "https://") && !strings.has_prefix(full, "http://") {
		log.warn("os_services: not opening a URL that isn't http or https")
		return false
	}
	argv := [3]cstring{"xdg-open", strings.clone_to_cstring(full, context.temp_allocator), nil}
	return spawn_detached(argv[:])
}

// spawn_detached runs argv, which ends in nil, with the default signal
// mask and SIGPIPE back to default: the shell blocks the quit signals for
// its signalfd and ignores SIGPIPE, and both would survive exec. The child
// forks again and exits, so the program runs on as an orphan and leaves no
// zombie behind. False if a fork or the exec fails: the grandchild writes
// exec's errno to a close-on-exec pipe, which a successful exec closes
// empty.
spawn_detached :: proc(argv: []cstring) -> bool {
	fds: [2]linux.Fd
	if err := linux.pipe2(&fds, {.CLOEXEC}); err != .NONE {
		log.warnf("os_services: couldn't make a pipe for %s: %v", argv[0], err)
		return false
	}
	read_end, write_end := posix.FD(fds[0]), posix.FD(fds[1])
	pid := posix.fork()
	if pid == 0 {
		grandchild := posix.fork()
		if grandchild == 0 {
			none: posix.sigset_t
			posix.sigemptyset(&none)
			posix.pthread_sigmask(.SETMASK, &none, nil)
			posix.signal(.SIGPIPE, nil) // SIG_DFL
			posix.execvp(argv[0], raw_data(argv))
			err := posix.errno()
			posix.write(write_end, ([^]byte)(&err), size_of(err))
			posix._exit(127)
		}
		posix._exit(0 if grandchild > 0 else 1)
	}
	if pid < 0 {
		log.warnf("os_services: couldn't fork for %s: %v", argv[0], posix.errno())
		posix.close(read_end)
		posix.close(write_end)
		return false
	}
	posix.close(write_end)
	defer posix.close(read_end)
	status: c.int
	waited := posix.waitpid(pid, &status, {})
	for waited < 0 && posix.errno() == .EINTR {
		waited = posix.waitpid(pid, &status, {})
	}
	if waited < 0 {
		log.warnf("os_services: couldn't wait for %s: %v", argv[0], posix.errno())
		return false
	}
	if !posix.WIFEXITED(status) || posix.WEXITSTATUS(status) != 0 {
		log.warnf("os_services: couldn't fork for %s", argv[0])
		return false
	}
	err: posix.Errno
	n := posix.read(read_end, ([^]byte)(&err), size_of(err))
	for n < 0 && posix.errno() == .EINTR {
		n = posix.read(read_end, ([^]byte)(&err), size_of(err))
	}
	switch {
	case n == size_of(err):
		log.warnf("os_services: %s didn't start: %v", argv[0], err)
		return false
	case n < 0:
		log.warnf("os_services: couldn't tell if %s started: %v", argv[0], posix.errno())
		return false
	}
	return true
}

// config_dir is where settings go: $XDG_CONFIG_HOME, or ~/.config. Empty
// without either.
config_dir :: proc(allocator: runtime.Allocator) -> string {
	return xdg_dir("XDG_CONFIG_HOME", "/.config", allocator)
}

// cache_dir is where caches go: $XDG_CACHE_HOME, or ~/.cache. Empty
// without either.
cache_dir :: proc(allocator: runtime.Allocator) -> string {
	return xdg_dir("XDG_CACHE_HOME", "/.cache", allocator)
}

@(private)
xdg_dir :: proc(variable, home_relative: string, allocator: runtime.Allocator) -> string {
	// The spec says to ignore a relative path.
	if dir := os.get_env(variable, context.temp_allocator); strings.has_prefix(dir, "/") {
		return strings.clone(dir, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	return strings.concatenate({home, home_relative}, allocator)
}
