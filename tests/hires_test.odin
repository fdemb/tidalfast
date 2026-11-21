package tidal_tests

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import vmem "core:mem/virtual"
import "core:time"
import drflac "../third_party/dr_flac"

import app "../src/app"
import "../src/audio"
import "../src/jobs"
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
				mdat, _ := audio.mp4_box_header(seg[pos + int(box.size):])
				frag, fst := audio.parse_mp4_moof(seg[pos:pos + int(box.size)], &init, &samples, box.size + i64(mdat.header), box.size + mdat.size)
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

// decode_all decodes a FLAC file with dr_flac, as the player does, to
// interleaved f32.
@(private = "file")
decode_all :: proc(flac: []u8, channels: int) -> []f32 {
	dec := drflac.open_memory(raw_data(flac), len(flac), nil)
	if dec == nil {
		return nil
	}
	defer drflac.close(dec)
	out := make([dynamic]f32, context.temp_allocator)
	buf: [4096 * 2]f32
	for {
		n := drflac.read_pcm_frames_f32(dec, u64(len(buf) / channels), &buf[0])
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
	testing.expect(t, tidal.is_error(aerr, .Lossy_Stream))
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
	mdat, _ := audio.mp4_box_header(seg[styp.size + moof.size:])
	testing.expect_value(t, mdat.kind, audio.mp4_fourcc("mdat"))
	frag, fst := audio.parse_mp4_moof(seg[styp.size:styp.size + moof.size], &init, &samples, moof.size + 8, moof.size + mdat.size)
	testing.expect_value(t, fst, audio.Parse_Status.Ok)
	testing.expect(t, frag.has_base_time)
	testing.expect_value(t, i64(frag.base_time), dash.starts[1])
	testing.expect_value(t, len(samples), 24)
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
	_, dst := audio.parse_mp4_moof(b[:], &init, &samples, 80, 1000)
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
	_, rerr := tidal.token_refresh(s, a)
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
	dir := fmt.tprintf("%s/tidalfast-settings-%d", temp_base(), time.now()._nsec)
	path := fmt.tprintf("%s/nested/settings.json", dir)
	defer os.remove_all(dir)

	st, ok := app.settings_load(path)
	testing.expect(t, !ok)
	testing.expect_value(t, st, app.Settings{volume = 0.7})
	testing.expect(t, app.settings_save(path, {bit_perfect = true}))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{bit_perfect = true})
	testing.expect(t, !os.exists(fmt.tprintf("%s.tmp", path)))

	// The scrollbar mode goes by name, and a name it doesn't know is the
	// default.
	testing.expect(t, app.settings_save(path, {scrollbars = .Docked}))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"Docked"`))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st, app.Settings{scrollbars = .Docked})
	_ = os.write_entire_file(path, transmute([]u8)string(`{"scrollbars": "Sideways"}`))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{volume = 0.7})

	// The player bar too, by name; a file from before it has it blurred.
	testing.expect(t, app.settings_save(path, {bar = .Solid}))
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"bar": "Solid"`))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st, app.Settings{bar = .Solid})

	// Still covers too; a file from before them has covers that lean.
	testing.expect(t, app.settings_save(path, {still_covers = true}))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st, app.Settings{still_covers = true})

	// Shuffle and repeat too; a file from before them has both off.
	testing.expect(t, app.settings_save(path, {shuffle = true, repeat = .One}))
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"repeat": "One"`))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st, app.Settings{shuffle = true, repeat = .One})

	// ReplayGain too, by name. A file from before it, or with a name it
	// doesn't know, has it Automatic, and the rest of the file still loads.
	for g in audio.Gain_Setting {
		testing.expect(t, app.settings_save(path, {replay_gain = g, volume = 0.5}))
		st, ok = app.settings_load(path)
		testing.expect(t, ok)
		testing.expect_value(t, st, app.Settings{replay_gain = g, volume = 0.5})
	}
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"replay_gain": "Off"`))
	_ = os.write_entire_file(path, transmute([]u8)string(`{"shuffle": true}`))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st.replay_gain, audio.Gain_Setting.Automatic)
	_ = os.write_entire_file(path, transmute([]u8)string(`{"replay_gain": "Loud", "shuffle": true}`))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{shuffle = true, volume = 0.7})

	_ = os.write_entire_file(path, transmute([]u8)string("{not json"))
	st, ok = app.settings_load(path)
	testing.expect(t, !ok)
	testing.expect_value(t, st, app.Settings{volume = 0.7})

	// A device that bit-perfect output changed goes in the file while it
	// lasts, and leaves it again.
	changed := app.Settings {
		bit_perfect = true,
		device = {orig_rate = 48000, rate = 96000, orig_format = {sample_rate = 48000, format_id = audio.FORMAT_LPCM, format_flags = 9, bytes_per_packet = 8, frames_per_packet = 1, bytes_per_frame = 8, channels = 2, bits = 32}},
	}
	changed.device.uid_len = copy(changed.device.uid[:], "BuiltInSpeakerDevice")
	testing.expect(t, app.settings_save(path, changed))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, changed)
	testing.expect(t, app.settings_save(path, {bit_perfect = true}))
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data), "device_change"))
	// The volume is kept. A file from before it was, or one with a volume
	// out of range, gives the default or the nearest end.
	testing.expect(t, app.settings_save(path, {volume = 0.35}))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st.volume, 0.35)
	testing.expect(t, app.settings_save(path, {volume = 0}))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st.volume, 0)
	_ = os.write_entire_file(path, transmute([]u8)string(`{"bit_perfect": false, "scrollbars": "Floating"}`))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st.volume, 0.7)
	_ = os.write_entire_file(path, transmute([]u8)string(`{"volume": 3}`))
	st, _ = app.settings_load(path)
	testing.expect_value(t, st.volume, 1)
	// A file from when the app had hog mode still loads, and saving drops it.
	_ = os.write_entire_file(path, transmute([]u8)string(`{"bit_perfect": true, "hog": true}`))
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{bit_perfect = true, volume = 0.7})
	testing.expect(t, app.settings_save(path, st))
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data), "hog"))
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

	capture := fmt.tprintf("%s/tidalfast-dash-%d.wav", temp_base(), time.now()._nsec)
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

// Log_Record keeps the lines logged to it, from any thread.
@(private = "file")
Log_Record :: struct {
	mutex: sync.Mutex,
	lines: [dynamic]string,
}

@(private = "file")
record_logger :: proc(r: ^Log_Record) -> runtime.Logger {
	return {
		procedure = proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
			r := (^Log_Record)(data)
			sync.guard(&r.mutex)
			append(&r.lines, strings.clone(text, runtime.heap_allocator()))
		},
		data = r,
		lowest_level = .Debug,
	}
}

// A DASH segment that fails mid-track, read by the decoder through dr_flac,
// is logged with the player's logger.
@(test)
dash_failure_in_the_decoder_is_logged :: proc(t: ^testing.T) {
	RATE :: 96000
	dash, _ := test_dash(2.2, 0.75, RATE)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	m.files["/d/0.mp4"] = dash.init
	segs := make([]audio.Segment, len(dash.segments), context.temp_allocator)
	for seg, i in dash.segments {
		path := fmt.tprintf("/d/%d.mp4", i + 1)
		if i == 0 {
			m.files[path] = seg // the others answer 404
		}
		segs[i] = {fmt.tprintf("%s%s", m.base_url, path[1:]), dash.starts[i]}
	}
	src := audio.Source {
		kind      = .Dash,
		serial    = 1,
		url       = fmt.tprintf("%sd/0.mp4", m.base_url),
		segments  = segs,
		timescale = RATE,
		dash_end  = dash.total,
		gain      = 1,
		seconds   = 2.2,
	}
	record := Log_Record{lines = make([dynamic]string, runtime.heap_allocator())}
	defer {
		for l in record.lines {
			delete(l, runtime.heap_allocator())
		}
		delete(record.lines)
	}
	runner := context.logger
	context.logger = record_logger(&record)
	p := audio.create(no_wake_hires, 0, null_output = true)
	context.logger = runner
	audio.play(p, src)
	for start := time.tick_now(); audio.status(p).error.serial != 1 && time.tick_since(start) < 5 * time.Second; {
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, audio.status(p).error.serial, u64(1))
	audio.destroy(p)
	logged := false
	for l in record.lines {
		logged ||= strings.contains(l, "audio: track 1 failed: download failed")
	}
	testing.expectf(t, logged, "the failure wasn't logged: %v", record.lines)
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

// Box building for the moof tests.
@(private = "file")
put32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private = "file")
put64 :: proc(b: ^[dynamic]u8, v: u64) {
	put32(b, u32(v >> 32))
	put32(b, u32(v))
}

// open_box starts a box and returns where its size goes; close_box fills
// the size in.
@(private = "file")
open_box :: proc(b: ^[dynamic]u8, kind: string) -> int {
	at := len(b)
	put32(b, 0)
	append(b, ..transmute([]u8)kind)
	return at
}

@(private = "file")
close_box :: proc(b: ^[dynamic]u8, at: int) {
	n := u32(len(b) - at)
	b[at], b[at + 1], b[at + 2], b[at + 3] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
}

// Traf is one traf for craft_moof: tfhd's flags and fields after the track
// id, and one trun with its flags, count, data offset and table.
@(private = "file")
Traf :: struct {
	track:       u32,
	tfhd_flags:  u32,
	base:        u64, // with tfhd_flags & 1
	default_len: u32, // with tfhd_flags & 0x10
	trun_flags:  u32,
	count:       u32,
	data_offset: i32, // with trun_flags & 1
	sizes:       []u32, // with trun_flags & 0x200
	tfdt:        []u8, // the tfdt body, version and flags included; none when empty
}

@(private = "file")
craft_moof :: proc(trafs: ..Traf) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	moof := open_box(&b, "moof")
	for tf in trafs {
		traf := open_box(&b, "traf")
		tfhd := open_box(&b, "tfhd")
		put32(&b, tf.tfhd_flags)
		put32(&b, tf.track)
		if tf.tfhd_flags & 0x01 != 0 {
			put64(&b, tf.base)
		}
		if tf.tfhd_flags & 0x10 != 0 {
			put32(&b, tf.default_len)
		}
		close_box(&b, tfhd)
		if len(tf.tfdt) > 0 {
			tfdt := open_box(&b, "tfdt")
			append(&b, ..tf.tfdt)
			close_box(&b, tfdt)
		}
		trun := open_box(&b, "trun")
		put32(&b, tf.trun_flags)
		put32(&b, tf.count)
		if tf.trun_flags & 0x01 != 0 {
			put32(&b, u32(tf.data_offset))
		}
		for v in tf.sizes {
			put32(&b, v)
		}
		close_box(&b, trun)
		close_box(&b, traf)
	}
	close_box(&b, moof)
	return b[:]
}

// A moof can only describe samples inside the mdat after it. Counts that
// can't fit are refused before anything is allocated, and a refused moof
// leaves the sample list as it was.
@(test)
fmp4_moof_bounds :: proc(t: ^testing.T) {
	init := audio.Mp4_Init {
		track_id = 1,
	}
	samples := make([dynamic]audio.Mp4_Sample, context.temp_allocator)
	append(&samples, audio.Mp4_Sample{1, 1}) // from an earlier fragment

	Case :: struct {
		name: string,
		traf: Traf,
		ok:   bool,
	}
	MDAT :: 1000 // payload bytes after the moof and an 8-byte mdat header
	cases := []Case {
		// The review's case: a 52-byte moof whose default size makes a
		// million one-byte samples.
		{"a million default-sized samples", {track = 1, tfhd_flags = 0x10, default_len = 1, trun_flags = 0x001, count = 1_000_000, data_offset = 60}, false},
		{"2^32-1 samples", {track = 1, tfhd_flags = 0x10, default_len = 1, trun_flags = 0x001, count = max(u32), data_offset = 60}, false},
		{"default sizes that fill the mdat", {track = 1, tfhd_flags = 0x10, default_len = 100, trun_flags = 0x001, count = 10, data_offset = 60}, true},
		{"default sizes one byte past it", {track = 1, tfhd_flags = 0x10, default_len = 100, trun_flags = 0x001, count = 10, data_offset = 61}, false},
		{"a default size of 0", {track = 1, tfhd_flags = 0x10, default_len = 0, trun_flags = 0x001, count = 1, data_offset = 60}, false},
		{"a sample size past the mdat", {track = 1, trun_flags = 0x201, count = 2, data_offset = 60, sizes = {500, 501}}, false},
		{"a sample size of 2^32-1", {track = 1, trun_flags = 0x201, count = 1, data_offset = 60, sizes = {max(u32)}}, false},
		{"data before the mdat", {track = 1, trun_flags = 0x201, count = 1, data_offset = -8, sizes = {10}}, false},
		{"a count longer than the table", {track = 1, trun_flags = 0x201, count = 3, data_offset = 60, sizes = {10, 10}}, false},
		{"a base offset near 2^64", {track = 1, tfhd_flags = 0x11, base = max(u64), default_len = 1, trun_flags = 0x001, count = 1}, false},
		{"another track only", {track = 2, trun_flags = 0x201, count = 1, data_offset = 60, sizes = {10}}, false},
	}
	for c in cases {
		moof := craft_moof(c.traf)
		data_start := i64(len(moof) + 8)
		data_end := data_start + MDAT
		// Keep data_offset relative to this moof's real size.
		if c.traf.trun_flags & 1 != 0 && c.traf.data_offset >= 60 {
			tf := c.traf
			tf.data_offset = i32(data_start) + c.traf.data_offset - 60
			moof = craft_moof(tf)
		}
		frag, st := audio.parse_mp4_moof(moof, &init, &samples, data_start, data_end)
		testing.expectf(t, (st == .Ok) == c.ok, "%s: %v (%s)", c.name, st, frag.reason)
		if st != .Ok {
			testing.expectf(t, len(samples) == 1, "%s: %d samples left behind", c.name, len(samples))
			testing.expectf(t, frag.reason != "", "%s: no reason", c.name)
		}
		for smp in samples[1:] {
			testing.expectf(t, smp.offset >= data_start && smp.offset + i64(smp.size) <= data_end, "%s: sample %v outside the mdat", c.name, smp)
		}
		resize(&samples, 1)
	}

	// More samples than any fragment needs, each in the table.
	sizes := make([]u32, audio.MP4_MAX_SAMPLES + 1, context.temp_allocator)
	for &v in sizes {
		v = 1
	}
	big := craft_moof({track = 1, trun_flags = 0x201, count = u32(len(sizes)), data_offset = 0, sizes = sizes})
	_, bst := audio.parse_mp4_moof(big, &init, &samples, i64(len(big)), i64(len(big)) + (1 << 20))
	testing.expect_value(t, bst, audio.Parse_Status.Invalid)
	testing.expect_value(t, len(samples), 1)

	// The mdat must come after the moof.
	moof := craft_moof({track = 1, trun_flags = 0x201, count = 1, sizes = {1}})
	_, mst := audio.parse_mp4_moof(moof, &init, &samples, 4, 100)
	testing.expect_value(t, mst, audio.Parse_Status.Invalid)

	// Box sizes: a 64-bit size above max(i64), boxes larger than what holds
	// them, and init segments with a huge box or one running to the end.
	_, hst := audio.mp4_box_header([]u8{0, 0, 0, 1, 'm', 'o', 'o', 'f', 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	testing.expect_value(t, hst, audio.Parse_Status.Invalid)
	nested := craft_moof({track = 1, trun_flags = 0x201, count = 1, sizes = {1}})
	nested[8], nested[9], nested[10], nested[11] = 0x7f, 0xff, 0xff, 0xff // the traf's size
	_, nst := audio.parse_mp4_moof(nested, &init, &samples, i64(len(nested)), i64(len(nested)) + 10)
	testing.expect_value(t, nst, audio.Parse_Status.Invalid)
	_, _, ist := audio.parse_mp4_init([]u8{0, 0, 0, 1, 'f', 't', 'y', 'p', 0x40, 0, 0, 0, 0, 0, 0, 0})
	testing.expect_value(t, ist, audio.Parse_Status.Invalid)
	_, _, ost := audio.parse_mp4_init([]u8{0, 0, 0, 0, 'f', 'r', 'e', 'e'})
	testing.expect_value(t, ost, audio.Parse_Status.Invalid)
	testing.expect_value(t, len(samples), 1)
}

// tfdt holds a 32-bit time in version 0 and a 64-bit one in version 1. A
// body too short for its version, or another version, is refused rather
// than read as the other layout. So are tfhd and trun versions with no
// known layout.
@(test)
fmp4_box_versions :: proc(t: ^testing.T) {
	init := audio.Mp4_Init {
		track_id = 1,
	}
	samples := make([dynamic]audio.Mp4_Sample, context.temp_allocator)
	Case :: struct {
		name: string,
		tfdt: []u8,
		ok:   bool,
		time: u64,
	}
	cases := []Case {
		{"version 0", {0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78}, true, 0x12345678},
		{"version 1", {1, 0, 0, 0, 0, 0, 0, 1, 0x12, 0x34, 0x56, 0x78}, true, 0x1_12345678},
		{"version 1 with a 32-bit time", {1, 0, 0, 0, 0x12, 0x34, 0x56, 0x78}, false, 0},
		{"version 0 without a time", {0, 0, 0, 0}, false, 0},
		{"version 2", {2, 0, 0, 0, 0x12, 0x34, 0x56, 0x78}, false, 0},
	}
	for c in cases {
		moof := craft_moof({track = 1, trun_flags = 0x201, count = 1, sizes = {10}, tfdt = c.tfdt})
		data_start := i64(len(moof) + 8)
		moof = craft_moof({track = 1, trun_flags = 0x201, count = 1, data_offset = i32(data_start), sizes = {10}, tfdt = c.tfdt})
		clear(&samples)
		frag, st := audio.parse_mp4_moof(moof, &init, &samples, data_start, data_start + 100)
		testing.expectf(t, (st == .Ok) == c.ok, "%s: %v (%s)", c.name, st, frag.reason)
		if c.ok {
			testing.expectf(t, frag.has_base_time && frag.base_time == c.time, "%s: base time %v %x", c.name, frag.has_base_time, frag.base_time)
		}
	}

	// The version is the top byte of the flags word. trun version 1 only
	// makes composition offsets signed.
	Version :: struct {
		name: string,
		tfhd: u32,
		trun: u32,
		ok:   bool,
	}
	versions := []Version{{"tfhd version 1", 1, 0, false}, {"trun version 2", 0, 2, false}, {"trun version 1", 0, 1, true}}
	for c in versions {
		tf := Traf{track = 1, tfhd_flags = c.tfhd << 24, trun_flags = c.trun << 24 | 0x201, count = 1, sizes = {10}}
		tf.data_offset = i32(len(craft_moof(tf)) + 8)
		moof := craft_moof(tf)
		clear(&samples)
		frag, st := audio.parse_mp4_moof(moof, &init, &samples, i64(tf.data_offset), i64(tf.data_offset) + 100)
		testing.expectf(t, (st == .Ok) == c.ok, "%s: %v (%s)", c.name, st, frag.reason)
	}
}

// Random damage to real moof boxes and init segments never crashes the
// parser, and a moof it accepts only has samples inside the mdat.
@(test)
fmp4_fuzz :: proc(t: ^testing.T) {
	dash, _ := test_dash(1.2, 0.5)
	init, _, _ := audio.parse_mp4_init(dash.init, context.temp_allocator)
	seg := dash.segments[0]
	styp, _ := audio.mp4_box_header(seg)
	moof_box, _ := audio.mp4_box_header(seg[styp.size:])
	mdat, _ := audio.mp4_box_header(seg[styp.size + moof_box.size:])
	orig := seg[styp.size:styp.size + moof_box.size]
	data_start, data_end := moof_box.size + i64(mdat.header), moof_box.size + mdat.size
	buf := make([]u8, len(orig), context.temp_allocator)
	ibuf := make([]u8, len(dash.init), context.temp_allocator)
	samples := make([dynamic]audio.Mp4_Sample, context.temp_allocator)
	rng := u64(0x9E3779B97F4A7C15)
	next :: proc(r: ^u64) -> u64 {
		r^ ~= r^ << 13
		r^ ~= r^ >> 7
		r^ ~= r^ << 17
		return r^
	}
	accepted := 0
	for _ in 0 ..< 20000 {
		copy(buf, orig)
		for _ in 0 ..< 1 + next(&rng) % 4 {
			i := int(next(&rng) % u64(len(buf)))
			// Size and count fields are what matter, so favour 0x00/0xff.
			switch next(&rng) % 3 {
			case 0:
				buf[i] = 0xff
			case 1:
				buf[i] = 0
			case:
				buf[i] = u8(next(&rng))
			}
		}
		clear(&samples)
		_, st := audio.parse_mp4_moof(buf, &init, &samples, data_start, data_end)
		if st == .Ok {
			accepted += 1
			testing.expect(t, len(samples) <= audio.MP4_MAX_SAMPLES)
			for smp in samples {
				if smp.offset < data_start || smp.offset + i64(smp.size) > data_end {
					testing.fail_now(t, "a sample outside the mdat")
				}
			}
		} else {
			testing.expect_value(t, len(samples), 0)
		}

		copy(ibuf, dash.init)
		ibuf[int(next(&rng) % u64(len(ibuf)))] = u8(next(&rng))
		ibuf[int(next(&rng) % u64(len(ibuf)))] = 0xff
		audio.parse_mp4_init(ibuf, context.temp_allocator)
	}
	testing.expect(t, accepted > 0)
}

// tfhd's base_data_offset counts from the start of the segment file, so
// sample offsets move by where the moof sits in it. default-base-is-moof
// counts from the moof, and so does the first traf without either. A later
// traf without either would need the earlier one's data and is refused.
@(test)
fmp4_base_data_offset :: proc(t: ^testing.T) {
	init := audio.Mp4_Init {
		track_id = 2,
	}
	samples := make([dynamic]audio.Mp4_Sample, context.temp_allocator)
	MOOF_AT :: 24 // after a styp

	explicit := craft_moof({track = 2, tfhd_flags = 0x01, base = MOOF_AT + 200, trun_flags = 0x201, count = 2, data_offset = 10, sizes = {30, 40}})
	_, st := audio.parse_mp4_moof(explicit, &init, &samples, i64(len(explicit)) + 8, 400, MOOF_AT)
	testing.expect_value(t, st, audio.Parse_Status.Ok)
	testing.expect_value(t, len(samples), 2)
	if len(samples) == 2 {
		testing.expect_value(t, samples[0], audio.Mp4_Sample{210, 30})
		testing.expect_value(t, samples[1], audio.Mp4_Sample{240, 40})
	}

	clear(&samples)
	moof_base := craft_moof({track = 2, tfhd_flags = 0x020000, trun_flags = 0x201, count = 1, data_offset = 210, sizes = {30}})
	_, st = audio.parse_mp4_moof(moof_base, &init, &samples, i64(len(moof_base)) + 8, 400, MOOF_AT)
	testing.expect_value(t, st, audio.Parse_Status.Ok)
	testing.expect_value(t, samples[0], audio.Mp4_Sample{210, 30})

	// The track's traf comes second, without a base.
	clear(&samples)
	second := craft_moof({track = 1, trun_flags = 0x201, count = 1, data_offset = 200, sizes = {10}}, {track = 2, trun_flags = 0x201, count = 1, data_offset = 210, sizes = {30}})
	f, sst := audio.parse_mp4_moof(second, &init, &samples, i64(len(second)) + 8, 400, MOOF_AT)
	testing.expect_value(t, sst, audio.Parse_Status.Invalid)
	testing.expect(t, f.reason != "")
	// With a base it's fine.
	second_based := craft_moof({track = 1, trun_flags = 0x201, count = 1, data_offset = 200, sizes = {10}}, {track = 2, tfhd_flags = 0x020000, trun_flags = 0x201, count = 1, data_offset = 210, sizes = {30}})
	_, sst = audio.parse_mp4_moof(second_based, &init, &samples, i64(len(second_based)) + 8, 400, MOOF_AT)
	testing.expect_value(t, sst, audio.Parse_Status.Ok)
}

// explicit_base rewrites a dashgen segment's tfhd from default-base-is-moof
// to an explicit base_data_offset of 0, the segment's first byte, with the
// trun's data_offset counted from there.
@(private = "file")
explicit_base :: proc(seg: []u8) -> []u8 {
	styp, _ := audio.mp4_box_header(seg)
	moof, _ := audio.mp4_box_header(seg[styp.size:])
	m := seg[styp.size:styp.size + moof.size]
	tfhd := strings.index(string(m), "tfhd") - 4
	trun := strings.index(string(m), "trun") - 4
	get :: proc(b: []u8) -> u32 {
		return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
	}
	set :: proc(b: []u8, v: u32) {
		b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
	}
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, ..seg[:int(styp.size)])
	moof_at := len(out)
	append(&out, ..m[:tfhd + 16]) // through the tfhd's track id
	append(&out, 0, 0, 0, 0, 0, 0, 0, 0) // base_data_offset 0
	append(&out, ..m[tfhd + 16:])
	o := out[moof_at:]
	set(o[0:], get(o[0:]) + 8) // moof
	traf := strings.index(string(o), "traf") - 4
	set(o[traf:], get(o[traf:]) + 8)
	set(o[tfhd:], get(o[tfhd:]) + 8)
	set(o[tfhd + 8:], 0x000001)
	t := trun + 8
	// data_offset was from the moof; the moof grew by 8 and the base is
	// now the segment's start.
	set(o[t + 16:], get(o[t + 16:]) + 8 + u32(moof_at))
	append(&out, ..seg[styp.size + moof.size:])
	return out[:]
}

// The player follows an explicit base_data_offset: a DASH track whose
// segments count their sample offsets from the segment's first byte plays
// bit for bit.
@(test)
dash_explicit_base_plays :: proc(t: ^testing.T) {
	RATE :: 96000
	dash, pcm := test_dash(1.6, 0.6, RATE)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	m.files["/e/0.mp4"] = dash.init
	segs := make([]audio.Segment, len(dash.segments), context.temp_allocator)
	for seg, i in dash.segments {
		path := fmt.tprintf("/e/%d.mp4", i + 1)
		m.files[path] = explicit_base(seg)
		segs[i] = {fmt.tprintf("%s%s", m.base_url, path[1:]), dash.starts[i]}
	}
	src := audio.Source {
		kind      = .Dash,
		serial    = 1,
		url       = fmt.tprintf("%se/0.mp4", m.base_url),
		segments  = segs,
		timescale = RATE,
		dash_end  = dash.total,
		gain      = 1,
		seconds   = 1.6,
	}
	capture := fmt.tprintf("%s/tidalfast-explicit-%d.wav", temp_base(), time.now()._nsec)
	defer os.remove(capture)
	p := audio.create(no_wake_hires, 0.3, capture, null_output = true, output = {bit_perfect = true})
	audio.play(p, src)
	ended := false
	for start := time.tick_now(); time.tick_since(start) < 6 * time.Second; {
		st := audio.status(p)
		testing.expectf(t, st.error.serial == 0, "the track failed: %s", audio.error_text(&st.error))
		if st.serial == 1 && st.state == .Ended {
			ended = true
			break
		}
		if st.error.serial != 0 {
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	audio.destroy(p)
	testing.expect(t, ended, "the track didn't play to the end")

	got := read_capture(capture)
	want := make([]f32, len(pcm), context.temp_allocator)
	for v, i in pcm {
		want[i] = as_float(v, 24)
	}
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
}

// Fake_List is an AudioBufferList with room for four buffers.
@(private = "file")
Fake_List :: struct {
	count:   u32,
	buffers: [4]audio.Audio_Buffer,
}

// fill_ring makes a ring holding frames numbered from 1, channel c of
// frame i being i*10 + c.
@(private = "file")
fill_ring :: proc(channels, frames: int) -> ^audio.Pcm_Ring {
	r := new(audio.Pcm_Ring, context.temp_allocator)
	data := make([]f32, 1024 * channels, context.temp_allocator)
	audio.ring_init(r, data, 1024, channels)
	src := make([]f32, frames * channels, context.temp_allocator)
	for i in 0 ..< frames {
		for c in 0 ..< channels {
			src[i * channels + c] = f32((i + 1) * 10 + c)
		}
	}
	audio.ring_write(r, src)
	return r
}

// hal_fill against buffer lists of several shapes: each buffer gets its
// own frames and channels, missing channels and frames are silence, and
// nothing is written past a buffer's size.
@(test)
hal_fill_buffer_shapes :: proc(t: ^testing.T) {
	POISON :: f32(-7)
	scratch := make([]f32, 4096, context.temp_allocator)
	poison :: proc(b: []f32) {
		for &v in b {
			v = POISON
		}
	}
	buffer :: proc(data: []f32, channels: int, extra_bytes := 0) -> audio.Audio_Buffer {
		return {channels = u32(channels), size = u32(len(data) * 4 - extra_bytes), data = raw_data(data)}
	}

	// One interleaved stereo buffer for a stereo source: written in place.
	// It holds 8 frames and 2 bytes; the ring has 6.
	{
		r := fill_ring(2, 6)
		buf := make([]f32, 17, context.temp_allocator)
		poison(buf)
		list := Fake_List{count = 1}
		list.buffers[0] = {channels = 2, size = 8 * 2 * 4 + 2, data = raw_data(buf)}
		m := audio.channel_map_make(2, {0, 1})
		testing.expect(t, m.identity)
		frames, n, out := audio.hal_fill((^audio.Audio_Buffer_List)(&list), r, scratch, &m)
		testing.expect_value(t, frames, 8)
		testing.expect_value(t, n, 6)
		testing.expect(t, out == raw_data(buf))
		testing.expect_value(t, buf[0], 10)
		testing.expect_value(t, buf[1], 11)
		testing.expect_value(t, buf[11], 61)
		for v in buf[12:16] {
			testing.expect_value(t, v, 0)
		}
		bytes := ([^]u8)(raw_data(buf[16:]))
		testing.expect(t, bytes[0] == 0 && bytes[1] == 0, "the bytes after the last frame weren't zeroed")
		testing.expect(t, bytes[2] != 0, "wrote past the buffer's size")
	}

	// Two non-interleaved buffers, one per channel.
	{
		r := fill_ring(2, 8)
		left := make([]f32, 8, context.temp_allocator)
		right := make([]f32, 8, context.temp_allocator)
		poison(left)
		poison(right)
		list := Fake_List{count = 2}
		list.buffers[0] = buffer(left, 1)
		list.buffers[1] = buffer(right, 1)
		m := audio.channel_map_make(2, {0, 1})
		frames, n, _ := audio.hal_fill((^audio.Audio_Buffer_List)(&list), r, scratch, &m)
		testing.expect_value(t, frames, 8)
		testing.expect_value(t, n, 8)
		testing.expect_value(t, left[0], 10)
		testing.expect_value(t, right[0], 11)
		testing.expect_value(t, left[7], 80)
		testing.expect_value(t, right[7], 81)
	}

	// A 4-channel interleaved device: stereo goes on its stereo pair, 3 and
	// 4 here, and the other two are silent.
	{
		r := fill_ring(2, 4)
		buf := make([]f32, 16, context.temp_allocator)
		poison(buf)
		list := Fake_List{count = 1}
		list.buffers[0] = buffer(buf, 4)
		m := audio.channel_map_make(2, {2, 3})
		testing.expect(t, !m.identity)
		audio.hal_fill((^audio.Audio_Buffer_List)(&list), r, scratch, &m)
		for i in 0 ..< 4 {
			f := buf[i * 4:]
			testing.expect_value(t, f[0], 0)
			testing.expect_value(t, f[1], 0)
			testing.expect_value(t, f[2], f32((i + 1) * 10))
			testing.expect_value(t, f[3], f32((i + 1) * 10 + 1))
		}
	}

	// A mono source on a stereo device plays on both channels.
	{
		r := fill_ring(1, 4)
		buf := make([]f32, 8, context.temp_allocator)
		poison(buf)
		list := Fake_List{count = 1}
		list.buffers[0] = buffer(buf, 2)
		m := audio.channel_map_make(1, {0, 1})
		audio.hal_fill((^audio.Audio_Buffer_List)(&list), r, scratch, &m)
		for i in 0 ..< 4 {
			testing.expect_value(t, buf[i * 2], f32((i + 1) * 10))
			testing.expect_value(t, buf[i * 2 + 1], f32((i + 1) * 10))
		}
	}

	// A buffer with no data is skipped; buffers of different sizes all get
	// the frames of the smallest, and the rest of the larger is silence.
	{
		r := fill_ring(2, 10)
		small := make([]f32, 4, context.temp_allocator)
		large := make([]f32, 8, context.temp_allocator)
		poison(small)
		poison(large)
		list := Fake_List{count = 3}
		list.buffers[0] = buffer(small, 1)
		list.buffers[1] = {channels = 1, size = 64, data = nil}
		list.buffers[2] = buffer(large, 1)
		m := audio.channel_map_make(2, {0, 2})
		frames, n, _ := audio.hal_fill((^audio.Audio_Buffer_List)(&list), r, scratch, &m)
		testing.expect_value(t, frames, 4)
		testing.expect_value(t, n, 4)
		testing.expect_value(t, small[3], 40)
		testing.expect_value(t, large[3], 41)
		for v in large[4:] {
			testing.expect_value(t, v, 0)
		}
	}

	// Nothing usable: no buffers, or only empty ones.
	{
		r := fill_ring(2, 4)
		list := Fake_List{count = 1}
		list.buffers[0] = {channels = 0, size = 0, data = nil}
		m := audio.channel_map_make(2, {0, 1})
		frames, n, _ := audio.hal_fill((^audio.Audio_Buffer_List)(&list), r, scratch, &m)
		testing.expect_value(t, frames, 0)
		testing.expect_value(t, n, 0)
		frames, n, _ = audio.hal_fill(nil, r, scratch, &m)
		testing.expect_value(t, frames, 0)
		testing.expect_value(t, audio.ring_buffered(r), 4)
	}
}

// When the output device goes away (simulated here: the null device can't
// be unplugged), the player closes the output, opens it again and plays
// on from where it was, instead of waiting on a ring nobody reads.
@(test)
device_loss_reopens :: proc(t: ^testing.T) {
	p := audio.create(no_wake_hires, 0.5, null_output = true, output = {bit_perfect = true})
	defer audio.destroy(p)
	audio.play(p, {kind = .Tone, serial = 1, gain = 1, seconds = 30, tone_hz = 440})
	before, ok := position(p, 22050)
	testing.expect(t, ok)
	audio.simulate_device_loss(p)
	for start := time.tick_now(); time.tick_since(start) < 2 * time.Second && audio.status(p).losses == 0; {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, audio.status(p).losses, 1)
	after, ok2 := position(p, before + 4410)
	testing.expect(t, ok2, "playback didn't go on after the device went away")
	testing.expect(t, after - before < 3 * 44100, "it skipped ahead")
	testing.expect_value(t, audio.status(p).device.rate, 44100)
}

// When another app sets the device to another rate (simulated here: the
// null device has no rate to change), the player stops writing to it at
// the old rate and plays on from where it was through the system mixer,
// saying why. The next time the output opens, it tries bit-perfect again.
@(test)
device_taken_falls_back_to_the_mixer :: proc(t: ^testing.T) {
	p := audio.create(no_wake_hires, 0.5, null_output = true, output = {bit_perfect = true})
	defer audio.destroy(p)
	audio.play(p, {kind = .Tone, serial = 1, gain = 1, seconds = 30, tone_hz = 440})
	before, ok := position(p, 22050)
	testing.expect(t, ok)
	audio.simulate_device_taken(p, 96000)
	for start := time.tick_now(); time.tick_since(start) < 2 * time.Second && audio.status(p).losses == 0; {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, audio.status(p).losses, 1)
	after, ok2 := position(p, before + 4410)
	testing.expect(t, ok2, "playback didn't go on after the device was taken")
	testing.expect(t, after - before < 3 * 44100, "it skipped ahead")
	st := audio.status(p)
	testing.expect(t, !st.device.bit_perfect)
	testing.expect_value(t, audio.device_reason(&st.device), "another app set the device to 96 kHz")

	audio.simulate_device_loss(p)
	for start := time.tick_now(); time.tick_since(start) < 2 * time.Second && audio.status(p).losses == 1; {
		time.sleep(5 * time.Millisecond)
	}
	_, ok3 := position(p, after + 4410)
	testing.expect(t, ok3)
	st = audio.status(p)
	testing.expect_value(t, st.losses, 2)
	testing.expect_value(t, audio.device_reason(&st.device), "")
}

// position waits up to 3 s for serial 1 to play past sample past.
@(private = "file")
position :: proc(p: ^audio.Player, past: i64) -> (i64, bool) {
	for start := time.tick_now(); time.tick_since(start) < 3 * time.Second; {
		if st := audio.status(p); st.serial == 1 && st.state == .Playing && st.sample > past {
			return st.sample, true
		}
		time.sleep(5 * time.Millisecond)
	}
	return 0, false
}

// Four threads saving different settings at once, while another reads the
// file: every read is whole JSON, the file ends with the newest settings,
// and no temp file is left.
@(test)
settings_saves_in_order :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/tidalfast-settings-race-%d", temp_base(), time.now()._nsec)
	defer os.remove_all(dir)
	store := app.Settings_Store {
		path = fmt.tprintf("%s/settings.json", dir),
	}

	Shared :: struct {
		store: ^app.Settings_Store,
		done:  bool,
		bad:   int,
		reads: int,
	}
	sh := Shared {
		store = &store,
	}
	writer :: proc(sh: ^Shared) {
		for i in 0 ..< 40 {
			st := app.Settings {
				bit_perfect = i % 2 == 0,
				device      = {rate = f64(1000 + i), orig_rate = 48000, uid_len = 3, uid = {0 = 'u', 1 = 'i', 2 = 'd'}},
			}
			app.settings_put(sh.store, st)
			app.settings_flush(sh.store)
		}
	}
	reader :: proc(sh: ^Shared) {
		for !sync.atomic_load(&sh.done) {
			data, err := os.read_entire_file(sh.store.path, context.temp_allocator)
			if err == nil {
				sh.reads += 1
				if _, ok := app.settings_decode_json(data); !ok {
					sh.bad += 1
				}
			}
			free_all(context.temp_allocator)
		}
	}
	r := thread.create_and_start_with_poly_data(&sh, reader)
	writers: [4]^thread.Thread
	for &w in writers {
		w = thread.create_and_start_with_poly_data(&sh, writer)
	}
	for w in writers {
		thread.join(w)
		thread.destroy(w)
	}
	// The newest settings, written last by whichever thread.
	app.settings_put(&store, {bit_perfect = true, volume = 0.5})
	testing.expect(t, app.settings_flush(&store))
	sync.atomic_store(&sh.done, true)
	thread.join(r)
	thread.destroy(r)

	testing.expectf(t, sh.bad == 0, "%d of %d reads weren't whole settings", sh.bad, sh.reads)
	st, ok := app.settings_load(store.path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{bit_perfect = true, volume = 0.5})
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for e in entries {
		testing.expectf(t, e.name == "settings.json", "left behind: %s", e.name)
	}
}

// With workers running, a change waits for a worker instead of the disk.
// Two quick changes make one write, with the newer settings: the second
// save finds the file already has them.
@(test)
settings_burst_writes_the_newest_once :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/tidalfast-settings-burst-%d", temp_base(), time.now()._nsec)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/settings.json", dir)
	s := new(app.State)
	defer free(s)
	d := &s.data
	d.settings_store.path = strings.clone(path)
	defer delete(d.settings_store.path)
	d.running = true

	app.settings_queue(d, {volume = 0.1})
	app.settings_queue(d, {volume = 0.2, shuffle = true})
	testing.expect(t, !os.exists(path), "a change wrote on the UI thread")
	saves := make([dynamic]app.Job, context.temp_allocator)
	for {
		job, ok := jobs.try_pop(&d.queue)
		if !ok {
			break
		}
		_, save := job.payload.(app.Save_Settings_Job)
		testing.expect(t, save)
		append(&saves, job)
	}
	testing.expect(t, len(saves) > 0)
	for job, i in saves {
		res := app.run_job(d, job)
		testing.expect_value(t, res.err, nil)
		app.result_free(&res)
		if i == 0 {
			st, ok := app.settings_load(path)
			testing.expect(t, ok)
			testing.expect_value(t, st, app.Settings{volume = 0.2, shuffle = true})
			testing.expect_value(t, os.remove(path), nil)
		}
	}
	testing.expect(t, !os.exists(path), "a save with nothing new wrote the file again")
}

// A save queued when the workers stop, which no worker ran, is written at
// shutdown, and so is the device record playback_shutdown clears after.
@(test)
shutdown_writes_the_newest_settings :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/tidalfast-settings-shutdown-%d", temp_base(), time.now()._nsec)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/settings.json", dir)
	s := new(app.State)
	defer free(s)
	d := &s.data
	d.settings_store.path = strings.clone(path)
	defer delete(d.settings_store.path)
	d.running = true

	s.settings = {volume = 0.4, repeat = .All, device = {orig_rate = 48000, rate = 96000}}
	app.settings_queue(d, s.settings)
	d.running = false
	for {
		if _, ok := jobs.try_pop(&d.queue); !ok {
			break
		}
	}
	testing.expect(t, !os.exists(path))
	testing.expect(t, app.settings_flush(&d.settings_store))
	st, ok := app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{volume = 0.4, repeat = .All, device = {orig_rate = 48000, rate = 96000}})

	s.playback.index = -1
	app.playback_shutdown(s)
	st, ok = app.settings_load(path)
	testing.expect(t, ok)
	testing.expect_value(t, st, app.Settings{volume = 0.4, repeat = .All})
}

// A record for a device that isn't there is left alone.
@(test)
device_change_undo_needs_the_device :: proc(t: ^testing.T) {
	c := audio.Device_Change {
		orig_rate = 48000,
		rate      = 96000,
	}
	testing.expect(t, !audio.device_change_undo(&c))
	c.uid_len = copy(c.uid[:], "tidalfast-test-no-such-device")
	testing.expect(t, !audio.device_change_undo(&c))
}

// Only a physical format that holds every bit of the source counts: an
// integer format at least as deep, or 32-bit float for up to 24 bits. A
// device with 16-bit integers only has nothing for a 24-bit track.
@(test)
physical_format_holds_every_bit :: proc(t: ^testing.T) {
	lpcm :: proc(bits: u32, float: bool, channels: u32 = 2) -> audio.Ranged_Description {
		flags: u32 = audio.FLAG_FLOAT if float else audio.FLAG_SIGNED
		return {format = {format_id = audio.FORMAT_LPCM, format_flags = flags, bits = bits, channels = channels}, rates = {44100, 192000}}
	}
	_, ok := audio.pick_physical_format({lpcm(16, false)}, 96000, 2, 24)
	testing.expect(t, !ok)
	f, ok2 := audio.pick_physical_format({lpcm(16, false), lpcm(32, true)}, 96000, 2, 24)
	testing.expect(t, ok2)
	testing.expect_value(t, f.bits, 32)
	f, ok2 = audio.pick_physical_format({lpcm(32, true), lpcm(32, false), lpcm(24, false)}, 96000, 2, 24)
	testing.expect(t, ok2)
	testing.expect(t, f.bits == 24 && f.format_flags & audio.FLAG_FLOAT == 0)
	testing.expect_value(t, f.sample_rate, 96000)
	_, ok = audio.pick_physical_format({lpcm(32, true)}, 96000, 2, 32)
	testing.expect(t, !ok)
	_, ok = audio.pick_physical_format({lpcm(24, false, 1)}, 96000, 2, 24)
	testing.expect(t, !ok)
}

// The output button names the device with a dot for the path, the menu
// shows each step from the track to the device, and the track's format goes
// under its title.
@(test)
output_button_and_signal_path :: proc(t: ^testing.T) {
	s := new(app.State)
	defer free(s)
	pb := &s.playback
	s.settings.bit_perfect = true

	// Nothing has played.
	label, mark := app.output_label(s)
	testing.expect_value(t, label, "Output")
	testing.expect_value(t, mark, app.Path_Mark.None)
	testing.expect_value(t, app.output_description(s), "Bit-perfect output is on")
	testing.expect_value(t, app.track_format(s), "")
	path := app.signal_path(s)
	testing.expect_value(t, path[0].detail, "Nothing playing")
	testing.expect_value(t, path[3].mark, app.Path_Mark.None)

	// Bit-perfect: every step passes the samples on.
	pb.status = {serial = 1, rate = 96000, bits = 24}
	dev := audio.Device_Info{bit_perfect = true, rate = 96000, bits = 24}
	dev.name_len = copy(dev.name[:], "Protocol Micro")
	app.playback_observe(s, {serial = 1, rate = 96000, bits = 24, device = dev})
	label, mark = app.output_label(s)
	testing.expect_value(t, label, "Protocol Micro")
	testing.expect_value(t, mark, app.Path_Mark.Exact)
	testing.expect_value(t, app.output_description(s), "Bit-perfect, 96 kHz")
	testing.expect_value(t, app.track_format(s), "FLAC, 24-bit, 96 kHz")
	path = app.signal_path(s)
	for step in path {
		testing.expectf(t, step.mark == .Exact, "%s: %v", step.name, step.mark)
	}
	testing.expect_value(t, path[0].detail, "FLAC, 24-bit, 96 kHz")
	testing.expect_value(t, path[2].detail, "Direct, no conversion")
	testing.expect_value(t, path[3].name, "Protocol Micro")
	testing.expect_value(t, path[3].detail, "24-bit integer, 96 kHz")

	// While the device reopens, the button keeps the last output.
	app.playback_observe(s, {serial = 1, rate = 96000, bits = 24})
	label, mark = app.output_label(s)
	testing.expect_value(t, label, "Protocol Micro")
	testing.expect_value(t, mark, app.Path_Mark.Exact)

	// Another app took the device: the mixer resamples, and the menu says
	// why.
	dev = {rate = 48000, bits = 24}
	dev.name_len = copy(dev.name[:], "Protocol Micro")
	dev.reason_len = copy(dev.reason[:], "another app set the device to 48 kHz")
	app.playback_observe(s, {serial = 1, rate = 96000, bits = 24, device = dev})
	label, mark = app.output_label(s)
	testing.expect_value(t, label, "Protocol Micro")
	testing.expect_value(t, mark, app.Path_Mark.Converted)
	testing.expect_value(t, app.output_description(s), "Not bit-perfect: another app set the device to 48 kHz")
	path = app.signal_path(s)
	testing.expect_value(t, path[0].mark, app.Path_Mark.Exact)
	testing.expect_value(t, path[1].mark, app.Path_Mark.Exact)
	testing.expect_value(t, path[2].detail, "Resampled to 48 kHz and mixed")
	testing.expect_value(t, path[2].mark, app.Path_Mark.Converted)
	testing.expect_value(t, path[3].mark, app.Path_Mark.Converted)

	// Bit-perfect output off: the conversions are the user's choice, so no
	// step is marked as a problem and the button has no dot.
	s.settings.bit_perfect = false
	label, mark = app.output_label(s)
	testing.expect_value(t, label, "Protocol Micro")
	testing.expect_value(t, mark, app.Path_Mark.None)
	testing.expect_value(t, app.output_description(s), "Bit-perfect output is off")
	path = app.signal_path(s)
	testing.expect_value(t, path[1].detail, "Applies volume and ReplayGain")
	for step in path[1:] {
		testing.expectf(t, step.mark == .Expected, "%s: %v", step.name, step.mark)
	}
}
