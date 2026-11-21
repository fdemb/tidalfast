package tidal_tests

// Damaged input for every parser of bytes the app doesn't control: DASH
// segments and manifests from the CDN, FLAC headers and frames, TIDAL's
// JSON, cover images, and the files the app keeps on disk, which a crash
// can leave cut short. Each parser gets every truncation of a good input,
// single-byte damage at positions from a fixed seed, and hostile size and
// count fields. None may crash, read out of bounds (a bounds check panic
// here), loop without end or allocate by a length the input names.

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import stbi "vendor:stb/image"

import app "../src/app"
import "../src/audio"
import "../src/cover"
import tidal "../src/tidal"
import "dashgen"

@(private = "file")
Ci_Rng :: struct {
	s: u64,
}

@(private = "file")
ci_next :: proc(r: ^Ci_Rng) -> u64 {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return r.s
}

// ci_damage changes one to three bytes of buf, favouring 0x00 and 0xff,
// which is what size and count fields go wrong with.
@(private = "file")
ci_damage :: proc(r: ^Ci_Rng, buf: []u8, lo := 0, hi := -1) {
	hi := len(buf) if hi < 0 else min(hi, len(buf))
	if hi <= lo {
		return
	}
	for _ in 0 ..< 1 + ci_next(r) % 3 {
		i := lo + int(ci_next(r) % u64(hi - lo))
		switch ci_next(r) % 3 {
		case 0:
			buf[i] = 0xff
		case 1:
			buf[i] = 0
		case:
			buf[i] = u8(ci_next(r))
		}
	}
}

@(private = "file")
ci_put_be32 :: proc(b: []u8, at: int, v: u32) {
	b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

@(private = "file")
ci_put_le32 :: proc(b: []u8, at: int, v: u32) {
	b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

// Values a size or count field holds when it's wrong.
@(private = "file")
CI_HOSTILE :: [?]u32{0, 1, 7, 8, 15, 0x7fff_ffff, 0x8000_0000, 0xffff_fff0, 0xffff_ffff}

// ci_inside says whether s is empty or lies inside buf.
@(private = "file")
ci_inside :: proc(s: string, buf: []u8) -> bool {
	if len(s) == 0 {
		return true
	}
	p, lo := uintptr(raw_data(s)), uintptr(raw_data(buf))
	return p >= lo && p + uintptr(len(s)) <= lo + uintptr(len(buf))
}

// The DASH segments of a short 16/48 stream.
@(private = "file")
ci_dash :: proc() -> dashgen.Dash {
	pcm := dashgen.quiet_signal(int(1.2 * 48000), 2, 16, 7, context.temp_allocator)
	flac := dashgen.encode_verbatim(pcm, 2, 16, 48000, 4096, context.temp_allocator)
	d, ok := dashgen.from_flac(flac, 0.5, context.temp_allocator)
	assert(ok)
	return d
}

@(private = "file")
ci_check_moof :: proc(t: ^testing.T, moof: []u8, init: ^audio.Mp4_Init, samples: ^[dynamic]audio.Mp4_Sample, data_start, data_end: i64) {
	clear(samples)
	_, st := audio.parse_mp4_moof(moof, init, samples, data_start, data_end)
	if st != .Ok {
		testing.expect_value(t, len(samples), 0)
		return
	}
	testing.expect(t, len(samples) <= audio.MP4_MAX_SAMPLES)
	for smp in samples {
		if smp.offset < data_start || smp.offset + i64(smp.size) > data_end {
			testing.fail_now(t, "a sample outside the mdat")
		}
	}
}

// What read_init does with an initialization segment: the dfLa's blocks
// must make a FLAC header the decoder can take.
@(private = "file")
ci_check_init :: proc(t: ^testing.T, data: []u8, h: ^audio.Flac_Header) {
	init, used, st := audio.parse_mp4_init(data, context.temp_allocator)
	if st != .Ok {
		return
	}
	testing.expect(t, used > 0 && used <= len(data))
	if audio.parse_flac_header(init.flac_head, h) == .Ok {
		testing.expect(t, h.streaminfo + 34 <= len(init.flac_head))
		_ = audio.flac_decoder_head(init.flac_head, h, context.temp_allocator)
	}
}

@(test)
corrupt_fmp4 :: proc(t: ^testing.T) {
	dash := ci_dash()
	h := new(audio.Flac_Header, context.temp_allocator)
	init, used, st := audio.parse_mp4_init(dash.init, context.temp_allocator)
	testing.expect_value(t, st, audio.Parse_Status.Ok)

	// A cut short initialization segment is never taken.
	for n in 0 ..< used {
		_, _, s := audio.parse_mp4_init(dash.init[:n], context.temp_allocator)
		testing.expectf(t, s != .Ok, "an init segment cut to %d of %d bytes parsed", n, used)
	}

	seg := dash.segments[0]
	styp, _ := audio.mp4_box_header(seg)
	moof_box, _ := audio.mp4_box_header(seg[styp.size:])
	mdat, _ := audio.mp4_box_header(seg[styp.size + moof_box.size:])
	moof := seg[styp.size:][:moof_box.size]
	data_start, data_end := moof_box.size + i64(mdat.header), moof_box.size + mdat.size
	samples := make([dynamic]audio.Mp4_Sample, context.temp_allocator)
	ci_check_moof(t, moof, &init, &samples, data_start, data_end)
	testing.expect(t, len(samples) > 0)

	// Nor a cut short moof, and box headers read from any prefix are sane.
	for n in 0 ..< len(moof) {
		clear(&samples)
		_, s := audio.parse_mp4_moof(moof[:n], &init, &samples, data_start, data_end)
		testing.expect_value(t, s, audio.Parse_Status.Invalid)
		testing.expect_value(t, len(samples), 0)
	}
	for n in 0 ..< len(seg) {
		box, s := audio.mp4_box_header(seg[:n])
		if s == .Ok {
			testing.expect(t, box.size == -1 || box.size >= i64(box.header))
		}
	}

	// Hostile 32-bit fields at every offset: box sizes of zero, smaller than
	// their header, past the end, sample counts whose table can't fit, and
	// 64-bit sizes that come out negative.
	hostile :: proc(t: ^testing.T, orig: []u8, buf: []u8, i: int, check: proc(t: ^testing.T, buf: []u8, ctx: rawptr), ctx: rawptr) {
		for v in CI_HOSTILE {
			copy(buf, orig)
			ci_put_be32(buf, i, v)
			check(t, buf, ctx)
		}
		copy(buf, orig)
		ci_put_be32(buf, i, u32(len(orig) - i + 1))
		check(t, buf, ctx)
		if i + 16 <= len(orig) {
			copy(buf, orig)
			ci_put_be32(buf, i, 1)
			for k in 0 ..< 8 {
				buf[i + 8 + k] = 0xff
			}
			check(t, buf, ctx)
		}
	}
	Moof_Ctx :: struct {
		init:                 ^audio.Mp4_Init,
		samples:              ^[dynamic]audio.Mp4_Sample,
		data_start, data_end: i64,
	}
	mctx := Moof_Ctx{&init, &samples, data_start, data_end}
	mbuf := make([]u8, len(moof), context.temp_allocator)
	for i in 0 ..= len(moof) - 4 {
		hostile(t, moof, mbuf, i, proc(t: ^testing.T, buf: []u8, ctx: rawptr) {
			c := (^Moof_Ctx)(ctx)
			ci_check_moof(t, buf, c.init, c.samples, c.data_start, c.data_end)
		}, &mctx)
	}
	ibuf := make([]u8, len(dash.init), context.temp_allocator)
	for i in 0 ..= len(dash.init) - 4 {
		hostile(t, dash.init, ibuf, i, proc(t: ^testing.T, buf: []u8, ctx: rawptr) {
			ci_check_init(t, buf, (^audio.Flac_Header)(ctx))
		}, h)
	}

	// And damage at random.
	rng := Ci_Rng{0x5EED_F4F4}
	for _ in 0 ..< 3000 {
		copy(mbuf, moof)
		ci_damage(&rng, mbuf)
		ci_check_moof(t, mbuf, &init, &samples, data_start, data_end)
		copy(ibuf, dash.init)
		ci_damage(&rng, ibuf)
		ci_check_init(t, ibuf, h)
	}
}

// A FLAC file of a second of 16/48 noise with a SEEKTABLE of points, each
// a sample number and an offset from the first frame.
@(private = "file")
ci_flac :: proc(points: [][2]u64) -> []u8 {
	pcm := dashgen.quiet_signal(48000, 2, 16, 3, context.temp_allocator)
	flac := dashgen.encode_verbatim(pcm, 2, 16, 48000, 1024, context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..flac[:42])
	out[4] &= 0x7f // STREAMINFO is no longer the last block
	size := 18 * len(points)
	append(&out, 0x83, u8(size >> 16), u8(size >> 8), u8(size))
	for p in points {
		for v in p {
			for k in 0 ..< 8 {
				append(&out, u8(v >> (56 - 8 * uint(k))))
			}
		}
		append(&out, 0x04, 0x00)
	}
	append(&out, ..flac[42:])
	return out[:]
}

// ci_check_seek says whether a seek in a parsed header only ever lands
// inside the file, as find_start's offsets must: a negative one indexes
// the stream's ring before its start.
@(private = "file")
ci_check_seek :: proc(t: ^testing.T, h: ^audio.Flac_Header, file_size: i64) -> bool {
	ok := true
	for target in ([]i64{0, 50, 1000, 24000, 47999, 1 << 40}) {
		b := audio.seek_bounds(h, target, file_size)
		guess := audio.seek_guess(b, target, 4800)
		for off in ([]i64{b.lo_offset, b.hi_offset, guess}) {
			if off < i64(h.audio_start) || off > file_size {
				ok = false
			}
		}
	}
	return ok
}

@(test)
corrupt_flac :: proc(t: ^testing.T) {
	file := ci_flac({{0, 0}, {max(u64), 0}, {24000, 96000}})
	h := new(audio.Flac_Header, context.temp_allocator)
	testing.expect_value(t, audio.parse_flac_header(file, h), audio.Parse_Status.Ok)
	start := h.audio_start
	info := h.info
	testing.expect_value(t, h.seek_count, 2)
	testing.expect(t, ci_check_seek(t, h, i64(len(file))))

	// Every truncation of the header asks for more; from audio_start on it
	// parses the same.
	for n in 0 ..= start + 64 {
		st := audio.parse_flac_header(file[:n], h)
		if n < start {
			testing.expectf(t, st == .Need_More, "cut to %d: %v", n, st)
		} else {
			testing.expectf(t, st == .Ok && h.audio_start == start, "cut to %d: %v", n, st)
		}
	}

	// Damage anywhere in the header, then what the player does with it.
	rng := Ci_Rng{0xF1AC_0001}
	buf := make([]u8, len(file), context.temp_allocator)
	for _ in 0 ..< 3000 {
		copy(buf, file)
		ci_damage(&rng, buf, 0, start + 8)
		if audio.parse_flac_header(buf, h) != .Ok {
			continue
		}
		testing.expect(t, h.audio_start <= len(buf) && h.streaminfo + 34 <= len(buf))
		testing.expect(t, h.seek_count >= 0 && h.seek_count <= audio.FLAC_MAX_SEEKPOINTS)
		_ = audio.flac_decoder_head(buf, h, context.temp_allocator)
		if !ci_check_seek(t, h, i64(len(buf))) {
			testing.fail_now(t, "a damaged SEEKTABLE moved a seek outside the file")
		}
	}

	// Hostile block lengths and an ID3 tag that claims the most it can.
	for at in ([]int{5, 42 + 1}) {
		copy(buf, file)
		buf[at], buf[at + 1], buf[at + 2] = 0xff, 0xff, 0xff
		testing.expect(t, audio.parse_flac_header(buf, h) != .Ok)
	}
	id3 := []u8{'I', 'D', '3', 4, 0, 0, 0x7f, 0x7f, 0x7f, 0x7f, 0, 0}
	testing.expect_value(t, audio.parse_flac_header(id3, h), audio.Parse_Status.Need_More)

	// Seekpoints whose offsets point before the file or past its end, or
	// overflow when added to audio_start, are no place to seek to.
	far := ci_flac({{0, 0xffff_ffff_ffff_fff0}, {100, 1 << 63}, {24000, 1 << 62}, {30000, max(u64) - 1}, {40000, u64(len(file)) * 4}})
	testing.expect_value(t, audio.parse_flac_header(far, h), audio.Parse_Status.Ok)
	testing.expect_value(t, h.seek_count, 5)
	testing.expect(t, ci_check_seek(t, h, i64(len(far))), "a seekpoint from the table moved a seek outside the file")

	// Frame headers: every prefix, every truncation of the frames, and
	// damage in them, at the end of the file and not.
	frames := file[start:]
	for n in 0 ..< 32 {
		_, _ = audio.parse_frame_header(frames[:n], info)
	}
	for n := 0; n < len(frames); n += 37 {
		for eof in ([]bool{false, true}) {
			off, _, st := audio.find_frame(frames[:n], info, eof)
			if st == .Ok {
				testing.expect(t, off >= 0 && off < n)
			}
		}
	}
	fbuf := make([]u8, len(frames), context.temp_allocator)
	for _ in 0 ..< 300 {
		copy(fbuf, frames)
		for _ in 0 ..< 8 {
			ci_damage(&rng, fbuf)
		}
		from := int(ci_next(&rng) % u64(len(fbuf)))
		off, _, st := audio.find_frame(fbuf[from:], info, ci_next(&rng) % 2 == 0)
		if st == .Ok {
			testing.expect(t, off >= 0 && off < len(fbuf) - from)
		}
	}
}

// An MPD in the shape TIDAL's take, with the fields to make hostile.
@(private = "file")
CI_MPD :: `<MPD mediaPresentationDuration="%s"><Period><AdaptationSet><Representation id="%s" codecs="flac"><SegmentTemplate timescale="%s" initialization="i.mp4" media="%s" startNumber="%s"><SegmentTimeline>%s</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`

@(test)
corrupt_mpd :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	allocator := vmem.arena_allocator(&arena)

	check :: proc(t: ^testing.T, mpd: string, allocator: mem.Allocator) -> tidal.Error {
		d, err := tidal.dash_info_from_mpd(mpd, allocator)
		if err == nil {
			testing.expect(t, len(d.segments) <= 200_000)
		}
		return err
	}
	good := MPD
	_, err := tidal.dash_info_from_mpd(good, allocator)
	testing.expect_value(t, err, nil)
	for n in 0 ..< len(good) {
		check(t, good[:n], allocator)
		free_all(allocator)
	}
	rng := Ci_Rng{0xDA5D_0001}
	buf := make([]u8, len(good), context.temp_allocator)
	for _ in 0 ..< 3000 {
		copy(buf, good)
		ci_damage(&rng, buf)
		check(t, string(buf), allocator)
		free_all(allocator)
	}

	long_media := strings.concatenate({strings.repeat("x", 2000, context.temp_allocator), "$Number$.mp4"}, context.temp_allocator)
	long_id := strings.repeat("r", 20000, context.temp_allocator)
	Case :: struct {
		duration, id, timescale, media, start, timeline: string,
		ok:                                              bool,
	}
	cases := []Case {
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S d="4" r="-1"/>`, true},
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S d="4" r="9223372036854775807"/>`, false},
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S d="4" r="99999999999999999999"/>`, false},
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S d="4" r="199999999"/>`, false},
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S d="0"/>`, false},
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S d="-4"/>`, false},
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S t="-9223372036854775808" d="4" r="-1"/>`, true},
		{"PT10S", "r", "1", "$Number$.mp4", "1", `<S t="9223372036854775807" d="9223372036854775807" r="3"/>`, true},
		{"PT10S", "r", "0", "$Number$.mp4", "1", `<S d="4" r="-1"/>`, true},
		{"PT10S", "r", "-5", "$Number$.mp4", "1", `<S d="4" r="-1"/>`, true},
		{"PT99999999999999999999S", "r", "1", "$Number$.mp4", "1", `<S d="4" r="-1"/>`, false},
		{"PT10S", "r", "1", "$Number$.mp4", "9223372036854775807", `<S d="4" r="-1"/>`, true},
		{"PT10S", "r", "1", "$Time%099999999999999999999d$.mp4", "1", `<S d="4" r="-1"/>`, false},
		{"PT10S", "r", "1", "$$$$$", "1", `<S d="4" r="-1"/>`, true},
		// A padded number or an id that makes each URL megabytes long, and
		// URLs that are each fine but many enough to make hundreds of
		// megabytes, are refused before they're made.
		{"PT10S", "r", "1", "$Number%020000d$.mp4", "1", `<S d="4" r="-1"/>`, false},
		{"PT10S", long_id, "1", strings.repeat("$RepresentationID$", 100, context.temp_allocator), "1", `<S d="4" r="-1"/>`, false},
		{"PT200000S", "r", "1", long_media, "1", `<S d="1" r="199990"/>`, false},
	}
	for c, i in cases {
		start := time.tick_now()
		err := check(t, fmt.tprintf(CI_MPD, c.duration, c.id, c.timescale, c.media, c.start, c.timeline), allocator)
		if c.ok {
			testing.expectf(t, err == nil, "case %d: %v", i, err)
		} else {
			testing.expectf(t, err != nil, "case %d parsed", i)
		}
		testing.expectf(t, time.tick_since(start) < time.Second, "case %d took %v", i, time.tick_since(start))
		free_all(allocator)
	}

	// The same through a playbackinfo answer, with manifests that aren't
	// base64, not XML, or BTS manifests of the wrong shape.
	b64 :: proc(s: string) -> string {
		return base64.encode(transmute([]u8)s, allocator = context.temp_allocator)
	}
	answers := []struct {
		mime, manifest: string,
	} {
		{"application/dash+xml", b64(MPD)},
		{"application/dash+xml", "%%%not base64"},
		{"application/dash+xml", b64("not xml")},
		{"application/dash+xml", ""},
		{"application/vnd.tidal.bts", b64(`{"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":["https://cdn.example/a.flac"]}`)},
		{"application/vnd.tidal.bts", b64(`{"codecs":"flac","urls":{}}`)},
		{"application/vnd.tidal.bts", b64(`{"codecs":5,"urls":[1,null,{}]}`)},
		{"application/vnd.tidal.bts", b64(`{"codecs":"flac","urls":[]}`)},
		{"application/vnd.tidal.bts", b64(`[]`)},
		{"application/vnd.tidal.bts", b64(`null`)},
		{"application/vnd.tidal.bts", b64(`{"codecs":"flac","urls":["https://x"`)},
	}
	for a, i in answers {
		obj := make(json.Object, allocator = allocator)
		obj["manifestMimeType"] = json.String(a.mime)
		obj["manifest"] = json.String(a.manifest)
		_, perr := tidal.parse_playback_info(obj, allocator)
		testing.expectf(t, (perr == nil) == (i == 0 || i == 4), "answer %d: %v", i, perr)
		free_all(allocator)
	}
}

// A list file with its sum, in a buffer as aligned as file_read's.
@(private = "file")
ci_aligned :: proc(file: []u8) -> []u8 {
	data, _ := mem.alloc_bytes_non_zeroed(len(file), 16, context.temp_allocator)
	copy(data, file)
	return data
}

@(private = "file")
Ci_File :: enum {
	List,
	Sidebar,
	Queue,
}

// ci_check_file decodes data as kind, checking that whatever it takes points
// inside data.
@(private = "file")
ci_check_file :: proc(t: ^testing.T, kind: Ci_File, data: []u8, allocator: mem.Allocator) -> app.File_Error {
	rows: []app.Row
	err: app.File_Error
	switch kind {
	case .List:
		_, rows, err = app.list_decode(data, .Playlist, "uuid-1", allocator)
	case .Queue:
		after: []i64
		_, rows, after, err = app.queue_decode(data, allocator)
		if err == .None {
			// Each extra plays after an earlier row, or at the end.
			first := len(rows) - len(after)
			testing.expect(t, first >= 0)
			for a, j in after {
				testing.expect(t, a >= -1 && a < i64(first + j))
			}
		}
	case .Sidebar:
		items: []app.Sidebar_Item
		_, items, err = app.sidebar_decode(data, allocator)
		for it in items {
			testing.expect(t, ci_inside(it.id, data) && ci_inside(it.name, data) && ci_inside(it.image, data))
		}
	}
	for r in rows {
		for s in ([]string{r.title, r.artist, r.album, r.added, r.duration, r.cover}) {
			if !ci_inside(s, data) {
				testing.fail_now(t, "a row's string points outside the file")
			}
		}
		for a in r.artists {
			testing.expect(t, a.start >= 0 && a.start <= a.end && int(a.end) <= len(r.artist))
		}
	}
	return err
}

// Where the list starts in the queue file below: the header, the extras'
// count and their two anchors padded to 16 bytes.
@(private = "file")
CI_QUEUE_PREFIX :: size_of(app.Queue_Header) + size_of(app.Queue_Extras) + 16

@(private = "file")
ci_seal :: proc(kind: Ci_File, data: []u8) {
	if kind == .Queue {
		// queue_seal trusts the extras count it wrote, so the sum goes over
		// the list where the good file has it, whatever the count now says.
		app.file_seal(data[CI_QUEUE_PREFIX:])
	} else {
		app.file_seal(data)
	}
}

@(test)
corrupt_list_files :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	allocator := vmem.arena_allocator(&arena)

	rows := []app.Row {
		{title = "Jóga", artist = "Björk, فيروز", album = "Homogenic", cover = "c-1", seconds = 305, id = 101, album_id = 11, track = 3, artists = {{id = 9, start = 0, end = 6}, {id = 10, start = 8, end = 18}}},
		{title = "", artist = "Björk", added = "Jan 5, 2026", duration = "4:15", seconds = 255, id = 102, album_id = 11, track = 1},
		{title = "Army of Me", artist = "Björk", album = "Post", seconds = 234, id = 103, album_id = 12, track = 1, artists = {{id = 9, start = 0, end = 6}}},
	}
	sb := app.Sidebar {
		items = []app.Sidebar_Item{{id = "a", name = "Polskie hity", image = "img", tracks = 85, updated = 99}, {id = "b", name = "", tracks = 0}},
	}
	files := [Ci_File][]u8 {
		.List    = app.rows_encode(.Playlist, "uuid-1", rows, 1760000000, {}, 3, context.temp_allocator),
		.Sidebar = app.sidebar_encode(&sb, 5, context.temp_allocator),
		.Queue   = app.queue_encode({index = 1, sample = 441000, rate = 44100}, rows, context.temp_allocator, []i64{0, 1}),
	}
	rng := Ci_Rng{0x0F11_E5ED}
	for file, kind in files {
		ci_seal(kind, file)
		data := ci_aligned(file)
		testing.expect_value(t, ci_check_file(t, kind, data, allocator), app.File_Error.None)

		// A file cut short at any length, as a crash mid-write leaves it.
		for n in 0 ..< len(data) {
			testing.expect(t, ci_check_file(t, kind, data[:n], allocator) != .None)
			free_all(allocator)
		}

		// Damage, with the sum made to match half the time so the fields
		// behind it are what's tested.
		work := ci_aligned(data)
		for i in 0 ..< 3000 {
			copy(work, data)
			ci_damage(&rng, work)
			if i % 2 == 0 {
				ci_seal(kind, work)
			}
			ci_check_file(t, kind, work, allocator)
			free_all(allocator)
		}

		// Hostile counts, text lengths and string offsets at every 4-byte
		// field, sum fixed.
		for at := 0; at + 4 <= len(data); at += 4 {
			for v in CI_HOSTILE {
				copy(work, data)
				ci_put_le32(work, at, v)
				ci_seal(kind, work)
				ci_check_file(t, kind, work, allocator)
				free_all(allocator)
			}
		}
	}
}

@(test)
corrupt_settings :: proc(t: ^testing.T) {
	good := `{"bit_perfect": true, "scrollbars": "Docked", "bar": "Solid", "device_change": {"uid": "BuiltInSpeakerDevice", "orig_rate": 48000, "orig_format": {"sample_rate": 48000, "format_id": 1819304813, "format_flags": 9, "bytes_per_packet": 8, "frames_per_packet": 1, "bytes_per_frame": 8, "channels": 2, "bits": 32, "reserved": 0}, "rate": 96000}, "volume": 0.5, "shuffle": true, "repeat": "One", "replay_gain": "Album", "title_bar": "Own", "still_covers": true, "button_layout": "close,minimize:maximize"}`
	check :: proc(t: ^testing.T, data: []u8) -> app.Settings {
		st, _ := app.settings_decode_json(data)
		testing.expectf(t, st.scrollbars >= min(type_of(st.scrollbars)) && st.scrollbars <= max(type_of(st.scrollbars)), "scrollbars %d", int(st.scrollbars))
		testing.expectf(t, st.bar >= min(app.Player_Bar) && st.bar <= max(app.Player_Bar), "bar %d", int(st.bar))
		testing.expectf(t, st.repeat >= min(audio.Repeat) && st.repeat <= max(audio.Repeat), "repeat %d", int(st.repeat))
		testing.expectf(t, st.replay_gain >= min(audio.Gain_Setting) && st.replay_gain <= max(audio.Gain_Setting), "replay gain %d", int(st.replay_gain))
		testing.expectf(t, st.title_bar >= min(app.Title_Bar) && st.title_bar <= max(app.Title_Bar), "title bar %d", int(st.title_bar))
		testing.expectf(t, st.volume >= 0 && st.volume <= 1, "volume %v", st.volume)
		testing.expectf(t, st.device.rate == 0 || (st.device.rate > 0 && st.device.orig_rate > 0), "device rates %v %v", st.device.rate, st.device.orig_rate)
		testing.expect(t, st.device.uid_len >= 0 && st.device.uid_len <= len(st.device.uid))
		return st
	}
	st := check(t, transmute([]u8)good)
	testing.expect_value(t, st.repeat, audio.Repeat.One)
	testing.expect_value(t, st.replay_gain, audio.Gain_Setting.Album)
	testing.expect_value(t, st.device.rate, 96000)
	for n in 0 ..< len(good) {
		check(t, transmute([]u8)good[:n])
	}
	rng := Ci_Rng{0x5E77_1265}
	buf := make([]u8, len(good), context.temp_allocator)
	for _ in 0 ..< 3000 {
		copy(buf, good)
		ci_damage(&rng, buf)
		check(t, buf)
	}

	// Choices stored by number reach tables indexed by them, as the player
	// bar's repeat button names its state: one out of range is the default.
	hostile := []string {
		`{"repeat": 7}`,
		`{"repeat": -1}`,
		`{"scrollbars": 200}`,
		`{"bar": 2}`,
		`{"title_bar": 3}`,
		`{"replay_gain": 9}`,
		`{"replay_gain": -1}`,
		`{"replay_gain": 255}`,
		`{"replay_gain": "Loud"}`,
		`{"replay_gain": true}`,
		`{"replay_gain": [1]}`,
		`{"replay_gain": {"name": "Album"}}`,
		`{"volume": NaN}`,
		`{"volume": Infinity}`,
		`{"volume": 1e999}`,
		`{"volume": "loud"}`,
		`{"device_change": {"uid": "x", "rate": NaN, "orig_rate": 48000}}`,
		`{"device_change": {"uid": "x", "rate": 96000, "orig_rate": -48000}}`,
		`{"device_change": {"uid": "x", "rate": -1, "orig_rate": 48000}}`,
		`{"device_change": []}`,
		`{"button_layout": 5}`,
		`{"button_layout": ":::,,,:close,close,close,appmenu,bogus"}`,
		`[]`,
		`null`,
		`"settings"`,
	}
	for src in hostile {
		st = check(t, transmute([]u8)src)
		testing.expectf(t, st.repeat == .Off && st.replay_gain == .Automatic && st.scrollbars == .Floating && st.bar == .Blurred && st.title_bar == .Automatic && st.device.rate == 0, "%s: %v", src, st)
	}
}

// Every value in a TIDAL answer replaced in turn by values of the wrong
// type, out of range, empty or missing.
@(private = "file")
ci_hostile_values :: proc(allocator: mem.Allocator) -> []json.Value {
	obj := make(json.Object, allocator = allocator)
	obj["x"] = json.Integer(1)
	arr := make(json.Array, 1, allocator)
	arr[0] = json.Object{}
	values := []json.Value {
			nil,
			json.Null{},
			json.Boolean(true),
			json.Integer(0),
			json.Integer(-1),
			json.Integer(max(i64)),
			json.Integer(min(i64)),
			json.Float(1e308),
			json.Float(-1e308),
			json.Float(math.inf_f64(1)),
			json.Float(math.nan_f64()),
			json.String(""),
			json.String("not a date"),
			json.String("9999-99-99T99:99:99.9999999999+99:99"),
			json.String("2023-02-30T24:60:60-00"),
			json.String("99999999999999999999999"),
			json.Array{},
			arr,
			json.Object{},
			obj,
	}
	out := make([]json.Value, len(values), allocator)
	copy(out, values)
	return out
}

@(private = "file")
Ci_Json :: struct {
	root:      ^json.Value,
	hostile:   []json.Value,
	allocator: mem.Allocator,
	runs:      int,
}

// ci_parse_all runs every TIDAL parser on the root object.
@(private = "file")
ci_parse_all :: proc(c: ^Ci_Json) {
	defer free_all(c.allocator)
	c.runs += 1
	obj, _ := c.root^.(json.Object)
	p := tidal.Parser {
		allocator       = c.allocator,
		listen_base_url = "https://listen.tidal.com",
		share_base_url  = "https://tidal.com/browse",
		has_user        = true,
		user_id         = 123,
		user_kind       = .Logged_In_User,
	}
	_ = tidal.parse_track(&p, obj)
	_ = tidal.parse_album(&p, obj)
	_ = tidal.parse_media(&p, obj)
	_ = tidal.parse_video(&p, obj)
	_ = tidal.parse_artist(&p, obj)
	_ = tidal.parse_playlist(&p, obj)
	_ = tidal.parse_folder(&p, obj)
	_ = tidal.parse_mix(&p, obj)
	_ = tidal.parse_mix_v2(&p, obj)
	_ = tidal.parse_user(&p, obj)
	_ = tidal.parse_genre(&p, obj)
	_ = tidal.parse_lyrics(&p, obj)
	_ = tidal.parse_stream(&p, obj)
	_ = tidal.parse_page(&p, obj)
	if arr, ok := obj["artists"].(json.Array); ok {
		_ = tidal.parse_artists(&p, arr)
	}
	_, _ = tidal.parse_item_by_type(&p, "TRACKS", obj)
	_, _ = tidal.parse_playback_info(obj, c.allocator)
}

@(private = "file")
ci_walk :: proc(c: ^Ci_Json, v: ^json.Value) {
	saved := v^
	for h in c.hostile {
		v^ = h
		ci_parse_all(c)
	}
	v^ = saved
	#partial switch &x in v^ {
	case json.Object:
		for _, &child in x {
			ci_walk(c, &child)
		}
	case json.Array:
		for &child in x {
			ci_walk(c, &child)
		}
	}
}

@(test)
corrupt_tidal_json :: proc(t: ^testing.T) {
	keep: vmem.Arena
	_ = vmem.arena_init_growing(&keep)
	defer vmem.arena_destroy(&keep)
	scratch: vmem.Arena
	_ = vmem.arena_init_growing(&scratch)
	defer vmem.arena_destroy(&scratch)
	keep_a := vmem.arena_allocator(&keep)

	mix := `{"id":"0011aabb","mixType":"TRACK_MIX","title":"Mix","subTitle":"s","images":{"SMALL":{"url":"https://x/s.jpg","width":320},"MEDIUM":{"url":"m"}},"detailImages":{},"titleTextInfo":{"text":"t","color":"#fff"},"updated":"2024-01-01T00:00:00Z","type":"TRACK_MIX","mixImages":[{"url":"a"},{"url":"b"}],"subtitleTextInfo":{"text":"u"}}`
	page := strings.concatenate({`{"title":"Explore","rows":[{"modules":[{"type":"ALBUM_LIST","title":"New","pagedList":{"items":[`, ALBUM_JSON, `]},"showMore":{"apiPath":"pages/albums","title":"More"}}]},{"modules":[{"type":"MIXED_TYPES_LIST","pagedList":{"items":[{"type":"TRACK","item":`, TRACK_JSON, `},{"type":"PLAYLIST","item":`, PLAYLIST_JSON, `}]}}]},{"modules":[{"type":"PAGE_LINKS","pagedList":{"items":[{"title":"Pop","apiPath":"pages/genre_pop"}]}}]}]}`}, context.temp_allocator)
	playback := fmt.tprintf(`{{"trackId":1,"audioQuality":"HI_RES_LOSSLESS","manifestMimeType":"application/dash+xml","manifest":"%s","sampleRate":96000,"bitDepth":24,"trackReplayGain":-5.5,"trackPeakAmplitude":0.9,"albumReplayGain":-6,"albumPeakAmplitude":0.95}}`, base64.encode(transmute([]u8)string(MPD), allocator = context.temp_allocator))
	folder := `{"trn":"trn:folder:1","name":"F","parent":"root","addedAt":"2024-01-01T00:00:00Z","data":{"id":"1","createdAt":"2024-01-01T00:00:00Z","totalNumberOfItems":3}}`

	c := Ci_Json {
		hostile   = ci_hostile_values(keep_a),
		allocator = vmem.arena_allocator(&scratch),
	}
	start := time.tick_now()
	for doc in ([]string{TRACK_JSON, ALBUM_JSON, PLAYLIST_JSON, mix, page, playback, folder}) {
		root, err := json.parse_string(doc, .JSON, true, keep_a)
		testing.expect_value(t, err, json.Error.None)
		c.root = &root
		ci_walk(&c, &root)

		// Cut short, an answer isn't JSON; whatever parses of it goes through.
		for n := 0; n < len(doc); n += 3 {
			cut, cerr := json.parse_string(doc[:n], .JSON, true, c.allocator)
			if cerr == nil {
				c.root = &cut
				ci_parse_all(&c)
			}
			free_all(c.allocator)
		}
	}
	testing.expect(t, c.runs > 1000)
	testing.expectf(t, time.tick_since(start) < 3 * time.Second, "took %v", time.tick_since(start))
}

@(private = "file")
ci_png_write :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
	context = runtime.default_context()
	out := (^[dynamic]u8)(ctx)
	append(out, ..([^]u8)(data)[:size])
}

@(test)
corrupt_cover :: proc(t: ^testing.T) {
	src: [16 * 16 * 4]u8
	for &v, i in src {
		v = u8(i * 7)
	}
	png := make([dynamic]u8, context.temp_allocator)
	stbi.write_png_to_func(ci_png_write, &png, 16, 16, 4, &src, 16 * 4)
	jpg := make([dynamic]u8, context.temp_allocator)
	stbi.write_jpg_to_func(ci_png_write, &jpg, 16, 16, 4, &src, 80)

	decode :: proc(t: ^testing.T, data: []u8) -> bool {
		any_ok := false
		for px in ([]int{0, 8}) {
			pixels, w, h, ok := cover.decode(data, px)
			if ok {
				testing.expect(t, w > 0 && h > 0 && len(pixels) == w * h * 4)
				any_ok = true
			}
			cover.free_pixels(pixels)
		}
		return any_ok
	}
	rng := Ci_Rng{0xC0BE_0001}
	for image in ([][]u8{png[:], jpg[:]}) {
		testing.expect(t, decode(t, image))
		for n := 0; n < len(image); n += 5 {
			decode(t, image[:n])
		}
		buf := make([]u8, len(image), context.temp_allocator)
		for _ in 0 ..< 500 {
			copy(buf, image)
			ci_damage(&rng, buf)
			decode(t, buf)
		}
	}
	// A PNG header naming a huge or empty image, and bytes that aren't one.
	buf := make([]u8, len(png), context.temp_allocator)
	for at in ([]int{16, 20}) {
		for v in CI_HOSTILE {
			copy(buf, png[:])
			ci_put_be32(buf, at, v)
			decode(t, buf)
		}
	}
	testing.expect(t, !decode(t, nil))
	testing.expect(t, !decode(t, transmute([]u8)string("<html>404 Not Found</html>")))
	testing.expect(t, !decode(t, transmute([]u8)string("GIF89a")))
}
