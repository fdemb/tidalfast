package audio

// Bit-perfect output isn't written for Linux yet. It would open the ALSA
// hw: device at the track's rate and format, or ask PipeWire for that per
// stream. Until then these stand in for the CoreAudio HAL calls the player
// makes: hal_configure always refuses with a reason the settings menu
// shows, so the player falls back to miniaudio, and there is no device
// state to listen to or put back.

import "core:time"

Audio_Object_ID :: u32
OS_Status :: i32

Property_Address :: struct {
	selector: u32,
	scope:    u32,
	element:  u32,
}

IO_Proc :: #type proc "c" (device: Audio_Object_ID, now: rawptr, input: ^Audio_Buffer_List, input_time: rawptr, output: ^Audio_Buffer_List, output_time: rawptr, client: rawptr) -> OS_Status
Listener_Proc :: #type proc "c" (id: Audio_Object_ID, count: u32, addresses: [^]Property_Address, client: rawptr) -> OS_Status

SYSTEM_OBJECT :: 1
PROP_DEFAULT_OUTPUT :: 1
PROP_ALIVE :: 2

HAL_SETTLE_TIMEOUT :: 2 * time.Second

// BIT_PERFECT says whether this OS has bit-perfect output. Without it the
// app hides the setting, since the miniaudio fallback would leave out the
// volume and ReplayGain for nothing.
BIT_PERFECT :: false

// Hal has the fields the player reads; none of them is ever set.
Hal :: struct {
	device:      Audio_Object_ID,
	running:     bool,
	rate:        int,
	format:      Stream_Description,
	channel_map: Channel_Map,
	orig_rate:   f64,
	orig_format: Stream_Description,
	has_orig:    bool,
	hogged:      bool,
	settle_ms:   f64,
}

default_output_device :: proc() -> Audio_Object_ID {
	return 0
}

// device_nominal_rate is 0: miniaudio converts to whatever the sound server
// runs at, and the player reports the track's rate instead.
device_nominal_rate :: proc(dev: Audio_Object_ID) -> f64 {
	return 0
}

device_alive :: proc(dev: Audio_Object_ID) -> bool {
	return false
}

device_stereo_channels :: proc(dev: Audio_Object_ID) -> [2]int {
	return {0, 1}
}

listen :: proc(id: Audio_Object_ID, selector: u32, listener: Listener_Proc, client: rawptr) -> bool {
	return false
}

unlisten :: proc(id: Audio_Object_ID, selector: u32, listener: Listener_Proc, client: rawptr) {}

device_name :: proc(dev: Audio_Object_ID) -> string {
	return "?"
}

device_uid :: proc(dev: Audio_Object_ID) -> string {
	return ""
}

device_change_undo :: proc(c: ^Device_Change) -> bool {
	return false
}

hal_configure :: proc(h: ^Hal, dev: Audio_Object_ID, rate, channels, bits: int, hog: bool) -> (ok: bool, reason: string) {
	return false, "not available on Linux yet"
}

hal_start :: proc(h: ^Hal, io_proc: IO_Proc, client: rawptr) -> bool {
	return false
}

hal_stop :: proc(h: ^Hal) {}

hal_close :: proc(h: ^Hal, restore: bool) {
	h^ = {}
}
