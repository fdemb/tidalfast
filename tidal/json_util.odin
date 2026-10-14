package tidal

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:time"

// Lenient accessors: a missing key, a JSON null or a value of the wrong type
// yields the zero value, so a response with missing fields parses into a
// partial object.

@(private)
jobj :: proc(obj: json.Object, key: string) -> (json.Object, bool) {
	v, ok := obj[key].(json.Object)
	return v, ok
}

@(private)
jarr :: proc(obj: json.Object, key: string) -> (json.Array, bool) {
	v, ok := obj[key].(json.Array)
	return v, ok
}

// Present and not null.
@(private)
jhas :: proc(obj: json.Object, key: string) -> bool {
	v, present := obj[key]
	if !present {
		return false
	}
	_, is_null := v.(json.Null)
	return v != nil && !is_null
}

// Missing, null, false, 0, "" and empty containers are false.
@(private)
jtruthy :: proc(v: json.Value) -> bool {
	switch x in v {
	case json.Null:
		return false
	case json.Integer:
		return x != 0
	case json.Float:
		return x != 0
	case json.Boolean:
		return x
	case json.String:
		return x != ""
	case json.Array:
		return len(x) > 0
	case json.Object:
		return len(x) > 0
	}
	return false
}

// Not cloned: valid only as long as the JSON is.
@(private)
jstr :: proc(obj: json.Object, key: string) -> string {
	#partial switch x in obj[key] {
	case json.String:
		return x
	}
	return ""
}

@(private)
ji64 :: proc(obj: json.Object, key: string, default: i64 = 0) -> i64 {
	return value_i64(obj[key], default)
}

@(private)
jint :: proc(obj: json.Object, key: string, default := 0) -> int {
	return int(value_i64(obj[key], i64(default)))
}

@(private)
value_i64 :: proc(v: json.Value, default: i64 = 0) -> i64 {
	#partial switch x in v {
	case json.Integer:
		return x
	case json.Float:
		return i64(x)
	case json.Boolean:
		return 1 if x else 0
	case json.String:
		if n, ok := strconv.parse_i64(x); ok {
			return n
		}
	}
	return default
}

@(private)
jf64 :: proc(obj: json.Object, key: string, default := 0.0) -> f64 {
	#partial switch x in obj[key] {
	case json.Integer:
		return f64(x)
	case json.Float:
		return x
	}
	return default
}

@(private)
jbool :: proc(obj: json.Object, key: string, default := false) -> bool {
	v, present := obj[key]
	if !present || v == nil {
		return default
	}
	if _, is_null := v.(json.Null); is_null {
		return default
	}
	return jtruthy(v)
}

// ID that TIDAL sends either as a string or as a number.
@(private)
value_id_string :: proc(v: json.Value, allocator := context.allocator) -> string {
	#partial switch x in v {
	case json.String:
		return strings.clone(x, allocator)
	case json.Integer:
		return strconv.write_int(make([]u8, 24, allocator), x, 10)
	case json.Float:
		return strconv.write_int(make([]u8, 24, allocator), i64(x), 10)
	}
	return ""
}

// ISO 8601 date or date-time, as found in TIDAL responses.
@(private)
jdate :: proc(obj: json.Object, key: string) -> Maybe(time.Time) {
	#partial switch x in obj[key] {
	case json.String:
		if t, ok := parse_datetime(x); ok {
			return t
		}
	}
	return nil
}

// parse_datetime accepts "2019-04-26", "2014-06-02T00:00:00.000+0000",
// "2023-05-01T10:00:00Z", "...+02:00" and naive "2025-01-01T12:00:00.123456"
// (taken as UTC).
parse_datetime :: proc(s: string) -> (t: time.Time, ok: bool) {
	str := strings.trim_space(s)
	digits :: proc(s: string, at, n: int) -> (v: int, ok: bool) {
		if at + n > len(s) {
			return 0, false
		}
		for i in at ..< at + n {
			c := s[i]
			if c < '0' || c > '9' {
				return 0, false
			}
			v = v * 10 + int(c - '0')
		}
		return v, true
	}

	year := digits(str, 0, 4) or_return
	if len(str) < 10 || str[4] != '-' || str[7] != '-' {
		return
	}
	month := digits(str, 5, 2) or_return
	day := digits(str, 8, 2) or_return

	hour, minute, second, nsec, offset_sec := 0, 0, 0, 0, 0
	i := 10
	if i < len(str) && (str[i] == 'T' || str[i] == ' ') {
		hour = digits(str, 11, 2) or_return
		minute = digits(str, 14, 2) or_return
		i = 16
		if i < len(str) && str[i] == ':' {
			second = digits(str, 17, 2) or_return
			i = 19
		}
		if i < len(str) && (str[i] == '.' || str[i] == ',') {
			i += 1
			scale := 100_000_000
			for i < len(str) && str[i] >= '0' && str[i] <= '9' {
				nsec += int(str[i] - '0') * scale
				scale /= 10
				i += 1
			}
		}
		if i < len(str) {
			switch str[i] {
			case 'Z', 'z':
			case '+', '-':
				sign := 1 if str[i] == '+' else -1
				oh := digits(str, i + 1, 2) or_return
				rest := str[i + 3:]
				rest = strings.trim_prefix(rest, ":")
				om := 0
				if len(rest) >= 2 {
					om = digits(rest, 0, 2) or_return
				}
				offset_sec = sign * (oh * 3600 + om * 60)
			case:
				return
			}
		}
	}

	t = time.components_to_time(year, month, day, hour, minute, second, nsec) or_return
	return time.time_add(t, -time.Duration(offset_sec) * time.Second), true
}

// format_datetime_naive writes t as a UTC timestamp without offset, with
// microseconds, e.g. "2025-01-01T12:00:00.123456".
format_datetime_naive :: proc(t: time.Time, allocator := context.allocator) -> string {
	y, mon, d := time.date(t)
	h, m, sec := time.clock(t)
	micro := (time.time_to_unix_nano(t) %% 1_000_000_000) / 1000
	b := strings.builder_make(allocator)
	pad :: proc(b: ^strings.Builder, v: i64, width: int) {
		buf: [24]u8
		s := strconv.write_int(buf[:], v, 10)
		for _ in len(s) ..< width {
			strings.write_byte(b, '0')
		}
		strings.write_string(b, s)
	}
	pad(&b, i64(y), 4)
	strings.write_byte(&b, '-')
	pad(&b, i64(mon), 2)
	strings.write_byte(&b, '-')
	pad(&b, i64(d), 2)
	strings.write_byte(&b, 'T')
	pad(&b, i64(h), 2)
	strings.write_byte(&b, ':')
	pad(&b, i64(m), 2)
	strings.write_byte(&b, ':')
	pad(&b, i64(sec), 2)
	strings.write_byte(&b, '.')
	pad(&b, micro, 6)
	return strings.to_string(b)
}

// Writes s as a JSON string literal.
@(private)
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case 0 ..< 0x20:
			HEX := "0123456789abcdef"
			strings.write_string(b, `\u00`)
			strings.write_byte(b, HEX[c >> 4])
			strings.write_byte(b, HEX[c & 0xF])
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}
