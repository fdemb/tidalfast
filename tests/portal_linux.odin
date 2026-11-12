package tidal_tests

// The few D-Bus messages the app sends and reads to ask the XDG desktop
// portal for a setting (src/os_services/portal_linux.odin).

import "core:encoding/endian"
import "core:testing"

import "../src/os_services"

@(test)
bus_address_finds_the_socket :: proc(t: ^testing.T) {
	path, abstract, ok := os_services.bus_path("unix:path=/run/user/1000/bus")
	testing.expect(t, ok && !abstract)
	testing.expect_value(t, path, "/run/user/1000/bus")
	path, abstract, ok = os_services.bus_path("tcp:host=x,port=1;unix:abstract=/tmp/dbus-AbC,guid=0123")
	testing.expect(t, ok && abstract)
	testing.expect_value(t, path, "/tmp/dbus-AbC")
	_, _, ok = os_services.bus_path("tcp:host=localhost,port=1234")
	testing.expect(t, !ok)
	_, _, ok = os_services.bus_path("")
	testing.expect(t, !ok)
}

// ReadOne answers a variant holding the value; Read, on portals before
// 2023, one more variant around it.
@(test)
portal_reply_gives_the_string :: proc(t: ^testing.T) {
	for depth in 0 ..< 2 {
		body := os_services.dbus_variant_body("appmenu:close", depth)
		value, ok := os_services.variant_string({body, "v"})
		testing.expect(t, ok)
		testing.expect_value(t, value, "appmenu:close")
		// Cut short anywhere, it fails instead of reading past the end.
		for n in 0 ..< len(body) {
			_, cut_ok := os_services.variant_string({body[:n], "v"})
			testing.expectf(t, !cut_ok, "a body cut to %d bytes", n)
		}
	}
	_, ok := os_services.variant_string({os_services.dbus_variant_body("x"), "s"})
	testing.expect(t, !ok, "a body that isn't a variant")
}

// A method call is laid out as the D-Bus spec says: the fixed header, the
// fields padded to 8, the body after them, its length in the header.
@(test)
dbus_call_has_the_spec_layout :: proc(t: ^testing.T) {
	body := []u8{1, 2, 3, 4}
	m := os_services.dbus_call(7, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "ReadOne", "ss", body)
	testing.expect_value(t, m[0], 'l')
	testing.expect_value(t, m[1], 1)
	testing.expect_value(t, m[3], 1)
	body_len, _ := endian.get_u32(m[4:8], .Little)
	serial, _ := endian.get_u32(m[8:12], .Little)
	fields_len, _ := endian.get_u32(m[12:16], .Little)
	testing.expect_value(t, body_len, 4)
	testing.expect_value(t, serial, 7)
	start := (16 + int(fields_len) + 7) &~ 7
	testing.expect_value(t, len(m), start + 4)
	testing.expect_value(t, m[start:][0], 1)
	// The path field comes first: code 1, signature "o", then the string.
	testing.expect_value(t, m[16], 1)
	testing.expect_value(t, string(m[17:20]), "\x01o\x00")
	n, _ := endian.get_u32(m[20:24], .Little)
	testing.expect_value(t, string(m[24:24 + n]), "/org/freedesktop/portal/desktop")
}
