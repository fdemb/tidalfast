// A stand-in for TIDAL to run the app against without an account:
//
//     odin run tests/mock_tidal -- -port=8787
//     TIDALFAST_API=http://127.0.0.1:8787 ./build/tidalfast
//
// It serves the device-code login (approved a few seconds after the code is
// first polled), token refresh with rotated refresh tokens, the session and
// user, 1433 liked tracks (100 a page at most, three of them unavailable
// and left out of their pages as TIDAL does), a list of playlists with one long one, their tracks,
// generated JPEG covers at any size under /images, and playback: LOSSLESS
// playbackinfopostpaywall answers whose BTS manifest points at FLAC files
// under /audio, served with Range support (see audio.odin). The first three
// liked tracks are a gapless live album. The next three are a hi-res test
// album (hires.odin): a quiet 16/44.1 track, then two quiet 24/96 tracks
// that come as DASH when a PKCE login asks for HI_RES_LOSSLESS. /search finds
// tracks of the long playlist by title or artist, with their albums and
// artists and the playlists by name; a query that matches nothing gets
// made-up tracks named after it, so any query has results. /albums/<id>/tracks
// and /artists/<id>/toptracks list a dozen made-up tracks. Every fifth
// made-up track has a second artist.
//
// The PKCE login: GET /authorize redirects to /android/login/auth with a
// code, and POST /oauth2/token trades it, with the Android client's id,
// for tokens that refresh only with that client id. Flags:
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
//     -audio-dir=PATH    where the generated audio goes (default /tmp/tidalfast-mock-audio)
//     -seektable=0       FLAC files without a SEEKTABLE, so seeks have to search
//     -audio-delay=MS    added before every audio response, like network latency
//     -audio-rate=KB     audio bandwidth in KB/s per connection (default unlimited)
//     -hires-only        liked tracks are only the hi-res album, so playing through them never reaches the loud test tracks
//     -device-flac       give the device-code login FLAC, as before; by default it gets AAC, as from TIDAL
//     -refuse-hires      answer HI_RES_LOSSLESS with 403, so the app falls back to LOSSLESS
//     -lossless-dash     send the hi-res album's 16/44.1 track as DASH to a PKCE login, at LOSSLESS too
//
// Each playlist has a lastUpdated. GET /mock/change?playlist=N adds a track
// to playlist N and moves its lastUpdated on; /mock/change?liked=1 likes a
// new track, which goes to the top of the liked tracks. Neither needs a
// token, so a script can change things while the app runs:
//
//     curl 'http://127.0.0.1:8787/mock/change?playlist=1'
//
// The app's own edits work too. GET /playlists/<uuid> gives a playlist and
// its ETag, and POST /playlists/<uuid>/items with that ETag in If-None-Match
// adds trackIds at the end, skipping one that's there already, and moves
// lastUpdated on. A stale ETag gets 412. POST /users/123/favorites/tracks
// likes trackId, unless it's liked already. Any track id from the mock can
// be added, and it's listed as it is elsewhere.
//
// It never prints tokens or Authorization headers.
package mock_tidal

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import stbi "vendor:stb/image"

USER_ID :: 123
LIKED :: 1433
LIKED_LIMIT :: 100 // the most liked tracks a page gives, whatever the request asks
// Liked tracks that can't be played. TIDAL counts them in
// totalNumberOfItems but leaves them out of their page, so that page comes
// back short.
UNAVAILABLE :: [?]int{120, 777, 1400}

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
	audio_dir:       string,
	seektable:       bool,
	audio_delay:     int,
	audio_rate:      int,
	hires_only:      bool,
	device_flac:     bool,
	refuse_hires:    bool,
	lossless_dash:   bool,
}

Server :: struct {
	config:        Config,
	port:          int,
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
	pkce:          bool, // the current tokens came from the PKCE login
	pkce_codes:    int,
	changes:       [len(PLAYLISTS)]int, // /mock/change calls per playlist
	liked_added:   [dynamic]int, // track ids liked through /mock/change or a POST, oldest first; heap
	added:         [len(PLAYLISTS)][dynamic]Added_Item, // tracks added by a POST; heap
}

Added_Item :: struct {
	at: int, // the row it went in at
	id: int,
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
		audio_dir     = "/tmp/tidalfast-mock-audio",
		seektable     = true,
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
		case "audio-dir":
			c.audio_dir = value
		case "seektable":
			c.seektable = n != 0
		case "audio-delay":
			c.audio_delay = n
		case "audio-rate":
			c.audio_rate = n
		case "hires-only":
			c.hires_only = value != "0"
		case "device-flac":
			c.device_flac = value != "0"
		case "refuse-hires":
			c.refuse_hires = value != "0"
		case "lossless-dash":
			c.lossless_dash = value != "0"
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
	server.port = ep.port
	if !audio_prepare(c.audio_dir, c.seektable) {
		fmt.eprintln("mock: couldn't make the audio files; playback won't work")
	}
	if !hires_prepare(c.audio_dir) {
		fmt.eprintln("mock: couldn't make the hi-res files")
	}
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
	range:  string,
	etag:   string, // If-None-Match
}

Response :: struct {
	status:        int,
	content_type:  string,
	body:          []u8,
	retry_after:   int,
	content_range: string,
	location:      string,
	etag:          string,
	audio:         bool, // send with -audio-delay and -audio-rate
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
	if resp.location != "" {
		head = fmt.tprintf("%sLocation: %s\r\n", head, resp.location)
	}
	if resp.etag != "" {
		head = fmt.tprintf("%sETag: %s\r\n", head, resp.etag)
	}
	if resp.audio {
		head = fmt.tprintf("%sAccept-Ranges: bytes\r\n", head)
		if resp.content_range != "" {
			head = fmt.tprintf("%sContent-Range: %s\r\n", head, resp.content_range)
		}
		if server.config.audio_delay > 0 {
			time.sleep(time.Duration(server.config.audio_delay) * time.Millisecond)
		}
	}
	if !send_all(client, transmute([]u8)strings.concatenate({head, "\r\n"}, context.temp_allocator)) {
		return
	}
	if !resp.audio || server.config.audio_rate <= 0 {
		send_all(client, resp.body)
		return
	}
	// Throttled: a 16 KB chunk at a time, paced to -audio-rate.
	CHUNK :: 16 << 10
	start := time.tick_now()
	for sent := 0; sent < len(resp.body); sent += CHUNK {
		if !send_all(client, resp.body[sent:min(sent + CHUNK, len(resp.body))]) {
			return
		}
		due := time.Duration(f64(sent + CHUNK) / f64(server.config.audio_rate * 1024) * f64(time.Second))
		if wait := due - time.tick_since(start); wait > 0 {
			time.sleep(wait)
		}
	}
}

parse_i :: proc(s: string) -> (int, bool) {
	return strconv.parse_int(strings.trim_space(s))
}

send_all :: proc(client: net.TCP_Socket, data: []u8) -> bool {
	data := data
	for len(data) > 0 {
		n, err := net.send_tcp(client, data)
		if err != nil {
			return false
		}
		data = data[n:]
	}
	return true
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
		} else if strings.equal_fold(name, "range") {
			req.range = value
		} else if strings.equal_fold(name, "if-none-match") {
			req.etag = value
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
	pkce := server.pkce
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
	case strings.has_prefix(path, "/audio/"):
		return audio_response(req)
	case strings.has_prefix(path, "/dash/"):
		return dash_response(req)
	case path == "/authorize":
		return authorize_response(req)
	case path == "/android/login/auth":
		return {status = 200, content_type = "text/html", body = transmute([]u8)string("<html><body><h1>Oops</h1><p>Copy this page's address into TIDALfast.</p></body></html>")}
	case path == "/mock/change":
		sync.guard(&server.mutex)
		if p, ok := parse_i(req.query["playlist"] or_else ""); ok && p >= 0 && p < len(PLAYLISTS) {
			PLAYLISTS[p].tracks += 1
			server.changes[p] += 1
			fmt.printfln("mock: playlist %d changed, %d tracks", p, PLAYLISTS[p].tracks)
		}
		if "liked" in req.query {
			append(&server.liked_added, 98 * 1_000_000 + len(server.liked_added))
			fmt.printfln("mock: a new liked track, %d liked", LIKED + len(server.liked_added))
		}
		return json_response(200, "{}")
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
	if req.auth != fmt.tprintf("Bearer mock-%saccess-%d", "pkce-" if pkce else "", token) {
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
	case strings.has_prefix(path, "/tracks/") && strings.has_suffix(path, "/playbackinfopostpaywall"):
		id, _ := parse_i(strings.trim_suffix(strings.trim_prefix(path, "/tracks/"), "/playbackinfopostpaywall"))
		quality := req.query["audioquality"] or_else "?"
		fmt.printfln("mock: playbackinfo for %d (%s)", id, quality)
		if !pkce && !server.config.device_flac {
			// What TIDAL gives the device-code client, whatever it asks for.
			return aac_playbackinfo(id)
		}
		if pkce && quality == "HI_RES_LOSSLESS" && server.config.refuse_hires {
			fmt.printfln("mock: refusing HI_RES_LOSSLESS for %d with 403", id)
			return json_response(403, `{"status":403,"subStatus":4005,"userMessage":"This quality is not available for this account"}`)
		}
		if hires_index(id) >= 0 {
			return hires_playbackinfo(id, quality, pkce)
		}
		return playbackinfo_response(id)
	case path == fmt.tprintf("/users/%d/favorites/tracks", USER_ID) && req.method == "POST":
		id, _ := parse_i(req.form["trackId"] or_else "")
		sync.guard(&server.mutex)
		if is_liked(id) {
			fmt.printfln("mock: track %d is liked already", id)
		} else {
			append(&server.liked_added, id)
			fmt.printfln("mock: liked track %d, %d liked", id, LIKED + len(server.liked_added))
		}
		return json_response(200, "{}")
	case path == fmt.tprintf("/users/%d/favorites/tracks", USER_ID):
		sync.mutex_lock(&server.mutex)
		liked_added := slice.clone(server.liked_added[:], context.temp_allocator)
		sync.mutex_unlock(&server.mutex)
		extra := 0 if server.config.hires_only else len(liked_added)
		liked := len(HIRES) if server.config.hires_only else LIKED + extra
		limit = min(limit, LIKED_LIMIT)
		b := list_begin(liked, offset, limit)
		first := true
		outer: for at in offset ..< min(offset + limit, liked) {
			if at < extra {
				if !first {
					strings.write_byte(&b, ',')
				}
				first = false
				fmt.sbprintf(&b, `{{"created":"2026-01-01T10:00:00.000+0000","item":`)
				write_track_id(&b, liked_added[extra - 1 - at])
				strings.write_byte(&b, '}')
				continue
			}
			i := at - extra
			if !server.config.hires_only {
				for u in UNAVAILABLE {
					if i == u {
						continue outer
					}
				}
			}
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			fmt.sbprintf(&b, `{{"created":"%s","item":`, date(i))
			if server.config.hires_only {
				write_hires_track(&b, i)
			} else if i < 3 {
				write_album_track(&b, i)
			} else if i < 3 + len(HIRES) {
				write_hires_track(&b, i - 3)
			} else {
				write_track(&b, 99, i)
			}
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
		return json_response(200, strings.to_string(b))
	case path == fmt.tprintf("/users/%d/playlistsAndFavoritePlaylists", USER_ID):
		b := list_begin(len(PLAYLISTS), offset, limit)
		sync.guard(&server.mutex)
		for i in offset ..< min(offset + limit, len(PLAYLISTS)) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"type":"USER_CREATED","created":"%s","playlist":`, date(i))
			write_playlist(&b, i)
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
		return json_response(200, strings.to_string(b))
	case path == "/search":
		return search_response(req.query["query"] or_else "", req.query["types"] or_else "", offset, limit)
	case strings.has_prefix(path, "/albums/") && strings.has_suffix(path, "/tracks"):
		id, _ := parse_i(strings.trim_suffix(strings.trim_prefix(path, "/albums/"), "/tracks"))
		return made_up_tracks(id, -1, offset, limit)
	case strings.has_prefix(path, "/artists/") && strings.has_suffix(path, "/toptracks"):
		id, _ := parse_i(strings.trim_suffix(strings.trim_prefix(path, "/artists/"), "/toptracks"))
		return made_up_tracks(-1, id, offset, limit)
	case strings.has_prefix(path, "/playlists/") && strings.has_suffix(path, "/items") && req.method == "POST":
		p := playlist_index(strings.trim_suffix(strings.trim_prefix(path, "/playlists/"), "/items"))
		if p < 0 {
			return json_response(404, `{"status":404,"userMessage":"Playlist not found"}`)
		}
		return add_items(p, req)
	case strings.has_prefix(path, "/playlists/") && strings.count(path, "/") == 2:
		p := playlist_index(strings.trim_prefix(path, "/playlists/"))
		if p < 0 {
			return json_response(404, `{"status":404,"userMessage":"Playlist not found"}`)
		}
		b := strings.builder_make(context.temp_allocator)
		sync.guard(&server.mutex)
		write_playlist(&b, p)
		r := json_response(200, strings.to_string(b))
		r.etag = playlist_etag(p)
		return r
	case strings.has_prefix(path, "/playlists/") && strings.has_suffix(path, "/tracks"):
		p := playlist_index(strings.trim_suffix(strings.trim_prefix(path, "/playlists/"), "/tracks"))
		if p < 0 {
			return json_response(404, `{"status":404,"userMessage":"Playlist not found"}`)
		}
		if server.config.page_delay > 0 {
			time.sleep(time.Duration(server.config.page_delay) * time.Millisecond)
		}
		sync.guard(&server.mutex)
		total := PLAYLISTS[p].tracks
		b := list_begin(total, offset, limit)
		rows: for i in offset ..< min(offset + limit, total) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			for a in server.added[p] {
				if a.at == i {
					write_track_id(&b, a.id)
					continue rows
				}
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
		server.pkce = false
		server.revoked = false
		server.api_requests = 0
		server.covers_401 = 0
		fmt.printfln("mock: device login approved, tokens %d", server.token)
	case "authorization_code":
		f := req.form
		switch {
		case f["client_id"] != PKCE_CLIENT_ID:
			fmt.println("mock: PKCE login with the wrong client id, 400")
			return json_response(400, `{"status":400,"error":"invalid_client"}`)
		case !strings.has_prefix(f["code"] or_else "", "mock-pkce-code-"), f["code_verifier"] == "", !strings.has_suffix(f["redirect_uri"] or_else "", "/android/login/auth"):
			fmt.println("mock: PKCE login with a bad code, verifier or redirect, 400")
			return json_response(400, `{"status":400,"error":"invalid_grant","error_description":"Bad authorization code"}`)
		}
		server.token += 1
		server.pkce = true
		server.revoked = false
		server.api_requests = 0
		fmt.printfln("mock: PKCE login, tokens %d", server.token)
	case "refresh_token":
		if server.revoked {
			fmt.println("mock: refresh after the login was revoked, 400")
			return json_response(400, `{"status":400,"error":"invalid_grant","sub_status":11101,"error_description":"Token could not be verified"}`)
		}
		if server.pkce && req.form["client_id"] != PKCE_CLIENT_ID {
			fmt.println("mock: PKCE tokens refreshed with another client id, 400")
			return json_response(400, `{"status":400,"error":"invalid_client","error_description":"Wrong client for this refresh token"}`)
		}
		if req.form["refresh_token"] != fmt.tprintf("mock-%srefresh-%d", "pkce-" if server.pkce else "", server.token) {
			fmt.println("mock: refresh with an old refresh token, 400")
			return json_response(400, `{"status":400,"error":"invalid_grant","sub_status":11101,"error_description":"Token could not be verified"}`)
		}
		server.token += 1
		fmt.printfln("mock: refreshed, tokens %d", server.token)
	case:
		return json_response(400, `{"status":400,"error":"unsupported_grant_type"}`)
	}
	kind := "pkce-" if server.pkce else ""
	return json_response(200, fmt.tprintf(`{{"access_token":"mock-%saccess-%d","refresh_token":"mock-%srefresh-%d","token_type":"Bearer","expires_in":%d,"user_id":%d}}`,
		kind, server.token, kind, server.token, server.config.expires_in, USER_ID))
}

playlist_index :: proc(id: string) -> int {
	for i in 0 ..< len(PLAYLISTS) {
		if playlist_id(i) == id {
			return i
		}
	}
	return -1
}

// write_playlist writes playlist p as TIDAL's playlist object. Hold the
// mutex.
write_playlist :: proc(b: ^strings.Builder, p: int) {
	pl := PLAYLISTS[p]
	fmt.sbprintf(b, `{{"uuid":"%s","title":%q,"numberOfTracks":%d,"numberOfVideos":0,"type":"USER","creator":{{"id":%d}},"squareImage":"%s","image":"%s","lastUpdated":"%s"}}`,
		playlist_id(p), pl.name, pl.tracks, USER_ID, image_id(1000 + p), image_id(2000 + p), last_updated(p, server.changes[p]))
}

// playlist_etag changes with every change to playlist p. Hold the mutex.
playlist_etag :: proc(p: int) -> string {
	return fmt.tprintf(`"%d-%d"`, p, server.changes[p])
}

// add_items adds the request's trackIds to the end of playlist p, as
// POST /playlists/<uuid>/items does.
add_items :: proc(p: int, req: ^Request) -> Response {
	sync.guard(&server.mutex)
	if req.etag != playlist_etag(p) {
		fmt.printfln("mock: adding to playlist %d with a stale ETag, 412", p)
		return json_response(412, `{"status":412,"subStatus":0,"userMessage":"The playlist was changed"}`)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"addedItemIds":[`)
	ids := req.form["trackIds"] or_else ""
	first := true
	for s in strings.split_iterator(&ids, ",") {
		id, ok := parse_i(s)
		if !ok || in_playlist(p, id) {
			fmt.printfln("mock: track %s is in playlist %d already", s, p)
			continue
		}
		append(&server.added[p], Added_Item{PLAYLISTS[p].tracks, id})
		PLAYLISTS[p].tracks += 1
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		fmt.sbprintf(&b, "%d", id)
		fmt.printfln("mock: added track %d to playlist %d, %d tracks", id, p, PLAYLISTS[p].tracks)
	}
	if !first {
		server.changes[p] += 1
	}
	fmt.sbprintf(&b, `],"lastUpdated":"%s"}}`, last_updated(p, server.changes[p]))
	return json_response(200, strings.to_string(b))
}

// in_playlist says whether playlist p lists track id. Hold the mutex.
in_playlist :: proc(p, id: int) -> bool {
	for a in server.added[p] {
		if a.id == id {
			return true
		}
	}
	at := id % 1_000_000
	if id / 1_000_000 != p || at >= PLAYLISTS[p].tracks {
		return false
	}
	for a in server.added[p] {
		if a.at == at {
			return false // another track took that row
		}
	}
	return true
}

// is_liked says whether track id is among the liked tracks. Hold the mutex.
is_liked :: proc(id: int) -> bool {
	for l in server.liked_added {
		if l == id {
			return true
		}
	}
	if id >= ALBUM_TRACK_ID && id < ALBUM_TRACK_ID + 3 || id >= HIRES_TRACK_ID && id < HIRES_TRACK_ID + len(HIRES) {
		return true
	}
	at := id - 99 * 1_000_000
	for u in UNAVAILABLE {
		if at == u {
			return false
		}
	}
	return at >= 3 + len(HIRES) && at < LIKED
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

// last_updated is playlist i's lastUpdated after n changes.
last_updated :: proc(i, n: int) -> string {
	return fmt.tprintf("2025-06-%02dT10:%02d:%02d.000+0000", 1 + i % 28, n / 60 % 60, n % 60)
}

date :: proc(i: int) -> string {
	return fmt.tprintf("20%02d-%02d-%02dT10:00:00.000+0000", 18 + i % 7, 1 + i % 12, 1 + i % 28)
}

track_hash :: proc(playlist, i: int) -> u32 {
	return u32(playlist * 100_003 + i) * 2654435761
}

// write_track_id writes the track with this id as the rest of the mock
// lists it: the gapless album, the hi-res album, or a playlist's row.
write_track_id :: proc(b: ^strings.Builder, id: int) {
	switch {
	case id >= ALBUM_TRACK_ID && id < ALBUM_TRACK_ID + 3:
		write_album_track(b, id - ALBUM_TRACK_ID)
	case id >= HIRES_TRACK_ID && id < HIRES_TRACK_ID + len(HIRES):
		write_hires_track(b, id - HIRES_TRACK_ID)
	case:
		write_track(b, id / 1_000_000, id % 1_000_000)
	}
}

write_track :: proc(b: ^strings.Builder, playlist, i: int) {
	h := track_hash(playlist, i)
	write_track_as(b, playlist * 1_000_000 + i, TITLES[(h >> 4) % len(TITLES)], int(h >> 8) % 700 + 1, int(h >> 16) % len(ARTISTS), i, h)
}

// write_track_as writes a track with the given id, title, album and artist
// (an index into ARTISTS, whose id is one more). Every fifth track has the
// next artist on it too.
write_track_as :: proc(b: ^strings.Builder, id: int, title: string, album, artist, i: int, h: u32) {
	fmt.sbprintf(b, `{{"id":%d,"title":%q,"duration":%d,"trackNumber":%d,"version":null,"dateAdded":"%s","artist":{{"id":%d,"name":%q}},"artists":[{{"id":%d,"name":%q}}`,
		id, title, 95 + int(h >> 12) % 400, 1 + i % 12, date(i),
		artist + 1, ARTISTS[artist], artist + 1, ARTISTS[artist])
	if i % 5 == 4 {
		other := (artist + 1) % len(ARTISTS)
		fmt.sbprintf(b, `,{{"id":%d,"name":%q}}`, other + 1, ARTISTS[other])
	}
	fmt.sbprintf(b, `],"album":{{"id":%d,"title":%q,"cover":"%s"}}}}`, album, album_title(album), image_id(album))
}

album_title :: proc(album: int) -> string {
	return fmt.tprintf("%s %s %d", ALBUM_WORDS[album % len(ALBUM_WORDS)], ALBUM_WORDS[(album / 12) % len(ALBUM_WORDS)], album)
}

SEARCH_MAX :: 300 // TIDAL's cap on results

// search_response finds tracks of the long playlist whose title or artist
// has the query in it, ignoring ASCII case. A query that matches nothing
// gets 120 made-up tracks with the query in their titles.
search_response :: proc(query, types: string, offset, limit: int) -> Response {
	needle := strings.to_lower(query, context.temp_allocator)
	Hit :: struct {
		id, album, artist: int,
		title:             string,
		h:                 u32,
	}
	hits := make([dynamic]Hit, 0, 64, context.temp_allocator)
	for i in 0 ..< PLAYLISTS[0].tracks {
		h := track_hash(0, i)
		title, artist := TITLES[(h >> 4) % len(TITLES)], int(h >> 16) % len(ARTISTS)
		if strings.contains(strings.to_lower(title, context.temp_allocator), needle) || strings.contains(strings.to_lower(ARTISTS[artist], context.temp_allocator), needle) {
			append(&hits, Hit{i, int(h >> 8) % 700 + 1, artist, title, h})
		}
		if len(hits) == SEARCH_MAX {
			break
		}
	}
	if len(hits) == 0 && needle != "" {
		for i in 0 ..< 120 {
			h := track_hash(77, i)
			append(&hits, Hit{77_000_000 + i, int(h >> 8) % 700 + 1, int(h >> 16) % len(ARTISTS), fmt.tprintf("%s %d", query, i + 1), h})
		}
	}
	want := proc(types, kind: string) -> bool {
		return types == "" || strings.contains(strings.to_upper(types, context.temp_allocator), kind)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{")
	n := 0
	if want(types, "TRACKS") {
		fmt.sbprintf(&b, `"tracks":{{"limit":%d,"offset":%d,"totalNumberOfItems":%d,"items":[`, limit, offset, len(hits))
		for i in offset ..< min(offset + limit, len(hits)) {
			if i > offset {
				strings.write_byte(&b, ',')
			}
			hit := hits[i]
			write_track_as(&b, hit.id, hit.title, hit.album, hit.artist, hit.id, hit.h)
			n += 1
		}
		strings.write_string(&b, "]},")
	}
	albums := make([dynamic]int, 0, 16, context.temp_allocator)
	artists := make([dynamic]int, 0, 16, context.temp_allocator)
	for hit in hits[:min(len(hits), 50)] {
		if !slice_has(albums[:], hit.album) {
			append(&albums, hit.album)
		}
		if !slice_has(artists[:], hit.artist) {
			append(&artists, hit.artist)
		}
	}
	if want(types, "ALBUMS") {
		strings.write_string(&b, `"albums":{"items":[`)
		for album, i in albums[:min(len(albums), limit)] {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			artist := album % len(ARTISTS)
			fmt.sbprintf(&b, `{{"id":%d,"title":%q,"cover":"%s","numberOfTracks":12,"artist":{{"id":%d,"name":%q}},"artists":[{{"id":%d,"name":%q}}]}}`,
				album, album_title(album), image_id(album), artist + 1, ARTISTS[artist], artist + 1, ARTISTS[artist])
		}
		strings.write_string(&b, "]},")
	}
	if want(types, "ARTISTS") {
		strings.write_string(&b, `"artists":{"items":[`)
		for artist, i in artists[:min(len(artists), limit)] {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"id":%d,"name":%q,"picture":"%s"}}`, artist + 1, ARTISTS[artist], image_id(3000 + artist))
		}
		strings.write_string(&b, "]},")
	}
	if want(types, "PLAYLISTS") {
		strings.write_string(&b, `"playlists":{"items":[`)
		count := 0
		for pl, i in PLAYLISTS {
			if !strings.contains(strings.to_lower(pl.name, context.temp_allocator), needle) {
				continue
			}
			if count > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{{"uuid":"%s","title":%q,"numberOfTracks":%d,"numberOfVideos":0,"type":"USER","creator":{{"id":%d}},"squareImage":"%s","image":"%s"}}`,
				playlist_id(i), pl.name, pl.tracks, USER_ID, image_id(1000 + i), image_id(2000 + i))
			count += 1
		}
		strings.write_string(&b, "]},")
	}
	strings.write_string(&b, `"videos":{"items":[]},"topHit":null}`)
	fmt.printfln("mock: search for \"%s\", types %s, offset %d: %d of %d tracks, %d albums, %d artists", query, types, offset, n, len(hits), len(albums), len(artists))
	return json_response(200, strings.to_string(b))
}

slice_has :: proc(s: []int, v: int) -> bool {
	for x in s {
		if x == v {
			return true
		}
	}
	return false
}

// made_up_tracks lists 12 tracks of an album or an artist's top 20.
made_up_tracks :: proc(album, artist: int, offset, limit: int) -> Response {
	total := 12 if album >= 0 else 20
	b := list_begin(total, offset, limit)
	for i in offset ..< min(offset + limit, total) {
		if i > offset {
			strings.write_byte(&b, ',')
		}
		h := track_hash(album if album >= 0 else 1000 + artist, i)
		al := album if album >= 0 else int(h >> 8) % 700 + 1
		ar := album % len(ARTISTS) if album >= 0 else max(artist - 1, 0) % len(ARTISTS)
		id := 5_000_000 + album * 100 + i if album >= 0 else 6_000_000 + artist * 100 + i
		write_track_as(&b, id, TITLES[(h >> 4) % len(TITLES)], al, ar, i, h)
	}
	strings.write_string(&b, "]}")
	fmt.printfln("mock: %s %d, %d tracks from %d", "album" if album >= 0 else "artist", album if album >= 0 else artist, total, offset)
	return json_response(200, strings.to_string(b))
}

write_album_track :: proc(b: ^strings.Builder, i: int) {
	fmt.sbprintf(b, `{{"id":%d,"title":%q,"duration":%d,"trackNumber":%d,"version":null,"artist":{{"id":7,"name":"The Mock Ensemble"}},"artists":[{{"id":7,"name":"The Mock Ensemble"}}],"album":{{"id":%d,"title":"Live at the Mock","cover":"%s"}}}}`,
		ALBUM_TRACK_ID + i, ALBUM_TITLES[i], ALBUM_LENGTHS[i] / RATE, i + 1, ALBUM_ID, image_id(ALBUM_ID))
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
