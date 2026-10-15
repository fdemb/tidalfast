package tidal

import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/xml"
import "core:fmt"
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
	bytes, derr := base64.decode(s.manifest, allocator = allocator)
	if derr != nil {
		return "", make_error(.Manifest_Decode, "Stream manifest is not valid base64")
	}
	return string(bytes), nil
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
		v, jerr := json.parse_string(data, .JSON, true, context.temp_allocator)
		obj, is_obj := v.(json.Object)
		if jerr != nil || !is_obj {
			return {}, make_error(.Manifest_Decode, "BTS manifest is not valid JSON")
		}
		p := Parser {
			allocator = allocator,
		}
		// TODO: Handle more than one download URL
		m.urls = pstrings(&p, obj, "urls")
		// Codecs can be read directly from BTS
		codecs := strings.to_upper(jstr(obj, "codecs"), context.temp_allocator)
		if dot := strings.index_byte(codecs, '.'); dot >= 0 {
			codecs = codecs[:dot]
		}
		m.codecs = strings.clone(codecs, allocator)
		m.mime_type = pstr(&p, obj, "mimeType")
		m.encryption_type = pstr(&p, obj, "encryptionType")
		if m.encryption_type != "" {
			m.encryption_key = pstr(&p, obj, "keyId")
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
	decode_error :: proc(what: string) -> Error {
		return make_error(.Manifest_Decode, "Invalid MPD manifest", detail = what)
	}

	doc, xerr := xml.parse_string(mpd_xml, allocator = context.temp_allocator)
	if xerr != nil || doc == nil || doc.element_count == 0 {
		return {}, decode_error("not XML")
	}
	root: xml.Element_ID = 0
	if doc.elements[0].ident != "MPD" {
		return {}, decode_error("missing MPD element")
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
		return {}, decode_error("missing Period/AdaptationSet/Representation")
	}
	levels := []xml.Element_ID{representation, adaptation}
	template, has_template := child(doc, representation, "SegmentTemplate")
	if !has_template {
		template, has_template = child(doc, adaptation, "SegmentTemplate")
	}
	if !has_template {
		return {}, decode_error("missing SegmentTemplate")
	}

	duration_attr, _ := attr(doc, root, "mediaPresentationDuration")
	duration, dok := parse_iso_duration(duration_attr)
	if !dok {
		return {}, decode_error("bad mediaPresentationDuration")
	}

	info.duration = duration
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
		return {}, decode_error("SegmentTemplate has no media attribute")
	}

	vars := Template_Vars {
		representation_id = inherited(doc, {representation}, "id"),
		bandwidth         = inherited(doc, {representation}, "bandwidth"),
	}
	if init_template, has_init := attr(doc, template, "initialization"); has_init && init_template != "" {
		info.init_url = expand_template(init_template, vars, allocator)
	}

	timescale := f64(info.timescale)
	period_end := i64(time.duration_seconds(duration) * timescale + 0.5)
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
			return {}, decode_error("empty SegmentTimeline")
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
				return {}, decode_error("segment without a positive duration")
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
				count = max((end - t + d - 1) / d, 1)
			}
			if i64(len(segments)) + count > MAX_DASH_SEGMENTS {
				return {}, decode_error("too many segments")
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
			return {}, decode_error("missing SegmentTimeline and segment duration")
		}
		count := max((period_end + d - 1) / d, 1)
		if count > MAX_DASH_SEGMENTS {
			return {}, decode_error("too many segments")
		}
		for k in 0 ..< count {
			vars.number = info.start_number + int(k)
			vars.time = k * d
			remaining := period_end - k * d
			append(&segments, Dash_Segment{url = expand_template(media_template, vars, allocator), duration = f64(min(d, remaining)) / timescale, start = k * d, length = min(d, remaining)})
		}
	}
	info.segments = segments[:]

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

// parse_iso_duration parses ISO 8601 durations like "PT3M25.123S".
parse_iso_duration :: proc(s: string) -> (d: time.Duration, ok: bool) {
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
