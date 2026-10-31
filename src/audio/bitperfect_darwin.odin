package audio

// Bit-perfect output on macOS, through the CoreAudio HAL. miniaudio plays
// through an AudioUnit that converts to whatever rate the device runs at;
// this talks to the device itself instead: it sets the device's nominal
// sample rate to the track's, picks a physical format with the track's bit
// depth, can take the device in hog mode, and renders into an
// AudioDeviceIOProc. The CoreAudio calls themselves are in
// coreaudio_darwin.odin.
//
// bitperfect_linux.odin declares the same procedures and the Hal fields
// the player reads, for PipeWire, so the player never sees either OS's
// types.
//
// What the device was set to before (rate, physical format, hog mode) is
// kept in Hal and put back by hal_close with restore set: when bit-perfect
// is turned off, on a hot reload and when the app quits. The same goes out
// as a Device_Change for the app to keep on disk (hal_device_change), so a
// start after a crash can put it back (device_change_undo).

import "core:fmt"
import "core:log"
import "core:sys/posix"
import "core:time"

// BIT_PERFECT says whether this OS has bit-perfect output.
BIT_PERFECT :: true

// HOG_MODE says whether bit-perfect output can take the device for this
// app alone.
HOG_MODE :: true

// Hal is one open HAL output: the device, its IOProc and what to put back.
Hal :: struct {
	device:         Device_ID,
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

@(private = "file")
HAL_SETTLE_TIMEOUT :: 2 * time.Second

default_output_device :: proc() -> Device_ID {
	dev: Audio_Object_ID
	if !get(SYSTEM_OBJECT, PROP_DEFAULT_OUTPUT, SCOPE_GLOBAL, &dev) {
		return 0
	}
	return dev
}

device_nominal_rate :: proc(dev: Device_ID) -> f64 {
	rate: f64
	get(dev, PROP_NOMINAL_RATE, SCOPE_GLOBAL, &rate)
	return rate
}

// hal_alive is false once h's device has gone, as when a USB DAC is
// unplugged.
hal_alive :: proc(h: ^Hal) -> bool {
	alive: u32
	return get(h.device, PROP_ALIVE, SCOPE_GLOBAL, &alive) && alive != 0
}

device_name :: proc(dev: Device_ID) -> string {
	return string_property(dev, PROP_NAME) or_else "?"
}

// watch_default_output tells w whenever the system's default output
// changes. CoreAudio may still run the listener after it's removed, which
// is why it touches nothing but w.
watch_default_output :: proc(w: ^Device_Watch) -> bool {
	return listen(SYSTEM_OBJECT, PROP_DEFAULT_OUTPUT, watch_listener, w)
}

unwatch_default_output :: proc(w: ^Device_Watch) {
	unlisten(SYSTEM_OBJECT, PROP_DEFAULT_OUTPUT, watch_listener, w)
}

// watch_device tells w whenever h's device comes or goes.
watch_device :: proc(h: ^Hal, w: ^Device_Watch) -> bool {
	return listen(h.device, PROP_ALIVE, watch_listener, w)
}

unwatch_device :: proc(h: ^Hal, w: ^Device_Watch) {
	unlisten(h.device, PROP_ALIVE, watch_listener, w)
}

// watch_listener runs on a HAL thread.
@(private = "file")
watch_listener :: proc "c" (id: Audio_Object_ID, count: u32, addresses: [^]Property_Address, client: rawptr) -> OS_Status {
	default_changed, device_changed := false, false
	for a in addresses[:count] {
		if a.selector == PROP_DEFAULT_OUTPUT {
			default_changed = true
		} else {
			device_changed = true
		}
	}
	watch_note((^Device_Watch)(client), default_changed, device_changed)
	return 0
}

// hal_configure readies dev for rate, channels and bits: hog mode if
// asked, then the nominal rate and a physical format that holds every bit
// of the source. Waits off the main thread (polling, up to
// HAL_SETTLE_TIMEOUT) until the device reports the rate, that physical
// format, and a 32-bit float virtual format at the rate, which is what the
// IOProc writes. If any of that doesn't happen, ok is false and reason
// says why, short enough for a menu line. Must be called with the IOProc
// stopped, since it sets the channel map.
hal_configure :: proc(h: ^Hal, dev: Device_ID, rate, channels, bits: int, hog: bool) -> (ok: bool, reason: string) {
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
	h.channel_map = channel_map_make(channels, device_stereo_channels(dev))
	return true, ""
}

// hal_start creates the IOProc on first use and starts the device. The
// IOProc renders p's ring (hal_render).
hal_start :: proc(h: ^Hal, p: ^Player) -> bool {
	if h.io_proc == nil {
		if st := AudioDeviceCreateIOProcID(h.device, hal_io_proc, p, &h.io_proc); st != 0 {
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

@(private = "file")
hal_io_proc :: proc "c" (device: Audio_Object_ID, now: rawptr, input: ^Audio_Buffer_List, input_time: rawptr, output: ^Audio_Buffer_List, output_time: rawptr, client: rawptr) -> OS_Status {
	hal_render((^Player)(client), output)
	return 0
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

// hal_device_change is what h has changed on its device so far, zero for
// nothing.
hal_device_change :: proc(h: ^Hal) -> (c: Device_Change) {
	if h.device != 0 && h.has_orig && h.rate != 0 {
		c.uid_len = copy(c.uid[:], device_uid(h.device))
		c.orig_rate = h.orig_rate
		c.orig_format = h.orig_format
		c.rate = f64(h.rate)
	}
	return
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
