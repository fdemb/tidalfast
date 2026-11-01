package tidal

import "core:encoding/json"
import "core:fmt"

// user_get fetches a user. Returns a Logged_In_User for the session's own
// user, a Fetched_User otherwise.
user_get :: proc(s: ^Session, user_id: i64, allocator := context.allocator) -> (user: User, err: Error) {
	scratch_begin(allocator)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("users/%d", user_id)}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return parse_user(&p, obj), nil
}

// user_image_url builds a profile picture URL. Valid sizes: 100, 210, 600.
user_image_url :: proc(s: ^Session, u: User, size: int, allocator := context.allocator) -> (url: string, err: Error) {
	switch size {
	case 100, 210, 600:
	case:
		return "", invalid_resolution(size, size)
	}
	if u.picture_id == "" {
		return "", make_error(.Asset_Not_Available, "No picture available")
	}
	return resource_url(s.config.image_url, u.picture_id, size, size, allocator), nil
}

// user_playlists returns the playlists the logged in user created.
user_playlists :: proc(s: ^Session, allocator := context.allocator) -> (playlists: []Playlist, err: Error) {
	scratch_begin(allocator)
	uid := logged_in_user_id(s) or_return
	obj := request_object(s, {method = .GET, path = fmt.tprintf("users/%d/playlists", uid)}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return map_items(&p, obj, Playlist, parse_playlist), nil
}

// user_public_playlists returns the logged in user's public playlists.
user_public_playlists :: proc(s: ^Session, offset := 0, limit := 50, allocator := context.allocator) -> (playlists: []Playlist, err: Error) {
	scratch_begin(allocator)
	uid := logged_in_user_id(s) or_return
	params := make_params()
	add_param(&params, "limit", limit)
	add_param(&params, "offset", offset)
	obj := request_object(
		s,
		{method = .GET, path = fmt.tprintf("user-playlists/%d/public", uid), base_url = s.config.api_v2_location, params = params[:]},
		context.temp_allocator,
	) or_return
	// The response also has followInfo and profile details; only playlists are kept.
	items, _ := jarr(obj, "items")
	p := parser_make(s, allocator)
	out := make([dynamic]Playlist, 0, len(items), allocator)
	for v in items {
		item := v.(json.Object) or_continue
		if pl, ok := jobj(item, "playlist"); ok && len(pl) > 0 {
			append(&out, parse_playlist(&p, pl))
		}
	}
	return out[:], nil
}

// user_playlist_and_favorite_playlists returns playlists the user created
// and the ones they favorited. TIDAL caps limit at 50. listed is how many
// items the page held, those skipped as broken included, and total is
// totalNumberOfItems, -1 if TIDAL didn't say.
user_playlist_and_favorite_playlists :: proc(s: ^Session, offset := 0, limit := 50, allocator := context.allocator) -> (playlists: []Playlist, listed, total: int, err: Error) {
	scratch_begin(allocator)
	uid := logged_in_user_id(s) or_return
	params := make_params()
	add_param(&params, "limit", limit)
	add_param(&params, "offset", offset)
	obj := request_object(s, {method = .GET, path = fmt.tprintf("users/%d/playlistsAndFavoritePlaylists", uid), params = params[:]}, context.temp_allocator) or_return
	items, _ := jarr(obj, "items")
	p := parser_make(s, allocator)
	out := make([dynamic]Playlist, 0, len(items), allocator)
	for v in items {
		item := v.(json.Object) or_continue
		pl := jobj(item, "playlist") or_continue
		p.date_added = item["created"]
		append(&out, parse_playlist(&p, pl))
		p.date_added = nil
	}
	return out[:], len(items), jint(obj, "totalNumberOfItems", -1), nil
}

// user_create_playlist creates a playlist in a folder ("root" by default).
user_create_playlist :: proc(s: ^Session, title: string, description: string, parent_id := "root", allocator := context.allocator) -> (playlist: Playlist, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "name", title)
	add_param(&params, "description", description)
	add_param(&params, "folderId", parent_id)
	obj := request_object(
		s,
		{method = .PUT, path = FOLDERS_ENDPOINT + "/create-playlist", base_url = s.config.api_v2_location, params = params[:]},
		context.temp_allocator,
	) or_return
	data, ok := jobj(obj, "data")
	if !ok || jstr(data, "uuid") == "" {
		return {}, make_error(.Object_Not_Found, "Playlist not found after creation")
	}
	p := parser_make(s, allocator)
	return parse_playlist(&p, data), nil
}

// user_create_folder creates a folder in a parent folder ("root" by default).
user_create_folder :: proc(s: ^Session, title: string, parent_id := "root", allocator := context.allocator) -> (folder: Folder, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "name", title)
	add_param(&params, "folderId", parent_id)
	obj := request_object(
		s,
		{method = .PUT, path = FOLDERS_ENDPOINT + "/create-folder", base_url = s.config.api_v2_location, params = params[:]},
		context.temp_allocator,
	) or_return
	if !jtruthy(obj["data"]) {
		return {}, make_error(.Object_Not_Found, "Folder not found after creation")
	}
	p := parser_make(s, allocator)
	return parse_folder(&p, obj), nil
}
