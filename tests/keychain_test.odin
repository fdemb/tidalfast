package tidal_tests

import "core:crypto"
import "core:fmt"
import "core:testing"

import "../src/mac"

// Round trip through the real login Keychain under a service name of its
// own, deleted afterwards. The random suffix keeps a run from touching an
// item a crashed earlier run left behind, which macOS would guard with a
// permission prompt since that run's binary was a different one.
@(test)
keychain_round_trip :: proc(t: ^testing.T) {
	key: u64
	crypto.rand_bytes(([^]u8)(&key)[:8])
	service := fmt.tprintf("tidalfast-test-%x", key)
	account := "auth"

	_, status := mac.keychain_get(service, account, context.temp_allocator)
	testing.expect_value(t, status, mac.ERR_SEC_ITEM_NOT_FOUND)

	testing.expect_value(t, mac.keychain_set(service, account, transmute([]u8)string("first")), mac.ERR_SEC_SUCCESS)
	defer testing.expect_value(t, mac.keychain_delete(service, account), mac.ERR_SEC_SUCCESS)
	data, gstatus := mac.keychain_get(service, account, context.temp_allocator)
	testing.expect_value(t, gstatus, mac.ERR_SEC_SUCCESS)
	testing.expect_value(t, string(data), "first")

	// A second set replaces the data instead of failing as a duplicate.
	testing.expect_value(t, mac.keychain_set(service, account, transmute([]u8)string("rotated refresh token")), mac.ERR_SEC_SUCCESS)
	data, gstatus = mac.keychain_get(service, account, context.temp_allocator)
	testing.expect_value(t, gstatus, mac.ERR_SEC_SUCCESS)
	testing.expect_value(t, string(data), "rotated refresh token")
}
