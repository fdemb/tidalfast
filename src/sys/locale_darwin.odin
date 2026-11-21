#+build darwin
package sys

import CF "core:sys/darwin/CoreFoundation"

foreign import CoreFoundation "system:CoreFoundation.framework"

@(private)
CF_STRING_ENCODING_UTF8 :: 0x08000100

@(private, default_calling_convention = "c")
foreign CoreFoundation {
	CFRelease :: proc(cf: rawptr) ---
	CFLocaleCopyPreferredLanguages :: proc() -> rawptr --- // CFArrayRef of CFStringRef
	CFLocaleCopyCurrent :: proc() -> rawptr --- // CFLocaleRef
	CFLocaleGetIdentifier :: proc(locale: rawptr) -> rawptr --- // CFStringRef
	CFArrayGetCount :: proc(array: rawptr) -> int ---
	CFArrayGetValueAtIndex :: proc(array: rawptr, index: int) -> rawptr ---
}

// locale is the user's language as TIDAL's ll_CC: the first of the
// preferred languages in System Settings ("pl-PL"), or the current
// locale's identifier when there are none, see locale_normalize.
locale :: proc(allocator := context.allocator) -> string {
	buf: [64]u8
	name := ""
	if langs := CFLocaleCopyPreferredLanguages(); langs != nil {
		if CFArrayGetCount(langs) > 0 {
			name = cf_cstring(CFArrayGetValueAtIndex(langs, 0), buf[:])
		}
		CFRelease(langs)
	}
	if name == "" {
		if current := CFLocaleCopyCurrent(); current != nil {
			name = cf_cstring(CFLocaleGetIdentifier(current), buf[:])
			CFRelease(current)
		}
	}
	return locale_normalize(name, allocator)
}

// cf_cstring copies a CFString into buf, "" if it doesn't fit.
@(private = "file")
cf_cstring :: proc(s: rawptr, buf: []u8) -> string {
	if s == nil || !CF.StringGetCString(CF.String(s), raw_data(buf), CF.Index(len(buf)), CF.StringEncoding(CF_STRING_ENCODING_UTF8)) {
		return ""
	}
	return string(cstring(raw_data(buf)))
}
