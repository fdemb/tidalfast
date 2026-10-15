package tidal_tests

import "core:testing"

import "../src/render"

@(test)
test_premultiplied_lut :: proc(t: ^testing.T) {
	pixels: [4]u8
	for a in 0 ..< 256 {
		for c in 0 ..< 256 {
			pixels = {u8(c), u8(c), u8(c), u8(a)}
			render.convert_premultiplied(pixels[:])
			want := u8(c) if a == 0 || a == 255 else render.premultiplied_exact(u8(c), u8(a))
			if pixels[0] != want || pixels[3] != u8(a) {
				testing.expectf(t, false, "c %d a %d: got %d, want %d", c, a, pixels[0], want)
				return
			}
		}
	}
	// 50% white comes out as 188, as the README says.
	pixels = {128, 128, 128, 128}
	render.convert_premultiplied(pixels[:])
	testing.expect_value(t, pixels, [4]u8{188, 188, 188, 128})
}
