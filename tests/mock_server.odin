package tidal_tests

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

// A one-connection-at-a-time HTTP server on 127.0.0.1 standing in for TIDAL.
// It models one playlist's items, the session endpoints and an echo endpoint,
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
	last_query: map[string]string,

	allocator:  runtime.Allocator,
}

mock_start :: proc(m: ^Mock, items: []Mock_Item = nil) {
	m.allocator = runtime.heap_allocator()
	m.items = make([dynamic]Mock_Item, m.allocator)
	m.requests = make([dynamic]string, m.allocator)
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
	clear_query(&m.last_query, m.allocator)
	delete(m.last_query)
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

	status, body, etag := mock_route(m, req, target)
	resp := fmt.tprintf(
		"HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nETag: %s\r\nConnection: close\r\n\r\n%s",
		status,
		len(body),
		etag,
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

	switch {
	case req.path == "/sessions":
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
