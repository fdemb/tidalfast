package tidal

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

@(private)
Allocator :: mem.Allocator
@(private)
JSON_Object :: json.Object

// scratch_begin opens a temp-allocator region that is released when the
// calling proc returns. Skipped when the caller asked for results in temp
// memory.
@(private, deferred_out = scratch_end)
scratch_begin :: proc(allocator: mem.Allocator, loc := #caller_location) -> runtime.Arena_Temp {
	if allocator == context.temp_allocator {
		return {}
	}
	return runtime.default_temp_allocator_temp_begin(loc)
}

@(private)
scratch_end :: proc(temp: runtime.Arena_Temp) {
	if temp.arena != nil {
		runtime.default_temp_allocator_temp_end(temp)
	}
}

// Appends a query/form parameter, formatting value in temp memory.
@(private)
add_param :: proc(params: ^[dynamic]Param, key: string, value: any) {
	append(params, Param{key, fmt.tprint(value)})
}

@(private)
make_params :: proc() -> [dynamic]Param {
	return make([dynamic]Param, 0, 8, context.temp_allocator)
}

// Image URL from one of the Config format strings.
@(private)
resource_url :: proc(format: string, id: string, width, height: int, allocator: mem.Allocator) -> string {
	path, _ := strings.replace_all(id, "-", "/", context.temp_allocator)
	return fmt.aprintf(format, path, width, height, allocator = allocator)
}

@(private)
resource_url_origin :: proc(format: string, id: string, allocator: mem.Allocator) -> string {
	path, _ := strings.replace_all(id, "-", "/", context.temp_allocator)
	return fmt.aprintf(format, path, allocator = allocator)
}

@(private)
invalid_resolution :: proc(width, height: int) -> Error {
	return make_error(.Invalid_Argument, "Invalid resolution")
}

// Joins strings with commas, in temp memory.
@(private)
join_ids :: proc(ids: []string) -> string {
	return strings.join(ids, ",", context.temp_allocator)
}

// Sizes TIDAL serves for wide (video and playlist) images.
@(private)
valid_wide_size :: proc(width, height: int) -> bool {
	switch {
	case width == 160 && height == 107, width == 480 && height == 320, width == 750 && height == 500, width == 1080 && height == 720:
		return true
	}
	return false
}
