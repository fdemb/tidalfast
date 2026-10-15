// Makes TIDAL-style DASH streams for the tests and the mock: a FLAC file
// cut into fragmented MP4 segments, the initialization segment with its
// dfLa box, and an MPD with a SegmentTemplate and SegmentTimeline. Also a
// FLAC encoder with verbatim subframes, so tests can make 24-bit FLAC
// without afconvert.
package dashgen

import "core:fmt"
import "core:strings"

import "../../src/audio"

Dash :: struct {
	init:     []u8,
	segments: [][]u8,
	starts:   []i64, // each segment's first sample
	lengths:  []i64, // its samples
	rate:     int,
	bits:     int,
	channels: int,
	total:    i64,
}

// Builder writes big-endian fields and nested boxes.
@(private)
Builder :: struct {
	buf:   [dynamic]u8,
	stack: [16]int,
	depth: int,
}

@(private)
u8_ :: proc(b: ^Builder, v: u8) {
	append(&b.buf, v)
}

@(private)
u16_ :: proc(b: ^Builder, v: u16) {
	append(&b.buf, u8(v >> 8), u8(v))
}

@(private)
u32_ :: proc(b: ^Builder, v: u32) {
	append(&b.buf, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private)
u64_ :: proc(b: ^Builder, v: u64) {
	u32_(b, u32(v >> 32))
	u32_(b, u32(v))
}

@(private)
zeros :: proc(b: ^Builder, n: int) {
	for _ in 0 ..< n {
		append(&b.buf, 0)
	}
}

@(private)
open :: proc(b: ^Builder, kind: string) {
	b.stack[b.depth] = len(b.buf)
	b.depth += 1
	u32_(b, 0)
	append(&b.buf, ..transmute([]u8)kind)
}

// full opens a FullBox with version and flags.
@(private)
full :: proc(b: ^Builder, kind: string, version: u8, flags: u32) {
	open(b, kind)
	u32_(b, u32(version) << 24 | flags)
}

@(private)
close :: proc(b: ^Builder) {
	b.depth -= 1
	start := b.stack[b.depth]
	size := u32(len(b.buf) - start)
	b.buf[start], b.buf[start + 1], b.buf[start + 2], b.buf[start + 3] = u8(size >> 24), u8(size >> 16), u8(size >> 8), u8(size)
}

@(private)
matrix_ :: proc(b: ^Builder) {
	for v in ([9]u32{0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000}) {
		u32_(b, v)
	}
}

// from_flac cuts a FLAC file into segments of about segment_seconds, whole
// frames each. A file without enough frames for one segment is one segment.
from_flac :: proc(flac: []u8, segment_seconds: f64, allocator := context.allocator) -> (d: Dash, ok: bool) {
	context.allocator = allocator
	h := new(audio.Flac_Header, context.temp_allocator)
	if audio.parse_flac_header(flac, h) != .Ok {
		return {}, false
	}
	info := h.info
	d.rate, d.bits, d.channels = info.sample_rate, info.bits, info.channels
	d.total = info.total_samples
	d.init = make_init(flac[h.streaminfo:h.streaminfo + 34], info)

	// Frame boundaries, confirmed by the next header's sample number.
	frames := make([dynamic][]u8, context.temp_allocator)
	firsts := make([dynamic]i64, context.temp_allocator)
	data := flac[h.audio_start:]
	off := 0
	for off < len(data) {
		fh, st := audio.parse_frame_header(data[off:], info)
		if st != .Ok {
			return {}, false
		}
		rel, _, fst := audio.find_frame(data[off + fh.size:], info, true)
		end := len(data) if fst != .Ok else off + fh.size + rel
		append(&frames, data[off:end])
		append(&firsts, fh.sample)
		off = end
	}
	sample_count :: proc(firsts: []i64, i: int, total: i64) -> i64 {
		return (firsts[i + 1] if i + 1 < len(firsts) else total) - firsts[i]
	}

	segs := make([dynamic][]u8)
	starts := make([dynamic]i64)
	lengths := make([dynamic]i64)
	want := i64(segment_seconds * f64(d.rate))
	for i := 0; i < len(frames); {
		j := i
		n := i64(0)
		for j < len(frames) && (n < want || j == i) {
			n += sample_count(firsts[:], j, d.total)
			j += 1
		}
		durations := make([]u32, j - i, context.temp_allocator)
		for k in i ..< j {
			durations[k - i] = u32(sample_count(firsts[:], k, d.total))
		}
		append(&segs, make_segment(u32(len(segs) + 1), u64(firsts[i]), frames[i:j], durations))
		append(&starts, firsts[i])
		append(&lengths, n)
		i = j
	}
	d.segments, d.starts, d.lengths = segs[:], starts[:], lengths[:]
	return d, true
}

@(private)
make_init :: proc(streaminfo: []u8, info: audio.Flac_Info) -> []u8 {
	b: Builder
	b.buf = make([dynamic]u8)
	open(&b, "ftyp")
	append(&b.buf, ..transmute([]u8)string("iso6"))
	u32_(&b, 0)
	append(&b.buf, ..transmute([]u8)string("iso6dashmp41"))
	close(&b)

	open(&b, "moov")
	full(&b, "mvhd", 0, 0)
	u32_(&b, 0) // creation
	u32_(&b, 0) // modification
	u32_(&b, u32(info.sample_rate))
	u32_(&b, 0) // duration: fragmented
	u32_(&b, 0x10000)
	u16_(&b, 0x100)
	zeros(&b, 10)
	matrix_(&b)
	zeros(&b, 24)
	u32_(&b, 2) // next track id
	close(&b)

	open(&b, "trak")
	full(&b, "tkhd", 0, 3)
	u32_(&b, 0)
	u32_(&b, 0)
	u32_(&b, 1) // track id
	u32_(&b, 0)
	u32_(&b, 0) // duration
	zeros(&b, 8)
	u16_(&b, 0) // layer
	u16_(&b, 0) // alternate group
	u16_(&b, 0x100) // volume
	u16_(&b, 0)
	matrix_(&b)
	u32_(&b, 0)
	u32_(&b, 0)
	close(&b)

	open(&b, "mdia")
	full(&b, "mdhd", 0, 0)
	u32_(&b, 0)
	u32_(&b, 0)
	u32_(&b, u32(info.sample_rate))
	u32_(&b, 0)
	u16_(&b, 0x55c4) // und
	u16_(&b, 0)
	close(&b)
	full(&b, "hdlr", 0, 0)
	u32_(&b, 0)
	append(&b.buf, ..transmute([]u8)string("soun"))
	zeros(&b, 12)
	append(&b.buf, ..transmute([]u8)string("SoundHandler\x00"))
	close(&b)

	open(&b, "minf")
	full(&b, "smhd", 0, 0)
	u32_(&b, 0)
	close(&b)
	open(&b, "dinf")
	full(&b, "dref", 0, 0)
	u32_(&b, 1)
	full(&b, "url ", 0, 1)
	close(&b)
	close(&b)
	close(&b)

	open(&b, "stbl")
	full(&b, "stsd", 0, 0)
	u32_(&b, 1)
	open(&b, "fLaC")
	zeros(&b, 6)
	u16_(&b, 1) // data reference index
	zeros(&b, 8)
	u16_(&b, u16(info.channels))
	u16_(&b, u16(info.bits))
	u16_(&b, 0)
	u16_(&b, 0)
	// 16.16 fixed point, 0 when the rate doesn't fit; dfLa has the real one.
	u32_(&b, u32(info.sample_rate) << 16 if info.sample_rate < 65536 else 0)
	full(&b, "dfLa", 0, 0)
	u8_(&b, 0x80) // STREAMINFO, last
	u8_(&b, 0)
	u8_(&b, 0)
	u8_(&b, 34)
	append(&b.buf, ..streaminfo)
	close(&b) // dfLa
	close(&b) // fLaC
	close(&b) // stsd
	for kind in ([]string{"stts", "stsc", "stco"}) {
		full(&b, kind, 0, 0)
		u32_(&b, 0)
		close(&b)
	}
	full(&b, "stsz", 0, 0)
	u32_(&b, 0)
	u32_(&b, 0)
	close(&b)
	close(&b) // stbl
	close(&b) // minf
	close(&b) // mdia
	close(&b) // trak

	open(&b, "mvex")
	full(&b, "trex", 0, 0)
	u32_(&b, 1)
	u32_(&b, 1)
	u32_(&b, 0)
	u32_(&b, 0)
	u32_(&b, 0)
	close(&b)
	close(&b)
	close(&b) // moov
	return b.buf[:]
}

@(private)
make_segment :: proc(sequence: u32, base_time: u64, frames: [][]u8, durations: []u32) -> []u8 {
	b: Builder
	b.buf = make([dynamic]u8)
	open(&b, "styp")
	append(&b.buf, ..transmute([]u8)string("msdh"))
	u32_(&b, 0)
	append(&b.buf, ..transmute([]u8)string("msdhmsix"))
	close(&b)

	moof_start := len(b.buf)
	open(&b, "moof")
	full(&b, "mfhd", 0, 0)
	u32_(&b, sequence)
	close(&b)
	open(&b, "traf")
	full(&b, "tfhd", 0, 0x020000) // default-base-is-moof
	u32_(&b, 1)
	close(&b)
	full(&b, "tfdt", 1, 0)
	u64_(&b, base_time)
	close(&b)
	full(&b, "trun", 0, 0x001 | 0x100 | 0x200)
	u32_(&b, u32(len(frames)))
	offset_at := len(b.buf)
	u32_(&b, 0) // data offset, below
	for f, i in frames {
		u32_(&b, durations[i])
		u32_(&b, u32(len(f)))
	}
	close(&b) // trun
	close(&b) // traf
	close(&b) // moof
	data_offset := u32(len(b.buf) - moof_start + 8)
	b.buf[offset_at], b.buf[offset_at + 1], b.buf[offset_at + 2], b.buf[offset_at + 3] = u8(data_offset >> 24), u8(data_offset >> 16), u8(data_offset >> 8), u8(data_offset)

	open(&b, "mdat")
	for f in frames {
		append(&b.buf, ..f)
	}
	close(&b)
	return b.buf[:]
}

// mpd is the manifest TIDAL would send for d, with the segments at
// base/0.mp4 (initialization) and base/1.mp4 on, and a query on every URL
// as TIDAL's tokens have.
mpd :: proc(d: Dash, base: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	seconds := f64(d.total) / f64(d.rate)
	fmt.sbprintf(&b, `<?xml version='1.0' encoding='UTF-8'?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:cenc="urn:mpeg:cenc:2013" profiles="urn:mpeg:dash:profile:isoff-main:2011" type="static" minBufferTime="PT3.993S" mediaPresentationDuration="PT%.3fS">`, seconds)
	fmt.sbprintf(&b, `<Period id="0"><AdaptationSet id="0" contentType="audio" mimeType="audio/mp4" segmentAlignment="true"><Representation id="FLAC,%d,%d" codecs="flac" bandwidth="%d" audioSamplingRate="%d">`, d.rate, d.bits, d.rate * d.bits * d.channels / 2, d.rate)
	fmt.sbprintf(&b, `<SegmentTemplate timescale="%d" initialization="%s/0.mp4?token=mock&amp;e=1" media="%s/$Number$.mp4?token=mock&amp;e=1" startNumber="1"><SegmentTimeline>`, d.rate, base, base)
	// Runs of equal lengths become one S with a repeat count.
	for i := 0; i < len(d.lengths); {
		j := i + 1
		for j < len(d.lengths) && d.lengths[j] == d.lengths[i] {
			j += 1
		}
		if i == 0 {
			fmt.sbprintf(&b, `<S t="0" d="%d"`, d.lengths[i])
		} else {
			fmt.sbprintf(&b, `<S d="%d"`, d.lengths[i])
		}
		if j - i > 1 {
			fmt.sbprintf(&b, ` r="%d"`, j - i - 1)
		}
		strings.write_string(&b, "/>")
		i = j
	}
	strings.write_string(&b, `</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`)
	return strings.to_string(b)
}

// encode_verbatim makes a FLAC file of interleaved samples with verbatim
// subframes: fixed blocks of block samples, independent channels, any bit
// depth from 8 to 32. Lossless by construction, so a test knows exactly
// which values must come back.
encode_verbatim :: proc(pcm: []i32, channels, bits, rate, block: int, allocator := context.allocator) -> []u8 {
	context.allocator = allocator
	total := len(pcm) / channels
	out := make([dynamic]u8)
	append(&out, 'f', 'L', 'a', 'C')
	append(&out, 0x80, 0, 0, 34)
	si: [34]u8
	si[0], si[1], si[2], si[3] = u8(block >> 8), u8(block), u8(block >> 8), u8(block)
	si[10] = u8(rate >> 12)
	si[11] = u8(rate >> 4)
	si[12] = u8(rate << 4) | u8(channels - 1) << 1 | u8((bits - 1) >> 4)
	si[13] = u8((bits - 1) & 0xf) << 4 | u8(total >> 32)
	si[14], si[15], si[16], si[17] = u8(total >> 24), u8(total >> 16), u8(total >> 8), u8(total)
	append(&out, ..si[:])

	bits_code: u8
	switch bits {
	case 8:
		bits_code = 1
	case 12:
		bits_code = 2
	case 16:
		bits_code = 4
	case 20:
		bits_code = 5
	case 24:
		bits_code = 6
	case 32:
		bits_code = 7
	}
	for start, frame := 0, 0; start < total; start, frame = start + block, frame + 1 {
		n := min(block, total - start)
		fs := len(out)
		// Block size from the 16 bits that follow, rate from STREAMINFO.
		append(&out, 0xff, 0xf8, 0x70, u8(channels - 1) << 4 | bits_code << 1)
		// The frame number, coded like UTF-8.
		switch {
		case frame < 0x80:
			append(&out, u8(frame))
		case frame < 0x800:
			append(&out, 0xc0 | u8(frame >> 6), 0x80 | u8(frame & 0x3f))
		case:
			append(&out, 0xe0 | u8(frame >> 12), 0x80 | u8(frame >> 6 & 0x3f), 0x80 | u8(frame & 0x3f))
		}
		append(&out, u8((n - 1) >> 8), u8(n - 1))
		append(&out, audio.crc8(out[fs:]))
		acc: u64
		nacc: uint
		put :: proc(out: ^[dynamic]u8, acc: ^u64, nacc: ^uint, v: u64, width: uint) {
			acc^ = acc^ << width | (v & (1 << width - 1))
			nacc^ += width
			for nacc^ >= 8 {
				nacc^ -= 8
				append(out, u8(acc^ >> nacc^))
			}
		}
		for c in 0 ..< channels {
			put(&out, &acc, &nacc, 0x02, 8) // verbatim subframe, no wasted bits
			for i in 0 ..< n {
				put(&out, &acc, &nacc, u64(u32(pcm[(start + i) * channels + c])), uint(bits))
			}
		}
		if nacc > 0 {
			put(&out, &acc, &nacc, 0, 8 - nacc)
		}
		crc := crc16(out[fs:])
		append(&out, u8(crc >> 8), u8(crc))
	}
	return out[:]
}

@(private)
crc16 :: proc(b: []u8) -> u16 {
	crc: u16
	for c in b {
		crc ~= u16(c) << 8
		for _ in 0 ..< 8 {
			crc = (crc << 1) ~ 0x8005 if crc & 0x8000 != 0 else crc << 1
		}
	}
	return crc
}

// Lfsr is a 32-bit xorshift generator, for test signals where any changed
// bit shows.
Lfsr :: struct {
	state: u32,
}

lfsr_next :: proc(l: ^Lfsr) -> u32 {
	x := l.state
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	l.state = x
	return x
}

// quiet_signal is frames of noise from an Lfsr seeded with seed, every bit
// position in use, at about -60 dBFS for the bit depth: values in
// [-2^(bits-11), 2^(bits-11)).
quiet_signal :: proc(frames, channels, bits: int, seed: u32, allocator := context.allocator) -> []i32 {
	out := make([]i32, frames * channels, allocator)
	l := Lfsr{seed}
	span := u32(1) << uint(bits - 10)
	for &v in out {
		v = i32(lfsr_next(&l) % span) - i32(span / 2)
	}
	return out
}
