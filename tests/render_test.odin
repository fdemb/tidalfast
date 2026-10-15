package tidal_tests

import "core:testing"

import "../src/render"

@(test)
test_premultiplied_lut :: proc(t: ^testing.T) {
	pixels: [4]u8
	for a in 0 ..< 256 {
		for c in 0 ..< 256 {
			pixels = {u8(c), u8(c), u8(c), u8(a)}
			render.convert_premultiplied(pixels[:])
			want := u8(c) if a == 0 || a == 255 else render.premultiplied_exact(u8(c), u8(a))
			if pixels[0] != want || pixels[3] != u8(a) {
				testing.expectf(t, false, "c %d a %d: got %d, want %d", c, a, pixels[0], want)
				return
			}
		}
	}
	// 50% white comes out as 188, as the README says.
	pixels = {128, 128, 128, 128}
	render.convert_premultiplied(pixels[:])
	testing.expect_value(t, pixels, [4]u8{188, 188, 188, 128})
}

// Covers and the text next to them share a draw call: colour and coverage
// textures have a slot each in a batch, so only another texture of a kind
// already bound starts a new one. Plain data, no Metal: the slots only need
// a non-nil texture.
@(test)
batches_bind_a_colour_and_a_coverage_texture :: proc(t: ^testing.T) {
	r := new(render.Renderer, context.temp_allocator)
	cover_page, other_page, glyphs := render.Texture(1), render.Texture(2), render.Texture(3)
	r.textures[1] = {texture = rawptr(uintptr(1)), width = 640, height = 640, format = .RGBA8}
	r.textures[2] = {texture = rawptr(uintptr(2)), width = 640, height = 640, format = .RGBA8}
	r.textures[3] = {texture = rawptr(uintptr(3)), width = 2048, height = 2048, format = .R8}
	instances := make([]render.Instance, 64, context.temp_allocator)
	r.instances = raw_data(instances)
	r.capacity[0] = len(instances)
	r.scale = 1
	r.clip_depth = 1
	r.clips[0] = {-1e9, -1e9, 1e9, 1e9}

	// Ten rows of a cover, a label and a solid rect.
	for i in 0 ..< 10 {
		y := f32(i) * 56
		render.push_image(r, {0, y, 40, 40}, cover_page, {80, 0, 80, 80})
		render.push_image(r, {50, y, 8, 12}, glyphs, {0, 0, 8, 12})
		render.push_rect(r, {0, y, 400, 1}, {1, 1, 1, 0.1})
	}
	testing.expect_value(t, r.batch_count, 1)
	testing.expect_value(t, r.batches[0].textures, [2]render.Texture{cover_page, glyphs})
	testing.expect_value(t, r.batches[0].count, 30)
	testing.expect(t, .Coverage in instances[1].flags && .Coverage not_in instances[0].flags)
	testing.expect_value(t, instances[0].src, [4]f32{0.125, 0, 0.25, 0.125})

	// A cover on another page needs the colour slot: a second batch, which
	// binds the glyphs again when they come.
	render.push_image(r, {0, 600, 40, 40}, other_page)
	render.push_image(r, {50, 600, 8, 12}, glyphs, {0, 0, 8, 12})
	testing.expect_value(t, r.batch_count, 2)
	testing.expect_value(t, r.batches[1].textures, [2]render.Texture{other_page, glyphs})
	testing.expect_value(t, r.batches[1].first, 30)
}
