package tidal_tests

import "core:testing"

import "../src/render"

// When Vulkan can't start, init tears down what it made and leaves the
// renderer zeroed, without a device, and the app carries on. Every call
// after that must draw nothing rather than call a Vulkan procedure that
// was never loaded.
@(test)
renderer_without_a_device_draws_nothing :: proc(t: ^testing.T) {
	r := new(render.Renderer, context.temp_allocator)
	tex := render.texture_create(r, 4, 4, .RGBA8)
	pixels: [4 * 4 * 4]u8
	render.texture_update(r, tex, pixels[:], 0, 0, 4, 4)
	for _ in 0 ..< 4 {
		render.begin_frame(r, 800, 600, 2, {0, 0, 0, 1})
		render.push_rect(r, {0, 0, 10, 10}, {1, 1, 1, 1})
		render.push(r, {0, 0, 10, 10}, {texture = tex})
		render.end_frame(r)
	}
	render.texture_destroy(r, tex)
	testing.expect_value(t, r.instance_count, 0)
	render.destroy(r)
}

// Glyphs written to an atlas page in one frame share one pair of barriers,
// so a copy waits for the ones before it only when their texels overlap.
@(test)
only_overlapping_texture_writes_wait :: proc(t: ^testing.T) {
	written: [4]i32
	testing.expect(t, !render.write_region(&written, {0, 0, 10, 12}), "first write")
	testing.expect(t, !render.write_region(&written, {11, 0, 20, 12}), "next on the shelf")
	testing.expect(t, !render.write_region(&written, {0, 13, 8, 20}), "next shelf down")
	testing.expect(t, render.write_region(&written, {5, 5, 6, 6}), "inside an earlier write")
	testing.expect(t, !render.write_region(&written, {0, 0, 5, 5}), "the barrier settled the earlier writes")
	testing.expect(t, render.write_region(&written, {4, 4, 9, 9}), "overlaps the write after the barrier")
}
