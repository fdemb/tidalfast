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

import "base:intrinsics"
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

rate_supported :: proc(ranges: []Value_Range, rate: f64) -> bool {
	for r in ranges {
		if rate >= r.minimum && rate <= r.maximum {
			return true
		}
	}
	return false
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

// pick_physical_format chooses the device format for a source of rate,
// channels and bits: linear PCM at that rate with the channels, preferring
// signed integers of exactly the source's bit depth, then the smallest
// integer depth above it, then 32-bit float, which holds up to 24 bits
// exactly. ok is false if no format runs at the rate and holds every bit.
pick_physical_format :: proc(formats: []Ranged_Description, rate: f64, channels, bits: int) -> (best: Stream_Description, ok: bool) {
	score_of :: proc(f: Stream_Description, bits: int) -> int {
		if f.format_flags & FLAG_FLOAT != 0 {
			return 1 if f.bits == 32 && bits <= 24 else 0
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

// same_format compares two formats field by field.
same_format :: proc(a, b: Stream_Description) -> bool {
	return a.sample_rate == b.sample_rate && a.format_id == b.format_id && a.format_flags == b.format_flags && a.bytes_per_packet == b.bytes_per_packet && a.frames_per_packet == b.frames_per_packet && a.bytes_per_frame == b.bytes_per_frame && a.channels == b.channels && a.bits == b.bits
}

// Device_Change is what bit-perfect output changed on a device: which
// device, what it had and the rate it was set to. Plain data, for the app
// to keep on disk while it lasts.
Device_Change :: struct {
	uid:         [128]u8,
	uid_len:     int,
	orig_rate:   f64,
	orig_format: Stream_Description,
	rate:        f64, // the rate this app set, 0 for no change
}

device_change_uid :: proc(c: ^Device_Change) -> string {
	return string(c.uid[:c.uid_len])
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

HAL_MAX_CHANNELS :: 32

// Channel_Map says which source channel each device channel plays, -1 for
// silence. Device channels count across the IOProc's buffers in order, so
// one interleaved buffer and one buffer per channel map the same way.
Channel_Map :: struct {
	source:   [HAL_MAX_CHANNELS]i8,
	identity: bool, // device channel i plays source channel i, the rest silence
}

// channel_map_make maps a source of channels onto a device. Mono and stereo
// go on the device's stereo pair (stereo, from device_stereo_channels),
// mono on both; more channels go one to one. Device channels left over are
// silent.
channel_map_make :: proc(channels: int, stereo: [2]int) -> (m: Channel_Map) {
	for &v in m.source {
		v = -1
	}
	if channels <= 2 {
		l, r := stereo[0], stereo[1]
		if l < 0 || l >= HAL_MAX_CHANNELS || r < 0 || r >= HAL_MAX_CHANNELS || l == r {
			l, r = 0, 1
		}
		m.source[l] = 0
		m.source[r] = 1 if channels == 2 else 0
	} else {
		for i in 0 ..< min(channels, HAL_MAX_CHANNELS) {
			m.source[i] = i8(i)
		}
	}
	m.identity = true
	for v, i in m.source {
		if int(v) != (i if i < channels else -1) {
			m.identity = false
		}
	}
	return
}

// hal_fill fills an IOProc's output buffers from ring, without locks,
// allocation or system calls. Every buffer is checked: one with no data is
// skipped, and frames come from the buffer that holds the fewest, so all
// channels get the same ones. Each buffer gets its frames through m, and
// whatever is left of it, frames the ring didn't have or bytes past the
// last whole frame, is zeroed. When the device takes the ring's layout as
// it is (one interleaved buffer, identity map) the ring is read straight
// into it; otherwise through scratch. Returns the frames written, how many
// came from the ring, and the frames as the ring's interleaved layout.
hal_fill :: proc "contextless" (list: ^Audio_Buffer_List, ring: ^Pcm_Ring, scratch: []f32, m: ^Channel_Map) -> (frames, n: u64, out: [^]f32) {
	out = raw_data(scratch)
	if list == nil || list.count == 0 {
		return
	}
	bufs := ([^]Audio_Buffer)(&list.buffers[0])[:list.count]
	ch := u64(ring.channels)
	frames = max(u64)
	for b in bufs {
		if b.data != nil && b.channels > 0 {
			frames = min(frames, u64(b.size) / (u64(b.channels) * size_of(f32)))
		}
	}
	if frames == max(u64) || ch == 0 {
		frames = 0
	}
	direct := len(bufs) == 1 && bufs[0].data != nil && u64(bufs[0].channels) == ch && m.identity
	if direct {
		out = ([^]f32)(bufs[0].data)
	} else if ch > 0 {
		frames = min(frames, u64(len(scratch)) / ch)
	}
	n = ring_read(ring, out, frames, 1, 1)
	for i in n * ch ..< frames * ch {
		out[i] = 0
	}
	first := 0 // the device channel of the buffer's first channel
	for b in bufs {
		if b.data == nil {
			first += int(b.channels)
			continue
		}
		bch := u64(b.channels)
		if !direct && bch > 0 {
			dst := ([^]f32)(b.data)
			for k in 0 ..< bch {
				dc := first + int(k)
				src := i64(m.source[dc]) if dc < HAL_MAX_CHANNELS else -1
				if src >= 0 && u64(src) < ch {
					for i in 0 ..< frames {
						dst[i * bch + k] = out[i * ch + u64(src)]
					}
				} else {
					for i in 0 ..< frames {
						dst[i * bch + k] = 0
					}
				}
			}
		}
		written := frames * bch * size_of(f32)
		if u64(b.size) > written {
			intrinsics.mem_zero(rawptr(uintptr(b.data) + uintptr(written)), int(u64(b.size) - written))
		}
		first += int(bch)
	}
	return
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

khz_text :: proc(rate: int) -> string {
	if rate % 1000 == 0 {
		return fmt.tprintf("%d", rate / 1000)
	}
	return fmt.tprintf("%.1f", f64(rate) / 1000)
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
