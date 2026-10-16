package audio

// The CoreAudio HAL output for bit-perfect mode. miniaudio plays through an
// AudioUnit that converts to whatever rate the device runs at; this talks
// to the device itself instead: it sets the device's nominal sample rate to
// the track's, picks a physical format with the track's bit depth, can take
// the device in hog mode, and renders into an AudioDeviceIOProc.
//
// These are plain C functions in CoreAudio.framework, declared by hand, so
// Odin calls them without the Obj-C runtime.
//
// What the device was set to before (rate, physical format, hog mode) is
// kept in Hal and put back by hal_close with restore set: when bit-perfect
// is turned off, on a hot reload and when the app quits. The same goes out
// as a Device_Change for the app to keep on disk, so a start after a crash
// can put it back (device_change_undo).

import "core:fmt"
import CF "core:sys/darwin/CoreFoundation"
import "core:log"
import "core:sys/posix"
import "core:time"

foreign import CoreAudio "system:CoreAudio.framework"

Audio_Object_ID :: u32
OS_Status :: i32

Property_Address :: struct {
	selector: u32,
	scope:    u32,
	element:  u32,
}

IO_Proc :: #type proc "c" (device: Audio_Object_ID, now: rawptr, input: ^Audio_Buffer_List, input_time: rawptr, output: ^Audio_Buffer_List, output_time: rawptr, client: rawptr) -> OS_Status
Listener_Proc :: #type proc "c" (id: Audio_Object_ID, count: u32, addresses: [^]Property_Address, client: rawptr) -> OS_Status

@(private = "file")
fourcc :: proc "contextless" (s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

SYSTEM_OBJECT :: 1
SCOPE_GLOBAL := fourcc("glob")
SCOPE_OUTPUT := fourcc("outp")
ELEMENT_MAIN :: 0

PROP_DEFAULT_OUTPUT := fourcc("dOut")
PROP_DEVICES := fourcc("dev#")
PROP_NAME := fourcc("lnam")
PROP_UID := fourcc("uid ")
PROP_ALIVE := fourcc("livn")
PROP_STEREO_CHANNELS := fourcc("dch2")
PROP_NOMINAL_RATE := fourcc("nsrt")
PROP_AVAILABLE_RATES := fourcc("nsr#")
PROP_HOG_MODE := fourcc("oink")
PROP_STREAMS := fourcc("stm#")
PROP_PHYSICAL_FORMAT := fourcc("pft ")
PROP_AVAILABLE_PHYSICAL := fourcc("pfta")
PROP_VIRTUAL_FORMAT := fourcc("sfmt")


@(default_calling_convention = "c")
foreign CoreAudio {
	AudioObjectGetPropertyDataSize :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32) -> OS_Status ---
	AudioObjectGetPropertyData :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32, data: rawptr) -> OS_Status ---
	AudioObjectSetPropertyData :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: u32, data: rawptr) -> OS_Status ---
	AudioDeviceCreateIOProcID :: proc(device: Audio_Object_ID, io_proc: IO_Proc, client: rawptr, id: ^rawptr) -> OS_Status ---
	AudioDeviceDestroyIOProcID :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioDeviceStart :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioDeviceStop :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioObjectAddPropertyListener :: proc(id: Audio_Object_ID, addr: ^Property_Address, listener: Listener_Proc, client: rawptr) -> OS_Status ---
	AudioObjectRemovePropertyListener :: proc(id: Audio_Object_ID, addr: ^Property_Address, listener: Listener_Proc, client: rawptr) -> OS_Status ---
}

@(private = "file")
get :: proc(id: Audio_Object_ID, selector, scope: u32, out: ^$T) -> bool {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	size := u32(size_of(T))
	return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, out) == 0
}

@(private = "file")
set :: proc(id: Audio_Object_ID, selector, scope: u32, value: ^$T) -> OS_Status {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	return AudioObjectSetPropertyData(id, &addr, 0, nil, u32(size_of(T)), value)
}

// get_array reads a property that is an array of T into the temp allocator.
@(private = "file")
get_array :: proc(id: Audio_Object_ID, selector, scope: u32, $T: typeid) -> []T {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	size: u32
	if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) != 0 || size < size_of(T) {
		return nil
	}
	out := make([]T, int(size) / size_of(T), context.temp_allocator)
	if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw_data(out)) != 0 {
		return nil
	}
	return out[:int(size) / size_of(T)]
}

default_output_device :: proc() -> Audio_Object_ID {
	dev: Audio_Object_ID
	if !get(SYSTEM_OBJECT, PROP_DEFAULT_OUTPUT, SCOPE_GLOBAL, &dev) {
		return 0
	}
	return dev
}

device_nominal_rate :: proc(dev: Audio_Object_ID) -> f64 {
	rate: f64
	get(dev, PROP_NOMINAL_RATE, SCOPE_GLOBAL, &rate)
	return rate
}

device_available_rates :: proc(dev: Audio_Object_ID) -> []Value_Range {
	return get_array(dev, PROP_AVAILABLE_RATES, SCOPE_GLOBAL, Value_Range)
}

// device_alive is false once the device has gone, as when a USB DAC is
// unplugged.
device_alive :: proc(dev: Audio_Object_ID) -> bool {
	alive: u32
	return get(dev, PROP_ALIVE, SCOPE_GLOBAL, &alive) && alive != 0
}

// device_stereo_channels is the pair of output channels the device wants
// stereo on, from 0. {0, 1} if it doesn't say.
device_stereo_channels :: proc(dev: Audio_Object_ID) -> [2]int {
	ch: [2]u32
	if !get(dev, PROP_STEREO_CHANNELS, SCOPE_OUTPUT, &ch) || ch[0] == 0 || ch[1] == 0 {
		return {0, 1}
	}
	return {int(ch[0]) - 1, int(ch[1]) - 1}
}

// listen calls listener with client whenever the property changes. The
// listener runs on a HAL thread.
listen :: proc(id: Audio_Object_ID, selector: u32, listener: Listener_Proc, client: rawptr) -> bool {
	addr := Property_Address{selector, SCOPE_GLOBAL, ELEMENT_MAIN}
	return AudioObjectAddPropertyListener(id, &addr, listener, client) == 0
}

unlisten :: proc(id: Audio_Object_ID, selector: u32, listener: Listener_Proc, client: rawptr) {
	addr := Property_Address{selector, SCOPE_GLOBAL, ELEMENT_MAIN}
	AudioObjectRemovePropertyListener(id, &addr, listener, client)
}

// device_hog_owner is the pid that has the device in hog mode, -1 for none.
device_hog_owner :: proc(dev: Audio_Object_ID) -> posix.pid_t {
	pid := posix.pid_t(-1)
	get(dev, PROP_HOG_MODE, SCOPE_GLOBAL, &pid)
	return pid
}

// device_output_stream is the device's first output stream, 0 if none.
device_output_stream :: proc(dev: Audio_Object_ID) -> Audio_Object_ID {
	streams := get_array(dev, PROP_STREAMS, SCOPE_OUTPUT, Audio_Object_ID)
	return streams[0] if len(streams) > 0 else 0
}

stream_physical_formats :: proc(stream: Audio_Object_ID) -> []Ranged_Description {
	return get_array(stream, PROP_AVAILABLE_PHYSICAL, SCOPE_GLOBAL, Ranged_Description)
}

stream_physical_format :: proc(stream: Audio_Object_ID) -> (f: Stream_Description, ok: bool) {
	ok = get(stream, PROP_PHYSICAL_FORMAT, SCOPE_GLOBAL, &f)
	return
}

stream_virtual_format :: proc(stream: Audio_Object_ID) -> (f: Stream_Description, ok: bool) {
	ok = get(stream, PROP_VIRTUAL_FORMAT, SCOPE_GLOBAL, &f)
	return
}

device_name :: proc(dev: Audio_Object_ID) -> string {
	return string_property(dev, PROP_NAME) or_else "?"
}

// device_uid is the device's persistent id, the same after a reboot.
device_uid :: proc(dev: Audio_Object_ID) -> string {
	return string_property(dev, PROP_UID) or_else ""
}

// string_property reads a CFString property into the temp allocator.
@(private = "file")
string_property :: proc(dev: Audio_Object_ID, selector: u32) -> (string, bool) {
	str: CF.String
	if !get(dev, selector, SCOPE_GLOBAL, &str) || str == nil {
		return "", false
	}
	defer CF.CFRelease(CF.TypeRef(str))
	buf := make([]u8, 256, context.temp_allocator)
	if !CF.StringGetCString(str, raw_data(buf), CF.Index(len(buf)), CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)) {
		return "", false
	}
	return string(cstring(raw_data(buf))), true
}

// device_by_uid finds a device by device_uid, 0 if it isn't there.
device_by_uid :: proc(uid: string) -> Audio_Object_ID {
	for dev in get_array(SYSTEM_OBJECT, PROP_DEVICES, SCOPE_GLOBAL, Audio_Object_ID) {
		if device_uid(dev) == uid {
			return dev
		}
	}
	return 0
}

// device_change_undo puts a device back as c says it was, if the device is
// there and still runs at the rate this app set: anything else means
// someone changed it since. For a start after the app died with the device
// changed. Doesn't wait for the device to settle.
device_change_undo :: proc(c: ^Device_Change) -> bool {
	if c.rate == 0 || c.uid_len == 0 {
		return false
	}
	dev := device_by_uid(device_change_uid(c))
	if dev == 0 || device_nominal_rate(dev) != c.rate {
		return false
	}
	if stream := device_output_stream(dev); stream != 0 && c.orig_format.sample_rate != 0 {
		if cur, ok := stream_physical_format(stream); ok && !same_format(cur, c.orig_format) {
			f := c.orig_format
			set(stream, PROP_PHYSICAL_FORMAT, SCOPE_GLOBAL, &f)
		}
	}
	if c.orig_rate != 0 && c.orig_rate != c.rate {
		r := c.orig_rate
		set(dev, PROP_NOMINAL_RATE, SCOPE_GLOBAL, &r)
	}
	log.infof("audio: %s was left at %.0f Hz; back to %.0f Hz", device_name(dev), c.rate, c.orig_rate)
	return true
}

// Hal is one open HAL output: the device, its IOProc and what to put back.
Hal :: struct {
	device:         Audio_Object_ID,
	stream:         Audio_Object_ID,
	io_proc:        rawptr,
	running:        bool,
	rate:           int,
	channels:       int,
	bits:           int,
	format:         Stream_Description, // the physical format in use
	channel_map:    Channel_Map, // read by the IOProc; set while it's stopped
	// What the device had before we changed it, to restore.
	orig_rate:      f64,
	orig_format:    Stream_Description,
	has_orig:       bool,
	hogged:         bool, // we hold hog mode
	settle_ms:      f64, // how long the last rate change took to show
}

HAL_SETTLE_TIMEOUT :: 2 * time.Second

// hal_configure readies dev for rate, channels and bits: hog mode if
// asked, then the nominal rate and a physical format that holds every bit
// of the source. Waits off the main thread (polling, up to
// HAL_SETTLE_TIMEOUT) until the device reports the rate, that physical
// format, and a 32-bit float virtual format at the rate, which is what the
// IOProc writes. If any of that doesn't happen, ok is false and reason
// says why, short enough for a menu line.
hal_configure :: proc(h: ^Hal, dev: Audio_Object_ID, rate, channels, bits: int, hog: bool) -> (ok: bool, reason: string) {
	if dev == 0 {
		return false, "no output device"
	}
	if h.device != dev {
		h^ = {}
		h.device = dev
	}
	if !h.has_orig {
		h.orig_rate = device_nominal_rate(dev)
		h.stream = device_output_stream(dev)
		h.orig_format, _ = stream_physical_format(h.stream)
		h.has_orig = true
	}
	if hog && !h.hogged {
		// Setting the property toggles it: it takes hog mode when nobody
		// has it and gives it up when we do, whatever the value.
		pid := posix.getpid()
		switch device_hog_owner(dev) {
		case pid:
			h.hogged = true
		case -1:
			v := pid
			h.hogged = set(dev, PROP_HOG_MODE, SCOPE_GLOBAL, &v) == 0 && device_hog_owner(dev) == pid
		}
		if !h.hogged {
			log.warn("audio: couldn't take the device in hog mode, playing without it")
		}
	} else if !hog && h.hogged {
		hal_release_hog(h)
	}
	if h.stream == 0 {
		return false, "the device has no output stream"
	}
	rates := device_available_rates(dev)
	if !rate_supported(rates, f64(rate)) {
		log.warnf("audio: %s can't run at %d Hz", device_name(dev), rate)
		return false, fmt.tprintf("the device can't run at %s kHz", khz_text(rate))
	}
	want := f64(rate)
	f, found := pick_physical_format(stream_physical_formats(h.stream), want, channels, bits)
	if !found {
		log.warnf("audio: %s has no format for %d channels of %d-bit at %d Hz", device_name(dev), channels, bits, rate)
		return false, fmt.tprintf("no %d-bit format at %s kHz", bits, khz_text(rate))
	}
	begin := time.tick_now()
	if device_nominal_rate(dev) != want {
		if st := set(dev, PROP_NOMINAL_RATE, SCOPE_GLOBAL, &want); st != 0 {
			log.errorf("audio: setting the rate to %d Hz failed (%d)", rate, st)
			return false, fmt.tprintf("the device refused %s kHz", khz_text(rate))
		}
	}
	if cur, _ := stream_physical_format(h.stream); !same_format(cur, f) {
		if st := set(h.stream, PROP_PHYSICAL_FORMAT, SCOPE_GLOBAL, &f); st != 0 {
			log.errorf("audio: setting the physical format to %s failed (%d)", format_name(f), st)
			return false, "the device refused the format"
		}
	}
	for {
		pf, pok := stream_physical_format(h.stream)
		vf, vok := stream_virtual_format(h.stream)
		rate_ok := device_nominal_rate(dev) == want
		format_ok := pok && same_format(pf, f)
		virtual_ok := vok && vf.format_flags & FLAG_FLOAT != 0 && vf.bits == 32 && vf.sample_rate == want
		if rate_ok && format_ok && virtual_ok {
			break
		}
		if time.tick_since(begin) > HAL_SETTLE_TIMEOUT {
			switch {
			case !rate_ok:
				log.warnf("audio: the device didn't switch to %d Hz", rate)
				return false, fmt.tprintf("the device stayed off %s kHz", khz_text(rate))
			case !format_ok:
				log.warnf("audio: the device's format is %s, not %s", format_name(pf), format_name(f))
				return false, "the device didn't take the format"
			}
			log.warnf("audio: the device takes %s, not 32-bit float", format_name(vf))
			return false, "the device doesn't take 32-bit float"
		}
		time.sleep(2 * time.Millisecond)
	}
	h.settle_ms = time.duration_milliseconds(time.tick_since(begin))
	h.format = f
	h.rate, h.channels, h.bits = rate, channels, bits
	return true, ""
}

// hal_start creates the IOProc on first use and starts the device.
hal_start :: proc(h: ^Hal, io_proc: IO_Proc, client: rawptr) -> bool {
	if h.io_proc == nil {
		if st := AudioDeviceCreateIOProcID(h.device, io_proc, client, &h.io_proc); st != 0 {
			log.errorf("audio: AudioDeviceCreateIOProcID failed (%d)", st)
			h.io_proc = nil
			return false
		}
	}
	if !h.running {
		if st := AudioDeviceStart(h.device, h.io_proc); st != 0 {
			log.errorf("audio: AudioDeviceStart failed (%d)", st)
			return false
		}
		h.running = true
	}
	return true
}

// hal_stop stops the IOProc. When it returns the IOProc no longer runs.
hal_stop :: proc(h: ^Hal) {
	if h.running {
		AudioDeviceStop(h.device, h.io_proc)
		h.running = false
	}
}

// hal_close stops and destroys the IOProc. With restore, the device gets
// back its rate and physical format and hog mode is released.
hal_close :: proc(h: ^Hal, restore: bool) {
	hal_stop(h)
	if h.io_proc != nil {
		AudioDeviceDestroyIOProcID(h.device, h.io_proc)
		h.io_proc = nil
	}
	if !restore || h.device == 0 {
		return
	}
	if h.has_orig {
		if h.stream != 0 && h.orig_format.sample_rate != 0 {
			cur, _ := stream_physical_format(h.stream)
			if cur != h.orig_format {
				f := h.orig_format
				set(h.stream, PROP_PHYSICAL_FORMAT, SCOPE_GLOBAL, &f)
			}
		}
		if h.orig_rate != 0 && device_nominal_rate(h.device) != h.orig_rate {
			r := h.orig_rate
			set(h.device, PROP_NOMINAL_RATE, SCOPE_GLOBAL, &r)
		}
		log.infof("audio: %s back to %.0f Hz", device_name(h.device), h.orig_rate)
	}
	hal_release_hog(h)
	h^ = {}
}

@(private = "file")
hal_release_hog :: proc(h: ^Hal) {
	if !h.hogged {
		return
	}
	h.hogged = false
	if device_hog_owner(h.device) != posix.getpid() {
		return
	}
	pid := posix.pid_t(-1)
	set(h.device, PROP_HOG_MODE, SCOPE_GLOBAL, &pid)
	if device_hog_owner(h.device) == posix.getpid() {
		log.warn("audio: hog mode is still ours after releasing it")
	}
}
