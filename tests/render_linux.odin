package tidal_tests

import "core:testing"

import vk "vendor:vulkan"

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

// A failed submit releases the GPU objects partway through a frame, as when
// a glyph upload runs out of staging room. The rest of the frame keeps its
// clips and draws nothing.
@(test)
renderer_released_mid_frame_draws_nothing :: proc(t: ^testing.T) {
	r := new(render.Renderer, context.temp_allocator)
	render.begin_frame(r, 800, 600, 2, {0, 0, 0, 1})
	instances := make([]render.Instance, 64, context.temp_allocator)
	r.instances = raw_data(instances)
	r.capacity[r.slot] = len(instances)
	render.push_clip(r, {0, 0, 100, 100})
	render.push_rect(r, {0, 0, 10, 10}, {1, 1, 1, 1})
	render.release(r)
	render.push_shadow(r, {0, 0, 10, 10}, 4, 8)
	render.push_clip(r, {10, 10, 50, 50})
	render.pop_clip(r)
	render.end_frame(r)
	testing.expect(t, r.instances == nil, "instances point into freed memory")
	testing.expect_value(t, r.instance_count, 1)
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

// A write that misses each earlier one but lands in the box around them
// still waits, since the earlier writes are kept only as that box.
@(test)
writes_inside_the_box_around_earlier_ones_wait :: proc(t: ^testing.T) {
	written: [4]i32
	testing.expect(t, !render.write_region(&written, {0, 0, 10, 10}), "first write")
	testing.expect(t, !render.write_region(&written, {20, 20, 30, 30}), "apart from the first")
	testing.expect(t, render.write_region(&written, {12, 12, 15, 15}), "between them")
}

// The surface may clamp the asked size. The swapchain is made again when
// the window's size changes, not on every frame its extent differs.
@(test)
clamped_swapchain_is_not_made_every_frame :: proc(t: ^testing.T) {
	g := render.Gpu {
		swapchain = vk.SwapchainKHR(1),
		extent    = {640, 480},
		requested = {800, 600},
	}
	testing.expect(t, !render.swapchain_stale(&g, {800, 600}), "same size as asked")
	testing.expect(t, render.swapchain_stale(&g, {900, 600}), "window resized")
	g.requested = {}
	testing.expect(t, render.swapchain_stale(&g, {800, 600}), "out of date after present")
	g = {requested = {800, 600}}
	testing.expect(t, render.swapchain_stale(&g, {800, 600}), "no swapchain")
}
