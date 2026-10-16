package tidal

import "core:fmt"
import "core:strings"

// Error_Kind says what went wrong: TIDAL's error responses, transport
// failures, and responses that could not be parsed.
Error_Kind :: enum {
	Network,                 // DNS, TLS, connection or timeout failure; no HTTP response
	Http,                    // non-2xx response not covered by a more specific kind
	Bad_Response,            // the body was not the JSON shape we expected
	Authentication,
	Not_Logged_In,
	Object_Not_Found,        // HTTP 404
	Too_Many_Requests,       // HTTP 429
	Abuse_Detected,          // HTTP 403 mentioning abuse or a suspension
	Backing_Off,             // request held back locally, see Config.backoff
	Asset_Not_Available,
	Url_Not_Available,
	Stream_Not_Available,
	Metadata_Not_Available,
	Unknown_Manifest_Format,
	Manifest_Decode,
	Mpd_Not_Available,
	Invalid_Isrc,
	Invalid_Upc,
	Invalid_Argument,
	Timeout,
	Cancelled,
	Io,
	Refresh_Failed,          // the token refresh failed, but TIDAL didn't refuse the refresh token
	Lossy_Stream,            // the manifest's codec isn't FLAC (AAC for the device-code client); the codec is the detail
}

// Longest server detail kept in an Api_Error, in bytes.
ERROR_DETAIL_MAX :: 240

Api_Error :: struct {
	kind:              Error_Kind,
	message:           string, // static text
	// HTTP status code, 0 when no response was received.
	status:            int,
	// TIDAL's subStatus from the error body, 0 when there was none.
	sub_status:        int,
	// Retry-After in seconds for Too_Many_Requests and Abuse_Detected, -1 if absent.
	retry_after:       int,
	// Seconds left before requests are sent again, for Backing_Off.
	seconds_remaining: f64,
	// Text from the server (error detail, userMessage or the start of the
	// body), stored inline so errors own no memory. Read it with error_detail.
	// It may hold anything the server sent, signed URLs included, so it is
	// for the screen and never for a log; see error_summary.
	detail_len:        int,
	detail_buf:        [ERROR_DETAIL_MAX]u8,
}

// Error is nil on success, so `or_return` and `if err != nil` work as usual.
Error :: union {
	Api_Error,
}

@(private)
make_error :: proc(kind: Error_Kind, message: string, status := 0, retry_after := -1, detail := "") -> Error {
	e := Api_Error {
		kind        = kind,
		message     = message,
		status      = status,
		retry_after = retry_after,
	}
	set_detail(&e, detail)
	return e
}

@(private)
set_detail :: proc(e: ^Api_Error, detail: string) {
	n := min(len(detail), ERROR_DETAIL_MAX)
	// Don't cut a UTF-8 sequence in half.
	for n > 0 && n < len(detail) && detail[n] & 0xC0 == 0x80 {
		n -= 1
	}
	copy(e.detail_buf[:], detail[:n])
	e.detail_len = n
}

// error_detail returns the server-provided text of e, or "".
error_detail :: proc(e: ^Api_Error) -> string {
	return string(e.detail_buf[:e.detail_len])
}

// error_kind returns the kind of err; ok is false when err is nil.
error_kind :: proc(err: Error) -> (kind: Error_Kind, ok: bool) {
	e := err.? or_return
	return e.kind, true
}

is_error :: proc(err: Error, kind: Error_Kind) -> bool {
	e, ok := err.?
	return ok && e.kind == kind
}

// error_string formats err for display. Returns "" for nil.
error_string :: proc(err: Error, allocator := context.allocator) -> string {
	e, ok := err.?
	if !ok {
		return ""
	}
	if detail := error_detail(&e); detail != "" {
		return fmt.aprintf("%v: %s (%s)", e.kind, e.message, detail, allocator = allocator)
	}
	return fmt.aprintf("%v: %s", e.kind, e.message, allocator = allocator)
}

// error_summary formats err for a log line from fields that can't carry
// server text: the kind, the HTTP status, the subStatus, and for
// Lossy_Stream the codec if it's one codec_name knows. Returns "" for nil.
error_summary :: proc(err: Error, allocator := context.allocator) -> string {
	e, ok := err.?
	if !ok {
		return ""
	}
	switch {
	case e.kind == .Lossy_Stream:
		return fmt.aprintf("%v, codec %s", e.kind, codec_name(error_detail(&e)), allocator = allocator)
	case e.status == 0 && (e.kind == .Network || e.kind == .Timeout || e.kind == .Cancelled):
		return fmt.aprintf("%v, no HTTP response", e.kind, allocator = allocator)
	case e.status == 0:
		// A response that arrived but didn't parse. The message is static
		// text, so it can say which part failed.
		return fmt.aprintf("%v: %s", e.kind, e.message, allocator = allocator)
	case e.sub_status != 0:
		return fmt.aprintf("%v, HTTP %d, subStatus %d", e.kind, e.status, e.sub_status, allocator = allocator)
	}
	return fmt.aprintf("%v, HTTP %d", e.kind, e.status, allocator = allocator)
}

// codec_name is codec if it's a codec TIDAL is known to send, by its
// name before the first dot, and "unknown" otherwise. Manifests are server
// text, so this is how a codec gets into a log.
codec_name :: proc(codec: string) -> string {
	KNOWN :: [?]string{"FLAC", "ALAC", "MP4A", "AAC", "AC3", "EAC3", "AC4", "MHA1", "MHM1", "OPUS", "MP3"}
	name := codec
	for c, i in codec {
		if c == '.' {
			name = codec[:i]
			break
		}
	}
	for k in KNOWN {
		if strings.equal_fold(name, k) {
			return k
		}
	}
	return "unknown"
}

// quality_name is quality if it's one of TIDAL's audio quality names, and
// "unknown" otherwise.
quality_name :: proc(quality: string) -> string {
	for q in QUALITY_NAMES {
		if quality == q {
			return q
		}
	}
	return "HI_RES" if quality == "HI_RES" else "unknown"
}

// Turns Object_Not_Found into a more specific kind and rewrites the
// Too_Many_Requests message, for model-specific errors.
@(private)
remap_error :: proc(err: Error, not_found_kind: Error_Kind, not_found_message: string, rate_limited_message: string) -> Error {
	e, ok := err.?
	if !ok {
		return nil
	}
	#partial switch e.kind {
	case .Object_Not_Found:
		e.kind = not_found_kind
		e.message = not_found_message
	case .Too_Many_Requests:
		e.message = rate_limited_message
	}
	return e
}
