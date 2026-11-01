package app

// Track lists: the open one, the kept ones and the play queue's. Each holds
// its rows in one reserved range of address space and asks for its pages a
// few at a time.

import "core:log"
import "core:mem"
import vmem "core:mem/virtual"

import "../jobs"

PAGES_IN_FLIGHT :: 2

// Track_View is a track list: the open one, one kept in memory after it
// closed (see lists.odin), or the open one being fetched again. Its rows,
// their loaded flags and its gaps live in space, their strings in its arena.
// gen tells its pages from those of other lists.
Track_View :: struct {
	gen:         u32,
	source:      Source,
	id:          Small,
	name:        Small,
	image:       Small,
	hint:        int, // tracks TIDAL said the list has
	arena:       vmem.Arena,
	has_arena:   bool, // arena and space are there
	space:       []u8, // reserved, see ROWS_MAX
	rows:        []Row, // in space
	loaded:      []bool, // in space
	loaded_rows: int,
	moved:       u32, // goes up when loaded rows move to other indices
	count:       int, // rows shown, loaded or not
	next_offset: int, // in TIDAL's offsets, which count the gaps
	in_flight:   int,
	done:        bool,
	error:       Small,
	gaps:        []Gap, // in space, by offset
	longest:     int, // seconds, of the longest track loaded
	version:     List_Version, // what TIDAL said the list was at when it was fetched
	fetched:     i64, // unix seconds the rows came from TIDAL; 0 until they all have
	reading:     bool, // waiting for its file
	found:       Found_Lists, // .Search: the albums, artists and playlists found, in arena
}

// Gap is where a page came back short before the end of its list: TIDAL
// leaves out tracks that can't be played but still counts them. The rows
// after it move up, so row i is at TIDAL's offset i plus the gaps before it.
Gap :: struct {
	offset:  int, // the page's
	missing: int,
}

// track_view is the list, open, fetched again or followed by the play
// queue, that gen names, or nil.
track_view :: proc(d: ^Data, gen: u32) -> ^Track_View {
	for v in ([]^Track_View{&d.refresh, &d.queued, &d.view}) {
		if v.gen == gen && v.source != .None {
			return v
		}
	}
	return nil
}

// drop_track_jobs drops the pages asked for but the ones for keep.
@(private = "file")
drop_track_jobs :: proc(job: ^Job, keep: rawptr) -> bool {
	q := (^Track_View)(keep)
	p, tracks := job.payload.(Tracks_Job)
	return tracks && (q.source == .None || p.view != q.gen)
}

POISON :: 0xdb

view_gen :: proc(d: ^Data) -> u32 {
	d.next_gen += 1
	return d.next_gen
}

// view_close closes the open list. A list that loaded whole is kept in
// memory (list_keep). One the play queue follows that's still loading goes
// on loading in d.queued, so the queue gets the rest of it. The rest is
// freed. A refresh of it stops.
view_close :: proc(d: ^Data) {
	v := &d.view
	if v.has_arena && v.gen == d.queue_view && !view_complete(v) && v.error.len == 0 && !v.reading {
		queued_drop(d)
		d.queued = take(v)
	}
	jobs.remove_if(&d.queue, drop_track_jobs, &d.queued)
	refresh_drop(d)
	if v.has_arena {
		if d.lists.memory && view_complete(v) && v.fetched != 0 {
			list_keep(d, take(v))
		} else {
			view_free(d, v)
		}
	}
	v^ = {gen = view_gen(d)}
}

// queued_drop stops loading the list the play queue followed. One that
// loaded whole is kept like a closed list.
queued_drop :: proc(d: ^Data) {
	q := &d.queued
	if q.source == .None {
		return
	}
	jobs.remove_if(&d.queue, page_of, &q.gen)
	if q.has_arena && d.lists.memory && view_complete(q) && q.fetched != 0 {
		list_keep(d, take(q))
	} else {
		view_free(d, q)
	}
	q^ = {}
}

// queue_list is the list the play queue follows while it loads, open or
// in d.queued, or nil.
queue_list :: proc(d: ^Data) -> ^Track_View {
	if d.view.source != .None && d.view.gen == d.queue_view {
		return &d.view
	}
	if d.queued.source != .None && d.queued.gen == d.queue_view {
		return &d.queued
	}
	return nil
}

// view_open opens a list from TIDAL, whatever is kept of it. list_open
// looks in the cache first.
view_open :: proc(d: ^Data, source: Source, id, name, image: string, hint: int) {
	view_close(d)
	view_fetch(d, source, id, name, image, hint)
}

// view_fetch has TIDAL fill the open list, just closed or read from a file
// that wasn't there.
view_fetch :: proc(d: ^Data, source: Source, id, name, image: string, hint: int) {
	v := &d.view
	sid, sname, simage := small(id), small(name), small(image)
	v^ = {gen = v.gen}
	v.source = source
	v.id, v.name, v.image = sid, sname, simage
	v.hint = hint
	v.count = hint
	v.version = list_version_now(d, source, id).? or_else {}
	view_init(v)
	view_reserve(v, max(hint, PAGE_FIRST))
	view_request_pages(d)
}

// A list's rows, their loaded flags and its gaps each have a range of one
// reservation, committed as the list grows. So rows never move, a longer
// list leaves no old copy behind, and a view can be moved by value. Pages
// the list hasn't reached cost nothing.
ROWS_MAX :: 1 << 18

GAPS_MAX :: ROWS_MAX / PAGE_FIRST + 1 // a gap is a short page

@(private = "file")
SPACE_PAGE :: 1 << 16

@(private = "file")
LOADED_AT :: (ROWS_MAX * size_of(Row) + SPACE_PAGE - 1) / SPACE_PAGE * SPACE_PAGE

@(private = "file")
GAPS_AT :: LOADED_AT + (ROWS_MAX + SPACE_PAGE - 1) / SPACE_PAGE * SPACE_PAGE

@(private = "file")
SPACE_SIZE :: GAPS_AT + GAPS_MAX * size_of(Gap)

// space_reserve reserves a list's space, with no rows yet.
space_reserve :: proc() -> (space: []u8, ok: bool) {
	err: mem.Allocator_Error
	if space, err = vmem.reserve(SPACE_SIZE); err != nil {
		return nil, false
	}
	if vmem.commit(&space[GAPS_AT], GAPS_MAX * size_of(Gap)) != nil {
		space_release(space)
		return nil, false
	}
	return space, true
}

space_release :: proc(space: []u8) {
	if space != nil {
		vmem.release(raw_data(space), len(space))
	}
}

// space_rows commits room for n rows in space, up to ROWS_MAX, and returns
// them and their loaded flags.
space_rows :: proc(space: []u8, n: int) -> (rows: []Row, loaded: []bool, ok: bool) {
	count := min(n, ROWS_MAX)
	if count == 0 {
		return nil, nil, true
	}
	if vmem.commit(&space[0], uint(count * size_of(Row))) != nil || vmem.commit(&space[LOADED_AT], uint(count)) != nil {
		return nil, nil, false
	}
	return ([^]Row)(&space[0])[:count], ([^]bool)(&space[LOADED_AT])[:count], true
}

// view_init makes v's arena and space, with no rows yet. has_arena says
// whether both are there.
view_init :: proc(v: ^Track_View) {
	v.has_arena = false
	if vmem.arena_init_growing(&v.arena) != nil {
		return
	}
	space, ok := space_reserve()
	if !ok {
		vmem.arena_destroy(&v.arena)
		return
	}
	v.space = space
	v.rows, v.loaded, v.gaps = nil, nil, nil
	v.has_arena = true
}

// view_release frees v's arena and space.
view_release :: proc(v: ^Track_View) {
	if !v.has_arena {
		return
	}
	vmem.arena_destroy(&v.arena)
	space_release(v.space)
	v.has_arena = false
	v.space, v.rows, v.loaded, v.gaps = nil, nil, nil, nil
}

// view_free frees a list's memory. Debug builds and tests poison it and
// keep it until the next one goes, see Data.poison.
view_free :: proc(d: ^Data, v: ^Track_View) {
	if !v.has_arena {
		return
	}
	if !d.poison {
		view_release(v)
		return
	}
	for b := v.arena.curr_block; b != nil; b = b.prev {
		mem.set(b.base, POISON, int(b.used))
	}
	mem.set(raw_data(v.rows), POISON, len(v.rows) * size_of(Row))
	mem.set(raw_data(v.loaded), POISON, len(v.loaded))
	mem.set(raw_data(v.gaps), POISON, len(v.gaps) * size_of(Gap))
	view_release(&d.retired)
	d.retired = take(v)
}

// view_bytes is about what a list holds in memory.
view_bytes :: proc(v: ^Track_View) -> int {
	if !v.has_arena {
		return 0
	}
	return arena_bytes(&v.arena) + int(mem.align_forward_uint(uint(len(v.rows) * size_of(Row) + len(v.loaded)), 16 << 10))
}

// view_reserve makes room for n rows, up to ROWS_MAX.
view_reserve :: proc(v: ^Track_View, n: int) {
	if n <= len(v.rows) || !v.has_arena || len(v.rows) == ROWS_MAX {
		return
	}
	size := max(n, 2 * len(v.rows))
	rows, loaded, ok := space_rows(v.space, size)
	if !ok {
		log.errorf("lists: no memory for %d rows", size)
		return
	}
	v.rows, v.loaded = rows, loaded
}

// view_add_rows copies the page asked for at offset with limit into the
// view. total is the list's length TIDAL gave with the page, or -1.
//
// With a total, the page that reaches it ends the list, and a short page
// before that is a gap (see Gap): the rows after it move up. Without one, a
// short page ends the list. Pages arrive out of order either way, so the
// earliest end found stands: an empty page asked for past the end mustn't
// bring back rows a short page before it cut. Rows past the end are
// dropped. Until the end is known, a full page past the count TIDAL gave
// grows the list.
view_add_rows :: proc(v: ^Track_View, offset, limit: int, rows: []Row, total := -1) {
	rows := rows
	last := len(rows) < limit
	if total >= 0 {
		last = offset + limit >= total || len(rows) == 0
		v.hint = total
	}
	start := view_row_at(v, offset)
	if !last && len(rows) < limit {
		view_close_gap(v, offset, start, limit, len(rows))
	}
	end := start + len(rows)
	if last && (!v.done || end < v.count) {
		v.done = true
		v.count = end
	}
	if v.done {
		rows = rows[:clamp(v.count - start, 0, len(rows))]
	} else {
		v.count = max(v.count, end)
	}
	view_reserve(v, start + len(rows))
	if !v.has_arena {
		return
	}
	rows = rows[:clamp(len(v.rows) - start, 0, len(rows))]
	a := vmem.arena_allocator(&v.arena)
	for r, i in rows {
		v.rows[start + i] = row_clone(r, a)
		v.loaded_rows += int(!v.loaded[start + i])
		v.loaded[start + i] = true
		v.longest = max(v.longest, r.seconds)
	}
}

// view_row_at is the row that TIDAL's offset lands on, past the gaps
// before it.
view_row_at :: proc(v: ^Track_View, offset: int) -> int {
	row := offset
	for g in v.gaps {
		if g.offset >= offset {
			break
		}
		row -= g.missing
	}
	return row
}

// view_close_gap records that the page at offset, whose rows start at row,
// came back with got of the limit rows asked for, and moves the rows of
// later pages up to close the gap. It's rare, so it counts the loaded rows
// again.
@(private = "file")
view_close_gap :: proc(v: ^Track_View, offset, row, limit, got: int) {
	missing := limit - got
	from := row + limit
	to := row + got
	used := min(v.count, len(v.rows))
	if from < used {
		copy(v.rows[to:], v.rows[from:used])
		copy(v.loaded[to:], v.loaded[from:used])
	}
	v.count = max(v.count - missing, to)
	v.moved += 1
	for i in v.count ..< used {
		v.loaded[i] = false
	}
	v.loaded_rows = 0
	for l in v.loaded[:min(v.count, len(v.loaded))] {
		v.loaded_rows += int(l)
	}
	if !v.has_arena || len(v.gaps) == GAPS_MAX {
		return
	}
	i := 0
	for i < len(v.gaps) && v.gaps[i].offset < offset {
		i += 1
	}
	n := len(v.gaps)
	v.gaps = ([^]Gap)(&v.space[GAPS_AT])[:n + 1]
	copy(v.gaps[i + 1:], v.gaps[i:n])
	v.gaps[i] = {offset, missing}
}

// view_request_pages keeps PAGES_IN_FLIGHT pages loading, for the open list
// and its refresh, until a short page says the list has ended. The first
// page is small so it shows sooner.
view_request_pages :: proc(d: ^Data) {
	view_pages(d, &d.view)
	view_pages(d, &d.refresh)
	view_pages(d, &d.queued)
}

// view_pages asks for v's next pages. It stops at a held one, so no page
// goes out ahead of an earlier one, and a page that ends the list leaves
// only later ones held.
view_pages :: proc(d: ^Data, v: ^Track_View) {
	for v.source != .None && !v.done && !v.reading && v.in_flight < PAGES_IN_FLIGHT && (v.next_offset < v.hint || v.in_flight == 0) && !page_held(d, v.gen) {
		limit := PAGE_FIRST if v.next_offset == 0 else PAGE_SIZE
		push_job(d, {payload = Tracks_Job{view = v.gen, source = v.source, id = v.id, offset = i32(v.next_offset), limit = i32(limit)}})
		v.next_offset += limit
		v.in_flight += 1
	}
}

// What the library screen shows, from the fake data or the live data.

// list_row returns row i of v, or nil while it's loading.
list_row :: proc(v: ^Track_View, i: int) -> ^Row {
	if i < 0 || i >= len(v.loaded) || !v.loaded[i] {
		return nil
	}
	return &v.rows[i]
}

// page_of picks the pages of the list gen names, queued or held.
@(private)
page_of :: proc(job: ^Job, gen: rawptr) -> bool {
	p, page := job.payload.(Tracks_Job)
	return page && p.view == (^u32)(gen)^
}

@(private)
page_held :: proc(d: ^Data, gen: u32) -> bool {
	for h in d.held[:d.held_count] {
		if p, page := h.job.payload.(Tracks_Job); page && p.view == gen {
			return true
		}
	}
	return false
}

// tracks_result takes a page of a list: the open one, a kept one or the
// one a refresh fetches.
tracks_result :: proc(s: ^State, res: ^Result, p: Tracks_Job) {
	d := &s.data
	failed := res.err != nil
	r := &d.refresh
	v := track_view(d, p.view)
	if v == nil {
		return
	}
	v.in_flight -= 1
	if failed {
		if v == r {
			refresh_drop(d) // the rows on screen stay
			return
		}
		v.error = res.message
		v.done = true
		v.in_flight -= held_remove_if(d, page_of, &v.gen)
		return
	}
	page, _ := res.payload.(Tracks_Result)
	view_add_rows(v, int(p.offset), int(p.limit), page.rows, page.total)
	if v.done {
		v.in_flight -= held_remove_if(d, page_of, &v.gen)
	}
	view_pages(d, v)
	if v != r {
		list_loaded(d, v)
	} else if view_complete(r) {
		refresh_land(s)
	}
}
