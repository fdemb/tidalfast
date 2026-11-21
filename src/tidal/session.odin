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
	is_pkce:              bool,
	user:                 Maybe(User),

	mutex:                sync.Mutex,
	refresh_mutex:        sync.Mutex,
	// The last token refresh, written under refresh_mutex. refresh_count
	// goes up by one per attempt and is read atomically, so a request can
	// tell whether one finished after it started. refresh_epoch is the auth
	// epoch of the login it refreshed.
	refresh_count:        u64,
	refresh_err:          Error,
	refresh_ended:        time.Tick,
	refresh_epoch:        u64,

	backoff_mutex:        sync.Mutex,
	backoff_until:        time.Tick,
	backoff_reason:       string,

	// The (client_id, client_secret) in use before session_client_enable_hires.
	device_client_id:     string,
	device_client_secret: string,

	curl_mutex:           sync.Mutex,
	curl_pool:            [dynamic]^curl.CURL,

	// Set atomically (session_abort) to make requests in flight and
	// login_device_wait fail with .Cancelled.
	abort:                bool,

	// Goes up by one each time session_clear_auth forgets the login.
	// Requests remember the epoch they started in and fail with .Cancelled
	// once it moves on. Written under `mutex`, read atomically.
	auth_epoch:           u64,

	// The login attempt under way, see session_set_login_attempt. Under
	// `mutex`.
	login_attempt:        u64,

	// Called after a login or token refresh changed the tokens, on the
	// thread that changed them. Refreshes run one at a time, so calls never
	// overlap. Set it before the session is shared between threads.
	on_auth_change:       proc(s: ^Session, data: rawptr),
	on_auth_change_data:  rawptr,

	allocator:            mem.Allocator, // token strings, freed when replaced
	arena:                vmem.Arena,    // config and user strings, freed by session_destroy
}

session_create :: proc(
	quality := DEFAULT_QUALITY,
	video_quality := DEFAULT_VIDEO_QUALITY,
	item_limit := 1000,
	alac := true,
	backoff := true,
	locale := "",
	allocator := context.allocator,
) -> ^Session {
	s := new(Session, allocator)
	s.allocator = allocator
	if err := vmem.arena_init_growing(&s.arena); err != nil {
		log.panicf("tidal: failed to reserve session arena: %v", err)
	}
	arena := vmem.arena_allocator(&s.arena)
	s.config = config_make(quality, video_quality, item_limit, alac, backoff, arena)
	if locale != "" {
		s.config.locale = strings.clone(locale, arena)
	}
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
	for str in ([]string{s.token_type, s.access_token, s.refresh_token, s.session_id, s.country_code, s.backoff_reason}) {
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
	is_pkce:       bool,
	client_id:     string, // the OAuth client the tokens are for, which refreshes them
	user_id:       i64, // 0 when no user is loaded
	user_kind:     User_Kind,
	epoch:         u64, // the session's auth_epoch; session_restore ignores it
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
		is_pkce       = s.is_pkce,
		epoch         = s.auth_epoch,
	}
	if s.is_pkce {
		a.client_id = strings.clone(s.config.client_id_pkce, allocator)
	} else if s.device_client_id != "" {
		a.client_id = strings.clone(s.device_client_id, allocator)
	} else {
		a.client_id = strings.clone(s.config.client_id, allocator)
	}
	if u, ok := s.user.?; ok {
		a.user_id = u.id
		a.user_kind = u.kind
	}
	return a
}

// session_restore puts back login state from session_auth without asking
// TIDAL, e.g. tokens kept from an earlier run. The user is known only by id
// and kind. An expired access token is refreshed by the first request.
session_restore :: proc(s: ^Session, a: Auth) {
	sync.guard(&s.mutex)
	set_owned(s, &s.token_type, a.token_type)
	set_owned(s, &s.access_token, a.access_token)
	set_owned(s, &s.refresh_token, a.refresh_token)
	set_owned(s, &s.session_id, a.session_id)
	set_owned(s, &s.country_code, a.country_code)
	s.expiry_time = a.expiry_time
	s.is_pkce = a.is_pkce
	s.user = nil
	if a.user_id != 0 {
		set_user(s, User{kind = a.user_kind, id = a.user_id})
	}
}

// session_clear_auth forgets the login: tokens, session id and user.
// Requests, refreshes and device logins started before it fail with
// .Cancelled, in flight or not, and a refresh that finishes anyway doesn't
// store its tokens. Safe from any thread.
session_clear_auth :: proc(s: ^Session) {
	sync.guard(&s.mutex)
	for f in ([]^string{&s.token_type, &s.access_token, &s.refresh_token, &s.session_id, &s.country_code}) {
		delete(f^, s.allocator)
		f^ = ""
	}
	s.expiry_time = nil
	s.is_pkce = false
	s.user = nil
	sync.atomic_store(&s.auth_epoch, s.auth_epoch + 1)
}

// session_epoch returns the session's auth epoch, see session_clear_auth.
session_epoch :: proc(s: ^Session) -> u64 {
	return sync.atomic_load(&s.auth_epoch)
}

// session_set_login_attempt names the login attempt now under way. A
// login given another attempt number drops its tokens before they reach
// the session, so a device-code poll answered after the user moved on to
// the PKCE login can't replace that login.
session_set_login_attempt :: proc(s: ^Session, attempt: u64) {
	sync.guard(&s.mutex)
	s.login_attempt = attempt
}

session_login_attempt :: proc(s: ^Session) -> u64 {
	sync.guard(&s.mutex)
	return s.login_attempt
}

// session_abort makes requests in flight, and any made while it's on, fail
// with .Cancelled. Safe from any thread.
session_abort :: proc(s: ^Session, on: bool) {
	sync.atomic_store(&s.abort, on)
}

@(private)
notify_auth_change :: proc(s: ^Session) {
	if s.on_auth_change != nil {
		s.on_auth_change(s, s.on_auth_change_data)
	}
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

// session_is_pkce says whether the login came from the PKCE client, which
// TIDAL gives hi-res streams.
session_is_pkce :: proc(s: ^Session) -> bool {
	sync.guard(&s.mutex)
	return s.is_pkce
}

// session_set_pkce_state replaces the PKCE verifier and client key that
// config_make generated.
session_set_pkce_state :: proc(s: ^Session, code_verifier, client_unique_key: string) {
	sync.guard(&s.mutex)
	a := vmem.arena_allocator(&s.arena)
	s.config.code_verifier = strings.clone(code_verifier, a)
	s.config.client_unique_key = strings.clone(client_unique_key, a)
	s.config.code_challenge = pkce_challenge(code_verifier, a)
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
