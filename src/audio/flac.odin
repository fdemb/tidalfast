package audio

// FLAC container parsing: the metadata blocks before the audio, frame
// headers, and where to start reading for a given sample. Decoding the
// frames themselves is dr_flac's job (third_party/dr_flac, player.odin).

FLAC_MAX_SEEKPOINTS :: 4096

Flac_Info :: struct {
	min_block:     int,
	max_block:     int,
	max_frame:     int, // bytes, 0 when unknown
	sample_rate:   int,
	channels:      int,
	bits:          int,
	total_samples: i64, // 0 when unknown
}

Seekpoint :: struct {
	sample: i64,
	offset: i64, // from the first frame
}

Flac_Header :: struct {
	info:        Flac_Info,
	audio_start: int, // file offset of the first frame
	streaminfo:  int, // file offset of STREAMINFO's 34 bytes
	seekpoints:  [FLAC_MAX_SEEKPOINTS]Seekpoint,
	seek_count:  int,
}

Parse_Status :: enum u8 {
	Ok,
	Need_More,
	Invalid,
}

// parse_flac_header reads the metadata blocks at the start of a file. With
// only part of the file in data it may say Need_More. An ID3v2 tag before
// "fLaC" is skipped.
parse_flac_header :: proc(data: []u8, h: ^Flac_Header) -> Parse_Status {
	h^ = {}
	pos := 0
	if len(data) < 10 {
		return .Need_More
	}
	if data[0] == 'I' && data[1] == 'D' && data[2] == '3' {
		size := int(data[6] & 0x7f) << 21 | int(data[7] & 0x7f) << 14 | int(data[8] & 0x7f) << 7 | int(data[9] & 0x7f)
		pos = 10 + size
	}
	if len(data) < pos + 4 {
		return .Need_More
	}
	if string(data[pos:pos + 4]) != "fLaC" {
		return .Invalid
	}
	pos += 4
	have_info := false
	for {
		if len(data) < pos + 4 {
			return .Need_More
		}
		last := data[pos] & 0x80 != 0
		kind := data[pos] & 0x7f
		size := int(data[pos + 1]) << 16 | int(data[pos + 2]) << 8 | int(data[pos + 3])
		body := pos + 4
		if kind == 127 {
			return .Invalid
		}
		// STREAMINFO and SEEKTABLE are needed whole. Other blocks (pictures,
		// tags, padding) only need to be skipped.
		if (kind == 0 || kind == 3) && len(data) < body + size {
			return .Need_More
		}
		switch kind {
		case 0:
			if size < 34 {
				return .Invalid
			}
			b := data[body:]
			h.streaminfo = body
			h.info.min_block = int(b[0]) << 8 | int(b[1])
			h.info.max_block = int(b[2]) << 8 | int(b[3])
			h.info.max_frame = int(b[7]) << 16 | int(b[8]) << 8 | int(b[9])
			h.info.sample_rate = int(b[10]) << 12 | int(b[11]) << 4 | int(b[12]) >> 4
			h.info.channels = int(b[12] >> 1 & 7) + 1
			h.info.bits = (int(b[12] & 1) << 4 | int(b[13]) >> 4) + 1
			h.info.total_samples = i64(b[13] & 0x0f) << 32 | i64(b[14]) << 24 | i64(b[15]) << 16 | i64(b[16]) << 8 | i64(b[17])
			if h.info.sample_rate == 0 || h.info.max_block < 16 {
				return .Invalid
			}
			have_info = true
		case 3:
			for i := 0; i + 18 <= size && h.seek_count < FLAC_MAX_SEEKPOINTS; i += 18 {
				p := data[body + i:]
				sample := be_u64(p)
				if sample == max(u64) {
					continue // placeholder
				}
				h.seekpoints[h.seek_count] = {i64(sample), i64(be_u64(p[8:]))}
				h.seek_count += 1
			}
		}
		pos = body + size
		if last {
			break
		}
	}
	if !have_info {
		return .Invalid
	}
	// audio_start must lie inside the file, so a file cut inside its last
	// block is caught here.
	if len(data) < pos {
		return .Need_More
	}
	h.audio_start = pos
	return .Ok
}

// flac_decoder_head is the header dr_flac gets: "fLaC" and STREAMINFO alone,
// flagged last, since it needs no other block and a picture can be
// megabytes. Frames come after it from wherever a seek put us, so the
// sample count, which dr_flac would count from the first frame it sees,
// goes to 0 (unknown).
flac_decoder_head :: proc(data: []u8, h: ^Flac_Header, allocator := context.allocator) -> []u8 {
	head := make([]u8, 42, allocator)
	copy(head, "fLaC")
	head[4], head[7] = 0x80, 34 // last block, type 0 (STREAMINFO), length 34
	si := head[8:]
	copy(si, data[h.streaminfo:][:34])
	si[13] &= 0xf0
	si[14], si[15], si[16], si[17] = 0, 0, 0, 0
	return head
}

be_u64 :: proc(b: []u8) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v = v << 8 | u64(b[i])
	}
	return v
}

Frame_Header :: struct {
	sample:   i64, // the frame's first sample
	block:    int, // samples in the frame
	size:     int, // header bytes, CRC included
	variable: bool, // variable block size: the coded number is a sample number
}

// parse_frame_header checks for a valid frame header at the start of b that
// fits info: sync code, reserved bits, the CRC-8 and the stream's rate,
// channels and bit depth when the header names them.
parse_frame_header :: proc(b: []u8, info: Flac_Info) -> (fh: Frame_Header, status: Parse_Status) {
	if len(b) < 2 {
		return {}, .Need_More
	}
	if b[0] != 0xff || b[1] & 0xfe != 0xf8 {
		return {}, .Invalid
	}
	if len(b) < 4 {
		return {}, .Need_More
	}
	fh.variable = b[1] & 1 != 0
	block_code := b[2] >> 4
	rate_code := b[2] & 0x0f
	channel_code := b[3] >> 4
	bits_code := b[3] >> 1 & 7
	if block_code == 0 || rate_code == 15 || channel_code > 10 || bits_code == 3 || b[3] & 1 != 0 {
		return {}, .Invalid
	}
	channels := int(channel_code) + 1 if channel_code < 8 else 2
	if channels != info.channels {
		return {}, .Invalid
	}
	if bits_code != 0 {
		BITS := [8]int{0, 8, 12, 0, 16, 20, 24, 32}
		if BITS[bits_code] != info.bits {
			return {}, .Invalid
		}
	}

	// The frame or sample number, coded like UTF-8 up to 7 bytes.
	pos := 4
	if len(b) <= pos {
		return {}, .Need_More
	}
	first := b[pos]
	extra := 0
	number: u64
	switch {
	case first & 0x80 == 0:
		number = u64(first)
	case first & 0xe0 == 0xc0:
		extra, number = 1, u64(first & 0x1f)
	case first & 0xf0 == 0xe0:
		extra, number = 2, u64(first & 0x0f)
	case first & 0xf8 == 0xf0:
		extra, number = 3, u64(first & 0x07)
	case first & 0xfc == 0xf8:
		extra, number = 4, u64(first & 0x03)
	case first & 0xfe == 0xfc:
		extra, number = 5, u64(first & 0x01)
	case first == 0xfe:
		extra, number = 6, 0
	case:
		return {}, .Invalid
	}
	if !fh.variable && extra > 5 {
		return {}, .Invalid
	}
	pos += 1
	if len(b) < pos + extra {
		return {}, .Need_More
	}
	for i in 0 ..< extra {
		c := b[pos + i]
		if c & 0xc0 != 0x80 {
			return {}, .Invalid
		}
		number = number << 6 | u64(c & 0x3f)
	}
	pos += extra

	switch block_code {
	case 1:
		fh.block = 192
	case 2 ..= 5:
		fh.block = 576 << (block_code - 2)
	case 6:
		if len(b) < pos + 1 {
			return {}, .Need_More
		}
		fh.block = int(b[pos]) + 1
		pos += 1
	case 7:
		if len(b) < pos + 2 {
			return {}, .Need_More
		}
		fh.block = (int(b[pos]) << 8 | int(b[pos + 1])) + 1
		pos += 2
	case:
		fh.block = 256 << (block_code - 8)
	}
	if fh.block > info.max_block {
		return {}, .Invalid
	}

	rate := 0
	switch rate_code {
	case 0:
		rate = info.sample_rate
	case 1 ..= 11:
		RATES := [12]int{0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000}
		rate = RATES[rate_code]
	case 12:
		if len(b) < pos + 1 {
			return {}, .Need_More
		}
		rate = int(b[pos]) * 1000
		pos += 1
	case 13, 14:
		if len(b) < pos + 2 {
			return {}, .Need_More
		}
		rate = int(b[pos]) << 8 | int(b[pos + 1])
		if rate_code == 14 {
			rate *= 10
		}
		pos += 2
	}
	if rate != info.sample_rate {
		return {}, .Invalid
	}

	if len(b) < pos + 1 {
		return {}, .Need_More
	}
	if crc8(b[:pos]) != b[pos] {
		return {}, .Invalid
	}
	fh.size = pos + 1
	if fh.variable {
		fh.sample = i64(number)
	} else {
		fh.sample = i64(number) * i64(info.max_block)
	}
	return fh, .Ok
}

// crc8 is FLAC's frame header CRC: polynomial x^8 + x^2 + x + 1, initial 0.
crc8 :: proc(b: []u8) -> u8 {
	crc: u8
	for c in b {
		crc ~= c
		for _ in 0 ..< 8 {
			crc = (crc << 1) ~ 0x07 if crc & 0x80 != 0 else crc << 1
		}
	}
	return crc
}

// find_frame finds the first frame header in data that the next header
// confirms: the one after it must start where this frame's samples end. A
// lone header passes only at the end of the file (at_eof), since a CRC-8 on
// its own lets about one in 256 random byte pairs through. Returns the
// header's offset in data and its first sample.
find_frame :: proc(data: []u8, info: Flac_Info, at_eof: bool) -> (offset: int, sample: i64, status: Parse_Status) {
	// A frame is never larger than this, so the confirming header must turn
	// up within it.
	limit := info.max_frame if info.max_frame > 0 else info.max_block * info.channels * 4 + 64
	for i := 0; i + 1 < len(data); i += 1 {
		if data[i] != 0xff {
			continue
		}
		fh, st := parse_frame_header(data[i:], info)
		if st == .Need_More {
			return 0, 0, .Need_More if !at_eof else .Invalid
		}
		if st != .Ok {
			continue
		}
		end := min(len(data), i + fh.size + limit + 16)
		confirmed := false
		for j := i + fh.size; j + 1 < end; j += 1 {
			if data[j] != 0xff {
				continue
			}
			next, nst := parse_frame_header(data[j:], info)
			if nst == .Ok && next.sample == fh.sample + i64(fh.block) {
				confirmed = true
				break
			}
			if nst == .Need_More {
				break
			}
		}
		if confirmed {
			return i, fh.sample, .Ok
		}
		if end == len(data) {
			if at_eof {
				return i, fh.sample, .Ok
			}
			// The confirming header may be in bytes not here yet.
			return 0, 0, .Need_More
		}
	}
	return 0, 0, .Need_More if !at_eof else .Invalid
}

// Seek_Bounds brackets a target sample between two known frame starts.
// Offsets are file offsets.
Seek_Bounds :: struct {
	lo_sample, lo_offset: i64,
	hi_sample, hi_offset: i64,
}

// seek_bounds starts the search for target: the seekpoints around it if the
// file has a SEEKTABLE, else the first frame and the end of the file.
seek_bounds :: proc(h: ^Flac_Header, target: i64, file_size: i64) -> Seek_Bounds {
	total := h.info.total_samples
	b := Seek_Bounds {
		lo_sample = 0,
		lo_offset = i64(h.audio_start),
		hi_sample = total,
		hi_offset = file_size,
	}
	for sp in h.seekpoints[:h.seek_count] {
		// A damaged table can point anywhere, and an offset before the file
		// would make the stream read before its window.
		if sp.offset < 0 || sp.offset > file_size - i64(h.audio_start) {
			continue
		}
		off := i64(h.audio_start) + sp.offset
		if sp.sample <= target && sp.sample >= b.lo_sample {
			b.lo_sample, b.lo_offset = sp.sample, off
		} else if sp.sample > target && sp.sample < b.hi_sample {
			b.hi_sample, b.hi_offset = sp.sample, off
		}
	}
	return b
}

// seek_guess picks the byte offset to probe for target inside b: linear in
// samples, aimed lead samples early so the frame found is more likely just
// before the target than after it.
seek_guess :: proc(b: Seek_Bounds, target: i64, lead: i64) -> i64 {
	if b.hi_sample <= b.lo_sample || b.hi_offset <= b.lo_offset {
		return b.lo_offset
	}
	aim := clamp(target - lead, b.lo_sample, b.hi_sample)
	frac := f64(aim - b.lo_sample) / f64(b.hi_sample - b.lo_sample)
	return b.lo_offset + i64(frac * f64(b.hi_offset - b.lo_offset))
}

// seek_update narrows b with a frame found at offset starting at sample.
seek_update :: proc(b: ^Seek_Bounds, target, sample, offset: i64) {
	if sample <= target {
		if sample >= b.lo_sample {
			b.lo_sample, b.lo_offset = sample, offset
		}
	} else if sample < b.hi_sample || b.hi_sample <= b.lo_sample {
		b.hi_sample, b.hi_offset = sample, offset
	}
}
