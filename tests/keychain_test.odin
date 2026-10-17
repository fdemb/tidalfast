package tidal_tests

import "core:crypto"
import "core:fmt"
import "core:testing"

import app "../src/app"
import "../src/os_services"

// Round trip through the OS Keychain under a service name of its own,
// deleted afterwards. The only test that touches the OS Keychain; the rest
// keep the login in memory. The random suffix keeps a run from touching an
// item a crashed earlier run left behind, which macOS would guard with a
// permission prompt since that run's binary was a different one.
@(test)
keychain_round_trip :: proc(t: ^testing.T) {
	key: u64
	crypto.rand_bytes(([^]u8)(&key)[:8])
	k: app.Keychain = app.Os_Keychain{app.small(fmt.tprintf("tidalfast-test-%x", key))}

	_, status := app.keychain_get(&k, context.temp_allocator)
	testing.expect_value(t, status, os_services.SECRET_NOT_FOUND)

	testing.expect_value(t, app.keychain_set(&k, transmute([]u8)string("first")), os_services.SECRET_OK)
	defer testing.expect_value(t, app.keychain_delete(&k), os_services.SECRET_OK)
	data, gstatus := app.keychain_get(&k, context.temp_allocator)
	testing.expect_value(t, gstatus, os_services.SECRET_OK)
	testing.expect_value(t, string(data), "first")

	// A second set replaces the data instead of failing as a duplicate.
	testing.expect_value(t, app.keychain_set(&k, transmute([]u8)string("rotated refresh token")), os_services.SECRET_OK)
	data, gstatus = app.keychain_get(&k, context.temp_allocator)
	testing.expect_value(t, gstatus, os_services.SECRET_OK)
	testing.expect_value(t, string(data), "rotated refresh token")
}
