package tidal

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

// search searches TIDAL. TIDAL returns at most 300 results; use offset to
// page. top_hit is the most relevant result among the requested types.
search :: proc(s: ^Session, query: string, types := SEARCH_ALL, limit := 50, offset := 0, allocator := context.allocator) -> (results: Search_Results, err: Error) {
	scratch_begin(allocator)
	SEARCH_TYPE_IDS := [Search_Type]string {
		.Artist   = "artists",
		.Album    = "albums",
		.Track    = "tracks",
		.Video    = "videos",
		.Playlist = "playlists",
		.Mix      = "mixs",
	}
	ids := make([dynamic]string, 0, 6, context.temp_allocator)
	for t in Search_Type {
		if t in types {
			append(&ids, SEARCH_TYPE_IDS[t])
		}
	}
	if len(ids) == 0 {
		return {}, make_error(.Invalid_Argument, "Tried to search for an invalid type")
	}

	params := make_params()
	add_param(&params, "query", query)
	add_param(&params, "limit", limit)
	add_param(&params, "offset", offset)
	add_param(&params, "types", join_ids(ids[:]))
	obj := request_object(s, {method = .GET, path = "search", params = params[:]}, context.temp_allocator) or_return

	p := parser_make(s, allocator)
	section :: proc(obj: json.Object, key: string) -> json.Object {
		o, _ := jobj(obj, key)
		return o
	}
	results.artists = map_items(&p, section(obj, "artists"), Artist, parse_artist)
	results.albums = map_items(&p, section(obj, "albums"), Album, parse_album_simple)
	results.tracks = map_items(&p, section(obj, "tracks"), Track, parse_track_in_album)
	results.videos = map_items(&p, section(obj, "videos"), Video, parse_video_simple)
	results.playlists = map_items(&p, section(obj, "playlists"), Playlist, parse_playlist)

	// Find the type of the top hit so it can be parsed
	if top, ok := jobj(obj, "topHit"); ok && len(top) > 0 {
		if value, has_value := jobj(top, "value"); has_value {
			if item, parsed := parse_item_by_type(&p, jstr(top, "type"), value); parsed {
				results.top_hit = item
			}
		}
	}
	return results, nil
}

// tracks_by_isrc returns the tracks with an ISRC (e.g. "USSM12209515"),
// using TIDAL's openapi v2. Fails with Object_Not_Found when none match and
// Invalid_Isrc when TIDAL rejects the code.
tracks_by_isrc :: proc(s: ^Session, isrc: string, allocator := context.allocator) -> (tracks: []Track, err: Error) {
	scratch_begin(allocator)
	ids := isrc_track_ids(s, isrc) or_return
	out := make([dynamic]Track, 0, len(ids), allocator)
	for id in ids {
		t, terr := track_get(s, id, allocator = allocator)
		if is_error(terr, .Object_Not_Found) {
			continue
		}
		if terr != nil {
			return nil, terr
		}
		append(&out, t)
	}
	return out[:], nil
}

// track_by_isrc returns the first track with an ISRC that TIDAL has. It
// fails as tracks_by_isrc does, and with Object_Not_Found when no match is
// available either.
track_by_isrc :: proc(s: ^Session, isrc: string, allocator := context.allocator) -> (track: Track, err: Error) {
	scratch_begin(allocator)
	ids := isrc_track_ids(s, isrc) or_return
	for id in ids {
		t, terr := track_get(s, id, allocator = allocator)
		if !is_error(terr, .Object_Not_Found) {
			return t, terr
		}
	}
	return {}, make_error(.Object_Not_Found, "No available track found for ISRC")
}

// The ids of the tracks with an ISRC, in temp memory.
@(private = "file")
isrc_track_ids :: proc(s: ^Session, isrc: string) -> (ids: []i64, err: Error) {
	params := []Param{{"filter[isrc]", isrc}}
	obj, rerr := request_object(s, {method = .GET, path = "tracks", params = params, base_url = s.config.openapi_v2_location}, context.temp_allocator)
	if is_error(rerr, .Http) {
		log.errorf("Invalid ISRC code '%s'", isrc)
		e := rerr.(Api_Error)
		e.kind, e.message = .Invalid_Isrc, "Invalid ISRC"
		return nil, e
	}
	if rerr != nil {
		return nil, rerr
	}
	data, _ := jarr(obj, "data")
	if len(data) == 0 {
		log.warnf("No matching tracks found for ISRC '%s'", isrc)
		return nil, make_error(.Object_Not_Found, "No matching tracks found for ISRC")
	}
	out := make([dynamic]i64, 0, len(data), context.temp_allocator)
	for v in data {
		item := v.(json.Object) or_continue
		append(&out, value_i64(item["id"]))
	}
	return out[:], nil
}

// albums_by_barcode returns the albums with a UPC barcode (e.g.
// "196589525444"), using TIDAL's openapi v2.
albums_by_barcode :: proc(s: ^Session, barcode: string, allocator := context.allocator) -> (albums: []Album, err: Error) {
	scratch_begin(allocator)
	params := []Param{{"filter[barcodeId]", barcode}}
	obj, rerr := request_object(s, {method = .GET, path = "albums", params = params, base_url = s.config.openapi_v2_location}, context.temp_allocator)
	if is_error(rerr, .Http) {
		log.errorf("Invalid UPC barcode '%s'.", barcode)
		e := rerr.(Api_Error)
		e.kind, e.message = .Invalid_Upc, "Invalid UPC"
		return nil, e
	}
	if rerr != nil {
		return nil, rerr
	}
	data, _ := jarr(obj, "data")
	if len(data) == 0 {
		log.warnf("No matching albums found for UPC barcode '%s'", barcode)
		return nil, make_error(.Object_Not_Found, "No matching albums found for UPC barcode")
	}
	out := make([dynamic]Album, 0, len(data), allocator)
	for v in data {
		item := v.(json.Object) or_continue
		a := album_get(s, value_i64(item["id"]), allocator) or_return
		append(&out, a)
	}
	return out[:], nil
}

// home fetches the home page as seen on https://listen.tidal.com, from the
// v2 feed or the legacy v1 page.
home :: proc(s: ^Session, use_legacy_endpoint := false, allocator := context.allocator) -> (page: Page, err: Error) {
	if use_legacy_endpoint {
		return page_get(s, "pages/home", nil, allocator)
	}
	scratch_begin(allocator)
	auth := session_auth(s, context.temp_allocator)
	params := []Param{{"deviceType", "BROWSER"}, {"locale", auth.locale}, {"platform", "WEB"}}
	obj := request_object(s, {method = .GET, path = "home/feed/static", base_url = s.config.api_v2_location, params = params}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return parse_page(&p, obj), nil
}

// https://listen.tidal.com/view/pages/explore
explore :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/explore", nil, allocator)
}

// https://listen.tidal.com/view/pages/hires
hires_page :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/hires", nil, allocator)
}

// https://listen.tidal.com/view/pages/for_you
for_you :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/for_you", nil, allocator)
}

// https://listen.tidal.com/view/pages/videos
videos_page :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/videos", nil, allocator)
}

// The global genre page, https://listen.tidal.com/view/pages/genre_page
genres_page :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/genre_page", nil, allocator)
}

// The local genre page, https://listen.tidal.com/view/pages/genre_page_local
local_genres_page :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/genre_page_local", nil, allocator)
}

// https://listen.tidal.com/view/pages/moods
moods_page :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/moods", nil, allocator)
}

// The user's mixes, https://listen.tidal.com/view/pages/my_collection_my_mixes
mixes_page :: proc(s: ^Session, allocator := context.allocator) -> (Page, Error) {
	return page_get(s, "pages/my_collection_my_mixes", nil, allocator)
}

// genres_get lists TIDAL's genres.
genres_get :: proc(s: ^Session, allocator := context.allocator) -> (genres: []Genre, err: Error) {
	scratch_begin(allocator)
	v, _ := request_json(s, {method = .GET, path = "genres"}, context.temp_allocator) or_return
	arr, ok := v.(json.Array)
	if !ok {
		return nil, make_error(.Bad_Response, "Expected a JSON array")
	}
	p := parser_make(s, allocator)
	out := make([dynamic]Genre, 0, len(arr), allocator)
	for g in arr {
		obj := g.(json.Object) or_continue
		append(&out, parse_genre(&p, obj))
	}
	return out[:], nil
}

Genre_Item_Type :: enum {
	Playlist,
	Artist,
	Album,
	Track,
	Video,
}

// genre_items returns a genre's items of one type.
genre_items :: proc(s: ^Session, genre: Genre, type: Genre_Item_Type, allocator := context.allocator) -> (items: []Item, err: Error) {
	scratch_begin(allocator)
	name: string
	has: bool
	switch type {
	case .Playlist:
		name, has = "playlists", genre.playlists
	case .Artist:
		name, has = "artists", genre.artists
	case .Album:
		name, has = "albums", genre.albums
	case .Track:
		name, has = "tracks", genre.tracks
	case .Video:
		name, has = "videos", genre.videos
	}
	if !has {
		return nil, make_error(.Invalid_Argument, "This genre does not contain the requested type", detail = name)
	}
	obj := request_object(s, {method = .GET, path = fmt.tprintf("genres/%s/%s", genre.path, name)}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	kind := strings.trim_suffix(name, "s")
	list, _ := jarr(obj, "items")
	out := make([dynamic]Item, 0, len(list), allocator)
	for v in list {
		o := v.(json.Object) or_continue
		if inner, nested := jobj(o, "item"); nested {
			o = inner
		}
		if item, ok := parse_item_by_type(&p, kind, o); ok {
			append(&out, item)
		}
	}
	return out[:], nil
}
