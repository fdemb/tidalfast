package tidal

import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/xml"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"

MANIFEST_MIME_MPD :: "application/dash+xml"
MANIFEST_MIME_BTS :: "application/vnd.tidal.bts"
MANIFEST_MIME_VIDEO :: "video/mp2t"

stream_is_mpd :: proc(s: Stream) -> bool {
	return strings.contains(s.manifest_mime_type, MANIFEST_MIME_MPD)
}

stream_is_bts :: proc(s: Stream) -> bool {
	return strings.contains(s.manifest_mime_type, MANIFEST_MIME_BTS)
}

// stream_manifest_data base64-decodes the manifest.
stream_manifest_data :: proc(s: Stream, allocator := context.allocator) -> (data: string, err: Error) {
	return decode_manifest(s.manifest, allocator)
}

@(private)
decode_manifest :: proc(manifest: string, allocator: mem.Allocator) -> (data: string, err: Error) {
	bytes, derr := base64.decode(manifest, allocator = allocator)
	if derr != nil {
		return "", make_error(.Manifest_Decode, "Stream manifest is not valid base64")
	}
	return string(bytes), nil
}

// A decoded BTS manifest: one or more file URLs.
@(private)
Bts_Manifest :: struct {
	codec:           string, // upper case, without the profile: FLAC, MP4A
	mime_type:       string,
	encryption_type: string,
	key_id:          string,
	urls:            []string,
}

@(private)
parse_bts :: proc(data: string, allocator: mem.Allocator) -> (m: Bts_Manifest, err: Error) {
	v, jerr := json.parse_string(data, .JSON, true, context.temp_allocator)
	obj, is_obj := v.(json.Object)
	if jerr != nil || !is_obj {
		return {}, make_error(.Manifest_Decode, "BTS manifest is not valid JSON")
	}
	p := Parser {
		allocator = allocator,
	}
	codec := strings.to_upper(jstr(obj, "codecs"), context.temp_allocator)
	if dot := strings.index_byte(codec, '.'); dot >= 0 {
		codec = codec[:dot]
	}
	return Bts_Manifest {
			codec = strings.clone(codec, allocator),
			mime_type = pstr(&p, obj, "mimeType"),
			encryption_type = pstr(&p, obj, "encryptionType"),
			key_id = pstr(&p, obj, "keyId"),
			urls = pstrings(&p, obj, "urls"),
		},
		nil
}

// mime_type_from_codec maps a codec name to the MIME type TIDAL uses for it.
mime_type_from_codec :: proc(codec: string) -> string {
	switch codec {
	case "MP3":
		return "audio/mp3"
	case "AAC", "MP4A":
		return "audio/m4a"
	case "FLAC":
		return "audio/x-flac"
	case "EAC3":
		return "audio/eac3"
	case "AC4":
		return "audio/mp4"
	}
	return "audio/m4a"
}

// file_extension_for guesses the file extension from a stream URL and codec.
file_extension_for :: proc(url: string, codec := "") -> string {
	switch {
	case strings.contains(url, ".flac"):
		return ".flac"
	// MPEG-4 is a container for audio and video. '.m4a' is used when it holds
	// only audio.
	case strings.contains(url, ".mp4"), strings.contains(url, ".m4a"), codec == "MP4A":
		return ".m4a"
	// Videos are streamed as '.ts' files.
	case strings.contains(url, ".ts"):
		return ".ts"
	}
	return ".mp4"
}

// stream_get_manifest decodes the MPD or BTS manifest of a stream.
stream_get_manifest :: proc(s: Stream, allocator := context.allocator) -> (m: Stream_Manifest, err: Error) {
	m.manifest_mime_type = strings.clone(s.manifest_mime_type, allocator)
	m.sample_rate = 44100
	m.mime_type = "audio/mpeg"

	if stream_is_mpd(s) {
		data := stream_manifest_data(s, context.temp_allocator) or_return
		dash := dash_info_from_mpd(data, allocator) or_return
		m.dash_info = dash
		m.urls = dash.urls
		// MPD reports mp4a codecs differently from BTS. Both are MP4A.
		switch {
		case strings.contains(dash.codecs, "flac"):
			m.codecs = "FLAC"
		case strings.contains(dash.codecs, "mp4a.40.5"), strings.contains(dash.codecs, "mp4a.40.2"):
			// LOW 96k is "mp4a.40.5", LOW 320k is "mp4a.40.2"
			m.codecs = "MP4A"
		case:
			m.codecs = dash.codecs
		}
		m.mime_type = dash.mime_type
		m.sample_rate = dash.audio_sampling_rate
		// TODO: Handle encryption key.
		m.encryption_type = "NONE"
	} else if stream_is_bts(s) {
		data := stream_manifest_data(s, allocator) or_return
		m.manifest_parsed = data
		bts := parse_bts(data, allocator) or_return
		// TODO: Handle more than one download URL
		m.urls = bts.urls
		m.codecs = bts.codec
		m.mime_type = bts.mime_type
		m.encryption_type = bts.encryption_type
		if m.encryption_type != "" {
			m.encryption_key = bts.key_id
		}
	} else {
		return {}, make_error(.Unknown_Manifest_Format, "Unknown manifest format", detail = m.manifest_mime_type)
	}

	if len(m.urls) == 0 {
		return {}, make_error(.Manifest_Decode, "Manifest has no URLs")
	}
	m.file_extension = file_extension_for(m.urls[0], m.codecs)
	return m, nil
}

// manifest_is_encrypted reports whether the stream needs a decryption key.
manifest_is_encrypted :: proc(m: Stream_Manifest) -> bool {
	return m.encryption_key != ""
}

// manifest_hls renders an HLS playlist for an MPD manifest.
manifest_hls :: proc(m: Stream_Manifest, allocator := context.allocator) -> (hls: string, err: Error) {
	dash, ok := m.dash_info.?
	if !ok {
		return "", make_error(.Mpd_Not_Available, "HLS stream requires MPD MetaData")
	}
	return dash_hls(dash, allocator), nil
}

// Upper bound on generated segments, against malformed timelines.
@(private = "file")
MAX_DASH_SEGMENTS :: 200_000

// dash_info_from_mpd parses the MPD XML that TIDAL sends for DASH streams:
// one period, adaptation set and representation with a SegmentTemplate.
dash_info_from_mpd :: proc(mpd_xml: string, allocator := context.allocator) -> (info: Dash_Info, err: Error) {
	// what is static text, so error_summary can log which check failed.
	decode_error :: proc(what: string) -> Error {
		return make_error(.Manifest_Decode, what, detail = what)
	}

	doc, xerr := xml.parse_string(mpd_xml, allocator = context.temp_allocator)
	if xerr != nil || doc == nil || doc.element_count == 0 {
		log.debugf("MPD is not XML: %v, %d bytes, first byte 0x%02x", xerr, len(mpd_xml), mpd_xml[0] if len(mpd_xml) > 0 else 0)
		return {}, decode_error("MPD: not XML")
	}
	if context.logger.lowest_level <= .Debug {
		log.debugf("MPD outline, %d bytes: %s", len(mpd_xml), mpd_outline(doc, context.temp_allocator))
	}
	root: xml.Element_ID = 0
	if doc.elements[0].ident != "MPD" {
		return {}, decode_error("MPD: missing MPD element")
	}

	child :: proc(doc: ^xml.Document, parent: xml.Element_ID, ident: string) -> (xml.Element_ID, bool) {
		return xml.find_child_by_ident(doc, parent, ident)
	}
	attr :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> (string, bool) {
		v, ok := xml.find_attribute_val_by_key(doc, id, key)
		return xml_unescape(v), ok
	}
	// Representation attributes may also sit on the AdaptationSet.
	inherited :: proc(doc: ^xml.Document, ids: []xml.Element_ID, key: string) -> string {
		for id in ids {
			if v, ok := attr(doc, id, key); ok {
				return v
			}
		}
		return ""
	}
	to_int :: proc(s: string, default: int) -> int {
		v, ok := strconv.parse_int(s, 10)
		return v if ok else default
	}

	period, ok1 := child(doc, root, "Period")
	adaptation, ok2 := child(doc, period, "AdaptationSet")
	representation, ok3 := child(doc, adaptation, "Representation")
	if !(ok1 && ok2 && ok3) {
		return {}, decode_error("MPD: missing Period/AdaptationSet/Representation")
	}
	levels := []xml.Element_ID{representation, adaptation}
	template, has_template := child(doc, representation, "SegmentTemplate")
	if !has_template {
		template, has_template = child(doc, adaptation, "SegmentTemplate")
	}
	if !has_template {
		return {}, decode_error("MPD: missing SegmentTemplate")
	}

	// mediaPresentationDuration is optional for static MPDs. Without it the
	// Period duration or the timeline itself gives the length.
	duration: time.Duration
	has_duration := false
	for source in ([]struct {
			id:  xml.Element_ID,
			key: string,
		}{{root, "mediaPresentationDuration"}, {period, "duration"}}) {
		if v, has := attr(doc, source.id, source.key); has {
			if duration, has_duration = parse_iso_duration(v); has_duration {
				break
			}
		}
	}

	info.content_type = strings.clone(inherited(doc, levels, "contentType"), allocator)
	info.mime_type = strings.clone(inherited(doc, levels, "mimeType"), allocator)
	info.codecs = strings.clone(inherited(doc, levels, "codecs"), allocator)
	info.audio_sampling_rate = to_int(inherited(doc, levels, "audioSamplingRate"), 0)

	timescale_attr, _ := attr(doc, template, "timescale")
	info.timescale = max(to_int(timescale_attr, 1), 1)
	start_attr, _ := attr(doc, template, "startNumber")
	info.start_number = to_int(start_attr, 1)
	media_template, _ := attr(doc, template, "media")
	info.media_url = strings.clone(media_template, allocator)
	if media_template == "" {
		return {}, decode_error("MPD: SegmentTemplate has no media attribute")
	}

	vars := Template_Vars {
		representation_id = inherited(doc, {representation}, "id"),
		bandwidth         = inherited(doc, {representation}, "bandwidth"),
	}
	if init_template, has_init := attr(doc, template, "initialization"); has_init && init_template != "" {
		info.init_url = expand_template(init_template, vars, allocator)
	}

	timescale := f64(info.timescale)
	period_end := i64(time.duration_seconds(duration) * timescale + 0.5) if has_duration else -1
	segments := make([dynamic]Dash_Segment, 0, 64, allocator)

	if timeline, has_timeline := child(doc, template, "SegmentTimeline"); has_timeline {
		entries := make([dynamic]xml.Element_ID, 0, 16, context.temp_allocator)
		for v in doc.elements[timeline].value {
			id := v.(xml.Element_ID) or_continue
			if doc.elements[id].ident == "S" {
				append(&entries, id)
			}
		}
		if len(entries) == 0 {
			return {}, decode_error("MPD: empty SegmentTimeline")
		}

		t: i64 = 0
		number := info.start_number
		for id, i in entries {
			if ts, has_t := attr(doc, id, "t"); has_t {
				t = i64(to_int(ts, int(t)))
			}
			ds, _ := attr(doc, id, "d")
			d := i64(to_int(ds, 0))
			if d <= 0 {
				return {}, decode_error("MPD: segment without a positive duration")
			}
			rs, _ := attr(doc, id, "r")
			r := to_int(rs, 0)
			count: i64
			if r >= 0 {
				count = i64(r) + 1
			} else {
				// r = -1 repeats until the next entry's start or the period end.
				end := period_end
				if i + 1 < len(entries) {
					if next_t, has_next := attr(doc, entries[i + 1], "t"); has_next {
						end = i64(to_int(next_t, int(end)))
					}
				}
				if end < 0 {
					return {}, decode_error("MPD: open-ended segment without a duration")
				}
				count = max((end - t + d - 1) / d, 1)
			}
			if i64(len(segments)) + count > MAX_DASH_SEGMENTS {
				return {}, decode_error("MPD: too many segments")
			}
			for _ in 0 ..< count {
				vars.number = number
				vars.time = t
				append(&segments, Dash_Segment{url = expand_template(media_template, vars, allocator), duration = f64(d) / timescale, start = t, length = d})
				t += d
				number += 1
			}
		}
	} else {
		// Fixed-duration segments: SegmentTemplate@duration.
		ds, _ := attr(doc, template, "duration")
		d := i64(to_int(ds, 0))
		if d <= 0 {
			return {}, decode_error("MPD: missing SegmentTimeline and segment duration")
		}
		if !has_duration {
			return {}, decode_error("MPD: fixed segments without a duration")
		}
		count := max((period_end + d - 1) / d, 1)
		if count > MAX_DASH_SEGMENTS {
			return {}, decode_error("MPD: too many segments")
		}
		for k in 0 ..< count {
			vars.number = info.start_number + int(k)
			vars.time = k * d
			remaining := period_end - k * d
			append(&segments, Dash_Segment{url = expand_template(media_template, vars, allocator), duration = f64(min(d, remaining)) / timescale, start = k * d, length = min(d, remaining)})
		}
	}
	info.segments = segments[:]
	if has_duration {
		info.duration = duration
	} else if len(segments) > 0 {
		last := segments[len(segments) - 1]
		info.duration = time.Duration(f64(last.start + last.length) / timescale * f64(time.Second))
	}

	urls := make([dynamic]string, 0, len(segments) + 1, allocator)
	if info.init_url != "" {
		append(&urls, info.init_url)
	}
	for seg in segments {
		append(&urls, seg.url)
	}
	info.urls = urls[:]
	return info, nil
}

@(private = "file")
Template_Vars :: struct {
	number:            int,
	time:              i64,
	representation_id: string,
	bandwidth:         string,
}

// Expands DASH URL template identifiers: $$, $RepresentationID$, $Number$,
// $Bandwidth$ and $Time$, the numeric ones with an optional %0Nd width.
@(private = "file")
expand_template :: proc(template: string, vars: Template_Vars, allocator: mem.Allocator) -> string {
	if strings.index_byte(template, '$') < 0 {
		return strings.clone(template, allocator)
	}
	b := strings.builder_make(allocator)
	rest := template
	for {
		open := strings.index_byte(rest, '$')
		if open < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:open])
		rest = rest[open + 1:]
		close := strings.index_byte(rest, '$')
		if close < 0 {
			// Unterminated: keep it literally.
			strings.write_byte(&b, '$')
			strings.write_string(&b, rest)
			break
		}
		ident := rest[:close]
		rest = rest[close + 1:]

		name, format := ident, ""
		if pct := strings.index_byte(ident, '%'); pct >= 0 {
			name, format = ident[:pct], ident[pct:]
		}
		width := 0
		if strings.has_prefix(format, "%0") && strings.has_suffix(format, "d") {
			width, _ = strconv.parse_int(format[2:len(format) - 1], 10)
		}
		write_number :: proc(b: ^strings.Builder, v: i64, width: int) {
			buf: [32]u8
			digits := strconv.write_int(buf[:], v, 10)
			for _ in len(digits) ..< width {
				strings.write_byte(b, '0')
			}
			strings.write_string(b, digits)
		}
		switch name {
		case "":
			strings.write_byte(&b, '$')
		case "Number":
			write_number(&b, i64(vars.number), width)
		case "Time":
			write_number(&b, vars.time, width)
		case "RepresentationID":
			strings.write_string(&b, vars.representation_id)
		case "Bandwidth":
			strings.write_string(&b, vars.bandwidth)
		case:
			// Unknown identifier: keep it literally.
			strings.write_byte(&b, '$')
			strings.write_string(&b, ident)
			strings.write_byte(&b, '$')
		}
	}
	return strings.to_string(b)
}

// dash_hls renders the DASH segments as an HLS media playlist. The
// initialization segment goes in EXT-X-MAP, so only media segments carry
// EXTINF durations.
dash_hls :: proc(d: Dash_Info, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	longest := 0.0
	for seg in d.segments {
		longest = max(longest, seg.duration)
	}
	strings.write_string(&b, "#EXTM3U\n#EXT-X-VERSION:7\n")
	fmt.sbprintf(&b, "#EXT-X-TARGETDURATION:%d\n", int(math.ceil(longest)))
	strings.write_string(&b, "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n")
	if d.init_url != "" {
		fmt.sbprintf(&b, "#EXT-X-MAP:URI=\"%s\"\n", d.init_url)
	}
	for seg in d.segments {
		fmt.sbprintf(&b, "#EXTINF:%.6f,\n%s\n", seg.duration, seg.url)
	}
	strings.write_string(&b, "#EXT-X-ENDLIST\n")
	return strings.to_string(b)
}

// mpd_outline describes an MPD for the debug log without its text: element
// and attribute names, and each value's shape with digits as 9. URLs and
// long values show only their length, and runs of S elements are counted.
mpd_outline :: proc(doc: ^xml.Document, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	outline_element(&b, doc, 0)
	return strings.to_string(b)

	outline_element :: proc(b: ^strings.Builder, doc: ^xml.Document, id: xml.Element_ID) {
		e := doc.elements[id]
		strings.write_string(b, e.ident)
		for a in e.attribs {
			strings.write_byte(b, ' ')
			strings.write_string(b, a.key)
			strings.write_byte(b, '=')
			outline_value(b, a.val)
		}
		children := 0
		for v in e.value {
			if _, is_child := v.(xml.Element_ID); is_child {
				children += 1
			}
		}
		if children == 0 {
			return
		}
		strings.write_string(b, " {")
		// A run of S elements prints its first one and its length.
		run_first: xml.Element_ID
		run := 0
		for v in e.value {
			child := v.(xml.Element_ID) or_continue
			if doc.elements[child].ident == "S" {
				if run == 0 {
					run_first = child
				}
				run += 1
				continue
			}
			outline_run(b, doc, run_first, run)
			run = 0
			strings.write_byte(b, ' ')
			outline_element(b, doc, child)
		}
		outline_run(b, doc, run_first, run)
		strings.write_string(b, " }")
	}

	outline_run :: proc(b: ^strings.Builder, doc: ^xml.Document, first: xml.Element_ID, count: int) {
		if count == 0 {
			return
		}
		if count > 1 {
			fmt.sbprintf(b, " %d S elements, first:", count)
		}
		strings.write_byte(b, ' ')
		outline_element(b, doc, first)
	}

	outline_value :: proc(b: ^strings.Builder, v: string) {
		if len(v) > 40 || strings.contains(v, "://") {
			fmt.sbprintf(b, "<%d bytes>", len(v))
			return
		}
		strings.write_byte(b, '"')
		for i in 0 ..< len(v) {
			c := v[i]
			switch {
			case c >= '0' && c <= '9':
				strings.write_byte(b, '9')
			case c > ' ' && c < 0x7f && c != '"' && c != '\\':
				strings.write_byte(b, c)
			case:
				fmt.sbprintf(b, "\\x%02x", c)
			}
		}
		strings.write_byte(b, '"')
	}
}

// parse_iso_duration parses ISO 8601 durations like "PT3M25.123S".
parse_iso_duration :: proc(str: string) -> (d: time.Duration, ok: bool) {
	s := strings.trim_space(str)
	if len(s) < 2 || s[0] != 'P' {
		return 0, false
	}
	in_time := false
	total: f64
	start := 1
	for i := 1; i < len(s); i += 1 {
		c := s[i]
		if c == 'T' {
			in_time = true
			start = i + 1
			continue
		}
		if (c >= '0' && c <= '9') || c == '.' || c == ',' {
			continue
		}
		num, nok := strconv.parse_f64(s[start:i])
		if !nok {
			return 0, false
		}
		switch c {
		case 'Y':
			total += num * 365 * 86400
		case 'M':
			total += num * (60 if in_time else 30 * 86400)
		case 'W':
			total += num * 7 * 86400
		case 'D':
			total += num * 86400
		case 'H':
			total += num * 3600
		case 'S':
			total += num
		case:
			return 0, false
		}
		start = i + 1
	}
	return time.Duration(total * f64(time.Second)), true
}

// Attribute values in TIDAL's MPD escape '&' in segment URLs.
@(private = "file")
xml_unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '&') < 0 {
		return s
	}
	out := s
	for pair in ([][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&amp;", "&"}}) {
		out, _ = strings.replace_all(out, pair[0], pair[1], context.temp_allocator)
	}
	return out
}
