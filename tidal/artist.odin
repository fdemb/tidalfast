package tidal

import "core:fmt"

// artist_get fetches an artist by id.
artist_get :: proc(s: ^Session, artist_id: i64, allocator := context.allocator) -> (artist: Artist, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d", artist_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Object_Not_Found, "Artist not found", "Artist unavailable")
	}
	p := parser_make(s, allocator)
	return parse_artist(&p, obj), nil
}

@(private = "file")
artist_album_list :: proc(s: ^Session, artist_id: i64, filter: string, limit: Maybe(int), offset: int, allocator: Allocator) -> (albums: []Album, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	if filter != "" {
		add_param(&params, "filter", filter)
	}
	if l, ok := limit.?; ok {
		add_param(&params, "limit", l)
	}
	add_param(&params, "offset", offset)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d/albums", artist_id), params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Album, parse_album_simple), nil
}

// artist_albums returns the artist's albums.
artist_albums :: proc(s: ^Session, artist_id: i64, limit: Maybe(int) = nil, offset := 0, allocator := context.allocator) -> ([]Album, Error) {
	return artist_album_list(s, artist_id, "", limit, offset, allocator)
}

// artist_ep_singles returns the artist's EPs and singles.
artist_ep_singles :: proc(s: ^Session, artist_id: i64, limit: Maybe(int) = nil, offset := 0, allocator := context.allocator) -> ([]Album, Error) {
	return artist_album_list(s, artist_id, "EPSANDSINGLES", limit, offset, allocator)
}

// artist_other returns albums the artist appears on as a featured artist.
artist_other :: proc(s: ^Session, artist_id: i64, limit: Maybe(int) = nil, offset := 0, allocator := context.allocator) -> ([]Album, Error) {
	return artist_album_list(s, artist_id, "COMPILATIONS", limit, offset, allocator)
}

// artist_top_tracks returns the artist's tracks, sorted by popularity.
artist_top_tracks :: proc(s: ^Session, artist_id: i64, limit: Maybe(int) = nil, offset := 0, allocator := context.allocator) -> (tracks: []Track, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	if l, ok := limit.?; ok {
		add_param(&params, "limit", l)
	}
	add_param(&params, "offset", offset)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d/toptracks", artist_id), params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Track, parse_track_in_album), nil
}

// artist_videos returns the artist's videos.
artist_videos :: proc(s: ^Session, artist_id: i64, limit: Maybe(int) = nil, offset := 0, allocator := context.allocator) -> (videos: []Video, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	if l, ok := limit.?; ok {
		add_param(&params, "limit", l)
	}
	add_param(&params, "offset", offset)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d/videos", artist_id), params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Video, parse_video_simple), nil
}

// artist_bio returns the biography, with identifiers of other TIDAL objects
// embedded in the text.
artist_bio :: proc(s: ^Session, artist_id: i64, allocator := context.allocator) -> (bio: string, err: Error) {
	scratch_begin(allocator)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d/bio", artist_id)}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return pstr(&p, obj, "text"), nil
}

// artist_similar returns similar artists.
artist_similar :: proc(s: ^Session, artist_id: i64, allocator := context.allocator) -> (artists: []Artist, err: Error) {
	scratch_begin(allocator)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d/similar", artist_id)}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Artist, parse_artist), nil
}

// artist_radio returns tracks similar to this artist.
artist_radio :: proc(s: ^Session, artist_id: i64, limit := 100, allocator := context.allocator) -> (tracks: []Track, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "limit", limit)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d/radio", artist_id), params = params[:]}, context.temp_allocator)
	if rerr != nil {
		return nil, remap_error(rerr, .Metadata_Not_Available, "Track radio not available for this track", "Track radio unavailable")
	}
	p := parser_make(s, allocator)
	return map_items(&p, obj, Track, parse_track_in_album), nil
}

// artist_radio_mix returns the artist radio as a Mix, with its items.
artist_radio_mix :: proc(s: ^Session, artist_id: i64, allocator := context.allocator) -> (mix: Mix, err: Error) {
	scratch_begin(allocator)
	obj, rerr := request_object(s, {method = .GET, path = fmt.tprintf("artists/%d/mix", artist_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Metadata_Not_Available, "Artist radio not available for this artist", "Artist radio unavailable")
	}
	return mix_get(s, jstr(obj, "id"), allocator)
}

// artist_image_url builds a picture URL. Valid sizes: 160, 320, 480, 750.
artist_image_url :: proc(s: ^Session, a: Artist, size := 320, allocator := context.allocator) -> (url: string, err: Error) {
	switch size {
	case 160, 320, 480, 750:
	case:
		return "", invalid_resolution(size, size)
	}
	if a.picture == "" {
		return "", make_error(.Asset_Not_Available, "No image available")
	}
	return resource_url(s.config.image_url, a.picture, size, size, allocator), nil
}

// artist_page fetches the artist page as seen on https://listen.tidal.com/artist/<id>.
artist_page :: proc(s: ^Session, artist_id: i64, allocator := context.allocator) -> (page: Page, err: Error) {
	return page_get(s, "pages/artist", {Param{"artistId", fmt.tprint(artist_id)}}, allocator)
}
