package tidal_tests

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// A one-connection-at-a-time HTTP server on 127.0.0.1 standing in for TIDAL.
// It models one playlist's items, the session endpoints, an echo endpoint,
// a rate-limited endpoint, a slow one, token refresh and the device login,
// and records every request line.

Mock_Item :: struct {
	kind: string, // "track" or "video"
	id:   i64,
}

Mock_Request :: struct {
	method:     string,
	path:       string,
	query:      map[string]string,
	authorized: bool,
}

Mock :: struct {
	socket:     net.TCP_Socket,
	base_url:   string,
	thread:     ^thread.Thread,
	stopping:   bool,

	mutex:      sync.Mutex,
	items:      [dynamic]Mock_Item,
	// Accept DELETEs without removing anything.
	stuck:      bool,
	requests:   [dynamic]string, // "METHOD /path?query"
	refreshes:  int, // POSTs to /token
	last_query: map[string]string,
	// Non-zero: /token and /device answer with this status (429 asks for
	// one second).
	token_status:  int,
	device_status: int,
	token_error:   string, // the OAuth error with token_status
	token_delay:   time.Duration, // before /token answers
	sessions_fail: int, // /sessions answers this many requests with a 503
	// /device_token, and /oauth2/token for an app session, answers poll i
	// with polls[i]: "pending", "slow_down", "denied", "429" or "ok"; past
	// the end, "pending". poll_times has when each poll arrived.
	polls:      []string,
	poll_count: int,
	poll_times: [dynamic]time.Tick,
	// Paths answered with these bytes, as audio files or DASH segments.
	files:      map[string][]u8,
	token_form: map[string]string, // the last POST to /token, decoded

	allocator:  runtime.Allocator,
}

mock_start :: proc(m: ^Mock, items: []Mock_Item = nil) {
	m.allocator = runtime.heap_allocator()
	m.items = make([dynamic]Mock_Item, m.allocator)
	m.requests = make([dynamic]string, m.allocator)
	m.poll_times = make([dynamic]time.Tick, m.allocator)
	m.files = make(map[string][]u8, m.allocator)
	m.token_form = make(map[string]string, m.allocator)
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
	delete(m.poll_times)
	clear_query(&m.last_query, m.allocator)
	delete(m.last_query)
	clear_query(&m.token_form, m.allocator)
	delete(m.token_form)
	delete(m.files)
	delete(m.base_url, m.allocator)
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
	lines := strings.split(head, "\r\n", context.temp_allocator)
	for line in lines[1:] {
		name, _, value := strings.partition(line, ":")
		value = strings.trim_space(value)
		if strings.equal_fold(name, "content-length") {
			content_length, _ = strconv.parse_int(value)
		} else if strings.equal_fold(name, "authorization") {
			authorized = true
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

	if req.path == "/token" {
		sync.guard(&m.mutex)
		clear_query(&m.token_form, m.allocator)
		form := string(buf[header_end + 4:])
		for pair in strings.split_iterator(&form, "&") {
			k, _, v := strings.partition(pair, "=")
			plus, _ := strings.replace_all(v, "+", " ", context.temp_allocator)
			dk, _ := net.percent_decode(k, context.temp_allocator)
			dv, _ := net.percent_decode(plus, context.temp_allocator)
			m.token_form[strings.clone(dk, m.allocator)] = strings.clone(dv, m.allocator)
		}
	}
	status, body, etag := mock_route(m, req, target)
	// A 429 always asks for one second.
	extra := "Retry-After: 1\r\n" if status == 429 else ""
	resp := fmt.tprintf(
		"HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nETag: %s\r\n%sConnection: close\r\n\r\n%s",
		status,
		len(body),
		etag,
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

	tracks, videos := 0, 0
	for it in m.items {
		if it.kind == "video" {
			videos += 1
		} else {
			tracks += 1
		}
	}
	etag = fmt.tprintf("etag-%d", len(m.items))
	if data, ok := m.files[req.path]; ok {
		return 200, string(data), etag
	}

	switch {
	case req.path == "/sessions":
		if m.sessions_fail > 0 {
			m.sessions_fail -= 1
			return 503, `{"userMessage":"unavailable"}`, etag
		}
		if !req.authorized && "sessionId" not_in req.query {
			return 401, `{"userMessage":"unauthorized"}`, etag
		}
		return 200, `{"sessionId":"00000000-0000-0000-0000-000000000001","countryCode":"PL","userId":123}`, etag
	case req.path == "/users/123":
		return 200, `{"id":123,"username":"user","firstName":"F","lastName":"L","email":"u@example.com"}`, etag
	case req.path == "/users/123/subscription":
		return 200, `{}`, etag
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
	case strings.has_prefix(req.path, "/playlists/pl/items/") && req.method == "DELETE":
		if !m.stuck {
			index_list := strings.trim_prefix(req.path, "/playlists/pl/items/")
			indices := strings.split(index_list, ",", context.temp_allocator)
			// Remove from the back so earlier indices stay valid.
			for i := len(indices) - 1; i >= 0; i -= 1 {
				idx, ok := strconv.parse_int(indices[i])
				if ok && idx >= 0 && idx < len(m.items) {
					ordered_remove(&m.items, idx)
				}
			}
		}
		return 200, `{}`, etag
	case req.path == "/playlists/pl/items":
		offset, _ := strconv.parse_int(req.query["offset"] or_else "0")
		limit, _ := strconv.parse_int(req.query["limit"] or_else "1000")
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"totalNumberOfItems":%d,"items":[`, len(m.items))
		for i in offset ..< min(offset + limit, len(m.items)) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			it := m.items[i]
			fmt.sbprintf(&b, `{{"type":"%s","item":{{"id":%d,"title":"t%d"}}}}`, it.kind, it.id, it.id)
		}
		strings.write_string(&b, "]}")
		return 200, strings.to_string(b), etag
	case req.path == "/playlists/pl":
		return 200, fmt.tprintf(`{{"uuid":"pl","title":"pl","numberOfTracks":%d,"numberOfVideos":%d,"type":"USER"}}`, tracks, videos), etag
	}
	return 404, `{"userMessage":"not found"}`, etag
}
