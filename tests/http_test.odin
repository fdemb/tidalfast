package tidal_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import tidal "../src/tidal"

// A session pointed at the mock, logged in with OAuth tokens.
@(private = "file")
mock_session :: proc(t: ^testing.T, m: ^Mock, login := true) -> ^tidal.Session {
	s := tidal.session_create()
	s.config.api_v1_location = m.base_url
	s.config.api_v2_location = m.base_url
	s.config.api_oauth2_token = "http://127.0.0.1:1/token" // must never be called
	if login {
		err := tidal.load_oauth_session(s, "Bearer", "access", "refresh", time.time_add(time.now(), time.Hour))
		testing.expect_value(t, err, nil)
	}
	return s
}

@(test)
remove_by_id_addresses_items_not_tracks :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m, {{"track", 11}, {"video", 99}, {"track", 22}})
	defer mock_stop(&m)
	s := mock_session(t, &m)
	defer tidal.session_destroy(s)

	pl := tidal.Playlist {
		id         = "pl",
		num_tracks = 2,
		num_videos = 1,
		etag       = "etag",
	}
	ok, err := tidal.user_playlist_remove_by_id(s, &pl, "22", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, ok)
	testing.expect_value(t, mock_count(&m, "DELETE /playlists/pl/items/2?"), 1)
	ids := mock_item_ids(&m, context.temp_allocator)
	testing.expect(t, slice.equal(ids, []i64{11, 99}), fmt.tprint(ids))

	missing, merr := tidal.user_playlist_remove_by_id(s, &pl, "12345", context.temp_allocator)
	testing.expect_value(t, merr, nil)
	testing.expect(t, !missing)
}

@(test)
remove_by_id_searches_every_page :: proc(t: ^testing.T) {
	items := make([]Mock_Item, 150, context.temp_allocator)
	for &it, i in items {
		it = {"track", i64(i + 1)}
	}
	m: Mock
	mock_start(&m, items)
	defer mock_stop(&m)
	s := mock_session(t, &m)
	defer tidal.session_destroy(s)
	s.config.item_limit = 1

	pl := tidal.Playlist {
		id         = "pl",
		num_tracks = 150,
		etag       = "etag",
	}
	ok, err := tidal.user_playlist_remove_by_id(s, &pl, "140", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, ok)
	testing.expect_value(t, mock_count(&m, "DELETE /playlists/pl/items/139?"), 1)
	testing.expect_value(t, pl.num_tracks, 149)
}

@(test)
delete_by_id_removes_tracks_and_videos :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m, {{"track", 11}, {"video", 99}, {"track", 22}, {"track", 33}})
	defer mock_stop(&m)
	s := mock_session(t, &m)
	defer tidal.session_destroy(s)

	pl := tidal.Playlist {
		id   = "pl",
		etag = "etag",
	}
	err := tidal.user_playlist_delete_by_id(s, &pl, {"99", "33"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, mock_count(&m, "DELETE /playlists/pl/items/1,3?"), 1)
	ids := mock_item_ids(&m, context.temp_allocator)
	testing.expect(t, slice.equal(ids, []i64{11, 22}), fmt.tprint(ids))
}

@(test)
clear_removes_videos_too :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m, {{"video", 5}, {"video", 6}, {"track", 7}})
	defer mock_stop(&m)
	s := mock_session(t, &m)
	defer tidal.session_destroy(s)

	// Stale counts from the caller: clear must not trust them.
	pl := tidal.Playlist {
		id   = "pl",
		etag = "etag",
	}
	err := tidal.user_playlist_clear(s, &pl, chunk_size = 2, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(mock_item_ids(&m, context.temp_allocator)), 0)
	testing.expect_value(t, pl.num_tracks + pl.num_videos, 0)
}

@(test)
clear_stops_when_nothing_is_removed :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m, {{"video", 5}})
	defer mock_stop(&m)
	m.stuck = true
	s := mock_session(t, &m)
	defer tidal.session_destroy(s)

	pl := tidal.Playlist {
		id   = "pl",
		etag = "etag",
	}
	err := tidal.user_playlist_clear(s, &pl, allocator = context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Bad_Response))
	testing.expect_value(t, mock_count(&m, "DELETE"), 1)
}

@(test)
path_query_is_merged :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_session(t, &m)
	defer tidal.session_destroy(s)

	_, err := tidal.request(s, {method = .GET, path = "echo?albumId=42&limit=5&q=a+b%26c"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.last_query["albumId"], "42")
	testing.expect_value(t, m.last_query["limit"], "5") // the path beats the default
	testing.expect_value(t, m.last_query["q"], "a b&c")
	testing.expect_value(t, m.last_query["sessionId"], "00000000-0000-0000-0000-000000000001")

	_, err = tidal.request(s, {method = .GET, path = "echo?limit=5", params = {{"limit", "7"}}}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.last_query["limit"], "7") // explicit params beat the path
	testing.expect_value(t, mock_count(&m, "GET /echo?limit=5?"), 0)
}

// temp_base is TMPDIR, which Linux usually leaves unset, or /tmp.
temp_base :: proc() -> string {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	return strings.trim_suffix(base, "/")
}

@(private = "file")
temp_dir :: proc(t: ^testing.T) -> string {
	dir := fmt.tprintf("%s/tidalfast-test-%d", temp_base(), time.time_to_unix_nano(time.now()))
	testing.expect_value(t, os.make_directory(dir), nil)
	return dir
}

@(test)
session_file_is_private_even_when_overwriting :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_session(t, &m)
	defer tidal.session_destroy(s)

	dir := temp_dir(t)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/session.json", dir)
	testing.expect_value(t, os.write_entire_file(path, "old", {.Read_User, .Write_User, .Read_Group, .Read_Other}), nil)

	testing.expect_value(t, tidal.session_save_file(s, path), nil)

	info, serr := os.stat(path, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, info.mode & {.Read_Group, .Write_Group, .Read_Other, .Write_Other}, os.Permissions{})
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"access_token": {"data": "access"}`), string(data))

	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect_value(t, len(entries), 1) // no temp file left behind
}

@(test)
session_id_login_round_trips :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := mock_session(t, &m, login = false)
	defer tidal.session_destroy(s)

	testing.expect_value(t, tidal.load_session(s, "00000000-0000-0000-0000-000000000001", "PL", 123), nil)
	dir := temp_dir(t)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/session.json", dir)
	testing.expect_value(t, tidal.session_save_file(s, path), nil)

	restored := mock_session(t, &m, login = false)
	defer tidal.session_destroy(restored)
	testing.expect_value(t, tidal.session_load_file(restored, path), nil)
	testing.expect(t, tidal.check_login(restored))
	user, ok := tidal.session_user(restored, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, user.id, 123)
}
