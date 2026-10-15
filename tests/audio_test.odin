package tidal_tests

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:testing"

import "../src/audio"
import tidal "../src/tidal"

// A FLAC encoder just good enough for tests: verbatim subframes, fixed
// block size, 16-bit stereo, optional SEEKTABLE and PADDING.

@(private = "file")
TEST_BLOCK :: 1152

@(private = "file")
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

// test_flac encodes frames*TEST_BLOCK samples of a counter signal. Seek
// points go every seek_every frames (0 for no SEEKTABLE).
@(private = "file")
test_flac :: proc(frames: int, seek_every: int) -> (file: []u8, audio_start: int) {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 'f', 'L', 'a', 'C')
	total := frames * TEST_BLOCK
	// STREAMINFO
	append(&out, 0, 0, 0, 34)
	si := [34]u8{}
	si[0], si[1] = u8(TEST_BLOCK >> 8), u8(TEST_BLOCK & 0xff)
	si[2], si[3] = u8(TEST_BLOCK >> 8), u8(TEST_BLOCK & 0xff)
	rate := 44100
	si[10] = u8(rate >> 12)
	si[11] = u8(rate >> 4)
	si[12] = u8(rate << 4) | (1 << 1) | 0 // 2 channels, bits-1 = 15: high bit 0
	si[13] = (15 & 0x0f) << 4 | u8(total >> 32)
	si[14], si[15], si[16], si[17] = u8(total >> 24), u8(total >> 16), u8(total >> 8), u8(total)
	append(&out, ..si[:])

	// Frames first, to know their offsets.
	frames_buf := make([dynamic]u8, context.temp_allocator)
	offsets := make([dynamic]int, context.temp_allocator)
	for f in 0 ..< frames {
		append(&offsets, len(frames_buf))
		start := len(frames_buf)
		// Sync, fixed blocking; block size code 0b0111 (16-bit size follows), rate 0b1001 (44.1k);
		// independent stereo (channel code 1), 16 bit.
		append(&frames_buf, 0xff, 0xf8, 0x79, 0x18)
		// Frame number as UTF-8.
		if f < 0x80 {
			append(&frames_buf, u8(f))
		} else {
			append(&frames_buf, 0xc0 | u8(f >> 6), 0x80 | u8(f & 0x3f))
		}
		append(&frames_buf, u8((TEST_BLOCK - 1) >> 8), u8((TEST_BLOCK - 1) & 0xff))
		append(&frames_buf, audio.crc8(frames_buf[start:]))
		for ch in 0 ..< 2 {
			append(&frames_buf, 0x02) // verbatim
			for i in 0 ..< TEST_BLOCK {
				v := i16((f * TEST_BLOCK + i) * (ch + 1))
				append(&frames_buf, u8(u16(v) >> 8), u8(u16(v)))
			}
		}
		c := crc16(frames_buf[start:])
		append(&frames_buf, u8(c >> 8), u8(c))
	}

	if seek_every > 0 {
		n := (frames + seek_every - 1) / seek_every
		size := n * 18
		append(&out, 3, u8(size >> 16), u8(size >> 8), u8(size))
		for k in 0 ..< n {
			f := k * seek_every
			be := proc(out: ^[dynamic]u8, v: u64) {
				for i := 7; i >= 0; i -= 1 {
					append(out, u8(v >> uint(i * 8)))
				}
			}
			be(&out, u64(f * TEST_BLOCK))
			be(&out, u64(offsets[f]))
			append(&out, u8(TEST_BLOCK >> 8), u8(TEST_BLOCK & 0xff))
		}
	}
	append(&out, 0x80 | 1, 0, 0, 100) // PADDING, last
	for _ in 0 ..< 100 {
		append(&out, 0)
	}
	audio_start = len(out)
	append(&out, ..frames_buf[:])
	return out[:], audio_start
}

@(test)
flac_header :: proc(t: ^testing.T) {
	file, start := test_flac(40, 10)
	h := new(audio.Flac_Header, context.temp_allocator)
	testing.expect_value(t, audio.parse_flac_header(file[:20], h), audio.Parse_Status.Need_More)
	testing.expect_value(t, audio.parse_flac_header(file, h), audio.Parse_Status.Ok)
	testing.expect_value(t, h.audio_start, start)
	testing.expect_value(t, h.info.sample_rate, 44100)
	testing.expect_value(t, h.info.channels, 2)
	testing.expect_value(t, h.info.bits, 16)
	testing.expect_value(t, h.info.max_block, TEST_BLOCK)
	testing.expect_value(t, h.info.total_samples, i64(40 * TEST_BLOCK))
	testing.expect_value(t, h.seek_count, 4)
	testing.expect_value(t, h.seekpoints[1].sample, i64(10 * TEST_BLOCK))
	// The header alone is enough; frames needn't be there.
	testing.expect_value(t, audio.parse_flac_header(file[:start], h), audio.Parse_Status.Ok)
	testing.expect_value(t, audio.parse_flac_header(transmute([]u8)string("OggS and more bytes"), h), audio.Parse_Status.Invalid)
}

@(test)
flac_frames :: proc(t: ^testing.T) {
	file, start := test_flac(200, 0)
	h := new(audio.Flac_Header, context.temp_allocator)
	audio.parse_flac_header(file, h)
	frame_len := (len(file) - start) / 200 // frames 0..127 have a 1-byte number, the rest 2
	fh, st := audio.parse_frame_header(file[start:], h.info)
	testing.expect_value(t, st, audio.Parse_Status.Ok)
	testing.expect_value(t, fh.sample, i64(0))
	testing.expect_value(t, fh.block, TEST_BLOCK)

	// A broken CRC-8 is not a header.
	bad := make([]u8, 16, context.temp_allocator)
	copy(bad, file[start:start + 16])
	bad[fh.size - 1] ~= 0x5a
	_, st = audio.parse_frame_header(bad, h.info)
	testing.expect_value(t, st, audio.Parse_Status.Invalid)

	// From the middle of a frame, find_frame lands on the next one. The
	// counter samples contain 0xff bytes, so false syncs are tried on the way.
	for probe in ([]int{1, frame_len / 2, 130 * frame_len + 17, 150 * frame_len + 3}) {
		off, sample, fst := audio.find_frame(file[start + probe:], h.info, false)
		testing.expect_value(t, fst, audio.Parse_Status.Ok)
		at := start + probe + off
		next, nst := audio.parse_frame_header(file[at:], h.info)
		testing.expect_value(t, nst, audio.Parse_Status.Ok)
		testing.expect_value(t, next.sample, sample)
		testing.expect(t, sample % TEST_BLOCK == 0)
		testing.expect(t, off <= frame_len + 8, fmt.tprintf("probe %d skipped %d bytes", probe, off))
	}
	// Too few bytes to confirm a header asks for more; at the end of the
	// file the last frame passes alone.
	_, _, fst := audio.find_frame(file[start + 5 * frame_len:start + 5 * frame_len + 40], h.info, false)
	testing.expect_value(t, fst, audio.Parse_Status.Need_More)
	off, sample, est := audio.find_frame(file[len(file) - frame_len - 4:], h.info, true)
	testing.expect_value(t, est, audio.Parse_Status.Ok)
	testing.expect_value(t, sample, i64(199 * TEST_BLOCK))
	// The last frame: a 9-byte header, two verbatim subframes and the CRC-16.
	last_size := 9 + 2 * (1 + 2 * TEST_BLOCK) + 2
	testing.expect_value(t, len(file) - frame_len - 4 + off, len(file) - last_size)
}

// search runs the player's seek search over a file in memory, counting
// probes: bounds from seek_bounds, guesses from seek_guess, a frame found
// with find_frame at each guess.
@(private = "file")
search :: proc(file: []u8, h: ^audio.Flac_Header, target: i64, near: i64) -> (offset, sample: i64, probes: int) {
	b := audio.seek_bounds(h, target, i64(len(file)))
	lead := i64(h.info.sample_rate / 4)
	for _ in 0 ..< 8 {
		if target - b.lo_sample <= near {
			break
		}
		guess := audio.seek_guess(b, target, lead)
		if guess <= b.lo_offset || guess >= b.hi_offset {
			break
		}
		probes += 1
		rel, s, st := audio.find_frame(file[guess:min(len(file), int(guess) + 64 << 10)], h.info, int(guess) + 64 << 10 >= len(file))
		if st != .Ok {
			b.hi_offset = guess
			continue
		}
		audio.seek_update(&b, target, s, guess + i64(rel))
		lead *= 2
	}
	return b.lo_offset, b.lo_sample, probes
}

@(test)
flac_seek :: proc(t: ^testing.T) {
	for seek_every in ([]int{0, 10}) {
		file, _ := test_flac(400, seek_every) // about 10 s
		h := new(audio.Flac_Header, context.temp_allocator)
		audio.parse_flac_header(file, h)
		near := i64(44100)
		for target in ([]i64{0, 500, 44100 * 3 + 17, 44100 * 7, 400 * TEST_BLOCK - 1}) {
			off, sample, probes := search(file, h, target, near)
			testing.expect(t, sample <= target && target - sample <= near, fmt.tprintf("target %d: frame at %d", target, sample))
			fh, st := audio.parse_frame_header(file[off:], h.info)
			testing.expect_value(t, st, audio.Parse_Status.Ok)
			testing.expect_value(t, fh.sample, sample)
			testing.expect(t, probes <= 2, fmt.tprintf("target %d took %d probes (seektable %v)", target, probes, seek_every > 0))
		}
	}
	// Bounds: the seekpoints around the target.
	file, start := test_flac(100, 10)
	h := new(audio.Flac_Header, context.temp_allocator)
	audio.parse_flac_header(file, h)
	b := audio.seek_bounds(h, 25 * TEST_BLOCK, i64(len(file)))
	testing.expect_value(t, b.lo_sample, i64(20 * TEST_BLOCK))
	testing.expect_value(t, b.hi_sample, i64(30 * TEST_BLOCK))
	testing.expect(t, b.lo_offset > i64(start) && b.hi_offset > b.lo_offset)
	g := audio.seek_guess(b, 25 * TEST_BLOCK, 0)
	testing.expect(t, abs(g - (b.lo_offset + b.hi_offset) / 2) <= 1)
}

@(test)
pcm_ring :: proc(t: ^testing.T) {
	r: audio.Pcm_Ring
	data := make([]f32, 16 * 2, context.temp_allocator)
	audio.ring_init(&r, data, 16, 2)
	in_ := make([]f32, 24 * 2, context.temp_allocator)
	for i in 0 ..< len(in_) {
		in_[i] = f32(i)
	}
	testing.expect_value(t, audio.ring_write(&r, in_[:10 * 2]), u64(10))
	testing.expect_value(t, audio.ring_free_frames(&r), u64(6))
	testing.expect_value(t, audio.ring_write(&r, in_[10 * 2:]), u64(6)) // only 6 fit
	out: [32]f32
	testing.expect_value(t, audio.ring_read(&r, &out[0], 4, 1, 1), u64(4))
	testing.expect_value(t, out[7], f32(7))
	// Wraps around.
	testing.expect_value(t, audio.ring_write(&r, in_[:4 * 2]), u64(4))
	n := audio.ring_read(&r, &out[0], 16, 1, 1)
	testing.expect_value(t, n, u64(16))
	testing.expect_value(t, out[0], f32(8))
	testing.expect_value(t, out[2 * 12], f32(0)) // the wrapped write
	testing.expect_value(t, audio.ring_buffered(&r), u64(0))

	// A flush drops what's unread; the reader skips to it.
	audio.ring_write(&r, in_[:5 * 2])
	at := audio.ring_flush(&r)
	audio.ring_write(&r, in_[40:44])
	testing.expect_value(t, audio.ring_buffered(&r), u64(2))
	n = audio.ring_read(&r, &out[0], 8, 1, 1)
	testing.expect_value(t, n, u64(2))
	testing.expect_value(t, out[0], f32(40))
	testing.expect_value(t, r.read, at + 2)

	// The gain ramps linearly to its target over the frames read.
	ones := []f32{1, 1, 1, 1, 1, 1, 1, 1}
	audio.ring_write(&r, ones)
	audio.ring_read(&r, &out[0], 4, 0, 1)
	testing.expect_value(t, out[0], f32(0.25))
	testing.expect_value(t, out[7], f32(1))

	// Marks: the reader adopts each once it reads past its position.
	q: audio.Mark_Queue
	audio.mark_push(&q, {at = 0, serial = 1})
	audio.mark_push(&q, {at = 100, serial = 2})
	audio.mark_push(&q, {at = 100, serial = 2, sample = 500, seek_id = 1})
	testing.expect(t, audio.mark_advance(&q, 50))
	testing.expect_value(t, q.cur.serial, u64(1))
	testing.expect(t, !audio.mark_advance(&q, 99))
	testing.expect(t, audio.mark_advance(&q, 100))
	testing.expect_value(t, q.cur.sample, i64(500))
	for _ in 0 ..< audio.MARKS - 1 {
		audio.mark_push(&q, {at = 1000})
	}
	testing.expect(t, !audio.mark_push(&q, {at = 1000}), "a full queue refuses a mark")
}

@(test)
replay_gain :: proc(t: ^testing.T) {
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-4}
	rg := audio.Replay_Gain{track_gain = -6.0206, track_peak = 0.9, album_gain = 3, album_peak = 0.95}
	testing.expect(t, near(audio.replay_gain_linear(rg, .Track), 0.5))
	// +3 dB is x1.413, but the album peak of 0.95 limits it to 1/0.95.
	testing.expect(t, near(audio.replay_gain_linear(rg, .Album), 1 / 0.95))
	rg.album_peak = 0.5
	testing.expect(t, near(audio.replay_gain_linear(rg, .Album), f32(math.pow(10, 3.0 / 20))))
	testing.expect(t, near(audio.replay_gain_linear({track_peak = 1, album_peak = 1}, .Track), 1))
	testing.expect_value(t, audio.volume_gain(1), f32(1))
	testing.expect_value(t, audio.volume_gain(0), f32(0))
	testing.expect(t, near(audio.volume_gain(0.5), 0.125))
	testing.expect_value(t, audio.volume_gain(2), f32(1))
}

@(test)
play_queue :: proc(t: ^testing.T) {
	q := []audio.Queue_Entry {
		{id = 1, album_id = 7, track_num = 1},
		{id = 2, album_id = 7, track_num = 2},
		{id = 0}, // not playable
		{id = 4, album_id = 7, track_num = 3},
		{id = 5, album_id = 9, track_num = 4},
		{id = 6, album_id = 8, track_num = 1},
	}
	testing.expect_value(t, audio.queue_next(q, -1), 0)
	testing.expect_value(t, audio.queue_next(q, 1), 3)
	testing.expect_value(t, audio.queue_next(q, 5), -1)
	testing.expect_value(t, audio.queue_previous(q, 3), 1)
	testing.expect_value(t, audio.queue_previous(q, 0), -1)
	// Previous restarts the track after a few seconds, else goes back.
	testing.expect_value(t, audio.queue_previous_action(q, 3, 10), 3)
	testing.expect_value(t, audio.queue_previous_action(q, 3, 1), 1)
	testing.expect_value(t, audio.queue_previous_action(q, 0, 1), 0)
	// Album gain when the neighbours are the same album in order.
	testing.expect_value(t, audio.queue_gain_mode(q, 0), audio.Gain_Mode.Album)
	testing.expect_value(t, audio.queue_gain_mode(q, 1), audio.Gain_Mode.Album)
	testing.expect_value(t, audio.queue_gain_mode(q, 3), audio.Gain_Mode.Track) // a hole before it
	testing.expect_value(t, audio.queue_gain_mode(q, 4), audio.Gain_Mode.Track)
	testing.expect_value(t, audio.queue_gain_mode(q, 5), audio.Gain_Mode.Track)
	shuffled := []audio.Queue_Entry{{id = 1, album_id = 7, track_num = 3}, {id = 2, album_id = 7, track_num = 1}}
	testing.expect_value(t, audio.queue_gain_mode(shuffled, 0), audio.Gain_Mode.Track)
}

@(private = "file")
playback_json :: proc(mime, manifest: string, extra := "") -> json.Object {
	encoded, _ := base64.encode(transmute([]u8)manifest, allocator = context.temp_allocator)
	src := fmt.tprintf(`{{"trackId":42,"audioQuality":"LOSSLESS","manifestMimeType":"%s","manifest":"%s","bitDepth":16,"sampleRate":44100%s}}`, mime, encoded, extra)
	v, _ := json.parse_string(src, .JSON, true, context.temp_allocator)
	return v.(json.Object)
}

@(test)
playback_info :: proc(t: ^testing.T) {
	BTS :: "application/vnd.tidal.bts"
	flac := `{"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":["https://cdn.example/42.flac?token=x"]}`
	info, err := tidal.parse_playback_info(playback_json(BTS, flac, `,"trackReplayGain":-7.5,"trackPeakAmplitude":0.98,"albumReplayGain":-8.25,"albumPeakAmplitude":0.999`), context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, info.url, "https://cdn.example/42.flac?token=x")
	testing.expect_value(t, info.codec, "FLAC")
	testing.expect_value(t, info.track_id, i64(42))
	testing.expect_value(t, info.track_gain, -7.5)
	testing.expect_value(t, info.album_gain, -8.25)
	testing.expect_value(t, info.album_peak, 0.999)

	// No gains: 0 dB and a peak of 1, so nothing changes.
	info, err = tidal.parse_playback_info(playback_json(BTS, flac), context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, info.track_gain, 0.0)
	testing.expect_value(t, info.track_peak, 1.0)
	// Only a track gain: the album falls back to it.
	info, _ = tidal.parse_playback_info(playback_json(BTS, flac, `,"trackReplayGain":-3,"trackPeakAmplitude":0.5`), context.temp_allocator)
	testing.expect_value(t, info.album_gain, -3.0)
	testing.expect_value(t, info.album_peak, 0.5)

	refused :: proc(t: ^testing.T, obj: json.Object, kind: tidal.Error_Kind, loc := #caller_location) {
		_, err := tidal.parse_playback_info(obj, context.temp_allocator)
		e, failed := err.?
		testing.expect(t, failed, "should be refused", loc = loc)
		testing.expect_value(t, e.kind, kind, loc = loc)
	}
	refused(t, playback_json(BTS, `{"mimeType":"audio/flac","codecs":"flac","encryptionType":"OLD_AES","keyId":"abc","urls":["u"]}`), .Stream_Not_Available)
	refused(t, playback_json(BTS, `{"mimeType":"audio/mp4","codecs":"mp4a.40.2","encryptionType":"NONE","urls":["u"]}`), .Stream_Not_Available)
	refused(t, playback_json(BTS, `{"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":[]}`), .Manifest_Decode)
	refused(t, playback_json(BTS, `not json`), .Manifest_Decode)
	refused(t, playback_json("application/dash+xml", `<MPD/>`), .Unknown_Manifest_Format)
}
