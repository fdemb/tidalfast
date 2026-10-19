package tidal_tests

import "core:fmt"
import "core:os"
import "core:testing"

import "../src/cacert"

// Debian's libcurl in the AppImage looks for Debian's bundle. On a system
// without it, such as openSUSE, the first bundle that exists is used instead.
@(test)
cacert_falls_back_when_the_builtin_bundle_is_missing :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "tidalfast-cacert-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(dir)
	debian := fmt.tprintf("%s/ca-certificates.crt", dir)
	fedora := fmt.tprintf("%s/ca-bundle.crt", dir)
	suse := fmt.tprintf("%s/ca-bundle.pem", dir)
	testing.expect_value(t, os.write_entire_file(fedora, "x"), nil)
	testing.expect_value(t, os.write_entire_file(suse, "x"), nil)

	testing.expect_value(t, cacert.pick(debian, {debian, fedora, suse}), fedora)
	testing.expect_value(t, cacert.pick(debian, {debian}), "")
	testing.expect_value(t, cacert.pick("", {fedora}), "")

	testing.expect_value(t, os.write_entire_file(debian, "x"), nil)
	testing.expect_value(t, cacert.pick(debian, {debian, fedora, suse}), "")
}
