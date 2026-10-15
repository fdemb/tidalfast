package tidal

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sync"
import curl "vendor:curl"

Method :: enum {
	GET,
	POST,
	PUT,
	DELETE,
}

Http_Response :: struct {
	status:      int,
	body:        []u8,
	etag:        string,
	retry_after: int, // -1 if absent or not a number of seconds
}

http_ok :: proc(r: Http_Response) -> bool {
	return r.status >= 200 && r.status < 400
}

@(private = "file")
curl_once: sync.Once

// http_send performs one HTTP exchange. body is sent form-encoded for
// POST/PUT/DELETE. Response body and etag are allocated with allocator.
// Only transport failures are errors; any HTTP status is returned as-is.
// With an epoch, the request fails with .Cancelled once the session's
// auth_epoch is different, before it's sent or while it's in flight.
@(private)
http_send :: proc(
	s: ^Session,
	method: Method,
	url: string,
	headers: []string,
	body: string,
	allocator: mem.Allocator,
	epoch: Maybe(u64) = nil,
) -> (
	resp: Http_Response,
	err: Error,
) {
	sync.once_do(&curl_once, proc() {curl.global_init(curl.GLOBAL_DEFAULT)})
	watch := Abort_Watch {
		abort = &s.abort,
		epoch = &s.auth_epoch,
	}
	watch.start, watch.watch_epoch = epoch.?
	if aborted(&watch) {
		return {}, make_error(.Cancelled, "Request cancelled")
	}

	h := curl_acquire(s)
	defer curl_release(s, h)

	tmp := context.temp_allocator
	curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, tmp))
	curl.easy_setopt(h, .NOSIGNAL, c.long(1))
	curl.easy_setopt(h, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(h, .ACCEPT_ENCODING, cstring(""))
	curl.easy_setopt(h, .CONNECTTIMEOUT, c.long(15))
	if s.config.timeout_seconds > 0 {
		curl.easy_setopt(h, .TIMEOUT, c.long(s.config.timeout_seconds))
	}

	list: ^curl.slist
	for hd in headers {
		list = curl.slist_append(list, strings.clone_to_cstring(hd, tmp))
	}
	defer curl.slist_free_all(list)
	if list != nil {
		curl.easy_setopt(h, .HTTPHEADER, list)
	}

	body_c := strings.clone_to_cstring(body, tmp)
	switch method {
	case .GET:
		curl.easy_setopt(h, .HTTPGET, c.long(1))
	case .POST:
		// Always send a (possibly empty) form body so Content-Length is set.
		curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(body)))
		curl.easy_setopt(h, .POSTFIELDS, body_c)
	case .PUT:
		curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(body)))
		curl.easy_setopt(h, .POSTFIELDS, body_c)
		curl.easy_setopt(h, .CUSTOMREQUEST, cstring("PUT"))
	case .DELETE:
		if body != "" {
			curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(body)))
			curl.easy_setopt(h, .POSTFIELDS, body_c)
		}
		curl.easy_setopt(h, .CUSTOMREQUEST, cstring("DELETE"))
	}

	sink := make([dynamic]u8, 0, 16 * 1024, allocator)
	capture := Header_Capture {
		retry_after = -1,
		allocator   = allocator,
	}
	curl.easy_setopt(h, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(h, .WRITEDATA, &sink)
	curl.easy_setopt(h, .HEADERFUNCTION, header_callback)
	curl.easy_setopt(h, .HEADERDATA, &capture)
	curl.easy_setopt(h, .NOPROGRESS, c.long(0))
	curl.easy_setopt(h, .XFERINFOFUNCTION, abort_callback)
	curl.easy_setopt(h, .XFERINFODATA, &watch)

	code := curl.easy_perform(h)
	if code == .E_ABORTED_BY_CALLBACK {
		delete(sink)
		return {}, make_error(.Cancelled, "Request cancelled")
	}
	if code != .E_OK {
		delete(sink)
		return {}, make_error(.Network, "HTTP request failed", detail = string(curl.easy_strerror(code)))
	}

	status: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &status)
	return Http_Response{status = int(status), body = sink[:], etag = capture.etag, retry_after = capture.retry_after}, nil
}

@(private = "file")
Header_Capture :: struct {
	etag:        string,
	retry_after: int,
	allocator:   mem.Allocator,
}

@(private = "file")
write_callback :: proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	n := int(size * nitems)
	sink := (^[dynamic]u8)(userdata)
	append(sink, ..buffer[:n])
	return c.size_t(n)
}

@(private = "file")
Abort_Watch :: struct {
	abort:       ^bool,
	epoch:       ^u64,
	start:       u64,
	watch_epoch: bool,
}

@(private = "file")
aborted :: proc "contextless" (w: ^Abort_Watch) -> bool {
	return sync.atomic_load(w.abort) || (w.watch_epoch && sync.atomic_load(w.epoch) != w.start)
}

// Called by curl about once a second and whenever data moves. A non-zero
// return aborts the transfer.
@(private = "file")
abort_callback :: proc "c" (watch: rawptr, dltotal, dlnow, ultotal, ulnow: curl.off_t) -> c.int {
	return 1 if aborted((^Abort_Watch)(watch)) else 0
}

@(private = "file")
header_callback :: proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	n := int(size * nitems)
	capture := (^Header_Capture)(userdata)
	line := strings.trim_space(string(buffer[:n]))

	// A new status line starts a new header block (redirects, 100 Continue).
	if strings.has_prefix(line, "HTTP/") {
		capture.etag = ""
		capture.retry_after = -1
		return c.size_t(n)
	}
	colon := strings.index_byte(line, ':')
	if colon < 0 {
		return c.size_t(n)
	}
	name := strings.trim_space(line[:colon])
	value := strings.trim_space(line[colon + 1:])
	if strings.equal_fold(name, "etag") {
		capture.etag = strings.clone(value, capture.allocator)
	} else if strings.equal_fold(name, "retry-after") {
		v, ok := strconv.parse_int(value, 10)
		capture.retry_after = v if ok else -1
	}
	return c.size_t(n)
}

// Easy handles are pooled so connections and TLS sessions get reused.
@(private = "file")
curl_acquire :: proc(s: ^Session) -> ^curl.CURL {
	sync.guard(&s.curl_mutex)
	if h, ok := pop_safe(&s.curl_pool); ok {
		return h
	}
	return curl.easy_init()
}

@(private = "file")
curl_release :: proc(s: ^Session, h: ^curl.CURL) {
	curl.easy_reset(h)
	sync.guard(&s.curl_mutex)
	append(&s.curl_pool, h)
}

@(private)
curl_pool_destroy :: proc(s: ^Session) {
	sync.guard(&s.curl_mutex)
	for h in s.curl_pool {
		curl.easy_cleanup(h)
	}
	delete(s.curl_pool)
}

// Percent-encodes and joins params as application/x-www-form-urlencoded.
@(private)
encode_params :: proc(params: []Param, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	for p, i in params {
		if i > 0 {
			strings.write_byte(&b, '&')
		}
		write_percent_encoded(&b, p.key)
		strings.write_byte(&b, '=')
		write_percent_encoded(&b, p.value)
	}
	return strings.to_string(b)
}

@(private = "file")
write_percent_encoded :: proc(b: ^strings.Builder, s: string) {
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '_', '.', '~':
			strings.write_byte(b, ch)
		case:
			strings.write_byte(b, '%')
			strings.write_byte(b, HEX[ch >> 4])
			strings.write_byte(b, HEX[ch & 0xF])
		}
	}
}

// Joins a base URL and a path: absolute paths win, otherwise
// the path is appended to the base, which always ends in '/'.
@(private)
join_url :: proc(base, path: string, allocator: mem.Allocator) -> string {
	if strings.contains(path, "://") {
		return path
	}
	return strings.concatenate({base, strings.trim_prefix(path, "/")}, allocator)
}
