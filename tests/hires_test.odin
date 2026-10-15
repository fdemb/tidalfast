package tidal_tests

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import vmem "core:mem/virtual"
import "core:time"
import ma "vendor:miniaudio"

import app "../src/app"
import "../src/audio"
import tidal "../src/tidal"
import "dashgen"

// A 24/96 stereo DASH stream of quiet noise, cut into segments of about
// segment_seconds, and the samples it holds.
@(private = "file")
test_dash :: proc(seconds, segment_seconds: f64, rate := 96000, bits := 24, block := 4096) -> (d: dashgen.Dash, pcm: []i32) {
	frames := int(seconds * f64(rate))
	pcm = dashgen.quiet_signal(frames, 2, bits, 0xC0FFEE, context.temp_allocator)
	flac := dashgen.encode_verbatim(pcm, 2, bits, rate, block, context.temp_allocator)
	ok: bool
	d, ok = dashgen.from_flac(flac, segment_seconds, context.temp_allocator)
	assert(ok)
	return
}

// demux turns a DASH stream back into a FLAC file with the parser the
// player uses: "fLaC" and the dfLa blocks, then every fragment's samples.
@(private = "file")
demux :: proc(t: ^testing.T, d: dashgen.Dash) -> []u8 {
	init, _, st := audio.parse_mp4_init(d.init, context.temp_allocator)
	testing.expect_value(t, st, audio.Parse_Status.Ok)
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..init.flac_head)
	samples := make([dynamic]audio.Mp4_Sample, context.temp_allocator)
	for seg, k in d.segments {
		pos := 0
		for pos < len(seg) {
			box, bst := audio.mp4_box_header(seg[pos:])
			testing.expect_value(t, bst, audio.Parse_Status.Ok)
			if box.kind == audio.mp4_fourcc("moof") {
				clear(&samples)
				frag, fst := audio.parse_mp4_moof(seg[pos:pos + int(box.size)], &init, &samples)
				testing.expect_value(t, fst, audio.Parse_Status.Ok)
				testing.expect_value(t, i64(frag.base_time), d.starts[k])
				for smp in samples {
					append(&out, ..seg[pos + int(smp.offset):pos + int(smp.offset) + int(smp.size)])
				}
			}
			pos += int(box.size)
		}
	}
	return out[:]
}

// decode_all decodes a FLAC file with dr_flac, through miniaudio as the
// player does, to interleaved f32.
@(private = "file")
decode_all :: proc(flac: []u8, channels: int) -> []f32 {
	dec: ma.decoder
	cfg := ma.decoder_config_init(.f32, 0, 0)
	cfg.encodingFormat = .flac
	if ma.decoder_init_memory(raw_data(flac), len(flac), &cfg, &dec) != .SUCCESS {
		return nil
	}
	defer ma.decoder_uninit(&dec)
	out := make([dynamic]f32, context.temp_allocator)
	buf: [4096 * 2]f32
	for {
		n: u64
		ma.decoder_read_pcm_frames(&dec, &buf[0], u64(len(buf) / channels), &n)
		if n == 0 {
			break
		}
		append(&out, ..buf[:int(n) * channels])
	}
	return out[:]
}

// The float the device gets for an integer sample of bits: v / 2^(bits-1).
// Exact in f32 up to 24 bits.
@(private = "file")
as_float :: proc(v: i32, bits: int) -> f32 {
	return f32(f64(v) / f64(i64(1) << uint(bits - 1)))
}

@(test)
mpd_segment_timeline :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	allocator := vmem.arena_allocator(&arena)

	// TIDAL's shape: absolute URLs with a query, $Number$ from 1, a run with
	// a repeat count and a shorter last segment.
	mpd := `<?xml version='1.0' encoding='UTF-8'?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT13.000S"><Period id="0"><AdaptationSet id="0" contentType="audio" mimeType="audio/mp4"><Representation id="FLAC,96000,24" codecs="flac" bandwidth="4608000" audioSamplingRate="96000"><SegmentTemplate timescale="96000" initialization="https://sp.example/a/0.mp4?token=t&amp;e=1" media="https://sp.example/a/$Number$.mp4?token=t&amp;e=1" startNumber="1"><SegmentTimeline><S t="0" d="384000" r="2"/><S d="96000"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	d, err := tidal.dash_info_from_mpd(mpd, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, d.timescale, 96000)
	testing.expect_value(t, d.audio_sampling_rate, 96000)
	testing.expect_value(t, len(d.segments), 4)
	testing.expect_value(t, d.init_url, "https://sp.example/a/0.mp4?token=t&e=1")
	testing.expect_value(t, d.segments[0].url, "https://sp.example/a/1.mp4?token=t&e=1")
	testing.expect_value(t, d.segments[3].url, "https://sp.example/a/4.mp4?token=t&e=1")
	for want, i in ([]i64{0, 384000, 768000, 1152000}) {
		testing.expect_value(t, d.segments[i].start, want)
	}
	testing.expect_value(t, d.segments[2].length, i64(384000))
	testing.expect_value(t, d.segments[3].length, i64(96000))

	// A t on a later entry jumps; r="-1" repeats up to it.
	gaps := `<MPD mediaPresentationDuration="PT10S"><Period><AdaptationSet><Representation codecs="flac"><SegmentTemplate timescale="1000" media="$Number$.mp4" initialization="i.mp4"><SegmentTimeline><S t="0" d="2000" r="-1"/><S t="6000" d="1000" r="3"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	g, gerr := tidal.dash_info_from_mpd(gaps, allocator)
	testing.expect_value(t, gerr, nil)
	testing.expect_value(t, len(g.segments), 7)
	for want, i in ([]i64{0, 2000, 4000, 6000, 7000, 8000, 9000}) {
		testing.expect_value(t, g.segments[i].start, want)
	}

	// What the mock sends round-trips.
	dash, _ := test_dash(1.5, 0.5, block = 4800)
	m, merr := tidal.dash_info_from_mpd(dashgen.mpd(dash, "http://127.0.0.1/x", allocator), allocator)
	testing.expect_value(t, merr, nil)
	testing.expect_value(t, len(m.segments), len(dash.segments))
	for seg, i in m.segments {
		testing.expect_value(t, seg.start, dash.starts[i])
		testing.expect_value(t, seg.length, dash.lengths[i])
	}
}

@(test)
dash_playback_info :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	allocator := vmem.arena_allocator(&arena)
	info_json :: proc(mpd: string) -> json.Object {
		encoded, _ := base64.encode(transmute([]u8)mpd, allocator = context.temp_allocator)
		src := fmt.tprintf(`{{"trackId":7,"audioQuality":"HI_RES_LOSSLESS","manifestMimeType":"application/dash+xml","manifest":"%s","bitDepth":24,"sampleRate":96000,"trackReplayGain":-4}}`, encoded)
		v, _ := json.parse_string(src, .JSON, true, context.temp_allocator)
		return v.(json.Object)
	}
	dash, _ := test_dash(2, 1)
	info, err := tidal.parse_playback_info(info_json(dashgen.mpd(dash, "https://cdn.example/t", allocator)), allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, info.dash)
	testing.expect_value(t, info.codec, "FLAC")
	testing.expect_value(t, info.url, "https://cdn.example/t/0.mp4?token=mock&e=1")
	testing.expect_value(t, len(info.segments), len(dash.segments))
	testing.expect_value(t, info.timescale, 96000)
	testing.expect_value(t, info.bit_depth, 24)
	testing.expect_value(t, info.track_gain, -4.0)

	aac := `<MPD mediaPresentationDuration="PT4S"><Period><AdaptationSet><Representation codecs="mp4a.40.2"><SegmentTemplate timescale="1" media="$Number$.mp4" initialization="i.mp4"><SegmentTimeline><S d="4"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	_, aerr := tidal.parse_playback_info(info_json(aac), allocator)
	testing.expect(t, tidal.is_error(aerr, .Stream_Not_Available))
	drm := `<MPD mediaPresentationDuration="PT4S"><Period><AdaptationSet><ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/><Representation codecs="flac"><SegmentTemplate timescale="1" media="$Number$.mp4" initialization="i.mp4"><SegmentTimeline><S d="4"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	_, derr := tidal.parse_playback_info(info_json(drm), allocator)
	testing.expect(t, tidal.is_error(derr, .Stream_Not_Available))
	_, eerr := tidal.parse_playback_info(info_json(`<MPD/>`), allocator)
	testing.expect(t, tidal.is_error(eerr, .Manifest_Decode))
}

@(test)
fmp4_boxes :: proc(t: ^testing.T) {
	dash, _ := test_dash(2.5, 1)
	testing.expect_value(t, len(dash.segments), 3)

	init, used, st := audio.parse_mp4_init(dash.init, context.temp_allocator)
	testing.expect_value(t, st, audio.Parse_Status.Ok)
	testing.expect_value(t, used, len(dash.init))
	testing.expect_value(t, init.track_id, u32(1))
	testing.expect_value(t, init.timescale, u32(96000))
	testing.expect(t, strings.has_prefix(string(init.flac_head), "fLaC"))
	h: audio.Flac_Header
	testing.expect_value(t, audio.parse_flac_header(init.flac_head, &h), audio.Parse_Status.Ok)
	testing.expect_value(t, h.info.bits, 24)
	testing.expect_value(t, h.info.sample_rate, 96000)
	testing.expect_value(t, h.info.total_samples, i64(240000))
	// Any prefix of the moov is not enough yet.
	_, _, partial := audio.parse_mp4_init(dash.init[:len(dash.init) - 1], context.temp_allocator)
	testing.expect_value(t, partial, audio.Parse_Status.Need_More)

	// The second segment: its moof's trun lists 24 frames (1 s at 4096
	// samples each, rounded up), whose sizes fill the mdat exactly.
	seg := dash.segments[1]
	styp, _ := audio.mp4_box_header(seg)
	moof, _ := audio.mp4_box_header(seg[styp.size:])
	testing.expect_value(t, moof.kind, audio.mp4_fourcc("moof"))
	samples := make([dynamic]audio.Mp4_Sample, context.temp_allocator)
	frag, fst := audio.parse_mp4_moof(seg[styp.size:styp.size + moof.size], &init, &samples)
	testing.expect_value(t, fst, audio.Parse_Status.Ok)
	testing.expect(t, frag.has_base_time)
	testing.expect_value(t, i64(frag.base_time), dash.starts[1])
	testing.expect_value(t, len(samples), 24)
	mdat, _ := audio.mp4_box_header(seg[styp.size + moof.size:])
	testing.expect_value(t, mdat.kind, audio.mp4_fourcc("mdat"))
	testing.expect_value(t, samples[0].offset, moof.size + 8)
	total := i64(0)
	for smp in samples {
		total += i64(smp.size)
	}
	testing.expect_value(t, total, mdat.size - 8)

	// A 64-bit size and a box running to the end of the data.
	large := []u8{0, 0, 0, 1, 'm', 'd', 'a', 't', 0, 0, 0, 0, 0, 0, 0, 20, 1, 2, 3, 4}
	lb, lst := audio.mp4_box_header(large)
	testing.expect_value(t, lst, audio.Parse_Status.Ok)
	testing.expect_value(t, lb.size, i64(20))
	testing.expect_value(t, lb.header, 16)
	open_ended, _ := audio.mp4_box_header([]u8{0, 0, 0, 0, 'm', 'd', 'a', 't'})
	testing.expect_value(t, open_ended.size, i64(-1))
	_, bad := audio.mp4_box_header([]u8{0, 0, 0, 3, 'm', 'd', 'a', 't'})
	testing.expect_value(t, bad, audio.Parse_Status.Invalid)

	// A trun without sizes takes tfhd's default, and data_offset goes on
	// from the previous trun when it's left out.
	b := make([dynamic]u8, context.temp_allocator)
	be32 :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
	}
	be32(&b, 8 + 8 + 20 + 20 + 16)
	append(&b, 'm', 'o', 'o', 'f')
	be32(&b, 8 + 20 + 20 + 16)
	append(&b, 't', 'r', 'a', 'f')
	be32(&b, 20)
	append(&b, 't', 'f', 'h', 'd')
	be32(&b, 0x020010)
	be32(&b, 1)
	be32(&b, 300) // default sample size
	be32(&b, 20)
	append(&b, 't', 'r', 'u', 'n')
	be32(&b, 0x001)
	be32(&b, 2)
	be32(&b, 100)
	be32(&b, 16)
	append(&b, 't', 'r', 'u', 'n')
	be32(&b, 0)
	be32(&b, 1)
	clear(&samples)
	_, dst := audio.parse_mp4_moof(b[:], &init, &samples)
	testing.expect_value(t, dst, audio.Parse_Status.Ok)
	testing.expect_value(t, len(samples), 3)
	testing.expect_value(t, samples[0], audio.Mp4_Sample{100, 300})
	testing.expect_value(t, samples[1], audio.Mp4_Sample{400, 300})
	testing.expect_value(t, samples[2], audio.Mp4_Sample{700, 300})
}

// 24-bit samples through fMP4, the demuxer and dr_flac come back as
// exactly v / 2^23: not one bit differs.
@(test)
fmp4_24bit_round_trip :: proc(t: ^testing.T) {
	dash, pcm := test_dash(1.2, 0.5)
	out := decode_all(demux(t, dash), 2)
	testing.expect_value(t, len(out), len(pcm))
	differ := 0
	for v, i in pcm {
		if i >= len(out) || transmute(u32)out[i] != transmute(u32)as_float(v, 24) {
			differ += 1
		}
	}
	testing.expectf(t, differ == 0, "%d of %d samples differ", differ, len(pcm))
}

@(test)
dash_seek_lookup :: proc(t: ^testing.T) {
	// Segments of 4 s in a timescale of 1000, at 96 kHz.
	starts := []i64{0, 4000, 8000, 12000}
	at :: proc(starts: []i64, sample: i64) -> int {
		return audio.dash_segment_index(starts, 1000, 96000, sample)
	}
	testing.expect_value(t, at(starts, 0), 0)
	testing.expect_value(t, at(starts, 4 * 96000 - 1), 0)
	testing.expect_value(t, at(starts, 4 * 96000), 1)
	testing.expect_value(t, at(starts, 11 * 96000), 2)
	testing.expect_value(t, at(starts, 100 * 96000), 3)
	testing.expect_value(t, at(starts, -5), 0)
	testing.expect_value(t, audio.dash_segment_sample(starts, 1000, 96000, 2), i64(8 * 96000))
	testing.expect_value(t, audio.dash_segment_index(nil, 1000, 96000, 500), 0)
	one := []i64{0}
	testing.expect_value(t, audio.dash_segment_index(one, 96000, 96000, 1 << 30), 0)
}

@(test)
pkce_redirect :: proc(t: ^testing.T) {
	REDIRECT :: "https://tidal.com/android/login/auth"
	code, err := tidal.pkce_redirect_code("https://tidal.com/android/login/auth?code=abc%2Fdef_1&state=na", REDIRECT)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, code, "abc/def_1")
	// Copied from an address bar, with quotes and a newline.
	code, err = tidal.pkce_redirect_code("  \"https://tidal.com/android/login/auth?state=x&code=XYZ#frag\"\n", REDIRECT)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, code, "XYZ")

	_, e1 := tidal.pkce_redirect_code("https://evil.example/android/login/auth?code=abc", REDIRECT)
	testing.expect(t, tidal.is_error(e1, .Invalid_Argument))
	_, e2 := tidal.pkce_redirect_code("https://tidal.com/android/login/authx?code=abc", REDIRECT)
	testing.expect(t, tidal.is_error(e2, .Invalid_Argument))
	_, e3 := tidal.pkce_redirect_code("https://tidal.com/android/login/auth?state=na", REDIRECT)
	testing.expect(t, tidal.is_error(e3, .Invalid_Argument))
	_, e4 := tidal.pkce_redirect_code("https://tidal.com/android/login/auth?error=access_denied", REDIRECT)
	testing.expect(t, tidal.is_error(e4, .Authentication))
	_, e5 := tidal.pkce_redirect_code("", REDIRECT)
	testing.expect(t, tidal.is_error(e5, .Invalid_Argument))

	// The URL carries the challenge of the verifier the session holds, also
	// after another session takes over the state.
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	verifier, key := tidal.pkce_new_state(context.temp_allocator)
	testing.expect_value(t, len(verifier), 43)
	tidal.session_set_pkce_state(s, verifier, key)
	url := tidal.pkce_login_url(s, context.temp_allocator)
	testing.expect(t, strings.contains(url, fmt.tprintf("code_challenge=%s&", tidal.pkce_challenge(verifier, context.temp_allocator))))
	testing.expect(t, strings.contains(url, fmt.tprintf("client_unique_key=%s&", key)))
	testing.expect(t, strings.contains(url, "client_id=6BDSRdpK9hqEBTgU&"))
}

// The PKCE exchange sends the Android client's id, the verifier and the
// code, and marks the login as PKCE, so refreshes and the Keychain item use
// that client.
@(test)
pkce_login_against_mock :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	s.config.api_v1_location = m.base_url
	s.config.api_oauth2_token = fmt.tprintf("%stoken", m.base_url)
	err := tidal.login_pkce_complete(s, "https://tidal.com/android/login/auth?code=the-code&state=na")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.token_form["grant_type"], "authorization_code")
	testing.expect_value(t, m.token_form["client_id"], "6BDSRdpK9hqEBTgU")
	testing.expect_value(t, m.token_form["code"], "the-code")
	testing.expect_value(t, m.token_form["code_verifier"], s.config.code_verifier)
	a := tidal.session_auth(s, context.temp_allocator)
	testing.expect(t, a.is_pkce)
	testing.expect_value(t, a.client_id, "6BDSRdpK9hqEBTgU")
	testing.expect(t, tidal.session_is_pkce(s))

	// A refresh goes out with the same client.
	_, rerr := tidal.token_refresh(s, a.refresh_token)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, m.token_form["client_id"], "6BDSRdpK9hqEBTgU")

	// The Keychain JSON keeps the client, and restoring it brings back PKCE.
	data := app.auth_marshal(a, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"client_id":"6BDSRdpK9hqEBTgU"`))
	s2 := tidal.session_create()
	defer tidal.session_destroy(s2)
	testing.expect(t, app.auth_restore(s2, data))
	testing.expect(t, tidal.session_is_pkce(s2))
	// An item from before the client id was stored goes by is_pkce.
	testing.expect(t, app.auth_restore(s2, transmute([]u8)string(`{"access_token":"a","refresh_token":"r","user_id":5,"is_pkce":false}`)))
	testing.expect(t, !tidal.session_is_pkce(s2))
}

@(test)
settings_persistence :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/tidalfast-settings-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	path := fmt.tprintf("%s/nested/settings.json", dir)
	defer os.remove_all(dir)

	st, ok := app.settings_load(path)
	testing.expect(t, !ok)
	testing.expect_value(t, st, app.Settings{})
	testing.expect(t, app.settings_save(path, {bit_perfect = true, hog = true}))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{bit_perfect = true, hog = true})
	testing.expect(t, app.settings_save(path, {bit_perfect = true}))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st, app.Settings{bit_perfect = true})
	testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", path)))

	_ = os.write_entire_file(path, transmute([]u8)string("{not json"))
	st, ok = app.settings_load(path)
	testing.expect(t, !ok)
	testing.expect_value(t, st, app.Settings{})

	for v in ([]app.Settings{{}, {bit_perfect = true}, {bit_perfect = true, hog = true}}) {
		testing.expect_value(t, app.settings_decode(app.settings_encode(v)), v)
	}
	// Hog mode only counts with bit-perfect output.
	testing.expect_value(t, app.output_of({hog = true}), audio.Output{})
}

@(private = "file")
no_wake_hires :: proc "c" () {}

// read_capture reads the float samples of a capture WAV.
@(private = "file")
read_capture :: proc(path: string) -> []f32 {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < 44 {
		return nil
	}
	return ([^]f32)(raw_data(data[44:]))[:(len(data) - 44) / 4]
}

// find_run returns where want starts in got, or -1.
@(private = "file")
find_run :: proc(got, want: []f32) -> int {
	outer: for i in 0 ..= len(got) - len(want) {
		for w, k in want {
			if transmute(u32)got[i + k] != transmute(u32)w {
				continue outer
			}
		}
		return i
	}
	return -1
}

// A DASH track played by the player in bit-perfect mode, on the null
// device, reaches the callback with every sample as decoded: ReplayGain
// and the volume are left out. Then a seek into the second segment starts
// exactly at the target sample.
@(test)
dash_player_bit_exact :: proc(t: ^testing.T) {
	RATE :: 96000
	dash, pcm := test_dash(2.2, 0.75, RATE)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	m.files["/d/0.mp4"] = dash.init
	segs := make([]audio.Segment, len(dash.segments), context.temp_allocator)
	for seg, i in dash.segments {
		path := fmt.tprintf("/d/%d.mp4", i + 1)
		m.files[path] = seg
		segs[i] = {fmt.tprintf("%s%s", m.base_url, path[1:]), dash.starts[i]}
	}
	src := audio.Source {
		kind      = .Dash,
		serial    = 1,
		url       = fmt.tprintf("%sd/0.mp4", m.base_url),
		segments  = segs,
		timescale = RATE,
		dash_end  = dash.total,
		gain      = 0.5, // must not be applied
		seconds   = 2.2,
	}
	want := make([]f32, len(pcm), context.temp_allocator)
	for v, i in pcm {
		want[i] = as_float(v, 24)
	}

	capture := fmt.tprintf("%s/tidalfast-dash-%d.wav", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	defer os.remove(capture)
	p := audio.create(no_wake_hires, 0.3, capture, null_output = true, output = {bit_perfect = true})
	audio.play(p, src)
	ended := false
	for start := time.tick_now(); time.tick_since(start) < 6 * time.Second; {
		st := audio.status(p)
		if st.serial == 1 && st.state == .Ended {
			ended = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, ended, "the track didn't play to the end")
	st := audio.status(p)
	testing.expect_value(t, st.bits, 24)
	testing.expect_value(t, st.rate, RATE)

	// A seek to a sample inside the second segment, not on a frame edge.
	target := dash.starts[1] + 1234
	audio.play(p, src, target)
	time.sleep(400 * time.Millisecond)
	audio.destroy(p)

	got := read_capture(capture)
	at := find_run(got, want[:4096])
	testing.expectf(t, at >= 0, "the track's first samples aren't in the capture")
	if at < 0 {
		return
	}
	differ := 0
	for w, i in want {
		if at + i >= len(got) || transmute(u32)got[at + i] != transmute(u32)w {
			differ += 1
		}
	}
	testing.expectf(t, differ == 0, "%d of %d samples differ", differ, len(want))
	after := got[at + len(want):]
	seek := find_run(after, want[target * 2:target * 2 + 4096])
	testing.expectf(t, seek >= 0, "the seek didn't start at sample %d", target)
	// Only silence before it: no frame before the target got through.
	for v in after[:max(seek, 0)] {
		if v != 0 {
			testing.fail_now(t, "audio before the seek target")
		}
	}
}

// Turning bit-perfect output on mid-track reopens the device and plays on
// from where the track was, not from the start.
@(test)
set_output_plays_on :: proc(t: ^testing.T) {
	p := audio.create(no_wake_hires, 0.5, null_output = true)
	defer audio.destroy(p)
	audio.play(p, {kind = .Tone, serial = 1, gain = 1, seconds = 30, tone_hz = 440})
	position :: proc(p: ^audio.Player, past: i64) -> (i64, bool) {
		for start := time.tick_now(); time.tick_since(start) < 3 * time.Second; {
			if st := audio.status(p); st.serial == 1 && st.state == .Playing && st.sample > past {
				return st.sample, true
			}
			time.sleep(5 * time.Millisecond)
		}
		return 0, false
	}
	before, ok := position(p, 22050)
	testing.expect(t, ok)
	audio.set_output(p, {bit_perfect = true})
	after, ok2 := position(p, before + 4410)
	testing.expect(t, ok2)
	testing.expect(t, after > before)
	testing.expect(t, audio.status(p).device.rate == 44100)
}
