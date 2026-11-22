package app

// Playback on the UI thread's side: the play queue, resolving streams on
// the workers, handing tracks to src/audio, media commands, and Now Playing.
//
// Double-clicking a row snapshots the open list into the queue and plays
// from that row. Play next and Add to queue in the track menu add a row
// from any list as an extra: a copy of the row kept after the list's items,
// with an anchor, the item it plays after in play order (the current one
// for Play next), or none for the end of the order (Add to queue). The play
// order is the list's order, shuffled or not, with each extra spliced in
// right after its anchor, the newest first, and the anchorless ones at the
// end (queue_reorder). The extras stay while the list's pages arrive and
// are saved with the queue. With nothing queued, an extra starts a queue
// of its own and plays. Each track gets a serial. Its stream is resolved by a
// Stream job; the result goes to audio.play, or to audio.set_next when the
// player asks for the following track ahead of time, which is how gapless
// works. The player's status says which serial is audible, and when that is
// the next track's, the queue moves on.
//
// The queue and where it was are kept on disk with the account's lists,
// so the next start shows the same track, paused at the same place
// (queue_save, playback_restore).
//
// With TIDALFAST_FAKE the fake rows play sine tones, 30 s each, so the
// player bar, queue and gapless switching work without an account.
//
// A PKCE login asks for HI_RES_LOSSLESS; a device-code login can only get
// LOSSLESS. Either may come back as DASH (see tidal.resolve_stream).

import "base:intrinsics"
import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../audio"
import "../cover"
import "../platform"
import "../tidal"

ARTWORK_SIZE :: 640
FAKE_TONE_SECONDS :: 30

Queue_Item :: struct {
	title, artist, album, cover: string,
	seconds:                     int,
	album_id:                    i64,
	artists:                     []Artist_Ref,
	row:                         int, // with the fake data, its row in State.rows
	after:                       int, // an extra's anchor: the item it plays after, always an earlier one, or -1 for the end
}

// Track_Source is a queue entry the player knows or is about to.
Track_Source :: struct {
	serial:    u64, // 0 for none
	queue:     u32, // the queue it's from, see Playback.queue_gen
	item:      int,
	track:     i64, // its TIDAL track id, or the fake id
	resolved:  bool, // url and gain are set
	url:       string, // heap; for DASH the initialization segment
	segments:  []audio.Segment, // DASH; heap, urls too
	timescale: i64, // DASH: units of the segments' starts per second
	dash_end:  i64, // DASH: where the last segment ends, in those units
	gain:      f32,
	rg:        audio.Replay_Gain, // what gain came from
	rate:      int,
	at:        i64, // where to start, in samples, once resolved
	retried:   bool, // re-resolved once after the stream URL stopped working
}

Artwork :: struct {
	pixels: []u8, // stb_image's
	w, h:   int,
	serial: u64, // the track it's for
}

Playback :: struct {
	player:          ^audio.Player,
	set_now_playing: proc "c" (info: ^platform.Now_Playing), // the shell's
	set_controls:    proc "c" (controls: ^platform.Player_Controls), // the shell's, or nil
	controls_sent:   Maybe(platform.Player_Controls),
	capture:         Small, // TIDALFAST_AUDIO_CAPTURE
	window:          int, // TIDALFAST_AUDIO_WINDOW_KB, in bytes
	null_output:     bool, // TIDALFAST_AUDIO_NULL: play to the silent null device

	// The queue: a snapshot of a list, then the extras, strings in arena.
	arena:           vmem.Arena,
	has_arena:       bool,
	items:           []Queue_Item,
	entries:         []audio.Queue_Entry,
	order:           []int, // the items in play order, see queue_reorder
	list_n:          int, // the items from the list; the extras come after them
	capacity:        int, // items, entries and order have room for this many
	loaded:          int, // rows loaded when the snapshot was taken
	moved:           u32, // the list's moved then
	list_key:        u64, // list_key of the list the queue came from
	queue_gen:       u32, // goes up each time a new list replaces the queue
	fake:            bool,

	index:           int, // current item, -1 for none
	serial:          u64, // the last one given out
	cur:             Track_Source,
	next:            Track_Source,
	// The next track whose stream failed to resolve, by queue, item and
	// track id. It isn't asked for again until it's current or the queue
	// changes; serial is 0 for none.
	next_failed:     Track_Source,
	paused:          bool,
	status:          audio.Status,
	output_seen:     audio.Device_Info, // the last open output, kept while the device reopens; reset when the output setting changes
	seek_id:         u32, // waiting for this seek to show up in status
	seek_serial:     u64, // the source it's for; it's dropped once that isn't current
	seek_sample:     i64,
	seek_seconds:    f64,
	dragging:        bool, // the progress bar is held: show the drag position
	drag_seconds:    f64,
	volume_sent:     f32,
	volume_save_at:  f64, // when to save the volume the wheel set, once it has stopped; 0 for none
	sleep:           Sleep_Timer,
	sleep_test:      f64, // TIDALFAST_SLEEP_TEST: a timed sleep timer of this many seconds, set at the first frame
	message:         Small,
	error_seen:      u64,

	art:             Artwork, // the current track's, for Now Playing
	next_art:        Artwork, // the next track's, fetched with its stream
	np_key:          u64, // what was last sent to Now Playing
	save_key:        u64, // what the queue's rows were last written for
	place_key:       u64, // and where in it, see Queue_Position
	file_key:        u64, // the key of the queue's last file

	// The row of the open list found holding the current track, for when
	// the queue's index doesn't (see playing_row), and what it was found in.
	found_row:       int,
	found_track:     i64,
	found_gen:       u32,
	found_loaded:    int,
	found_count:     int,
}

playback_start :: proc(s: ^State, shell: ^platform.Shell) {
	pb := &s.playback
	pb.index = -1
	pb.set_now_playing = shell.set_now_playing
	pb.set_controls = shell.set_player_controls
	pb.capture = small(os.get_env("TIDALFAST_AUDIO_CAPTURE", context.temp_allocator))
	pb.window = audio.STREAM_WINDOW
	if kb, ok := strconv.parse_int(os.get_env("TIDALFAST_AUDIO_WINDOW_KB", context.temp_allocator)); ok {
		pb.window = kb << 10
	}
	pb.null_output = os.get_env("TIDALFAST_AUDIO_NULL", context.temp_allocator) != ""
	if v, ok := strconv.parse_f64(os.get_env("TIDALFAST_SLEEP_TEST", context.temp_allocator)); ok && v > 0 {
		pb.sleep_test = v
	}
	s.data.launch_log_path = launch_log_path(runtime.heap_allocator())
	if v, ok := strconv.parse_f32(os.get_env("TIDALFAST_VOLUME", context.temp_allocator)); ok {
		s.volume_before_override = s.settings.volume
		s.settings.volume = clamp(v, 0, 1)
	}
	when !audio.BIT_PERFECT {
		s.settings.bit_perfect = false
	}
	// The app died with a device switched to a track's rate. Put it back
	// before anything plays.
	if s.settings.device.rate != 0 {
		audio.device_change_undo(&s.settings.device)
		s.settings.device = {}
		settings_queue(&s.data, settings_to_save(s))
	}
	pb.volume_sent = volume_heard(s.settings)
	pb.player = audio.create(shell.request_redraw, pb.volume_sent, small_str(&pb.capture), pb.window, pb.null_output, output_of(s.settings))
}

playback_shutdown :: proc(s: ^State) {
	pb := &s.playback
	if pb.player != nil && pb.index >= 0 && disk_on(&s.data) {
		pb.status = audio.status(pb.player)
		queue_write_now(&s.data, queue_file(pb, context.temp_allocator))
	}
	if pb.volume_save_at != 0 {
		volume_save(s, now = true)
	}
	audio.destroy(pb.player)
	pb.player = nil
	// destroy put the device back.
	if s.settings.device.rate != 0 {
		s.settings.device = {}
		settings_queue(&s.data, settings_to_save(s), now = true)
	}
	if pb.set_now_playing != nil {
		none: platform.Now_Playing
		pb.set_now_playing(&none)
	}
	source_clear(&pb.cur)
	source_clear(&pb.next)
	if pb.has_arena {
		vmem.arena_destroy(&pb.arena)
		pb.has_arena = false
	}
	artwork_free(&pb.art)
	artwork_free(&pb.next_art)
}

@(private = "file")
artwork_free :: proc(a: ^Artwork) {
	cover.free_pixels(a.pixels)
	a^ = {}
}

@(private = "file")
source_clear :: proc(t: ^Track_Source) {
	source_forget_url(t)
	t^ = {}
}

// source_forget_url frees the track's URLs.
@(private = "file")
source_forget_url :: proc(t: ^Track_Source) {
	heap := runtime.heap_allocator()
	delete(t.url, heap)
	for seg in t.segments {
		delete(seg.url, heap)
	}
	delete(t.segments, heap)
	t.url, t.segments = "", nil
}

@(private = "file")
source_of :: proc(pb: ^Playback, t: ^Track_Source) -> audio.Source {
	if pb.fake {
		hz := 220 * math.pow(2, f32(t.item % 24) / 12)
		return {kind = .Tone, serial = t.serial, gain = 1, seconds = FAKE_TONE_SECONDS, tone_hz = hz}
	}
	src := audio.Source {
		kind    = .Flac,
		serial  = t.serial,
		url     = t.url,
		gain    = t.gain,
		seconds = f64(pb.items[t.item].seconds),
	}
	if len(t.segments) > 0 {
		src.kind = .Dash
		src.segments = t.segments
		src.timescale = t.timescale
		src.dash_end = t.dash_end
	}
	return src
}

// queue_snapshot copies v, the open list or the one the queue follows,
// into the queue. The fake data has only the open list.
@(private = "file")
queue_snapshot :: proc(s: ^State, v: ^Track_View) {
	pb := &s.playback
	n := view_count(s) if s.data.fake else v.count
	a := queue_reset(pb, n)
	pb.fake = s.data.fake
	s.data.queue_view = v.gen
	pb.loaded = v.loaded_rows
	pb.moved = v.moved
	for i in 0 ..< n {
		row := view_row(s, i) if s.data.fake else list_row(v, i)
		if row == nil {
			continue
		}
		queue_fill(pb, i, row, a)
		pb.items[i].row = fake_row_index(s, i)
		if pb.fake {
			pb.entries[i].id = -i64(i + 1)
		}
	}
}

// queue_follow brings the queue up to date with v, the list it was
// snapshot from, as its pages arrive: the rows that came since are copied
// in. Rows that moved take a new snapshot. The extras are put back after
// the list's items, their anchors moved with the items they name.
@(private = "file")
queue_follow :: proc(s: ^State, v: ^Track_View) {
	pb := &s.playback
	old_n := pb.list_n
	moved := v.moved != pb.moved || !pb.has_arena
	extras := queue_extras_take(pb, deep = moved)
	if moved {
		queue_snapshot(s, v)
		queue_extras_put(pb, extras, old_n, clone = true)
		return
	}
	a := vmem.arena_allocator(&pb.arena)
	if n, old := v.count, len(pb.items); n != old {
		queue_grow(pb, n)
		pb.items = queue_len(pb.items, n)
		pb.entries = queue_len(pb.entries, n)
		pb.order = queue_len(pb.order, n)
		if n > old {
			slice.zero(pb.items[old:])
			slice.zero(pb.entries[old:])
		}
		pb.list_n = n
	}
	pb.loaded = v.loaded_rows
	for &e, i in pb.entries {
		if e.id != 0 {
			continue
		}
		if row := list_row(v, i); row != nil {
			queue_fill(pb, i, row, a)
		}
	}
	queue_extras_put(pb, extras, old_n, clone = false)
}

// Queue_Extra is an extra taken out of the queue while its list part
// changes, with its anchor by item and track.
@(private = "file")
Queue_Extra :: struct {
	item:  Queue_Item,
	entry: audio.Queue_Entry,
	after: Queue_Place,
}

// queue_extras_take takes the extras out of the queue, leaving the list's
// items. deep copies their strings, for when the arena goes.
@(private = "file")
queue_extras_take :: proc(pb: ^Playback, deep: bool) -> []Queue_Extra {
	out := make([]Queue_Extra, len(pb.items) - pb.list_n, context.temp_allocator)
	for &x, j in out {
		i := pb.list_n + j
		x.item = pb.items[i]
		if deep {
			x.item = item_clone(x.item, context.temp_allocator)
		}
		x.entry = pb.entries[i]
		a := x.item.after
		x.after = {a, pb.entries[a].id if a >= 0 else 0}
	}
	pb.items = pb.items[:pb.list_n]
	pb.entries = pb.entries[:pb.list_n]
	pb.order = pb.order[:pb.list_n]
	return out
}

// queue_extras_put puts extras taken from a queue whose list had old_n
// items back after the list's items now. clone copies their strings into
// the queue's arena. The order needs a queue_reorder after it.
@(private = "file")
queue_extras_put :: proc(pb: ^Playback, extras: []Queue_Extra, old_n: int, clone: bool) {
	for &x in extras {
		i := queue_append(pb)
		pb.items[i] = item_clone(x.item, vmem.arena_allocator(&pb.arena)) if clone else x.item
		pb.entries[i] = x.entry
		pb.items[i].after = queue_place(pb, x.after, old_n)
	}
}

@(private = "file")
item_clone :: proc(it: Queue_Item, a: runtime.Allocator) -> Queue_Item {
	out := it
	out.title = strings.clone(it.title, a)
	out.artist = strings.clone(it.artist, a)
	out.album = strings.clone(it.album, a)
	out.cover = strings.clone(it.cover, a)
	out.artists = slice.clone(it.artists, a)
	return out
}

// queue_grow makes room for n items, keeping the items, entries and order.
@(private = "file")
queue_grow :: proc(pb: ^Playback, n: int) {
	if n <= pb.capacity {
		return
	}
	a := vmem.arena_allocator(&pb.arena)
	pb.capacity = max(n, 2 * pb.capacity)
	items := make([]Queue_Item, pb.capacity, a)
	entries := make([]audio.Queue_Entry, pb.capacity, a)
	order := make([]int, pb.capacity, a)
	copy(items, pb.items)
	copy(entries, pb.entries)
	copy(order, pb.order)
	pb.items = items[:len(pb.items)]
	pb.entries = entries[:len(pb.entries)]
	pb.order = order[:len(pb.order)]
}

// queue_append adds an empty item at the end, and returns it. Its place in
// the order is left to the caller.
@(private = "file")
queue_append :: proc(pb: ^Playback) -> int {
	i := len(pb.items)
	queue_grow(pb, i + 1)
	pb.items = queue_len(pb.items, i + 1)
	pb.entries = queue_len(pb.entries, i + 1)
	pb.order = queue_len(pb.order, i + 1)
	pb.items[i] = {}
	pb.entries[i] = {}
	return i
}

// queue_place is where an item of the queue before its list changed from
// old_n items is now: an extra keeps its place after the list, and the
// list's item is found by its track (queue_find).
@(private = "file")
queue_place :: proc(pb: ^Playback, p: Queue_Place, old_n: int) -> int {
	if p.item < 0 {
		return -1
	}
	if p.item >= old_n {
		return p.item - old_n + pb.list_n
	}
	return queue_find(pb, p.track, p.item)
}

// queue_len is s at length n, which can be up to the queue's capacity.
@(private = "file")
queue_len :: proc(s: []$T, n: int) -> []T {
	return ([^]T)(raw_data(s))[:n]
}

// queue_reset makes a new, empty queue of n items, and returns its
// arena's allocator.
@(private = "file")
queue_reset :: proc(pb: ^Playback, n: int) -> runtime.Allocator {
	if pb.has_arena {
		vmem.arena_destroy(&pb.arena)
	}
	pb.has_arena = vmem.arena_init_growing(&pb.arena) == nil
	a := vmem.arena_allocator(&pb.arena)
	pb.items = make([]Queue_Item, n, a)
	pb.entries = make([]audio.Queue_Entry, n, a)
	pb.order = make([]int, n, a)
	pb.capacity = n
	pb.list_n = n
	audio.queue_order(pb.order, nil, false)
	return a
}

// queue_reorder puts the list's items in list order, or with shuffle on,
// the items in head and then the rest shuffled, and splices the extras in:
// each right after its anchor, with what was spliced after it, the newest
// first, and those without one at the end in the order they came. An
// extra in head stands for the list item it hangs from.
@(private = "file")
queue_reorder :: proc(s: ^State, head: []int) {
	pb := &s.playback
	shuffle := s.settings.shuffle
	roots := make([]int, len(head) if shuffle else 0, context.temp_allocator)
	for &r, k in roots {
		r = queue_root(pb, head[k])
	}
	base := make([]int, pb.list_n, context.temp_allocator)
	audio.queue_order(base, roots, shuffle)

	n := len(pb.items)
	first := make([]int, n, context.temp_allocator)
	sibling := make([]int, n, context.temp_allocator)
	slice.fill(first, -1)
	ends := make([dynamic]int, context.temp_allocator)
	for i in pb.list_n ..< n {
		if a := pb.items[i].after; a >= 0 {
			sibling[i] = first[a]
			first[a] = i
		} else {
			append(&ends, i)
		}
	}
	p := 0
	for i in base {
		p = splice(pb.order, first, sibling, i, p)
	}
	for i in ends {
		p = splice(pb.order, first, sibling, i, p)
	}
}

// splice puts item i in order at p, then what hangs from it, and returns
// the place after them.
@(private = "file")
splice :: proc(order, first, sibling: []int, i, at: int) -> int {
	order[at] = i
	p := at + 1
	for c := first[i]; c >= 0; c = sibling[c] {
		p = splice(order, first, sibling, c, p)
	}
	return p
}

// queue_root is the list item that item i hangs from, itself for a list
// item, or -1 for an extra at the end of the order.
@(private = "file")
queue_root :: proc(pb: ^Playback, item: int) -> int {
	i := item
	for i >= pb.list_n && i < len(pb.items) {
		i = pb.items[i].after
	}
	return i if i < len(pb.items) else -1
}

// queue_fill makes queue item i row, its strings copied with a.
@(private = "file")
queue_fill :: proc(pb: ^Playback, i: int, row: ^Row, a: runtime.Allocator) {
	pb.items[i] = {
		title    = strings.clone(row.title, a),
		artist   = strings.clone(row.artist, a),
		album    = strings.clone(row.album, a),
		cover    = strings.clone(row.cover, a),
		seconds  = row.seconds,
		album_id = row.album_id,
		artists  = slice.clone(row.artists, a),
	}
	pb.entries[i] = {id = row.id, album_id = row.album_id, track_num = row.track}
}

// playback_play_row plays row i of the open list, with the rest of the
// list queued after it. A track preloaded from the old queue isn't reused,
// even at the same row.
playback_play_row :: proc(s: ^State, i: int) {
	if !row_playable(s, i) {
		return
	}
	queue_snapshot(s, &s.data.view)
	s.playback.list_key = list_key(s)
	queue_reorder(s, {i})
	s.playback.queue_gen += 1
	start_item(s, i)
}

// playback_queue_row adds row i of the open list to the queue as an extra:
// with next set right after the current track in play order (Play next),
// else at the end of the order (Add to queue). With nothing queued it
// starts a queue of that track and plays it, as it does when the current
// track stopped on a failure. A queue that played out goes on to it by
// itself (playback_observe). A preloaded next track that's no longer next
// is dropped.
playback_queue_row :: proc(s: ^State, i: int, next: bool) -> bool {
	if !row_playable(s, i) {
		return false
	}
	pb := &s.playback
	row := view_row(s, i)
	if pb.index < 0 || !pb.has_arena {
		queue_reset(pb, 0)
		pb.fake = s.data.fake
		pb.list_key = 0
		pb.loaded = 0
		pb.moved = 0
		// A gen no view is given, as for a restored queue: no list follows.
		s.data.queue_view = view_gen(&s.data)
		item := queue_extra(s, i, row, -1)
		pb.order[0] = item
		pb.queue_gen += 1
		start_item(s, item)
		return true
	}
	after := -1
	if next {
		after = pb.index
		// The player already went on to the preloaded track.
		if pb.next.serial != 0 && pb.status.serial == pb.next.serial {
			after = pb.next.item
		}
	}
	item := queue_extra(s, i, row, after)
	// In place, as queue_reorder would put it, so the rest keeps its order.
	last := len(pb.order) - 1
	if p, found := slice.linear_search(pb.order[:last], after); found {
		copy(pb.order[p + 2:], pb.order[p + 1:last])
		pb.order[p + 1] = item
	} else {
		pb.order[last] = item
	}
	if pb.cur.serial == 0 {
		start_item(s, item)
		return true
	}
	if pb.next.serial != 0 && audio.queue_after(pb.entries, pb.order, pb.index, s.settings.repeat, user = false) != pb.next.item {
		next_drop(pb)
	}
	return true
}

// queue_extra appends row, row i of the open list, to the queue as an
// extra anchored after item after, and returns its item. Its place in the
// order is left to the caller.
@(private = "file")
queue_extra :: proc(s: ^State, i: int, row: ^Row, after: int) -> int {
	pb := &s.playback
	item := queue_append(pb)
	queue_fill(pb, item, row, vmem.arena_allocator(&pb.arena))
	pb.items[item].row = fake_row_index(s, i)
	pb.items[item].after = after
	if pb.fake {
		pb.entries[item].id = -i64(pb.items[item].row + 1)
	}
	return item
}

// playback_stop stops the player and forgets the queue and Now Playing,
// as at start. The player and its settings stay.
playback_stop :: proc(s: ^State) {
	pb := &s.playback
	if pb.player != nil {
		audio.stop(pb.player)
	}
	source_clear(&pb.cur)
	source_clear(&pb.next)
	artwork_free(&pb.art)
	artwork_free(&pb.next_art)
	if pb.has_arena {
		vmem.arena_destroy(&pb.arena)
	}
	pb^ = {
		player          = pb.player,
		set_now_playing = pb.set_now_playing,
		set_controls    = pb.set_controls,
		controls_sent   = pb.controls_sent,
		capture         = pb.capture,
		window          = pb.window,
		null_output     = pb.null_output,
		volume_sent     = pb.volume_sent,
		serial          = pb.serial,
		queue_gen       = pb.queue_gen,
		save_key        = pb.save_key,
		index           = -1,
		// A fade the stop cut short leaves the player's volume down until
		// the stop has taken.
		sleep           = {restore = pb.sleep.restore || pb.sleep.fade_from != 0, fade_serial = pb.sleep.fade_serial},
	}
	if pb.set_now_playing != nil {
		none: platform.Now_Playing
		pb.set_now_playing(&none)
	}
	s.library.playing = -1
}

// start_item makes queue item i the current track, from sample at, and
// plays it unless paused is set.
@(private = "file")
start_item :: proc(s: ^State, i: int, at: i64 = 0, paused := false) {
	pb := &s.playback
	if i < 0 || i >= len(pb.entries) || pb.entries[i].id == 0 {
		return
	}
	pb.index = i
	pb.paused = paused
	pb.seek_id = 0
	pb.message = {}
	if next_failed(pb, i) {
		pb.next_failed = {}
	}
	// The preloaded next track: the player keeps its bytes.
	if pb.next.serial != 0 && pb.next.queue == pb.queue_gen && pb.next.item == i && pb.next.track == pb.entries[i].id {
		source_clear(&pb.cur)
		pb.cur = pb.next
		pb.next = {}
		pb.cur.at = at
		if pb.cur.resolved {
			audio.play(pb.player, source_of(pb, &pb.cur), at, paused)
		}
		artwork_free(&pb.art)
		pb.art = pb.next_art
		pb.next_art = {}
		if pb.art.serial != pb.cur.serial {
			request_artwork(s, &pb.cur)
		}
		return
	}
	source_clear(&pb.cur)
	source_clear(&pb.next)
	artwork_free(&pb.next_art)
	pb.serial += 1
	pb.cur = {serial = pb.serial, queue = pb.queue_gen, item = i, track = pb.entries[i].id, at = at}
	// Silence until the stream resolves, rather than more of the old track.
	if !pb.fake {
		audio.play(pb.player, {serial = pb.cur.serial}, at, paused)
	}
	resolve(s, &pb.cur)
}

// resolve asks for t's stream, or makes it a tone in the fake data.
@(private = "file")
resolve :: proc(s: ^State, t: ^Track_Source) {
	pb := &s.playback
	if pb.fake {
		t.resolved = true
		t.rate = 44100
		if t == &pb.cur {
			audio.play(pb.player, source_of(pb, t), t.at, pb.paused)
		} else {
			audio.set_next(pb.player, source_of(pb, t))
		}
		request_artwork(s, t)
		return
	}
	push_job(&s.data, {payload = Stream_Job{track = pb.entries[t.item].id, serial = t.serial}})
	request_artwork(s, t)
}

@(private = "file")
request_artwork :: proc(s: ^State, t: ^Track_Source) {
	pb := &s.playback
	if pb.fake {
		fake_artwork(pb, t)
		return
	}
	if pb.items[t.item].cover == "" {
		return
	}
	image := Image_Job{id = small(pb.items[t.item].cover), size = ARTWORK_SIZE, fetch = ARTWORK_SIZE}
	push_job(&s.data, {payload = Artwork_Job{serial = t.serial, image = image}}, PRIORITY_COVER)
}

// fake_artwork gives a fake track a small cover of its own colour, so Now
// Playing shows one without a server.
@(private = "file")
fake_artwork :: proc(pb: ^Playback, t: ^Track_Source) {
	SIDE :: 64
	pixels := ([^]u8)(libc.malloc(SIDE * SIDE * 4)) // freed as stb_image's are
	if pixels == nil {
		return
	}
	h := u32(t.track) * 2654435761
	for i in 0 ..< SIDE * SIDE {
		pixels[i * 4 + 0] = u8(h >> 8)
		pixels[i * 4 + 1] = u8(h >> 16)
		pixels[i * 4 + 2] = u8(i % SIDE * 4)
		pixels[i * 4 + 3] = 255
	}
	a := &pb.art if t == &pb.cur else &pb.next_art
	artwork_free(a)
	a^ = {pixels[:SIDE * SIDE * 4], SIDE, SIDE, t.serial}
}

// artwork_result takes an Artwork job's result.
artwork_result :: proc(s: ^State, res: ^Result, job: Artwork_Job) {
	pb := &s.playback
	a: ^Artwork
	switch job.serial {
	case 0:
		return
	case pb.cur.serial:
		a = &pb.art
	case pb.next.serial:
		a = &pb.next_art
	case:
		return
	}
	img, ok := &res.payload.(Image_Result)
	if !ok || img.pixels == nil {
		return
	}
	artwork_free(a)
	a^ = {take(&img.pixels), img.w, img.h, job.serial}
}

// stream_result takes a Stream job's result.
stream_result :: proc(s: ^State, res: ^Result, job: Stream_Job) {
	pb := &s.playback
	t: ^Track_Source
	switch job.serial {
	case pb.cur.serial:
		t = &pb.cur
	case pb.next.serial:
		t = &pb.next
	case:
		return // for a track no longer wanted
	}
	if _, failed := res.err.?; failed {
		title := pb.items[t.item].title
		if t == &pb.next {
			// Try it again when it's current, and say so then. Until then
			// the player's want_next stays up, and it isn't asked for again.
			pb.next_failed = {serial = pb.next.serial, queue = pb.next.queue, item = pb.next.item, track = pb.next.track}
			source_clear(&pb.next)
			return
		}
		if e, _ := res.err.?; e == .Lossy_Stream {
			// Every track comes like this for this login, so skipping on
			// would only fail through the queue.
			stream, _ := res.payload.(Stream_Result)
			pb.message = small(lossy_message(small_str(&stream.codec)))
			stop_current(pb)
			return
		}
		pb.message = small(fmt.tprintf("Couldn't play %s: %s", title, small_str(&res.message)))
		skip_failed(s)
		return
	}
	stream, _ := res.payload.(Stream_Result)
	info := stream.info
	mode := audio.queue_gain_mode(pb.entries, pb.order, t.item)
	t.rg = audio.Replay_Gain{info.track_gain, info.track_peak, info.album_gain, info.album_peak}
	heap := runtime.heap_allocator()
	source_forget_url(t)
	t.url = strings.clone(info.url, heap)
	if info.dash {
		t.segments = make([]audio.Segment, len(info.segments), heap)
		for seg, i in info.segments {
			t.segments[i] = {strings.clone(seg.url, heap), seg.start}
		}
		last := info.segments[len(info.segments) - 1]
		t.timescale = i64(info.timescale)
		t.dash_end = last.start + last.length
	}
	t.gain = audio.setting_gain(t.rg, s.settings.replay_gain, mode)
	// A restored position is in the rate it was saved at.
	if t.rate > 0 && info.sample_rate > 0 && t.rate != info.sample_rate {
		t.at = t.at * i64(info.sample_rate) / i64(t.rate)
	}
	t.rate = info.sample_rate
	t.resolved = true
	log.infof("app: track %d resolved: %s %s%s, %d-bit %d Hz, %s gain (%s) %.2f dB -> x%.3f", info.track_id, tidal.quality_name(info.quality), tidal.codec_name(info.codec), fmt.tprintf(" in DASH, %d segments", len(info.segments)) if info.dash else "", info.bit_depth, info.sample_rate, mode, s.settings.replay_gain, 20 * math.log10(f64(t.gain)), t.gain)
	if t == &pb.cur {
		audio.play(pb.player, source_of(pb, t), t.at, pb.paused)
	} else {
		audio.set_next(pb.player, source_of(pb, t))
	}
}

// playback_set_replay_gain changes how ReplayGain is applied. The playing
// track keeps its gain: its next seconds are already in the player's ring
// at it, and changing it there would step the level. The next track gets
// the new one, also when it's already resolved and waiting.
playback_set_replay_gain :: proc(s: ^State, g: audio.Gain_Setting) {
	pb := &s.playback
	s.settings.replay_gain = g
	settings_queue(&s.data, settings_to_save(s))
	t := &pb.next
	if t.serial == 0 || !t.resolved || pb.fake {
		return
	}
	t.gain = audio.setting_gain(t.rg, g, audio.queue_gain_mode(pb.entries, pb.order, t.item))
	if pb.player != nil {
		audio.set_next_gain(pb.player, t.serial, t.gain)
	}
}

// lossy_message is the player bar's line when TIDAL sent a lossy stream
// in place of FLAC.
lossy_message :: proc(codec: string) -> string {
	if codec == "" || strings.has_prefix(codec, "MP4A") || strings.has_prefix(codec, "AAC") {
		return "TIDAL sent AAC for this login. Log in with TIDAL again for lossless."
	}
	return fmt.tprintf("TIDAL sent %s for this login, which TIDALfast doesn't play. Log in with TIDAL again for lossless.", codec)
}

// skip_failed moves past a track that can't play.
@(private = "file")
skip_failed :: proc(s: ^State) {
	pb := &s.playback
	// Not round again on repeat: a queue where nothing plays would go on
	// asking for streams.
	n := audio.queue_next(pb.entries, pb.order, pb.index)
	if n < 0 {
		stop_current(pb)
		return
	}
	msg := pb.message
	start_item(s, n, paused = pb.paused)
	pb.message = msg
}

// stop_current drops the current track after a failure that ends playback.
// The player was playing its placeholder's silence, so it stops too.
@(private = "file")
stop_current :: proc(pb: ^Playback) {
	source_clear(&pb.cur)
	pb.paused = true
	audio.stop(pb.player)
}

playback_next :: proc(s: ^State) {
	pb := &s.playback
	if n := audio.queue_after(pb.entries, pb.order, pb.index, s.settings.repeat, user = true); n >= 0 {
		start_item(s, n)
	}
}

playback_previous :: proc(s: ^State) {
	pb := &s.playback
	if pb.index < 0 {
		return
	}
	i := audio.queue_previous_action(pb.entries, pb.order, pb.index, playback_position(s))
	if i == pb.index {
		playback_seek(s, 0)
	} else {
		start_item(s, i)
	}
}

// playback_set_shuffle turns shuffle on or off. Turning it on shuffles
// what's after the current track; off goes back to list order from it.
playback_set_shuffle :: proc(s: ^State, on: bool) {
	pb := &s.playback
	s.settings.shuffle = on
	settings_queue(&s.data, settings_to_save(s))
	if pb.index >= 0 {
		queue_reorder(s, {pb.index})
		next_drop(pb)
	}
}

playback_set_repeat :: proc(s: ^State, repeat: audio.Repeat) {
	pb := &s.playback
	s.settings.repeat = repeat
	settings_queue(&s.data, settings_to_save(s))
	next_drop(pb)
}

// repeat_after is the repeat mode the repeat button goes to from r.
repeat_after :: proc(r: audio.Repeat) -> audio.Repeat {
	return audio.Repeat((int(r) + 1) % len(audio.Repeat))
}

// next_drop forgets the preloaded next track after what comes next has
// changed. The player then asks for the next one again.
@(private = "file")
next_drop :: proc(pb: ^Playback) {
	if pb.next.serial == 0 || pb.status.serial == pb.next.serial {
		return
	}
	source_clear(&pb.next)
	artwork_free(&pb.next_art)
	audio.set_next(pb.player, {})
}

// sleep_hold_next keeps the next track from playing while a sleep timer
// waits for the end of the current one. A preloaded next track the decoder
// hasn't started is dropped. One whose first frames the decoder has
// already put in the ring after the current track's last, which happens in
// a track's last few seconds, is pulled back with a seek to where the
// current track is, after which it is dropped too.
sleep_hold_next :: proc(s: ^State) {
	pb := &s.playback
	st := &pb.status
	if !pb.sleep.end_of_track || pb.next.serial == 0 || pb.cur.serial == 0 || st.serial != pb.cur.serial {
		return
	}
	if st.next_serial == pb.next.serial || st.want_next {
		next_drop(pb)
	} else if st.next_serial == 0 && pb.seek_id == 0 && pb.cur.resolved {
		playback_seek(s, playback_position(s))
	}
}

// playback_toggle plays when nothing plays (idle, paused or at the end of
// the queue) and pauses otherwise.
playback_toggle :: proc(s: ^State) {
	playback_set_paused(s, playback_playing(s))
}

// playback_set_paused pauses or plays. Playing with nothing loaded starts
// the selected row, or the first; playing at the end of the queue starts
// it again from the top.
playback_set_paused :: proc(s: ^State, paused: bool) {
	pb := &s.playback
	if !paused && (pb.index < 0 || pb.cur.serial == 0) {
		sel := s.library.selected
		playback_play_row(s, sel if sel >= 0 else 0)
		return
	}
	if !paused && pb.status.state == .Ended && pb.status.serial == pb.cur.serial {
		if first := audio.queue_next(pb.entries, pb.order, -1); first >= 0 {
			start_item(s, first)
		}
		return
	}
	if pb.index < 0 {
		return
	}
	pb.paused = paused
	audio.set_paused(pb.player, paused)
}

playback_seek :: proc(s: ^State, seconds: f64) {
	pb := &s.playback
	if pb.cur.serial == 0 {
		return
	}
	at := max(seconds, 0)
	rate := pb.cur.rate if pb.cur.rate > 0 else 44100
	if pb.status.serial == pb.cur.serial && pb.status.rate > 0 {
		rate = pb.status.rate
	}
	sample := i64(at * f64(rate))
	if !pb.cur.resolved {
		pb.cur.at = sample
		// The silent placeholder holds the position status reports.
		if !pb.fake {
			audio.play(pb.player, {serial = pb.cur.serial}, sample, pb.paused)
		}
		return
	}
	if pb.status.state == .Ended && pb.status.serial == pb.cur.serial {
		audio.play(pb.player, source_of(pb, &pb.cur), sample, pb.paused)
		return
	}
	pb.seek_id = audio.seek(pb.player, pb.cur.serial, sample)
	pb.seek_serial = pb.cur.serial
	pb.seek_sample = sample
	pb.seek_seconds = at
}

// playback_seek_by moves the current track's position by seconds, kept
// between its start and its end. With nothing loaded it does nothing.
playback_seek_by :: proc(s: ^State, seconds: f64) {
	if s.playback.cur.serial == 0 {
		return
	}
	at := max(playback_position(s) + seconds, 0)
	if d := playback_duration(s); d > 0 {
		at = min(at, d)
	}
	playback_seek(s, at)
}

// playback_set_volume sets the volume, unmuting at it, and saves it when
// save is set, as at the end of a drag.
playback_set_volume :: proc(s: ^State, v: f32, save: bool) {
	s.settings.volume = v
	s.settings.muted = false
	volume_send(s)
	if save {
		volume_save(s)
	}
}

// playback_toggle_mute mutes, or unmutes at the level from before. At a
// level of 0 it unmutes at the default, so the button always brings the
// sound back.
playback_toggle_mute :: proc(s: ^State) {
	if volume_silent(s.settings) {
		s.settings.muted = false
		if s.settings.volume == 0 {
			s.settings.volume = VOLUME_DEFAULT
		}
	} else {
		s.settings.muted = true
	}
	volume_send(s)
	settings_queue(&s.data, settings_to_save(s))
}

// volume_heard is the volume the player plays at: none while muted.
volume_heard :: proc(st: Settings) -> f32 {
	return 0 if st.muted else st.volume
}

// volume_silent says whether the speaker button shows the sound off, and
// unmutes when clicked.
volume_silent :: proc(st: Settings) -> bool {
	return st.muted || st.volume == 0
}

@(private = "file")
volume_send :: proc(s: ^State) {
	pb := &s.playback
	if v := volume_heard(s.settings); pb.player != nil && v != pb.volume_sent {
		audio.set_volume(pb.player, v)
		pb.volume_sent = v
	}
}

// volume_save saves the volume the slider or the wheel set, over
// TIDALFAST_VOLUME's.
volume_save :: proc(s: ^State, now := false) {
	s.playback.volume_save_at = 0
	s.volume_before_override = nil
	settings_queue(&s.data, s.settings, now)
}

// playback_position is the current track's position in seconds, as the
// player bar shows it: a pending seek or drag shows its target at once.
playback_position :: proc(s: ^State) -> f64 {
	pb := &s.playback
	switch {
	case pb.dragging:
		return pb.drag_seconds
	case pb.seek_id != 0 && pb.seek_serial == pb.cur.serial:
		return pb.seek_seconds
	case pb.status.serial == pb.cur.serial && (pb.status.rate > 0 || pb.cur.rate > 0):
		// The player learns the rate from the file a moment after the first
		// samples are in; until then TIDAL's is as good.
		return f64(pb.status.sample) / f64(pb.status.rate if pb.status.rate > 0 else pb.cur.rate)
	case pb.cur.rate > 0:
		return f64(pb.cur.at) / f64(pb.cur.rate)
	}
	return 0
}

// playback_duration is the current track's length in seconds: the file's
// once the player knows it, else what TIDAL said.
playback_duration :: proc(s: ^State) -> f64 {
	pb := &s.playback
	if pb.status.serial == pb.cur.serial && pb.status.rate > 0 && pb.status.total > 0 {
		return f64(pb.status.total) / f64(pb.status.rate)
	}
	if pb.index >= 0 {
		return FAKE_TONE_SECONDS if pb.fake else f64(pb.items[pb.index].seconds)
	}
	return 0
}

playback_item :: proc(s: ^State) -> ^Queue_Item {
	pb := &s.playback
	if pb.index < 0 || pb.index >= len(pb.items) {
		return nil
	}
	return &pb.items[pb.index]
}

playback_playing :: proc(s: ^State) -> bool {
	pb := &s.playback
	ended := pb.status.state == .Ended && pb.status.serial == pb.cur.serial
	return pb.index >= 0 && !pb.paused && !ended
}

// playback_media runs the media commands among events.
playback_media :: proc(s: ^State, events: []platform.Event) {
	for e in events {
		if e.kind != .Media {
			continue
		}
		switch e.media {
		case .None:
		case .Play:
			playback_set_paused(s, false)
		case .Pause:
			playback_set_paused(s, true)
		case .Toggle:
			playback_toggle(s)
		case .Next:
			playback_next(s)
		case .Previous:
			playback_previous(s)
		case .Seek:
			playback_seek(s, f64(e.dx))
		case .Volume:
			// Saved at once, as when the slider is let go.
			if !math.is_nan(e.dx) {
				playback_set_volume(s, clamp(e.dx, 0, 1), true)
			}
		case .Shuffle:
			if on := e.dx != 0; on != s.settings.shuffle {
				playback_set_shuffle(s, on)
			}
		case .Repeat:
			REPEATS := [platform.Player_Repeat]audio.Repeat {
				.Off = .Off,
				.All = .All,
				.One = .One,
			}
			if e.dx >= 0 && e.dx <= f32(max(platform.Player_Repeat)) {
				if r := REPEATS[platform.Player_Repeat(e.dx)]; r != s.settings.repeat {
					playback_set_repeat(s, r)
				}
			}
		}
	}
}

// playback_observe takes in the player's status: it keeps the device
// change on disk, settles seeks, and moves the queue on.
playback_observe :: proc(s: ^State, status: audio.Status) {
	pb := &s.playback
	pb.status = status
	st := &pb.status
	if st.device.rate > 0 {
		pb.output_seen = st.device
	}
	// Keep what bit-perfect output changed on the device on disk while it
	// lasts, so a start after a crash can put it back.
	if st.change != s.settings.device {
		s.settings.device = st.change
		settings_queue(&s.data, settings_to_save(s))
	}
	if pb.seek_id != 0 && (pb.seek_serial != pb.cur.serial || (st.serial == pb.cur.serial && st.seek_id >= pb.seek_id)) {
		pb.seek_id = 0
	}

	// The player went on to the preloaded track.
	if pb.next.serial != 0 && st.serial == pb.next.serial {
		source_clear(&pb.cur)
		pb.cur = pb.next
		pb.next = {}
		pb.index = pb.cur.item
		pb.seek_id = 0
		artwork_free(&pb.art)
		pb.art = pb.next_art
		pb.next_art = {}
		if pb.art.serial != pb.cur.serial {
			request_artwork(s, &pb.cur)
		}
		// A sleep timer for the end of the track that couldn't hold the
		// next one back, set as the track changed: stop it at its start.
		if pb.sleep.end_of_track {
			playback_set_paused(s, true)
			playback_seek(s, 0)
			sleep_fired(s, .Slept)
		}
	}
	sleep_hold_next(s)
	// It wants the track after the current one. A sleep timer for the end
	// of the track wants none, so the track ends instead of going on.
	if st.want_next && pb.next.serial == 0 && st.serial == pb.cur.serial && !pb.sleep.end_of_track {
		if n := audio.queue_after(pb.entries, pb.order, pb.index, s.settings.repeat, user = false); n >= 0 && !next_failed(pb, n) {
			pb.serial += 1
			pb.next = {serial = pb.serial, queue = pb.queue_gen, item = n, track = pb.entries[n].id}
			resolve(s, &pb.next)
		}
	}
	// The queue ran out, or the next track wasn't ready in time.
	// With a sleep timer for the end of the track, the next one waits at
	// its start, paused.
	if st.state == .Ended && st.serial == pb.cur.serial && st.serial != 0 {
		n := audio.queue_after(pb.entries, pb.order, pb.index, s.settings.repeat, user = false)
		if n >= 0 && pb.next.serial == 0 {
			start_item(s, n, paused = pb.sleep.end_of_track)
			if pb.sleep.end_of_track {
				sleep_fired(s, .Slept)
			}
		} else if n < 0 && pb.sleep.end_of_track {
			sleep_fired(s, .Slept_At_End)
		}
	}
	if e := st.error; e.serial != 0 && e.serial == pb.cur.serial && e.serial != pb.error_seen {
		pb.error_seen = e.serial
		expired := e.http_status >= 400 && e.http_status < 500
		if expired && !pb.cur.retried {
			// Stream URLs expire. Get a new one and carry on from here.
			pb.cur.retried = true
			pb.cur.resolved = false
			pb.cur.at = st.sample if st.serial == pb.cur.serial else pb.cur.at
			source_forget_url(&pb.cur)
			pb.serial += 1
			pb.cur.serial = pb.serial
			resolve(s, &pb.cur)
		} else {
			pb.message = small(fmt.tprintf("Couldn't play %s: %s", pb.items[pb.cur.item].title, audio.error_text(&e)))
		}
	}
}

// playback_update runs once a frame after data_update: media commands,
// the player's status, the queue moving on, and Now Playing.
playback_update :: proc(s: ^State, events: []platform.Event) {
	pb := &s.playback
	if pb.player == nil {
		return
	}
	playback_media(s, events)
	playback_observe(s, audio.status(pb.player))

	// Keep the queue in step with its list while pages arrive, whether or
	// not the list is still open. A page that came back short moves the
	// rows after it up, and the queue's tracks with them.
	d := &s.data
	if v := queue_list(d); !pb.fake && pb.index >= 0 && v != nil && (pb.loaded != v.loaded_rows || pb.moved != v.moved) {
		index, old_n := pb.index, pb.list_n
		played := order_played(s)
		queue_follow(s, v)
		pb.index = queue_place(pb, {index, pb.cur.track}, old_n)
		pb.cur.item = pb.index
		if pb.next.serial != 0 {
			pb.next.item = queue_place(pb, {pb.next.item, pb.next.track}, old_n)
		}
		if pb.next_failed.serial != 0 {
			pb.next_failed.item = queue_place(pb, {pb.next_failed.item, pb.next_failed.track}, old_n)
		}
		head := make([]int, len(played), context.temp_allocator)
		for p, i in played {
			head[i] = queue_place(pb, p, old_n)
		}
		queue_reorder(s, head)
	}
	if q := &d.queued; q.source != .None && (q.gen != d.queue_view || !view_loading(q) && q.in_flight == 0 && (pb.index < 0 || pb.loaded == q.loaded_rows)) {
		queued_drop(d)
	}
	s.library.playing = playing_row(s)
	update_now_playing(s)
	update_controls(s)
	queue_save(s)
}

@(private = "file")
Queue_Place :: struct {
	item:  int,
	track: i64,
}

// order_played is the queue's items in play order up to the current one,
// then the next if it's chosen, by track and item. When pages move items,
// the order keeps those and shuffles the rest again.
@(private = "file")
order_played :: proc(s: ^State) -> []Queue_Place {
	if !s.settings.shuffle {
		return nil
	}
	pb := &s.playback
	out := make([dynamic]Queue_Place, context.temp_allocator)
	for i in pb.order {
		append(&out, Queue_Place{i, pb.entries[i].id})
		if i == pb.index {
			break
		}
	}
	if pb.next.serial != 0 {
		append(&out, Queue_Place{pb.next.item, pb.next.track})
	}
	return out[:]
}

// next_failed says whether queue item i is the next track that failed to
// resolve in this queue.
@(private = "file")
next_failed :: proc(pb: ^Playback, i: int) -> bool {
	f := &pb.next_failed
	return f.serial != 0 && f.queue == pb.queue_gen && f.item == i && i < len(pb.entries) && f.track == pb.entries[i].id
}

// queue_find is the list's item holding track: at, if it does, or else the
// nearest one before it, where a gap closing in the list moved it. It's
// never an extra.
@(private = "file")
queue_find :: proc(pb: ^Playback, track: i64, at: int) -> int {
	if at >= 0 && at < pb.list_n && pb.entries[at].id == track {
		return at
	}
	for i := min(at, pb.list_n - 1); i >= 0; i -= 1 {
		if pb.entries[i].id == track {
			return i
		}
	}
	return min(at, pb.list_n - 1)
}

// list_key names the open list: its kind and TIDAL id, or the search's
// query. A list opened again gets the same key, a different one another.
list_key :: proc(s: ^State) -> u64 {
	if s.data.fake {
		sr := &s.search
		return fake_list_key(sr.fake_source, s.library.playlist, small_str(&sr.fake_title))
	}
	v := &s.data.view
	if v.source == .None {
		return 0
	}
	return source_list_key(v.source, small_str(&v.id))
}

// source_list_key is list_key for a TIDAL list. Queue files keep it, so it
// mustn't change.
source_list_key :: proc(source: Source, id: string) -> u64 {
	h := fnv(FNV_BASIS, u8(source))
	for b in transmute([]u8)id {
		h = fnv(h, b)
	}
	return h
}

// fake_list_key is list_key for the fake data: the playlist while no fake
// list is browsed, the browsed list's title otherwise.
fake_list_key :: proc(source: Source, playlist: int, title: string) -> u64 {
	h := fnv(FNV_BASIS, u8(source))
	if source != .None {
		for b in transmute([]u8)title {
			h = fnv(h, b)
		}
		return h
	}
	return fnv(fnv(h, u8(playlist)), u8(playlist >> 8))
}

FNV_BASIS :: 14695981039346656037

@(private = "file")
fnv :: proc(h: u64, b: u8) -> u64 {
	return (h ~ u64(b)) * 1099511628211
}

// sidebar_queued says whether the play queue came from sidebar entry i.
sidebar_queued :: proc(s: ^State, i: int) -> bool {
	pb := &s.playback
	if pb.index < 0 || pb.index >= len(pb.entries) {
		return false
	}
	key: u64
	switch {
	case s.data.fake:
		key = fake_list_key(.None, i, "")
	case i == 0:
		key = source_list_key(.Liked, "")
	case i - 1 < len(s.data.sidebar.items):
		key = source_list_key(.Playlist, s.data.sidebar.items[i - 1].id)
	case:
		return false
	}
	return pb.list_key == key
}

// playing_row is the row of the open list that plays, or -1. Only the list
// the queue came from has one, so the same track in another list isn't
// lit. It's the queue's index while that row holds the track. After the
// list was opened again its rows may differ, so it's the first row with
// the track's id, looked for once each time the rows change. An extra
// isn't one of the list's rows, so none is lit while one plays.
playing_row :: proc(s: ^State) -> int {
	pb := &s.playback
	if pb.index < 0 || pb.index >= pb.list_n || pb.list_key != list_key(s) {
		return -1
	}
	if pb.fake {
		return pb.index
	}
	track := pb.entries[pb.index].id
	if row := view_row(s, pb.index); row != nil && row.id == track {
		return pb.index
	}
	v := &s.data.view
	if pb.found_track != track || pb.found_gen != v.gen || pb.found_loaded != v.loaded_rows || pb.found_count != v.count {
		pb.found_track, pb.found_gen, pb.found_loaded, pb.found_count = track, v.gen, v.loaded_rows, v.count
		pb.found_row = -1
		for i in 0 ..< min(v.count, len(v.loaded)) {
			if v.loaded[i] && v.rows[i].id == track {
				pb.found_row = i
				break
			}
		}
	}
	return pb.found_row
}

// update_now_playing tells the system what plays when the track, its
// state, its length, a finished seek or the artwork changed. The system
// moves the elapsed time along by itself from the rate.
@(private = "file")
update_now_playing :: proc(s: ^State) {
	pb := &s.playback
	if pb.set_now_playing == nil {
		return
	}
	item := playback_item(s)
	state := platform.Now_Playing_State.Stopped
	if item != nil {
		state = .Playing if playback_playing(s) else .Paused
	}
	duration := playback_duration(s)
	art := pb.art.pixels if pb.art.serial == pb.cur.serial else nil
	// A seek sends the target when asked for and the real position once
	// the audio is there.
	key: u64 = 14695981039346656037
	for v in ([]u64{pb.cur.serial, u64(state), u64(pb.seek_id), u64(pb.status.seek_id), u64(duration * 10), u64(len(art) > 0)}) {
		key = (key ~ v) * 1099511628211
	}
	if item == nil {
		key = 0
	}
	if key == pb.np_key {
		return
	}
	pb.np_key = key
	if item == nil {
		none: platform.Now_Playing
		pb.set_now_playing(&none)
		return
	}
	np := platform.Now_Playing {
		title       = strings.clone_to_cstring(item.title, context.temp_allocator),
		artist      = strings.clone_to_cstring(item.artist, context.temp_allocator),
		album       = strings.clone_to_cstring(item.album, context.temp_allocator),
		duration    = duration,
		elapsed     = playback_position(s),
		state       = state,
		artwork_key = pb.art.serial if len(art) > 0 else 0,
	}
	if len(art) > 0 {
		np.artwork = raw_data(art)
		np.artwork_width = u32(pb.art.w)
		np.artwork_height = u32(pb.art.h)
	}
	pb.set_now_playing(&np)
}

// update_controls tells the shell the player bar's volume, shuffle and
// repeat when they change, so the desktop's media controls show them.
@(private = "file")
update_controls :: proc(s: ^State) {
	pb := &s.playback
	if pb.set_controls == nil {
		return
	}
	REPEATS := [audio.Repeat]platform.Player_Repeat {
		.Off = .Off,
		.All = .All,
		.One = .One,
	}
	c := platform.Player_Controls {
		volume  = f64(volume_heard(s.settings)),
		shuffle = b32(s.settings.shuffle),
		repeat  = REPEATS[s.settings.repeat],
	}
	if sent, ok := pb.controls_sent.?; ok && sent == c {
		return
	}
	pb.controls_sent = c
	pb.set_controls(&c)
}

// queue_save writes the queue's file when its rows change, and its
// position file when only its place does: its current track, pause, a
// finished seek or the end. The running position isn't one of those;
// playback_shutdown writes the last one. A write still queued is dropped
// for the newer one. A queue that stopped is deleted, so it doesn't come
// back.
@(private = "file")
queue_save :: proc(s: ^State) {
	pb := &s.playback
	if pb.fake {
		return
	}
	d := &s.data
	if pb.index < 0 {
		if pb.save_key != 0 {
			pb.save_key, pb.place_key = 0, 0
			disk_drop_queued(d, {.Write_Queue, .Write_Queue_Position})
			disk_push(d, {op = .Delete_Queue})
		}
		return
	}
	ended := pb.status.state == .Ended && pb.status.serial == pb.cur.serial
	count, loaded := u64(len(pb.entries)), u64(pb.loaded)
	if v := queue_list(d); v != nil && view_filling(v) {
		count, loaded = 0, floor_pow2(loaded)
	}
	rows := fnv_u64({u64(pb.queue_gen), count, loaded, u64(len(pb.items) - pb.list_n)})
	place := fnv_u64({u64(pb.index), u64(pb.cur.track), u64(pb.paused), u64(pb.status.seek_id), u64(ended)})
	if rows != pb.save_key {
		pb.save_key, pb.place_key = rows, place
		disk_drop_queued(d, {.Write_Queue, .Write_Queue_Position})
		disk_push(d, {op = .Write_Queue, blob = queue_file(pb, runtime.heap_allocator())})
	} else if place != pb.place_key {
		pb.place_key = place
		disk_drop_queued(d, {.Write_Queue_Position})
		h := queue_head(pb)
		p := Queue_Position{magic = QUEUE_POSITION_MAGIC, key = h.key, index = h.index, sample = h.sample, rate = h.rate}
		disk_push(d, {op = .Write_Queue_Position, blob = slice.clone(mem.ptr_to_bytes(&p), runtime.heap_allocator())})
	}
}

@(private = "file")
fnv_u64 :: proc(values: []u64) -> u64 {
	key: u64 = 14695981039346656037
	for v in values {
		key = (key ~ v) * 1099511628211
	}
	return key
}

@(private = "file")
floor_pow2 :: proc(n: u64) -> u64 {
	return 0 if n == 0 else 1 << (63 - intrinsics.count_leading_zeros(n))
}

// queue_file is the queue as its file, at the current position, with a new
// key so no older position file goes with it.
@(private = "file")
queue_file :: proc(pb: ^Playback, allocator: runtime.Allocator) -> []u8 {
	pb.file_key = rand.uint64() | 1
	head := queue_head(pb)
	rows := make([]Row, len(pb.items), context.temp_allocator)
	for &it, i in pb.items {
		e := pb.entries[i]
		rows[i] = {
			title    = it.title,
			artist   = it.artist,
			album    = it.album,
			cover    = it.cover,
			seconds  = it.seconds,
			id       = e.id,
			album_id = it.album_id,
			artists  = it.artists,
			track    = e.track_num,
		}
	}
	after := make([]i64, len(pb.items) - pb.list_n, context.temp_allocator)
	for &a, j in after {
		a = i64(pb.items[pb.list_n + j].after)
	}
	return queue_encode(head, rows, allocator, after)
}

// queue_head is the queue's file header, at the current position.
@(private = "file")
queue_head :: proc(pb: ^Playback) -> Queue_Header {
	st := &pb.status
	head := Queue_Header {
		index    = i64(pb.index),
		sample   = pb.cur.at,
		rate     = i64(pb.cur.rate),
		list_key = pb.list_key,
		key      = pb.file_key,
	}
	if st.serial != 0 && st.serial == pb.cur.serial {
		head.sample = st.sample
		if st.rate > 0 {
			head.rate = i64(st.rate)
		}
		if st.state == .Ended {
			head.sample = 0
		}
	}
	if pb.seek_id != 0 && pb.seek_serial == pb.cur.serial {
		head.sample = pb.seek_sample
	}
	return head
}

// playback_restore takes the queue's file read at sign-in: the queue comes
// back with its track paused where it was, its stream resolving so play
// starts at once.
playback_restore :: proc(s: ^State, file: Queue_File_Result) {
	pb := &s.playback
	if pb.index >= 0 || s.data.fake || pb.player == nil || len(file.rows) == 0 {
		return
	}
	head := file.header
	a := queue_reset(pb, len(file.rows))
	for &row, i in file.rows {
		queue_fill(pb, i, &row, a)
	}
	// queue_decode checked each anchor is an earlier row.
	pb.list_n = len(file.rows) - len(file.after)
	for after, j in file.after {
		pb.items[pb.list_n + j].after = int(after)
	}
	pb.fake = false
	pb.list_key = head.list_key
	// A gen no view is given, so playback_update never takes the queue
	// for a snapshot of the open list.
	s.data.queue_view = view_gen(&s.data)
	pb.loaded = pb.list_n
	pb.queue_gen += 1
	i := int(head.index)
	at := head.sample
	if i < 0 || i >= len(pb.entries) || pb.entries[i].id == 0 {
		i = audio.queue_next(pb.entries, pb.order, clamp(i, 0, len(pb.entries)) - 1)
		at = 0
	}
	if i < 0 {
		queue_reset(pb, 0)
		return
	}
	queue_reorder(s, {i})
	start_item(s, i, max(at, 0), paused = true)
	pb.cur.rate = int(head.rate)
	log.infof("app: resumed the queue at item %d of %d, %.1f s in", i, len(pb.entries), playback_position(s))
}
