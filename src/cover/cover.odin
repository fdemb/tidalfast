// Cover art: which size to fetch, decoding on a worker, and the texture
// cache. The cache is plain data with fixed arrays, owned by the UI thread,
// so it lives in the app's State and survives a hot reload. It never calls
// the renderer: eviction hands back the textures for the caller to destroy.
package cover

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

Kind :: enum u8 {
	Album, // album covers, also used for tracks
	Playlist, // a playlist's square image
}

// The square sizes resources.tidal.com serves, smallest first.
SIZES := [Kind][]int {
	.Album    = {80, 160, 320, 640, 1280},
	.Playlist = {160, 320, 480, 640, 750, 1080},
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
	size:         u16,
	id_len:       u8,
	id:           [ID_MAX]u8,
	texture:      render.Texture,
	bytes:        int,
	last_used:    u64, // frame it was last drawn or asked for
	wanted_frame: u64, // last frame something asked for it
	priority:     u8, // lowest priority asked for in wanted_frame
	ready_time:   f64, // or when it failed
}

Cache :: struct {
	entries: [MAX_ENTRIES]Entry,
	buckets: [BUCKETS]u16, // index + 1 of the first entry, 0 for none
	used:    int, // entries not Free
	bytes:   int, // texture bytes of Ready entries
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

// want returns the entry for (id, size), adding it as Wanted if it's new,
// and records that frame asked for it at priority. Nil when the id is too
// long, or every entry is in use and none can be dropped.
want :: proc(c: ^Cache, kind: Kind, id: string, size: int, frame: u64, priority: u8) -> ^Entry {
	if len(id) == 0 || len(id) > ID_MAX {
		return nil
	}
	key := key_of(id, size)
	e := lookup(c, key)
	if e == nil {
		ok: bool
		e, ok = add(c, key, frame)
		if !ok {
			return nil
		}
		e.kind = kind
		e.size = u16(size)
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

// remove frees an entry. A Ready entry's texture is the caller's to destroy.
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
		c.bytes -= e.bytes
	}
	c.used -= 1
	e^ = {}
}

@(private)
mem_index :: proc(c: ^Cache, e: ^Entry) -> int {
	return int(uintptr(e) - uintptr(&c.entries[0])) / size_of(Entry)
}

// texture_bytes is what a mipmapped RGBA8 texture of w by h costs.
texture_bytes :: proc(w, h: int) -> int {
	return w * h * 4 * 4 / 3
}

// set_ready stores the uploaded texture of key's entry. False if the entry
// is gone, in which case the caller destroys the texture.
set_ready :: proc(c: ^Cache, key: u64, texture: render.Texture, w, h: int, now: f64) -> bool {
	e := lookup(c, key)
	if e == nil || e.state == .Ready {
		return false
	}
	e.state = .Ready
	e.texture = texture
	e.bytes = texture_bytes(w, h)
	e.ready_time = now
	c.bytes += e.bytes
	return true
}

set_failed :: proc(c: ^Cache, key: u64, now: f64) {
	if e := lookup(c, key); e != nil && e.state != .Ready {
		e.state = .Failed
		e.ready_time = now
	}
}

// evict drops least recently used Ready entries until the cache is within
// its budget, never one used in frame, and writes their textures to out
// for the caller to destroy. Returns how many it wrote.
evict :: proc(c: ^Cache, frame: u64, out: []render.Texture) -> int {
	n := 0
	for c.bytes > c.budget && n < len(out) {
		oldest: ^Entry
		for &e in c.entries {
			if e.state == .Ready && e.last_used < frame && (oldest == nil || e.last_used < oldest.last_used) {
				oldest = &e
			}
		}
		if oldest == nil {
			break
		}
		out[n] = oldest.texture
		n += 1
		remove(c, oldest)
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
// The pixels belong to stb_image; free them with free_pixels. Safe on any
// thread.
decode :: proc(data: []u8) -> (pixels: []u8, w, h: int, ok: bool) {
	x, y, channels: i32
	p := stbi.load_from_memory(raw_data(data), i32(len(data)), &x, &y, &channels, 4)
	if p == nil {
		return nil, 0, 0, false
	}
	pixels = p[:x * y * 4]
	// stb_image gives straight alpha. JPEGs are opaque, so this is only a
	// scan for them; a PNG with transparency gets premultiplied first.
	if channels == 4 {
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
		stbi.image_free(raw_data(pixels))
	}
}
