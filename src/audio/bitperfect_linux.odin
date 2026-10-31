package audio

// Bit-perfect output isn't written for Linux yet. It would open the ALSA
// hw: device at the track's rate and format, or ask PipeWire for that per
// stream. Until then these are the procedures bitperfect_darwin.odin has,
// doing nothing: hal_configure always refuses with a reason the settings
// menu shows, so the player falls back to miniaudio, and there is no
// device to watch or put back.

// BIT_PERFECT says whether this OS has bit-perfect output. Without it the
// app hides the setting, since the miniaudio fallback would leave out the
// volume and ReplayGain for nothing.
BIT_PERFECT :: false

// Hal has the fields the player reads; none of them is ever set.
Hal :: struct {
	device:      Device_ID,
	format:      Stream_Description,
	channel_map: Channel_Map,
	hogged:      bool,
	settle_ms:   f64,
}

default_output_device :: proc() -> Device_ID {
	return 0
}

// device_nominal_rate is 0: miniaudio converts to whatever the sound server
// runs at, and the player reports the track's rate instead.
device_nominal_rate :: proc(dev: Device_ID) -> f64 {
	return 0
}

device_alive :: proc(dev: Device_ID) -> bool {
	return false
}

device_name :: proc(dev: Device_ID) -> string {
	return "?"
}

watch_default_output :: proc(w: ^Device_Watch) -> bool {
	return false
}

unwatch_default_output :: proc(w: ^Device_Watch) {}

watch_device :: proc(dev: Device_ID, w: ^Device_Watch) -> bool {
	return false
}

unwatch_device :: proc(dev: Device_ID, w: ^Device_Watch) {}

hal_configure :: proc(h: ^Hal, dev: Device_ID, rate, channels, bits: int, hog: bool) -> (ok: bool, reason: string) {
	return false, "not available on Linux yet"
}

hal_start :: proc(h: ^Hal, p: ^Player) -> bool {
	return false
}

hal_stop :: proc(h: ^Hal) {}

hal_close :: proc(h: ^Hal, restore: bool) {
	h^ = {}
}

hal_device_change :: proc(h: ^Hal) -> Device_Change {
	return {}
}

device_change_undo :: proc(c: ^Device_Change) -> bool {
	return false
}
