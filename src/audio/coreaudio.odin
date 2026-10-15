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
// is turned off, on a hot reload and when the app quits.

import "core:fmt"
import CF "core:sys/darwin/CoreFoundation"
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

Value_Range :: struct {
	minimum: f64,
	maximum: f64,
}

// AudioStreamBasicDescription
Stream_Description :: struct {
	sample_rate:       f64,
	format_id:         u32,
	format_flags:      u32,
	bytes_per_packet:  u32,
	frames_per_packet: u32,
	bytes_per_frame:   u32,
	channels:          u32,
	bits:              u32,
	reserved:          u32,
}

// AudioStreamRangedDescription
Ranged_Description :: struct {
	format: Stream_Description,
	rates:  Value_Range,
}

Audio_Buffer :: struct {
	channels: u32,
	size:     u32,
	data:     rawptr,
}

Audio_Buffer_List :: struct {
	count:   u32,
	buffers: [1]Audio_Buffer, // count of them
}

IO_Proc :: #type proc "c" (device: Audio_Object_ID, now: rawptr, input: ^Audio_Buffer_List, input_time: rawptr, output: ^Audio_Buffer_List, output_time: rawptr, client: rawptr) -> OS_Status

@(private = "file")
fourcc :: proc "contextless" (s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

SYSTEM_OBJECT :: 1
SCOPE_GLOBAL := fourcc("glob")
SCOPE_OUTPUT := fourcc("outp")
ELEMENT_MAIN :: 0

PROP_DEFAULT_OUTPUT := fourcc("dOut")
PROP_NAME := fourcc("lnam")
PROP_NOMINAL_RATE := fourcc("nsrt")
PROP_AVAILABLE_RATES := fourcc("nsr#")
PROP_HOG_MODE := fourcc("oink")
PROP_STREAMS := fourcc("stm#")
PROP_PHYSICAL_FORMAT := fourcc("pft ")
PROP_AVAILABLE_PHYSICAL := fourcc("pfta")
PROP_VIRTUAL_FORMAT := fourcc("sfmt")

FORMAT_LPCM := fourcc("lpcm")
FLAG_FLOAT :: 1 << 0
FLAG_BIG_ENDIAN :: 1 << 1
FLAG_SIGNED :: 1 << 2
FLAG_NON_INTERLEAVED :: 1 << 5
FLAG_NON_MIXABLE :: 1 << 6

@(default_calling_convention = "c")
foreign CoreAudio {
	AudioObjectGetPropertyDataSize :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32) -> OS_Status ---
	AudioObjectGetPropertyData :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32, data: rawptr) -> OS_Status ---
	AudioObjectSetPropertyData :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: u32, data: rawptr) -> OS_Status ---
	AudioDeviceCreateIOProcID :: proc(device: Audio_Object_ID, io_proc: IO_Proc, client: rawptr, id: ^rawptr) -> OS_Status ---
	AudioDeviceDestroyIOProcID :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioDeviceStart :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioDeviceStop :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
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

rate_supported :: proc(ranges: []Value_Range, rate: f64) -> bool {
	for r in ranges {
		if rate >= r.minimum && rate <= r.maximum {
			return true
		}
	}
	return false
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

// pick_physical_format chooses the device format for a source of rate,
// channels and bits: linear PCM at that rate with the channels, preferring
// signed integers of exactly the source's bit depth, then the smallest
// integer depth above it, then 32-bit float. ok is false if no format runs
// at the rate.
pick_physical_format :: proc(formats: []Ranged_Description, rate: f64, channels, bits: int) -> (best: Stream_Description, ok: bool) {
	score_of :: proc(f: Stream_Description, bits: int) -> int {
		if f.format_flags & FLAG_FLOAT != 0 {
			return 1 if f.bits == 32 else 0
		}
		if f.format_flags & FLAG_SIGNED == 0 || int(f.bits) < bits {
			return 0
		}
		return 1000 - int(f.bits) + (1000 if int(f.bits) == bits else 0)
	}
	best_score := 0
	for r in formats {
		f := r.format
		if f.format_id != FORMAT_LPCM || int(f.channels) < channels || rate < r.rates.minimum || rate > r.rates.maximum {
			continue
		}
		// Fewer spare channels first, then the depth.
		score := score_of(f, bits) * 16 - min(int(f.channels) - channels, 15)
		if score > best_score {
			best_score = score
			best = f
			best.sample_rate = rate
			ok = true
		}
	}
	return
}

format_name :: proc(f: Stream_Description) -> string {
	kind := "float" if f.format_flags & FLAG_FLOAT != 0 else "int"
	return fmt.tprintf("%d ch %d-bit %s at %.0f Hz", f.channels, f.bits, kind, f.sample_rate)
}

device_name :: proc(dev: Audio_Object_ID) -> string {
	name: CF.String
	if !get(dev, PROP_NAME, SCOPE_GLOBAL, &name) || name == nil {
		return "?"
	}
	defer CF.CFRelease(CF.TypeRef(name))
	buf := make([]u8, 256, context.temp_allocator)
	if !CF.StringGetCString(name, raw_data(buf), CF.Index(len(buf)), CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)) {
		return "?"
	}
	return string(cstring(raw_data(buf)))
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
	// What the device had before we changed it, to restore.
	orig_rate:      f64,
	orig_format:    Stream_Description,
	has_orig:       bool,
	hogged:         bool, // we hold hog mode
	settle_ms:      f64, // how long the last rate change took to show
}

HAL_SETTLE_TIMEOUT :: 2 * time.Second

// hal_configure readies dev for rate, channels and bits: hog mode if
// asked, then the nominal rate and a physical format that fits. Waits off
// the main thread (polling, up to HAL_SETTLE_TIMEOUT) until the device
// reports the new rate. False if the device can't run at rate.
hal_configure :: proc(h: ^Hal, dev: Audio_Object_ID, rate, channels, bits: int, hog: bool) -> bool {
	if dev == 0 {
		return false
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
			fmt.eprintln("audio: couldn't take the device in hog mode, playing without it")
		}
	} else if !hog && h.hogged {
		hal_release_hog(h)
	}
	rates := device_available_rates(dev)
	if !rate_supported(rates, f64(rate)) {
		fmt.eprintfln("audio: %s can't run at %d Hz", device_name(dev), rate)
		return false
	}
	begin := time.tick_now()
	want := f64(rate)
	if device_nominal_rate(dev) != want {
		if st := set(dev, PROP_NOMINAL_RATE, SCOPE_GLOBAL, &want); st != 0 {
			fmt.eprintfln("audio: setting the rate to %d Hz failed (%d)", rate, st)
			return false
		}
	}
	if h.stream != 0 {
		if f, ok := pick_physical_format(stream_physical_formats(h.stream), want, channels, bits); ok {
			cur, _ := stream_physical_format(h.stream)
			if cur != f {
				if st := set(h.stream, PROP_PHYSICAL_FORMAT, SCOPE_GLOBAL, &f); st != 0 {
					fmt.eprintfln("audio: setting the physical format to %s failed (%d)", format_name(f), st)
				}
			}
		}
	}
	for device_nominal_rate(dev) != want {
		if time.tick_since(begin) > HAL_SETTLE_TIMEOUT {
			fmt.eprintfln("audio: the device didn't switch to %d Hz", rate)
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
	h.settle_ms = time.duration_milliseconds(time.tick_since(begin))
	h.format, _ = stream_physical_format(h.stream)
	h.rate, h.channels, h.bits = rate, channels, bits
	return true
}

// hal_start creates the IOProc on first use and starts the device.
hal_start :: proc(h: ^Hal, io_proc: IO_Proc, client: rawptr) -> bool {
	if h.io_proc == nil {
		if st := AudioDeviceCreateIOProcID(h.device, io_proc, client, &h.io_proc); st != 0 {
			fmt.eprintfln("audio: AudioDeviceCreateIOProcID failed (%d)", st)
			h.io_proc = nil
			return false
		}
	}
	if !h.running {
		if st := AudioDeviceStart(h.device, h.io_proc); st != 0 {
			fmt.eprintfln("audio: AudioDeviceStart failed (%d)", st)
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
		fmt.eprintfln("audio: %s back to %.0f Hz", device_name(h.device), h.orig_rate)
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
		fmt.eprintln("audio: hog mode is still ours after releasing it")
	}
}
