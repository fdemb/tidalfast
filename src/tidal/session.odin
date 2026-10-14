package tidal

import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"
import curl "vendor:curl"

// Session is the entry point. Create it with
// session_create; it is safe to use from several threads once logged in.
//
// Memory: every proc that returns data takes an `allocator` and allocates all
// of the result (strings, slices, nested models) with it. Pass an arena and
// free it when the UI no longer needs the data. Scratch memory (HTTP bodies,
// parsed JSON) comes from context.temp_allocator and is released before the
// proc returns, so don't pass context.temp_allocator as the result allocator.
Session :: struct {
	config:               Config,
	user_agent:           string,
	client_version:       string,

	// Login state. Guarded by `mutex`; read it with session_auth from other
	// threads.
	token_type:           string,
	access_token:         string,
	refresh_token:        string,
	expiry_time:          Maybe(time.Time),
	session_id:           string,
	country_code:         string,
	locale:               string,
	is_pkce:              bool,
	user:                 Maybe(User),

	mutex:                sync.Mutex,
	refresh_mutex:        sync.Mutex,

	backoff_mutex:        sync.Mutex,
	backoff_until:        time.Tick,
	backoff_reason:       string,

	// The (client_id, client_secret) in use before session_client_enable_hires.
	device_client_id:     string,
	device_client_secret: string,

	curl_mutex:           sync.Mutex,
	curl_pool:            [dynamic]^curl.CURL,

	allocator:            mem.Allocator, // token strings, freed when replaced
	arena:                vmem.Arena,    // config and user strings, freed by session_destroy
}

session_create :: proc(
	quality := DEFAULT_QUALITY,
	video_quality := DEFAULT_VIDEO_QUALITY,
	item_limit := 1000,
	alac := true,
	backoff := true,
	allocator := context.allocator,
) -> ^Session {
	s := new(Session, allocator)
	s.allocator = allocator
	if err := vmem.arena_init_growing(&s.arena); err != nil {
		log.panicf("tidal: failed to reserve session arena: %v", err)
	}
	arena := vmem.arena_allocator(&s.arena)
	s.config = config_make(quality, video_quality, item_limit, alac, backoff, arena)
	// More Android User-Agents here: https://user-agents.net/browsers/android
	s.user_agent = "Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36"
	s.client_version = "2025.7.16"
	s.curl_pool.allocator = allocator
	return s
}

session_destroy :: proc(s: ^Session) {
	if s == nil {
		return
	}
	curl_pool_destroy(s)
	for str in ([]string{s.token_type, s.access_token, s.refresh_token, s.session_id, s.country_code, s.locale, s.backoff_reason}) {
		delete(str, s.allocator)
	}
	vmem.arena_destroy(&s.arena)
	free(s, s.allocator)
}

// Auth is a copy of the session's login state.
Auth :: struct {
	token_type:    string,
	access_token:  string,
	refresh_token: string,
	expiry_time:   Maybe(time.Time),
	session_id:    string,
	country_code:  string,
	locale:        string,
	is_pkce:       bool,
	user_id:       i64, // 0 when no user is loaded
	user_kind:     User_Kind,
}

// session_auth copies the login state, e.g. to persist it.
session_auth :: proc(s: ^Session, allocator := context.allocator) -> Auth {
	sync.guard(&s.mutex)
	a := Auth {
		token_type    = strings.clone(s.token_type, allocator),
		access_token  = strings.clone(s.access_token, allocator),
		refresh_token = strings.clone(s.refresh_token, allocator),
		expiry_time   = s.expiry_time,
		session_id    = strings.clone(s.session_id, allocator),
		country_code  = strings.clone(s.country_code, allocator),
		locale        = strings.clone(s.locale, allocator),
		is_pkce       = s.is_pkce,
	}
	if u, ok := s.user.?; ok {
		a.user_id = u.id
		a.user_kind = u.kind
	}
	return a
}

// session_user returns a copy of the logged in user.
session_user :: proc(s: ^Session, allocator := context.allocator) -> (user: User, ok: bool) {
	sync.guard(&s.mutex)
	u := s.user.? or_return
	return clone_user(u, allocator), true
}

session_set_quality :: proc(s: ^Session, quality: Quality) {
	sync.guard(&s.mutex)
	s.config.quality = quality
}

session_set_video_quality :: proc(s: ^Session, quality: Video_Quality) {
	sync.guard(&s.mutex)
	s.config.video_quality = quality
}

// session_client_enable_hires swaps config.client_id/client_secret for the
// PKCE pair, the only one entitled to hi-res streams. The device login keeps
// using the original client, as TIDAL rejects the PKCE client there.
session_client_enable_hires :: proc(s: ^Session) {
	sync.guard(&s.mutex)
	if s.config.client_id != s.config.client_id_pkce {
		s.device_client_id = s.config.client_id
		s.device_client_secret = s.config.client_secret
	}
	s.config.client_id = s.config.client_id_pkce
	s.config.client_secret = s.config.client_secret_pkce
}

@(private)
device_client_credentials :: proc(s: ^Session) -> (id, secret: string) {
	sync.guard(&s.mutex)
	if s.device_client_id != "" {
		return s.device_client_id, s.device_client_secret
	}
	return s.config.client_id, s.config.client_secret
}

// Replaces an owned token string. Caller holds s.mutex.
@(private)
set_owned :: proc(s: ^Session, field: ^string, value: string) {
	if field^ == value {
		return
	}
	delete(field^, s.allocator)
	field^ = strings.clone(value, s.allocator)
}

// Stores the logged in user. Caller holds s.mutex.
@(private)
set_user :: proc(s: ^Session, u: User) {
	s.user = clone_user(u, vmem.arena_allocator(&s.arena))
}

@(private)
clone_user :: proc(u: User, allocator: mem.Allocator) -> User {
	c := u
	c.name = strings.clone(u.name, allocator)
	c.first_name = strings.clone(u.first_name, allocator)
	c.last_name = strings.clone(u.last_name, allocator)
	c.picture_id = strings.clone(u.picture_id, allocator)
	c.username = strings.clone(u.username, allocator)
	c.email = strings.clone(u.email, allocator)
	return c
}

@(private)
logged_in_user_id :: proc(s: ^Session) -> (id: i64, err: Error) {
	sync.guard(&s.mutex)
	u, ok := s.user.?
	if !ok || u.id == 0 {
		return 0, make_error(.Not_Logged_In, "No user is logged in")
	}
	return u.id, nil
}
