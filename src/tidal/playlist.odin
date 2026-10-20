package tidal

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"

// playlist_get fetches a playlist, including its ETag.
playlist_get :: proc(s: ^Session, playlist_id: string, allocator := context.allocator) -> (playlist: Playlist, err: Error) {
	scratch_begin(allocator)
	obj, resp, rerr := request_object_resp(s, {method = .GET, path = fmt.tprintf("playlists/%s", playlist_id)}, context.temp_allocator)
	if rerr != nil {
		return {}, remap_error(rerr, .Object_Not_Found, "Playlist not found", "Playlist unavailable")
	}
	p := parser_make(s, allocator)
	playlist = parse_playlist(&p, obj)
	playlist.etag = strings.clone(resp.etag, allocator)
	return playlist, nil
}

@(private)
total_items :: proc(s: ^Session, path: string, base_url := "", extra: []Param = nil) -> (count: int, err: Error) {
	scratch_begin(context.allocator)
	params := make_params()
	append(&params, ..extra)
	add_param(&params, "limit", 1)
	add_param(&params, "offset", 0)
	obj := request_object(s, {method = .GET, path = path, params = params[:], base_url = base_url}, context.temp_allocator) or_return
	return jint(obj, "totalNumberOfItems"), nil
}

// playlist_tracks_count returns the number of tracks with one small request.
playlist_tracks_count :: proc(s: ^Session, playlist_id: string) -> (int, Error) {
	return total_items(s, fmt.tprintf("playlists/%s/tracks", playlist_id))
}

// playlist_items_count returns the number of items (tracks and videos).
playlist_items_count :: proc(s: ^Session, playlist_id: string) -> (int, Error) {
	return total_items(s, fmt.tprintf("playlists/%s/items", playlist_id))
}

@(private)
add_order :: proc(params: ^[dynamic]Param, order: string, direction: Maybe(Order_Direction)) {
	if order != "" {
		add_param(params, "order", order)
	}
	if d, ok := direction.?; ok {
		add_param(params, "orderDirection", ORDER_DIRECTION_NAMES[d])
	}
}

@(private)
item_order_name :: proc(order: Maybe(Item_Order)) -> string {
	o, ok := order.?
	return ITEM_ORDER_NAMES[o] if ok else ""
}

// playlist_tracks returns a page of the playlist's tracks and how many
// tracks TIDAL says it has.
playlist_tracks :: proc(
	s: ^Session,
	playlist_id: string,
	limit: Maybe(int) = nil,
	offset := 0,
	order: Maybe(Item_Order) = nil,
	order_direction: Maybe(Order_Direction) = nil,
	allocator := context.allocator,
) -> (
	tracks: []Track,
	total: int,
	err: Error,
) {
	scratch_begin(allocator)
	params := make_params()
	if l, ok := limit.?; ok {
		add_param(&params, "limit", l)
	}
	add_param(&params, "offset", offset)
	add_order(&params, item_order_name(order), order_direction)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("playlists/%s/tracks", playlist_id), params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Track, parse_track_in_album), jint(obj, "totalNumberOfItems"), nil
}

// playlist_tracks_paginated fetches all tracks, 50 per request, two
// requests at a time.
playlist_tracks_paginated :: proc(
	s: ^Session,
	playlist_id: string,
	order: Maybe(Item_Order) = nil,
	order_direction: Maybe(Order_Direction) = nil,
	allocator := context.allocator,
) -> (
	tracks: []Track,
	err: Error,
) {
	scratch_begin(allocator)
	count := playlist_tracks_count(s, playlist_id) or_return
	params := make_params()
	add_order(&params, item_order_name(order), order_direction)
	r := Request {
		method = .GET,
		path   = fmt.tprintf("playlists/%s/tracks", playlist_id),
		params = params[:],
	}
	return paginate(s, r, count, Track, parse_track_in_album, allocator)
}

// playlist_items returns up to the first 100 tracks and videos.
playlist_items :: proc(
	s: ^Session,
	playlist_id: string,
	limit := 100,
	offset := 0,
	order: Maybe(Item_Order) = nil,
	order_direction: Maybe(Order_Direction) = nil,
	allocator := context.allocator,
) -> (
	items: []Media,
	err: Error,
) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "limit", limit)
	add_param(&params, "offset", offset)
	add_order(&params, item_order_name(order), order_direction)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("playlists/%s/items", playlist_id), params = params[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Media, parse_media_in_album), nil
}

// playlist_image_url builds a square picture URL. Valid sizes: 160, 320,
// 480, 640, 750, 1080. Without a square picture, falls back to the wide one
// when wide_fallback is set.
playlist_image_url :: proc(s: ^Session, pl: Playlist, size := 480, wide_fallback := true, allocator := context.allocator) -> (url: string, err: Error) {
	switch size {
	case 160, 320, 480, 640, 750, 1080:
	case:
		return "", invalid_resolution(size, size)
	}
	if pl.square_picture != "" {
		return resource_url(s.config.image_url, pl.square_picture, size, size, allocator), nil
	}
	if pl.picture != "" && wide_fallback {
		return playlist_wide_image_url(s, pl, allocator = allocator)
	}
	return "", make_error(.Asset_Not_Available, "No picture available")
}

// playlist_wide_image_url builds a wide picture URL. Valid sizes: 160x107,
// 480x320, 750x500, 1080x720.
playlist_wide_image_url :: proc(s: ^Session, pl: Playlist, width := 1080, height := 720, allocator := context.allocator) -> (url: string, err: Error) {
	if !valid_wide_size(width, height) {
		return "", invalid_resolution(width, height)
	}
	if pl.picture == "" {
		return "", make_error(.Asset_Not_Available, "No picture available")
	}
	return resource_url(s.config.image_url, pl.picture, width, height, allocator), nil
}

// ---- User playlists ----
//
// These change a playlist the logged in user owns. They send the playlist's
// ETag, then re-read it into `allocator` and overwrite *pl. Old field
// strings are not freed; keep playlists in an arena. If the change went
// through and only the re-read failed, they still succeed: *pl keeps its
// old fields and loses its ETag, so the next change reads it first.

// Tracks plus videos. Item indices and positions count both.
@(private = "file")
total_items_of :: proc(pl: ^Playlist) -> int {
	return pl.num_tracks + pl.num_videos
}

// Re-reads the playlist to get a fresh ETag.
@(private = "file")
reparse :: proc(s: ^Session, pl: ^Playlist, allocator: Allocator) -> Error {
	fresh := playlist_get(s, pl.id, allocator) or_return
	pl^ = fresh
	return nil
}

// reread is reparse after a change TIDAL took, which a failed read can't undo.
@(private = "file")
reread :: proc(s: ^Session, pl: ^Playlist, allocator: Allocator) {
	if reparse(s, pl, allocator) != nil {
		pl.etag = ""
	}
}

@(private = "file")
etag_headers :: proc(s: ^Session, pl: ^Playlist, allocator: Allocator) -> (headers: []string, err: Error) {
	if pl.etag == "" {
		reparse(s, pl, allocator) or_return
	}
	if pl.etag == "" {
		return nil, nil
	}
	return slice.clone([]string{fmt.tprintf("If-None-Match: %s", pl.etag)}, context.temp_allocator), nil
}

// user_playlist_edit sets the title and description. Empty values keep the
// current ones.
user_playlist_edit :: proc(s: ^Session, pl: ^Playlist, title := "", description := "", allocator := context.allocator) -> (err: Error) {
	scratch_begin(allocator)
	data := make_params()
	add_param(&data, "title", title if title != "" else pl.name)
	add_param(&data, "description", description if description != "" else pl.description)
	request(s, {method = .POST, path = fmt.tprintf("playlists/%s", pl.id), data = data[:]}, context.temp_allocator) or_return
	reread(s, pl, allocator)
	return nil
}

// user_playlist_add adds tracks by id and returns the ids that were added.
// position < 0 appends at the end.
user_playlist_add :: proc(
	s: ^Session,
	pl: ^Playlist,
	media_ids: []string,
	allow_duplicates := false,
	position := -1,
	limit := 100,
	allocator := context.allocator,
) -> (
	added: []i64,
	err: Error,
) {
	scratch_begin(allocator)
	if len(media_ids) == 0 {
		return nil, make_error(.Invalid_Argument, "An empty list was provided.")
	}
	headers := etag_headers(s, pl, allocator) or_return
	pos := position
	if pos < 0 || pos > total_items_of(pl) {
		pos = total_items_of(pl)
	}
	data := make_params()
	add_param(&data, "onArtifactNotFound", "SKIP")
	add_param(&data, "trackIds", join_ids(media_ids))
	add_param(&data, "toIndex", pos)
	add_param(&data, "onDupes", "ADD" if allow_duplicates else "SKIP")
	params := make_params()
	add_param(&params, "limit", limit)
	obj := request_object(
		s,
		{method = .POST, path = fmt.tprintf("playlists/%s/items", pl.id), params = params[:], data = data[:], headers = headers},
		context.temp_allocator,
	) or_return
	reread(s, pl, allocator)
	return added_item_ids(obj, allocator), nil
}

@(private = "file")
added_item_ids :: proc(obj: JSON_Object, allocator: Allocator) -> []i64 {
	arr, ok := jarr(obj, "addedItemIds")
	if !ok {
		return nil
	}
	out := make([]i64, len(arr), allocator)
	for v, i in arr {
		out[i] = value_i64(v)
	}
	return out
}

// user_playlist_merge adds the items of another playlist and returns the ids
// that were added.
user_playlist_merge :: proc(
	s: ^Session,
	pl: ^Playlist,
	from_playlist_id: string,
	allow_duplicates := false,
	allow_missing := true,
	allocator := context.allocator,
) -> (
	added: []i64,
	err: Error,
) {
	scratch_begin(allocator)
	headers := etag_headers(s, pl, allocator) or_return
	data := make_params()
	add_param(&data, "fromPlaylistUuid", from_playlist_id)
	add_param(&data, "onArtifactNotFound", "SKIP" if allow_missing else "FAIL")
	add_param(&data, "onDupes", "ADD" if allow_duplicates else "SKIP")
	obj := request_object(s, {method = .POST, path = fmt.tprintf("playlists/%s/items", pl.id), data = data[:], headers = headers}, context.temp_allocator) or_return
	reread(s, pl, allocator)
	return added_item_ids(obj, allocator), nil
}

// user_playlist_add_by_isrc adds the first track matching isrc. Returns
// false when no track matched or TIDAL did not add it.
user_playlist_add_by_isrc :: proc(
	s: ^Session,
	pl: ^Playlist,
	isrc: string,
	allow_duplicates := false,
	position := -1,
	allocator := context.allocator,
) -> (
	ok: bool,
	err: Error,
) {
	scratch_begin(allocator)
	track, terr := track_by_isrc(s, isrc, context.temp_allocator)
	if is_error(terr, .Object_Not_Found) {
		return false, nil
	}
	if terr != nil {
		return false, terr
	}
	track_id := track.id
	added := user_playlist_add(s, pl, {fmt.tprint(track_id)}, allow_duplicates, position, allocator = allocator) or_return
	return slice.contains(added, track_id), nil
}

// Media ids of every item (tracks and videos) in /items order, across all
// pages. Edits address items by this position.
@(private = "file")
playlist_item_ids :: proc(s: ^Session, playlist_id: string) -> (ids: []i64, err: Error) {
	count := playlist_items_count(s, playlist_id) or_return
	r := Request {
		method = .GET,
		path   = fmt.tprintf("playlists/%s/items", playlist_id),
	}
	bodies := fetch_pages(s, r, count) or_return
	defer free_bodies(bodies)
	scratch: vmem.Arena
	defer vmem.arena_destroy(&scratch)

	out := make([dynamic]i64, 0, count, context.temp_allocator)
	for _, i in bodies {
		obj := next_page_json(bodies, i, &scratch) or_return
		items, _ := jarr(obj, "items")
		for item in items {
			entry, _ := item.(json.Object)
			if inner, nested := jobj(entry, "item"); nested {
				entry = inner
			}
			append(&out, ji64(entry, "id", -1))
		}
	}
	return out[:], nil
}

// Positions of the items whose id is in media_ids.
@(private = "file")
item_indices :: proc(s: ^Session, pl: ^Playlist, media_ids: []string) -> (indices: []int, err: Error) {
	wanted := make([dynamic]i64, 0, len(media_ids), context.temp_allocator)
	for m in media_ids {
		if id, ok := strconv.parse_i64(strings.trim_space(m)); ok {
			append(&wanted, id)
		}
	}
	if len(wanted) == 0 {
		return nil, nil
	}
	ids := playlist_item_ids(s, pl.id) or_return
	out := make([dynamic]int, 0, len(wanted), context.temp_allocator)
	for id, i in ids {
		if slice.contains(wanted[:], id) {
			append(&out, i)
		}
	}
	return out[:], nil
}

// user_playlist_move_by_id moves the first item (track or video) with
// media_id to position. ok is false when the playlist has no such item.
user_playlist_move_by_id :: proc(s: ^Session, pl: ^Playlist, media_id: string, position: int, allocator := context.allocator) -> (ok: bool, err: Error) {
	scratch_begin(allocator)
	indices := item_indices(s, pl, {media_id}) or_return
	if len(indices) == 0 {
		return false, nil
	}
	user_playlist_move_by_indices(s, pl, indices[:1], position, allocator) or_return
	return true, nil
}

user_playlist_move_by_index :: proc(s: ^Session, pl: ^Playlist, index: int, position: int, allocator := context.allocator) -> Error {
	return user_playlist_move_by_indices(s, pl, {index}, position, allocator)
}

// user_playlist_move_by_indices moves items to position. An out of range
// position moves them to the end.
user_playlist_move_by_indices :: proc(s: ^Session, pl: ^Playlist, indices: []int, position: int, allocator := context.allocator) -> (err: Error) {
	scratch_begin(allocator)
	headers := etag_headers(s, pl, allocator) or_return
	pos := position
	if pos < 0 || pos >= total_items_of(pl) {
		pos = total_items_of(pl)
	}
	data := make_params()
	add_param(&data, "toIndex", pos)
	path := fmt.tprintf("playlists/%s/items/%s", pl.id, join_ints(indices))
	request(s, {method = .POST, path = path, data = data[:], headers = headers}, context.temp_allocator) or_return
	reread(s, pl, allocator)
	return nil
}

// user_playlist_remove_by_id removes the first item (track or video) with
// media_id. ok is false when the playlist has no such item.
user_playlist_remove_by_id :: proc(s: ^Session, pl: ^Playlist, media_id: string, allocator := context.allocator) -> (ok: bool, err: Error) {
	scratch_begin(allocator)
	indices := item_indices(s, pl, {media_id}) or_return
	if len(indices) == 0 {
		return false, nil
	}
	user_playlist_remove_by_indices(s, pl, indices[:1], allocator) or_return
	return true, nil
}

// user_playlist_delete_by_id removes every item whose id is in media_ids.
// Does nothing when none match.
user_playlist_delete_by_id :: proc(s: ^Session, pl: ^Playlist, media_ids: []string, allocator := context.allocator) -> (err: Error) {
	scratch_begin(allocator)
	if len(media_ids) == 0 {
		return make_error(.Invalid_Argument, "An empty list was provided.")
	}
	indices := item_indices(s, pl, media_ids) or_return
	if len(indices) == 0 {
		return nil
	}
	return user_playlist_remove_by_indices(s, pl, indices, allocator)
}

user_playlist_remove_by_index :: proc(s: ^Session, pl: ^Playlist, index: int, allocator := context.allocator) -> Error {
	return user_playlist_remove_by_indices(s, pl, {index}, allocator)
}

user_playlist_remove_by_indices :: proc(s: ^Session, pl: ^Playlist, indices: []int, allocator := context.allocator) -> (err: Error) {
	scratch_begin(allocator)
	headers := etag_headers(s, pl, allocator) or_return
	path := fmt.tprintf("playlists/%s/items/%s", pl.id, join_ints(indices))
	request(s, {method = .DELETE, path = path, headers = headers}, context.temp_allocator) or_return
	reread(s, pl, allocator)
	return nil
}

// user_playlist_clear removes all tracks and videos, chunk_size per request.
user_playlist_clear :: proc(s: ^Session, pl: ^Playlist, chunk_size := 50, allocator := context.allocator) -> (err: Error) {
	scratch_begin(allocator)
	// Start from the current counts, not whatever the caller last saw.
	reparse(s, pl, allocator) or_return
	for total_items_of(pl) > 0 {
		before := total_items_of(pl)
		n := min(before, max(chunk_size, 1))
		indices := make([]int, n, context.temp_allocator)
		for i in 0 ..< n {
			indices[i] = i
		}
		user_playlist_remove_by_indices(s, pl, indices, allocator) or_return
		if pl.etag == "" {
			reparse(s, pl, allocator) or_return
		}
		if total_items_of(pl) >= before {
			return make_error(.Bad_Response, "Playlist did not shrink after removing items")
		}
	}
	return nil
}

user_playlist_set_public :: proc(s: ^Session, pl: ^Playlist, allocator := context.allocator) -> (err: Error) {
	return set_visibility(s, pl, "set-public", allocator)
}

user_playlist_set_private :: proc(s: ^Session, pl: ^Playlist, allocator := context.allocator) -> (err: Error) {
	return set_visibility(s, pl, "set-private", allocator)
}

@(private = "file")
set_visibility :: proc(s: ^Session, pl: ^Playlist, action: string, allocator: Allocator) -> (err: Error) {
	scratch_begin(allocator)
	path := fmt.tprintf("playlists/%s/%s", pl.id, action)
	request(s, {method = .PUT, path = path, base_url = s.config.api_v2_location}, context.temp_allocator) or_return
	reread(s, pl, allocator)
	return nil
}

// user_playlist_delete deletes the playlist.
user_playlist_delete :: proc(s: ^Session, playlist_id: string) -> (err: Error) {
	scratch_begin(context.allocator)
	_, err = request(s, {method = .DELETE, path = fmt.tprintf("playlists/%s", playlist_id)}, context.temp_allocator)
	return
}

@(private)
join_ints :: proc(values: []int) -> string {
	parts := make([]string, len(values), context.temp_allocator)
	for v, i in values {
		parts[i] = fmt.tprint(v)
	}
	return join_ids(parts)
}

// ---- Folders ----

FOLDERS_ENDPOINT :: "my-collection/playlists/folders"

@(private = "file")
find_folder :: proc(s: ^Session, folder_id: string, parent_folder_id: string, allocator: Allocator) -> (folder: Folder, found: bool, err: Error) {
	params := make_params()
	add_param(&params, "folderId", parent_folder_id)
	add_param(&params, "offset", 0)
	add_param(&params, "limit", 50)
	add_param(&params, "order", "NAME")
	add_param(&params, "includeOnly", "FOLDER")
	obj := request_object(s, {method = .GET, path = FOLDERS_ENDPOINT, base_url = s.config.api_v2_location, params = params[:]}, context.temp_allocator) or_return
	items, _ := jarr(obj, "items")
	for v in items {
		item := v.(JSON_Object) or_continue
		data, _ := jobj(item, "data")
		if jstr(data, "id") == folder_id {
			p := parser_make(s, allocator)
			folder = parse_folder(&p, item)
			folder.parent_folder_id = strings.clone(parent_folder_id, allocator)
			return folder, true, nil
		}
	}
	return {}, false, nil
}

// folder_get looks the folder up among the first 50 folders of its parent.
folder_get :: proc(s: ^Session, folder_id: string, parent_folder_id := "root", allocator := context.allocator) -> (folder: Folder, err: Error) {
	scratch_begin(allocator)
	found: bool
	folder, found, err = find_folder(s, folder_id, parent_folder_id, allocator)
	if err != nil {
		return {}, remap_error(err, .Object_Not_Found, "Folder not found", "Folder unavailable")
	}
	if !found {
		return {}, make_error(.Object_Not_Found, "Folder not found")
	}
	return folder, nil
}

@(private = "file")
folder_reparse :: proc(s: ^Session, f: ^Folder, allocator: Allocator) -> Error {
	parent := f.parent_folder_id if f.parent_folder_id != "" else "root"
	fresh, found := find_folder(s, f.id, parent, allocator) or_return
	if found {
		f^ = fresh
	}
	return nil
}

folder_rename :: proc(s: ^Session, f: ^Folder, name: string, allocator := context.allocator) -> (err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "trn", f.trn)
	add_param(&params, "name", name)
	request(s, {method = .PUT, path = FOLDERS_ENDPOINT + "/rename", base_url = s.config.api_v2_location, params = params[:]}, context.temp_allocator) or_return
	_ = folder_reparse(s, f, allocator) // the change stands if this fails
	return nil
}

folder_remove :: proc(s: ^Session, f: Folder) -> (err: Error) {
	scratch_begin(context.allocator)
	params := make_params()
	add_param(&params, "trns", f.trn)
	_, err = request(s, {method = .PUT, path = FOLDERS_ENDPOINT + "/remove", base_url = s.config.api_v2_location, params = params[:]}, context.temp_allocator)
	return
}

// folder_items returns the playlists in a folder.
folder_items :: proc(s: ^Session, folder_id: string, offset := 0, limit := 50, allocator := context.allocator) -> (playlists: []Playlist, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "folderId", folder_id)
	add_param(&params, "offset", offset)
	add_param(&params, "limit", limit)
	add_param(&params, "order", "NAME")
	add_param(&params, "includeOnly", "PLAYLIST")
	obj := request_object(s, {method = .GET, path = FOLDERS_ENDPOINT, base_url = s.config.api_v2_location, params = params[:]}, context.temp_allocator) or_return
	// parse_playlist unwraps each item's "data".
	p := parser_make(s, allocator)
	return map_items(&p, obj, Playlist, parse_playlist), nil
}

// folder_add_items moves playlists (ids or trns) into the folder.
folder_add_items :: proc(s: ^Session, f: ^Folder, trns: []string, allocator := context.allocator) -> Error {
	return folder_move_items_to_folder(s, f, trns, f.id, allocator)
}

// folder_move_items_to_root moves playlists out of the folder to the root.
folder_move_items_to_root :: proc(s: ^Session, f: ^Folder, trns: []string, allocator := context.allocator) -> Error {
	return folder_move_items_to_folder(s, f, trns, "root", allocator)
}

// folder_move_items_to_folder moves playlists (ids or trns) to destination,
// or to f when destination is empty.
folder_move_items_to_folder :: proc(s: ^Session, f: ^Folder, trns: []string, destination := "", allocator := context.allocator) -> (err: Error) {
	scratch_begin(allocator)
	if len(trns) == 0 {
		return make_error(.Invalid_Argument, "An empty list was provided.")
	}
	params := make_params()
	add_param(&params, "folderId", destination if destination != "" else f.id)
	add_param(&params, "trns", join_ids(full_trns(trns, "playlist")))
	request(s, {method = .PUT, path = FOLDERS_ENDPOINT + "/move", base_url = s.config.api_v2_location, params = params[:]}, context.temp_allocator) or_return
	_ = folder_reparse(s, f, allocator) // the change stands if this fails
	return nil
}

// Prefixes bare ids with "trn:<kind>:".
@(private)
full_trns :: proc(ids: []string, kind: string) -> []string {
	out := make([]string, len(ids), context.temp_allocator)
	for id, i in ids {
		out[i] = id if strings.contains(id, "trn:") else fmt.tprintf("trn:%s:%s", kind, id)
	}
	return out
}
