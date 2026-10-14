package tidal

import "core:fmt"
import "core:slice"

// track_get fetches a track. With with_album, the sparse album embedded in
// the track is replaced by the full album (one more request).
track_get :: proc(s: ^Session, track_id: i64, with_album := false, allocator := context.allocator) -> (track: Track, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("tracks/%d", track_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Object_Not_Found, "Track not found", "Track unavailable")
	}
	p := parser_make(s, allocator)
	track = parse_track(&p, obj)
	if with_album && track.album != nil {
		album := album_get(s, track.album.id, allocator) or_return
		track.album = new_clone(album, allocator)
	}
	return track, nil
}

// track_url returns a direct URL to the track at the configured quality.
// Not available for PKCE sessions; use track_stream instead.
track_url :: proc(s: ^Session, track_id: i64, allocator := context.allocator) -> (url: string, err: Error) {
	scratch_begin(allocator)
	auth := session_auth(s, context.temp_allocator)
	if auth.is_pkce {
		return "", make_error(.Url_Not_Available, "Track URL not available with PKCE sessions", detail = QUALITY_NAMES[s.config.quality])
	}
	params := make_params()
	add_param(&params, "urlusagemode", "STREAM")
	add_param(&params, "audioquality", QUALITY_NAMES[s.config.quality])
	add_param(&params, "assetpresentation", "FULL")
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("tracks/%d/urlpostpaywall", track_id), params = params[:]}, context.temp_allocator)
	if rerr != nil {
		return "", remap_error(rerr, .Url_Not_Available, "URL not available for this track", "URL unavailable")
	}
	return first_url(obj, allocator)
}

@(private)
first_url :: proc(obj: JSON_Object, allocator: Allocator) -> (url: string, err: Error) {
	urls, ok := jarr(obj, "urls")
	if !ok || len(urls) == 0 {
		return "", make_error(.Bad_Response, "Response has no urls")
	}
	return value_id_string(urls[0], allocator), nil
}

// track_lyrics fetches the lyrics of a track.
track_lyrics :: proc(s: ^Session, track_id: i64, allocator := context.allocator) -> (lyrics: Lyrics, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("tracks/%d/lyrics", track_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Metadata_Not_Available, "No lyrics exists for this track", "Lyrics unavailable")
	}
	p := parser_make(s, allocator)
	return parse_lyrics(&p, obj), nil
}

// track_radio returns tracks similar to this track.
track_radio :: proc(s: ^Session, track_id: i64, limit := 100, allocator := context.allocator) -> (tracks: []Track, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "limit", limit)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("tracks/%d/radio", track_id), params = params[:]}, context.temp_allocator)
	if rerr != nil {
		return nil, remap_error(rerr, .Metadata_Not_Available, "Track radio not available for this track", "Track radio unavailable")
	}
	p := parser_make(s, allocator)
	return map_items(&p, obj, Track, parse_track_in_album), nil
}

// track_radio_mix returns the track radio as a Mix, with its items.
track_radio_mix :: proc(s: ^Session, track_id: i64, allocator := context.allocator) -> (mix: Mix, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("tracks/%d/mix", track_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Metadata_Not_Available, "Track radio not available for this track", "Track radio unavailable")
	}
	return mix_get(s, jstr(obj, "id"), allocator)
}

// track_stream fetches the playback info for a track at the configured
// quality. Decode it with stream_get_manifest.
track_stream :: proc(s: ^Session, track_id: i64, allocator := context.allocator) -> (stream: Stream, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "playbackmode", "STREAM")
	add_param(&params, "audioquality", QUALITY_NAMES[s.config.quality])
	add_param(&params, "assetpresentation", "FULL")
	obj, rerr := request_object(
		s,
		{method = .GET, path = fmt.tprintf("tracks/%d/playbackinfopostpaywall", track_id), params = params[:]},
		context.temp_allocator,
	)
	if rerr != nil {
		return {}, remap_error(rerr, .Stream_Not_Available, "Stream not available for this track", "Stream unavailable")
	}
	p := parser_make(s, allocator)
	return parse_stream(&p, obj), nil
}

track_is_hi_res_lossless :: proc(t: Track) -> bool {
	return slice.contains(t.media_metadata_tags, "HIRES_LOSSLESS")
}

track_is_lossless :: proc(t: Track) -> bool {
	return slice.contains(t.media_metadata_tags, "LOSSLESS")
}

track_is_dolby_atmos :: proc(t: Track) -> bool {
	return slice.contains(t.audio_modes, "DOLBY_ATMOS")
}

// video_get fetches a video by id.
video_get :: proc(s: ^Session, video_id: i64, allocator := context.allocator) -> (video: Video, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("videos/%d", video_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Object_Not_Found, "Video not found", "Video unavailable")
	}
	p := parser_make(s, allocator)
	return parse_video(&p, obj), nil
}

// video_url returns the URL of the m3u8 playlist at the configured quality.
video_url :: proc(s: ^Session, video_id: i64, allocator := context.allocator) -> (url: string, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "urlusagemode", "STREAM")
	add_param(&params, "videoquality", VIDEO_QUALITY_NAMES[s.config.video_quality])
	add_param(&params, "assetpresentation", "FULL")
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("videos/%d/urlpostpaywall", video_id), params = params[:]}, context.temp_allocator)
	if rerr != nil {
		return "", remap_error(rerr, .Url_Not_Available, "URL not available for this video", "URL unavailable")
	}
	return first_url(obj, allocator)
}

// video_image_url builds a still image URL. Valid sizes: 160x107, 480x320,
// 750x500, 1080x720.
video_image_url :: proc(s: ^Session, v: Video, width := 1080, height := 720, allocator := context.allocator) -> (url: string, err: Error) {
	if !valid_wide_size(width, height) {
		return "", invalid_resolution(width, height)
	}
	if v.image_id == "" {
		return "", make_error(.Asset_Not_Available, "No cover image")
	}
	return resource_url(s.config.image_url, v.image_id, width, height, allocator), nil
}
