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

FILE_MAGIC :: 0x434c_4654 // "TFLC"
FILE_FORMAT :: 1

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

// File_Row is a Row on disk.
File_Row :: struct {
	text:      [7]File_Str, // title, artist, album, added, added_by, duration, cover
	seconds:   i32,
	track:     i32,
	id:        i64,
	album_id:  i64,
	artist_id: i64,
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
	Damaged, // its sum or a string's bounds are wrong
}

@(private = "file")
File_Writer :: struct {
	buf:  []u8,
	base: int, // where the text starts
	text: int, // where the next string goes
}

@(private = "file")
put :: proc(w: ^File_Writer, s: string) -> File_Str {
	at := w.text
	copy(w.buf[at:], s)
	w.text += len(s)
	return {u32(at - w.base), u32(len(s))}
}

@(private = "file")
writer_make :: proc(source: Source, id: string, count, text: int, allocator: runtime.Allocator) -> (w: File_Writer, h: ^File_Header) {
	rec := size_of(File_Row) if source != .None else size_of(File_Item)
	w.buf = make([]u8, size_of(File_Header) + count * rec + text + len(id), allocator)
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

@(private = "file")
writer_finish :: proc(w: ^File_Writer) -> []u8 {
	h := (^File_Header)(raw_data(w.buf))
	h.sum = hash.fnv64a(w.buf[size_of(File_Header):])
	return w.buf
}

// list_encode is a done list as a file.
list_encode :: proc(v: ^Track_View, allocator: runtime.Allocator) -> []u8 {
	n := min(v.count, len(v.rows))
	text := 0
	for &r in v.rows[:n] {
		text += len(r.title) + len(r.artist) + len(r.album) + len(r.added) + len(r.added_by) + len(r.duration) + len(r.cover)
	}
	w, h := writer_make(v.source, small_str(&v.id), n, text, allocator)
	h.fetched = v.fetched
	h.version = v.version
	h.hint = i64(v.hint)
	rows := ([^]File_Row)(raw_data(w.buf[size_of(File_Header):]))[:n]
	for &r, i in v.rows[:n] {
		rows[i] = {
			text      = {put(&w, r.title), put(&w, r.artist), put(&w, r.album), put(&w, r.added), put(&w, r.added_by), put(&w, r.duration), put(&w, r.cover)},
			seconds   = i32(r.seconds),
			track     = i32(r.track),
			id        = r.id,
			album_id  = r.album_id,
			artist_id = r.artist_id,
		}
	}
	return writer_finish(&w)
}

// sidebar_encode is the sidebar as a file.
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
	return writer_finish(&w)
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

// list_decode turns a list file read into the list's arena into rows whose
// strings point into it.
list_decode :: proc(data: []u8, source: Source, id: string, allocator: runtime.Allocator) -> (h: ^File_Header, rows: []Row, err: File_Error) {
	recs: rawptr
	text: []u8
	h, recs, text, err = file_check(data, source, id)
	if err != .None {
		return
	}
	file_rows := ([^]File_Row)(recs)[:h.count]
	rows = make([]Row, h.count, allocator)
	for &f, i in file_rows {
		r := &rows[i]
		strs := [7]^string{&r.title, &r.artist, &r.album, &r.added, &r.added_by, &r.duration, &r.cover}
		for p, j in strs {
			ok: bool
			if p^, ok = file_str(text, f.text[j]); !ok {
				return nil, nil, .Damaged
			}
		}
		r.seconds = int(f.seconds)
		r.track = int(f.track)
		r.id = f.id
		r.album_id = f.album_id
		r.artist_id = f.artist_id
	}
	return
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
