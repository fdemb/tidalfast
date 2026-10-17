package app

// The list cache. Closed track lists stay in memory, least recently used
// first out past LIST_MEMORY_BUDGET, and every list but search results
// goes to disk under ~/Library/Caches/tidalfast/<user id>/ (list_file.odin),
// with the sidebar. Opening a list shows the kept copy at once, without a
// request. It's fetched again in the background only when there's a sign
// it changed (list_stale), and the new rows replace the old ones in place
// (refresh_land).
//
// The signs, per kind:
//
//   Playlist     the sidebar's lastUpdated or track count isn't the one it
//                was fetched with. One that isn't in the sidebar (opened from
//                a search): a day old.
//   Liked Songs  the favorites count or the newest track isn't the
//                sidebar's, or it's three days old.
//   Album        30 days old.
//   Artist       a day old.
//   Search       memory only; five minutes old, and it's gone.
//
// At sign-in the sidebar comes from disk while it's fetched as before. It's
// fetched again when the window becomes key or a sidebar entry opens, once
// it's five minutes old, and a list that changed is fetched again when it's
// open, or else when it's opened next.
//
// Disk reads and writes run on a thread of their own (disk_main), so a read
// never waits behind network jobs and writes happen in order. A write goes
// to a temp file that's renamed into place. The directory is kept under
// LIST_DISK_BUDGET by dropping the files opened longest ago. Sign-out
// deletes it. TIDALFAST_CACHE picks another directory; against
// TIDALFAST_API it's ~/Library/Caches/tidalfast-mock, and with the fake
// data nothing is kept.

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "../jobs"
import "../os_services"

LIST_MEMORY_BUDGET :: 16 << 20
LIST_MEMORY_MAX :: 64
LIST_DISK_BUDGET :: 50 << 20
COVER_DISK_BUDGET :: 50 << 20
COVER_EVICT_EVERY :: 256 // cover writes between checks of the budget
DISK_QUEUE :: 64

DAY :: 86400
PLAYLIST_MAX_AGE :: DAY // a playlist the sidebar doesn't list
LIKED_MAX_AGE :: 3 * DAY
ALBUM_MAX_AGE :: 30 * DAY
ARTIST_MAX_AGE :: DAY
SEARCH_MAX_AGE :: 5 * 60
SIDEBAR_MAX_AGE :: 5 * time.Minute

// List_Version is what a list was fetched at: a playlist's lastUpdated (unix
// ms) and track count, Liked Songs' count and newest track. Zero is unknown
// in a list's own version; what TIDAL is at now is a Maybe, since an empty
// Liked Songs is all zeros too.
List_Version :: struct {
	updated: i64,
	count:   i64,
	newest:  i64,
}

List_Entry :: struct {
	view:  Track_View,
	used:  u64,
	bytes: int,
}

Disk_Op :: enum u8 {
	Read,
	Write, // Job.blob, from list_encode or sidebar_encode
	Touch, // mark it opened now, for eviction
	Delete,
	Read_Queue, // the play queue's file, see queue_save
	Write_Queue, // Job.blob, from queue_encode
	Delete_Queue,
}

Lists :: struct {
	memory:  bool, // closed lists are kept, see list_keep
	root:    string, // heap; "" for no disk cache
	user:    i64, // whose files: root/<user>; the workers read it (atomic)
	entries: [LIST_MEMORY_MAX]List_Entry,
	count:   int,
	bytes:   int,
	clock:   u64,
	queue:   jobs.Queue(Job, DISK_QUEUE),
	thread:  posix.pthread_t,
	running: bool,
	mutex:   sync.Mutex, // a write against sign-out's delete
	covers_written: int, // cover files written this session (atomic)
}

// lists_root is where the cache goes: TIDALFAST_CACHE, or the user's
// Caches folder, a folder of its own for a mock server. Heap.
lists_root :: proc(mock: bool) -> string {
	if dir := os.get_env("TIDALFAST_CACHE", context.temp_allocator); dir != "" {
		return strings.clone(dir, runtime.heap_allocator())
	}
	dir := os_services.cache_dir(context.temp_allocator)
	if dir == "" {
		return ""
	}
	return strings.concatenate({dir, "/tidalfast-mock" if mock else "/tidalfast"}, runtime.heap_allocator())
}

unix_now :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

// list_stale says whether a list fetched at version and time fetched should
// be fetched again, now that TIDAL is at current (nil if unknown).
list_stale :: proc(source: Source, version: List_Version, fetched: i64, current: Maybe(List_Version), now: i64) -> bool {
	age := now - fetched
	if fetched <= 0 || age < 0 {
		return true
	}
	switch source {
	case .None:
	case .Playlist:
		now_at, known := current.?
		if !known {
			return age > PLAYLIST_MAX_AGE
		}
		return version != now_at
	case .Liked:
		now_at, known := current.?
		return (known && version != now_at) || age > LIKED_MAX_AGE
	case .Album:
		return age > ALBUM_MAX_AGE
	case .Artist:
		return age > ARTIST_MAX_AGE
	case .Search:
		return age > SEARCH_MAX_AGE
	}
	return true
}

// list_version_now is what the sidebar says a list is at, or nil if it
// doesn't say.
list_version_now :: proc(d: ^Data, source: Source, id: string) -> Maybe(List_Version) {
	sb := &d.sidebar
	if !sb.loaded {
		return nil
	}
	#partial switch source {
	case .Liked:
		return List_Version{count = i64(sb.liked_count), newest = sb.liked_newest}
	case .Playlist:
		for &it in sb.items {
			if it.id == id {
				return List_Version{updated = it.updated, count = i64(it.tracks)}
			}
		}
	}
	return nil
}

// arena_bytes is about what an arena holds in memory.
arena_bytes :: proc(a: ^vmem.Arena) -> int {
	n := 0
	for b := a.curr_block; b != nil; b = b.prev {
		n += int(mem.align_forward_uint(b.used, 16 << 10))
	}
	return n
}

// arena_free frees a list's arena. Debug builds and tests poison it and
// keep it until the next one goes, see Data.poison.
arena_free :: proc(d: ^Data, a: ^vmem.Arena) {
	if !d.poison {
		vmem.arena_destroy(a)
		return
	}
	for b := a.curr_block; b != nil; b = b.prev {
		mem.set(b.base, POISON, int(b.used))
	}
	if d.has_retired {
		vmem.arena_destroy(&d.retired)
	}
	d.retired = a^
	d.has_retired = true
}

// list_name names a list for the log: its kind and TIDAL id.
list_name :: proc(source: Source, id: string) -> string {
	return fmt.tprintf("%v %s", source, id) if id != "" else fmt.tprint(source)
}

// view_complete says whether every row of a list is in and none failed.
view_complete :: proc(v: ^Track_View) -> bool {
	return v.source != .None && v.done && v.in_flight == 0 && v.error.len == 0 && !v.reading
}

// Memory

lru_find :: proc(d: ^Data, source: Source, id: string) -> int {
	l := &d.lists
	for i in 0 ..< l.count {
		v := &l.entries[i].view
		if v.source == source && small_str(&v.id) == id {
			return i
		}
	}
	return -1
}

// lru_remove takes entry i out of memory and gives it to the caller.
lru_remove :: proc(d: ^Data, i: int) -> Track_View {
	l := &d.lists
	v := l.entries[i].view
	l.bytes -= l.entries[i].bytes
	l.count -= 1
	l.entries[i] = l.entries[l.count]
	l.entries[l.count] = {}
	return v
}

lru_drop :: proc(d: ^Data, i: int) {
	v := lru_remove(d, i)
	arena_free(d, &v.arena)
}

@(private = "file")
lru_oldest :: proc(d: ^Data) -> int {
	l := &d.lists
	at := 0
	for i in 1 ..< l.count {
		if l.entries[i].used < l.entries[at].used {
			at = i
		}
	}
	return at
}

// list_keep puts a closed list in memory in place of an older copy, then
// trims the kept lists to LIST_MEMORY_BUDGET.
list_keep :: proc(d: ^Data, v: Track_View) {
	l := &d.lists
	v := v
	v.gaps = nil // only used while pages arrive
	if i := lru_find(d, v.source, small_str(&v.id)); i >= 0 {
		lru_drop(d, i)
	}
	if l.count == LIST_MEMORY_MAX {
		lru_drop(d, lru_oldest(d))
	}
	l.clock += 1
	bytes := arena_bytes(&v.arena)
	l.entries[l.count] = {v, l.clock, bytes}
	l.count += 1
	l.bytes += bytes
	lists_trim(d)
}

// lists_trim drops the lists used longest ago until the rest fit
// LIST_MEMORY_BUDGET.
@(private = "file")
lists_trim :: proc(d: ^Data) {
	l := &d.lists
	for l.bytes > LIST_MEMORY_BUDGET && l.count > 0 {
		lru_drop(d, lru_oldest(d))
	}
}

lists_clear :: proc(d: ^Data) {
	for d.lists.count > 0 {
		lru_drop(d, d.lists.count - 1)
	}
}

// Opening

// list_open opens a list from memory, from disk, or else from TIDAL.
list_open :: proc(d: ^Data, source: Source, id, name, image: string, hint: int) {
	view_close(d)
	v := &d.view
	if q := &d.queued; q.source == source && small_str(&q.id) == id {
		// Still loading for the play queue: it opens as far as it got.
		v^ = q^
		q^ = {}
		v.name = small(name)
		v.image = small(image)
		return
	}
	if d.lists.memory {
		if i := lru_find(d, source, id); i >= 0 {
			gen := v.gen
			v^ = lru_remove(d, i)
			v.gen = gen
			v.name = small(name)
			v.image = small(image)
			log.debugf("lists: %s from memory", list_name(source, id))
			disk_push(d, {op = .Touch, source = source, id = small(id)})
			list_check(d)
			return
		}
	}
	if disk_on(d) && source != .Search {
		v.source = source
		v.id = small(id)
		v.name = small(name)
		v.image = small(image)
		v.hint = hint
		v.count = hint
		v.reading = true
		if disk_push(d, {op = .Read, source = source, view = v.gen, id = small(id)}) {
			return
		}
		v.reading = false
	}
	view_fetch(d, source, id, name, image, hint)
}

// list_check fetches the open list again in the background if it's stale.
// Search results aren't: a refresh would bring back the songs only, and
// search_from_memory searches again for old ones.
list_check :: proc(d: ^Data) {
	v := &d.view
	if v.fetched == 0 || v.source == .Search || d.refresh.source != .None {
		return
	}
	id := small_str(&v.id)
	if list_stale(v.source, v.version, v.fetched, list_version_now(d, v.source, id), unix_now()) {
		log.debugf("lists: %s changed, fetching it again", list_name(v.source, id))
		refresh_start(d)
	}
}

// list_loaded is for a list whose last page came in: it's written to disk.
list_loaded :: proc(d: ^Data, v: ^Track_View) {
	if v.fetched != 0 || !view_complete(v) {
		return
	}
	v.fetched = unix_now()
	list_save(d, v)
}

list_save :: proc(d: ^Data, v: ^Track_View) {
	if !disk_on(d) || v.source == .Search {
		return
	}
	disk_push(d, {op = .Write, source = v.source, id = v.id, blob = list_encode(v, runtime.heap_allocator())})
}

sidebar_save :: proc(d: ^Data) {
	if !disk_on(d) || !d.sidebar.loaded {
		return
	}
	disk_push(d, {op = .Write, blob = sidebar_encode(&d.sidebar, unix_now(), runtime.heap_allocator())})
}

// Refreshing

// refresh_start fetches the open list again into d.refresh. The open list
// stays on screen until it's done.
refresh_start :: proc(d: ^Data) {
	v := &d.view
	r := &d.refresh
	r^ = {
		gen     = view_gen(d),
		source  = v.source,
		id      = v.id,
		name    = v.name,
		image   = v.image,
		version = list_version_now(d, v.source, small_str(&v.id)).? or_else {},
	}
	r.hint = int(r.version.count) if r.version.count > 0 else v.hint
	r.count = r.hint
	r.has_arena = vmem.arena_init_growing(&r.arena) == nil
	view_reserve(r, max(r.hint, PAGE_FIRST))
	view_pages(d, r)
}

// refresh_drop forgets the refresh. Its rows were never drawn.
refresh_drop :: proc(d: ^Data) {
	r := &d.refresh
	if r.has_arena {
		vmem.arena_destroy(&r.arena)
	}
	r^ = {}
}

// Row_Marks are the rows the library points at, by track id, so they can be
// found again when a list's rows change under them.
Row_Marks :: struct {
	selected, top, menu, status: i64,
	at:                          [4]int, // their rows before
	menu_open:                   bool,
	offset:                      f32,
}

row_marks :: proc(s: ^State) -> (m: Row_Marks) {
	lib := &s.library
	id :: proc(s: ^State, i: int) -> i64 {
		r := view_row(s, i)
		return r.id if r != nil else 0
	}
	m.at = {lib.selected, lib.top_row, lib.menu_row, lib.status_track}
	m.selected = id(s, lib.selected)
	m.top = id(s, lib.top_row)
	m.menu = id(s, lib.menu_row)
	m.status = id(s, lib.status_track)
	m.menu_open = lib.menu_list == list_gen(s)
	m.offset = lib.top_offset
	return
}

// find_row is the row holding track, the one nearest near if several do, or
// -1.
find_row :: proc(v: ^Track_View, track: i64, near: int) -> int {
	if track == 0 {
		return -1
	}
	best := -1
	for i in 0 ..< min(v.count, len(v.loaded)) {
		if v.loaded[i] && v.rows[i].id == track && (best < 0 || abs(i - near) < abs(best - near)) {
			best = i
		}
	}
	return best
}

// rows_moved points the library back at the tracks in m after the open
// list's rows changed: the selection, the track menu, the status line and
// the scroll position, which keeps the first row in view where it was. The
// playing row follows by itself (playing_row), and the play queue is a copy.
rows_moved :: proc(s: ^State, m: Row_Marks) {
	lib := &s.library
	v := &s.data.view
	lib.selected = find_row(v, m.selected, m.at[0])
	if top := find_row(v, m.top, m.at[1]); top >= 0 {
		lib.anchor_row = top
		lib.anchor_offset = m.offset
	}
	if m.menu_open {
		if row := find_row(v, m.menu, m.at[2]); row >= 0 {
			lib.menu_row = row
			lib.menu_list = list_gen(s)
		}
	}
	if lib.status != .None {
		if row := find_row(v, m.status, m.at[3]); row >= 0 {
			lib.status_track = row
		} else {
			lib.status = .None
		}
	}
}

// refresh_land makes the refreshed rows the open list's. Results land
// before the frame is built, so nothing borrows the old rows.
refresh_land :: proc(s: ^State) {
	d := &s.data
	marks := row_marks(s)
	old := d.view
	d.view = d.refresh
	d.view.fetched = unix_now()
	d.refresh = {}
	if old.has_arena {
		arena_free(d, &old.arena)
	}
	rows_moved(s, marks)
	log.debugf("lists: %s fetched again, %d rows", list_name(d.view.source, small_str(&d.view.id)), d.view.count)
	list_save(d, &d.view)
}

// Own edits

ADD_STATUSES :: bit_set[Status]{.Adding, .Added, .Already_In, .Add_Failed}

// add_to_list adds row track of the open list to sidebar entry entry on
// TIDAL: Liked Songs likes it, a playlist gets it at the end. add_result
// puts it in the kept copies. The fake data only says it was added.
add_to_list :: proc(s: ^State, track, entry: int) {
	d := &s.data
	row := view_row(s, track)
	if row == nil {
		return
	}
	if d.fake {
		set_status(s, .Added, track, entry)
		return
	}
	if entry < 0 || entry > len(d.sidebar.items) || row.id == 0 {
		return
	}
	job := Job{kind = .Add_Track, source = .Liked, key = u64(row.id)}
	if entry > 0 {
		job.source = .Playlist
		job.id = small(d.sidebar.items[entry - 1].id)
	}
	push_job(d, job) // a refused one is held and pushed next frame
	set_status(s, .Adding, track, entry)
}

// add_result takes an Add_Track. With the row as TIDAL now lists it, the
// kept copies take it in place at the version TIDAL gave, so nothing is
// fetched again. Without it they're dropped and the list is fetched again.
// The status line says how it went if it still names this add.
add_result :: proc(s: ^State, res: ^Result) {
	d := &s.data
	lib := &s.library
	job := &res.job
	id := small_str(&job.id)
	err, failed := res.err.?
	added := res.added
	if job.source == .Liked && len(res.rows) == 1 {
		// Liking a liked track adds nothing, and only the count tells.
		added = res.version.count > i64(d.sidebar.liked_count)
	}
	status := Status.Added
	switch {
	case failed:
		status = .Add_Failed
		log.warnf("lists: adding a track to %s failed: %v", list_name(job.source, id), err)
	case !added:
		status = .Already_In
	case len(res.rows) == 1:
		list_edited(s, job.source, id, true, res.rows[0], res.version)
	case:
		list_forget(s, job.source, id)
	}
	if lib.status != .Adding {
		return
	}
	row := view_row(s, lib.status_track)
	entry := lib.status_list
	same_list := entry == 0 if job.source == .Liked else entry > 0 && entry <= len(d.sidebar.items) && d.sidebar.items[entry - 1].id == id
	if row != nil && row.id == i64(job.key) && same_list {
		lib.status = status
	}
}

// list_forget drops the kept copies of a list that changed in a way the
// app can't put in them. The open list is fetched again now, any other
// when it next opens.
list_forget :: proc(s: ^State, source: Source, id: string) {
	d := &s.data
	r := &d.refresh
	if r.source == source && small_str(&r.id) == id {
		refresh_drop(d)
	}
	v := &d.view
	if v.source == source && small_str(&v.id) == id && v.fetched != 0 {
		refresh_start(d)
	} else if i := lru_find(d, source, id); i >= 0 {
		lru_drop(d, i)
	}
	disk_push(d, {op = .Delete, source = source, id = small(id)})
}

// list_edited applies an edit the app made on TIDAL to the copies it keeps,
// so neither the next open nor the next launch fetches the list again. With
// add, row goes at the end of a playlist or the top of Liked Songs; without
// it, the first row with row.id goes. version is the list's after the edit,
// as TIDAL gave it, or {} to have the next sidebar refresh fetch it again.
// Call it between frames, as results are handled.
list_edited :: proc(s: ^State, source: Source, id: string, add: bool, row: Row, version: List_Version) {
	d := &s.data
	sb := &d.sidebar
	if source == .Liked {
		sb.liked_count, sb.liked_newest = int(version.count), version.newest
	}
	for &it in sb.items {
		if source == .Playlist && it.id == id {
			it.tracks, it.updated = int(version.count), version.updated
		}
	}
	sidebar_save(d)
	r := &d.refresh
	if r.source == source && small_str(&r.id) == id {
		refresh_drop(d)
	}
	v := &d.view
	if v.source == source && small_str(&v.id) == id && v.fetched != 0 {
		marks := row_marks(s)
		if view_edit(v, add, row) {
			rows_moved(s, marks)
		}
		v.version = version
		list_save(d, v)
		return
	}
	if i := lru_find(d, source, id); i >= 0 {
		e := &d.lists.entries[i]
		view_edit(&e.view, add, row)
		e.view.version = version
		d.lists.bytes -= e.bytes
		e.bytes = arena_bytes(&e.view.arena)
		d.lists.bytes += e.bytes
		list_save(d, &e.view)
		lists_trim(d)
		return
	}
	// Only on disk, if at all: it's fetched again when it opens.
	disk_push(d, {op = .Delete, source = source, id = small(id)})
}

// view_edit adds or removes a row of a done list.
view_edit :: proc(v: ^Track_View, add: bool, row: Row) -> bool {
	if !v.has_arena {
		return false
	}
	n := min(v.count, len(v.rows))
	if add {
		view_reserve(v, n + 1)
		at := 0 if v.source == .Liked else n
		copy(v.rows[at + 1:n + 1], v.rows[at:n])
		v.rows[at] = row_clone(row, vmem.arena_allocator(&v.arena))
		slice.fill(v.loaded[:n + 1], true)
		v.count = n + 1
		v.loaded_rows = n + 1
		v.hint += 1
		v.longest = max(v.longest, row.seconds)
		return true
	}
	at := -1
	for i in 0 ..< n {
		if v.rows[i].id == row.id {
			at = i
			break
		}
	}
	if at < 0 {
		return false
	}
	copy(v.rows[at:], v.rows[at + 1:n])
	v.loaded[n - 1] = false
	v.count = n - 1
	v.loaded_rows -= 1
	v.hint = max(v.hint - 1, 0)
	return true
}

row_clone :: proc(r: Row, a: runtime.Allocator) -> Row {
	out := r
	out.title = strings.clone(r.title, a)
	out.artist = strings.clone(r.artist, a)
	out.artists = slice.clone(r.artists, a)
	out.album = strings.clone(r.album, a)
	out.added = strings.clone(r.added, a)
	out.duration = strings.clone(r.duration, a)
	out.cover = strings.clone(r.cover, a)
	return out
}

// The sidebar

// sidebar_adopt takes a sidebar from TIDAL or from disk. The open playlist
// is found again by id, since playlists may have come or gone. One from
// disk is taken only while TIDAL's hasn't come.
sidebar_adopt :: proc(s: ^State, res: ^Result, from_disk: bool) {
	d := &s.data
	lib := &s.library
	open := ""
	if !s.search.browsing && d.view.source == .Playlist {
		open = strings.clone(small_str(&d.view.id), context.temp_allocator)
	}
	loading := d.sidebar.loading
	fetched := d.sidebar.fetched
	sidebar_free(d)
	d.sidebar = {
		arena        = res.arena,
		items        = res.playlists,
		liked_count  = res.liked_count,
		liked_newest = res.liked_newest,
		loaded       = true,
		loading      = loading,
		fresh        = !from_disk,
		fetched      = fetched if from_disk else time.tick_now(),
	}
	res.arena = nil
	if lib.status in ADD_STATUSES {
		lib.status = .None // it names a sidebar entry by its place
	}
	if open != "" {
		lib.playlist = -1
		for &it, i in d.sidebar.items {
			if it.id == open {
				lib.playlist = i + 1
			}
		}
	}
	if d.view.source == .None {
		select_playlist(s, 0)
	} else if !from_disk {
		list_check(d)
	}
}

// sidebar_check fetches the sidebar again if it's older than
// SIDEBAR_MAX_AGE, or came from disk and TIDAL's never did. It runs on
// things the user does, never on a timer.
sidebar_check :: proc(d: ^Data) {
	// A zero tick is when the machine booted, not long ago after a reboot.
	if d.account == .Signed_In && (d.sidebar.fetched == {} || time.tick_since(d.sidebar.fetched) > SIDEBAR_MAX_AGE) {
		request_playlists(d)
	}
}

// lists_window_key fetches the sidebar again when the window becomes key,
// if it's old.
lists_window_key :: proc(s: ^State, key: bool) {
	d := &s.data
	if key && !d.window_key {
		sidebar_check(d)
	}
	d.window_key = key
}

// The disk

disk_on :: proc(d: ^Data) -> bool {
	return d.lists.root != "" && d.lists.user != 0
}

// lists_signed_in points the disk cache at the user's folder and reads the
// sidebar and the play queue from it.
lists_signed_in :: proc(d: ^Data, user: i64) {
	sync.atomic_store(&d.lists.user, user)
	disk_push(d, {op = .Read})
	disk_push(d, {op = .Read_Queue})
}

// lists_forget drops what's kept for the account that signed out: in memory
// and its folder on disk.
lists_forget :: proc(d: ^Data) {
	lists_clear(d)
	refresh_drop(d)
	jobs.remove_if(&d.lists.queue, drop_disk_job, nil)
	dir := disk_dir(d.lists.root, d.lists.user, context.temp_allocator) if disk_on(d) else ""
	// The delete and the user going are one step under the mutex, so a
	// cover write waiting on it sees the user gone.
	sync.guard(&d.lists.mutex)
	if dir != "" {
		os.remove_all(dir)
	}
	sync.atomic_store(&d.lists.user, 0)
}

@(private = "file")
drop_disk_job :: proc(job: ^Job, _: rawptr) -> bool {
	delete(job.blob, runtime.heap_allocator())
	job.blob = nil
	return true
}

// disk_push queues a disk job for the signed-in user. The disk cache is
// best effort: a full queue drops it.
disk_push :: proc(d: ^Data, job: Job) -> bool {
	job := job
	job.kind = .Disk
	job.auth = d.auth_gen
	job.key = u64(d.lists.user)
	if !disk_on(d) || !jobs.push(&d.lists.queue, job) {
		delete(job.blob, runtime.heap_allocator())
		return false
	}
	return true
}

disk_start :: proc(d: ^Data) {
	l := &d.lists
	if l.running {
		return
	}
	jobs.start(&l.queue)
	posix.pthread_create(&l.thread, nil, disk_main, d)
	l.running = true
}

disk_stop :: proc(d: ^Data) {
	l := &d.lists
	if !l.running {
		return
	}
	jobs.stop(&l.queue)
	posix.pthread_join(l.thread)
	l.running = false
}

// lists_shutdown frees everything the cache holds. The disk thread has
// stopped.
lists_shutdown :: proc(d: ^Data) {
	jobs.remove_if(&d.lists.queue, drop_disk_job, nil)
	lists_clear(d)
	refresh_drop(d)
	delete(d.lists.root, runtime.heap_allocator())
	d.lists.root = ""
}

@(private = "file")
disk_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	context.logger = app_logger()
	d := (^Data)(arg)
	for {
		job, ticket, ok := jobs.pop_wait(&d.lists.queue)
		if !ok {
			break
		}
		res, reply := disk_run(d, job)
		free_all(context.temp_allocator)
		if reply {
			if !jobs.push_wait(&d.results, res) {
				// Stopping for a reload: read it again after.
				result_free(&res)
				jobs.requeue(&d.lists.queue, job, ticket)
				continue
			}
			d.wake()
		}
		jobs.done(&d.lists.queue)
	}
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
}

disk_dir :: proc(root: string, user: i64, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("%s/%d", root, user, allocator = allocator)
}

// disk_path is the file for a list, or the sidebar for .None. Ids that
// aren't plain letters, digits and dashes go by their hash.
disk_path :: proc(dir: string, source: Source, id: string, allocator: runtime.Allocator) -> string {
	names := [Source]string {
		.None     = "sidebar",
		.Liked    = "liked",
		.Playlist = "playlist-",
		.Search   = "search-",
		.Album    = "album-",
		.Artist   = "artist-",
	}
	name := id
	for c in transmute([]u8)id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '-') {
			name = fmt.tprintf("%x", fnv64(id))
			break
		}
	}
	if source == .None || source == .Liked {
		name = ""
	}
	return fmt.aprintf("%s/%s%s.tfl", dir, names[source], name, allocator = allocator)
}

@(private = "file")
fnv64 :: proc(s: string) -> u64 {
	h: u64 = 14695981039346656037
	for b in transmute([]u8)s {
		h = (h ~ u64(b)) * 1099511628211
	}
	return h
}

// disk_run does a disk job. Reads answer with a Result; the rest don't.
disk_run :: proc(d: ^Data, job: Job) -> (res: Result, reply: bool) {
	res.job = job
	defer delete(job.blob, runtime.heap_allocator())
	id := job.id
	dir := disk_dir(d.lists.root, i64(job.key), context.temp_allocator)
	path := disk_path(dir, job.source, small_str(&id), context.temp_allocator)
	#partial switch job.op {
	case .Read:
		disk_read(&res, path, job.source, small_str(&id))
		return res, true
	case .Read_Queue, .Write_Queue, .Delete_Queue:
		path = queue_path(dir, context.temp_allocator)
	}
	if job.op == .Read_Queue {
		queue_read(&res, path)
		return res, true
	}
	#partial switch job.op {
	case .Write_Queue:
		queue_seal(job.blob)
	case .Write:
		file_seal(job.blob)
	}
	sync.guard(&d.lists.mutex)
	if job.auth != sync.atomic_load(&d.auth_gen) {
		return // that account is gone
	}
	switch job.op {
	case .Read, .Read_Queue:
	case .Write_Queue:
		disk_write(dir, path, job.blob)
	case .Write:
		if disk_write(dir, path, job.blob) {
			disk_evict(dir, LIST_DISK_BUDGET, ".tfl")
		}
	case .Touch:
		now := time.now()
		os.change_times(path, now, now)
	case .Delete, .Delete_Queue:
		os.remove(path)
	}
	return
}

// queue_path is the play queue's file. It isn't a .tfl, so disk_evict
// never drops it.
queue_path :: proc(dir: string, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("%s/queue.tfq", dir, allocator = allocator)
}

// queue_read reads the play queue's file into res, in an arena of its own.
// A file that's damaged or of another format is deleted.
@(private = "file")
queue_read :: proc(res: ^Result, path: string) {
	res.arena = new(vmem.Arena, runtime.heap_allocator())
	if vmem.arena_init_growing(res.arena) != nil {
		free(res.arena, runtime.heap_allocator())
		res.arena = nil
		return
	}
	a := vmem.arena_allocator(res.arena)
	data, ok := file_read(path, a)
	if !ok {
		return
	}
	err: File_Error
	if res.queue, res.rows, err = queue_decode(data, a); err != .None {
		log.warnf("lists: dropping the play queue's file (%v)", err)
		os.remove(path)
		return
	}
	res.hit = true
}

// queue_write_now writes the play queue's file on this thread, after the
// disk thread has stopped.
queue_write_now :: proc(d: ^Data, blob: []u8) {
	assert(!d.lists.running, "the disk thread could write an older queue after this one")
	if !disk_on(d) {
		return
	}
	queue_seal(blob)
	dir := disk_dir(d.lists.root, d.lists.user, context.temp_allocator)
	sync.guard(&d.lists.mutex)
	disk_write(dir, queue_path(dir, context.temp_allocator), blob)
}

// disk_read reads a list or the sidebar into res, in an arena of its own
// that the list adopts. A file that's damaged or of another format is
// deleted.
@(private = "file")
disk_read :: proc(res: ^Result, path: string, source: Source, id: string) {
	res.arena = new(vmem.Arena, runtime.heap_allocator())
	if vmem.arena_init_growing(res.arena) != nil {
		free(res.arena, runtime.heap_allocator())
		res.arena = nil
		return
	}
	a := vmem.arena_allocator(res.arena)
	data, ok := file_read(path, a)
	if !ok {
		return
	}
	h: ^File_Header
	err: File_Error
	if source == .None {
		h, res.playlists, err = sidebar_decode(data, a)
	} else {
		h, res.rows, err = list_decode(data, source, id, a)
	}
	if err != .None {
		log.warnf("lists: dropping a cache file (%v)", err)
		os.remove(path)
		return
	}
	res.hit = true
	res.version = h.version
	res.fetched = h.fetched
	res.total = int(h.hint)
	res.liked_count = int(h.version.count)
	res.liked_newest = h.version.newest
	now := time.now()
	os.change_times(path, now, now)
}

@(private = "file")
disk_write :: proc(dir, path: string, blob: []u8) -> bool {
	os.make_directory_all(dir)
	key: u64
	crypto.rand_bytes(mem.ptr_to_bytes(&key))
	tmp := fmt.tprintf("%s.tmp-%x", path, key)
	f, oerr := os.open(tmp, {.Write, .Create, .Excl}, {.Read_User, .Write_User})
	if oerr != nil {
		return false
	}
	_, werr := os.write(f, blob)
	if cerr := os.close(f); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.rename(tmp, path)
	}
	if werr != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// disk_evict deletes the files in dir ending in ext opened longest ago
// until the rest take budget bytes or less, and temp files a crash left.
// The sidebar stays. It returns how many it deleted.
disk_evict :: proc(dir: string, budget: int, ext: string) -> int {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return 0
	}
	files := make([dynamic]os.File_Info, 0, len(infos), context.temp_allocator)
	total := 0
	removed := 0
	for fi in infos {
		if strings.contains(fi.name, ".tmp-") {
			if time.since(fi.modification_time) > time.Minute {
				os.remove(fi.fullpath)
				removed += 1
			}
			continue
		}
		if !strings.has_suffix(fi.name, ext) {
			continue
		}
		total += int(fi.size)
		if fi.name != "sidebar.tfl" {
			append(&files, fi)
		}
	}
	if total <= budget {
		return removed
	}
	slice.sort_by(files[:], proc(a, b: os.File_Info) -> bool {
		return time.diff(a.modification_time, b.modification_time) > 0
	})
	for fi in files {
		if total <= budget {
			break
		}
		if os.remove(fi.fullpath) == nil {
			total -= int(fi.size)
			removed += 1
		}
	}
	return removed
}

// Covers. Image ids never change what they show, so a cover file is never
// stale. The workers read and write them next to the lists, in
// root/<user>/covers, so sign-out deletes them too.

// cover_file is where a Cover job's JPEG goes, or "" with no disk cache.
cover_file :: proc(d: ^Data, image: string, size: int) -> (dir, path: string) {
	user := sync.atomic_load(&d.lists.user)
	if d.lists.root == "" || user == 0 || image == "" {
		return "", ""
	}
	for c in transmute([]u8)image {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '-') {
			return "", ""
		}
	}
	dir = fmt.tprintf("%s/%d/covers", d.lists.root, user)
	return dir, fmt.tprintf("%s/%s-%d.jpg", dir, image, size)
}

// cover_read reads a cover's JPEG from disk, heap, and marks it used.
cover_read :: proc(path: string) -> ([]u8, bool) {
	if path == "" {
		return nil, false
	}
	data, ok := file_read(path, runtime.heap_allocator())
	if ok {
		now := time.now()
		os.change_times(path, now, now)
	}
	return data, ok
}

// cover_write keeps a downloaded JPEG, unless its user signed out since
// the path was made. Every COVER_EVICT_EVERY writes, starting with the
// first, the folder is brought back under COVER_DISK_BUDGET.
cover_write :: proc(d: ^Data, dir, path: string, data: []u8) {
	if path == "" {
		return
	}
	sync.guard(&d.lists.mutex)
	if !strings.has_prefix(dir, fmt.tprintf("%s/%d/", d.lists.root, sync.atomic_load(&d.lists.user))) {
		return
	}
	if disk_write(dir, path, data) && sync.atomic_add(&d.lists.covers_written, 1) % COVER_EVICT_EVERY == 0 {
		disk_evict(dir, COVER_DISK_BUDGET, ".jpg")
	}
}

// disk_result takes a disk read: the open list's rows, the sidebar or the
// play queue.
disk_result :: proc(s: ^State, res: ^Result) {
	d := &s.data
	if res.job.op == .Read_Queue {
		if res.job.auth == d.auth_gen {
			playback_restore(s, res)
		}
		return
	}
	if res.job.source == .None {
		if res.hit && !d.sidebar.fresh {
			log.debugf("lists: sidebar from disk, %d playlists", len(res.playlists))
			sidebar_adopt(s, res, true)
		}
		return
	}
	v := &d.view
	if res.job.view != v.gen || !v.reading {
		return
	}
	v.reading = false
	if !res.hit {
		view_fetch(d, v.source, small_str(&v.id), small_str(&v.name), small_str(&v.image), v.hint)
		return
	}
	v.arena = res.arena^
	free(res.arena, runtime.heap_allocator())
	res.arena = nil
	v.has_arena = true
	n := len(res.rows)
	v.rows = res.rows
	v.loaded = make([]bool, n, vmem.arena_allocator(&v.arena))
	slice.fill(v.loaded, true)
	v.count = n
	v.loaded_rows = n
	v.hint = res.total
	v.next_offset = res.total
	v.done = true
	v.version = res.version
	v.fetched = res.fetched
	for &r in v.rows {
		v.longest = max(v.longest, r.seconds)
	}
	log.debugf("lists: %s from disk, %d rows", list_name(v.source, small_str(&v.id)), n)
	list_check(d)
}
