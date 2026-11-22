package tidal_tests

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// A one-connection-at-a-time HTTP server on 127.0.0.1 standing in for TIDAL.
// It models one playlist's items, adding tracks to it and liking tracks,
// playlists the user makes, renames and deletes, whose items take the same
// adds, lists and removals as that one's, the session endpoints, an
// echo endpoint, a rate-limited endpoint, a slow one, token refresh, the
// device login and the parts of an artist page, and records every request
// line.

// Mock_Playlist is a playlist made with create-playlist. Its strings are
// the mock's.
Mock_Playlist :: struct {
	id:    string,
	name:  string,
	items: [dynamic]Mock_Item, // as the playlist pl's, see mock_items_route
}

// A "gone" item is a track TIDAL can't play: counted, but left out of the
// pages, as TIDAL does.
Mock_Item :: struct {
	kind: string, // "track", "video" or "gone"
	id:   i64,
}

// A redirect's body (301, 302, 303, 307 or 308) is its Location.
Mock_Answer :: struct {
	status: int,
	body:   string,
}

Mock_Request :: struct {
	method:     string,
	path:       string,
	query:      map[string]string,
	form:       map[string]string, // the body, decoded
	etag:       string, // If-None-Match
	authorized: bool,
}

Mock :: struct {
	socket:     net.TCP_Socket,
	base_url:   string,
	thread:     ^thread.Thread,
	stopping:   bool,

	mutex:      sync.Mutex,
	items:      [dynamic]Mock_Item,
	liked:      [dynamic]i64, // tracks liked by a POST, newest first, on top of the MOCK_LIKED
	// Tracks of the MOCK_LIKED range unliked with a DELETE; a POST likes
	// one back where it was. Tracks liked by a POST go off liked itself,
	// since they were listed on top of it.
	liked_removed: [dynamic]i64,
	followed:      [dynamic]i64, // artists followed by a POST, oldest first
	// Playlists made by create-playlist, newest first, which
	// playlistsAndFavoritePlaylists lists, POST /playlists/<id> renames and
	// DELETE /playlists/<id> deletes.
	playlists:     [dynamic]Mock_Playlist,
	made:          int, // playlists made, which names the next one's id
	// Stuck accepts DELETEs without removing anything.
	stuck:         bool,
	requests:   [dynamic]string, // "METHOD /path?query"
	refreshes:  int, // POSTs to /token
	last_query: map[string]string,
	// Non-zero: /token and /device answer with this status (429 asks for
	// one second).
	token_status:  int,
	device_status: int,
	token_error:   string, // the OAuth error with token_status
	token_delay:   time.Duration, // before /token answers
	oauth_delay:   time.Duration, // before /oauth2/token answers
	sessions_fail: int, // /sessions answers this many requests with a 503
	sessions_status: int, // or with this status, if set
	// After a POST adds to the playlist, this many GETs of it answer 429.
	add_then_limit: int,
	limit_left:     int,
	// /device_token, and /oauth2/token for an app session, answers poll i
	// with polls[i]: "pending", "slow_down", "denied", "429" or "ok"; past
	// the end, "pending". poll_times has when each poll arrived.
	polls:      []string,
	poll_count: int,
	poll_times: [dynamic]time.Tick,
	// Paths answered with these bytes, as audio files or DASH segments.
	files:      map[string][]u8,
	token_form: map[string]string, // the last POST to /token or /oauth2/token, decoded
	// playbackinfopostpaywall's answer for each audioquality; 404 for others.
	playback:   map[string]Mock_Answer,
	// Paths answered with these instead of their route, such as a failure.
	// A key with ?offset=n answers only that page, before its path's.
	// A request with a filter is looked up as "path?filter=value".
	answers:    map[string]Mock_Answer,

	allocator:  runtime.Allocator,
}

mock_start :: proc(m: ^Mock, items: []Mock_Item = nil) {
	m.allocator = runtime.heap_allocator()
	m.items = make([dynamic]Mock_Item, m.allocator)
	m.liked = make([dynamic]i64, m.allocator)
	m.liked_removed = make([dynamic]i64, m.allocator)
	m.followed = make([dynamic]i64, m.allocator)
	m.playlists = make([dynamic]Mock_Playlist, m.allocator)
	m.requests = make([dynamic]string, m.allocator)
	m.poll_times = make([dynamic]time.Tick, m.allocator)
	m.files = make(map[string][]u8, m.allocator)
	m.token_form = make(map[string]string, m.allocator)
	m.playback = make(map[string]Mock_Answer, m.allocator)
	m.answers = make(map[string]Mock_Answer, m.allocator)
	append(&m.items, ..items)

	sock, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	assert(err == nil, "mock: listen failed")
	m.socket = sock
	ep, _ := net.bound_endpoint(sock)
	m.base_url = fmt.aprintf("http://127.0.0.1:%d/", ep.port, allocator = m.allocator)
	m.thread = thread.create_and_start_with_poly_data(m, mock_serve)
}

mock_stop :: proc(m: ^Mock) {
	sync.atomic_store(&m.stopping, true)
	// Wake accept() with a throwaway connection.
	if c, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = mock_port(m)}); err == nil {
		net.close(c)
	}
	thread.join(m.thread)
	thread.destroy(m.thread)
	net.close(m.socket)
	for r in m.requests {
		delete(r, m.allocator)
	}
	delete(m.requests)
	delete(m.items)
	delete(m.liked)
	delete(m.followed)
	for p in m.playlists {
		delete(p.id, m.allocator)
		delete(p.name, m.allocator)
		delete(p.items)
	}
	delete(m.playlists)
	delete(m.poll_times)
	clear_query(&m.last_query, m.allocator)
	delete(m.last_query)
	clear_query(&m.token_form, m.allocator)
	delete(m.token_form)
	delete(m.files)
	delete(m.playback)
	delete(m.answers)
	delete(m.base_url, m.allocator)
}

// mock_set_items replaces the playlist's items, as an edit elsewhere would.
mock_set_items :: proc(m: ^Mock, items: []Mock_Item) {
	sync.guard(&m.mutex)
	clear(&m.items)
	append(&m.items, ..items)
}

@(private = "file")
mock_port :: proc(m: ^Mock) -> int {
	ep, _ := net.bound_endpoint(m.socket)
	return ep.port
}

mock_item_ids :: proc(m: ^Mock, allocator := context.allocator) -> []i64 {
	sync.guard(&m.mutex)
	out := make([]i64, len(m.items), allocator)
	for it, i in m.items {
		out[i] = it.id
	}
	return out
}

// Number of recorded requests whose line starts with prefix.
mock_count :: proc(m: ^Mock, prefix: string) -> int {
	sync.guard(&m.mutex)
	n := 0
	for r in m.requests {
		if strings.has_prefix(r, prefix) {
			n += 1
		}
	}
	return n
}

@(private = "file")
clear_query :: proc(q: ^map[string]string, allocator: runtime.Allocator) {
	for k, v in q {
		delete(k, allocator)
		delete(v, allocator)
	}
	clear(q)
}

@(private = "file")
mock_serve :: proc(m: ^Mock) {
	context.allocator = m.allocator
	for !sync.atomic_load(&m.stopping) {
		client, _, err := net.accept_tcp(m.socket)
		if err != nil {
			continue
		}
		if !sync.atomic_load(&m.stopping) {
			mock_handle(m, client)
		}
		net.close(client)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
mock_handle :: proc(m: ^Mock, client: net.TCP_Socket) {
	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	chunk: [4096]u8
	header_end := -1
	for header_end < 0 {
		n, rerr := net.recv_tcp(client, chunk[:])
		if rerr != nil || n == 0 {
			return
		}
		append(&buf, ..chunk[:n])
		header_end = strings.index(string(buf[:]), "\r\n\r\n")
	}
	head := string(buf[:header_end])
	content_length := 0
	authorized := false
	etag: string
	lines := strings.split(head, "\r\n", context.temp_allocator)
	for line in lines[1:] {
		name, _, value := strings.partition(line, ":")
		value = strings.trim_space(value)
		if strings.equal_fold(name, "content-length") {
			content_length, _ = strconv.parse_int(value)
		} else if strings.equal_fold(name, "authorization") {
			authorized = true
		} else if strings.equal_fold(name, "if-none-match") {
			etag = value
		}
	}
	for len(buf) < header_end + 4 + content_length {
		n, rerr := net.recv_tcp(client, chunk[:])
		if rerr != nil || n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
	}

	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) < 2 {
		return
	}
	req := Mock_Request {
		method     = parts[0],
		etag       = etag,
		authorized = authorized,
	}
	target := parts[1]
	path, _, query := strings.partition(target, "?")
	req.path = path
	req.query = make(map[string]string, 8, context.temp_allocator)
	rest := query
	for pair in strings.split_iterator(&rest, "&") {
		k, _, v := strings.partition(pair, "=")
		dk, _ := net.percent_decode(k, context.temp_allocator)
		dv, _ := net.percent_decode(v, context.temp_allocator)
		req.query[dk] = dv
	}
	req.form = make(map[string]string, 8, context.temp_allocator)
	form := string(buf[header_end + 4:])
	for pair in strings.split_iterator(&form, "&") {
		k, _, v := strings.partition(pair, "=")
		plus, _ := strings.replace_all(v, "+", " ", context.temp_allocator)
		dk, _ := net.percent_decode(k, context.temp_allocator)
		dv, _ := net.percent_decode(plus, context.temp_allocator)
		req.form[dk] = dv
	}

	if req.path == "/token" || req.path == "/oauth2/token" {
		sync.guard(&m.mutex)
		clear_query(&m.token_form, m.allocator)
		for k, v in req.form {
			m.token_form[strings.clone(k, m.allocator)] = strings.clone(v, m.allocator)
		}
	}
	status, body, out_etag := mock_route(m, req, target)
	// A 429 always asks for one second.
	extra := "Retry-After: 1\r\n" if status == 429 else ""
	switch status {
	case 301, 302, 303, 307, 308:
		extra = fmt.tprintf("Location: %s\r\n", body)
		body = ""
	}
	resp := fmt.tprintf(
		"HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nETag: %s\r\n%sConnection: close\r\n\r\n%s",
		status,
		len(body),
		out_etag,
		extra,
		body,
	)
	data := transmute([]u8)resp
	for len(data) > 0 {
		n, serr := net.send_tcp(client, data)
		if serr != nil {
			return
		}
		data = data[n:]
	}
}

@(private = "file")
mock_route :: proc(m: ^Mock, req: Mock_Request, target: string) -> (status: int, body: string, etag: string) {
	sync.guard(&m.mutex)
	append(&m.requests, fmt.aprintf("%s %s", req.method, target))
	clear_query(&m.last_query, m.allocator)
	for k, v in req.query {
		m.last_query[strings.clone(k)] = strings.clone(v)
	}

	etag = fmt.tprintf("etag-%d", len(m.items))
	if data, ok := m.files[req.path]; ok {
		return 200, string(data), etag
	}
	answer_key := req.path
	if filter, ok := req.query["filter"]; ok {
		answer_key = fmt.tprintf("%s?filter=%s", req.path, filter)
	}
	if offset, ok := req.query["offset"]; ok {
		if a, found := m.answers[fmt.tprintf("%s?offset=%s", req.path, offset)]; found {
			return a.status, a.body, etag
		}
	}
	if a, ok := m.answers[answer_key]; ok {
		return a.status, a.body, etag
	}

	if strings.has_suffix(req.path, "/playbackinfopostpaywall") {
		a, ok := m.playback[req.query["audioquality"] or_else ""]
		if !ok {
			return 404, `{"status":404,"userMessage":"not found"}`, etag
		}
		return a.status, a.body, etag
	}

	if m.limit_left > 0 && req.method == "GET" && strings.has_prefix(req.path, "/playlists/pl") {
		m.limit_left -= 1
		return 429, `{"userMessage":"Too many requests"}`, etag
	}

	switch {
	case req.path == "/sessions":
		if m.sessions_fail > 0 {
			m.sessions_fail -= 1
			return m.sessions_status if m.sessions_status != 0 else 503, `{"userMessage":"unavailable"}`, etag
		}
		if !req.authorized && "sessionId" not_in req.query {
			return 401, `{"userMessage":"unauthorized"}`, etag
		}
		return 200, `{"sessionId":"00000000-0000-0000-0000-000000000001","countryCode":"PL","userId":123}`, etag
	case req.path == "/users/123":
		return 200, `{"id":123,"username":"user","firstName":"F","lastName":"L","email":"u@example.com"}`, etag
	case req.path == "/users/123/subscription":
		return 200, `{}`, etag
	case req.path == "/users/123/favorites/tracks" && req.method == "POST":
		id, _ := strconv.parse_i64(req.form["trackId"] or_else "")
		if id >= 1 && id <= MOCK_LIKED {
			if at := removed_at(m, id); at >= 0 {
				// Liked again after a DELETE took it off: it's back where
				// it was among the MOCK_LIKED, not on top.
				ordered_remove(&m.liked_removed, at)
				return 200, `{}`, etag
			}
		}
		liked := id >= 1 && id <= MOCK_LIKED
		for l in m.liked {
			liked ||= l == id
		}
		if !liked {
			inject_at(&m.liked, 0, id)
		}
		return 200, `{}`, etag
	case strings.has_prefix(req.path, "/users/123/favorites/tracks/") && req.method == "DELETE":
		id, _ := strconv.parse_i64(strings.trim_prefix(req.path, "/users/123/favorites/tracks/"))
		if at := liked_at(m, id); at >= 0 {
			// Liked on top by a POST: off the list, not recorded.
			ordered_remove(&m.liked, at)
		} else if id >= 1 && id <= MOCK_LIKED {
			if removed_at(m, id) < 0 {
				append(&m.liked_removed, id)
			}
		}
		return 200, `{}`, etag
	case req.path == "/users/123/favorites/artists" && req.method == "POST":
		for id_s in strings.split(req.form["artistId"] or_else "", ",", context.temp_allocator) {
			if id, ok := strconv.parse_i64(id_s); ok && !slice.contains(m.followed[:], id) {
				append(&m.followed, id)
			}
		}
		return 200, `{}`, etag
	case strings.has_prefix(req.path, "/users/123/favorites/artists/") && req.method == "DELETE":
		id, _ := strconv.parse_i64(strings.trim_prefix(req.path, "/users/123/favorites/artists/"))
		if at, found := slice.linear_search(m.followed[:], id); found {
			ordered_remove(&m.followed, at)
		}
		return 200, `{}`, etag
	case req.path == "/v2/my-collection/playlists/folders/create-playlist" && req.method == "PUT":
		m.made += 1
		made := Mock_Playlist{fmt.aprintf("made-%d", m.made, allocator = m.allocator), strings.clone(req.query["name"] or_else "", m.allocator), make([dynamic]Mock_Item, m.allocator)}
		inject_at(&m.playlists, 0, made)
		return 200, fmt.tprintf(`{{"trn":"trn:playlist:%s","itemType":"PLAYLIST","addedAt":"2026-03-01T10:00:00.000+0000","parent":null,"data":%s}}`, made.id, mock_playlist_json(made)), etag
	case req.path == "/users/123/playlistsAndFavoritePlaylists":
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"limit":50,"offset":0,"totalNumberOfItems":%d,"items":[`, len(m.playlists))
		for p, i in m.playlists {
			fmt.sbprintf(&b, `%s{{"type":"USER_CREATED","created":"2026-03-01T10:00:00.000+0000","playlist":%s}}`, "," if i > 0 else "", mock_playlist_json(p))
		}
		strings.write_string(&b, "]}")
		return 200, strings.to_string(b), etag
	case strings.has_prefix(req.path, "/playlists/made-"):
		id, _, rest := strings.partition(strings.trim_prefix(req.path, "/playlists/"), "/")
		at := -1
		for p, i in m.playlists {
			if p.id == id {
				at = i
			}
		}
		if at < 0 {
			return 404, `{"status":404,"userMessage":"Playlist not found"}`, etag
		}
		made := &m.playlists[at]
		made_etag := fmt.tprintf("etag-%s-%d", made.id, len(made.items))
		switch {
		case rest != "":
			if st, b, ok := mock_items_route(m, req, &made.items, fmt.tprintf("/%s", rest), made_etag); ok {
				return st, b, made_etag
			}
		case req.method == "DELETE":
			delete(m.playlists[at].id, m.allocator)
			delete(m.playlists[at].name, m.allocator)
			delete(m.playlists[at].items)
			ordered_remove(&m.playlists, at)
			return 200, ``, etag
		case req.method == "POST":
			if title, ok := req.form["title"]; ok {
				delete(m.playlists[at].name, m.allocator)
				m.playlists[at].name = strings.clone(title, m.allocator)
			}
			return 200, ``, etag
		case:
			return 200, mock_playlist_json(m.playlists[at]), made_etag
		}
	case req.path == "/users/123/favorites/ids":
		return 200, mock_liked_ids(m.liked[:], m.liked_removed[:], m.followed[:]), etag
	case req.path == "/users/123/favorites/tracks":
		return 200, mock_liked_page(req.query["offset"] or_else "0", req.query["limit"] or_else "50", m.liked[:], m.liked_removed[:]), etag
	case req.path == "/echo":
		return 200, `{}`, etag
	case req.path == "/refused":
		return 401, `{"status":401,"subStatus":11002,"userMessage":"Session is not valid"}`, etag
	case req.path == "/limited":
		return 429, `{"userMessage":"Too many requests"}`, etag
	case req.path == "/slow":
		sync.mutex_unlock(&m.mutex)
		time.sleep(2 * time.Second)
		sync.mutex_lock(&m.mutex)
		return 200, `{}`, etag
	case req.path == "/device":
		if m.device_status != 0 {
			return m.device_status, `{"userMessage":"no"}`, etag
		}
		return 200, `{"deviceCode":"dc","userCode":"UC","verificationUri":"link","verificationUriComplete":"link/UC","expiresIn":300,"interval":1}`, etag
	case strings.has_prefix(req.path, "/images/"):
		// Covers carry no token. A 401 here mustn't end the login.
		return 401, `{"status":401,"subStatus":11003,"userMessage":"unauthorized"}`, etag
	case req.path == "/device_token" || req.path == "/oauth2/token":
		if req.path == "/oauth2/token" && m.oauth_delay > 0 {
			sync.mutex_unlock(&m.mutex)
			time.sleep(m.oauth_delay)
			sync.mutex_lock(&m.mutex)
		}
		poll := m.polls[m.poll_count] if m.poll_count < len(m.polls) else "pending"
		m.poll_count += 1
		append(&m.poll_times, time.tick_now())
		switch poll {
		case "slow_down":
			return 400, `{"status":400,"error":"slow_down"}`, etag
		case "denied":
			return 400, `{"status":400,"error":"access_denied"}`, etag
		case "429":
			return 429, `{"userMessage":"Too many requests"}`, etag
		case "503":
			return 503, `{"status":503,"error":"temporarily_unavailable"}`, etag
		case "ok":
			return 200, `{"access_token":"device-access","refresh_token":"device-refresh","token_type":"Bearer","expires_in":3600}`, etag
		}
		return 400, `{"status":400,"error":"authorization_pending"}`, etag
	case req.path == "/token":
		if m.token_delay > 0 {
			sync.mutex_unlock(&m.mutex)
			time.sleep(m.token_delay)
			sync.mutex_lock(&m.mutex)
		}
		if m.token_status != 0 {
			return m.token_status, fmt.tprintf(`{{"status":%d,"error":"%s"}}`, m.token_status, m.token_error), etag
		}
		// A refresh that rotates the refresh token, as TIDAL may.
		m.refreshes += 1
		return 200, fmt.tprintf(`{{"access_token":"access-%d","refresh_token":"refresh-%d","token_type":"Bearer","expires_in":3600}}`, m.refreshes, m.refreshes), etag
	case req.path == "/playlists/pl" || strings.has_prefix(req.path, "/playlists/pl/"):
		ok: bool
		if status, body, ok = mock_items_route(m, req, &m.items, strings.trim_prefix(req.path, "/playlists/pl"), etag); ok {
			if status == 200 && req.method == "POST" {
				m.limit_left = m.add_then_limit
			}
			return status, body, etag
		}
	case req.path == "/search":
		// Every search finds artist 7 and one of its songs.
		return 200, `{"artists":{"items":[{"id":7,"name":"Artist 7","picture":"pic-7"}]},"tracks":{"items":[{"id":700,"title":"Top 1 of Artist 7","duration":200,"artist":{"id":7,"name":"Artist 7"},"artists":[{"id":7,"name":"Artist 7"}],"album":{"id":7000,"title":"Album 7000","cover":"cover-7000"}}]},"albums":{"items":[]},"playlists":{"items":[]}}`, etag
	case strings.has_prefix(req.path, "/artists/"):
		status, body = mock_artist(req)
		return status, body, etag
	}
	return 404, `{"userMessage":"not found"}`, etag
}

// mock_counts is how many tracks, gone ones included, and videos items has.
@(private = "file")
mock_counts :: proc(items: []Mock_Item) -> (tracks, videos: int) {
	for it in items {
		if it.kind == "video" {
			videos += 1
		} else {
			tracks += 1
		}
	}
	return
}

// mock_items_route answers a playlist's own routes, rest being the path
// after /playlists/<id>: the playlist (as pl, which tests read with the
// items' counts), its tracks and items, adding with the ETag in
// If-None-Match and removing by index. ok is false for another route.
@(private = "file")
mock_items_route :: proc(m: ^Mock, req: Mock_Request, items: ^[dynamic]Mock_Item, rest, etag: string) -> (status: int, body: string, ok: bool) {
	tracks, videos := mock_counts(items[:])
	offset, _ := strconv.parse_int(req.query["offset"] or_else "0")
	limit, _ := strconv.parse_int(req.query["limit"] or_else "1000")
	switch {
	case rest == "" && req.method == "GET":
		return 200, fmt.tprintf(`{{"uuid":"pl","title":"pl","numberOfTracks":%d,"numberOfVideos":%d,"type":"USER","lastUpdated":"2026-03-01T10:00:%02d.000+0000"}}`, tracks, videos, len(items) % 60), true
	case strings.has_prefix(rest, "/items/") && req.method == "DELETE":
		if !m.stuck {
			indices := strings.split(strings.trim_prefix(rest, "/items/"), ",", context.temp_allocator)
			// Remove from the back so earlier indices stay valid.
			for i := len(indices) - 1; i >= 0; i -= 1 {
				idx, iok := strconv.parse_int(indices[i])
				if iok && idx >= 0 && idx < len(items) {
					ordered_remove(items, idx)
				}
			}
		}
		return 200, `{}`, true
	case rest == "/items" && req.method == "POST":
		if req.etag != etag {
			return 412, `{"status":412,"userMessage":"The playlist was changed"}`, true
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"addedItemIds":[`)
		ids := req.form["trackIds"] or_else ""
		first := true
		ids_loop: for s in strings.split_iterator(&ids, ",") {
			id, iok := strconv.parse_i64(s)
			if !iok {
				continue
			}
			if req.form["onDupes"] != "ADD" {
				for it in items {
					if it.kind == "track" && it.id == id {
						continue ids_loop
					}
				}
			}
			append(items, Mock_Item{"track", id})
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			fmt.sbprintf(&b, "%d", id)
		}
		strings.write_string(&b, "]}")
		return 200, strings.to_string(b), true
	case rest == "/tracks":
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"totalNumberOfItems":%d,"items":[`, tracks)
		n := 0
		first := true
		for it in items {
			if it.kind == "video" {
				continue
			}
			if n >= offset && n < offset + limit && it.kind == "track" {
				if !first {
					strings.write_byte(&b, ',')
				}
				first = false
				fmt.sbprintf(&b, `{{"id":%d,"title":"t%d","duration":200,"dateAdded":"2026-02-03T10:00:00.000+0000","artist":{{"id":1,"name":"A"}},"artists":[{{"id":1,"name":"A"}}],"album":{{"id":2,"title":"B","cover":""}}}}`, it.id, it.id)
			}
			n += 1
		}
		strings.write_string(&b, "]}")
		return 200, strings.to_string(b), true
	case rest == "/items":
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"totalNumberOfItems":%d,"items":[`, len(items))
		first := true
		for i in offset ..< min(offset + limit, len(items)) {
			it := items[i]
			if it.kind == "gone" {
				continue
			}
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			fmt.sbprintf(&b, `{{"type":"%s","item":{{"id":%d,"title":"t%d"}}}}`, it.kind, it.id, it.id)
		}
		strings.write_string(&b, "]}")
		return 200, strings.to_string(b), true
	}
	return 0, "", false
}

// mock_playlist_json is a made playlist as TIDAL's playlist object.
@(private = "file")
mock_playlist_json :: proc(p: Mock_Playlist) -> string {
	tracks, videos := mock_counts(p.items[:])
	return fmt.tprintf(`{{"uuid":"%s","title":%q,"description":"","numberOfTracks":%d,"numberOfVideos":%d,"type":"USER","creator":{{"id":123}},"squareImage":"","lastUpdated":"2026-03-01T10:00:%02d.000+0000"}}`, p.id, p.name, tracks, videos, len(p.items) % 60)
}

MOCK_LIKED :: 1433
MOCK_LIKED_LIMIT :: 100
// Liked tracks TIDAL counts but leaves out of their pages, since they
// can't be played. Track i has id i + 1.
MOCK_UNAVAILABLE :: [?]int{120, 777, 1400}

// liked_removed_at says where track id sits among the unliked ones, or -1.
@(private = "file")
liked_removed_at :: proc(removed: []i64, id: i64) -> int {
	for r, at in removed {
		if r == id {
			return at
		}
	}
	return -1
}

// liked_at says where track id sits among the ones liked by a POST, or -1.
@(private = "file")
liked_at :: proc(m: ^Mock, id: i64) -> int {
	return liked_removed_at(m.liked[:], id)
}

// removed_at says the same of the MOCK_LIKED ones a DELETE took off, or -1.
@(private = "file")
removed_at :: proc(m: ^Mock, id: i64) -> int {
	return liked_removed_at(m.liked_removed[:], id)
}

// mock_liked_ids answers users/123/favorites/ids with the ids the
// favorites pages list and the followed artists, as strings, as TIDAL does.
mock_liked_ids :: proc(liked: []i64, removed: []i64, followed: []i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"ALBUM":[],"PLAYLIST":[],"VIDEO":[],"ARTIST":[`)
	for id, i in followed {
		fmt.sbprintf(&b, `%s"%d"`, "," if i > 0 else "", id)
	}
	strings.write_string(&b, `],"TRACK":[`)
	first := true
	write :: proc(b: ^strings.Builder, first: ^bool, id: i64) {
		if !first^ {
			strings.write_byte(b, ',')
		}
		first^ = false
		fmt.sbprintf(b, `"%d"`, id)
	}
	for id in liked {
		write(&b, &first, id)
	}
	outer: for i in 0 ..< MOCK_LIKED {
		for u in MOCK_UNAVAILABLE {
			if i == u {
				continue outer
			}
		}
		if liked_removed_at(removed, i64(i + 1)) < 0 {
			write(&b, &first, i64(i + 1))
		}
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// mock_liked_page answers users/123/favorites/tracks as TIDAL does: at
// most MOCK_LIKED_LIMIT a page, the unavailable tracks left out, and
// totalNumberOfItems counting them. Tracks liked by a POST come first. A
// track unliked with a DELETE is gone from both: it doesn't take a
// position, like an unavailable one takes one and is left out.
mock_liked_page :: proc(offset_s, limit_s: string, liked: []i64 = nil, removed: []i64 = nil) -> string {
	offset, _ := strconv.parse_int(offset_s)
	limit, _ := strconv.parse_int(limit_s)
	limit = min(limit, MOCK_LIKED_LIMIT)
	b := strings.builder_make(context.temp_allocator)
	total := MOCK_LIKED - len(removed) + len(liked)
	fmt.sbprintf(&b, `{{"limit":%d,"offset":%d,"totalNumberOfItems":%d,"items":[`, limit, offset, total)
	first := true
	outer: for at in offset ..< min(offset + limit, total) {
		if at < len(liked) {
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			fmt.sbprintf(&b, `{{"created":"2026-02-03T10:00:00.000+0000","item":{{"id":%d,"title":"t%d","duration":200,"artist":{{"id":1,"name":"A"}},"artists":[{{"id":1,"name":"A"}}],"album":{{"id":2,"title":"B","cover":""}}}}}}`, liked[at], liked[at])
			continue
		}
		// Where at lands in the MOCK_LIKED range, the unliked ones not
		// taking a position.
		at_base := at - len(liked)
		i := 0
		for at_base > 0 {
			i += 1
			if liked_removed_at(removed, i64(i + 1)) < 0 {
				at_base -= 1
			}
		}
		for liked_removed_at(removed, i64(i + 1)) >= 0 {
			i += 1
		}
		for u in MOCK_UNAVAILABLE {
			if i == u {
				continue outer
			}
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		fmt.sbprintf(&b, `{{"created":"2024-01-01T10:00:00.000+0000","item":{{"id":%d,"title":"Liked %d","duration":%d,"artist":{{"id":1,"name":"A"}},"artists":[{{"id":1,"name":"A"}}],"album":{{"id":2,"title":"B","cover":""}}}}}}`, i + 1, i, 180 + i % 60)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

MOCK_ARTIST_ALBUMS :: 73 // artist 1's albums; the others have 9
MOCK_TOP_TRACKS :: 8 // every artist's

// mock_artist answers /artists/<n> and its bio, albums (with filter
// EPSANDSINGLES or COMPILATIONS), top tracks and similar artists. Artist n is
// "Artist n", and artist 1 has MOCK_ARTIST_ALBUMS albums, more than a page.
@(private = "file")
mock_artist :: proc(req: Mock_Request) -> (status: int, body: string) {
	id_str, _, what := strings.partition(strings.trim_prefix(req.path, "/artists/"), "/")
	id, _ := strconv.parse_int(id_str)
	if id <= 0 {
		return 404, `{"status":404,"userMessage":"Artist not found"}`
	}
	offset, _ := strconv.parse_int(req.query["offset"] or_else "0")
	limit, _ := strconv.parse_int(req.query["limit"] or_else "10")
	b := strings.builder_make(context.temp_allocator)
	switch what {
	case "":
		return 200, fmt.tprintf(`{{"id":%d,"name":"Artist %d","picture":"pic-%d"}}`, id, id, id)
	case "bio":
		return 200, fmt.tprintf(`{{"source":"mock","text":"Artist %d plays with [wimpLink artistId=\"%d\"]Artist %d[/wimpLink].<br/>Second line."}}`, id, id + 1, id + 1)
	case "albums":
		count, base, kind := MOCK_ARTIST_ALBUMS if id == 1 else 9, 0, "ALBUM"
		switch req.query["filter"] or_else "" {
		case "EPSANDSINGLES":
			count, base, kind = 4, 100, "EP"
		case "COMPILATIONS":
			count, base = 2, 200
		}
		fmt.sbprintf(&b, `{{"limit":%d,"offset":%d,"totalNumberOfItems":%d,"items":[`, limit, offset, count)
		for i in offset ..< min(offset + limit, count) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			album := id * 1000 + base + i
			fmt.sbprintf(&b, `{{"id":%d,"title":"Album %d","cover":"cover-%d","numberOfTracks":10,"type":"%s","releaseDate":"2020-01-01","artist":{{"id":%d,"name":"Artist %d"}},"artists":[{{"id":%d,"name":"Artist %d"}}]}}`, album, album, album, kind, id, id, id, id)
		}
	case "toptracks":
		fmt.sbprintf(&b, `{{"limit":%d,"offset":%d,"totalNumberOfItems":%d,"items":[`, limit, offset, MOCK_TOP_TRACKS)
		for i in offset ..< min(offset + limit, MOCK_TOP_TRACKS) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			track := id * 100 + i
			fmt.sbprintf(&b, `{{"id":%d,"title":"Top %d of Artist %d","duration":200,"artist":{{"id":%d,"name":"Artist %d"}},"artists":[{{"id":%d,"name":"Artist %d"}}],"album":{{"id":%d,"title":"Album %d","cover":"cover-%d"}}}}`, track, i + 1, id, id, id, id, id, id * 1000, id * 1000, id * 1000)
		}
	case "similar":
		strings.write_string(&b, `{"limit":10,"offset":0,"totalNumberOfItems":3,"items":[`)
		for i in 1 ..= 3 {
			if i > 1 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"id":%d,"name":"Artist %d","picture":"pic-%d"}}`, id + i, id + i, id + i)
		}
	case:
		return 404, `{"userMessage":"not found"}`
	}
	strings.write_string(&b, "]}")
	return 200, strings.to_string(b)
}
