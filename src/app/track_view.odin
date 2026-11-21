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
// gen tells its pages from those of other lists. load says how far its rows
// got, and in_flight counts its pages out to TIDAL in any state: a list can
// end or fail with later pages still out, and their answers still land.
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
	load:        List_Load,
	gaps:        []Gap, // in space, by offset
	longest:     int, // seconds, of the longest track loaded
	version:     List_Version, // what TIDAL said the list was at when it was fetched
	fetched:     i64, // unix seconds the rows came from TIDAL; 0 until they all have
	found:       Found_Lists, // .Search: the albums, artists and playlists found, in arena
}

// List_Load is how far a list's rows got. A list starts paging, or
// reading its file, and ends up ended or failed.
List_Load :: union #no_nil {
	List_Paging,
	List_Reading,
	List_Ended,
	List_Failed,
}

// List_Paging asks TIDAL for pages until one finds the end. It's the zero
// value, so a list fetched from TIDAL starts here.
List_Paging :: struct {}

// List_Reading waits for the list's file, see list_open. It has no arena
// until the file comes.
List_Reading :: struct {}

// List_Ended knows where the list ends: a page reached it, or the file had
// every row. count no longer grows, and no more pages go out.
List_Ended :: struct {}

// List_Failed is a list a page failed for. The rows it has stay, and no
// more pages go out.
List_Failed :: struct {
	error: Small,
}

// view_loading says whether a list's length isn't known yet: it's paging
// or reading its file.
view_loading :: proc(v: ^Track_View) -> bool {
	switch _ in v.load {
	case List_Paging, List_Reading:
		return true
	case List_Ended, List_Failed:
	}
	return false
}

// view_filling says whether rows are still to come: pages are out or due,
// or the file is being read.
view_filling :: proc(v: ^Track_View) -> bool {
	if v.source == .None {
		return false
	}
	switch _ in v.load {
	case List_Paging, List_Reading:
		return true
	case List_Ended:
		return v.in_flight > 0
	case List_Failed:
	}
	return false
}

// view_complete says whether every row of a list is in and none failed.
view_complete :: proc(v: ^Track_View) -> bool {
	_, ended := v.load.(List_Ended)
	return v.source != .None && ended && v.in_flight == 0
}

// view_error is why a page of the list failed, or "".
view_error :: proc(v: ^Track_View) -> string {
	if f, failed := &v.load.(List_Failed); failed {
		return small_str(&f.error)
	}
	return ""
}

// Gap is where a page came back short: TIDAL leaves out tracks that can't
// be played but still counts them. The rows after it move up, so row i is
// at TIDAL's offset i plus the gaps before it. Which of the page's tracks
// were left out TIDAL doesn't say, so a row in the page could be at any of
// missing + 1 offsets (see view_item_index).
Gap :: struct {
	offset:  int, // the page's
	limit:   int, // the offsets it spans
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
	if v.has_arena && v.gen == d.queue_view && view_filling(v) {
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
	} else if span := min(limit, total - offset); last && total >= 0 && len(rows) < span {
		// The last page short of the total: nothing after it moves.
		view_gap_add(v, offset, span, span - len(rows))
	}
	end := start + len(rows)
	loading := view_loading(v)
	if last && (loading || end < v.count) {
		if loading {
			v.load = List_Ended{}
		}
		v.count = end
	}
	if !view_loading(v) {
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
	view_gap_add(v, offset, limit, missing)
}

// view_gap_add records the gap of the page at offset, in offset order.
// Past GAPS_MAX it records nothing, and view_item_index no longer knows
// where the rows are.
@(private = "file")
view_gap_add :: proc(v: ^Track_View, offset, limit, missing: int) {
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
	v.gaps[i] = {offset, limit, missing}
}

// view_item_index is where row i of a done list sits among TIDAL's items,
// as removing it by index needs: from lo to hi, which are the same unless
// the row's page came back short. ok is false when the gaps aren't known,
// as for a list read from its file or kept in memory, whose gaps went.
view_item_index :: proc(v: ^Track_View, i: int) -> (lo, hi: int, ok: bool) {
	missing := v.hint - v.count
	if missing == 0 {
		return i, i, true
	}
	known := 0
	for g in v.gaps {
		known += g.missing
	}
	if known != missing {
		return
	}
	lo = i
	extra, before := 0, 0
	for g in v.gaps {
		start := g.offset - before // the page's first row
		if i >= start + g.limit - g.missing {
			lo += g.missing
		} else if i >= start {
			extra = g.missing
		}
		before += g.missing
	}
	return lo, lo + extra, true
}

// view_remove_at takes row at out of a done list. index is where TIDAL had
// it, so the gaps after it move up with the rows; -1 when that isn't known
// forgets the gaps.
view_remove_at :: proc(v: ^Track_View, at, index: int) -> bool {
	n := min(v.count, len(v.rows))
	if !v.has_arena || at < 0 || at >= n {
		return false
	}
	copy(v.rows[at:], v.rows[at + 1:n])
	v.loaded[n - 1] = false
	v.count = n - 1
	v.loaded_rows -= 1
	v.moved += 1
	v.hint = max(v.hint - 1, 0)
	if index < 0 {
		v.gaps = nil
	}
	for &g in v.gaps {
		if g.offset > index {
			g.offset -= 1
		} else if index < g.offset + g.limit {
			g.limit -= 1
		}
	}
	return true
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
	_, paging := v.load.(List_Paging)
	for paging && v.source != .None && v.in_flight < PAGES_IN_FLIGHT && (v.next_offset < v.hint || v.in_flight == 0) && !page_held(d, v.gen) {
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
		v.load = List_Failed{res.message}
		v.in_flight -= held_remove_if(d, page_of, &v.gen)
		return
	}
	page, _ := res.payload.(Tracks_Result)
	view_add_rows(v, int(p.offset), int(p.limit), page.rows, page.total)
	if !view_loading(v) {
		v.in_flight -= held_remove_if(d, page_of, &v.gen)
	}
	view_pages(d, v)
	if v != r {
		list_loaded(d, v)
	} else if view_complete(r) {
		refresh_land(s)
	}
}
