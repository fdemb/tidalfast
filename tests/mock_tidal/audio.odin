package mock_tidal

// Audio for the mock: a "live album" of three tracks cut from one
// continuous sine sweep, so a gap, a repeat or a click where one track
// meets the next shows up as a break in the sweep, plus four plain tones
// that every other track id plays. Generated as WAV at startup and encoded
// to FLAC with macOS's afconvert. afconvert writes no SEEKTABLE, so the
// files are rebuilt with one (every 2 s) unless -seektable=0, followed by a
// PADDING block the decoder has to skip.
//
// album-source.wav in the audio directory is the whole sweep, for
// tests/audio_check to compare a capture against.
//
// Encoding takes a few seconds, so the files stay in the directory with a
// stamp naming the mock binary that made them, and a mock started again
// from the same binary reads them back (audio_load).

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "../../src/audio"

RATE :: 44100
ALBUM_ID :: 4242
ALBUM_TRACK_ID :: 900_001 // and the next two
// Lengths in samples, deliberately not multiples of afconvert's 4608-sample frames.
ALBUM_LENGTHS := [3]int{RATE * 20 + 1234, RATE * 17 + 777, RATE * 12 + 4321}
ALBUM_TITLES := [3]string{"Overture (Live)", "The Long Middle (Live)", "Encore (Live)"}
// The album gain of -6.02 dB is x0.5; the track gains differ, so playing
// the album with track gain would show up as a jump at each boundary.
ALBUM_GAIN :: -6.0206
TRACK_GAINS := [3]f64{-2, -9, -4}
TONE_HZ := [4]f64{330, 392, 440, 523.25}
TONE_SECONDS :: 25

Audio_File :: struct {
	name: string,
	data: []u8,
}

audio_files: [8]Audio_File // 7 is the hi-res album's 16/44.1 track

// audio_stamp names this mock binary and the seektable setting. The
// files are the same as long as both are.
audio_stamp :: proc(seektable: bool) -> string {
	exe, _ := os.get_executable_path(context.temp_allocator)
	info, err := os.stat(exe, context.temp_allocator)
	if err != nil {
		return ""
	}
	return fmt.tprintf("%s %d %d seektable=%v", exe, info.size, time.to_unix_nanoseconds(info.modification_time), seektable)
}

// audio_load reads the files an earlier run of this binary left in dir,
// the hi-res ones too. False when the stamp doesn't match or a file is
// missing; then they have to be made again.
audio_load :: proc(dir, stamp: string) -> bool {
	have, err := os.read_entire_file(fmt.tprintf("%s/stamp", dir), context.temp_allocator)
	if stamp == "" || err != nil || string(have) != stamp || !os.exists(fmt.tprintf("%s/album-source.wav", dir)) {
		return false
	}
	names := [7]string{"album1", "album2", "album3", "tone0", "tone1", "tone2", "tone3"}
	for name, i in names {
		data, rerr := os.read_entire_file(fmt.tprintf("%s/%s.flac", dir, name), context.allocator)
		if rerr != nil {
			return false
		}
		audio_files[i] = {name, data}
	}
	if !hires_load(dir) {
		return false
	}
	fmt.printfln("mock: audio from %s", dir)
	return true
}

// audio_make makes every file in dir, and the stamp once they're all
// there, so files from a run cut short aren't read back.
audio_make :: proc(dir, stamp: string, seektable: bool) {
	_ = os.remove(fmt.tprintf("%s/stamp", dir))
	if !audio_prepare(dir, seektable) {
		fmt.eprintln("mock: couldn't make the audio files; playback won't work")
		return
	}
	if !hires_prepare(dir) {
		fmt.eprintln("mock: couldn't make the hi-res files")
		return
	}
	if stamp != "" {
		_ = os.write_entire_file(fmt.tprintf("%s/stamp", dir), transmute([]u8)stamp)
	}
}

audio_prepare :: proc(dir: string, seektable: bool) -> bool {
	os.make_directory(dir)
	total := 0
	for n in ALBUM_LENGTHS {
		total += n
	}
	sweep := make([]i16, total * 2)
	f0, f1 := 110.0, 1760.0
	T := f64(total) / RATE
	k := math.ln(f1 / f0)
	// Noise at -30 dB keeps FLAC from squeezing the sweep to a few hundred
	// kbps; with it the files are closer to music's 700 to 1000 kbps.
	seed := u32(1)
	noise :: proc(seed: ^u32) -> f64 {
		seed^ = seed^ * 1664525 + 1013904223
		return f64(seed^ >> 8) / f64(1 << 24) - 0.5
	}
	for i in 0 ..< total {
		t := f64(i) / RATE
		phase := 2 * math.PI * f0 * T / k * (math.exp(t / T * k) - 1)
		sweep[i * 2] = i16(32767 * (0.45 * math.sin(phase) + 0.06 * noise(&seed)))
		sweep[i * 2 + 1] = i16(32767 * (0.45 * math.sin(phase * 1.5) + 0.06 * noise(&seed)))
	}
	if !write_wav(fmt.tprintf("%s/album-source.wav", dir), sweep) {
		return false
	}
	start := 0
	for n, i in ALBUM_LENGTHS {
		name := fmt.aprintf("album%d", i + 1)
		data, ok := encode(dir, name, sweep[start * 2:(start + n) * 2], seektable)
		if !ok {
			return false
		}
		audio_files[i] = {name, data}
		start += n
	}
	for hz, i in TONE_HZ {
		pcm := make([]i16, TONE_SECONDS * RATE * 2, context.temp_allocator)
		for j in 0 ..< TONE_SECONDS * RATE {
			v := i16(0.3 * 32767 * math.sin(2 * math.PI * hz * f64(j) / RATE))
			pcm[j * 2], pcm[j * 2 + 1] = v, v
		}
		name := fmt.aprintf("tone%d", i)
		data, ok := encode(dir, name, pcm, seektable)
		if !ok {
			return false
		}
		audio_files[3 + i] = {name, data}
	}
	fmt.printfln("mock: audio in %s (seektable %v)", dir, seektable)
	return true
}

// encode writes pcm as WAV, runs afconvert, and returns the FLAC, rebuilt
// with a SEEKTABLE if asked.
encode :: proc(dir, name: string, pcm: []i16, seektable: bool) -> ([]u8, bool) {
	wav := fmt.tprintf("%s/%s.wav", dir, name)
	flac := fmt.tprintf("%s/%s.flac", dir, name)
	if !write_wav(wav, pcm) {
		return nil, false
	}
	desc := os.Process_Desc {
		command = {"afconvert", "-f", "flac", "-d", "flac", wav, flac},
	}
	state, _, stderr, err := os.process_exec(desc, context.temp_allocator)
	if err != nil || !state.success {
		fmt.eprintfln("mock: afconvert failed for %s: %v %s", name, err, string(stderr))
		return nil, false
	}
	os.remove(wav)
	data, rerr := os.read_entire_file(flac, context.allocator)
	if rerr != nil {
		return nil, false
	}
	if seektable {
		data = add_seektable(data)
		_ = os.write_entire_file(flac, data)
	}
	return data, true
}

write_wav :: proc(path: string, pcm: []i16) -> bool {
	h: [44]u8
	put32 :: proc(b: []u8, v: u32) {
		b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
	size := u32(len(pcm) * 2)
	copy(h[0:], "RIFF")
	put32(h[4:], 36 + size)
	copy(h[8:], "WAVEfmt ")
	put32(h[16:], 16)
	h[20], h[22] = 1, 2 // PCM, stereo
	put32(h[24:], RATE)
	put32(h[28:], RATE * 4)
	h[32], h[34] = 4, 16
	copy(h[36:], "data")
	put32(h[40:], size)
	out := make([]u8, 44 + len(pcm) * 2, context.temp_allocator)
	copy(out, h[:])
	copy(out[44:], mem.slice_to_bytes(pcm))
	return os.write_entire_file(path, out) == nil
}

// add_seektable rebuilds a FLAC file as STREAMINFO, a SEEKTABLE with a
// point every 2 s, a 4 KB PADDING block, and the frames. The frames are
// found with the player's own frame header parser.
add_seektable :: proc(data: []u8) -> []u8 {
	h := new(audio.Flac_Header, context.temp_allocator)
	if audio.parse_flac_header(data, h) != .Ok {
		return data
	}
	frames := data[h.audio_start:]
	points := make([dynamic]audio.Seekpoint, context.temp_allocator)
	next_point := i64(0)
	off := 0
	for off < len(frames) {
		fh, st := audio.parse_frame_header(frames[off:], h.info)
		if st != .Ok {
			off += 1
			continue
		}
		if fh.sample >= next_point {
			append(&points, audio.Seekpoint{fh.sample, i64(off)})
			next_point += 2 * RATE
		}
		// Skip to the next frame: the next confirmed header after this one.
		rel, _, fst := audio.find_frame(frames[off + fh.size:], h.info, true)
		if fst != .Ok {
			break
		}
		off += fh.size + rel
	}
	out := make([dynamic]u8, 0, len(data) + 8192)
	append(&out, ..transmute([]u8)string("fLaC"))
	append(&out, 0, 0, 0, 34)
	append(&out, ..data[h.streaminfo:h.streaminfo + 34])
	size := len(points) * 18
	append(&out, 3, u8(size >> 16), u8(size >> 8), u8(size))
	for p in points {
		be :: proc(out: ^[dynamic]u8, v: u64) {
			for i := 7; i >= 0; i -= 1 {
				append(out, u8(v >> uint(i * 8)))
			}
		}
		be(&out, u64(p.sample))
		be(&out, u64(p.offset))
		append(&out, u8(h.info.max_block >> 8), u8(h.info.max_block))
	}
	append(&out, 0x80 | 1, 0, 0x10, 0) // PADDING, 4096 bytes, last
	for _ in 0 ..< 4096 {
		append(&out, 0)
	}
	append(&out, ..frames)
	return out[:]
}

album_index :: proc(track_id: int) -> int {
	i := track_id - ALBUM_TRACK_ID
	return i if i >= 0 && i < 3 else -1
}

// playbackinfo_response is a LOSSLESS playbackinfopostpaywall answer with
// a BTS manifest pointing at /audio/<file>.flac on this server.
playbackinfo_response :: proc(track_id: int) -> Response {
	a := album_index(track_id)
	file := audio_files[a] if a >= 0 else audio_files[3 + track_id % 4]
	if file.data == nil {
		return json_response(404, `{"status":404,"userMessage":"No audio"}`)
	}
	manifest := fmt.tprintf(`{{"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":["http://127.0.0.1:%d/audio/%s.flac"]}}`, server.port, file.name)
	encoded, _ := base64.encode(transmute([]u8)manifest, allocator = context.temp_allocator)
	track_gain, track_peak, album_gain, album_peak := -3.0, 0.3, -3.0, 0.3
	if a >= 0 {
		track_gain, track_peak, album_gain, album_peak = TRACK_GAINS[a], 0.5, ALBUM_GAIN, 0.5
	}
	return json_response(200, fmt.tprintf(
		`{{"trackId":%d,"assetPresentation":"FULL","audioMode":"STEREO","audioQuality":"LOSSLESS","manifestMimeType":"application/vnd.tidal.bts","manifestHash":"mock","manifest":"%s","trackReplayGain":%f,"trackPeakAmplitude":%f,"albumReplayGain":%f,"albumPeakAmplitude":%f,"bitDepth":16,"sampleRate":44100}}`,
		track_id, encoded, track_gain, track_peak, album_gain, album_peak))
}

// aac_playbackinfo is what the device-code client gets: HTTP 200 with a
// BTS manifest for AAC in MP4, which the app refuses. The URL goes nowhere.
aac_playbackinfo :: proc(track_id: int) -> Response {
	fmt.printfln("mock: %d to the device-code login is AAC", track_id)
	manifest := fmt.tprintf(`{{"mimeType":"audio/mp4","codecs":"mp4a.40.2","encryptionType":"NONE","urls":["http://127.0.0.1:%d/audio/none.m4a"]}}`, server.port)
	encoded, _ := base64.encode(transmute([]u8)manifest, allocator = context.temp_allocator)
	return json_response(200, fmt.tprintf(
		`{{"trackId":%d,"assetPresentation":"FULL","audioMode":"STEREO","audioQuality":"HIGH","manifestMimeType":"application/vnd.tidal.bts","manifestHash":"mock","manifest":"%s","trackReplayGain":-3.0,"trackPeakAmplitude":0.3,"albumReplayGain":-3.0,"albumPeakAmplitude":0.3,"bitDepth":16,"sampleRate":44100}}`,
		track_id, encoded))
}

// audio_response serves a FLAC file, honouring "Range: bytes=a-" and
// "bytes=a-b".
audio_response :: proc(req: ^Request) -> Response {
	name := strings.trim_suffix(strings.trim_prefix(req.path, "/audio/"), ".flac")
	data: []u8
	for f in audio_files {
		if f.name == name {
			data = f.data
		}
	}
	if data == nil {
		return json_response(404, `{}`)
	}
	r := Response {
		status       = 200,
		content_type = "audio/flac",
		body         = data,
		audio        = true,
	}
	if strings.has_prefix(req.range, "bytes=") {
		a, _, b := strings.partition(strings.trim_prefix(req.range, "bytes="), "-")
		start, _ := parse_i(a)
		end := len(data) - 1
		if b != "" {
			end, _ = parse_i(b)
		}
		if start >= len(data) {
			r.status = 416
			r.body = nil
			r.content_range = fmt.tprintf("bytes */%d", len(data))
			return r
		}
		end = min(end, len(data) - 1)
		r.status = 206
		r.body = data[start:end + 1]
		r.content_range = fmt.tprintf("bytes %d-%d/%d", start, end, len(data))
	}
	return r
}
