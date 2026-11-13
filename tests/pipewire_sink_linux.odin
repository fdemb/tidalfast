package tidal_tests

import "core:testing"

import "../src/audio"

// Bit-perfect output forces PipeWire's graph to the track's rate. On a
// MacBook Air under Asahi the default sink is a filter chain that offers
// 88.2 kHz, the speakers behind it ran at 96 kHz instead, and their
// protection daemon locked them. Only a sound card's own node may be forced.
@(test)
bit_perfect_needs_a_sound_card :: proc(t: ^testing.T) {
	// Asahi's speaker DSP: a node with no device.
	ok, reason := audio.sink_allows_bit_perfect({found = true})
	testing.expect(t, !ok)
	testing.expect_value(t, reason, "the output is a filter or virtual sink, not a sound card")

	ok, reason = audio.sink_allows_bit_perfect({found = true, has_device = true, device_api = "bluez5"})
	testing.expect(t, !ok)
	testing.expect_value(t, reason, "Bluetooth output isn't bit-perfect")

	ok, _ = audio.sink_allows_bit_perfect({found = true, has_device = true, device_api = "other"})
	testing.expect(t, !ok)

	ok, _ = audio.sink_allows_bit_perfect({})
	testing.expect(t, !ok)

	ok, reason = audio.sink_allows_bit_perfect({found = true, has_device = true, device_api = "alsa"})
	testing.expect(t, ok)
	testing.expect_value(t, reason, "")

	// Every refusal fits the Output menu's reason.
	for s in ([]audio.Pw_Sink{{}, {found = true}, {found = true, has_device = true, device_api = "bluez5"}, {found = true, has_device = true}}) {
		_, r := audio.sink_allows_bit_perfect(s)
		testing.expect(t, len(r) <= 64, r)
	}
}

@(test)
default_sink_name_reads_the_metadata_value :: proc(t: ^testing.T) {
	testing.expect_value(t, audio.default_sink_name(`{"name":"audio_effect.j313-convolver"}`), "audio_effect.j313-convolver")
	testing.expect_value(t, audio.default_sink_name(`{ "name": "alsa_output.usb" }`), "alsa_output.usb")
	testing.expect_value(t, audio.default_sink_name(`{"name":`), "")
	testing.expect_value(t, audio.default_sink_name(`{"name":3}`), "")
	testing.expect_value(t, audio.default_sink_name(`{"name":"open`), "")
	testing.expect_value(t, audio.default_sink_name(""), "")
}
