package audio

// The formats, channel maps and buffer filling of bit-perfect output, which
// need no OS calls. The types keep CoreAudio's layouts (each OS's backend
// fills the same Audio_Buffer_List), so the macOS backend passes them to
// the HAL as they are and the tests run anywhere.

import "base:intrinsics"
import "core:fmt"

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

FORMAT_LPCM :: 0x6c70_636d // 'lpcm'
FLAG_FLOAT :: 1 << 0
FLAG_BIG_ENDIAN :: 1 << 1
FLAG_SIGNED :: 1 << 2
FLAG_NON_INTERLEAVED :: 1 << 5
FLAG_NON_MIXABLE :: 1 << 6

rate_supported :: proc(ranges: []Value_Range, rate: f64) -> bool {
	for r in ranges {
		if rate >= r.minimum && rate <= r.maximum {
			return true
		}
	}
	return false
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

khz_text :: proc(rate: int) -> string {
	if rate % 1000 == 0 {
		return fmt.tprintf("%d", rate / 1000)
	}
	return fmt.tprintf("%.1f", f64(rate) / 1000)
}

