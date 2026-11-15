// The CPU rasterizer: draws a frame's instances into a BGRA8 sRGB buffer
// with no GPU. The frame is cut into CPU_TILE pixel tiles. Each instance goes
// into the tiles its pixels touch, and each tile hashes what it draws. A
// target keeps the hash of every tile it holds, so only tiles whose hash
// changed are drawn again, by a pool of worker threads. A tile is drawn in
// premultiplied linear f32 and encoded to sRGB once at the end, so it blends
// as the GPU does.
//
// Instances sort into kinds: opaque and translucent fills, glyphs and images
// drawn 1:1 from a texture, and the general case, which runs the fragment
// shader's maths per pixel. The backend that presents the buffer (see
// cpu_darwin.odin) calls cpu_render.
package render

import "base:runtime"
import "core:math"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"

import "../sys"

CPU_TILE :: 64
CPU_MAX_WORKERS :: 7

// A pixel or texel in premultiplied linear light.
Px :: [4]f32

Cpu_Kind :: enum u8 {
	Skip,
	Fill_Opaque,
	Fill_Blend,
	Glyph, // R8 coverage, 1:1
	Image, // colour texture, 1:1
	General,
}

// Cpu_Prep is what the tiles need of an instance, worked out once a frame.
Cpu_Prep :: struct {
	bounds:  [4]i32, // the pixels it may touch, x0 y0 x1 y1
	color:   Px, // its colour, where all four corners share one
	tex:     ^Texture_Slot,
	offset:  [2]i32, // texel minus pixel, for Glyph and Image
	hash:    u64,
	kind:    Cpu_Kind,
	uniform: bool,
}

// Cpu_Texture is a texture's texels in memory: R8, or RGBA8 with BGRA8
// swizzled to RGBA on the way in.
Cpu_Texture :: struct {
	pixels:  []u8,
	version: u32,
}

// Cpu_Target is a buffer to draw into and the hash of each tile it holds.
Cpu_Target :: struct {
	pixels:        [^]u8,
	stride:        int, // bytes per row
	width, height: int,
	hashes:        []u64,
}

Cpu_Job :: enum u8 {
	Tiles,
	Scene,
}

Cpu_Worker :: struct {
	cpu:   ^Cpu,
	index: int,
}

Cpu :: struct {
	instances:      [^]Instance,
	capacity:       int,
	prep:           []Cpu_Prep,

	tiles_x:        int,
	tiles_y:        int,
	tile_first:     []u32,
	tile_count:     []u32,
	refs:           []u32, // instance indices, tile by tile, in drawing order
	dirty:          []u32,
	dirty_count:    int,

	// The frame being drawn, for the workers.
	r:              ^Renderer,
	target:         Cpu_Target,
	clear:          Px,
	job:            Cpu_Job,
	job_count:      int,
	next:           int,
	scene_tiles:    []u32,

	workers:        [CPU_MAX_WORKERS]sys.Thread,
	worker_args:    [CPU_MAX_WORKERS]Cpu_Worker,
	worker_count:   int,
	wake:           sync.Sema,
	done:           sync.Wait_Group,
	quit:           bool,
	scratch:        [CPU_MAX_WORKERS + 1][]Px,

	// The backdrop: what's under it at half size from scene_origin, blurred.
	scene:          []Px,
	blur:           []Px,
	scene_origin:   [2]int,
	scene_size:     [2]int,
	blurred_hash:   u64,
}

cpu_srgb_decode: [256]f32
cpu_linear_lut: [4097]f32
cpu_srgb_encode: [65536]u8

cpu_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

cpu_init :: proc(c: ^Cpu) {
	for i in 0 ..< 256 {
		cpu_srgb_decode[i] = linear_from_srgb(f32(i) / 255)
	}
	for i in 0 ..< len(cpu_linear_lut) {
		cpu_linear_lut[i] = linear_from_srgb(f32(i) / 4096)
	}
	for i in 0 ..< len(cpu_srgb_encode) {
		cpu_srgb_encode[i] = u8(math.round(srgb_from_linear(f32(i) / 65535) * 255))
	}
	a := cpu_allocator()
	c.capacity = INITIAL_INSTANCES
	c.instances = ([^]Instance)(mem.alloc(c.capacity * size_of(Instance), allocator = a) or_else nil)
	c.prep = make([]Cpu_Prep, c.capacity, a)
	for &s in c.scratch {
		s = make([]Px, CPU_TILE * CPU_TILE, a)
	}
	c.worker_count = clamp(os.get_processor_core_count() - 1, 0, CPU_MAX_WORKERS)
	for i in 0 ..< c.worker_count {
		c.worker_args[i] = {c, i + 1}
		if !sys.thread_start(&c.workers[i], cpu_worker_main, &c.worker_args[i]) {
			c.worker_count = i
			break
		}
	}
}

cpu_destroy :: proc(c: ^Cpu) {
	c.quit = true
	sync.sema_post(&c.wake, c.worker_count)
	for i in 0 ..< c.worker_count {
		sys.thread_join(c.workers[i])
	}
	a := cpu_allocator()
	mem.free(c.instances, a)
	delete(c.prep, a)
	delete(c.tile_first, a)
	delete(c.tile_count, a)
	delete(c.refs, a)
	delete(c.dirty, a)
	delete(c.scene_tiles, a)
	delete(c.scene, a)
	delete(c.blur, a)
	for s in c.scratch {
		delete(s, a)
	}
}

// cpu_memory is the heap the rasterizer keeps, in bytes, apart from
// textures and the buffers it draws into.
cpu_memory :: proc(c: ^Cpu) -> Gpu_Memory {
	m: Gpu_Memory
	m.instances = c.capacity * (size_of(Instance) + size_of(Cpu_Prep)) + len(c.refs) * 4 + len(c.tile_first) * 8
	m.staging = len(c.scratch) * CPU_TILE * CPU_TILE * size_of(Px)
	m.backdrop = (len(c.scene) + len(c.blur)) * size_of(Px)
	return m
}

cpu_frame_begin :: proc(r: ^Renderer, c: ^Cpu) -> [^]Instance {
	r.capacity[r.slot] = c.capacity
	return c.instances
}

cpu_grow :: proc(r: ^Renderer, c: ^Cpu) {
	a := cpu_allocator()
	capacity := c.capacity * 2
	instances := ([^]Instance)(mem.alloc(capacity * size_of(Instance), allocator = a) or_else nil)
	if instances == nil {
		return
	}
	mem.copy(instances, c.instances, r.instance_count * size_of(Instance))
	mem.free(c.instances, a)
	delete(c.prep, a)
	c.prep = make([]Cpu_Prep, capacity, a)
	c.instances = instances
	c.capacity = capacity
	r.capacity[r.slot] = capacity
	r.instances = instances
}

// Textures

cpu_texture_slot :: proc(width, height: int, format: Texture_Format, mipmapped: bool) -> Texture_Slot {
	bpp := 1 if format == .R8 else 4
	pixels := make([]u8, width * height * bpp, cpu_allocator())
	return {cpu = {pixels = pixels}, width = i32(width), height = i32(height), format = format, mipmapped = mipmapped}
}

cpu_texture_write :: proc(slot: ^Texture_Slot, pixels: []byte, x, y, w, h, bpp: int) {
	tw := int(slot.width)
	for row in 0 ..< h {
		from := pixels[row * w * bpp:][:w * bpp]
		to := slot.cpu.pixels[((y + row) * tw + x) * bpp:][:w * bpp]
		if slot.format == .BGRA8 {
			for i := 0; i < len(from); i += 4 {
				to[i], to[i + 1], to[i + 2], to[i + 3] = from[i + 2], from[i + 1], from[i], from[i + 3]
			}
		} else {
			copy(to, from)
		}
	}
	slot.cpu.version += 1
}

cpu_texture_copy :: proc(from, to: ^Texture_Slot, w, h: int) {
	bpp := 1 if from.format == .R8 else 4
	for row in 0 ..< h {
		copy(to.cpu.pixels[row * int(to.width) * bpp:][:w * bpp], from.cpu.pixels[row * int(from.width) * bpp:][:w * bpp])
	}
	to.cpu.version += 1
}

// Frame

// cpu_render draws the frame into target, only the tiles whose hash differs
// from the one target holds. It returns how many tiles it drew and a hash
// of the whole frame.
cpu_render :: proc(r: ^Renderer, c: ^Cpu, target: Cpu_Target) -> (drawn: int, frame_hash: u64) {
	c.r = r
	c.target = target
	c.clear = {linear_from_srgb(r.clear.r), linear_from_srgb(r.clear.g), linear_from_srgb(r.clear.b), r.clear.a}
	cpu_bin(r, c)

	if r.backdrop.batch >= 0 && r.backdrop.hash != c.blurred_hash {
		cpu_backdrop(r, c)
		c.blurred_hash = r.backdrop.hash
	}

	seed := hash_words(&c.clear, 0x51ed270b27a3d9f1)
	frame_hash = seed
	c.dirty_count = 0
	for t in 0 ..< c.tiles_x * c.tiles_y {
		h := seed
		refs := c.refs[c.tile_first[t]:][:c.tile_count[t]]
		for i in cpu_tile_start(c, t, refs, max(int)) ..< len(refs) {
			h = bits_mix(h, c.prep[refs[i]].hash)
		}
		frame_hash = bits_mix(frame_hash, h)
		if target.hashes[t] != h {
			target.hashes[t] = h
			c.dirty[c.dirty_count] = u32(t)
			c.dirty_count += 1
		}
	}
	cpu_run(c, .Tiles, c.dirty_count)
	return c.dirty_count, frame_hash
}

bits_mix :: #force_inline proc "contextless" (h, w: u64) -> u64 {
	return bits.rotate_left64((h ~ w) * 0x9e3779b97f4a7c15, 29)
}

// cpu_bin works out each instance's Cpu_Prep and puts it into the tiles it
// touches.
@(private = "file")
cpu_bin :: proc(r: ^Renderer, c: ^Cpu) {
	a := cpu_allocator()
	w, h := c.target.width, c.target.height
	c.tiles_x = (w + CPU_TILE - 1) / CPU_TILE
	c.tiles_y = (h + CPU_TILE - 1) / CPU_TILE
	tiles := c.tiles_x * c.tiles_y
	if len(c.tile_first) < tiles {
		delete(c.tile_first, a)
		delete(c.tile_count, a)
		delete(c.dirty, a)
		delete(c.scene_tiles, a)
		c.tile_first = make([]u32, tiles, a)
		c.tile_count = make([]u32, tiles, a)
		c.dirty = make([]u32, tiles, a)
		c.scene_tiles = make([]u32, tiles, a)
	}
	mem.zero_slice(c.tile_count[:tiles])

	for b in r.batches[:r.batch_count] {
		for i in b.first ..< b.first + b.count {
			p := &c.prep[i]
			inst := &r.instances[i]
			texture := b.textures[1 if .Coverage in inst.flags else 0]
			cpu_prepare(r, inst, texture_slot(r, texture) if .Textured in inst.flags else nil, p, w, h)
			if p.kind == .Skip {
				continue
			}
			for ty in int(p.bounds.y) / CPU_TILE ..= int(p.bounds.w - 1) / CPU_TILE {
				for tx in int(p.bounds.x) / CPU_TILE ..= int(p.bounds.z - 1) / CPU_TILE {
					c.tile_count[ty * c.tiles_x + tx] += 1
				}
			}
		}
	}

	total: u32
	for t in 0 ..< tiles {
		c.tile_first[t] = total
		total += c.tile_count[t]
		c.tile_count[t] = 0
	}
	if len(c.refs) < int(total) {
		delete(c.refs, a)
		c.refs = make([]u32, max(int(total), 2 * len(c.refs)), a)
	}
	for i in 0 ..< r.instance_count {
		p := &c.prep[i]
		if p.kind == .Skip {
			continue
		}
		for ty in int(p.bounds.y) / CPU_TILE ..= int(p.bounds.w - 1) / CPU_TILE {
			for tx in int(p.bounds.x) / CPU_TILE ..= int(p.bounds.z - 1) / CPU_TILE {
				t := ty * c.tiles_x + tx
				c.refs[c.tile_first[t] + c.tile_count[t]] = u32(i)
				c.tile_count[t] += 1
			}
		}
	}
}

@(private = "file")
cpu_prepare :: proc(r: ^Renderer, inst: ^Instance, slot: ^Texture_Slot, p: ^Cpu_Prep, w, h: int) {
	p^ = {}
	if .Textured in inst.flags && slot == nil {
		return
	}
	pad := max(inst.softness, 0.5) + 1
	x0 := max(inst.dst.x - pad, inst.clip.x, 0)
	y0 := max(inst.dst.y - pad, inst.clip.y, 0)
	x1 := min(inst.dst.z + pad, inst.clip.z, f32(w))
	y1 := min(inst.dst.w + pad, inst.clip.w, f32(h))
	p.bounds = {i32(math.ceil(x0 - 0.5)), i32(math.ceil(y0 - 0.5)), i32(math.ceil(x1 - 0.5)), i32(math.ceil(y1 - 0.5))}
	if p.bounds.x >= p.bounds.z || p.bounds.y >= p.bounds.w {
		return
	}

	c0 := inst.colors[0]
	p.uniform = c0 == inst.colors[1] && c0 == inst.colors[2] && c0 == inst.colors[3]
	p.color = {linear_from_srgb(c0.r) * c0.a, linear_from_srgb(c0.g) * c0.a, linear_from_srgb(c0.b) * c0.a, c0.a}
	p.tex = slot

	p.kind = .General
	plain := inst.flags & {.Backdrop, .Glass, .Additive} == {} && inst.border == 0 && inst.softness == 0 && inst.radii == {} && p.uniform
	if plain {
		// A plain rect on whole pixels covers exactly its pixels.
		exact := [4]i32 {
			i32(max(inst.dst.x, inst.clip.x, 0)),
			i32(max(inst.dst.y, inst.clip.y, 0)),
			i32(min(inst.dst.z, inst.clip.z, f32(w))),
			i32(min(inst.dst.w, inst.clip.w, f32(h))),
		}
		if .Textured not_in inst.flags {
			p.kind = .Fill_Opaque if c0.a >= 1 else .Fill_Blend
			p.bounds = exact
		} else {
			tw, th := f32(slot.width), f32(slot.height)
			sx, sy := inst.src.x * tw, inst.src.y * th
			sw, sh := inst.src.z * tw - sx, inst.src.w * th - sy
			one_to_one :=
				abs(sw - (inst.dst.z - inst.dst.x)) < 0.01 &&
				abs(sh - (inst.dst.w - inst.dst.y)) < 0.01 &&
				abs(sx - math.round(sx)) < 0.01 &&
				abs(sy - math.round(sy)) < 0.01
			if one_to_one {
				p.kind = .Glyph if .Coverage in inst.flags else .Image
				p.offset = {i32(math.round(sx) - inst.dst.x), i32(math.round(sy) - inst.dst.y)}
				p.bounds = exact
			}
		}
		if p.bounds.x >= p.bounds.z || p.bounds.y >= p.bounds.w {
			p.kind = .Skip
			return
		}
	}

	h := hash_words(inst, 0)
	if slot != nil {
		h = bits_mix(h, u64(uintptr(slot)) ~ u64(slot.cpu.version) << 48)
	}
	if .Backdrop in inst.flags {
		h = bits_mix(h, r.backdrop.hash)
	}
	p.hash = h
}

// cpu_tile_start is where tile t starts drawing: at the last instance
// before limit that fills the whole tile with an opaque colour, or at 0.
@(private = "file")
cpu_tile_start :: proc(c: ^Cpu, t: int, refs: []u32, limit: int) -> int {
	x0, y0, x1, y1 := cpu_tile_rect(c, t)
	for i := len(refs) - 1; i >= 0; i -= 1 {
		if int(refs[i]) >= limit {
			continue
		}
		p := &c.prep[refs[i]]
		if p.kind == .Fill_Opaque && p.bounds.x <= i32(x0) && p.bounds.y <= i32(y0) && p.bounds.z >= i32(x1) && p.bounds.w >= i32(y1) {
			return i
		}
	}
	return 0
}

@(private = "file")
cpu_tile_rect :: proc(c: ^Cpu, t: int) -> (x0, y0, x1, y1: int) {
	x0 = t % c.tiles_x * CPU_TILE
	y0 = t / c.tiles_x * CPU_TILE
	return x0, y0, min(x0 + CPU_TILE, c.target.width), min(y0 + CPU_TILE, c.target.height)
}

// Workers

@(private = "file")
cpu_run :: proc(c: ^Cpu, job: Cpu_Job, count: int) {
	c.job = job
	c.job_count = count
	sync.atomic_store(&c.next, 0)
	helpers := min(c.worker_count, count - 1)
	if helpers > 0 {
		sync.wait_group_add(&c.done, helpers)
		sync.sema_post(&c.wake, helpers)
	}
	cpu_work(c, 0)
	if helpers > 0 {
		sync.wait_group_wait(&c.done)
	}
}

@(private = "file")
cpu_work :: proc(c: ^Cpu, worker: int) {
	for {
		i := sync.atomic_add(&c.next, 1)
		if i >= c.job_count {
			return
		}
		switch c.job {
		case .Tiles:
			cpu_draw_tile(c, worker, int(c.dirty[i]))
		case .Scene:
			cpu_scene_tile(c, worker, int(c.scene_tiles[i]))
		}
	}
}

@(private = "file")
cpu_worker_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	w := (^Cpu_Worker)(arg)
	c := w.cpu
	for {
		sync.sema_wait(&c.wake)
		if c.quit {
			return nil
		}
		cpu_work(c, w.index)
		sync.wait_group_done(&c.done)
	}
}

// Tiles

// cpu_raster draws the tile t's instances before limit into buf, a
// CPU_TILE wide tile of premultiplied linear pixels.
@(private = "file")
cpu_raster :: proc(c: ^Cpu, buf: []Px, t: int, limit: int) {
	x0, y0, x1, y1 := cpu_tile_rect(c, t)
	refs := c.refs[c.tile_first[t]:][:c.tile_count[t]]
	start := cpu_tile_start(c, t, refs, limit)
	if start == 0 && (len(refs) == 0 || !cpu_covers(c, refs[0], x0, y0, x1, y1)) {
		for y in 0 ..< y1 - y0 {
			for &px in buf[y * CPU_TILE:][:x1 - x0] {
				px = c.clear
			}
		}
	}
	for i in refs[start:] {
		if int(i) >= limit {
			break
		}
		cpu_draw(c, buf, i, x0, y0, x1, y1)
	}
}

@(private = "file")
cpu_covers :: proc(c: ^Cpu, i: u32, x0, y0, x1, y1: int) -> bool {
	p := &c.prep[i]
	return p.kind == .Fill_Opaque && p.bounds.x <= i32(x0) && p.bounds.y <= i32(y0) && p.bounds.z >= i32(x1) && p.bounds.w >= i32(y1)
}

@(private = "file")
cpu_draw_tile :: proc(c: ^Cpu, worker, t: int) {
	buf := c.scratch[worker]
	cpu_raster(c, buf, t, max(int))
	x0, y0, x1, y1 := cpu_tile_rect(c, t)
	for y in y0 ..< y1 {
		out := c.target.pixels[y * c.target.stride + x0 * 4:]
		row := buf[(y - y0) * CPU_TILE:]
		for x in 0 ..< x1 - x0 {
			px := row[x]
			out[x * 4 + 0] = cpu_encode(px.b)
			out[x * 4 + 1] = cpu_encode(px.g)
			out[x * 4 + 2] = cpu_encode(px.r)
			out[x * 4 + 3] = u8(clamp(px.a, 0, 1) * 255 + 0.5)
		}
	}
}

cpu_encode :: #force_inline proc "contextless" (v: f32) -> u8 {
	return cpu_srgb_encode[int(clamp(v, 0, 1) * 65535 + 0.5)]
}

cpu_linear :: #force_inline proc "contextless" (v: f32) -> f32 {
	f := clamp(v, 0, 1) * 4096
	i := min(int(f), 4095)
	t := f - f32(i)
	return cpu_linear_lut[i] + (cpu_linear_lut[i + 1] - cpu_linear_lut[i]) * t
}

@(private = "file")
cpu_draw :: proc(c: ^Cpu, buf: []Px, i: u32, tx0, ty0, tx1, ty1: int) {
	p := &c.prep[i]
	x0, y0 := max(int(p.bounds.x), tx0), max(int(p.bounds.y), ty0)
	x1, y1 := min(int(p.bounds.z), tx1), min(int(p.bounds.w), ty1)
	if x0 >= x1 || y0 >= y1 {
		return
	}
	switch p.kind {
	case .Skip:
	case .Fill_Opaque:
		for y in y0 ..< y1 {
			for &px in buf[(y - ty0) * CPU_TILE + x0 - tx0:][:x1 - x0] {
				px = p.color
			}
		}
	case .Fill_Blend:
		inv := 1 - p.color.a
		for y in y0 ..< y1 {
			for &px in buf[(y - ty0) * CPU_TILE + x0 - tx0:][:x1 - x0] {
				px = p.color + px * inv
			}
		}
	case .Glyph:
		tw := int(p.tex.width)
		pixels := p.tex.cpu.pixels
		for y in y0 ..< y1 {
			src := pixels[(y + int(p.offset.y)) * tw + x0 + int(p.offset.x):]
			row := buf[(y - ty0) * CPU_TILE + x0 - tx0:]
			for x in 0 ..< x1 - x0 {
				cov := src[x]
				if cov == 0 {
					continue
				}
				s := p.color * (f32(cov) * (1.0 / 255))
				row[x] = s + row[x] * (1 - s.a)
			}
		}
	case .Image:
		tw := int(p.tex.width)
		pixels := p.tex.cpu.pixels
		for y in y0 ..< y1 {
			src := pixels[((y + int(p.offset.y)) * tw + x0 + int(p.offset.x)) * 4:]
			row := buf[(y - ty0) * CPU_TILE + x0 - tx0:]
			for x in 0 ..< x1 - x0 {
				a := src[x * 4 + 3]
				if a == 0 {
					continue
				}
				s := p.color * Px{cpu_srgb_decode[src[x * 4]], cpu_srgb_decode[src[x * 4 + 1]], cpu_srgb_decode[src[x * 4 + 2]], f32(a) * (1.0 / 255)}
				row[x] = s + row[x] * (1 - s.a)
			}
		}
	case .General:
		cpu_general(c, &c.r.instances[i], p, buf, x0, y0, x1, y1, tx0, ty0)
	}
}

@(private = "file")
box_sdf :: #force_inline proc "contextless" (p, half: [2]f32, r: f32) -> f32 {
	q := [2]f32{abs(p.x), abs(p.y)} - half + r
	m := [2]f32{max(q.x, 0), max(q.y, 0)}
	return math.sqrt(m.x * m.x + m.y * m.y) + min(max(q.x, q.y), 0) - r
}

@(private = "file")
smoothstep :: #force_inline proc "contextless" (e0, e1, x: f32) -> f32 {
	t := clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private = "file")
inside :: #force_inline proc "contextless" (d, w: f32) -> f32 {
	return 1 - smoothstep(-w, w, d)
}

@(private = "file")
pm :: #force_inline proc "contextless" (c: Color) -> Px {
	return {c.r * c.a, c.g * c.a, c.b * c.a, c.a}
}

@(private = "file")
linear_premultiplied :: proc "contextless" (c: Color) -> Px {
	return {cpu_linear(c.r) * c.a, cpu_linear(c.g) * c.a, cpu_linear(c.b) * c.a, c.a}
}

// cpu_general is the fragment shader for one instance over x0 y0 x1 y1 of
// the tile at tx0 ty0.
@(private = "file")
cpu_general :: proc(c: ^Cpu, inst: ^Instance, p: ^Cpu_Prep, buf: []Px, x0, y0, x1, y1, tx0, ty0: int) {
	size := [2]f32{max(inst.dst.z - inst.dst.x, 1e-4), max(inst.dst.w - inst.dst.y, 1e-4)}
	half := size * 0.5
	centre := inst.dst.xy + half
	w := max(inst.softness, 0.5)
	rmax := min(max(inst.radii.x, inst.radii.y, inst.radii.z, inst.radii.w), min(half.x, half.y))
	// Inside safe the edge is far enough that coverage is 1; inside
	// hollow a border covers nothing.
	safe := half - (rmax + w + 1)
	hollow := half - inst.border - (rmax + w + 1)
	border := inst.border > 0
	for y in y0 ..< y1 {
		row := buf[(y - ty0) * CPU_TILE:]
		ly := f32(y) + 0.5 - centre.y
		for x in x0 ..< x1 {
			lx := f32(x) + 0.5 - centre.x
			ax, ay := abs(lx), abs(ly)
			if border && ax < hollow.x && ay < hollow.y {
				continue
			}
			local := [2]f32{lx, ly}
			radius := ly < 0 ? (lx < 0 ? inst.radii.x : inst.radii.y) : (lx < 0 ? inst.radii.z : inst.radii.w)
			radius = min(radius, min(half.x, half.y))
			coverage: f32 = 1
			if !(ax < safe.x && ay < safe.y) {
				coverage = inside(box_sdf(local, half, radius), w)
			}
			if border {
				coverage *= 1 - inside(box_sdf(local, half - inst.border, max(radius - inst.border, 0)), w)
			}
			if coverage <= 0 {
				continue
			}
			t := ([2]f32{f32(x) + 0.5, f32(y) + 0.5} - inst.dst.xy) / size

			color := p.color
			if !p.uniform {
				tc := [2]f32{clamp(t.x, 0, 1), clamp(t.y, 0, 1)}
				top := pm(inst.colors[0]) * (1 - tc.x) + pm(inst.colors[1]) * tc.x
				bottom := pm(inst.colors[2]) * (1 - tc.x) + pm(inst.colors[3]) * tc.x
				m := top * (1 - tc.y) + bottom * tc.y
				if m.a > 0 {
					color = {cpu_linear(m.r / m.a) * m.a, cpu_linear(m.g / m.a) * m.a, cpu_linear(m.b / m.a) * m.a, m.a}
				} else {
					color = {}
				}
			}

			if .Glass in inst.flags {
				color = cpu_glass(c, inst, local, half, radius, t)
			} else if .Backdrop in inst.flags {
				uv := inst.src.xy + (inst.src.zw - inst.src.xy) * t
				color = cpu_backdrop_at(c, uv, color, inst.extra)
			} else if .Textured in inst.flags {
				uv := inst.src.xy + (inst.src.zw - inst.src.xy) * t
				color *= cpu_sample(p.tex, uv, .Nearest in inst.flags)
			}

			out := color * coverage
			if .Additive in inst.flags {
				out.a = inst.extra * coverage
			}
			row[x - tx0] = out + row[x - tx0] * (1 - out.a)
		}
	}
}

@(private = "file")
cpu_fetch :: #force_inline proc "contextless" (slot: ^Texture_Slot, x, y: int) -> Px {
	if slot.format == .R8 {
		v := f32(slot.cpu.pixels[y * int(slot.width) + x]) * (1.0 / 255)
		return {v, v, v, v}
	}
	t := slot.cpu.pixels[(y * int(slot.width) + x) * 4:]
	return {cpu_srgb_decode[t[0]], cpu_srgb_decode[t[1]], cpu_srgb_decode[t[2]], f32(t[3]) * (1.0 / 255)}
}

// cpu_sample samples slot at uv with clamp to edge, filtered unless nearest.
@(private = "file")
cpu_sample :: proc "contextless" (slot: ^Texture_Slot, uv: [2]f32, nearest: bool) -> Px {
	tw, th := int(slot.width), int(slot.height)
	if nearest {
		return cpu_fetch(slot, clamp(int(math.floor(uv.x * f32(tw))), 0, tw - 1), clamp(int(math.floor(uv.y * f32(th))), 0, th - 1))
	}
	u, v := uv.x * f32(tw) - 0.5, uv.y * f32(th) - 0.5
	fu, fv := math.floor(u), math.floor(v)
	ax, ay := u - fu, v - fv
	xa, ya := int(fu), int(fv)
	x0, x1 := clamp(xa, 0, tw - 1), clamp(xa + 1, 0, tw - 1)
	y0, y1 := clamp(ya, 0, th - 1), clamp(ya + 1, 0, th - 1)
	top := cpu_fetch(slot, x0, y0) * (1 - ax) + cpu_fetch(slot, x1, y0) * ax
	bottom := cpu_fetch(slot, x0, y1) * (1 - ax) + cpu_fetch(slot, x1, y1) * ax
	return top * (1 - ay) + bottom * ay
}

// Backdrop

// cpu_backdrop draws what's under the backdrop at half size and blurs it.
// The half size grid starts on an even pixel, so no 2x2 block straddles two
// tiles and the tiles can go in parallel.
@(private = "file")
cpu_backdrop :: proc(r: ^Renderer, c: ^Cpu) {
	a := cpu_allocator()
	region := r.backdrop.region
	ox, oy := int(region.x) &~ 1, int(region.y) &~ 1
	sw, sh := (int(region.z) - ox + 1) / 2, (int(region.w) - oy + 1) / 2
	if sw <= 0 || sh <= 0 {
		return
	}
	if len(c.scene) < sw * sh {
		delete(c.scene, a)
		delete(c.blur, a)
		c.scene = make([]Px, sw * sh, a)
		c.blur = make([]Px, sw * sh, a)
	}
	c.scene_origin = {ox, oy}
	c.scene_size = {sw, sh}
	mem.zero_slice(c.scene[:sw * sh])

	count := 0
	for ty in oy / CPU_TILE ..= min(int(region.w) - 1, c.target.height - 1) / CPU_TILE {
		for tx in ox / CPU_TILE ..= min(int(region.z) - 1, c.target.width - 1) / CPU_TILE {
			c.scene_tiles[count] = u32(ty * c.tiles_x + tx)
			count += 1
		}
	}
	cpu_run(c, .Scene, count)

	// Three box blurs make about a gaussian. The GPU's dual filter reaches
	// about 2^levels pixels.
	sigma := f32(int(1) << uint(r.backdrop.levels)) * 0.45
	radius := max(int(math.round((math.sqrt(4 * sigma * sigma + 1) - 1) / 2)), 1)
	scene, blur := c.scene[:sw * sh], c.blur[:sw * sh]
	for _ in 0 ..< 3 {
		box_blur(scene, blur, sw, sh, radius, 1, sw)
		box_blur(blur, scene, sh, sw, radius, sw, 1)
	}
	copy(blur, scene)
}

// box_blur blurs lines of src into dst: count lines of n pixels, step apart
// along a line and stride apart between lines, with the edges repeated.
@(private = "file")
box_blur :: proc(src, dst: []Px, n, count, radius, step, stride: int) {
	scale := 1 / f32(2 * radius + 1)
	at :: #force_inline proc(src: []Px, base, step, i, n: int) -> Px {
		return src[base + clamp(i, 0, n - 1) * step]
	}
	for line in 0 ..< count {
		base := line * stride
		sum: Px
		for i in -radius ..= radius {
			sum += at(src, base, step, i, n)
		}
		for i in 0 ..< n {
			dst[base + i * step] = sum * scale
			sum += at(src, base, step, i + radius + 1, n) - at(src, base, step, i - radius, n)
		}
	}
}

@(private = "file")
cpu_scene_tile :: proc(c: ^Cpu, worker, t: int) {
	buf := c.scratch[worker]
	limit := int(c.r.batches[c.r.backdrop.batch].first)
	cpu_raster(c, buf, t, limit)
	x0, y0, x1, y1 := cpu_tile_rect(c, t)
	region := c.r.backdrop.region
	ox, oy := c.scene_origin.x, c.scene_origin.y
	sw, sh := c.scene_size.x, c.scene_size.y
	for y in max(y0, oy) ..< min(y1, int(region.w)) {
		sy := (y - oy) / 2
		if sy >= sh {
			break
		}
		for x in max(x0, ox) ..< min(x1, int(region.z)) {
			sx := (x - ox) / 2
			if sx < sw {
				c.scene[sy * sw + sx] += buf[(y - y0) * CPU_TILE + x - x0] * 0.25
			}
		}
	}
}

// cpu_backdrop_sample is the blur at uv, which runs over the backdrop's
// region as Instance.src does.
@(private = "file")
cpu_backdrop_sample :: proc "contextless" (c: ^Cpu, uv: [2]f32) -> Px {
	sw, sh := c.scene_size.x, c.scene_size.y
	if sw == 0 || sh == 0 {
		return {}
	}
	region := c.r.backdrop.region
	px := region.xy + uv * (region.zw - region.xy)
	u := (px.x - f32(c.scene_origin.x)) / 2 - 0.5
	v := (px.y - f32(c.scene_origin.y)) / 2 - 0.5
	fu, fv := math.floor(u), math.floor(v)
	ax, ay := u - fu, v - fv
	x0, x1 := clamp(int(fu), 0, sw - 1), clamp(int(fu) + 1, 0, sw - 1)
	y0, y1 := clamp(int(fv), 0, sh - 1), clamp(int(fv) + 1, 0, sh - 1)
	b := c.blur
	top := b[y0 * sw + x0] * (1 - ax) + b[y0 * sw + x1] * ax
	bottom := b[y1 * sw + x0] * (1 - ax) + b[y1 * sw + x1] * ax
	return top * (1 - ay) + bottom * ay
}

@(private = "file")
cpu_backdrop_at :: proc "contextless" (c: ^Cpu, uv: [2]f32, under: Px, saturation: f32) -> Px {
	b := cpu_backdrop_sample(c, uv)
	luma := b.r * 0.2126 + b.g * 0.7152 + b.b * 0.0722
	b = {max(luma + (b.r - luma) * saturation, 0), max(luma + (b.g - luma) * saturation, 0), max(luma + (b.b - luma) * saturation, 0), b.a}
	return under + b * (1 - under.a)
}

// cpu_glass is glass() in the fragment shader.
@(private = "file")
cpu_glass :: proc(c: ^Cpu, inst: ^Instance, local, half: [2]f32, radius: f32, t: [2]f32) -> Px {
	d := box_sdf(local, half, radius)
	grad := [2]f32 {
		box_sdf(local + {0.5, 0}, half, radius) - box_sdf(local - {0.5, 0}, half, radius),
		box_sdf(local + {0, 0.5}, half, radius) - box_sdf(local - {0, 0.5}, half, radius),
	}
	n := grad / max(math.sqrt(grad.x * grad.x + grad.y * grad.y), 1e-4)
	bevel := inst.colors[2].y
	x := clamp(1 + d / bevel, 0, 1)
	slope := 1 - math.sqrt(1 - x * x)

	under: Px
	if .Backdrop in inst.flags {
		uv := inst.src.xy + (inst.src.zw - inst.src.xy) * t
		per_pixel := (inst.src.zw - inst.src.xy) / (half * 2)
		shift := n * slope * inst.colors[2].x * per_pixel
		tint := linear_premultiplied(inst.colors[1])
		red := cpu_backdrop_at(c, uv + shift * 0.94, tint, inst.extra)
		green := cpu_backdrop_at(c, uv + shift, tint, inst.extra)
		blue := cpu_backdrop_at(c, uv + shift * 1.06, tint, inst.extra)
		under = {red.r, green.g, blue.b, green.a}
	}
	tint := linear_premultiplied(inst.colors[0])
	color := tint + under * (1 - tint.a)

	highlight := inst.colors[2].z
	light := [2]f32{-0.6, -1} / math.sqrt(f32(0.36 + 1))
	facing := n.x * light.x + n.y * light.y
	line := 1 - smoothstep(0, inst.colors[3].w, -d)
	catch_light := 0.12 + 0.88 * math.pow(max(facing, 0), 1.5) + 0.5 * math.pow(max(-facing, 0), 1.5)
	lit := line * catch_light * highlight + slope * slope * (0.2 + 0.8 * max(facing, 0)) * 0.2 * highlight
	lit += 0.03 * highlight * clamp(-local.y / half.y, 0, 1)
	glow_r := max(inst.colors[3].z, 1)
	to_glow := (local + inst.dst.xy + half - inst.colors[3].xy) / glow_r
	lit += inst.colors[2].w * 0.12 * math.exp(-2 * (to_glow.x * to_glow.x + to_glow.y * to_glow.y))
	dim := 1 - 0.3 * slope * max(-facing, 0)
	return {color.r * dim + lit, color.g * dim + lit, color.b * dim + lit, color.a}
}

cpu_elapsed_ms :: proc(start: time.Tick) -> f32 {
	return f32(time.duration_milliseconds(time.tick_since(start)))
}
