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
	// 50% white comes out as 188, as docs/renderer.md says.
	pixels = {128, 128, 128, 128}
	render.convert_premultiplied(pixels[:])
	testing.expect_value(t, pixels, [4]u8{188, 188, 188, 128})
}

// Covers and the text next to them share a draw call: colour and coverage
// textures have a slot each in a batch, so only another texture of a kind
// already bound starts a new one. Plain data, no GPU: a slot only needs a
// size to count as live.
@(test)
batches_bind_a_colour_and_a_coverage_texture :: proc(t: ^testing.T) {
	r := new(render.Renderer, context.temp_allocator)
	cover_page, other_page, glyphs := render.Texture(1), render.Texture(2), render.Texture(3)
	r.textures[1] = {width = 640, height = 640, format = .RGBA8}
	r.textures[2] = {width = 640, height = 640, format = .RGBA8}
	r.textures[3] = {width = 2048, height = 2048, format = .R8}
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

// push_sprite is push_image for a rect already on whole pixels, as glyphs
// are: at any scale it must write the instance push_image does.
@(test)
sprites_match_images :: proc(t: ^testing.T) {
	r := new(render.Renderer, context.temp_allocator)
	glyphs, emoji, stale := render.Texture(1), render.Texture(2), render.Texture(3 | 5 << 16)
	r.textures[1] = {width = 512, height = 512, format = .R8}
	r.textures[2] = {width = 256, height = 256, format = .BGRA8}
	instances := make([]render.Instance, 64, context.temp_allocator)
	r.instances = raw_data(instances)
	r.capacity[0] = len(instances)
	r.clip_depth = 1
	r.clips[0] = {-1e9, -1e9, 1e9, 1e9}
	for scale in ([]f32{1, 2, 1.5, 1.25}) {
		r.scale = scale
		for texture in ([]render.Texture{glyphs, emoji, stale}) {
			for dst in ([][4]f32{{10, 20, 17, 31}, {-3, 7, 0, 19}, {1023, 2047, 1030, 2060}}) {
				src := render.Rect{5, 9, dst.z - dst.x, dst.w - dst.y}
				tint := render.Color{0.9, 0.8, 0.7, 0.6}
				r.instance_count, r.batch_count = 0, 0
				render.push_clip(r, {2, 3, 400, 500})
				rect := render.Rect{dst.x / scale, dst.y / scale, (dst.z - dst.x) / scale, (dst.w - dst.y) / scale}
				render.push_image(r, rect, texture, src, tint)
				render.push_sprite(r, dst, texture, src, tint)
				render.pop_clip(r)
				testing.expect_value(t, r.instance_count, 2)
				testing.expectf(t, instances[0] == instances[1], "scale %v texture %v dst %v: %v, want %v", scale, texture, dst, instances[1], instances[0])
			}
		}
	}
}

// The backdrop blurs again only when its hash changes, so a change to an
// instance under it must change the hash, and the same frame must not.
@(test)
backdrop_hash_follows_what_it_blurs :: proc(t: ^testing.T) {
	if !render.BACKDROPS {
		return
	}
	r := new(render.Renderer, context.temp_allocator)
	instances := make([]render.Instance, 64, context.temp_allocator)
	r.instances = raw_data(instances)
	r.capacity[0] = len(instances)
	r.scale = 2
	r.width, r.height = 400, 300
	frame :: proc(r: ^render.Renderer, under: render.Color, x: f32) -> u64 {
		r.instance_count, r.batch_count = 0, 0
		r.clip_depth = 1
		r.clips[0] = {-1e9, -1e9, 1e9, 1e9}
		r.backdrop = {batch = -1}
		render.push_rect(r, {0, 0, 400, 30}, {1, 1, 1, 1}) // far above the bar
		render.push_rect(r, {x, 240, 100, 20}, under)
		render.push_backdrop(r, {0, 250, 400, 50}, 20, 1.5, {0, 0, 0, 0.5})
		return r.backdrop.hash
	}
	h := frame(r, {0.2, 0.3, 0.4, 1}, 10)
	testing.expect(t, h != 0)
	testing.expect_value(t, frame(r, {0.2, 0.3, 0.4, 1}, 10), h)
	testing.expect(t, frame(r, {0.2, 0.3, 0.41, 1}, 10) != h)
	testing.expect(t, frame(r, {0.2, 0.3, 0.4, 1}, 10.5) != h)
}
