package tidal_tests

import "core:testing"

import "../src/app"
import "../src/audio"

// Linux has no bit-perfect output yet, and the miniaudio fallback in
// bit-perfect mode leaves out the volume and ReplayGain, so a saved
// setting must not turn it on.
@(test)
bit_perfect_setting_is_ignored_on_linux :: proc(t: ^testing.T) {
	testing.expect_value(t, app.output_of({bit_perfect = true, hog = true}), audio.Output{})
}
