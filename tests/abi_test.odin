package tidal_tests

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

import "../src/platform"
import "../third_party/kbts"

Shared :: struct {
	name: string,
	type: typeid,
}

// Prefix is how C reaches the fields of a struct that Odin embeds with using.
Prefix :: struct {
	type: typeid,
	path: string,
}

// The shell and the app share these structs through shell/platform.h. The
// size asserts on both sides miss two fields of the same size swapped, so
// this compiles a C program that prints every field's offset from the
// header and compares it with the Odin struct's.
@(test)
platform_h_matches_platform_odin :: proc(t: ^testing.T) {
	shared := []Shared {
		{"Event", platform.Event},
		{"Memory", platform.Memory},
		{"Now_Playing", platform.Now_Playing},
		{"Player_Controls", platform.Player_Controls},
		{"Text_Input", platform.Text_Input},
		{"Access_Node", platform.Access_Node},
		{"Wayland_Surface", platform.Wayland_Surface},
		{"Win32_Surface", platform.Win32_Surface},
		{"Shell", platform.Shell},
		{"Frame_Input", platform.Frame_Input},
		{"Frame_Result", platform.Frame_Result},
	}
	expect_layouts(t, "#include \"platform.h\"", "shell", "platform.odin", "platform.h", shared, nil)
}

// The kb_text_shape bindings are written by hand against the header, and a
// new version of the library can move a field without changing a name.
@(test)
kbts_bindings_match_kb_text_shape_h :: proc(t: ^testing.T) {
	shared := []Shared {
		{"kbts_blob_table", kbts.blob_table},
		{"kbts_load_font_state", kbts.load_font_state},
		{"kbts_blob_header", kbts.blob_header},
		{"kbts_font", kbts.font},
		{"kbts_font_info", kbts.font_info},
		{"kbts_font_info2", kbts.font_info2},
		{"kbts_font_info2_1", kbts.font_info2_1},
		{"kbts_font_info2_2", kbts.font_info2_2},
		{"kbts_feature_override", kbts.feature_override},
		{"kbts_variation", kbts.variation},
		{"kbts_variation_axis_info", kbts.variation_axis_info},
		{"kbts_variation_instance_info", kbts.variation_instance_info},
		{"kbts_uid", kbts.uid},
		{"kbts_break_state", kbts.break_state},
		{"kbts_decode", kbts.decode},
		{"kbts_glyph", kbts.glyph},
		{"kbts_shape_codepoint", kbts.shape_codepoint},
		{"kbts_shape_codepoint2", kbts.shape_codepoint2},
		{"kbts_shape_codepoint_iterator", kbts.shape_codepoint_iterator},
		{"kbts_glyph_iterator", kbts.glyph_iterator},
		{"kbts_arena", kbts.arena},
		{"kbts_glyph_storage", kbts.glyph_storage},
		{"kbts_font_coverage_test", kbts.font_coverage_test},
		{"kbts_run", kbts.run},
		{"kbts_run2", kbts.run2},
	}
	// C embeds a font_info2 as a field named Base; the Odin structs have it
	// with using, and the other using fields are flat in C.
	prefixes := []Prefix{{kbts.font_info2, "Base."}}
	expect_layouts(t, "#include <stdint.h>\n#include \"kb_text_shape.h\"", "third_party/kbts", "the kbts bindings", "kb_text_shape.h", shared, prefixes)
}

expect_layouts :: proc(t: ^testing.T, include, include_dir, odin_name, c_name: string, shared: []Shared, prefixes: []Prefix) {
	want, c := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&c, "#include <stdio.h>\n#include <stddef.h>\n%s\nint main(void) {{", include)
	for s in shared {
		fmt.sbprintfln(&want, "%s %d", s.name, reflect.size_of_typeid(s.type))
		fmt.sbprintfln(&c, "\tprintf(\"%s %%zu\\n\", sizeof(%s));", s.name, s.name)
		emit_fields(&want, &c, s.name, s.type, "", 0, prefixes)
	}
	fmt.sbprintln(&c, "\treturn 0;\n}")

	dir, _ := os.make_directory_temp("", "tidalfast-abi-*", context.temp_allocator)
	defer os.remove_all(dir)
	src := fmt.tprintf("%s/abi.c", dir)
	exe := fmt.tprintf("%s/abi", dir)
	testing.expect_value(t, os.write_entire_file(src, transmute([]u8)strings.to_string(c)), nil)
	when ODIN_OS == .Windows {
		exe = fmt.tprintf("%s\\abi.exe", dir)
		command := []string{"cl", "/nologo", "/std:c11", fmt.tprintf("/I%s", include_dir), src, fmt.tprintf("/Fe%s", exe), fmt.tprintf("/Fo%s\\abi.obj", dir)}
	} else {
		command := []string{"cc", fmt.tprintf("-I%s", include_dir), src, "-o", exe}
	}
	build, cc_out, cc_err, err := os.process_exec({command = command}, context.temp_allocator)
	// Odin's process_wait on Windows says success whatever the exit code.
	if !testing.expectf(t, err == nil && build.success && build.exit_code == 0, "cc failed: %v %s %s", err, string(cc_out), string(cc_err)) {
		return
	}
	run, got, run_err, rerr := os.process_exec({command = {exe}}, context.temp_allocator)
	testing.expectf(t, rerr == nil && run.success && run.exit_code == 0, "%s failed: %v %v %s", exe, rerr, run, string(run_err))

	want_lines := strings.split_lines(strings.trim_space(strings.to_string(want)), context.temp_allocator)
	got_lines := strings.split_lines(strings.trim_space(string(got)), context.temp_allocator)
	testing.expect_value(t, len(got_lines), len(want_lines))
	for line, i in want_lines {
		if i < len(got_lines) {
			testing.expectf(t, got_lines[i] == line, "%s has %q, %s %q", odin_name, line, c_name, got_lines[i])
		}
	}
}

// emit_fields writes each field's offset, going into using fields, whose
// fields C reaches through prefix.
@(private = "file")
emit_fields :: proc(want, c: ^strings.Builder, name: string, type: typeid, prefix: string, base: uintptr, prefixes: []Prefix) {
	for f in reflect.struct_fields_zipped(type) {
		if f.name == "_" {
			continue
		}
		if f.is_using {
			inner := prefix
			for p in prefixes {
				if p.type == f.type.id {
					inner = fmt.tprintf("%s%s", prefix, p.path)
				}
			}
			emit_fields(want, c, name, f.type.id, inner, base + f.offset, prefixes)
			continue
		}
		fmt.sbprintfln(want, "%s.%s%s %d", name, prefix, f.name, base + f.offset)
		fmt.sbprintfln(c, "\tprintf(\"%s.%s%s %%zu\\n\", offsetof(%s, %s%s));", name, prefix, f.name, name, prefix, f.name)
	}
}
