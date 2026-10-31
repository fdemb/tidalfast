package text

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:sync"
import "core:sys/posix"

import "../../third_party/kbts"

// Fallback fonts load on a worker thread. Finding one can mean CoreText
// going through every installed font, and loading one maps the file and
// parses it: 21 ms on the UI thread for the first Hebrew. Meanwhile the UI
// thread shapes without the font and marks the run pending; begin_frame
// takes finished faces and pending runs get reshaped when next asked for.
//
// The thread runs this dylib's code, so unload stops and joins it and
// reload starts it again. Everything it shares with the UI thread is plain
// data in Loader, guarded by mutex.

LOAD_QUEUE :: 256
LOAD_RESULTS :: 16

// Characters whose fallbacks init loads straight away: CJK, kana, Hangul,
// Arabic, Hebrew and emoji.
PREWARM := [?]rune{0x4e00, 0x3042, 0xac00, 0x0627, 0x05d0, 0x1f600}

Load_Request :: struct {
	font:      Font,
	codepoint: rune, // find a fallback for font that has this
	ct:        Font_Ref, // macOS: or load this CoreText font; retained, released by the UI thread
	name:      u64, // ct's name hash
}

Load_Result :: struct {
	using request: Load_Request,
	found:         u64, // name hash of the face found, 0 for none
	face:          Face, // set if loaded: the face wasn't loaded before
	loaded:        bool,
}

@(private)
Known_Face :: struct {
	name: u64,
	kb:   kbts.font,
}

Loader :: struct {
	mutex:         sync.Mutex,
	cond:          sync.Cond, // requests arrived, results room freed, or stop
	stop:          bool,
	running:       bool,
	busy:          bool, // the worker is loading a request
	thread:        posix.pthread_t,
	// The shell's request_redraw. It lives in the shell, not the dylib, so
	// it stays valid across reloads.
	wake:          proc "c" (),
	requests:      [LOAD_QUEUE]Load_Request, // a ring
	request_head:  int,
	request_count: int,
	results:       [LOAD_RESULTS]Load_Result,
	result_count:  int,

	// Only the worker touches these after init: every face loaded so far,
	// primary fonts first, with its own copy of each kb_text_shape font to
	// check coverage without reading State.faces.
	known:         [MAX_FACES]Known_Face,
	known_count:   int,
	primary:       [Font]Font_Ref,
}

@(private)
loader_start :: proc(l: ^Loader) {
	if l.running {
		return
	}
	l.stop = false
	l.running = posix.pthread_create(&l.thread, nil, loader_main, l) == .NONE
}

// loader_stop waits for the worker to finish the request in hand and exit.
// Queued requests and unread results stay.
@(private)
loader_stop :: proc(l: ^Loader) {
	if !l.running {
		return
	}
	sync.mutex_lock(&l.mutex)
	l.stop = true
	sync.cond_broadcast(&l.cond)
	sync.mutex_unlock(&l.mutex)
	posix.pthread_join(l.thread)
	l.running = false
}

// load_request queues a request. False if the queue is full.
@(private)
load_request :: proc(l: ^Loader, req: Load_Request) -> bool {
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	if l.request_count == LOAD_QUEUE {
		return false
	}
	l.requests[(l.request_head + l.request_count) % LOAD_QUEUE] = req
	l.request_count += 1
	sync.cond_signal(&l.cond)
	return true
}

// take_results moves finished results into out and returns how many.
@(private)
take_results :: proc(l: ^Loader, out: ^[LOAD_RESULTS]Load_Result) -> int {
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	n := l.result_count
	copy(out[:n], l.results[:n])
	l.result_count = 0
	if n > 0 {
		sync.cond_signal(&l.cond)
	}
	return n
}

// loading is true while a font request is queued, being loaded, or
// finished but not yet taken by begin_frame.
loading :: proc(t: ^State) -> bool {
	l := &t.loader
	sync.mutex_lock(&l.mutex)
	defer sync.mutex_unlock(&l.mutex)
	return l.request_count > 0 || l.busy || l.result_count > 0
}

@(private)
loader_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	l := (^Loader)(arg)
	for {
		sync.mutex_lock(&l.mutex)
		for !l.stop && (l.request_count == 0 || l.result_count == LOAD_RESULTS) {
			sync.cond_wait(&l.cond, &l.mutex)
		}
		if l.stop {
			sync.mutex_unlock(&l.mutex)
			break
		}
		req := l.requests[l.request_head]
		l.request_head = (l.request_head + 1) % LOAD_QUEUE
		l.request_count -= 1
		l.busy = true
		sync.mutex_unlock(&l.mutex)

		result := load(l, req)
		free_all(context.temp_allocator)

		sync.mutex_lock(&l.mutex)
		l.results[l.result_count] = result
		l.result_count += 1
		l.busy = false
		sync.mutex_unlock(&l.mutex)
		if l.wake != nil {
			l.wake()
		}
	}
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
}

// load_face loads font file data into kb_text_shape and readies the face
// for rasterizing: on macOS a copy of ct at BASE_SIZE (face_native_init).
// False if loading fails or kb_text_shape doesn't find need (if not -1) in
// the font. Safe on any thread.
@(private)
load_face :: proc(face: ^Face, ct: Font_Ref, data: []byte, index: int, mapped: bool, need: rune = -1) -> bool {
	face^ = {}
	blob, ok := load_kb_font(&face.kb, data, index)
	if !ok {
		return false
	}
	face.blob = blob
	if need >= 0 && kbts.CodepointToGlyphId(&face.kb, need) == 0 {
		libc.free(blob)
		return false
	}
	info: kbts.font_info2_1
	info.Size = size_of(info)
	kbts.GetFontInfo2(&face.kb, &info)
	face.units_per_em = f32(info.UnitsPerEm)
	face.ascent = f32(info.Ascent) / face.units_per_em
	face.descent = -f32(info.Descent) / face.units_per_em
	face.file = data
	face.mapped = mapped
	if hhea := font_table(data, index, "hhea"); len(hhea) >= 36 {
		face.hmetrics = int(hhea[34]) << 8 | int(hhea[35])
		face.hmtx = font_table(data, index, "hmtx")
	}
	if !face_native_init(face, ct, index) {
		libc.free(blob)
		face^ = {}
		return false
	}
	return true
}

// load_kb_font parses a font into kb_text_shape, placing its blob in
// malloc'd memory, which the face owns. Not Odin allocators: those carry a
// procedure pointer into one dylib, and this runs on the worker.
@(private)
load_kb_font :: proc(f: ^kbts.font, data: []byte, index: int) -> (blob: rawptr, ok: bool) {
	state: kbts.load_font_state
	scratch_size, out_size, err := kbts.LoadFont(f, &state, data, c.int(index))
	if err != .NEED_TO_CREATE_BLOB {
		return nil, err == .NONE
	}
	// PlaceBlob fails on a null buffer even when it needs no bytes.
	scratch := libc.malloc(uint(max(scratch_size, 1)))
	defer libc.free(scratch)
	blob = libc.malloc(uint(max(out_size, 1)))
	if kbts.PlaceBlob(f, &state, scratch, blob) != .NONE {
		libc.free(blob)
		return nil, false
	}
	return blob, true
}

// free_face releases what a face owns. The face may come from any loaded
// copy of the dylib.
@(private)
free_face :: proc(face: ^Face) {
	face_native_free(face)
	if face.mapped {
		posix.munmap(raw_data(face.file), uint(len(face.file)))
	}
	libc.free(face.blob)
	face^ = {}
}

@(private)
map_file :: proc(path: cstring) -> ([]byte, bool) {
	fd := posix.open(path, {})
	if fd < 0 {
		return nil, false
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || st.st_size <= 0 {
		return nil, false
	}
	size := uint(st.st_size)
	p := posix.mmap(nil, size, {.READ}, {.PRIVATE}, fd, 0)
	if p == posix.MAP_FAILED {
		return nil, false
	}
	return ([^]byte)(p)[:size], true
}

// mapped_fonts counts the fallback font files mapped with mmap, their bytes
// and how many of those bytes are in RAM. Mapped files count toward the
// process's resident size but not its footprint: the kernel can drop their
// pages and read them back from the file. UI thread only.
mapped_fonts :: proc(t: ^State) -> (count, mapped, resident: int) {
	page := uintptr(posix.sysconf(._PAGESIZE))
	vec: [1024]u8
	for &face in t.faces[:t.face_count] {
		if !face.mapped {
			continue
		}
		count += 1
		mapped += len(face.file)
		end := uintptr(raw_data(face.file)) + uintptr(len(face.file))
		for at := uintptr(raw_data(face.file)) &~ (page - 1); at < end; {
			n := min(int((end - at + page - 1) / page), len(vec))
			if mincore(rawptr(at), uint(n) * uint(page), &vec[0]) != 0 {
				break
			}
			for v in vec[:n] {
				resident += int(page) if v & 1 != 0 else 0
			}
			at += uintptr(n) * page
		}
	}
	return
}
