package os_services

// The desktop's settings through the XDG desktop portal's Settings
// interface, as GTK reads them inside Flatpak: GNOME's window button
// layout, for one. A D-Bus client of its own over the session bus's
// socket, just big enough for one call, so that neither libdbus nor GLib
// is loaded for it. It blocks for up to PORTAL_TIMEOUT_MS, so call it off
// the UI thread.

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// The bus starts the portal for the call when it isn't running, which
// can take a moment on a cold start.
PORTAL_TIMEOUT_MS :: 3000

@(private = "file")
DBUS_CALL :: 1
@(private = "file")
DBUS_RETURN :: 2
@(private = "file")
DBUS_ERROR :: 3

@(private = "file")
FIELD_PATH :: 1
@(private = "file")
FIELD_INTERFACE :: 2
@(private = "file")
FIELD_MEMBER :: 3
@(private = "file")
FIELD_REPLY_SERIAL :: 5
@(private = "file")
FIELD_DESTINATION :: 6
@(private = "file")
FIELD_SIGNATURE :: 8

// portal_setting_string reads the string setting key in namespace, such
// as "org.gnome.desktop.wm.preferences" and "button-layout". ok is false
// without a session bus or a portal, or when the portal has no such
// string.
portal_setting_string :: proc(namespace, key: string, allocator := context.allocator) -> (value: string, ok: bool) {
	fd := bus_connect() or_return
	defer posix.close(fd)
	body := make([dynamic]u8, context.temp_allocator)
	put_string(&body, namespace)
	put_string(&body, key)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, "BEGIN\r\n")
	append(&out, ..dbus_call(1, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", nil))
	// ReadOne came with version 2 of the interface, in 2023. Read, which
	// every version has, wraps the value in one variant too many.
	for member, i in ([2]string{"ReadOne", "Read"}) {
		serial := u32(2 + i)
		append(&out, ..dbus_call(serial, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", member, "ss", body[:]))
		send_all(fd, out[:]) or_return
		clear(&out)
		reply, kind := read_reply(fd, serial) or_return
		if kind == DBUS_RETURN {
			s := variant_string(reply) or_return
			return strings.clone(s, allocator), true
		}
	}
	return "", false
}

// bus_connect connects to the session bus and authenticates, up to the
// BEGIN, which goes with the first message.
@(private = "file")
bus_connect :: proc() -> (fd: posix.FD, ok: bool) {
	address := os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator)
	if address == "" {
		if runtime_dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); runtime_dir != "" {
			address = fmt.tprintf("unix:path=%s/bus", runtime_dir)
		}
	}
	path, abstract := bus_path(address) or_return
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	start := 1 if abstract else 0
	if start + len(path) >= len(addr.sun_path) {
		return -1, false
	}
	for i in 0 ..< len(path) {
		addr.sun_path[start + i] = c.char(path[i])
	}
	addr_len := posix.socklen_t(int(offset_of(posix.sockaddr_un, sun_path)) + start + len(path) + (0 if abstract else 1))
	fd = posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1, false
	}
	timeout := posix.timeval {
		tv_sec  = PORTAL_TIMEOUT_MS / 1000,
		tv_usec = (PORTAL_TIMEOUT_MS % 1000) * 1000,
	}
	posix.setsockopt(fd, posix.SOL_SOCKET, .RCVTIMEO, &timeout, size_of(timeout))
	posix.setsockopt(fd, posix.SOL_SOCKET, .SNDTIMEO, &timeout, size_of(timeout))
	if posix.connect(fd, (^posix.sockaddr)(&addr), addr_len) != .OK {
		posix.close(fd)
		return -1, false
	}
	// EXTERNAL: the uid in decimal, hex-encoded, which the bus checks
	// against the socket's credentials.
	uid := fmt.tprint(posix.getuid())
	hello := strings.builder_make(context.temp_allocator)
	strings.write_string(&hello, "\x00AUTH EXTERNAL ")
	for i in 0 ..< len(uid) {
		fmt.sbprintf(&hello, "%02x", uid[i])
	}
	strings.write_string(&hello, "\r\n")
	if !send_all(fd, transmute([]u8)strings.to_string(hello)) {
		posix.close(fd)
		return -1, false
	}
	line: [256]u8
	n := 0
	for n < len(line) {
		if posix.recv(fd, &line[n], 1, {}) != 1 {
			break
		}
		n += 1
		if n >= 2 && line[n - 2] == '\r' && line[n - 1] == '\n' {
			break
		}
	}
	if !strings.has_prefix(string(line[:n]), "OK ") {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

// bus_path is the socket of the first unix address in a D-Bus address
// list, such as "unix:path=/run/user/1000/bus" or
// "unix:abstract=/tmp/dbus-x,guid=...".
bus_path :: proc(address: string) -> (path: string, abstract: bool, ok: bool) {
	rest := address
	for entry in strings.split_iterator(&rest, ";") {
		if !strings.has_prefix(entry, "unix:") {
			continue
		}
		params := entry[len("unix:"):]
		for param in strings.split_iterator(&params, ",") {
			if strings.has_prefix(param, "path=") {
				return param[len("path="):], false, true
			}
			if strings.has_prefix(param, "abstract=") {
				return param[len("abstract="):], true, true
			}
		}
	}
	return "", false, false
}

@(private = "file")
send_all :: proc(fd: posix.FD, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n := posix.send(fd, raw_data(data[sent:]), uint(len(data)) - uint(sent), {.NOSIGNAL})
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

@(private = "file")
recv_all :: proc(fd: posix.FD, data: []u8) -> bool {
	got := 0
	for got < len(data) {
		n := posix.recv(fd, raw_data(data[got:]), uint(len(data)) - uint(got), {})
		if n <= 0 {
			return false
		}
		got += int(n)
	}
	return true
}

// read_reply reads messages until the return or error for serial, and
// gives its body. Others, such as Hello's return and the NameAcquired
// signal, are skipped.
@(private = "file")
read_reply :: proc(fd: posix.FD, serial: u32) -> (body: Dbus_Body, kind: u8, ok: bool) {
	for _ in 0 ..< 16 {
		head: [16]u8
		recv_all(fd, head[:]) or_return
		if head[0] != 'l' {
			return {}, 0, false
		}
		body_len, _ := endian.get_u32(head[4:8], .Little)
		fields_len, _ := endian.get_u32(head[12:16], .Little)
		total := 16 + align(int(fields_len), 8) + int(body_len)
		if total > 1 << 20 {
			return {}, 0, false
		}
		msg := make([]u8, total, context.temp_allocator)
		copy(msg, head[:])
		recv_all(fd, msg[16:]) or_return
		reply_serial, signature, parsed := header_fields(msg[:16 + int(fields_len)])
		if !parsed {
			return {}, 0, false
		}
		if (msg[1] == DBUS_RETURN || msg[1] == DBUS_ERROR) && reply_serial == serial {
			return {msg[16 + align(int(fields_len), 8):], signature}, msg[1], true
		}
	}
	return {}, 0, false
}

Dbus_Body :: struct {
	data:      []u8,
	signature: string,
}

// header_fields finds the reply serial and the body's signature in a
// message's header.
@(private = "file")
header_fields :: proc(header: []u8) -> (reply_serial: u32, signature: string, ok: bool) {
	off := 16
	for off < len(header) {
		off = align(off, 8)
		if off + 2 > len(header) {
			return 0, "", false
		}
		code := header[off]
		sig_len := int(header[off + 1])
		if off + 2 + sig_len + 1 > len(header) {
			return 0, "", false
		}
		sig := string(header[off + 2:off + 2 + sig_len])
		off += 2 + sig_len + 1
		switch sig {
		case "u":
			off = align(off, 4)
			if off + 4 > len(header) {
				return 0, "", false
			}
			v, _ := endian.get_u32(header[off:off + 4], .Little)
			if code == FIELD_REPLY_SERIAL {
				reply_serial = v
			}
			off += 4
		case "s", "o":
			off = align(off, 4)
			if off + 4 > len(header) {
				return 0, "", false
			}
			n, _ := endian.get_u32(header[off:off + 4], .Little)
			off += 4 + int(n) + 1
		case "g":
			if off >= len(header) {
				return 0, "", false
			}
			n := int(header[off])
			if code == FIELD_SIGNATURE && off + 1 + n <= len(header) {
				signature = string(header[off + 1:off + 1 + n])
			}
			off += 1 + n + 1
		case:
			return 0, "", false
		}
	}
	return reply_serial, signature, true
}

// variant_string is the string in a body that is a variant, unwrapping
// variants inside it.
variant_string :: proc(body: Dbus_Body) -> (value: string, ok: bool) {
	if body.signature != "v" {
		return "", false
	}
	b := body.data
	off := 0
	for _ in 0 ..< 4 {
		if off >= len(b) {
			return "", false
		}
		n := int(b[off])
		if off + 1 + n + 1 > len(b) {
			return "", false
		}
		sig := string(b[off + 1:off + 1 + n])
		off += 1 + n + 1
		switch sig {
		case "v":
			continue
		case "s":
			off = align(off, 4)
			if off + 4 > len(b) {
				return "", false
			}
			length, _ := endian.get_u32(b[off:off + 4], .Little)
			off += 4
			if off + int(length) + 1 > len(b) || b[off + int(length)] != 0 {
				return "", false
			}
			return string(b[off:off + int(length)]), true
		case:
			return "", false
		}
	}
	return "", false
}

// dbus_call is a method call message with the body given, which has
// signature.
dbus_call :: proc(serial: u32, destination, path, interface, member, signature: string, body: []u8) -> []u8 {
	m := make([dynamic]u8, context.temp_allocator)
	append(&m, 'l', DBUS_CALL, 0, 1)
	put_u32(&m, u32(len(body)))
	put_u32(&m, serial)
	put_u32(&m, 0) // the fields' length, below
	header_field(&m, FIELD_PATH, "o", path)
	header_field(&m, FIELD_INTERFACE, "s", interface)
	header_field(&m, FIELD_MEMBER, "s", member)
	header_field(&m, FIELD_DESTINATION, "s", destination)
	if signature != "" {
		header_field(&m, FIELD_SIGNATURE, "g", signature)
	}
	endian.put_u32(m[12:16], .Little, u32(len(m) - 16))
	pad(&m, 8)
	append(&m, ..body)
	return m[:]
}

// dbus_variant_body is a body of one variant holding a string, as a
// Settings call returns it, wrapped in depth more variants.
dbus_variant_body :: proc(value: string, depth := 0) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< depth {
		put_signature(&b, "v")
	}
	put_signature(&b, "s")
	put_string(&b, value)
	return b[:]
}

@(private = "file")
header_field :: proc(m: ^[dynamic]u8, code: u8, sig: string, value: string) {
	pad(m, 8)
	append(m, code)
	put_signature(m, sig)
	if sig == "g" {
		put_signature(m, value)
	} else {
		put_string(m, value)
	}
}

@(private = "file")
align :: proc(n, to: int) -> int {
	return (n + to - 1) &~ (to - 1)
}

@(private = "file")
pad :: proc(m: ^[dynamic]u8, to: int) {
	for len(m) % to != 0 {
		append(m, 0)
	}
}

@(private = "file")
put_u32 :: proc(m: ^[dynamic]u8, v: u32) {
	pad(m, 4)
	b: [4]u8
	endian.put_u32(b[:], .Little, v)
	append(m, ..b[:])
}

@(private = "file")
put_string :: proc(m: ^[dynamic]u8, s: string) {
	put_u32(m, u32(len(s)))
	append(m, s)
	append(m, 0)
}

@(private = "file")
put_signature :: proc(m: ^[dynamic]u8, s: string) {
	append(m, u8(len(s)))
	append(m, s)
	append(m, 0)
}
