// Cover art: which size to fetch, decoding on a worker, and the texture
// cache. The cache is plain data with fixed arrays, owned by the UI thread,
// so it lives in the app's State and survives a hot reload. It never calls
// the renderer: it asks the caller to create a page's texture, and trim
// hands back the textures for the caller to destroy.
package cover

import "core:c/libc"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:strings"

import stbi "vendor:stb/image"

import "../render"

MAX_ENTRIES :: 2048
BUCKETS :: 4096 // a power of two
ID_MAX :: 48 // TIDAL image ids are UUIDs, 36 bytes
FADE_SECONDS :: 0.25
RETRY_SECONDS :: 30 // a failed cover still on screen is tried again after this
MAX_SOURCE_PIXELS :: 4096 * 4096 // the largest cover TIDAL serves is 1280 square

Kind :: enum u8 {
	Album, // album covers, also used for tracks
	Playlist, // a playlist's square image
	Artist, // an artist's picture
}

// The square sizes resources.tidal.com serves, smallest first.
SIZES := [Kind][]int {
	.Album    = {80, 160, 320, 640, 1280},
	.Playlist = {160, 320, 480, 640, 750, 1080},
	.Artist   = {160, 320, 480, 750},
}

// pick_size returns the smallest size of kind at least points * scale
// pixels across, or the largest there is.
pick_size :: proc(kind: Kind, points, scale: f32) -> int {
	need := int(points * scale + 0.5)
	sizes := SIZES[kind]
	for s in sizes {
		if s >= need {
			return s
		}
	}
	return sizes[len(sizes) - 1]
}

// url fills in a format string like Config.image_url, which takes the id
// with its dashes turned into slashes, then the width and height.
url :: proc(format: string, id: string, size: int, allocator := context.allocator) -> string {
	path, _ := strings.replace_all(id, "-", "/", context.temp_allocator)
	return fmt.aprintf(format, path, size, size, allocator = allocator)
}

key_of :: proc(id: string, size: int) -> u64 {
	n := u32(size)
	return hash.fnv64a(mem.ptr_to_bytes(&n), hash.fnv64a(transmute([]u8)id)) | 1
}

State :: enum u8 {
	Free,
	Wanted, // asked for, no job yet
	Queued, // a job is queued or a worker has it
	Ready,
	Failed,
}

Entry :: struct {
	key:          u64,
	next:         u16, // index + 1 of the next entry in the bucket, 0 ends it
	state:        State,
	kind:         Kind,
	px:           u16, // pixels across on screen, and in the texture
	fetch:        u16, // the size downloaded, see pick_size
	id_len:       u8,
	id:           [ID_MAX]u8,
	page:         u8, // Ready: where the pixels are
	slot:         u8,
	last_used:    u64, // frame it was last drawn or asked for
	wanted_frame: u64, // last frame something asked for it
	priority:     u8, // lowest priority asked for in wanted_frame
	ready_time:   f64, // or when it failed
}

// Covers share textures: a page holds a grid of covers of one pixel size,
// each drawn at exactly that size, so no page needs mipmaps. One texture
// per cover cost three times its pixels in Metal's allocation overhead.
MAX_PAGES :: 64
PAGE_SIDE :: 640 // texels across a page, unless a single cover is wider
PAGE_COLS :: 8 // at most, so a page's slots fit in a u64

Page :: struct {
	texture: render.Texture, // zero until the caller creates it, see place
	px:      u16, // the covers' size; 0 for a free page
	cols:    u8,
	used:    u64, // a bit per slot
}

Cache :: struct {
	entries: [MAX_ENTRIES]Entry,
	buckets: [BUCKETS]u16, // index + 1 of the first entry, 0 for none
	pages:   [MAX_PAGES]Page,
	used:    int, // entries not Free
	ready:   int, // Ready entries
	bytes:   int, // the pages' texture bytes
	budget:  int,
}

init :: proc(c: ^Cache, budget: int) {
	c^ = {}
	c.budget = budget
}

entry_id :: proc(e: ^Entry) -> string {
	return string(e.id[:e.id_len])
}

lookup :: proc(c: ^Cache, key: u64) -> ^Entry {
	for i := c.buckets[key & (BUCKETS - 1)]; i != 0; i = c.entries[i - 1].next {
		if e := &c.entries[i - 1]; e.key == key {
			return e
		}
	}
	return nil
}

// want returns the entry for (id, px), adding it as Wanted if it's new,
// and records that frame asked for it at priority. px is the size it's
// drawn at in pixels; the worker downloads fetch and scales it to px. Nil
// when the id is too long, or every entry is in use and none can be
// dropped.
want :: proc(c: ^Cache, kind: Kind, id: string, px, fetch: int, frame: u64, priority: u8) -> ^Entry {
	if len(id) == 0 || len(id) > ID_MAX || px <= 0 {
		return nil
	}
	key := key_of(id, px)
	e := lookup(c, key)
	if e == nil {
		ok: bool
		e, ok = add(c, key, frame)
		if !ok {
			return nil
		}
		e.kind = kind
		e.px = u16(px)
		e.fetch = u16(fetch)
		e.id_len = u8(len(id))
		copy(e.id[:], id)
		e.state = .Wanted
	}
	if e.wanted_frame != frame {
		e.wanted_frame = frame
		e.priority = priority
	} else {
		e.priority = min(e.priority, priority)
	}
	e.last_used = frame
	return e
}

@(private)
add :: proc(c: ^Cache, key: u64, frame: u64) -> (e: ^Entry, ok: bool) {
	index := -1
	for &f, i in c.entries {
		if f.state == .Free {
			index = i
			break
		}
	}
	if index < 0 {
		// Every entry is taken. Reuse the least recently used one with no
		// texture and no job, so nothing is lost but a retry.
		oldest := max(u64)
		for &f, i in c.entries {
			if (f.state == .Failed || f.state == .Wanted) && f.last_used < frame && f.last_used < oldest {
				oldest = f.last_used
				index = i
			}
		}
		if index < 0 {
			return nil, false
		}
		remove(c, &c.entries[index])
	}
	e = &c.entries[index]
	e^ = {key = key}
	bucket := &c.buckets[key & (BUCKETS - 1)]
	e.next = bucket^
	bucket^ = u16(index + 1)
	c.used += 1
	return e, true
}

// remove frees an entry, and its slot if it's Ready. The page stays.
remove :: proc(c: ^Cache, e: ^Entry) {
	if e.state == .Free {
		return
	}
	index := u16(mem_index(c, e) + 1)
	link := &c.buckets[e.key & (BUCKETS - 1)]
	for link^ != 0 {
		if link^ == index {
			link^ = e.next
			break
		}
		link = &c.entries[link^ - 1].next
	}
	if e.state == .Ready {
		c.pages[e.page].used &~= 1 << e.slot
		c.ready -= 1
	}
	c.used -= 1
	e^ = {}
}

@(private)
mem_index :: proc(c: ^Cache, e: ^Entry) -> int {
	return int(uintptr(e) - uintptr(&c.entries[0])) / size_of(Entry)
}

// page_layout is how many covers of px a page holds across, and its side
// in texels.
page_layout :: proc(px: int) -> (cols, side: int) {
	cols = clamp(PAGE_SIDE / max(px, 1), 1, PAGE_COLS)
	return cols, cols * px
}

// page_bytes is what a page of px covers costs: RGBA8, no mipmaps.
page_bytes :: proc(px: int) -> int {
	_, side := page_layout(px)
	return side * side * 4
}

// place finds the pixels of key's entry a slot and marks it Ready. It takes
// a free slot in a page of the same size, else opens a new page while the
// pages fit the budget, else reuses the least recently used cover of that
// size, else opens a page over the budget, which trim gives back later. A
// reused slot's cover wasn't drawn in the last render.FRAMES_IN_FLIGHT
// frames, so no frame the GPU may still be drawing samples it. When the
// returned page has no texture yet, the caller creates one of
// page_layout's side. Nil if the entry is gone or Ready, or there's no
// room at all.
place :: proc(c: ^Cache, key: u64, frame: u64, now: f64) -> (e: ^Entry, page: ^Page) {
	e = lookup(c, key)
	if e == nil || e.state == .Ready {
		return nil, nil
	}
	px := int(e.px)
	p, slot := -1, -1
	for &pg, i in c.pages {
		if int(pg.px) == px {
			if free := free_slot(&pg); free >= 0 {
				p, slot = i, free
				break
			}
		}
	}
	if p < 0 && c.bytes + page_bytes(px) <= c.budget {
		p = open_page(c, px)
		slot = 0 if p >= 0 else -1
	}
	if p < 0 {
		oldest: ^Entry
		for &o in c.entries {
			if o.state == .Ready && int(o.px) == px && o.last_used + render.FRAMES_IN_FLIGHT <= frame && (oldest == nil || o.last_used < oldest.last_used) {
				oldest = &o
			}
		}
		if oldest != nil {
			p, slot = int(oldest.page), int(oldest.slot)
			remove(c, oldest)
		}
	}
	if p < 0 {
		p = open_page(c, px)
		slot = 0
	}
	if p < 0 {
		return nil, nil
	}
	page = &c.pages[p]
	page.used |= 1 << uint(slot)
	e.state = .Ready
	e.page = u8(p)
	e.slot = u8(slot)
	e.ready_time = now
	c.ready += 1
	return e, page
}

@(private)
free_slot :: proc(pg: ^Page) -> int {
	n := int(pg.cols) * int(pg.cols)
	for i in 0 ..< n {
		if pg.used & (1 << uint(i)) == 0 {
			return i
		}
	}
	return -1
}

@(private)
open_page :: proc(c: ^Cache, px: int) -> int {
	for &pg, i in c.pages {
		if pg.px == 0 {
			cols, _ := page_layout(px)
			pg = {px = u16(px), cols = u8(cols)}
			c.bytes += page_bytes(px)
			return i
		}
	}
	return -1
}

// texture and src are where a Ready entry's pixels are: the page's texture
// and the slot's rect in texels.
texture :: proc(c: ^Cache, e: ^Entry) -> render.Texture {
	return c.pages[e.page].texture
}

src :: proc(c: ^Cache, e: ^Entry) -> render.Rect {
	cols := int(c.pages[e.page].cols)
	px := f32(e.px)
	return {f32(int(e.slot) % cols) * px, f32(int(e.slot) / cols) * px, px, px}
}

set_failed :: proc(c: ^Cache, key: u64, now: f64) {
	if e := lookup(c, key); e != nil && e.state != .Ready {
		e.state = .Failed
		e.ready_time = now
	}
}

// trim gives back whole pages while the pages are over budget: the page
// whose newest cover was drawn longest ago goes first, never one with a
// cover drawn in frame. Its covers are forgotten, and its texture is
// written to out for the caller to destroy. Returns how many it wrote.
trim :: proc(c: ^Cache, frame: u64, out: []render.Texture) -> int {
	n := 0
	for c.bytes > c.budget && n < len(out) {
		newest: [MAX_PAGES]u64
		for &e in c.entries {
			if e.state == .Ready {
				newest[e.page] = max(newest[e.page], e.last_used)
			}
		}
		p := -1
		for pg, i in c.pages {
			if pg.px != 0 && newest[i] < frame && (p < 0 || newest[i] < newest[p]) {
				p = i
			}
		}
		if p < 0 {
			break
		}
		for &e in c.entries {
			if e.state == .Ready && int(e.page) == p {
				remove(c, &e)
			}
		}
		pg := &c.pages[p]
		if pg.texture != 0 {
			out[n] = pg.texture
			n += 1
		}
		c.bytes -= page_bytes(int(pg.px))
		pg^ = {}
	}
	return n
}

// alpha is how far a Ready entry has faded in, 0 to 1.
alpha :: proc(e: ^Entry, now: f64) -> f32 {
	if e == nil || e.state != .Ready {
		return 0
	}
	return clamp(f32((now - e.ready_time) / FADE_SECONDS), 0, 1)
}

// decode turns JPEG or PNG bytes into RGBA8 premultiplied the way
// render.texture_update wants it, so the upload can pass converted = true.
// With px set it scales the image to px square first, filtering in linear
// light, so the texture is drawn at exactly its size and needs no mipmaps.
// The pixels are malloc'd; free them with free_pixels. Safe on any thread.
// An image over MAX_SOURCE_PIXELS is refused from its header.
decode :: proc(data: []u8, px := 0) -> (pixels: []u8, w, h: int, ok: bool) {
	x, y, channels: i32
	if stbi.info_from_memory(raw_data(data), i32(len(data)), &x, &y, &channels) == 0 || int(x) * int(y) > MAX_SOURCE_PIXELS {
		return nil, 0, 0, false
	}
	p := stbi.load_from_memory(raw_data(data), i32(len(data)), &x, &y, &channels, 4)
	if p == nil {
		return nil, 0, 0, false
	}
	if px > 0 && (x != i32(px) || y != i32(px)) {
		out := ([^]u8)(libc.malloc(uint(px * px * 4)))
		if out == nil {
			stbi.image_free(p)
			return nil, 0, 0, false
		}
		// Straight alpha in: stb weights the colours by alpha itself.
		resized := stbi.resize_uint8_srgb(p, x, y, 0, out, i32(px), i32(px), 0, 4, 3, 0) != 0
		stbi.image_free(p)
		if !resized {
			libc.free(out)
			return nil, 0, 0, false
		}
		p, x, y = out, i32(px), i32(px)
	}
	pixels = p[:x * y * 4]
	// stb_image gives straight alpha. JPEGs are opaque, so this is only a
	// scan for them; a PNG with transparency gets premultiplied first.
	if channels == 2 || channels == 4 {
		for i := 0; i < len(pixels); i += 4 {
			a := u32(pixels[i + 3])
			if a < 255 {
				for k in 0 ..< 3 {
					pixels[i + k] = u8((u32(pixels[i + k]) * a + 127) / 255)
				}
			}
		}
	}
	render.convert_premultiplied(pixels)
	return pixels, int(x), int(y), true
}

free_pixels :: proc(pixels: []u8) {
	if pixels != nil {
		libc.free(raw_data(pixels)) // stbi_image_free is free
	}
}
