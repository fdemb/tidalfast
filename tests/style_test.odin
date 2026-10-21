package tidal_tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The app styles boxes through the stacks. A style field written on a box
// after it's built is allowed only when the value reads that box, as in
// `b.text_color = mix(SECONDARY, TEXT, b.hot_t)`, or when the write sits
// right under an `if` that tests the box, as under `if ui.drop_hover(item)`.
@(test)
test_app_styles_go_through_the_stacks :: proc(t: ^testing.T) {
	FIELDS :: []string{"font", "font_size", "text_color", "text_align", "text_pad", "background", "border_color", "hover_color", "active_color", "radius"}
	files, _ := filepath.glob("src/app/*.odin", context.temp_allocator)
	testing.expect(t, len(files) > 0, "the app's sources")
	for path in files {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expect(t, err == nil, path) {
			continue
		}
		above := ""
		for line, n in strings.split_lines(string(data), context.temp_allocator) {
			code := strings.trim_space(line)
			defer if code != "" {
				above = code
			}
			dot := strings.index_byte(code, '.')
			eq := strings.index(code, " = ")
			if dot <= 0 || eq < dot || strings.contains(code[:dot], " ") {
				continue
			}
			box := code[:dot]
			field := strings.trim_suffix(code[dot + 1:eq], " +")
			reads_box := strings.contains(code[eq:], fmt.tprintf("%s.", box))
			tested_above := strings.has_prefix(above, "if ") && strings.contains(above, fmt.tprintf("(%s)", box))
			for f in FIELDS {
				if field == f && !reads_box && !tested_above {
					testing.fail_now(t, fmt.tprintf("%s:%d sets %s after the box is built; use a style scope or ui.set_next_%s: %s", path, n + 1, f, f, code))
				}
			}
		}
	}
}
