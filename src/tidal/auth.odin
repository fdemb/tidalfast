package tidal

import "base:runtime"
import "core:c/libc"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

Print_Proc :: proc(text: string)
Read_Line_Proc :: proc(prompt: string, allocator := context.allocator) -> string

default_print :: proc(text: string) {
	fmt.println(text)
}

// default_read_line prints prompt and reads one line from stdin.
default_read_line :: proc(prompt: string, allocator := context.allocator) -> string {
	fmt.print(prompt)
	libc.fflush(libc.stdout)
	buf: [4096]u8
	if libc.fgets(cast([^]byte)&buf[0], len(buf), libc.stdin) == nil {
		return ""
	}
	line := string(cstring(&buf[0]))
	return strings.clone(strings.trim_right(line, "\r\n"), allocator)
}

// ---- Token handling ----

// token_refresh gets a new access token with refresh_token and stores it.
// TIDAL may rotate the refresh token; the new one is kept.
token_refresh :: proc(s: ^Session, refresh_token: string) -> (ok: bool, err: Error) {
	return refresh_tokens(s, refresh_token, session_epoch(s))
}

// refresh_tokens is token_refresh for the login of auth epoch epoch. If the
// login was cleared since, the new tokens are dropped. Only TIDAL refusing
// the refresh token means the login is gone (.Authentication, see
// is_refresh_refused). A rate limit, a held back or cancelled request comes
// back as that, and any other failure, unreachable network included, as
// .Refresh_Failed, which keeps the tokens.
@(private)
refresh_tokens :: proc(s: ^Session, refresh_token: string, epoch: u64) -> (ok: bool, err: Error) {
	client_id, client_secret: string
	{
		// session_client_enable_hires swaps these under the lock.
		sync.guard(&s.mutex)
		client_id = s.config.client_id_pkce if s.is_pkce else s.config.client_id
		client_secret = s.config.client_secret_pkce if s.is_pkce else s.config.client_secret
	}
	form := []Param {
		{"grant_type", "refresh_token"},
		{"refresh_token", refresh_token},
		{"client_id", client_id},
		{"client_secret", client_secret},
	}
	resp, obj, perr := post_form(s, s.config.api_oauth2_token, form, epoch, context.temp_allocator)
	if e, failed := perr.?; failed {
		if e.kind == .Network {
			e.kind = .Refresh_Failed
		}
		return false, e
	}
	if is_rate_limit(resp) {
		return false, http_error(resp)
	}
	if resp.status != 200 {
		detail := fmt.tprintf("%s: %s", jstr(obj, "error"), jstr(obj, "error_description"))
		if is_refresh_refused(resp.status, jstr(obj, "error")) {
			return false, make_error(.Authentication, "Authentication failed", resp.status, detail = detail)
		}
		return false, make_error(.Refresh_Failed, "Token refresh failed", resp.status, detail = detail)
	}
	if obj == nil {
		return false, make_error(.Bad_Response, "Token response is not valid JSON", resp.status)
	}

	{
		sync.guard(&s.mutex)
		if s.auth_epoch != epoch {
			return false, make_error(.Cancelled, "The login was cleared during the refresh")
		}
		set_owned(s, &s.access_token, jstr(obj, "access_token"))
		s.expiry_time = time.time_add(time.now(), time.Duration(ji64(obj, "expires_in")) * time.Second)
		set_owned(s, &s.token_type, jstr(obj, "token_type"))
		// When the field is absent the existing refresh token is still valid.
		if new_refresh := jstr(obj, "refresh_token"); new_refresh != "" {
			set_owned(s, &s.refresh_token, new_refresh)
		}
	}
	notify_auth_change(s)
	return true, nil
}

// is_refresh_refused says whether a token endpoint error means the refresh
// token will never work again: 400 or 401 with invalid_grant, which RFC
// 6749 section 5.2 sends for a refresh token that's expired, revoked or
// rotated away. The reference clients know no TIDAL-specific rejection
// beyond it. Anything else, such as a 408 or a 400 with another code, may
// be temporary, so the caller keeps the tokens and tries again.
@(private = "file")
is_refresh_refused :: proc(status: int, oauth_error: string) -> bool {
	return (status == 400 || status == 401) && oauth_error == "invalid_grant"
}

// Reads sessionId, countryCode and the user after the tokens are set.
@(private = "file")
finish_login :: proc(s: ^Session) -> (err: Error) {
	scratch_begin(context.allocator)
	obj := request_object(s, {method = .GET, path = "sessions"}, context.temp_allocator) or_return
	user_id := ji64(obj, "userId")
	{
		sync.guard(&s.mutex)
		set_owned(s, &s.session_id, jstr(obj, "sessionId"))
		set_owned(s, &s.country_code, jstr(obj, "countryCode"))
		set_owned(s, &s.locale, "en_US") // TODO: get locale from system configuration
	}
	u := user_get(s, user_id, context.temp_allocator) or_return
	sync.guard(&s.mutex)
	set_user(s, u)
	return nil
}

// Stores the tokens of an OAuth token response, then loads the session.
// Nothing is stored if the login was cleared after epoch.
@(private = "file")
process_auth_token :: proc(s: ^Session, obj: json.Object, is_pkce: bool, epoch: u64) -> Error {
	{
		sync.guard(&s.mutex)
		if s.auth_epoch != epoch {
			return make_error(.Cancelled, "The login was cleared during the login")
		}
		set_owned(s, &s.access_token, jstr(obj, "access_token"))
		s.expiry_time = time.time_add(time.now(), time.Duration(ji64(obj, "expires_in")) * time.Second)
		set_owned(s, &s.refresh_token, jstr(obj, "refresh_token"))
		set_owned(s, &s.token_type, jstr(obj, "token_type"))
		// Before finish_login: if that fails, the tokens are kept and a
		// retry must still refresh them with the client they're for.
		s.is_pkce = is_pkce
	}
	finish_login(s) or_return
	notify_auth_change(s)
	return nil
}

// load_oauth_session logs in with tokens from an earlier OAuth login.
// Expired access tokens are refreshed automatically when refresh_token is
// given.
load_oauth_session :: proc(
	s: ^Session,
	token_type: string,
	access_token: string,
	refresh_token := "",
	expiry_time: Maybe(time.Time) = nil,
	is_pkce := false,
) -> Error {
	{
		sync.guard(&s.mutex)
		set_owned(s, &s.token_type, token_type)
		set_owned(s, &s.access_token, access_token)
		set_owned(s, &s.refresh_token, refresh_token)
		s.expiry_time = expiry_time
		s.is_pkce = is_pkce
	}
	return finish_login(s)
}

// load_session logs in with the session id of an earlier login. Without
// country_code or user_id they are fetched from TIDAL. An invalid or expired
// id may still succeed here; verify with check_login.
load_session :: proc(s: ^Session, session_id: string, country_code := "", user_id: i64 = 0) -> (err: Error) {
	scratch_begin(context.allocator)
	if !is_uuid(session_id) {
		log.error("Session id did not have a valid UUID format")
		return make_error(.Invalid_Argument, "Session id did not have a valid UUID format")
	}
	sync.mutex_lock(&s.mutex)
	set_owned(s, &s.session_id, session_id)
	sync.mutex_unlock(&s.mutex)
	country, uid := country_code, user_id
	if uid == 0 || country == "" {
		obj := request_object(s, {method = .GET, path = "sessions"}, context.temp_allocator) or_return
		country = jstr(obj, "countryCode")
		uid = ji64(obj, "userId")
	}
	sync.mutex_lock(&s.mutex)
	set_owned(s, &s.country_code, country)
	sync.mutex_unlock(&s.mutex)
	u := user_get(s, uid, context.temp_allocator) or_return
	sync.guard(&s.mutex)
	set_user(s, u)
	return nil
}

@(private = "file")
is_uuid :: proc(s: string) -> bool {
	str := strings.trim_prefix(strings.trim_suffix(s, "}"), "{")
	str = strings.trim_prefix(str, "urn:uuid:")
	hex_count := 0
	for c in str {
		switch c {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
			hex_count += 1
		case '-':
		case:
			return false
		}
	}
	return hex_count == 32
}

// check_login reports whether the session is valid.
check_login :: proc(s: ^Session) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	auth := session_auth(s, context.temp_allocator)
	if auth.user_id == 0 || auth.session_id == "" {
		return false
	}
	resp, err := basic_request(s, {method = .GET, path = fmt.tprintf("users/%d/subscription", auth.user_id)}, context.temp_allocator)
	return err == nil && http_ok(resp)
}

// ---- Device (limited input) login ----

// login_device_start asks TIDAL for a device code. Show the user
// verification_uri_complete, then call login_device_wait.
login_device_start :: proc(s: ^Session, allocator := context.allocator) -> (link: Link_Login, err: Error) {
	scratch_begin(allocator)
	client_id, _ := device_client_credentials(s)
	form := []Param{{"client_id", client_id}, {"scope", "r_usr w_usr w_sub"}}
	resp, obj := post_form(s, s.config.api_device_auth, form, session_epoch(s), context.temp_allocator) or_return
	if !http_ok(resp) {
		if !is_rate_limit(resp) {
			log.errorf("Login failed: %s", body_prefix(resp, 500))
		}
		return {}, http_error(resp)
	}
	if obj == nil {
		return {}, make_error(.Bad_Response, "Device authorization response is not valid JSON", resp.status)
	}
	p := Parser {
		allocator = allocator,
	}
	return Link_Login {
			expires_in = jf64(obj, "expiresIn"),
			user_code = pstr(&p, obj, "userCode"),
			verification_uri = pstr(&p, obj, "verificationUri"),
			verification_uri_complete = pstr(&p, obj, "verificationUriComplete"),
			interval = jf64(obj, "interval"),
			device_code = pstr(&p, obj, "deviceCode"),
		},
		nil
}

// Added to the polling interval each time TIDAL answers slow_down, in
// seconds, as RFC 8628 says.
SLOW_DOWN_STEP :: 5

// login_device_wait polls TIDAL until the user approves the device code,
// then logs in. With until_expiry = false it checks once. Blocks; run it on
// a worker thread in a UI. Setting cancel^ to true (atomically) stops it.
//
// It waits link.interval seconds between polls and adds SLOW_DOWN_STEP to
// link.interval when TIDAL asks it to slow down, so a caller that polls
// again after an error keeps the slower pace. It returns .Timeout when the
// code expired, .Authentication if the user denied it, a rate limit as
// .Too_Many_Requests or .Abuse_Detected (with the backoff started), and
// transport errors as they come.
login_device_wait :: proc(s: ^Session, link: ^Link_Login, until_expiry := true, cancel: ^bool = nil) -> (err: Error) {
	scratch_begin(context.allocator)
	epoch := session_epoch(s)
	expiry := link.expires_in if until_expiry else 1
	client_id, client_secret := device_client_credentials(s)
	form := []Param {
		{"client_id", client_id},
		{"client_secret", client_secret},
		{"device_code", link.device_code},
		{"grant_type", "urn:ietf:params:oauth:grant-type:device_code"},
		{"scope", "r_usr w_usr w_sub"},
	}
	if link.interval <= 0 {
		link.interval = 2
	}

	for expiry > 0 {
		resp, obj := post_form(s, s.config.api_oauth2_token, form, epoch, context.temp_allocator) or_return
		if http_ok(resp) && obj != nil {
			return process_auth_token(s, obj, false, epoch)
		}
		if is_rate_limit(resp) {
			return http_error(resp)
		}
		// authorization_pending and anything unknown: keep polling, as
		// other TIDAL clients do.
		switch jstr(obj, "error") {
		case "slow_down":
			link.interval += SLOW_DOWN_STEP
		case "access_denied":
			return make_error(.Authentication, "The login was denied", resp.status)
		case "expired_token":
			// Requests take time, so the expiry countdown drifts. Stop when
			// TIDAL says the code expired.
			return make_error(.Timeout, "You took too long to log in")
		}
		if !until_expiry {
			break
		}
		deadline := time.tick_add(time.tick_now(), time.Duration(link.interval * f64(time.Second)))
		for time.tick_diff(time.tick_now(), deadline) > 0 {
			if (cancel != nil && sync.atomic_load(cancel)) || sync.atomic_load(&s.abort) || session_epoch(s) != epoch {
				return make_error(.Cancelled, "Login cancelled")
			}
			time.sleep(100 * time.Millisecond)
		}
		expiry -= link.interval
	}
	return make_error(.Timeout, "You took too long to log in")
}

// login_oauth_simple runs the device login, showing the link with print_fn.
login_oauth_simple :: proc(s: ^Session, print_fn: Print_Proc = default_print) -> (err: Error) {
	scratch_begin(context.allocator)
	link := login_device_start(s, context.temp_allocator) or_return
	print_fn(fmt.tprintf("Visit https://%s to log in, the code will expire in %v seconds", link.verification_uri_complete, int(link.expires_in)))
	return login_device_wait(s, &link)
}

// ---- PKCE login ----

// pkce_login_url returns the URL to log in with in a web browser. PKCE is
// the only login with access to hi-res (up to 24-bit, 192 kHz) FLAC.
pkce_login_url :: proc(s: ^Session, allocator := context.allocator) -> string {
	params := []Param {
		{"response_type", "code"},
		{"redirect_uri", s.config.pkce_uri_redirect},
		{"client_id", s.config.client_id_pkce},
		{"lang", "EN"},
		{"appMode", "android"},
		{"client_unique_key", s.config.client_unique_key},
		{"code_challenge", s.config.code_challenge},
		{"code_challenge_method", "S256"},
		{"restrict_signup", "true"},
	}
	return fmt.aprintf("%s?%s", s.config.api_pkce_auth, encode_params(params, context.temp_allocator), allocator = allocator)
}

// login_pkce_complete finishes a PKCE login with the URL of the "Oops" page
// the browser was redirected to after login.
login_pkce_complete :: proc(s: ^Session, url_redirect: string) -> (err: Error) {
	scratch_begin(context.allocator)
	// w_usr=WRITE_USR, r_usr=READ_USR_DATA, w_sub=WRITE_SUBSCRIPTION
	SCOPE_DEFAULT :: "r_usr+w_usr+w_sub"

	code := pkce_redirect_code(url_redirect, s.config.pkce_uri_redirect) or_return
	form := []Param {
		{"code", code},
		{"client_id", s.config.client_id_pkce},
		{"grant_type", "authorization_code"},
		{"redirect_uri", s.config.pkce_uri_redirect},
		{"scope", SCOPE_DEFAULT},
		{"code_verifier", s.config.code_verifier},
		{"client_unique_key", s.config.client_unique_key},
	}
	epoch := session_epoch(s)
	resp, obj := post_form(s, s.config.api_oauth2_token, form, epoch, context.temp_allocator) or_return
	if !http_ok(resp) {
		if !is_rate_limit(resp) {
			log.errorf("Login failed: %s", body_prefix(resp, 500))
		}
		if resp.status == 400 || resp.status == 401 {
			// invalid_grant: a code used twice, too old, or for another verifier.
			return make_error(.Authentication, "TIDAL didn't accept this login. Log in again for a new address.", resp.status, detail = jstr(obj, "error"))
		}
		return http_error(resp)
	}
	if obj == nil {
		return make_error(.Authentication, "Wrong one-time authorization code", resp.status)
	}
	return process_auth_token(s, obj, true, epoch)
}

// pkce_redirect_code takes the authorization code out of the address TIDAL
// redirected the browser to after a PKCE login. The address must start
// with redirect_uri, the one the login URL named. Spaces and quotes around
// it, as a copy from a browser's address bar may bring, are dropped.
pkce_redirect_code :: proc(url_redirect: string, redirect_uri: string) -> (code: string, err: Error) {
	url := strings.trim(url_redirect, " \t\r\n\"'<>")
	if !strings.has_prefix(url, redirect_uri) || (len(url) > len(redirect_uri) && url[len(redirect_uri)] != '?' && url[len(redirect_uri)] != '/') {
		return "", make_error(.Invalid_Argument, "That isn't the address TIDAL sends you to after the login", detail = url)
	}
	if e, has_error := query_value(url, "error"); has_error {
		return "", make_error(.Authentication, "The login was denied", detail = e)
	}
	c, found := query_value(url, "code")
	if !found || c == "" {
		return "", make_error(.Invalid_Argument, "The address has no login code in it", detail = url)
	}
	return c, nil
}

@(private = "file")
query_value :: proc(url: string, key: string) -> (value: string, found: bool) {
	q := strings.index_byte(url, '?')
	if q < 0 {
		return "", false
	}
	query := url[q + 1:]
	if hash := strings.index_byte(query, '#'); hash >= 0 {
		query = query[:hash]
	}
	for part in strings.split_iterator(&query, "&") {
		k, _, v := strings.partition(part, "=")
		if k == key {
			decoded, ok := net.percent_decode(v, context.temp_allocator)
			return decoded if ok else v, true
		}
	}
	return "", false
}

// login_pkce runs the PKCE login interactively: it prints the login URL and
// reads the redirect URL with read_line.
login_pkce :: proc(s: ^Session, print_fn: Print_Proc = default_print, read_line: Read_Line_Proc = default_read_line) -> (err: Error) {
	scratch_begin(context.allocator)
	url := pkce_login_url(s, context.temp_allocator)
	print_fn("READ CAREFULLY!")
	print_fn("---------------")
	print_fn(
		"You need to open this link and login with your username and password. " +
		"Afterwards you will be redirected to an 'Oops' page. " +
		"To complete the login you must copy the URL from this 'Oops' page and paste it to the input field.",
	)
	print_fn(url)
	redirect := read_line("Paste 'Ooops' page URL here and press <ENTER>:", context.temp_allocator)
	return login_pkce_complete(s, strings.trim_space(redirect))
}

// ---- Session file ----

// session_save_file writes the login state as JSON. The file is only
// readable by the current user.
session_save_file :: proc(s: ^Session, path: string) -> (err: Error) {
	scratch_begin(context.allocator)
	if !check_login(s) {
		return make_error(.Not_Logged_In, "No valid session to save")
	}
	a := session_auth(s, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	field :: proc(b: ^strings.Builder, key: string, value: string, null_if_empty := true) {
		fmt.sbprintf(b, "%q: {{\"data\": ", key)
		if value == "" && null_if_empty {
			strings.write_string(b, "null")
		} else {
			write_json_string(b, value)
		}
		strings.write_string(b, "}")
	}
	strings.write_byte(&b, '{')
	field(&b, "token_type", a.token_type)
	strings.write_string(&b, ", ")
	field(&b, "session_id", a.session_id)
	strings.write_string(&b, ", ")
	field(&b, "access_token", a.access_token)
	strings.write_string(&b, ", ")
	field(&b, "refresh_token", a.refresh_token)
	fmt.sbprintf(&b, ", \"is_pkce\": {{\"data\": %v}}, ", a.is_pkce)
	expiry := ""
	if t, ok := a.expiry_time.?; ok {
		expiry = format_datetime_naive(t, context.temp_allocator)
	}
	field(&b, "expiry_time", expiry)
	strings.write_byte(&b, '}')

	return write_private_file(path, transmute([]u8)strings.to_string(b))
}

// Writes data to a new file only the current user can read, then renames it
// over path. An existing file's permissions never apply to the tokens, and a
// crash leaves either the old file or the new one.
@(private = "file")
write_private_file :: proc(path: string, data: []u8) -> Error {
	key: u64
	crypto.rand_bytes(mem.ptr_to_bytes(&key))
	tmp_path := fmt.tprintf("%s.tmp-%x", path, key)

	f, oerr := os.open(tmp_path, os.O_WRONLY | os.O_CREATE | os.O_EXCL, {.Read_User, .Write_User})
	if oerr != nil {
		return make_error(.Io, "Could not write session file", detail = fmt.tprint(oerr))
	}
	_, werr := os.write(f, data)
	if werr == nil {
		werr = os.sync(f)
	}
	if cerr := os.close(f); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.rename(tmp_path, path)
	}
	if werr != nil {
		_ = os.remove(tmp_path)
		return make_error(.Io, "Could not write session file", detail = fmt.tprint(werr))
	}
	return nil
}

// session_load_file logs in with a file written by session_save_file or by
// another client using the same format.
session_load_file :: proc(s: ^Session, path: string) -> (err: Error) {
	scratch_begin(context.allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		log.infof("Could not load session from %s: %v", path, rerr)
		return make_error(.Io, "Could not read session file", detail = fmt.tprint(rerr))
	}
	log.infof("Loading session from %s...", path)
	v, jerr := json.parse(data, .JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
	if jerr != nil || !ok {
		return make_error(.Bad_Response, "Session file is not valid JSON")
	}
	get :: proc(obj: json.Object, key: string) -> json.Value {
		inner, _ := jobj(obj, key)
		return inner["data"]
	}
	str :: proc(v: json.Value) -> string {
		s, _ := v.(json.String)
		return s
	}
	expiry: Maybe(time.Time)
	if e := str(get(obj, "expiry_time")); e != "" {
		if t, tok := parse_datetime(e); tok {
			expiry = t
		} else {
			log.infof("Ignoring invalid expiry_time in %s", path)
		}
	}
	// Sessions logged in by session id alone have no OAuth tokens.
	if str(get(obj, "access_token")) == "" {
		session_id := str(get(obj, "session_id"))
		if session_id == "" {
			return make_error(.Not_Logged_In, "Session file has neither an access token nor a session id")
		}
		return load_session(s, session_id)
	}
	is_pkce, _ := get(obj, "is_pkce").(json.Boolean)
	return load_oauth_session(
		s,
		str(get(obj, "token_type")),
		str(get(obj, "access_token")),
		str(get(obj, "refresh_token")),
		expiry,
		bool(is_pkce),
	)
}

// login_session_file logs in from a session file, or runs a new login
// (device, or PKCE with do_pkce) and saves it. Returns whether the session
// is valid afterwards.
login_session_file :: proc(s: ^Session, path: string, do_pkce := false, print_fn: Print_Proc = default_print) -> (ok: bool, err: Error) {
	_ = session_load_file(s, path)

	// Session could not be loaded, attempt to create a new session
	if !check_login(s) {
		if do_pkce {
			log.info("Creating new session (PKCE)...")
			login_pkce(s, print_fn) or_return
		} else {
			log.info("Creating new session (OAuth)...")
			login_oauth_simple(s, print_fn) or_return
		}
	}

	if check_login(s) {
		log.info("TIDAL Login OK")
		session_save_file(s, path) or_return
		return true, nil
	}
	log.info("TIDAL Login KO")
	return false, nil
}
