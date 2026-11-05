package tidal_tests

import "core:testing"

import "../src/audio"

// Exclusive output on Windows hands the device integers: each 16- and
// 24-bit sample the decoder turned into a float comes back as the same
// integer in a container of 2, 3 or 4 bytes, and out-of-range floats clip.
@(test)
float_to_pcm_is_exact :: proc(t: ^testing.T) {
	values := []i32{0, 1, -1, 32767, -32768, 12345, 8388607, -8388608, 4660}
	for bits in ([]int{16, 24}) {
		for v in values {
			if v > (1 << u32(bits - 1)) - 1 || v < -(1 << u32(bits - 1)) {
				continue
			}
			// What dr_flac gives: the sample shifted to 32 bits, over 2^31.
			f := [1]f32{f32(f64(v << u32(32 - bits)) / 2147483648.0)}
			for bytes in ([]int{2, 3, 4}) {
				if bytes * 8 < bits {
					continue
				}
				out: [4]u8
				audio.float_to_pcm(&f[0], &out[0], 1, bytes)
				got: i32
				for k in 0 ..< bytes {
					got |= i32(out[k]) << u32(8 * (4 - bytes + k))
				}
				got >>= u32(32 - bits)
				testing.expectf(t, got == v, "%d-bit %d in %d bytes came out %d", bits, v, bytes, got)
			}
		}
	}
	loud := [2]f32{1.5, -1.5}
	out: [8]u8
	audio.float_to_pcm(&loud[0], &out[0], 2, 4)
	testing.expect_value(t, (^i32)(&out[0])^, max(i32))
	testing.expect_value(t, (^i32)(&out[4])^, min(i32))
}
