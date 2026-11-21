package sys

import "core:strings"

DEFAULT_LOCALE :: "en_US"

// locale_normalize turns a locale name as an OS writes it ("pl_PL.UTF-8",
// "pl-PL", "zh-Hans-CN", "en_US_POSIX") into TIDAL's ll_CC form, allocated
// with allocator. The encoding (after '.') and modifier (after '@') are
// dropped, and a four letter script between the language and the region
// is skipped. A language with no region gets the region CLDR's likely
// subtags give it, for the languages in likely_region. Anything else,
// "C", "POSIX" and empty included, gives DEFAULT_LOCALE.
locale_normalize :: proc(raw: string, allocator := context.allocator) -> string {
	name := strings.trim_space(raw)
	if end := strings.index_any(name, ".@"); end >= 0 {
		name = name[:end]
	}
	lang, region: [2]u8
	have_region := false
	rest := name
	for i := 0; rest != "" && !have_region; i += 1 {
		part := rest
		if sep := strings.index_any(rest, "_-"); sep >= 0 {
			part, rest = rest[:sep], rest[sep + 1:]
		} else {
			rest = ""
		}
		switch {
		case i == 0:
			if len(part) != 2 || !ascii_letters(part) {
				return strings.clone(DEFAULT_LOCALE, allocator)
			}
			lang = {lower(part[0]), lower(part[1])}
		case len(part) == 2 && ascii_letters(part):
			region = {upper(part[0]), upper(part[1])}
			have_region = true
		case i == 1 && len(part) == 4 && ascii_letters(part):
		// A script, such as Hans in zh-Hans-CN.
		case:
			rest = ""
		}
	}
	if lang == {} {
		return strings.clone(DEFAULT_LOCALE, allocator)
	}
	if !have_region {
		r, known := likely_region(string(lang[:]))
		if !known {
			return strings.clone(DEFAULT_LOCALE, allocator)
		}
		region = {r[0], r[1]}
	}
	out := [5]u8{lang[0], lang[1], '_', region[0], region[1]}
	return strings.clone(string(out[:]), allocator)
}

// likely_region is the region CLDR's likely subtags pair with a language,
// for the languages TIDAL's apps come in and their neighbours.
@(private)
likely_region :: proc(lang: string) -> (region: string, ok: bool) {
	switch lang {
	case "en": return "US", true
	case "de": return "DE", true
	case "fr": return "FR", true
	case "es": return "ES", true
	case "pt": return "BR", true
	case "it": return "IT", true
	case "nl": return "NL", true
	case "pl": return "PL", true
	case "nb", "no", "nn": return "NO", true
	case "sv": return "SE", true
	case "da": return "DK", true
	case "fi": return "FI", true
	case "is": return "IS", true
	case "ja": return "JP", true
	case "ko": return "KR", true
	case "zh": return "CN", true
	case "cs": return "CZ", true
	case "sk": return "SK", true
	case "hu": return "HU", true
	case "ro": return "RO", true
	case "hr": return "HR", true
	case "sl": return "SI", true
	case "sr": return "RS", true
	case "bg": return "BG", true
	case "el": return "GR", true
	case "tr": return "TR", true
	case "ru": return "RU", true
	case "uk": return "UA", true
	case "et": return "EE", true
	case "lv": return "LV", true
	case "lt": return "LT", true
	case "he": return "IL", true
	}
	return "", false
}

@(private)
ascii_letters :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') {
			return false
		}
	}
	return true
}

@(private)
lower :: proc(c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

@(private)
upper :: proc(c: u8) -> u8 {
	return c - 32 if c >= 'a' && c <= 'z' else c
}
