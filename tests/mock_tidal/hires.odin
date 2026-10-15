package mock_tidal

// The hi-res test album: a 16/44.1 track served as a BTS FLAC, then two
// 24/96 tracks served as DASH (fragmented MP4 holding FLAC, cut by
// tests/dashgen) to a PKCE login that asks for HI_RES_LOSSLESS. Anyone else
// gets LOSSLESS, as TIDAL does: the 16/44.1 file.
//
// Every track is noise from a seeded xorshift generator at about -60 dBFS,
// so bit-perfect playback, which skips the volume, stays quiet, and a
// capture can be compared against <name>-source.wav sample for sample. The
// 24-bit tracks use every bit position of the low 13 bits.

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"

import "../dashgen"

PKCE_CLIENT_ID :: "6BDSRdpK9hqEBTgU" // TIDAL's Android client, see src/tidal/config.odin
HIRES_ALBUM_ID :: 4343
HIRES_TRACK_ID :: 900_101 // and the next two
HIRES_SEGMENT_SECONDS :: 4

Hires :: struct {
	name:    string,
	title:   string,
	rate:    int,
	bits:    int,
	seconds: int,
}

HIRES := [3]Hires {
	{"hires-a", "Quiet Noise 16/44.1", 44100, 16, 8},
	{"hires-b", "Quiet Noise 24/96", 96000, 24, 10},
	{"hires-c", "Quiet Noise 24/96 Again", 96000, 24, 6},
}

hires_dash: [len(HIRES)]dashgen.Dash

hires_prepare :: proc(dir: string) -> bool {
	for h, i in HIRES {
		pcm := dashgen.quiet_signal(h.rate * h.seconds, 2, h.bits, u32(0x5eed0 + i), context.temp_allocator)
		wav := fmt.tprintf("%s/%s-source.wav", dir, h.name)
		flac := fmt.tprintf("%s/%s.flac", dir, h.name)
		if !write_wav_int(wav, pcm, h.rate, h.bits, 2) {
			return false
		}
		desc := os.Process_Desc {
			command = {"afconvert", "-f", "flac", "-d", "flac", wav, flac},
		}
		state, _, stderr, err := os.process_exec(desc, context.temp_allocator)
		if err != nil || !state.success {
			fmt.eprintfln("mock: afconvert failed for %s: %v %s", h.name, err, string(stderr))
			return false
		}
		data, rerr := os.read_entire_file(flac, context.allocator)
		if rerr != nil {
			return false
		}
		if h.bits == 16 {
			audio_files[7] = {h.name, data}
			continue
		}
		d, ok := dashgen.from_flac(data, HIRES_SEGMENT_SECONDS)
		if !ok {
			fmt.eprintfln("mock: couldn't cut %s into segments", h.name)
			return false
		}
		hires_dash[i] = d
		fmt.printfln("mock: %s: %d-bit %d Hz, %d samples in %d segments", h.name, d.bits, d.rate, d.total, len(d.segments))
	}
	return true
}

// write_wav_int writes interleaved integer samples as 16 or 24-bit PCM.
write_wav_int :: proc(path: string, pcm: []i32, rate, bits, channels: int) -> bool {
	bytes := bits / 8
	out := make([dynamic]u8, 0, 44 + len(pcm) * bytes, context.temp_allocator)
	put32 :: proc(out: ^[dynamic]u8, v: u32) {
		append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	put16 :: proc(out: ^[dynamic]u8, v: u16) {
		append(out, u8(v), u8(v >> 8))
	}
	size := u32(len(pcm) * bytes)
	append(&out, ..transmute([]u8)string("RIFF"))
	put32(&out, 36 + size)
	append(&out, ..transmute([]u8)string("WAVEfmt "))
	put32(&out, 16)
	put16(&out, 1)
	put16(&out, u16(channels))
	put32(&out, u32(rate))
	put32(&out, u32(rate * channels * bytes))
	put16(&out, u16(channels * bytes))
	put16(&out, u16(bits))
	append(&out, ..transmute([]u8)string("data"))
	put32(&out, size)
	for v in pcm {
		for b in 0 ..< bytes {
			append(&out, u8(u32(v) >> uint(8 * b)))
		}
	}
	return os.write_entire_file(path, out[:]) == nil
}

hires_index :: proc(track_id: int) -> int {
	i := track_id - HIRES_TRACK_ID
	return i if i >= 0 && i < len(HIRES) else -1
}

write_hires_track :: proc(b: ^strings.Builder, k: int) {
	h := HIRES[k]
	quality := "HIRES_LOSSLESS" if h.bits > 16 else "LOSSLESS"
	fmt.sbprintf(b, `{{"id":%d,"title":%q,"duration":%d,"trackNumber":%d,"version":null,"audioQuality":"%s","artist":{{"id":8,"name":"The Mock Quartet"}},"artists":[{{"id":8,"name":"The Mock Quartet"}}],"album":{{"id":%d,"title":"Hi-Res Test","cover":"%s"}}}}`,
		HIRES_TRACK_ID + k, h.title, h.seconds, k + 1, quality, HIRES_ALBUM_ID, image_id(HIRES_ALBUM_ID))
}

// hires_playbackinfo answers playbackinfopostpaywall for a hi-res album
// track: DASH 24/96 for a PKCE login asking for HI_RES_LOSSLESS, else the
// 16/44.1 file as BTS.
hires_playbackinfo :: proc(track_id: int, quality: string, pkce: bool) -> Response {
	k := hires_index(track_id)
	h := HIRES[k]
	gains := `"trackReplayGain":-3.0,"trackPeakAmplitude":0.01,"albumReplayGain":-3.0,"albumPeakAmplitude":0.01`
	if h.bits > 16 && pkce && quality == "HI_RES_LOSSLESS" && hires_dash[k].init != nil {
		base := fmt.tprintf("http://127.0.0.1:%d/dash/%s", server.port, h.name)
		manifest := dashgen.mpd(hires_dash[k], base, context.temp_allocator)
		encoded, _ := base64.encode(transmute([]u8)manifest, allocator = context.temp_allocator)
		return json_response(200, fmt.tprintf(
			`{{"trackId":%d,"assetPresentation":"FULL","audioMode":"STEREO","audioQuality":"HI_RES_LOSSLESS","manifestMimeType":"application/dash+xml","manifestHash":"mock","manifest":"%s",%s,"bitDepth":%d,"sampleRate":%d}}`,
			track_id, encoded, gains, h.bits, h.rate))
	}
	if h.bits > 16 {
		fmt.printfln("mock: %d is hi-res, but only a PKCE login asking for HI_RES_LOSSLESS gets it; sending LOSSLESS", track_id)
	}
	if audio_files[7].data == nil {
		return json_response(404, `{"status":404,"userMessage":"No audio"}`)
	}
	manifest := fmt.tprintf(`{{"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":["http://127.0.0.1:%d/audio/%s.flac"]}}`, server.port, audio_files[7].name)
	encoded, _ := base64.encode(transmute([]u8)manifest, allocator = context.temp_allocator)
	return json_response(200, fmt.tprintf(
		`{{"trackId":%d,"assetPresentation":"FULL","audioMode":"STEREO","audioQuality":"LOSSLESS","manifestMimeType":"application/vnd.tidal.bts","manifestHash":"mock","manifest":"%s",%s,"bitDepth":16,"sampleRate":44100}}`,
		track_id, encoded, gains))
}

// dash_response serves /dash/<name>/<n>.mp4: 0 is the initialization
// segment, 1 on the media segments.
dash_response :: proc(req: ^Request) -> Response {
	rest := strings.trim_prefix(req.path, "/dash/")
	name, _, file := strings.partition(rest, "/")
	n, ok := parse_i(strings.trim_suffix(file, ".mp4"))
	for h, k in HIRES {
		d := &hires_dash[k]
		if h.name != name || d.init == nil || !ok {
			continue
		}
		body: []u8
		switch {
		case n == 0:
			body = d.init
		case n >= 1 && n <= len(d.segments):
			body = d.segments[n - 1]
		case:
			return json_response(404, `{}`)
		}
		return {status = 200, content_type = "video/mp4", body = body, audio = true}
	}
	return json_response(404, `{}`)
}

// authorize_response stands in for TIDAL's login page: it redirects
// straight to the "Oops" page with a code, as if the user had logged in.
authorize_response :: proc(req: ^Request) -> Response {
	if req.query["client_id"] != PKCE_CLIENT_ID || req.query["code_challenge"] == "" {
		return {status = 400, content_type = "text/html", body = transmute([]u8)string("<html><body>Bad client or no code challenge</body></html>")}
	}
	server.pkce_codes += 1
	return {
		status = 302,
		content_type = "text/html",
		location = fmt.tprintf("%s?code=mock-pkce-code-%d&state=na", req.query["redirect_uri"], server.pkce_codes),
	}
}
