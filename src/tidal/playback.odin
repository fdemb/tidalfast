package tidal

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Stream_Info is what the player needs to play a track: one URL to a FLAC
// file (BTS), or the segments of a fragmented MP4 holding FLAC (DASH), and
// the loudness data for ReplayGain.
Stream_Info :: struct {
	track_id:      i64,
	quality:       string, // what TIDAL delivered: LOSSLESS, HI_RES_LOSSLESS, ...
	codec:         string, // FLAC, MP4A, ...
	mime_type:     string,
	url:           string, // BTS: the file; DASH: the initialization segment
	dash:          bool,
	segments:      []Dash_Segment, // DASH: the media segments in order
	timescale:     int, // DASH: units of Dash_Segment.start and length per second
	sample_rate:   int,
	bit_depth:     int,
	// ReplayGain in dB and linear peaks. A missing gain is 0 dB and a
	// missing peak 1.0, so it does nothing.
	track_gain:    f64,
	track_peak:    f64,
	album_gain:    f64,
	album_peak:    f64,
}

// resolve_stream asks TIDAL how to play a track at quality. This is the one
// place that knows which endpoint gives streams: v1 playbackinfopostpaywall.
// LOSSLESS through the device-code client comes as a BTS manifest with one
// FLAC URL. HI_RES_LOSSLESS, and every FLAC tier through the PKCE client,
// comes as a DASH MPD whose segments are fragmented MP4 holding FLAC.
// Encrypted and non-FLAC streams are refused.
resolve_stream :: proc(s: ^Session, track_id: i64, quality: Quality, allocator := context.allocator) -> (info: Stream_Info, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "playbackmode", "STREAM")
	add_param(&params, "audioquality", QUALITY_NAMES[quality])
	add_param(&params, "assetpresentation", "FULL")
	obj, rerr := request_object(
		s,
		{method = .GET, path = fmt.tprintf("tracks/%d/playbackinfopostpaywall", track_id), params = params[:]},
		context.temp_allocator,
	)
	if rerr != nil {
		return {}, remap_error(rerr, .Stream_Not_Available, "Stream not available for this track", "Stream unavailable")
	}
	return parse_playback_info(obj, allocator)
}

// parse_playback_info reads a playbackinfopostpaywall response.
parse_playback_info :: proc(obj: json.Object, allocator := context.allocator) -> (info: Stream_Info, err: Error) {
	info = {
		track_id    = ji64(obj, "trackId"),
		quality     = strings.clone(jstr(obj, "audioQuality"), allocator),
		sample_rate = jint(obj, "sampleRate", 44100),
		bit_depth   = jint(obj, "bitDepth", 16),
		track_gain  = jf64(obj, "trackReplayGain", 0),
		track_peak  = jf64(obj, "trackPeakAmplitude", 1),
		album_gain  = jf64(obj, "albumReplayGain", 0),
		album_peak  = jf64(obj, "albumPeakAmplitude", 1),
	}
	if info.track_peak <= 0 {
		info.track_peak = 1
	}
	if info.album_peak <= 0 {
		info.album_peak = 1
	}
	// Some tracks have no album gain; the track's is the best guess then.
	if !jhas(obj, "albumReplayGain") && jhas(obj, "trackReplayGain") {
		info.album_gain, info.album_peak = info.track_gain, info.track_peak
	}

	mime := jstr(obj, "manifestMimeType")
	if strings.contains(mime, MANIFEST_MIME_MPD) {
		return parse_dash_playback(info, jstr(obj, "manifest"), allocator)
	}
	if !strings.contains(mime, MANIFEST_MIME_BTS) {
		return {}, make_error(.Unknown_Manifest_Format, "Unknown manifest format", detail = mime)
	}
	raw, derr := base64.decode(jstr(obj, "manifest"), allocator = context.temp_allocator)
	if derr != nil {
		return {}, make_error(.Manifest_Decode, "Stream manifest is not valid base64")
	}
	v, jerr := json.parse(raw, .JSON, true, context.temp_allocator)
	m, is_obj := v.(json.Object)
	if jerr != nil || !is_obj {
		return {}, make_error(.Manifest_Decode, "BTS manifest is not valid JSON")
	}
	// LOSSLESS comes unencrypted ("NONE"). Anything else needs keys we
	// don't have.
	if enc := jstr(m, "encryptionType"); enc != "" && enc != "NONE" {
		return {}, make_error(.Stream_Not_Available, "Encrypted stream", detail = enc)
	}
	codec := strings.to_upper(jstr(m, "codecs"), context.temp_allocator)
	if dot := strings.index_byte(codec, '.'); dot >= 0 {
		codec = codec[:dot]
	}
	info.codec = strings.clone(codec, allocator)
	info.mime_type = strings.clone(jstr(m, "mimeType"), allocator)
	if codec != "FLAC" && !strings.contains(info.mime_type, "flac") {
		return {}, make_error(.Stream_Not_Available, "Not a FLAC stream", detail = codec)
	}
	urls, _ := jarr(m, "urls")
	if len(urls) == 0 {
		return {}, make_error(.Manifest_Decode, "Manifest has no URLs")
	}
	url, _ := urls[0].(json.String)
	if url == "" {
		return {}, make_error(.Manifest_Decode, "Manifest URL is empty")
	}
	info.url = strings.clone(url, allocator)
	return info, nil
}

// parse_dash_playback reads the MPD of a DASH answer into info.
@(private = "file")
parse_dash_playback :: proc(info: Stream_Info, manifest: string, allocator := context.allocator) -> (out: Stream_Info, err: Error) {
	out = info
	raw, derr := base64.decode(manifest, allocator = context.temp_allocator)
	if derr != nil {
		return {}, make_error(.Manifest_Decode, "Stream manifest is not valid base64")
	}
	mpd := string(raw)
	// Widevine and PlayReady streams name their DRM here.
	if strings.contains(mpd, "ContentProtection") {
		return {}, make_error(.Stream_Not_Available, "Encrypted stream", detail = "ContentProtection")
	}
	dash := dash_info_from_mpd(mpd, allocator) or_return
	if !strings.contains(strings.to_lower(dash.codecs, context.temp_allocator), "flac") {
		return {}, make_error(.Stream_Not_Available, "Not a FLAC stream", detail = dash.codecs)
	}
	if dash.init_url == "" || len(dash.segments) == 0 {
		return {}, make_error(.Manifest_Decode, "DASH manifest has no initialization or media segments")
	}
	out.dash = true
	out.codec = strings.clone("FLAC", allocator)
	out.mime_type = dash.mime_type
	out.url = dash.init_url
	out.segments = dash.segments
	out.timescale = dash.timescale
	if dash.audio_sampling_rate > 0 {
		out.sample_rate = dash.audio_sampling_rate
	}
	return out, nil
}
