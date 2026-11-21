package app

// The list cache's files (see lists.odin): one per track list, and one for
// the sidebar. A file is a File_Header, then fixed-size records, then the
// text the records' strings point into. Loading reads the whole file into
// the list's arena and slices the strings out of it, so nothing is copied.
//
// The layout is this machine's: little-endian, Odin's struct alignment.
// FILE_FORMAT goes up when it changes, and a file of another format is
// deleted when it's read. Files hold metadata only: names, ids, image ids
// and counts, never tokens or URLs.

import "base:runtime"
import "core:hash"
import "core:mem"
import "core:os"
import "core:slice"

FILE_MAGIC :: 0x434c_4654 // "TFLC"
FILE_FORMAT :: 3

File_Str :: struct {
	off, len: u32,
}

File_Header :: struct {
	magic:   u32,
	format:  u32,
	source:  Source, // .None for the sidebar
	_:       [3]u8,
	count:   u32, // records
	text:    u32, // bytes of text after the records
	_:       u32,
	fetched: i64, // unix seconds
	version: List_Version, // the sidebar's: Liked Songs'
	hint:    i64, // the list's length as TIDAL counts it
	id:      File_Str,
	sum:     u64, // FNV-1a of everything after the header
}

// File_Row is a Row on disk. Its artists are their Artist_Refs' bytes,
// in the text.
File_Row :: struct {
	text:     [6]File_Str, // title, artist, album, added, duration, cover
	artists:  File_Str,
	seconds:  i32,
	track:    i32,
	id:       i64,
	album_id: i64,
}

// File_Item is a Sidebar_Item on disk.
File_Item :: struct {
	text:    [3]File_Str, // id, name, image
	_:       u32,
	tracks:  i64,
	updated: i64,
}

File_Error :: enum u8 {
	None,
	Short, // shorter than its header and records say
	Magic,
	Format, // another FILE_FORMAT
	Other, // another list's file
	Damaged, // its sum or a string's bounds are wrong, or it has more than ROWS_MAX rows
	Memory, // no memory for its rows, which says nothing about the file
}

@(private = "file")
File_Writer :: struct {
	whole:  []u8, // the prefix, then buf
	buf:    []u8,
	base:   int, // where the text starts
	text:   int, // where the next string goes
}

@(private = "file")
put :: proc(w: ^File_Writer, s: string) -> File_Str {
	at := w.text
	copy(w.buf[at:], s)
	w.text += len(s)
	return {u32(at - w.base), u32(len(s))}
}

// writer_make starts a file, after prefix bytes w.buf leaves out.
@(private = "file")
writer_make :: proc(source: Source, id: string, count, text: int, allocator: runtime.Allocator, prefix := 0) -> (w: File_Writer, h: ^File_Header) {
	rec := size_of(File_Row) if source != .None else size_of(File_Item)
	w.whole = make([]u8, prefix + size_of(File_Header) + count * rec + text + len(id), allocator)
	w.buf = w.whole[prefix:]
	h = (^File_Header)(raw_data(w.buf))
	h^ = {
		magic  = FILE_MAGIC,
		format = FILE_FORMAT,
		source = source,
		count  = u32(count),
		text   = u32(text + len(id)),
	}
	w.base = size_of(File_Header) + count * rec
	w.text = w.base
	h.id = put(&w, id)
	return
}

// file_seal fills in a list or sidebar file's sum, which the encode procs
// leave out.
file_seal :: proc(file: []u8) {
	h := (^File_Header)(raw_data(file))
	h.sum = hash.fnv64a(file[size_of(File_Header):])
}

// list_encode is a done list as a file, without its sum (see file_seal).
list_encode :: proc(v: ^Track_View, allocator: runtime.Allocator) -> []u8 {
	n := min(v.count, len(v.rows))
	return rows_encode(v.source, small_str(&v.id), v.rows[:n], v.fetched, v.version, i64(v.hint), allocator)
}

// rows_encode is rows as a list file, after prefix bytes left zero.
rows_encode :: proc(source: Source, id: string, rows: []Row, fetched: i64, version: List_Version, hint: i64, allocator: runtime.Allocator, prefix := 0) -> []u8 {
	text := 0
	for &r in rows {
		text += len(r.title) + len(r.artist) + len(r.album) + len(r.added) + len(r.duration) + len(r.cover)
		text += len(r.artists) * size_of(Artist_Ref)
	}
	w, h := writer_make(source, id, len(rows), text, allocator, prefix)
	h.fetched = fetched
	h.version = version
	h.hint = hint
	recs := ([^]File_Row)(raw_data(w.buf[size_of(File_Header):]))[:len(rows)]
	for &r, i in rows {
		recs[i] = {
			text     = {put(&w, r.title), put(&w, r.artist), put(&w, r.album), put(&w, r.added), put(&w, r.duration), put(&w, r.cover)},
			artists  = put(&w, string(slice.to_bytes(r.artists))),
			seconds  = i32(r.seconds),
			track    = i32(r.track),
			id       = r.id,
			album_id = r.album_id,
		}
	}
	return w.whole
}

// sidebar_encode is the sidebar as a file, without its sum.
sidebar_encode :: proc(sb: ^Sidebar, fetched: i64, allocator: runtime.Allocator) -> []u8 {
	text := 0
	for it in sb.items {
		text += len(it.id) + len(it.name) + len(it.image)
	}
	w, h := writer_make(.None, "", len(sb.items), text, allocator)
	h.fetched = fetched
	h.version = {count = i64(sb.liked_count), newest = sb.liked_newest}
	items := ([^]File_Item)(raw_data(w.buf[size_of(File_Header):]))[:len(sb.items)]
	for it, i in sb.items {
		items[i] = {
			text    = {put(&w, it.id), put(&w, it.name), put(&w, it.image)},
			tracks  = i64(it.tracks),
			updated = it.updated,
		}
	}
	return w.whole
}

// file_check validates a file read whole into data, which must be 8-byte
// aligned, for the list source and id (.None for the sidebar). It returns
// the header, the records and the text.
file_check :: proc(data: []u8, source: Source, id: string) -> (h: ^File_Header, records: rawptr, text: []u8, err: File_Error) {
	if len(data) < size_of(File_Header) {
		return nil, nil, nil, .Short
	}
	h = (^File_Header)(raw_data(data))
	if h.magic != FILE_MAGIC {
		return nil, nil, nil, .Magic
	}
	if h.format != FILE_FORMAT {
		return nil, nil, nil, .Format
	}
	if h.source != source {
		return nil, nil, nil, .Other
	}
	rec := size_of(File_Row) if source != .None else size_of(File_Item)
	text_at := size_of(File_Header) + int(h.count) * rec
	if len(data) != text_at + int(h.text) {
		return nil, nil, nil, .Short
	}
	if hash.fnv64a(data[size_of(File_Header):]) != h.sum {
		return nil, nil, nil, .Damaged
	}
	text = data[text_at:]
	file_id, ok := file_str(text, h.id)
	if !ok {
		return nil, nil, nil, .Damaged
	}
	if file_id != id {
		return nil, nil, nil, .Other
	}
	return h, raw_data(data[size_of(File_Header):]), text, .None
}

@(private = "file")
file_str :: proc(text: []u8, s: File_Str) -> (string, bool) {
	if u64(s.off) + u64(s.len) > u64(len(text)) {
		return "", false
	}
	return string(text[s.off:][:s.len]), true
}

// file_artists copies a row's artists out of the text, which isn't aligned
// for them, and checks that each name lies inside an artist string of
// artist_len bytes.
@(private = "file")
file_artists :: proc(text: []u8, s: File_Str, artist_len: int, allocator: runtime.Allocator) -> ([]Artist_Ref, bool) {
	b, ok := file_str(text, s)
	if !ok || len(b) % size_of(Artist_Ref) != 0 {
		return nil, false
	}
	if len(b) == 0 {
		return nil, true
	}
	refs := make([]Artist_Ref, len(b) / size_of(Artist_Ref), allocator)
	copy(slice.to_bytes(refs), b)
	for a in refs {
		if a.start < 0 || a.start > a.end || int(a.end) > artist_len {
			return nil, false
		}
	}
	return refs, true
}

// list_decode turns a list file read into the list's arena into rows whose
// strings point into it.
list_decode :: proc(data: []u8, source: Source, id: string, allocator: runtime.Allocator) -> (h: ^File_Header, rows: []Row, err: File_Error) {
	recs: rawptr
	text: []u8
	h, recs, text, err = file_check(data, source, id)
	if err != .None {
		return
	}
	rows = make([]Row, h.count, allocator)
	if err = list_rows(recs, text, rows, allocator); err != .None {
		return nil, nil, err
	}
	return
}

// list_decode_into is list_decode with the rows in a list's space (see
// space_rows) instead of the arena, so the list can take them as they are.
// loaded is the rows' loaded flags, not yet set.
list_decode_into :: proc(data: []u8, source: Source, id: string, space: []u8, allocator: runtime.Allocator) -> (h: ^File_Header, rows: []Row, loaded: []bool, err: File_Error) {
	recs: rawptr
	text: []u8
	h, recs, text, err = file_check(data, source, id)
	if err != .None {
		return
	}
	if h.count > ROWS_MAX {
		return nil, nil, nil, .Damaged
	}
	ok: bool
	if rows, loaded, ok = space_rows(space, int(h.count)); !ok {
		return nil, nil, nil, .Memory
	}
	if err = list_rows(recs, text, rows, allocator); err != .None {
		return nil, nil, nil, err
	}
	return
}

// list_rows fills rows from a checked file's records and text.
@(private = "file")
list_rows :: proc(recs: rawptr, text: []u8, rows: []Row, allocator: runtime.Allocator) -> File_Error {
	file_rows := ([^]File_Row)(recs)[:len(rows)]
	for &f, i in file_rows {
		r := &rows[i]
		strs := [6]^string{&r.title, &r.artist, &r.album, &r.added, &r.duration, &r.cover}
		for p, j in strs {
			ok: bool
			if p^, ok = file_str(text, f.text[j]); !ok {
				return .Damaged
			}
		}
		ok: bool
		if r.artists, ok = file_artists(text, f.artists, len(r.artist), allocator); !ok {
			return .Damaged
		}
		r.seconds = int(f.seconds)
		r.track = int(f.track)
		r.id = f.id
		r.album_id = f.album_id
	}
	return .None
}

// sidebar_decode turns a sidebar file into items whose strings point into
// it.
sidebar_decode :: proc(data: []u8, allocator: runtime.Allocator) -> (h: ^File_Header, items: []Sidebar_Item, err: File_Error) {
	recs: rawptr
	text: []u8
	h, recs, text, err = file_check(data, .None, "")
	if err != .None {
		return
	}
	file_items := ([^]File_Item)(recs)[:h.count]
	items = make([]Sidebar_Item, h.count, allocator)
	for &f, i in file_items {
		it := &items[i]
		strs := [3]^string{&it.id, &it.name, &it.image}
		for p, j in strs {
			ok: bool
			if p^, ok = file_str(text, f.text[j]); !ok {
				return nil, nil, .Damaged
			}
		}
		it.tracks = int(f.tracks)
		it.updated = f.updated
	}
	return
}

// file_read reads path whole, 16-byte aligned, with allocator.
file_read :: proc(path: string, allocator: runtime.Allocator) -> ([]u8, bool) {
	f, err := os.open(path)
	if err != nil {
		return nil, false
	}
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil || size < 0 || size > 1 << 30 {
		return nil, false
	}
	buf, aerr := mem.alloc_bytes_non_zeroed(int(size), 16, allocator)
	if aerr != nil {
		return nil, false
	}
	got := 0
	for got < len(buf) {
		n, rerr := os.read(f, buf[got:])
		if rerr != nil || n <= 0 {
			return nil, false
		}
		got += n
	}
	return buf, true
}

// The queue's file (see player.odin) is a Queue_Header, then a
// Queue_Extras with the anchors of the queue's extras (its Play next and
// Add to queue tracks), then the queue as a list file of source .Search
// and id "queue", with the extras last. Format 1 had no Queue_Extras. The
// header and the anchors are padded to 16 bytes, so the list file after
// them is as aligned as file_read's buffer.

QUEUE_MAGIC :: 0x5551_4654 // "TFQU"
QUEUE_FORMAT :: 2

Queue_Header :: struct {
	magic:    u32,
	format:   u32,
	index:    i64, // the current item
	sample:   i64, // where in it, in samples
	rate:     i64, // the rate sample is in, 0 if unknown
	list_key: u64, // Playback.list_key
	key:      u64, // new with each write, see Queue_Position
}

#assert(size_of(Queue_Header) % 16 == 0)

// Queue_Extras is how many of the rows are extras. An i64 for each follows
// it: the row the extra plays after, or -1 for the end of the play order.
Queue_Extras :: struct {
	count: i64,
	_:     i64,
}

#assert(size_of(Queue_Extras) % 16 == 0)

QUEUE_POSITION_MAGIC :: 0x5051_4654 // "TFQP"

// Queue_Position is where the queue is, in a file of its own, so a pause,
// a seek or another track doesn't write the queue's rows again. It stands
// in for the header's place when its key is the header's.
Queue_Position :: struct {
	magic:  u32,
	_:      u32,
	key:    u64,
	index:  i64,
	sample: i64,
	rate:   i64,
}

// queue_prefix is where the list file starts in a queue file of the
// current format with extras extras.
@(private = "file")
queue_prefix :: proc(extras: int) -> int {
	return size_of(Queue_Header) + size_of(Queue_Extras) + (extras * size_of(i64) + 15) &~ 15
}

// queue_encode is a queue file of rows, without its sum (see queue_seal).
// after is the anchors of the extras, which are the last len(after) rows.
queue_encode :: proc(head: Queue_Header, rows: []Row, allocator: runtime.Allocator, after: []i64 = nil) -> []u8 {
	buf := rows_encode(.Search, "queue", rows, 0, {}, i64(len(rows)), allocator, queue_prefix(len(after)))
	h := (^Queue_Header)(raw_data(buf))
	h^ = head
	h.magic = QUEUE_MAGIC
	h.format = QUEUE_FORMAT
	(^Queue_Extras)(&buf[size_of(Queue_Header)]).count = i64(len(after))
	copy(([^]i64)(&buf[size_of(Queue_Header) + size_of(Queue_Extras)])[:len(after)], after)
	return buf
}

// queue_seal fills in a queue file's sum, which queue_encode leaves out.
queue_seal :: proc(file: []u8) {
	extras := (^Queue_Extras)(&file[size_of(Queue_Header)]).count
	file_seal(file[queue_prefix(int(extras)):])
}

// queue_place_ok says whether a place read from a queue file or its
// position file can be used. Neither is in the list's sum. A day at 768 kHz
// bounds the position, so rescaling it to another rate can't overflow.
queue_place_ok :: proc(sample, rate: i64) -> bool {
	return rate >= 0 && rate <= 768000 && sample >= 0 && (rate == 0 || sample <= rate * 86400)
}

// queue_decode reads a queue file read whole into data, 16-byte aligned.
// The rows' strings point into data. after is the extras' anchors, each a
// row before its own, so they can't go round in a loop.
queue_decode :: proc(data: []u8, allocator: runtime.Allocator) -> (head: Queue_Header, rows: []Row, after: []i64, err: File_Error) {
	if len(data) < size_of(Queue_Header) {
		return {}, nil, nil, .Short
	}
	head = (^Queue_Header)(raw_data(data))^
	if head.magic != QUEUE_MAGIC {
		return {}, nil, nil, .Magic
	}
	if head.format != 1 && head.format != QUEUE_FORMAT {
		return {}, nil, nil, .Format
	}
	if !queue_place_ok(head.sample, head.rate) {
		return {}, nil, nil, .Damaged
	}
	// Without a rate the position can't be placed, so the track starts over.
	if head.rate == 0 {
		head.sample = 0
	}
	prefix, extras := size_of(Queue_Header), 0
	if head.format == QUEUE_FORMAT {
		if len(data) < size_of(Queue_Header) + size_of(Queue_Extras) {
			return {}, nil, nil, .Short
		}
		count := (^Queue_Extras)(&data[size_of(Queue_Header)]).count
		if count < 0 || count > ROWS_MAX {
			return {}, nil, nil, .Damaged
		}
		extras = int(count)
		prefix = queue_prefix(extras)
		if len(data) < prefix {
			return {}, nil, nil, .Short
		}
	}
	if _, rows, err = list_decode(data[prefix:], .Search, "queue", allocator); err != .None {
		return {}, nil, nil, err
	}
	if extras > len(rows) {
		return {}, nil, nil, .Damaged
	}
	after = make([]i64, extras, allocator)
	if extras > 0 {
		copy(after, ([^]i64)(&data[size_of(Queue_Header) + size_of(Queue_Extras)])[:extras])
	}
	first := len(rows) - extras
	for a, j in after {
		if a < -1 || a >= i64(first + j) {
			return {}, nil, nil, .Damaged
		}
	}
	return
}
