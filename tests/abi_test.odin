package tidal_tests

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

import "../src/platform"

// The shell and the app share these structs through shell/platform.h. The
// size asserts on both sides miss two fields of the same size swapped, so
// this compiles a C program that prints every field's offset from the
// header and compares it with the Odin struct's.
@(test)
platform_h_matches_platform_odin :: proc(t: ^testing.T) {
	Shared :: struct {
		name: string,
		type: typeid,
	}
	shared := []Shared {
		{"Event", platform.Event},
		{"Memory", platform.Memory},
		{"Now_Playing", platform.Now_Playing},
		{"Text_Input", platform.Text_Input},
		{"Access_Node", platform.Access_Node},
		{"Wayland_Surface", platform.Wayland_Surface},
		{"Shell", platform.Shell},
		{"Frame_Input", platform.Frame_Input},
		{"Frame_Result", platform.Frame_Result},
		{"App_API", platform.App_API},
	}
	want, c := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&c, "#include <stdio.h>\n#include \"platform.h\"\nint main(void) {")
	for s in shared {
		fmt.sbprintfln(&want, "%s %d", s.name, reflect.size_of_typeid(s.type))
		fmt.sbprintfln(&c, "\tprintf(\"%s %%zu\\n\", sizeof(%s));", s.name, s.name)
		for f in reflect.struct_fields_zipped(s.type) {
			if f.name == "_" {
				continue
			}
			fmt.sbprintfln(&want, "%s.%s %d", s.name, f.name, f.offset)
			fmt.sbprintfln(&c, "\tprintf(\"%s.%s %%zu\\n\", offsetof(%s, %s));", s.name, f.name, s.name, f.name)
		}
	}
	fmt.sbprintln(&c, "\treturn 0;\n}")

	dir, _ := os.make_directory_temp("", "tidalfast-abi-*", context.temp_allocator)
	defer os.remove_all(dir)
	src := fmt.tprintf("%s/abi.c", dir)
	exe := fmt.tprintf("%s/abi", dir)
	testing.expect_value(t, os.write_entire_file(src, transmute([]u8)strings.to_string(c)), nil)
	build, _, cc_err, err := os.process_exec({command = {"cc", "-Ishell", src, "-o", exe}}, context.temp_allocator)
	if !testing.expectf(t, err == nil && build.success, "cc failed: %v %s", err, string(cc_err)) {
		return
	}
	run, got, _, rerr := os.process_exec({command = {exe}}, context.temp_allocator)
	testing.expect(t, rerr == nil && run.success)

	want_lines := strings.split_lines(strings.trim_space(strings.to_string(want)), context.temp_allocator)
	got_lines := strings.split_lines(strings.trim_space(string(got)), context.temp_allocator)
	testing.expect_value(t, len(got_lines), len(want_lines))
	for line, i in want_lines {
		if i < len(got_lines) {
			testing.expectf(t, got_lines[i] == line, "platform.odin has %q, platform.h %q", line, got_lines[i])
		}
	}
}
