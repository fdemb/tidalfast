package tidal_tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"


// The app styles boxes through the stacks. A style field written on a box
// after it's built is allowed only where the value comes from the box's own
// state, which the stacks can't know before it's built.
@(test)
test_app_styles_go_through_the_stacks :: proc(t: ^testing.T) {
	ALLOWED :: []string {
		"b.text_color = mix(SECONDARY, TEXT, b.hot_t)", // cards.odin, text_button lights as it's hovered
		"item.border_color = ACCENT", // library.odin, under ui.drop_hover(item)
	}
	FIELDS :: []string{"font", "font_size", "text_color", "text_align", "text_pad", "background", "border_color", "hover_color", "active_color", "radius"}
	files, _ := filepath.glob("src/app/*.odin", context.temp_allocator)
	testing.expect(t, len(files) > 0, "the app's sources")
	for path in files {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expect(t, err == nil, path) {
			continue
		}
		for line, n in strings.split_lines(string(data), context.temp_allocator) {
			code := strings.trim_space(line)
			dot := strings.index_byte(code, '.')
			eq := strings.index(code, " = ")
			if dot <= 0 || eq < dot || strings.contains(code[:dot], " ") {
				continue
			}
			field := strings.trim_suffix(code[dot + 1:eq], " +")
			allowed := false
			for a in ALLOWED {
				allowed ||= code == a
			}
			for f in FIELDS {
				if field == f && !allowed {
					testing.fail_now(t, fmt.tprintf("%s:%d sets %s after the box is built; use a style scope or ui.set_next_%s: %s", path, n + 1, f, f, code))
				}
			}
		}
	}
}
