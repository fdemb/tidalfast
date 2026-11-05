package audio

// No bit-perfect output on Windows yet: miniaudio plays through WASAPI's
// shared mode, where the audio engine converts every app's sound to the
// device's mix format. Bit-perfect output would be WASAPI exclusive mode,
// which architecture.md lists as not done. These are the procedures the
// player calls, all saying there is nothing to open.

// BIT_PERFECT says whether this OS has bit-perfect output.
BIT_PERFECT :: false

// MIXER_NAME is what converts and mixes the apps' sound on this OS.
MIXER_NAME :: "Windows audio"

Hal :: struct {
	device:      Device_ID,
	format:      Stream_Description,
	channel_map: Channel_Map,
	settle_ms:   f64,
}

default_output_device :: proc() -> Device_ID {
	return 1
}

// device_nominal_rate is 0: miniaudio converts to the mix format, and the
// player reports the track's rate instead.
device_nominal_rate :: proc(dev: Device_ID) -> f64 {
	return 0
}

device_name :: proc(dev: Device_ID) -> string {
	return "Default output"
}

watch_format :: proc(dev: Device_ID, w: ^Device_Watch) -> bool {
	return false
}

unwatch_format :: proc(dev: Device_ID, w: ^Device_Watch) {}

device_physical_format :: proc(dev: Device_ID) -> (bits: int, float: bool, ok: bool) {
	return
}

hal_alive :: proc(h: ^Hal) -> bool {
	return false
}

// miniaudio follows the default output itself.
watch_default_output :: proc(w: ^Device_Watch) -> bool {
	return false
}

unwatch_default_output :: proc(w: ^Device_Watch) {}

watch_device :: proc(h: ^Hal, w: ^Device_Watch) -> bool {
	return false
}

hal_taken :: proc(h: ^Hal) -> string {
	return ""
}

unwatch_device :: proc(h: ^Hal, w: ^Device_Watch) {}

hal_configure :: proc(h: ^Hal, dev: Device_ID, rate, channels, bits: int) -> (ok: bool, reason: string) {
	return false, "Not on Windows yet"
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
