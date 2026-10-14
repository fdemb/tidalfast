package tidal

import "core:fmt"
import "core:time"

// album_get fetches an album by id.
album_get :: proc(s: ^Session, album_id: i64, allocator := context.allocator) -> (album: Album, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("albums/%d", album_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Object_Not_Found, "Album not found", "Album unavailable")
	}
	p := parser_make(s, allocator)
	return parse_album(&p, obj), nil
}

// album_year is the year of album_available_release_date.
album_year :: proc(a: Album) -> Maybe(int) {
	t, ok := album_available_release_date(a).?
	if !ok {
		return nil
	}
	y, _, _ := time.date(t)
	return y
}

// album_available_release_date returns the release date if known, otherwise
// the date the album was released on TIDAL.
album_available_release_date :: proc(a: Album) -> Maybe(time.Time) {
	if t, ok := a.release_date.?; ok {
		return t
	}
	return a.tidal_release_date
}

// album_tracks returns the tracks of an album. When parent is given, every
// track's `album` points to it (it must outlive the result); otherwise each
// track gets the sparse album from the track JSON.
album_tracks :: proc(
	s: ^Session,
	album_id: i64,
	limit: Maybe(int) = nil,
	offset := 0,
	parent: ^Album = nil,
	allocator := context.allocator,
) -> (
	tracks: []Track,
	err: Error,
) {
	scratch_begin(allocator)
	params := make_params()
	if l, ok := limit.?; ok {
		add_param(&params, "limit", l)
	}
	add_param(&params, "offset", offset)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("albums/%d/tracks", album_id), params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	p.album = parent
	return map_items(&p, obj, Track, parse_track_in_album), nil
}

// album_items returns the first `limit` tracks and videos of an album. See
// album_tracks for parent.
album_items :: proc(
	s: ^Session,
	album_id: i64,
	limit := 100,
	offset := 0,
	parent: ^Album = nil,
	allocator := context.allocator,
) -> (
	items: []Media,
	err: Error,
) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "offset", offset)
	add_param(&params, "limit", limit)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("albums/%d/items", album_id), params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	p.album = parent
	return map_items(&p, obj, Media, parse_media_in_album), nil
}

// album_image_url builds a cover URL. Valid sizes: 80, 160, 320, 640, 1280;
// 0 means the original resolution. Albums without a cover get the default one.
album_image_url :: proc(s: ^Session, a: Album, size := 320, allocator := context.allocator) -> (url: string, err: Error) {
	switch size {
	case 0, 80, 160, 320, 640, 1280:
	case:
		return "", invalid_resolution(size, size)
	}
	cover := a.cover if a.cover != "" else DEFAULT_ALBUM_IMG
	if size == 0 {
		return resource_url_origin(s.config.image_url_origin, cover, allocator), nil
	}
	return resource_url(s.config.image_url, cover, size, size, allocator), nil
}

// album_video_url builds a URL to the mp4 video cover. Valid sizes: 80, 160,
// 320, 640, 1280; 0 means the original resolution.
album_video_url :: proc(s: ^Session, a: Album, size := 320, allocator := context.allocator) -> (url: string, err: Error) {
	if a.video_cover == "" {
		return "", make_error(.Asset_Not_Available, "This album does not have a video cover.")
	}
	switch size {
	case 0, 80, 160, 320, 640, 1280:
	case:
		return "", invalid_resolution(size, size)
	}
	if size == 0 {
		return resource_url_origin(s.config.video_url_origin, a.video_cover, allocator), nil
	}
	return resource_url(s.config.video_url, a.video_cover, size, size, allocator), nil
}

// album_page fetches the album page as seen on https://listen.tidal.com/album/<id>.
album_page :: proc(s: ^Session, album_id: i64, allocator := context.allocator) -> (page: Page, err: Error) {
	return page_get(s, "pages/album", {Param{"albumId", fmt.tprint(album_id)}}, allocator)
}

// album_similar returns albums similar to this one.
album_similar :: proc(s: ^Session, album_id: i64, allocator := context.allocator) -> (albums: []Album, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("albums/%d/similar", album_id)}, context.temp_allocator)
	if rerr != nil {
		return nil, remap_error(rerr, .Metadata_Not_Available, "No similar albums exist for this album", "Similar artists unavailable")
	}
	p := parser_make(s, allocator)
	return map_items(&p, obj, Album, parse_album_simple), nil
}

// album_review returns the album review, with wimp links. Fails with an
// Http error if there is no review yet.
album_review :: proc(s: ^Session, album_id: i64, allocator := context.allocator) -> (review: string, err: Error) {
	scratch_begin(allocator)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("albums/%d/review", album_id)}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return pstr(&p, obj, "text"), nil
}

Audio_Resolution :: struct {
	bit_depth:   int,
	sample_rate: int,
}

// album_audio_resolution returns the bit depth and sample rate of the first
// track, or of every track with individual_tracks. That costs one request
// per track, so use it with care.
album_audio_resolution :: proc(s: ^Session, album_id: i64, individual_tracks := false, allocator := context.allocator) -> (res: []Audio_Resolution, err: Error) {
	scratch_begin(allocator)
	tracks := album_tracks(s, album_id, allocator = context.temp_allocator) or_return
	if len(tracks) == 0 {
		return nil, make_error(.Object_Not_Found, "Album has no tracks")
	}
	n := len(tracks) if individual_tracks else 1
	out := make([]Audio_Resolution, n, allocator)
	for i in 0 ..< n {
		stream := track_stream(s, tracks[i].id, context.temp_allocator) or_return
		out[i] = {stream.bit_depth, stream.sample_rate}
	}
	return out, nil
}
