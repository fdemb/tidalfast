// A stand-in for TIDAL to run the app against without an account:
//
//     odin run tests/mock_tidal -- -port=8787
//     TIDALFAST_API=http://127.0.0.1:8787 ./build/tidalfast
//
// It serves the device-code login (approved a few seconds after the code is
// first polled), token refresh with rotated refresh tokens, the session and
// user, liked tracks, a list of playlists with one long one, their tracks,
// and generated JPEG covers at any size under /images. Flags:
//
//     -port=N            0 picks a free port; the port is printed
//     -tracks=N          tracks in the long playlist (default 3000)
//     -approve-after=S   seconds after the first poll that the login is approved (default 3)
//     -expires-in=S      access token lifetime TIDAL reports (default 14400)
//     -page-delay=MS     added to every track page (default 0)
//     -cover-delay=MS    added to every cover (default 40)
//     -rate-limit-at=N   answer the Nth request with 429 and Retry-After: 3
//     -device-429=N      answer the first N device code requests with 429 and Retry-After: 3
//     -slow-down=N       answer the first N polls of each code with slow_down
//     -revoke-after=N    after N API requests (not logins or covers), refuse the login with 401 until a new device login, once
//     -cover-401=N       answer the first N covers after each device login with 401
//     -cover-401-delay=MS  wait this long before each of those 401s (default 0)
//     -poll-429=N        answer poll N of each code with 429 and Retry-After: 1
//
// It never prints tokens or Authorization headers.
package mock_tidal

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import stbi "vendor:stb/image"

USER_ID :: 123
LIKED :: 240

Config :: struct {
	port:            int,
	tracks:          int,
	approve_after:   f64,
	expires_in:      int,
	page_delay:      int,
	cover_delay:     int,
	rate_limit_at:   int,
	device_429:      int,
	slow_down:       int,
	revoke_after:    int,
	cover_401:       int,
	cover_401_delay: int,
	poll_429:        int,
}

Server :: struct {
	config:        Config,
	mutex:         sync.Mutex,
	requests:      int,
	token:         int, // the current access and refresh token number
	first_poll:    time.Tick,
	polled:        bool,
	polls:         int, // of the current code
	codes:         int, // device codes handed out
	api_requests:  int, // since the last device login
	revoked:       bool,
	was_revoked:   bool,
	last_poll:     time.Tick,
	covers_401:    int, // covers answered 401 since the last device login
}

server: Server

Playlist :: struct {
	name:   string,
	tracks: int,
}

PLAYLISTS := [?]Playlist {
	{"Mock Long Playlist", 0}, // config.tracks
	{"Road Trip", 120},
	{"Late Night Jazz", 64},
	{"Polskie hity", 85},
	{"夜のドライブ", 42},
	{"أغاني عربية", 30},
	{"Deep Focus", 210},
	{"Workout Bangers", 75},
	{"Lo-fi Beats", 160},
	{"Classical Essentials", 99},
	{"Empty", 0},
	{"Synthwave Nights", 55},
}

TITLES := [?]string{"Blue in Green", "Teardrop", "Hyperballad", "Pyramid Song", "Avril 14th", "Jóga", "夜に駆ける", "밤편지", "عيونك", "Wszystko czego dziś chcę", "Midnight City", "Dreams", "Windowlicker", "So What", "Lose Yourself 🔥"}
ARTISTS := [?]string{"Miles Davis", "Massive Attack", "Björk", "Radiohead", "Aphex Twin", "YOASOBI", "아이유", "فيروز", "Kult", "M83", "Fleetwood Mac", "Eminem"}
ALBUM_WORDS := [?]string{"Blue", "Night", "Summer", "Glass", "Echo", "Neon", "Paper", "River", "Static", "Velvet", "Iron", "Golden"}

main :: proc() {
	c := Config {
		tracks        = 3000,
		approve_after = 3,
		expires_in    = 14400,
		cover_delay   = 40,
	}
	for arg in os.args[1:] {
		name, _, value := strings.partition(strings.trim_prefix(arg, "-"), "=")
		n, _ := strconv.parse_int(value)
		switch name {
		case "port":
			c.port = n
		case "tracks":
			c.tracks = n
		case "approve-after":
			c.approve_after, _ = strconv.parse_f64(value)
		case "expires-in":
			c.expires_in = n
		case "page-delay":
			c.page_delay = n
		case "cover-delay":
			c.cover_delay = n
		case "rate-limit-at":
			c.rate_limit_at = n
		case "device-429":
			c.device_429 = n
		case "slow-down":
			c.slow_down = n
		case "revoke-after":
			c.revoke_after = n
		case "cover-401":
			c.cover_401 = n
		case "cover-401-delay":
			c.cover_401_delay = n
		case "poll-429":
			c.poll_429 = n
		case:
			fmt.eprintln("mock: unknown flag", arg)
			os.exit(2)
		}
	}
	PLAYLISTS[0].tracks = c.tracks
	server.config = c
	server.token = 1

	sock, err := net.listen_tcp({address = net.IP4_Loopback, port = c.port})
	if err != nil {
		fmt.eprintln("mock: listen failed:", err)
		os.exit(1)
	}
	ep, _ := net.bound_endpoint(sock)
	fmt.printfln("mock: listening on http://127.0.0.1:%d", ep.port)
	os.flush(os.stdout)
	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			continue
		}
		thread.run_with_poly_data(client, serve)
	}
}

Request :: struct {
	method: string,
	path:   string,
	query:  map[string]string,
	form:   map[string]string,
	auth:   string,
}

Response :: struct {
	status:       int,
	content_type: string,
	body:         []u8,
	retry_after:  int,
}

serve :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	defer free_all(context.temp_allocator)
	req, ok := read_request(client)
	if !ok {
		return
	}
	resp := route(&req)
	head := fmt.tprintf("HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n", resp.status, resp.content_type, len(resp.body))
	if resp.retry_after > 0 {
		head = fmt.tprintf("%sRetry-After: %d\r\n", head, resp.retry_after)
	}
	send_all(client, transmute([]u8)strings.concatenate({head, "\r\n"}, context.temp_allocator))
	send_all(client, resp.body)
}

send_all :: proc(client: net.TCP_Socket, data: []u8) {
	data := data
	for len(data) > 0 {
		n, err := net.send_tcp(client, data)
		if err != nil {
			return
		}
		data = data[n:]
	}
}

read_request :: proc(client: net.TCP_Socket) -> (req: Request, ok: bool) {
	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	chunk: [4096]u8
	header_end := -1
	for header_end < 0 {
		n, err := net.recv_tcp(client, chunk[:])
		if err != nil || n == 0 {
			return
		}
		append(&buf, ..chunk[:n])
		header_end = strings.index(string(buf[:]), "\r\n\r\n")
	}
	lines := strings.split(string(buf[:header_end]), "\r\n", context.temp_allocator)
	content_length := 0
	for line in lines[1:] {
		name, _, value := strings.partition(line, ":")
		value = strings.trim_space(value)
		if strings.equal_fold(name, "content-length") {
			content_length, _ = strconv.parse_int(value)
		} else if strings.equal_fold(name, "authorization") {
			req.auth = value
		}
	}
	for len(buf) < header_end + 4 + content_length {
		n, err := net.recv_tcp(client, chunk[:])
		if err != nil || n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
	}
	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) < 2 {
		return
	}
	req.method = parts[0]
	target, _, query := strings.partition(parts[1], "?")
	req.path = target
	req.query = parse_form(query)
	req.form = parse_form(string(buf[header_end + 4:]))
	return req, true
}

parse_form :: proc(s: string) -> map[string]string {
	out := make(map[string]string, 8, context.temp_allocator)
	rest := s
	for pair in strings.split_iterator(&rest, "&") {
		k, _, v := strings.partition(pair, "=")
		plus, _ := strings.replace_all(v, "+", " ", context.temp_allocator)
		dk, _ := net.percent_decode(k, context.temp_allocator)
		dv, _ := net.percent_decode(plus, context.temp_allocator)
		out[dk] = dv
	}
	return out
}

json_response :: proc(status: int, body: string) -> Response {
	return {status = status, content_type = "application/json", body = transmute([]u8)body}
}

route :: proc(req: ^Request) -> Response {
	sync.mutex_lock(&server.mutex)
	server.requests += 1
	n := server.requests
	token := server.token
	sync.mutex_unlock(&server.mutex)
	if n == server.config.rate_limit_at {
		fmt.println("mock: rate limiting request", n)
		r := json_response(429, `{"status":429,"subStatus":0,"userMessage":"Too many requests"}`)
		r.retry_after = 3
		return r
	}

	path := req.path
	switch {
	case path == "/oauth2/device_authorization":
		sync.guard(&server.mutex)
		server.codes += 1
		if server.codes <= server.config.device_429 {
			fmt.printfln("mock: device code request %d, 429", server.codes)
			r := json_response(429, `{"status":429,"subStatus":0,"userMessage":"Too many requests"}`)
			r.retry_after = 3
			return r
		}
		server.polled = false
		server.polls = 0
		fmt.printfln("mock: device code %d issued", server.codes)
		return json_response(200, `{"deviceCode":"mock-device-code","userCode":"MOCK1","verificationUri":"link.tidal.com","verificationUriComplete":"link.tidal.com/MOCK1","expiresIn":300,"interval":1}`)
	case path == "/oauth2/token":
		return token_response(req)
	case strings.has_prefix(path, "/images/"):
		sync.mutex_lock(&server.mutex)
		refuse := server.covers_401 < server.config.cover_401
		if refuse {
			server.covers_401 += 1
		}
		k, codes := server.covers_401, server.codes
		sync.mutex_unlock(&server.mutex)
		if refuse {
			time.sleep(time.Duration(server.config.cover_401_delay) * time.Millisecond)
			fmt.printfln("mock: cover %d asked for under device code %d, 401", k, codes)
			return json_response(401, `{"status":401,"subStatus":11002,"userMessage":"Unauthorized"}`)
		}
		return cover_response(path)
	}

	sync.mutex_lock(&server.mutex)
	server.api_requests += 1
	if server.config.revoke_after > 0 && server.api_requests > server.config.revoke_after && !server.was_revoked {
		server.revoked = true
		server.was_revoked = true
	}
	revoked := server.revoked
	sync.mutex_unlock(&server.mutex)
	if revoked {
		fmt.printfln("mock: request %d, %s %s after the login was revoked, 401", n, req.method, path)
		return json_response(401, `{"status":401,"subStatus":11002,"userMessage":"Session is not valid"}`)
	}
	if req.auth != fmt.tprintf("Bearer mock-access-%d", token) {
		fmt.printfln("mock: request %d, %s %s with a stale or missing token, 401", n, req.method, path)
		return json_response(401, `{"status":401,"subStatus":11003,"userMessage":"The token has expired. (Expired on time)"}`)
	}
	offset, _ := strconv.parse_int(req.query["offset"] or_else "0")
	limit, _ := strconv.parse_int(req.query["limit"] or_else "50")
	switch {
	case path == "/sessions":
		return json_response(200, fmt.tprintf(`{{"sessionId":"00000000-0000-4000-8000-000000000001","countryCode":"PL","userId":%d}}`, USER_ID))
	case path == fmt.tprintf("/users/%d", USER_ID):
		return json_response(200, fmt.tprintf(`{{"id":%d,"username":"mock","firstName":"Mock","lastName":"User","email":"mock@example.com"}}`, USER_ID))
	case path == fmt.tprintf("/users/%d/favorites/tracks", USER_ID):
		b := list_begin(LIKED, offset, limit)
		for i in offset ..< min(offset + limit, LIKED) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"created":"%s","item":`, date(i))
			write_track(&b, 99, i)
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
		return json_response(200, strings.to_string(b))
	case path == fmt.tprintf("/users/%d/playlistsAndFavoritePlaylists", USER_ID):
		b := list_begin(len(PLAYLISTS), offset, limit)
		for i in offset ..< min(offset + limit, len(PLAYLISTS)) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			pl := PLAYLISTS[i]
			fmt.sbprintf(&b, `{{"type":"USER_CREATED","created":"%s","playlist":{{"uuid":"%s","title":%q,"numberOfTracks":%d,"numberOfVideos":0,"type":"USER","creator":{{"id":%d}},"squareImage":"%s","image":"%s"}}}}`,
				date(i), playlist_id(i), pl.name, pl.tracks, USER_ID, image_id(1000 + i), image_id(2000 + i))
		}
		strings.write_string(&b, "]}")
		return json_response(200, strings.to_string(b))
	case strings.has_prefix(path, "/playlists/") && strings.has_suffix(path, "/tracks"):
		id := strings.trim_suffix(strings.trim_prefix(path, "/playlists/"), "/tracks")
		p := -1
		for i in 0 ..< len(PLAYLISTS) {
			if playlist_id(i) == id {
				p = i
			}
		}
		if p < 0 {
			return json_response(404, `{"status":404,"userMessage":"Playlist not found"}`)
		}
		if server.config.page_delay > 0 {
			time.sleep(time.Duration(server.config.page_delay) * time.Millisecond)
		}
		total := PLAYLISTS[p].tracks
		b := list_begin(total, offset, limit)
		for i in offset ..< min(offset + limit, total) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			write_track(&b, p, i)
		}
		strings.write_string(&b, "]}")
		return json_response(200, strings.to_string(b))
	}
	fmt.printfln("mock: no route for %s %s", req.method, path)
	return json_response(404, `{"status":404,"userMessage":"Not found"}`)
}

token_response :: proc(req: ^Request) -> Response {
	sync.guard(&server.mutex)
	switch req.form["grant_type"] {
	case "urn:ietf:params:oauth:grant-type:device_code":
		if !server.polled {
			server.polled = true
			server.first_poll = time.tick_now()
		}
		server.polls += 1
		gap := time.duration_seconds(time.tick_since(server.last_poll)) if server.polls > 1 else 0
		server.last_poll = time.tick_now()
		if server.polls <= server.config.slow_down {
			fmt.printfln("mock: poll %d, %.3f s after the last, slow_down", server.polls, gap)
			return json_response(400, `{"status":400,"error":"slow_down","error_description":"Polling too fast"}`)
		}
		if server.polls == server.config.poll_429 {
			fmt.printfln("mock: poll %d, %.3f s after the last, 429", server.polls, gap)
			r := json_response(429, `{"status":429,"subStatus":0,"userMessage":"Too many requests"}`)
			r.retry_after = 1
			return r
		}
		fmt.printfln("mock: poll %d, %.3f s after the last", server.polls, gap)
		if time.duration_seconds(time.tick_since(server.first_poll)) < server.config.approve_after {
			return json_response(400, `{"status":400,"error":"authorization_pending","sub_status":1002,"error_description":"Device Authorization code is not authorized yet"}`)
		}
		server.token += 1
		server.revoked = false
		server.api_requests = 0
		server.covers_401 = 0
		fmt.printfln("mock: device login approved, tokens %d", server.token)
	case "refresh_token":
		if server.revoked {
			fmt.println("mock: refresh after the login was revoked, 400")
			return json_response(400, `{"status":400,"error":"invalid_grant","sub_status":11101,"error_description":"Token could not be verified"}`)
		}
		if req.form["refresh_token"] != fmt.tprintf("mock-refresh-%d", server.token) {
			fmt.println("mock: refresh with an old refresh token, 400")
			return json_response(400, `{"status":400,"error":"invalid_grant","sub_status":11101,"error_description":"Token could not be verified"}`)
		}
		server.token += 1
		fmt.printfln("mock: refreshed, tokens %d", server.token)
	case:
		return json_response(400, `{"status":400,"error":"unsupported_grant_type"}`)
	}
	return json_response(200, fmt.tprintf(`{{"access_token":"mock-access-%d","refresh_token":"mock-refresh-%d","token_type":"Bearer","expires_in":%d,"user_id":%d}}`,
		server.token, server.token, server.config.expires_in, USER_ID))
}

list_begin :: proc(total, offset, limit: int) -> strings.Builder {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"limit":%d,"offset":%d,"totalNumberOfItems":%d,"items":[`, limit, offset, total)
	return b
}

playlist_id :: proc(i: int) -> string {
	return fmt.tprintf("00000000-0000-4000-9000-%012x", i)
}

image_id :: proc(n: int) -> string {
	return fmt.tprintf("%08x-0000-4000-8000-%012x", n * 2654435761 % 0xffffffff, n)
}

date :: proc(i: int) -> string {
	return fmt.tprintf("20%02d-%02d-%02dT10:00:00.000+0000", 18 + i % 7, 1 + i % 12, 1 + i % 28)
}

write_track :: proc(b: ^strings.Builder, playlist, i: int) {
	h := u32(playlist * 100_003 + i) * 2654435761
	album := int(h >> 8) % 700 + 1
	fmt.sbprintf(b, `{{"id":%d,"title":%q,"duration":%d,"version":null,"dateAdded":"%s","artist":{{"id":%d,"name":%q}},"artists":[{{"id":%d,"name":%q}}],"album":{{"id":%d,"title":"%s %s %d","cover":"%s"}}}}`,
		playlist * 1_000_000 + i, TITLES[(h >> 4) % len(TITLES)], 95 + int(h >> 12) % 400, date(i),
		h % 50, ARTISTS[(h >> 16) % len(ARTISTS)], h % 50, ARTISTS[(h >> 16) % len(ARTISTS)],
		album, ALBUM_WORDS[album % len(ALBUM_WORDS)], ALBUM_WORDS[(album / 12) % len(ALBUM_WORDS)], album, image_id(album))
}

// cover_response draws a cover for /images/<id with / for ->/<w>x<h>.jpg:
// a diagonal gradient in a hue from the id with a disc on it, as a JPEG.
cover_response :: proc(path: string) -> Response {
	rest := strings.trim_prefix(path, "/images/")
	slash := strings.last_index_byte(rest, '/')
	if slash < 0 {
		return json_response(404, `{}`)
	}
	id := rest[:slash]
	size_str := strings.trim_suffix(rest[slash + 1:], ".jpg")
	ws, _, hs := strings.partition(size_str, "x")
	w, _ := strconv.parse_int(ws)
	h, _ := strconv.parse_int(hs)
	if w <= 0 || h <= 0 || w > 2000 || h > 2000 {
		return json_response(404, `{}`)
	}
	if server.config.cover_delay > 0 {
		time.sleep(time.Duration(server.config.cover_delay) * time.Millisecond)
	}
	seed := hash.fnv32a(transmute([]u8)id)
	hue := f32(seed % 360) / 360
	a := hsv(hue, 0.65, 0.95)
	c := hsv(hue + 0.12, 0.8, 0.35)
	pixels := make([]u8, w * h * 3, context.temp_allocator)
	cx, cy := f32(w) * (0.3 + f32((seed >> 9) % 40) / 100), f32(h) * (0.3 + f32((seed >> 17) % 40) / 100)
	radius := f32(min(w, h)) * 0.22
	for y in 0 ..< h {
		for x in 0 ..< w {
			t := (f32(x) / f32(w) + f32(y) / f32(h)) / 2
			col := a + (c - a) * t
			if d := math.hypot(f32(x) - cx, f32(y) - cy); d < radius {
				col = col * 0.4 + 0.6 * [3]f32{1, 1, 1} * (1 - d / radius * 0.3)
			}
			i := (y * w + x) * 3
			pixels[i], pixels[i + 1], pixels[i + 2] = u8(col.r * 255), u8(col.g * 255), u8(col.b * 255)
		}
	}
	out := make([dynamic]u8, 0, 16 * 1024, context.temp_allocator)
	write :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
		out := (^[dynamic]u8)(ctx)
		context = runtime.default_context()
		append(out, ..([^]u8)(data)[:size])
	}
	stbi.write_jpg_to_func(write, &out, i32(w), i32(h), 3, raw_data(pixels), 85)
	return {status = 200, content_type = "image/jpeg", body = out[:]}
}

hsv :: proc(h, s, v: f32) -> [3]f32 {
	h6 := (h - math.floor(h)) * 6
	k := [3]f32{math.mod(5 + h6, 6), math.mod(3 + h6, 6), math.mod(1 + h6, 6)}
	out: [3]f32
	for i in 0 ..< 3 {
		out[i] = v - v * s * max(0, min(k[i], 4 - k[i], 1))
	}
	return out
}
