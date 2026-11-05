package app

// The memory breakdown a snapshot (snapshot.odin) holds: the memory the OS
// counts against the app split into groups (api, playback, ui, gpu,
// system) and items in them. It comes from two views. The app's: the pages
// of each arena and buffer it owns that count, from mincore, the bytes
// malloc gave its own heap buffers, and the size of each texture and
// buffer it made on the GPU. The OS's: the footprint split into pools by
// the kind of memory (os_memory, per OS). Each item comes out of its pool,
// and what's left of a pool goes in as an item of its own, so the items
// add up to the pools, which on macOS add up to the footprint.

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sync"

import "../audio"
import "../cover"
import "../render"
import "../sys"

Mem_Group :: enum u8 {
	Api,
	Playback,
	Ui,
	Gpu,
	System,
}

MEM_GROUP_NAMES := [Mem_Group]string {
	.Api      = "api",
	.Playback = "playback",
	.Ui       = "ui",
	.Gpu      = "gpu",
	.System   = "system",
}

// Mem_Pool is a kind of memory the OS counts apart. An item comes out of
// the pool its bytes are in. On Linux malloc's memory is anonymous like the
// rest, so HEAP_POOL is Anon there.
Mem_Pool :: enum u8 {
	Anon, // anonymous pages with no tag: arenas, the shell's memory blocks
	Malloc,
	Gpu, // Metal's or Vulkan's buffers and textures
	Surfaces, // IOSurfaces: the drawables and the window's backing
	Other, // what no item of the app's is in: binaries' data, stacks and the like
}

MEM_POOL_NAMES := [Mem_Pool]string {
	.Anon     = "anon",
	.Malloc   = "malloc",
	.Gpu      = "gpu",
	.Surfaces = "surfaces",
	.Other    = "other",
}

// Init_Part is a step of start, after which Measure.init_offsets keeps how
// far the persistent arena had got, so each step's share of it can be told
// apart.
Init_Part :: enum u8 {
	Render,
	Text,
	Ui,
	Library,
	Data,
	Rows,
	Playback,
	Search,
}

Mem_Item :: struct {
	group: Mem_Group,
	pool:  Mem_Pool,
	name:  string,
	bytes: int,
}

// Os_Part is a share of the Other pool, with the name it goes under.
Os_Part :: struct {
	name:  string,
	bytes: int,
}

Os_Memory :: struct {
	footprint: int,
	pools:     [Mem_Pool]int, // Other is the sum of other
	other:     [4]Os_Part,
}

MAX_MEM_ITEMS :: 48

Breakdown :: struct {
	items: [MAX_MEM_ITEMS]Mem_Item,
	count: int,
}

// breakdown_json writes the breakdown's fields, "footprint" and "items",
// into sb.
breakdown_json :: proc(s: ^State, sb: ^strings.Builder) {
	b: Breakdown
	breakdown_collect(s, &b)
	om := os_memory(&s.renderer)
	breakdown_settle(&b, om)
	fmt.sbprintf(sb, `"footprint":%d,"items":[`, om.footprint)
	first := true
	for item in b.items[:b.count] {
		if item.bytes <= 0 {
			continue
		}
		if !first {
			strings.write_byte(sb, ',')
		}
		first = false
		fmt.sbprintf(sb, `{{"group":"%s","pool":"%s","name":"%s","bytes":%d}}`, MEM_GROUP_NAMES[item.group], MEM_POOL_NAMES[item.pool], item.name, item.bytes)
	}
	strings.write_byte(sb, ']')
}

// breakdown_settle adds what's left of each pool once the app's items are
// out of it, and the Other pool's parts.
breakdown_settle :: proc(b: ^Breakdown, om: Os_Memory) {
	REST := [Mem_Pool]struct {
		group: Mem_Group,
		name:  string,
	} {
		.Anon     = {.System, "other anonymous memory"},
		.Malloc   = {.System, "malloc outside the app's buffers"},
		.Gpu      = {.Gpu, "other GPU memory (driver, pipelines)"},
		.Surfaces = {.Gpu, "drawables and window surfaces"},
		.Other    = {},
	}
	used: [Mem_Pool]int
	for item in b.items[:b.count] {
		used[item.pool] += item.bytes
	}
	for pool in Mem_Pool {
		if pool != .Other && om.pools[pool] > used[pool] {
			breakdown_add(b, REST[pool].group, pool, REST[pool].name, om.pools[pool] - used[pool])
		}
	}
	for part in om.other {
		breakdown_add(b, .System, .Other, part.name, part.bytes)
	}
}

breakdown_add :: proc(b: ^Breakdown, group: Mem_Group, pool: Mem_Pool, name: string, bytes: int) {
	if b.count < len(b.items) {
		b.items[b.count] = {group, pool, name, bytes}
		b.count += 1
	}
}

// breakdown_collect adds an item for each part of the app that holds
// memory. Pages in State and the persistent arena go to the field or init
// step whose range holds the page's first byte, so none counts twice.
@(private = "file")
breakdown_collect :: proc(s: ^State, b: ^Breakdown) {
	d := &s.data
	m := &s.measure

	// State, and the persistent arena by init step.
	state := pages_counted(s, size_of(State))
	data := pages_counted(d, size_of(Data))
	covers := pages_counted(&d.covers, size_of(cover.Cache))
	playback := pages_counted(&s.playback, size_of(Playback))
	text := pages_counted(&s.text, size_of(s.text))
	base := raw_data(s.arena.data)
	span: [Init_Part]int
	from := 0
	for part in Init_Part {
		span[part] = pages_counted(&base[from], m.init_offsets[part] - from)
		from = m.init_offsets[part]
	}
	later := pages_counted(&base[from], s.arena.offset - from)

	// api
	if d.session != nil {
		breakdown_add(b, .Api, .Anon, "session", arena_counted(&d.session.arena))
	}
	if d.sidebar.arena != nil {
		breakdown_add(b, .Api, .Anon, "sidebar", arena_counted(d.sidebar.arena))
	}
	breakdown_add(b, .Api, .Anon, "open list", view_counted(&d.view))
	breakdown_add(b, .Api, .Anon, "list refresh", view_counted(&d.refresh))
	breakdown_add(b, .Api, .Anon, "queued list", view_counted(&d.queued))
	breakdown_add(b, .Api, .Anon, "freed list (debug)", view_counted(&d.retired))
	kept := 0
	for &e in d.lists.entries[:d.lists.count] {
		kept += view_counted(&e.view)
	}
	breakdown_add(b, .Api, .Anon, "kept lists", kept)
	artists := 0
	for &page in d.artists.pages {
		for part in page.parts {
			if ready, ok := part.(Artist_Ready); ok && ready.arena != nil {
				artists += arena_counted(ready.arena)
			}
		}
	}
	breakdown_add(b, .Api, .Anon, "artist pages", artists)
	if d.home.arena != nil {
		breakdown_add(b, .Api, .Anon, "home", arena_counted(d.home.arena))
	}
	if s.search.arena != nil {
		breakdown_add(b, .Api, .Anon, "search results", arena_counted(s.search.arena))
	}
	ids := heap_bytes(raw_data(d.liked.ids)) + heap_bytes(raw_data(d.liked.edits)) + heap_bytes(raw_data(d.followed.ids)) + heap_bytes(raw_data(d.followed.edits))
	breakdown_add(b, .Api, HEAP_POOL, "liked and followed ids", ids)
	scratch := 0
	for &t in d.worker_temps {
		if at := sync.atomic_load(&t.base); at != 0 {
			scratch += pages_counted(rawptr(at), int(sync.atomic_load(&t.size)))
		}
	}
	breakdown_add(b, .Api, HEAP_POOL, "worker scratch", scratch)
	breakdown_add(b, .Api, .Anon, "data state", data - covers + span[.Data])

	// playback
	if p := s.playback.player; p != nil {
		pm := audio.memory(p)
		breakdown_add(b, .Playback, .Anon, "player", arena_counted(pm.arena))
		windows, tracks := 0, 0
		for i in 0 ..< len(pm.tracks) {
			windows += pages_counted(raw_data(pm.windows[i]), len(pm.windows[i]))
			tracks += arena_counted(pm.tracks[i])
		}
		breakdown_add(b, .Playback, .Anon, "stream windows", windows)
		breakdown_add(b, .Playback, .Anon, "track data", tracks)
	}
	if s.playback.has_arena {
		breakdown_add(b, .Playback, .Anon, "queue", arena_counted(&s.playback.arena))
	}
	breakdown_add(b, .Playback, .Anon, "playback state", playback + span[.Playback])

	// ui
	breakdown_add(b, .Ui, .Anon, "text caches", text + span[.Text])
	tables := 0
	for &face in s.text.faces[:s.text.face_count] {
		tables += heap_bytes(face.blob)
	}
	tables += heap_bytes(raw_data(s.text.fallback_cache))
	breakdown_add(b, .Ui, HEAP_POOL, "font tables", tables)
	breakdown_add(b, .Ui, .Anon, "cover index", covers)
	breakdown_add(b, .Ui, .Anon, "fake rows", span[.Rows])
	breakdown_add(b, .Ui, .Anon, "frame arena", pages_counted(raw_data(s.frame_arena.data), len(s.frame_arena.data)))
	rest := state - data - playback - text
	breakdown_add(b, .Ui, .Anon, "app state", rest + span[.Render] + span[.Ui] + span[.Library] + span[.Search] + later)

	// gpu
	r := &s.renderer
	atlas := 0
	for page in s.text.atlas.pages[:s.text.atlas.page_count] {
		atlas += render.texture_bytes(r, page.texture)
	}
	for t in s.text.atlas.outgrown[:s.text.atlas.outgrown_count] {
		atlas += render.texture_bytes(r, t)
	}
	breakdown_add(b, .Gpu, .Gpu, "glyph atlas", atlas)
	cover_pages := 0
	for page in d.covers.pages {
		cover_pages += render.texture_bytes(r, page.texture)
	}
	for t in d.evicted {
		cover_pages += render.texture_bytes(r, t)
	}
	breakdown_add(b, .Gpu, .Gpu, "cover pages", cover_pages)
	gm := render.gpu_memory(r)
	breakdown_add(b, .Gpu, .Gpu, "instance buffers", gm.instances)
	breakdown_add(b, .Gpu, .Gpu, "upload buffers", gm.staging)
	breakdown_add(b, .Gpu, .Gpu, "backdrop blur", gm.backdrop)
}

@(private = "file")
view_counted :: proc(v: ^Track_View) -> int {
	if !v.has_arena {
		return 0
	}
	return arena_counted(&v.arena) + pages_counted(raw_data(v.space), len(v.space))
}

// arena_counted is the pages of a's blocks that count toward the
// footprint. It holds a's mutex, so a thread allocating from a can't free
// a block under it.
@(private = "file")
arena_counted :: proc(a: ^vmem.Arena) -> int {
	sync.mutex_guard(&a.mutex)
	n := 0
	for block := a.curr_block; block != nil; block = block.prev {
		n += pages_counted(block, int(uintptr(block.base) - uintptr(block) + uintptr(block.committed)))
	}
	return n
}

// pages_counted is the bytes of the pages whose first byte is in the n
// bytes at ptr and which count toward the footprint (PAGE_COUNTS).
pages_counted :: proc(ptr: rawptr, n: int) -> int {
	if ptr == nil || n <= 0 {
		return 0
	}
	page := uintptr(sys.page_size())
	end := uintptr(ptr) + uintptr(n)
	vec: [1024]u8
	total := 0
	for at := mem.align_forward_uintptr(uintptr(ptr), page); at < end; {
		pages := min(int((end - at + page - 1) / page), len(vec))
		if sys.page_flags(rawptr(at), vec[:pages]) {
			for v in vec[:pages] {
				total += int(page) if v & PAGE_COUNTS != 0 else 0
			}
		}
		at += uintptr(pages) * page
	}
	return total
}

