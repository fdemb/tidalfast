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
			if i := strings.index(code, "//"); i >= 0 {
				code = strings.trim_space(code[:i])
			}
			defer if code != "" {
				above = code
			}
			box, field, value, ok := style_write(code)
			if !ok {
				continue
			}
			reads_box := strings.contains(value, fmt.tprintf("%s.", box))
			tested_above := strings.has_prefix(above, "if ") && strings.contains(above, fmt.tprintf("(%s)", box))
			if !reads_box && !tested_above {
				testing.fail_now(t, fmt.tprintf("%s:%d sets %s after the box is built; use a style scope or ui.set_next_%s: %s", path, n + 1, field, field, code))
			}
		}
	}
}

// style_write splits an assignment to a box's style field, or to part of
// one, such as `sig.box.radius = 8`, `b.text_color += tint` or
// `bar.background.a = 0.5`, into the box's expression, the field and the
// value.
@(private = "file")
style_write :: proc(code: string) -> (box, field, value: string, ok: bool) {
	FIELDS :: []string{"font", "font_size", "text_color", "text_align", "text_pad", "background", "border_color", "hover_color", "active_color", "radius"}
	eq := strings.index(code, "= ")
	if eq <= 0 || strings.has_prefix(code[eq - 1:], "==") || strings.contains_any(code[:eq], "(\"") {
		return
	}
	target := strings.trim_space(strings.trim_right(code[:eq], "+-*/ "))
	if strings.contains(target, " ") {
		return
	}
	parts := strings.split(target, ".", context.temp_allocator)
	for p, i in parts[1:] {
		for f in FIELDS {
			if p == f {
				return strings.join(parts[:i + 1], ".", context.temp_allocator), f, code[eq + 1:], true
			}
		}
	}
	return
}
