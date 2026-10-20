package audio

// Fragmented MP4 holding FLAC, which is what TIDAL's DASH segments are. The
// initialization segment has the moov box, whose fLaC sample entry carries
// a dfLa box: FLAC's metadata blocks (STREAMINFO and maybe others) as they
// would follow "fLaC" at the start of a .flac file. Each media segment is a
// moof box, whose trun lists the sizes of its samples, and an mdat holding
// them. A FLAC sample is one FLAC frame, so "fLaC", the dfLa blocks and the
// samples in order make a FLAC stream that the decoder reads as a file.

import "core:mem"

MP4_MAX_BOX :: 16 << 20 // larger moov or moof boxes are refused
MP4_MAX_SAMPLES :: 1 << 16 // per fragment; a 4 s segment of 192 kHz FLAC has about 190

Mp4_Box :: struct {
	kind:   u32, // fourcc, big endian
	size:   i64, // the whole box, header included; -1: to the end of the data
	header: int,
}

Mp4_Init :: struct {
	track_id:         u32,
	timescale:        u32, // mdhd: units of tfdt and sample durations per second
	duration:         u64, // mdhd, in timescale units, often 0 in fragmented files
	default_duration: u32, // trex
	default_size:     u32, // trex
	flac_head:        []u8, // "fLaC" and the dfLa metadata blocks, the last one flagged last
}

Mp4_Sample :: struct {
	offset: i64, // from the start of the moof box
	size:   u32,
}

Mp4_Fragment :: struct {
	track_id:      u32,
	base_time:     u64, // tfdt, in the track's timescale
	has_base_time: bool,
	reason:        string, // why parse_mp4_moof refused it
}

mp4_fourcc :: proc "contextless" (s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

@(private = "file")
be32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

// mp4_box_header reads the box header at the start of b.
mp4_box_header :: proc(b: []u8) -> (box: Mp4_Box, status: Parse_Status) {
	if len(b) < 8 {
		return {}, .Need_More
	}
	size := i64(be32(b))
	box.kind = be32(b[4:])
	box.header = 8
	switch size {
	case 0:
		size = -1
	case 1:
		if len(b) < 16 {
			return {}, .Need_More
		}
		size = i64(be_u64(b[8:]))
		box.header = 16
		// Also catches sizes above max(i64), which come out negative.
		if size < 16 {
			return {}, .Invalid
		}
	case:
		if size < 8 {
			return {}, .Invalid
		}
	}
	box.size = size
	return box, .Ok
}

// Box_Iter walks the boxes inside data, which holds them whole.
@(private = "file")
Box_Iter :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file")
next_box :: proc(it: ^Box_Iter) -> (kind: u32, body: []u8, ok: bool) {
	if it.pos >= len(it.data) {
		return
	}
	box, st := mp4_box_header(it.data[it.pos:])
	if st != .Ok || box.size > i64(len(it.data) - it.pos) {
		return
	}
	end := len(it.data) if box.size < 0 else it.pos + int(box.size)
	body = it.data[it.pos + box.header:end]
	it.pos = end
	return box.kind, body, true
}

@(private = "file")
find_box :: proc(data: []u8, kind: u32) -> (body: []u8, ok: bool) {
	it := Box_Iter{data = data}
	for {
		k, b := next_box(&it) or_return
		if k == kind {
			return b, true
		}
	}
}

// parse_mp4_init reads an initialization segment: it needs the whole moov
// box, and says Need_More until data has it. used is where the moov ends. The first track whose sample
// entry is fLaC is the one. flac_head is allocated with allocator.
parse_mp4_init :: proc(data: []u8, allocator := context.allocator) -> (init: Mp4_Init, used: int, status: Parse_Status) {
	pos := 0
	moov: []u8
	for moov == nil {
		if pos > MP4_MAX_BOX {
			return {}, 0, .Invalid
		}
		box, st := mp4_box_header(data[pos:])
		if st != .Ok {
			return {}, 0, st
		}
		// An initialization segment is a few small boxes. One running to
		// the end, or a big one, means the moov isn't coming.
		if box.size < 0 || box.size > MP4_MAX_BOX {
			return {}, 0, .Invalid
		}
		if box.size > i64(len(data) - pos) {
			return {}, 0, .Need_More
		}
		end := pos + int(box.size)
		if box.kind == mp4_fourcc("moov") {
			moov = data[pos + box.header:end]
		}
		pos = end
	}

	it := Box_Iter{data = moov}
	found := false
	for {
		kind, body := next_box(&it) or_break
		switch kind {
		case mp4_fourcc("trak"):
			if !found {
				found = parse_trak(body, &init, allocator)
			}
		case mp4_fourcc("mvex"):
			mv := Box_Iter{data = body}
			for {
				k, trex := next_box(&mv) or_break
				// version and flags, track_ID, default_sample_description_index,
				// default_sample_duration, default_sample_size, default_sample_flags
				if k == mp4_fourcc("trex") && len(trex) >= 24 {
					init.default_duration = be32(trex[12:])
					init.default_size = be32(trex[16:])
				}
			}
		}
	}
	if !found {
		return {}, 0, .Invalid
	}
	return init, pos, .Ok
}

@(private = "file")
parse_trak :: proc(trak: []u8, init: ^Mp4_Init, allocator: mem.Allocator) -> bool {
	track_id: u32
	if tkhd, ok := find_box(trak, mp4_fourcc("tkhd")); ok && len(tkhd) >= 4 {
		// version 1 has 64-bit times before the id.
		off := 20 if tkhd[0] == 1 else 12
		if len(tkhd) >= off + 4 {
			track_id = be32(tkhd[off:])
		}
	}
	mdia := find_box(trak, mp4_fourcc("mdia")) or_return
	mdhd := find_box(mdia, mp4_fourcc("mdhd")) or_return
	timescale: u32
	duration: u64
	if len(mdhd) >= 4 && mdhd[0] == 1 && len(mdhd) >= 32 {
		timescale = be32(mdhd[20:])
		duration = be_u64(mdhd[24:])
	} else if len(mdhd) >= 20 {
		timescale = be32(mdhd[12:])
		duration = u64(be32(mdhd[16:]))
	}
	minf := find_box(mdia, mp4_fourcc("minf")) or_return
	stbl := find_box(minf, mp4_fourcc("stbl")) or_return
	stsd := find_box(stbl, mp4_fourcc("stsd")) or_return
	if len(stsd) < 8 {
		return false
	}
	entries := Box_Iter{data = stsd[8:]} // version, flags, entry_count
	for {
		kind, entry := next_box(&entries) or_break
		// An AudioSampleEntry has 28 bytes of fields before its boxes.
		if kind != mp4_fourcc("fLaC") || len(entry) < 28 {
			continue
		}
		dfla := find_box(entry[28:], mp4_fourcc("dfLa")) or_continue
		if len(dfla) < 4 + 4 + 34 {
			return false
		}
		head, ok := flac_head_from_dfla(dfla[4:], allocator)
		if !ok {
			return false
		}
		init.track_id = track_id
		init.timescale = timescale
		init.duration = duration
		init.flac_head = head
		return true
	}
	return false
}

// flac_head_from_dfla makes "fLaC" plus the metadata blocks of a dfLa box
// (after its version and flags). It checks the blocks fit, STREAMINFO comes
// first, and marks the last block as last.
@(private = "file")
flac_head_from_dfla :: proc(blocks: []u8, allocator: mem.Allocator) -> ([]u8, bool) {
	pos := 0
	last_header := -1
	for pos + 4 <= len(blocks) {
		if pos == 0 && blocks[0] & 0x7f != 0 {
			return nil, false // STREAMINFO must be first
		}
		size := int(blocks[pos + 1]) << 16 | int(blocks[pos + 2]) << 8 | int(blocks[pos + 3])
		if pos + 4 + size > len(blocks) {
			return nil, false
		}
		last_header = pos
		last := blocks[pos] & 0x80 != 0
		pos += 4 + size
		if last {
			break
		}
	}
	if last_header < 0 {
		return nil, false
	}
	head := make([]u8, 4 + pos, allocator)
	copy(head, "fLaC")
	copy(head[4:], blocks[:pos])
	head[4 + last_header] |= 0x80
	return head, true
}

// parse_mp4_moof reads a moof box (header included) for the track in init
// and appends its samples to samples, with offsets from the moof's start.
// Sample sizes missing from trun come from tfhd's default, then trex's.
//
// Every sample must lie between data_start and data_end, counted from the
// moof's start: the payload of the mdat that follows it. That bounds the
// sample count before anything is appended, so a small moof can't ask for
// millions of samples. moof_at is the moof's offset in its segment file,
// which a tfhd with an explicit base_data_offset counts from. On Invalid,
// samples is as it was and frag.reason says why.
parse_mp4_moof :: proc(moof: []u8, init: ^Mp4_Init, samples: ^[dynamic]Mp4_Sample, data_start, data_end: i64, moof_at: i64 = 0) -> (frag: Mp4_Fragment, status: Parse_Status) {
	first := len(samples)
	refuse :: proc(samples: ^[dynamic]Mp4_Sample, first: int, reason: string) -> (Mp4_Fragment, Parse_Status) {
		resize(samples, first)
		return {reason = reason}, .Invalid
	}
	box, st := mp4_box_header(moof)
	if st != .Ok || box.kind != mp4_fourcc("moof") || box.size != i64(len(moof)) {
		return refuse(samples, first, "not a whole moof box")
	}
	if data_start < i64(len(moof)) || data_end < data_start {
		return refuse(samples, first, "the mdat isn't after the moof")
	}
	it := Box_Iter{data = moof[box.header:]}
	first_traf := true
	for {
		kind, traf := next_box(&it) or_break
		if kind != mp4_fourcc("traf") {
			continue
		}
		is_first := first_traf
		first_traf = false
		tfhd, has_tfhd := find_box(traf, mp4_fourcc("tfhd"))
		if !has_tfhd || len(tfhd) < 8 {
			return refuse(samples, first, "a traf without a tfhd")
		}
		if tfhd[0] != 0 {
			return refuse(samples, first, "an unknown tfhd version")
		}
		flags := be32(tfhd) & 0xffffff
		track_id := be32(tfhd[4:])
		if init.track_id != 0 && track_id != init.track_id {
			continue
		}
		frag.track_id = track_id
		p := 8
		default_size := init.default_size
		// Where the first trun's data_offset counts from (ISO 14496-12
		// 8.8.7): base_data_offset, from the start of the segment file;
		// else the moof, with default-base-is-moof or for the first traf.
		// A later traf without either starts where the previous traf's
		// data ended, which would need the other tracks' sample sizes.
		base := i64(0)
		if flags & 0x01 != 0 {
			if len(tfhd) < p + 8 {
				return refuse(samples, first, "tfhd is too short")
			}
			abs := be_u64(tfhd[p:])
			if abs > u64(max(i64) / 2) {
				return refuse(samples, first, "base_data_offset is out of range")
			}
			base = i64(abs) - moof_at
			p += 8
		} else if flags & 0x020000 == 0 && !is_first {
			return refuse(samples, first, "a second traf without a base offset isn't supported")
		}
		if flags & 0x02 != 0 {
			p += 4
		}
		if flags & 0x08 != 0 {
			p += 4
		}
		if flags & 0x10 != 0 {
			if len(tfhd) < p + 4 {
				return refuse(samples, first, "tfhd is too short")
			}
			default_size = be32(tfhd[p:])
			p += 4
		}
		if tfdt, ok := find_box(traf, mp4_fourcc("tfdt")); ok {
			switch {
			case len(tfdt) >= 12 && tfdt[0] == 1:
				frag.base_time = be_u64(tfdt[4:])
			case len(tfdt) >= 8 && tfdt[0] == 0:
				frag.base_time = u64(be32(tfdt[4:]))
			case:
				return refuse(samples, first, "tfdt is too short or an unknown version")
			}
			frag.has_base_time = true
		}

		// Each trun's data starts at its data_offset from the base, or right
		// after the previous trun's samples.
		next := base
		tr := Box_Iter{data = traf}
		for {
			k, trun := next_box(&tr) or_break
			if k != mp4_fourcc("trun") {
				continue
			}
			if len(trun) < 8 {
				return refuse(samples, first, "trun is too short")
			}
			if trun[0] > 1 {
				return refuse(samples, first, "an unknown trun version")
			}
			tflags := be32(trun) & 0xffffff
			count := i64(be32(trun[4:]))
			if count > i64(MP4_MAX_SAMPLES - (len(samples) - first)) {
				return refuse(samples, first, "too many samples in one fragment")
			}
			q := 8
			if tflags & 0x001 != 0 {
				if len(trun) < q + 4 {
					return refuse(samples, first, "trun is too short")
				}
				next = base + i64(i32(be32(trun[q:])))
				q += 4
			}
			if tflags & 0x004 != 0 {
				q += 4
			}
			per := 0
			for bit in ([]u32{0x100, 0x200, 0x400, 0x800}) {
				per += 4 if tflags & bit != 0 else 0
			}
			if i64(len(trun)) < i64(q) + count * i64(per) {
				return refuse(samples, first, "trun is shorter than its sample table")
			}
			if next < data_start || next > data_end {
				return refuse(samples, first, "a trun's data isn't in the mdat")
			}
			// Each sample is at least a byte, and with sizes from the
			// defaults all of them are the same: both bound the count by
			// what's left of the mdat.
			if tflags & 0x200 == 0 {
				if default_size == 0 {
					return refuse(samples, first, "a sample without a size")
				}
				if count * i64(default_size) > data_end - next {
					return refuse(samples, first, "the samples don't fit in the mdat")
				}
			} else if count > data_end - next {
				return refuse(samples, first, "the samples don't fit in the mdat")
			}
			for _ in 0 ..< count {
				r := q
				if tflags & 0x100 != 0 {
					r += 4
				}
				size := default_size
				if tflags & 0x200 != 0 {
					size = be32(trun[r:])
				}
				if size == 0 || i64(size) > data_end - next {
					return refuse(samples, first, "a sample isn't in the mdat")
				}
				append(samples, Mp4_Sample{offset = next, size = size})
				next += i64(size)
				q += per
			}
		}
		return frag, .Ok
	}
	return refuse(samples, first, "no traf for the track")
}
