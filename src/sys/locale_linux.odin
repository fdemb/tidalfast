#+build linux
package sys

import "core:os"

// locale is the user's language as TIDAL's ll_CC, from the first of
// LC_ALL, LC_MESSAGES and LANG that is set, see locale_normalize.
locale :: proc(allocator := context.allocator) -> string {
	for name in ([]string{"LC_ALL", "LC_MESSAGES", "LANG"}) {
		if v := os.get_env(name, context.temp_allocator); v != "" {
			return locale_normalize(v, allocator)
		}
	}
	return locale_normalize("", allocator)
}
