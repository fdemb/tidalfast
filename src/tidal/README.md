# tidal

An unofficial TIDAL API client in Odin, package `tidal`. Its tests live in `tests/` at the repository root, and `examples/cli/` is a small CLI built on it.

It needs only Odin's core library and `vendor:curl`, which links the system libcurl on macOS and Linux.

## Using it from an app

```odin
import tidal "../tidal"

s := tidal.session_create(quality = .High_Lossless)
defer tidal.session_destroy(s)

if err := tidal.session_load_file(s, "session.json"); err != nil {
	link, _ := tidal.login_device_start(s)
	show_code(link.verification_uri_complete) // your UI
	// Another attempt number, set from any thread, stops the wait.
	tidal.session_set_login_attempt(s, attempt)
	tidal.login_device_wait(s, &link, attempt = attempt) or_return
	tidal.session_save_file(s, "session.json")
}

// One arena per view. Everything a call returns lives in its allocator.
results := tidal.search(s, "Beatles", {.Album, .Track}, allocator = view_arena) or_return
```

What a UI needs to know:

- **Data is plain structs.** `Track`, `Album`, `Playlist` and the rest have no methods and hold no session pointer. Operations are procs that take the session: `album_tracks(s, id)`, `track_stream(s, id)`, `user_playlist_add(s, &pl, ids)`.
- **Memory.** Every proc that returns data takes `allocator` and puts the whole result there, including nested strings and slices. Free the allocator, not individual fields. Scratch memory (HTTP bodies, JSON) comes from `context.temp_allocator` and is released before the proc returns, so don't pass `context.temp_allocator` as the result allocator.
- **Errors.** Procs return `tidal.Error`, a union that is nil on success, so `or_return` works. Check the kind with `error_kind(err)` or `is_error(err, .Object_Not_Found)`. Errors own no memory; `error_detail(&e)` reads the server's message from an inline buffer, and `e.sub_status` holds TIDAL's numeric `subStatus`. The detail is server text and may hold a signed URL, so it's for the screen only. For a log line use `error_summary(err)`: the kind, the HTTP status and the `subStatus`, and a codec only if `codec_name` knows it. The library's own `log` calls follow the same rule.
- **Threads.** Calls block on the network, so run them off the UI thread. A `Session` can be shared between threads: token refresh happens once even when several requests hit an expired token, and the rate-limit backoff state is shared. Each thread needs its own result allocator, or a thread-safe one.
- **Saved logins.** `session_auth` copies the login state out; `session_restore` puts it back without a request, so an app can keep it somewhere safe (TIDALfast uses the Keychain). Set `Session.on_auth_change` to hear about new tokens after a login or refresh. TIDAL may rotate the refresh token on refresh, so save every time it's called. It runs on the thread that refreshed, one call at a time.
- **Stopping.** `session_abort(s, true)` makes requests in flight and new ones fail with `.Cancelled`, and stops `login_device_wait`. To stop one wait and leave the session alone, pass the wait an `attempt` and call `session_set_login_attempt` with another number. Between polls the wait returns `.Cancelled` within 100 ms, and it drops tokens that a poll in flight gets after the change.
- **Signing out.** `session_clear_auth` forgets the tokens, session id and user. Requests, refreshes and device logins that started before it fail with `.Cancelled`, in flight or not, and a refresh that finishes anyway doesn't store its tokens. `Auth.epoch` and `session_epoch` say which login a copy of the state came from. `token_refresh` takes an `Auth` and refreshes only if the login it came from hasn't been cleared since, so a copy taken before a sign-out fails with `.Cancelled` instead of replacing the next login's tokens. `session_set_epoch` carries the epoch over to a session that replaces this one, and asserts that it doesn't go back.
- **Rate limits.** After a 429 or an anti-abuse 403 the session refuses every request with `.Backing_Off` until `Retry-After` has passed (60 s or 30 minutes without one). That covers the OAuth endpoints too: device login, polling and token refresh. A rate-limited refresh fails with `.Too_Many_Requests`, not `.Authentication`, so only TIDAL turning down the refresh token looks like a lost login. `backoff_state` and `backoff_restore` carry a running backoff over to a new session.
- **Refresh failures.** A refresh fails with `.Authentication` only when TIDAL answers 400 or 401 with the OAuth error `invalid_grant`. Every other failure, unreachable network included, is `.Refresh_Failed` and keeps the tokens, so the caller can try again later. Say a request's token had expired and its refresh failed that way. If TIDAL then answers the request with a 401 that doesn't mention the expiry, the request returns the `.Refresh_Failed` error, not the 401.
- **Polymorphic results** are unions: `Media` (track or video), `Item` (anything a page row or search top hit can hold), `Page_Category`, `Creator`.

## API overview

| Area | Procs |
| --- | --- |
| Session | `session_create`, `session_destroy`, `session_auth`, `session_restore`, `session_clear_auth`, `session_abort`, `session_set_login_attempt`, `backoff_remaining`, `backoff_state`, `backoff_restore`, `session_user`, `session_set_quality`, `session_client_enable_hires`, `check_login` |
| Login | `login_device_start`, `login_device_wait`, `login_oauth_simple`, `pkce_login_url`, `login_pkce_complete`, `login_pkce`, `load_oauth_session`, `load_session`, `token_refresh` |
| Session file | `login_session_file`, `session_save_file`, `session_load_file` |
| Tracks and videos | `track_get`, `track_stream`, `track_url`, `track_lyrics`, `track_radio`, `track_radio_mix`, `video_get`, `video_url` |
| Streams | `stream_get_manifest`, `manifest_hls`, `stream_manifest_data` |
| Albums and artists | `album_get`, `album_tracks`, `album_items`, `album_similar`, `album_review`, `artist_get`, `artist_albums`, `artist_top_tracks`, `artist_radio`, ... |
| Playlists and folders | `playlist_get`, `playlist_tracks`, `playlist_tracks_paginated`, `user_playlist_add`, `user_playlist_remove_by_indices`, `folder_get`, `folder_items`, ... |
| User and favorites | `user_get`, `user_playlists`, `user_create_playlist`, `favorites_tracks`, `favorites_tracks_paginated`, `favorites_add_track`, ... |
| Browsing | `search`, `home`, `explore`, `page_get`, `page_link_get`, `page_flatten`, `mix_get`, `genres_get`, `tracks_by_isrc`, `track_by_isrc`, `albums_by_barcode` |

`examples/cli/main.odin` shows most of these in use.

## Behavior worth knowing

- Missing JSON fields give zero values; a response with missing fields still parses.
- Unknown page module types are skipped, so new TIDAL modules don't break a page.
- A playlist the logged in user created has `is_user_playlist = true`. The `user_playlist_*` procs fetch its ETag on the first edit and re-read it after each change.
- Playlist edits address positions in the full item list, tracks and videos together. The `*_by_id` procs read every page of that list before deciding an id is missing.
- `*_paginated` procs fetch 50 items per request on two threads. If any request fails, the whole call fails.
- Session files are JSON, written to a new 0600 file and renamed into place, so an existing file's permissions never apply. A session logged in by session id alone restores through `load_session`.
- Requests time out after `config.timeout_seconds` (30 by default).
- `login_device_wait` takes the link by pointer. It waits `link.interval` seconds between polls and adds 5 to it when TIDAL answers `slow_down`, so a caller that polls again after a network error keeps the slower pace. It returns `.Timeout` when the code expired, `.Authentication` when the user denied it, and a rate limit or a transport error as soon as one happens.
- `resource_get` downloads a file outside the API, such as a cover from `resources.tidal.com`, under the same backoff as API requests. It sends no token and never refreshes or clears one, so its errors, a 401 included, say nothing about the login.
- Every endpoint, the device authorization one included (`config.api_device_auth`), comes from `Config`, so tests and the app's mock mode can point a session elsewhere.
- A query string in a request path is merged with the default parameters; the path's values win over defaults, and `Request.params` win over both.
- `Dash_Info` keeps the initialization segment (`init_url`) apart from the media `segments`, each with its own duration. `urls` lists both in download order. `manifest_hls` puts the initialization segment in `EXT-X-MAP`.

## Tests

```
odin test tests
odin build examples/cli -out:build/tidal-cli
```

The tests parse TIDAL-shaped JSON, DASH and BTS manifests, and check the PKCE challenge, client IDs and HLS output against known values. Playlist edits, query merging, session files, the rate-limit backoff and token refresh run against a mock HTTP server in `tests/mock_server.odin`. Nothing in them needs a TIDAL account.
