package tidal

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Favorites of the logged in user.

@(private = "file")
favorites_base :: proc(s: ^Session) -> (path: string, err: Error) {
	uid := logged_in_user_id(s) or_return
	return fmt.tprintf("users/%d/favorites", uid), nil
}

@(private = "file")
add_favorite :: proc(s: ^Session, kind: string, key: string, ids: []string, params: []Param = nil) -> (err: Error) {
	scratch_begin(context.allocator)
	if len(ids) == 0 {
		return make_error(.Invalid_Argument, "An empty list was provided.")
	}
	base := favorites_base(s) or_return
	data := []Param{{key, join_ids(ids)}}
	_, err = request(s, {method = .POST, path = fmt.tprintf("%s/%s", base, kind), data = data, params = params}, context.temp_allocator)
	return
}

@(private = "file")
remove_favorite :: proc(s: ^Session, kind: string, id: string) -> (err: Error) {
	scratch_begin(context.allocator)
	base := favorites_base(s) or_return
	_, err = request(s, {method = .DELETE, path = fmt.tprintf("%s/%s/%s", base, kind, id)}, context.temp_allocator)
	return
}

favorites_add_album :: proc(s: ^Session, album_ids: []string) -> Error {
	return add_favorite(s, "albums", "albumId", album_ids)
}

favorites_add_artist :: proc(s: ^Session, artist_ids: []string) -> Error {
	return add_favorite(s, "artists", "artistId", artist_ids)
}

favorites_add_track :: proc(s: ^Session, track_ids: []string) -> Error {
	return add_favorite(s, "tracks", "trackId", track_ids)
}

favorites_add_video :: proc(s: ^Session, video_id: string) -> Error {
	return add_favorite(s, "videos", "videoIds", {video_id}, {{"limit", "100"}})
}

// favorites_add_track_by_isrc favorites the first track matching isrc.
// Returns false when no track matched.
favorites_add_track_by_isrc :: proc(s: ^Session, isrc: string) -> (ok: bool, err: Error) {
	scratch_begin(context.allocator)
	tracks, terr := tracks_by_isrc(s, isrc, context.temp_allocator)
	if is_error(terr, .Object_Not_Found) || (terr == nil && len(tracks) == 0) {
		return false, nil
	}
	if terr != nil {
		return false, terr
	}
	favorites_add_track(s, {fmt.tprint(tracks[0].id)}) or_return
	return true, nil
}

// favorites_add_playlist favorites playlists into a folder (v2 endpoint).
// With validate, ok reports whether TIDAL confirmed every playlist.
favorites_add_playlist :: proc(s: ^Session, playlist_ids: []string, parent_folder_id := "root", validate := false) -> (ok: bool, err: Error) {
	scratch_begin(context.allocator)
	if len(playlist_ids) == 0 {
		return false, make_error(.Invalid_Argument, "An empty list was provided.")
	}
	params := []Param{{"folderId", parent_folder_id}, {"uuids", join_ids(playlist_ids)}}
	resp := request(s, {method = .PUT, path = FOLDERS_ENDPOINT + "/add-favorites", base_url = s.config.api_v2_location, params = params}, context.temp_allocator) or_return
	if !validate {
		return true, nil
	}
	v, jerr := json.parse(resp.body, .JSON, true, context.temp_allocator)
	obj, is_obj := v.(json.Object)
	if jerr != nil || !is_obj {
		return false, nil
	}
	added, _ := jarr(obj, "addedItems")
	if len(added) == 0 {
		return false, nil
	}
	// Playlist ids follow the 'trn:playlist:' prefix.
	added_ids := make([dynamic]string, 0, len(added), context.temp_allocator)
	for item in added {
		o := item.(json.Object) or_continue
		parts := strings.split(jstr(o, "trn"), ":", context.temp_allocator)
		if len(parts) < 3 {
			return false, nil
		}
		append(&added_ids, parts[2])
	}
	for id in playlist_ids {
		if !slice.contains(added_ids[:], id) {
			return false, nil
		}
	}
	return true, nil
}

@(private = "file")
change_mixes :: proc(s: ^Session, mix_ids: []string, action: string, result_key: string, validate: bool) -> (ok: bool, err: Error) {
	scratch_begin(context.allocator)
	if len(mix_ids) == 0 {
		return false, make_error(.Invalid_Argument, "An empty list was provided.")
	}
	params := []Param{{"mixIds", join_ids(mix_ids)}, {"onArtifactNotFound", "FAIL"}}
	resp := request(s, {method = .PUT, path = fmt.tprintf("favorites/mixes/%s", action), base_url = s.config.api_v2_location, params = params}, context.temp_allocator) or_return
	if !validate {
		return true, nil
	}
	v, _ := json.parse(resp.body, .JSON, true, context.temp_allocator)
	obj, _ := v.(json.Object)
	changed, _ := jarr(obj, result_key)
	for id in mix_ids {
		found := false
		for c in changed {
			if str, is_str := c.(json.String); is_str && str == id {
				found = true
				break
			}
		}
		if !found {
			return false, nil
		}
	}
	return true, nil
}

// favorites_add_mixes favorites mixes, e.g. artist or track radios (v2
// endpoint). Missing ids fail the request.
favorites_add_mixes :: proc(s: ^Session, mix_ids: []string, validate := false) -> (ok: bool, err: Error) {
	return change_mixes(s, mix_ids, "add", "addedItems", validate)
}

favorites_remove_mixes :: proc(s: ^Session, mix_ids: []string, validate := false) -> (ok: bool, err: Error) {
	return change_mixes(s, mix_ids, "remove", "deletedItems", validate)
}

favorites_remove_artist :: proc(s: ^Session, artist_id: string) -> Error {
	return remove_favorite(s, "artists", artist_id)
}

favorites_remove_album :: proc(s: ^Session, album_id: string) -> Error {
	return remove_favorite(s, "albums", album_id)
}

favorites_remove_track :: proc(s: ^Session, track_id: string) -> Error {
	return remove_favorite(s, "tracks", track_id)
}

favorites_remove_video :: proc(s: ^Session, video_id: string) -> Error {
	return remove_favorite(s, "videos", video_id)
}

favorites_remove_playlist :: proc(s: ^Session, playlist_ids: []string) -> Error {
	return favorites_remove_folders_playlists(s, playlist_ids, "playlist")
}

// favorites_remove_folders_playlists removes folders or playlists (ids or
// trns). kind is "folder" or "playlist".
favorites_remove_folders_playlists :: proc(s: ^Session, trns: []string, kind := "folder") -> (err: Error) {
	scratch_begin(context.allocator)
	if kind != "playlist" && kind != "folder" {
		return make_error(.Invalid_Argument, "Invalid trn value used for playlist/folder endpoint")
	}
	if len(trns) == 0 {
		return make_error(.Invalid_Argument, "An empty list was provided.")
	}
	params := []Param{{"trns", join_ids(full_trns(trns, kind))}}
	_, err = request(s, {method = .PUT, path = FOLDERS_ENDPOINT + "/remove", base_url = s.config.api_v2_location, params = params}, context.temp_allocator)
	return
}

// ---- Listing ----

@(private = "file")
list_params :: proc(limit, offset: int, order: string, direction: Maybe(Order_Direction)) -> []Param {
	params := make_params()
	add_param(&params, "limit", limit)
	add_param(&params, "offset", offset)
	add_order(&params, order, direction)
	return params[:]
}

@(private = "file")
order_name :: proc(names: [$E]string, order: Maybe(E)) -> string {
	o, ok := order.?
	return names[o] if ok else ""
}

// favorites_list returns one page and the total TIDAL gives for the whole
// list.
@(private = "file")
favorites_list :: proc(s: ^Session, kind: string, params: []Param, $T: typeid, parse: proc(p: ^Parser, obj: json.Object) -> T, allocator: Allocator) -> (items: []T, total: int, err: Error) {
	scratch_begin(allocator)
	base := favorites_base(s) or_return
	obj := request_object(s, {method = .GET, path = fmt.tprintf("%s/%s", base, kind), params = params}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, T, parse), jint(obj, "totalNumberOfItems"), nil
}

@(private = "file")
favorites_count :: proc(s: ^Session, kind: string) -> (count: int, err: Error) {
	base := favorites_base(s) or_return
	return total_items(s, fmt.tprintf("%s/%s", base, kind))
}

@(private = "file")
favorites_paginated :: proc(s: ^Session, kind: string, order: string, direction: Maybe(Order_Direction), $T: typeid, parse: proc(p: ^Parser, obj: json.Object) -> T, allocator: Allocator) -> (items: []T, err: Error) {
	scratch_begin(allocator)
	count := favorites_count(s, kind) or_return
	base := favorites_base(s) or_return
	params := make_params()
	add_order(&params, order, direction)
	return paginate(s, {method = .GET, path = fmt.tprintf("%s/%s", base, kind), params = params[:]}, count, T, parse, allocator)
}

favorites_artists :: proc(s: ^Session, limit := 50, offset := 0, order: Maybe(Artist_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> ([]Artist, Error) {
	items, _, err := favorites_list(s, "artists", list_params(limit, offset, order_name(ARTIST_ORDER_NAMES, order), order_direction), Artist, parse_artist, allocator)
	return items, err
}

favorites_artists_count :: proc(s: ^Session) -> (int, Error) {
	return favorites_count(s, "artists")
}

favorites_artists_paginated :: proc(s: ^Session, order: Maybe(Artist_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> ([]Artist, Error) {
	return favorites_paginated(s, "artists", order_name(ARTIST_ORDER_NAMES, order), order_direction, Artist, parse_artist, allocator)
}

favorites_albums :: proc(s: ^Session, limit := 50, offset := 0, order: Maybe(Album_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> ([]Album, Error) {
	items, _, err := favorites_list(s, "albums", list_params(limit, offset, order_name(ALBUM_ORDER_NAMES, order), order_direction), Album, parse_album_simple, allocator)
	return items, err
}

favorites_albums_count :: proc(s: ^Session) -> (int, Error) {
	return favorites_count(s, "albums")
}

favorites_albums_paginated :: proc(s: ^Session, order: Maybe(Album_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> ([]Album, Error) {
	return favorites_paginated(s, "albums", order_name(ALBUM_ORDER_NAMES, order), order_direction, Album, parse_album_simple, allocator)
}

// favorites_tracks returns one page of liked tracks and how many there are
// in all. TIDAL leaves tracks that can't be played out of a page but counts
// them in the total, so a page can come back short before the end.
favorites_tracks :: proc(s: ^Session, limit := 50, offset := 0, order: Maybe(Item_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> (tracks: []Track, total: int, err: Error) {
	return favorites_list(s, "tracks", list_params(limit, offset, order_name(ITEM_ORDER_NAMES, order), order_direction), Track, parse_track_in_album, allocator)
}

// Includes tracks that may not be available for playback.
// favorites_track_ids returns the id of every liked track in one request,
// from users/<id>/favorites/ids. TIDAL doesn't document it; the web player
// and other clients use it, and it lists the ids as strings.
favorites_track_ids :: proc(s: ^Session, allocator := context.allocator) -> (ids: []i64, err: Error) {
	scratch_begin(allocator)
	base := favorites_base(s) or_return
	obj := request_object(s, {method = .GET, path = fmt.tprintf("%s/ids", base)}, context.temp_allocator) or_return
	list, _ := obj["TRACK"].(json.Array)
	out := make([dynamic]i64, 0, len(list), allocator)
	for v in list {
		#partial switch x in v {
		case json.String:
			if id, ok := strconv.parse_i64(x); ok {
				append(&out, id)
			}
		case json.Integer:
			append(&out, x)
		}
	}
	return out[:], nil
}

favorites_tracks_count :: proc(s: ^Session) -> (int, Error) {
	return favorites_count(s, "tracks")
}

favorites_tracks_paginated :: proc(s: ^Session, order: Maybe(Item_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> ([]Track, Error) {
	return favorites_paginated(s, "tracks", order_name(ITEM_ORDER_NAMES, order), order_direction, Track, parse_track_in_album, allocator)
}

favorites_videos :: proc(s: ^Session, limit := 50, offset := 0, order: Maybe(Video_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> ([]Video, Error) {
	items, _, err := favorites_list(s, "videos", list_params(limit, offset, order_name(VIDEO_ORDER_NAMES, order), order_direction), Video, parse_video_simple, allocator)
	return items, err
}

favorites_videos_count :: proc(s: ^Session) -> (int, Error) {
	return favorites_count(s, "videos")
}

favorites_videos_paginated :: proc(s: ^Session, order: Maybe(Item_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> ([]Video, Error) {
	return favorites_paginated(s, "videos", order_name(ITEM_ORDER_NAMES, order), order_direction, Video, parse_video_simple, allocator)
}

// favorites_playlists returns favorite playlists in the root folder (v2
// endpoint, at most 50 per call). Pass the returned cursor to get the next
// page; it is empty after the last one. TIDAL ignores offset here.
favorites_playlists :: proc(
	s: ^Session,
	limit := 50,
	offset := 0,
	order: Maybe(Playlist_Order) = nil,
	order_direction: Maybe(Order_Direction) = nil,
	cursor := "",
	allocator := context.allocator,
) -> (
	playlists: []Playlist,
	next_cursor: string,
	err: Error,
) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "folderId", "root")
	add_param(&params, "offset", offset)
	add_param(&params, "limit", limit)
	// Only PLAYLIST types; folders are left out
	add_param(&params, "includeOnly", "PLAYLIST")
	if cursor != "" {
		add_param(&params, "cursor", cursor)
	}
	o, has_order := order.?
	add_param(&params, "order", PLAYLIST_ORDER_NAMES[o] if has_order else PLAYLIST_ORDER_NAMES[.Date_Created])
	d, has_dir := order_direction.?
	add_param(&params, "orderDirection", ORDER_DIRECTION_NAMES[d] if has_dir else ORDER_DIRECTION_NAMES[.Descending])
	obj := request_object(s, {method = .GET, path = FOLDERS_ENDPOINT, base_url = s.config.api_v2_location, params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Playlist, parse_playlist), pstr(&p, obj, "cursor"), nil
}

// favorites_playlists_paginated follows the cursor until all favorite
// playlists are fetched.
favorites_playlists_paginated :: proc(
	s: ^Session,
	order: Maybe(Playlist_Order) = nil,
	order_direction: Maybe(Order_Direction) = nil,
	allocator := context.allocator,
) -> (
	playlists: []Playlist,
	err: Error,
) {
	scratch_begin(allocator)
	out := make([dynamic]Playlist, allocator)
	cursor := ""
	for {
		items, next := favorites_playlists(s, order = order, order_direction = order_direction, cursor = cursor, allocator = allocator) or_return
		append(&out, ..items)
		if next == "" || len(items) == 0 {
			break
		}
		cursor = next
	}
	return out[:], nil
}

// favorites_playlists_count returns the number of playlists in the root
// collection.
favorites_playlists_count :: proc(s: ^Session) -> (int, Error) {
	return total_items(s, FOLDERS_ENDPOINT, s.config.api_v2_location, {{"folderId", "root"}, {"includeOnly", ""}})
}

// favorites_playlist_folders returns the user's folders under a parent.
// Pass the returned cursor to get the next page.
favorites_playlist_folders :: proc(
	s: ^Session,
	limit := 50,
	offset := 0,
	order: Maybe(Playlist_Order) = nil,
	order_direction: Maybe(Order_Direction) = nil,
	parent_folder_id := "root",
	cursor := "",
	allocator := context.allocator,
) -> (
	folders: []Folder,
	next_cursor: string,
	err: Error,
) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "folderId", parent_folder_id)
	add_param(&params, "offset", offset)
	add_param(&params, "limit", limit)
	o, has_order := order.?
	add_param(&params, "order", PLAYLIST_ORDER_NAMES[o] if has_order else "NAME")
	add_param(&params, "includeOnly", "FOLDER")
	if cursor != "" {
		add_param(&params, "cursor", cursor)
	}
	if d, ok := order_direction.?; ok {
		add_param(&params, "orderDirection", ORDER_DIRECTION_NAMES[d])
	}
	obj := request_object(s, {method = .GET, path = FOLDERS_ENDPOINT, base_url = s.config.api_v2_location, params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Folder, parse_folder), pstr(&p, obj, "cursor"), nil
}

// favorites_mixes returns favorite mixes and radios (v2 endpoint).
favorites_mixes :: proc(s: ^Session, limit := 50, offset := 0, order: Maybe(Mix_Order) = nil, order_direction: Maybe(Order_Direction) = nil, allocator := context.allocator) -> (mixes: []Mix_V2, err: Error) {
	scratch_begin(allocator)
	params := list_params(limit, offset, order_name(MIX_ORDER_NAMES, order), order_direction)
	obj := request_object(s, {method = .GET, path = "favorites/mixes", base_url = s.config.api_v2_location, params = params}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Mix_V2, parse_mix_v2), nil
}
