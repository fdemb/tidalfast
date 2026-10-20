package tidal

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

// Backoff after a rate limit (HTTP 429) without a Retry-After header, in seconds.
RATE_LIMIT_BACKOFF :: 60
// Backoff after an anti-abuse rejection without a Retry-After header, in seconds.
ABUSE_BACKOFF :: 30 * 60
// Refresh the access token this long before it expires, so requests don't race the expiry.
TOKEN_EXPIRY_MARGIN :: 60 * time.Second
// How long a failed token refresh answers the requests that waited for it,
// instead of each trying again.
REFRESH_FAILURE_SHARED :: 5 * time.Second

Param :: struct {
	key:   string,
	value: string,
}

Request :: struct {
	method:   Method,
	path:     string, // relative to base_url, or an absolute URL
	params:   []Param, // query string; override the default sessionId/countryCode/limit
	data:     []Param, // form body
	headers:  []string, // "Name: value"
	base_url: string, // defaults to config.api_v1_location
}

// backoff_remaining returns the seconds left of the current backoff, 0 if
// requests are not being held back.
backoff_remaining :: proc(s: ^Session) -> f64 {
	sync.guard(&s.backoff_mutex)
	if s.backoff_until == {} {
		return 0
	}
	return max(0, -time.duration_seconds(time.tick_since(s.backoff_until)))
}

// backoff_state returns when the current backoff ends and why, {} and ""
// for none, so it can be carried over to another session with
// backoff_restore.
backoff_state :: proc(s: ^Session, allocator := context.allocator) -> (until: time.Tick, reason: string) {
	sync.guard(&s.backoff_mutex)
	return s.backoff_until, strings.clone(s.backoff_reason, allocator)
}

// backoff_restore starts a backoff that ends at until, unless the session
// already has one that ends later.
backoff_restore :: proc(s: ^Session, until: time.Tick, reason: string) {
	if until == {} {
		return
	}
	sync.guard(&s.backoff_mutex)
	if s.backoff_until == {} || time.tick_diff(s.backoff_until, until) > 0 {
		s.backoff_until = until
		delete(s.backoff_reason, s.allocator)
		s.backoff_reason = strings.clone(reason, s.allocator)
	}
}

@(private = "file")
check_backoff :: proc(s: ^Session) -> Error {
	sync.guard(&s.backoff_mutex)
	if s.backoff_until == {} {
		return nil
	}
	remaining := -time.duration_seconds(time.tick_since(s.backoff_until))
	if remaining <= 0 {
		return nil
	}
	e := Api_Error {
		kind              = .Backing_Off,
		message           = "Backing off from TIDAL",
		retry_after       = -1,
		seconds_remaining = remaining,
	}
	set_detail(&e, s.backoff_reason)
	return e
}

// Hold back further requests after a rate limit or anti-abuse response.
// Requests made while TIDAL is limiting or suspecting the account only
// prolong it, and can lead to a permanent ban.
@(private = "file")
start_backoff_if_needed :: proc(s: ^Session, resp: Http_Response) {
	if !s.config.backoff {
		return
	}
	seconds: int
	reason: string
	if resp.status == 429 {
		seconds = resp.retry_after if resp.retry_after > 0 else RATE_LIMIT_BACKOFF
		reason = "rate limited (HTTP 429)"
	} else if is_abuse_response(resp) {
		seconds = resp.retry_after if resp.retry_after > 0 else ABUSE_BACKOFF
		reason = fmt.tprintf("abuse detected (HTTP 403): %s", body_prefix(resp, 200))
	} else {
		return
	}
	log.warnf("Backing off from TIDAL for %ds: HTTP %d", seconds, resp.status)

	sync.guard(&s.backoff_mutex)
	until := time.tick_add(time.tick_now(), time.Duration(seconds) * time.Second)
	// Never shorten a backoff that is already running
	if s.backoff_until == {} || time.tick_diff(s.backoff_until, until) > 0 {
		s.backoff_until = until
		delete(s.backoff_reason, s.allocator)
		s.backoff_reason = strings.clone(reason, s.allocator)
	}
}

@(private)
is_abuse_response :: proc(resp: Http_Response) -> bool {
	if resp.status != 403 {
		return false
	}
	text := strings.to_lower(string(resp.body), context.temp_allocator)
	return strings.contains(text, "abuse") || strings.contains(text, "suspend")
}

@(private)
body_prefix :: proc(resp: Http_Response, n: int) -> string {
	b := string(resp.body)
	return b[:min(n, len(b))]
}

// Refresh the access token, at most once for concurrent callers.
//
// If several threads hit an expired token at the same time, each would POST
// the same refresh token. TIDAL rotates refresh tokens, so every POST after
// the first would use a token that has just been invalidated. stale is the
// access token the caller's request was sent with; if the session holds a
// different one by now, another thread already refreshed. since is the
// session's refresh_count when the request started: an attempt that failed
// after it, within REFRESH_FAILURE_SHARED, is the caller's failure too.
@(private)
refresh_access_token :: proc(s: ^Session, stale: string, since: u64) -> (refreshed: bool, err: Error) {
	sync.guard(&s.refresh_mutex)
	current, refresh: string
	epoch: u64
	{
		sync.guard(&s.mutex)
		current = strings.clone(s.access_token, context.temp_allocator)
		refresh = strings.clone(s.refresh_token, context.temp_allocator)
		epoch = s.auth_epoch
	}
	if current != stale {
		return true, nil
	}
	if refresh == "" {
		return false, nil
	}
	if s.refresh_count != since && s.refresh_err != nil && time.tick_since(s.refresh_ended) < REFRESH_FAILURE_SHARED {
		return false, s.refresh_err
	}
	return refresh_tokens(s, refresh, epoch)
}

// Whether the access token is expired, or about to be. TIDAL's expired-token
// userMessage has changed over time, so the expiry is checked up front.
@(private = "file")
access_token_expired :: proc(a: Auth) -> bool {
	expiry, ok := a.expiry_time.?
	if !ok || a.refresh_token == "" {
		return false
	}
	return time.diff(time.now(), expiry) <= TOKEN_EXPIRY_MARGIN
}

// Sends with the session's current access token. epoch is the auth epoch
// the request started in; if the login was cleared since, it's cancelled.
@(private = "file")
send :: proc(s: ^Session, method: Method, url: string, headers: []string, body: string, epoch: u64, allocator: mem.Allocator) -> (resp: Http_Response, sent_token: string, err: Error) {
	check_backoff(s) or_return
	auth := session_auth(s, context.temp_allocator)
	all := make([dynamic]string, 0, len(headers) + 1, context.temp_allocator)
	append(&all, ..headers)
	if auth.token_type != "" && auth.access_token != "" {
		append(&all, fmt.tprintf("authorization: %s %s", auth.token_type, auth.access_token))
	}
	resp = http_send(s, method, url, all[:], body, allocator, epoch) or_return
	start_backoff_if_needed(s, resp)
	return resp, auth.access_token, nil
}

@(private = "file")
has_header :: proc(headers: []string, name: string) -> bool {
	for h in headers {
		colon := strings.index_byte(h, ':')
		if colon >= 0 && strings.equal_fold(strings.trim_space(h[:colon]), name) {
			return true
		}
	}
	return false
}

// basic_request sends a request to TIDAL and returns the response whatever
// its status. Refreshes the access token before it expires and retries once
// if TIDAL reports it expired.
basic_request :: proc(s: ^Session, r: Request, allocator := context.allocator) -> (resp: Http_Response, err: Error) {
	check_backoff(s) or_return
	tmp := context.temp_allocator

	refresh_since := sync.atomic_load(&s.refresh_count)
	auth := session_auth(s, tmp)
	params := make([dynamic]Param, 0, len(r.params) + 3, tmp)
	if auth.session_id != "" {
		append(&params, Param{"sessionId", auth.session_id})
	}
	if auth.country_code != "" {
		append(&params, Param{"countryCode", auth.country_code})
	}
	append(&params, Param{"limit", fmt.tprint(s.config.item_limit)})

	// A path may carry its own query (page links do). Its values override the
	// defaults, and r.params override both.
	path, query := split_query(r.path)
	for p in parse_query(query, tmp) {
		set_param(&params, p)
	}
	for p in r.params {
		set_param(&params, p)
	}

	headers := make([dynamic]string, 0, len(r.headers) + 2, tmp)
	append(&headers, ..r.headers)
	if !has_header(r.headers, "x-tidal-client-version") {
		append(&headers, fmt.tprintf("x-tidal-client-version: %s", s.client_version))
	}
	if !has_header(r.headers, "User-Agent") {
		append(&headers, fmt.tprintf("User-Agent: %s", s.user_agent))
	}

	early_refresh: Error
	if access_token_expired(auth) {
		log.debug("The access token is about to expire, trying to refresh it.")
		if _, rerr := refresh_access_token(s, auth.access_token, refresh_since); rerr != nil {
			// Don't fail the request: the token may still be accepted, and if it
			// isn't, the expired-token handling below reports the failure.
			log.warnf("Proactive access token refresh failed: %s", error_summary(rerr, tmp))
			early_refresh = rerr
		}
	}

	base := r.base_url if r.base_url != "" else s.config.api_v1_location
	url := join_url(base, path, tmp)
	url = fmt.tprintf("%s?%s", url, encode_params(params[:], tmp))
	body := encode_params(r.data, tmp)

	sent_token: string
	resp, sent_token = send(s, r.method, url, headers[:], body, auth.epoch, allocator) or_return

	refresh_token: string
	{
		sync.guard(&s.mutex)
		refresh_token = s.refresh_token
	}
	if !http_ok(resp) && refresh_token != "" {
		user_message := ""
		if v, jerr := json.parse(resp.body, .JSON, true, tmp); jerr == nil {
			if obj, ok := v.(json.Object); ok {
				user_message = jstr(obj, "userMessage")
			}
		}
		if strings.has_prefix(user_message, "The token has expired.") {
			log.debug("The access token has expired, trying to refresh it.")
			refreshed, rerr := refresh_access_token(s, sent_token, refresh_since)
			if rerr != nil {
				return resp, rerr
			}
			if refreshed {
				// Retry exactly once. If TIDAL still reports an expired token
				// (e.g. clock skew), return that response instead of looping.
				delete(resp.body, allocator)
				delete(resp.etag, allocator)
				resp = {}
				resp, _ = send(s, r.method, url, headers[:], body, auth.epoch, allocator) or_return
			}
		} else if resp.status == 401 && is_error(early_refresh, .Refresh_Failed) {
			// TIDAL refused the token that couldn't be refreshed, without
			// saying it expired. The refresh failure is what to report: it
			// keeps the login, a plain 401 would end it.
			return resp, early_refresh
		} else {
			log.debugf("HTTP error on %d", resp.status)
		}
	}
	return resp, nil
}

// resource_get downloads a file outside the API, such as cover art from
// resources.tidal.com: no token, no default parameters. It shares the
// session's backoff, so a rate limit on either side holds back both.
resource_get :: proc(s: ^Session, url: string, allocator := context.allocator) -> (body: []u8, err: Error) {
	check_backoff(s) or_return
	headers := []string{fmt.tprintf("User-Agent: %s", s.user_agent)}
	resp := http_send(s, .GET, url, headers, "", allocator) or_return
	start_backoff_if_needed(s, resp)
	delete(resp.etag, allocator)
	if !http_ok(resp) {
		defer delete(resp.body, allocator)
		return nil, http_error(resp)
	}
	return resp.body, nil
}

// request is basic_request, with non-2xx responses turned into Errors. A
// response that came with an error is returned too, for the caller to free.
request :: proc(s: ^Session, r: Request, allocator := context.allocator) -> (resp: Http_Response, err: Error) {
	resp, err = basic_request(s, r, allocator)
	if err != nil {
		return
	}
	if !http_ok(resp) {
		log.infof("Request %v %s resulted in HTTP %d", r.method, r.path, resp.status)
		return resp, http_error(resp)
	}
	return resp, nil
}

// request_json sends r and parses the body. The JSON lives in allocator.
request_json :: proc(s: ^Session, r: Request, allocator := context.allocator) -> (value: json.Value, resp: Http_Response, err: Error) {
	resp = request(s, r, allocator) or_return
	v, jerr := json.parse(resp.body, .JSON, true, allocator)
	if jerr != nil {
		return nil, resp, make_error(.Bad_Response, "Response is not valid JSON", resp.status)
	}
	return v, resp, nil
}

// Same as request_json, but expects a JSON object.
@(private)
request_object :: proc(s: ^Session, r: Request, allocator := context.allocator) -> (obj: json.Object, err: Error) {
	obj, _, err = request_object_resp(s, r, allocator)
	return
}

@(private)
request_object_resp :: proc(s: ^Session, r: Request, allocator := context.allocator) -> (obj: json.Object, resp: Http_Response, err: Error) {
	v: json.Value
	v, resp = request_json(s, r, allocator) or_return
	o, ok := v.(json.Object)
	if !ok {
		return nil, resp, make_error(.Bad_Response, "Expected a JSON object", resp.status)
	}
	return o, resp, nil
}

// Maps an error response to an Error, like http_error_to_tidal_error.
@(private)
http_error :: proc(resp: Http_Response) -> Error {
	detail := ""
	sub_status := 0
	if len(resp.body) > 0 {
		if v, jerr := json.parse(resp.body, .JSON, true, context.temp_allocator); jerr == nil {
			if obj, ok := v.(json.Object); ok {
				if n, is_num := obj["subStatus"].(json.Integer); is_num {
					sub_status = int(n)
				} else if f, is_float := obj["subStatus"].(json.Float); is_float && f == f64(int(f)) {
					sub_status = int(f)
				}
				if errs, has := jarr(obj, "errors"); has && len(errs) > 0 {
					if first, is_obj := errs[0].(json.Object); is_obj {
						detail = jstr(first, "detail")
					}
				} else if msg := jstr(obj, "userMessage"); msg != "" {
					detail = msg
				}
			}
		} else {
			// Not every error body is JSON, e.g. gateway or anti-abuse rejections
			detail = body_prefix(resp, 200)
		}
	}
	err: Error
	switch {
	case resp.status == 404:
		err = make_error(.Object_Not_Found, "Object not found", resp.status, detail = detail)
	case resp.status == 429:
		err = make_error(.Too_Many_Requests, "Too many requests", resp.status, resp.retry_after, detail)
	case is_abuse_response(resp):
		err = make_error(.Abuse_Detected, "Abuse detected by TIDAL", resp.status, resp.retry_after, detail)
	case:
		err = make_error(.Http, "HTTP error", resp.status, detail = detail)
	}
	if e, ok := &err.(Api_Error); ok {
		e.sub_status = sub_status
	}
	return err
}

// POSTs a form without TIDAL's default params, as the OAuth endpoints
// expect. It goes through the same backoff as API requests: refused while
// one runs, and a 429 or anti-abuse 403 starts one. It's cancelled if the
// login is cleared after epoch.
@(private)
post_form :: proc(s: ^Session, url: string, form: []Param, epoch: u64, allocator: mem.Allocator) -> (resp: Http_Response, obj: json.Object, err: Error) {
	check_backoff(s) or_return
	headers := []string{fmt.tprintf("User-Agent: %s", s.user_agent)}
	resp = http_send(s, .POST, url, headers, encode_params(form, context.temp_allocator), allocator, epoch) or_return
	start_backoff_if_needed(s, resp)
	if v, jerr := json.parse(resp.body, .JSON, true, allocator); jerr == nil {
		obj, _ = v.(json.Object)
	}
	return resp, obj, nil
}

// is_rate_limit says whether resp is a 429 or an anti-abuse 403, which
// start a backoff and must reach the caller as such, not as a failed login.
@(private)
is_rate_limit :: proc(resp: Http_Response) -> bool {
	return resp.status == 429 || is_abuse_response(resp)
}

@(private = "file")
set_param :: proc(params: ^[dynamic]Param, p: Param) {
	for &existing in params {
		if existing.key == p.key {
			existing.value = p.value
			return
		}
	}
	append(params, p)
}

// Splits "path?query#fragment" into path and query; the fragment is dropped.
@(private)
split_query :: proc(target: string) -> (path, query: string) {
	t := target
	if hash := strings.index_byte(t, '#'); hash >= 0 {
		t = t[:hash]
	}
	if q := strings.index_byte(t, '?'); q >= 0 {
		return t[:q], t[q + 1:]
	}
	return t, ""
}

// Decodes an application/x-www-form-urlencoded query.
@(private)
parse_query :: proc(query: string, allocator: mem.Allocator) -> []Param {
	out := make([dynamic]Param, 0, 4, allocator)
	rest := query
	for part in strings.split_iterator(&rest, "&") {
		if part == "" {
			continue
		}
		k, _, v := strings.partition(part, "=")
		append(&out, Param{query_decode(k, allocator), query_decode(v, allocator)})
	}
	return out[:]
}

@(private = "file")
query_decode :: proc(s: string, allocator: mem.Allocator) -> string {
	plus, _ := strings.replace_all(s, "+", " ", allocator)
	decoded, ok := net.percent_decode(plus, allocator)
	return decoded if ok else plus
}
