package os_services

// The desktop's settings through the XDG desktop portal's Settings
// interface, as GTK reads them inside Flatpak: GNOME's window button
// layout, for one. A D-Bus client of its own over the session bus's
// socket, just big enough for a read and the SettingChanged signal, so
// that neither libdbus nor GLib is loaded for it. portal_setting_string
// blocks for up to PORTAL_TIMEOUT_MS and portal_setting_watch for as long
// as the bus is there, so call them off the UI thread.

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
DBUS_SIGNAL :: 4

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

// The longest message read whole. Longer ones are read and dropped.
@(private = "file")
MESSAGE_MAX :: 8 << 10

// portal_setting_string reads the string setting key in namespace, such
// as "org.gnome.desktop.wm.preferences" and "button-layout". ok is false
// without a session bus or a portal, or when the portal has no such
// string.
portal_setting_string :: proc(namespace, key: string, allocator := context.allocator) -> (value: string, ok: bool) {
	fd := bus_connect() or_return
	defer posix.close(fd)
	buf: [MESSAGE_MAX]u8
	s := read_setting(fd, namespace, key, buf[:]) or_return
	return strings.clone(s, allocator), true
}

// portal_setting_watch gives changed the string setting as
// portal_setting_string reads it, and then each new value the portal's
// SettingChanged signal brings, blocked on the bus's socket in between.
// It returns when the connection ends, and at once, without calling
// changed, when there is no session bus or the portal has no such string.
portal_setting_watch :: proc(namespace, key: string, changed: proc(value: string, user: rawptr), user: rawptr) {
	fd, connected := bus_connect()
	if !connected {
		return
	}
	defer posix.close(fd)
	buf: [MESSAGE_MAX]u8
	value, read := read_setting(fd, namespace, key, buf[:])
	if !read {
		return
	}
	changed(value, user)
	// The bus then sends only the portal's signals for this one setting.
	rule := fmt.tprintf(
		"type='signal',sender='org.freedesktop.portal.Desktop',path='/org/freedesktop/portal/desktop',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='%s',arg1='%s'",
		namespace,
		key,
	)
	body := make([dynamic]u8, context.temp_allocator)
	put_string(&body, rule)
	if !send_all(fd, dbus_call(4, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", body[:])) {
		return
	}
	forever: posix.timeval
	posix.setsockopt(fd, posix.SOL_SOCKET, .RCVTIMEO, &forever, size_of(forever))
	for {
		msg := read_message(fd, buf[:]) or_break
		ns, k, v, is_change := setting_changed(msg)
		if is_change && ns == namespace && k == key {
			changed(v, user)
		}
	}
}

// read_setting asks the portal for a string setting on a connection that
// has just authenticated. The value is in buf.
@(private = "file")
read_setting :: proc(fd: posix.FD, namespace, key: string, buf: []u8) -> (value: string, ok: bool) {
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
		reply, kind := read_reply(fd, serial, buf) or_return
		if kind == DBUS_RETURN {
			return variant_string(reply)
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

// read_message reads the next message into buf. One too long for buf, or
// in big-endian order, is read and dropped, and comes back empty.
@(private = "file")
read_message :: proc(fd: posix.FD, buf: []u8) -> (msg: []u8, ok: bool) {
	head: [16]u8
	recv_all(fd, head[:]) or_return
	order: endian.Byte_Order
	switch head[0] {
	case 'l':
		order = .Little
	case 'B':
		order = .Big
	case:
		return nil, false
	}
	body_len, _ := endian.get_u32(head[4:8], order)
	fields_len, _ := endian.get_u32(head[12:16], order)
	total := 16 + align(int(fields_len), 8) + int(body_len)
	if total > 1 << 27 {
		return nil, false
	}
	if total > len(buf) || order != .Little {
		for left := total - 16; left > 0; {
			n := min(left, len(buf))
			recv_all(fd, buf[:n]) or_return
			left -= n
		}
		return buf[:0], true
	}
	copy(buf, head[:])
	recv_all(fd, buf[16:total]) or_return
	return buf[:total], true
}

// read_reply reads messages until the return or error for serial, and
// gives its body. Others, such as Hello's return and the NameAcquired
// signal, are skipped.
@(private = "file")
read_reply :: proc(fd: posix.FD, serial: u32, buf: []u8) -> (body: Dbus_Body, kind: u8, ok: bool) {
	for _ in 0 ..< 16 {
		msg := read_message(fd, buf) or_return
		if len(msg) == 0 {
			continue
		}
		h := header_fields(msg) or_return
		if (msg[1] == DBUS_RETURN || msg[1] == DBUS_ERROR) && h.reply_serial == serial {
			return h.body, msg[1], true
		}
	}
	return {}, 0, false
}

// setting_changed reads a message that is the portal's SettingChanged
// signal: the setting's namespace and key, and its new value when that is
// a string. ok is false for any other message.
setting_changed :: proc(msg: []u8) -> (namespace, key, value: string, ok: bool) {
	if len(msg) < 16 || msg[0] != 'l' || msg[1] != DBUS_SIGNAL {
		return
	}
	h := header_fields(msg) or_return
	if h.interface != "org.freedesktop.portal.Settings" || h.member != "SettingChanged" || h.body.signature != "ssv" {
		return
	}
	b := h.body.data
	off := 0
	namespace = body_string(b, &off) or_return
	key = body_string(b, &off) or_return
	value = variant_string_at(b, off) or_return
	return namespace, key, value, true
}

Dbus_Body :: struct {
	data:      []u8,
	signature: string,
}

@(private = "file")
Header :: struct {
	reply_serial: u32,
	interface:    string,
	member:       string,
	body:         Dbus_Body,
}

// header_fields reads the fields of a whole message's header that the
// client looks at, and finds its body.
@(private = "file")
header_fields :: proc(msg: []u8) -> (h: Header, ok: bool) {
	fields_len, _ := endian.get_u32(msg[12:16], .Little)
	if int(fields_len) > len(msg) - 16 {
		return {}, false
	}
	header := msg[:16 + int(fields_len)]
	off := 16
	for off < len(header) {
		off = align(off, 8)
		if off + 2 > len(header) {
			return {}, false
		}
		code := header[off]
		sig_len := int(header[off + 1])
		if off + 2 + sig_len + 1 > len(header) {
			return {}, false
		}
		sig := string(header[off + 2:off + 2 + sig_len])
		off += 2 + sig_len + 1
		switch sig {
		case "u":
			off = align(off, 4)
			if off + 4 > len(header) {
				return {}, false
			}
			v, _ := endian.get_u32(header[off:off + 4], .Little)
			if code == FIELD_REPLY_SERIAL {
				h.reply_serial = v
			}
			off += 4
		case "s", "o":
			s := body_string(header, &off) or_return
			if code == FIELD_INTERFACE {
				h.interface = s
			} else if code == FIELD_MEMBER {
				h.member = s
			}
		case "g":
			if off >= len(header) {
				return {}, false
			}
			n := int(header[off])
			if off + 1 + n + 1 > len(header) {
				return {}, false
			}
			if code == FIELD_SIGNATURE {
				h.body.signature = string(header[off + 1:off + 1 + n])
			}
			off += 1 + n + 1
		case:
			return {}, false
		}
	}
	start := align(len(header), 8)
	if start > len(msg) {
		return {}, false
	}
	h.body.data = msg[start:]
	return h, true
}

// body_string is the string at off in b, which it moves past it.
@(private = "file")
body_string :: proc(b: []u8, off: ^int) -> (s: string, ok: bool) {
	o := align(off^, 4)
	if o + 4 > len(b) {
		return "", false
	}
	n, _ := endian.get_u32(b[o:o + 4], .Little)
	o += 4
	if int(n) > len(b) - o - 1 || b[o + int(n)] != 0 {
		return "", false
	}
	off^ = o + int(n) + 1
	return string(b[o:o + int(n)]), true
}

// variant_string is the string in a body that is a variant, unwrapping
// variants inside it.
variant_string :: proc(body: Dbus_Body) -> (value: string, ok: bool) {
	if body.signature != "v" {
		return "", false
	}
	return variant_string_at(body.data, 0)
}

// variant_string_at is the string in the variant at start in a body b,
// unwrapping variants inside it.
@(private = "file")
variant_string_at :: proc(b: []u8, start: int) -> (value: string, ok: bool) {
	off := start
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
			return body_string(b, &off)
		case:
			return "", false
		}
	}
	return "", false
}

// dbus_call is a method call message with the body given, which has
// signature.
dbus_call :: proc(serial: u32, destination, path, interface, member, signature: string, body: []u8) -> []u8 {
	return dbus_message(DBUS_CALL, serial, destination, path, interface, member, signature, body)
}

// dbus_setting_changed is the portal's SettingChanged signal for a
// string setting, as the bus delivers it.
dbus_setting_changed :: proc(serial: u32, namespace, key, value: string) -> []u8 {
	body := make([dynamic]u8, context.temp_allocator)
	put_string(&body, namespace)
	put_string(&body, key)
	put_signature(&body, "s")
	put_string(&body, value)
	return dbus_message(DBUS_SIGNAL, serial, "", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", "ssv", body[:])
}

@(private = "file")
dbus_message :: proc(kind: u8, serial: u32, destination, path, interface, member, signature: string, body: []u8) -> []u8 {
	m := make([dynamic]u8, context.temp_allocator)
	append(&m, 'l', kind, 0, 1)
	put_u32(&m, u32(len(body)))
	put_u32(&m, serial)
	put_u32(&m, 0) // the fields' length, below
	header_field(&m, FIELD_PATH, "o", path)
	header_field(&m, FIELD_INTERFACE, "s", interface)
	header_field(&m, FIELD_MEMBER, "s", member)
	if destination != "" {
		header_field(&m, FIELD_DESTINATION, "s", destination)
	}
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
