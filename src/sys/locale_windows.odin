#+build windows
package sys

import "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(private, default_calling_convention = "system")
foreign kernel32 {
	GetUserDefaultLocaleName :: proc(name: [^]u16, length: i32) -> i32 ---
}

// locale is the user's locale as TIDAL's ll_CC, from
// GetUserDefaultLocaleName ("pl-PL"), see locale_normalize.
locale :: proc(allocator := context.allocator) -> string {
	wide: [windows.LOCALE_NAME_MAX_LENGTH]u16
	// The length counts the terminating NUL; 0 is a failure.
	n := int(GetUserDefaultLocaleName(&wide[0], i32(len(wide))))
	if n <= 1 || n > len(wide) {
		return locale_normalize("", allocator)
	}
	// Locale names are ASCII. Anything else isn't one locale_normalize takes.
	name: [windows.LOCALE_NAME_MAX_LENGTH]u8
	for c, i in wide[:n - 1] {
		if c > 127 {
			return locale_normalize("", allocator)
		}
		name[i] = u8(c)
	}
	return locale_normalize(string(name[:n - 1]), allocator)
}
