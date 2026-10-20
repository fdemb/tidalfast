package audio

// A Stream is one track's bytes on their way from the network to the
// decoder. A fetch thread downloads the file with HTTP range requests into
// a fixed window of the file that slides forward as the decoder reads. A
// seek outside the window moves the window and starts a new request there;
// one inside it costs nothing.
//
// The fetch thread blocks when the window is full, so a paused track holds
// one connection and no CPU. If the server drops the connection meanwhile,
// the next request resumes where the window ends.
//
// A DASH stream is a list of URLs, the initialization segment and then the
// media segments, fetched one after the other into the same window as one
// run of bytes. It can't seek by byte offset, only start again at a
// segment (stream_restart_segment), and offsets count from there.

import "base:runtime"
import "core:c"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import curl "vendor:curl"

import "../cacert"

STREAM_WINDOW :: 3 << 20 // bytes kept per track, about 17 s of 16/44.1 FLAC, 5 s of 24/192
KEEP_BEHIND :: 256 << 10 // bytes kept before the read position, for short seeks back
FETCH_RETRIES :: 5

Stream :: struct {
	mutex:       sync.Mutex,
	cond:        sync.Cond, // room in the window, a new request, or stop
	url:         string, // borrowed from the slot until stream_clear
	buf:         []u8, // the window, page aligned; file offset o lives at buf[o % len]
	released:    bool, // buf's pages went back to the system; written again after pages_reuse
	win_start:   i64, // oldest byte still held
	win_end:     i64, // one past the newest byte
	read_pos:    i64, // the decoder's position; bytes before keep_from may go
	length:      i64, // file size, -1 until a response says
	gen:         u64, // bumped by stream_restart; a transfer for an older gen stops
	active:      bool, // has a URL; the fetch thread works on it
	dash:        bool, // segments instead of url
	seg_urls:    []string, // borrowed, like url
	seg_next:    int, // the segment being fetched
	seg_base:    i64, // the offset its first byte lands at
	seg_starts:  []i64, // each segment's first offset once known, -1 before; borrowed, like url
	failed:      bool, // gave up after FETCH_RETRIES
	http_status: int, // of the last failed response, 0 for transport errors
	error:       [96]u8,
	stop:        bool,
	wake:        ^Wake, // the decode thread's, posted when bytes arrive
	thread:      posix.pthread_t,
	// Header and seek data, filled by the decode thread once it has read them.
	header:      Flac_Header,
	head:        []u8, // the bytes before the first frame, borrowed, like url
	has_header:  bool,
	logger:      runtime.Logger, // stream_init's caller's, for the fetch thread
}

stream_init :: proc(st: ^Stream, wake: ^Wake, window := STREAM_WINDOW) {
	// Its own mapping, so stream_clear can give the pages back.
	buf, err := vmem.reserve_and_commit(uint(window))
	assert(err == nil, "audio: no memory for the stream window")
	st.buf = buf
	st.released = true
	st.wake = wake
	st.length = -1
	st.logger = context.logger
	posix.pthread_create(&st.thread, nil, fetch_main, st)
}

stream_destroy :: proc(st: ^Stream) {
	sync.lock(&st.mutex)
	st.stop = true
	st.gen += 1
	sync.cond_broadcast(&st.cond)
	sync.unlock(&st.mutex)
	posix.pthread_join(st.thread)
	stream_clear(st)
	vmem.release(raw_data(st.buf), uint(len(st.buf)))
}

// stream_open points the stream at a new URL, from offset 0. The URL must
// last until stream_clear.
stream_open :: proc(st: ^Stream, url: string) {
	sync.guard(&st.mutex)
	stream_clear_locked(st)
	st.url = url
	st.active = true
	st.gen += 1
	sync.cond_broadcast(&st.cond)
}

// stream_open_segments points the stream at DASH segments, fetched in
// order from the first. starts has room for one offset per URL. Both must
// last until stream_clear.
stream_open_segments :: proc(st: ^Stream, urls: []string, starts: []i64) {
	assert(len(starts) == len(urls))
	sync.guard(&st.mutex)
	stream_clear_locked(st)
	st.seg_urls = urls
	st.seg_starts = starts
	for &v in st.seg_starts {
		v = -1
	}
	if len(urls) > 0 {
		st.seg_starts[0] = 0
	}
	st.dash = true
	st.active = true
	st.gen += 1
	sync.cond_broadcast(&st.cond)
}

// stream_restart_segment drops the bytes held and fetches from segment
// index on. Offset 0 is then that segment's first byte.
stream_restart_segment :: proc(st: ^Stream, index: int) {
	sync.guard(&st.mutex)
	st.seg_next = clamp(index, 0, len(st.seg_urls))
	st.seg_base = 0
	for &v in st.seg_starts {
		v = -1
	}
	if st.seg_next < len(st.seg_starts) {
		st.seg_starts[st.seg_next] = 0
	}
	st.win_start, st.win_end, st.read_pos = 0, 0, 0
	st.length = -1
	if st.seg_next == len(st.seg_urls) {
		st.length = 0
	}
	st.failed = false
	st.gen += 1
	sync.cond_broadcast(&st.cond)
}

// stream_clear stops the transfer and forgets the URL and header. After it
// the stream holds nothing it borrowed.
stream_clear :: proc(st: ^Stream) {
	sync.guard(&st.mutex)
	stream_clear_locked(st)
	st.gen += 1
	sync.cond_broadcast(&st.cond)
}

@(private = "file")
stream_clear_locked :: proc(st: ^Stream) {
	// Nothing in the window is wanted any more: a stop, another track or
	// none. Its pages stop counting against the app until bytes arrive.
	if !st.released && pages_release(st.buf) {
		st.released = true
	}
	st.url = ""
	st.head = nil
	st.seg_urls = nil
	st.seg_starts = nil
	st.dash = false
	st.seg_next, st.seg_base = 0, 0
	st.has_header = false
	st.active = false
	st.failed = false
	st.http_status = 0
	st.length = -1
	st.win_start, st.win_end, st.read_pos = 0, 0, 0
}

// stream_restart moves the read position to offset. If offset is outside
// the bytes held, the window empties and a new request starts there.
stream_restart :: proc(st: ^Stream, offset: i64) {
	sync.guard(&st.mutex)
	if offset >= st.win_start && offset <= st.win_end {
		st.read_pos = offset
		sync.cond_broadcast(&st.cond)
		return
	}
	st.win_start, st.win_end, st.read_pos = offset, offset, offset
	st.failed = false
	st.gen += 1
	sync.cond_broadcast(&st.cond)
}

Read_Result :: enum u8 {
	Ok,
	Eof, // fewer bytes than asked: the file ends
	Failed, // the fetch gave up
	Interrupted, // wait returned true
}

// stream_read copies len(dst) bytes from offset, waiting for them to
// arrive. It takes them as they come, so dst may be longer than the window.
// Each time the bytes aren't there yet it calls wait, which sleeps until
// the stream's wake is posted, can handle commands, and returns true to
// give up. Moves the read position to the end of what it copied, and n
// counts those bytes whatever the result.
stream_read :: proc(st: ^Stream, offset: i64, dst: []u8, wait: proc(data: rawptr) -> bool, data: rawptr) -> (n: int, res: Read_Result) {
	for {
		sync.lock(&st.mutex)
		at := offset + i64(n)
		if st.dash && at < st.win_start {
			sync.unlock(&st.mutex)
			return n, .Failed
		}
		if !st.dash && (at < st.win_start || at > st.win_end) {
			// Not held and not next: move the window here.
			sync.unlock(&st.mutex)
			stream_restart(st, at)
			continue
		}
		want := i64(len(dst) - n)
		if st.length >= 0 {
			want = clamp(st.length - at, 0, want)
		}
		k := clamp(st.win_end - at, 0, want)
		ring_read(st.buf, at, dst[n:][:k])
		n += int(k)
		at += k
		if k == want {
			st.read_pos = at
			sync.cond_broadcast(&st.cond)
			sync.unlock(&st.mutex)
			if n < len(dst) {
				return n, .Eof
			}
			return n, .Ok
		}
		// The fetcher may be waiting for room that only moving read_pos
		// frees. A DASH read can be ahead of what has arrived, when it skips
		// a box; bytes before it may go as they arrive.
		if pos := min(at, st.win_end); st.read_pos != pos {
			st.read_pos = pos
			sync.cond_broadcast(&st.cond)
		}
		failed := st.failed
		sync.unlock(&st.mutex)
		if failed {
			return n, .Failed
		}
		if wait(data) {
			return n, .Interrupted
		}
	}
}

// stream_segment_start is the offset where the DASH segment holding
// offset starts, 0 if that isn't known. An explicit base_data_offset in a
// moof counts from there.
stream_segment_start :: proc(st: ^Stream, offset: i64) -> i64 {
	sync.guard(&st.mutex)
	start := i64(0)
	for v in st.seg_starts {
		if v >= 0 && v <= offset {
			start = v
		}
	}
	return start
}

// stream_done says whether the whole file has arrived.
stream_done :: proc(st: ^Stream) -> bool {
	sync.guard(&st.mutex)
	return st.active && st.length >= 0 && st.win_end >= st.length
}

stream_error :: proc(st: ^Stream, buf: []u8) -> (status: int, msg: string) {
	sync.guard(&st.mutex)
	n := copy(buf, st.error[:])
	for i in 0 ..< n {
		if buf[i] == 0 {
			n = i
			break
		}
	}
	return st.http_status, string(buf[:n])
}

@(private = "file")
Transfer :: struct {
	st:      ^Stream,
	gen:     u64,
	base:    i64, // the stream offset of the URL's first byte
	pos:     i64, // stream offset of the next byte to arrive
	skip:    i64, // bytes to drop, when a server ignores the Range header
	status:  int,
	aborted: bool,
}

@(private = "file")
curl_once: sync.Once

@(private = "file")
fetch_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	st := (^Stream)(arg)
	context.logger = st.logger
	sync.once_do(&curl_once, proc() {curl.global_init(curl.GLOBAL_DEFAULT)})
	h := curl.easy_init()
	failures := 0
	last_gen: u64
	for {
		sync.lock(&st.mutex)
		for !st.stop && (!st.active || st.failed || (st.length >= 0 && st.win_end >= st.length) || (st.dash && st.seg_next >= len(st.seg_urls)) || window_full(st)) {
			sync.cond_wait(&st.cond, &st.mutex)
		}
		if st.stop {
			sync.unlock(&st.mutex)
			break
		}
		gen := st.gen
		if gen != last_gen {
			failures = 0
			last_gen = gen
		}
		start := st.win_end
		base := i64(0)
		url: string
		if st.dash {
			base = st.seg_base
			url = strings.clone(st.seg_urls[st.seg_next], context.temp_allocator)
		} else {
			url = strings.clone(st.url, context.temp_allocator)
		}
		sync.unlock(&st.mutex)

		t := Transfer {
			st     = st,
			gen    = gen,
			base   = base,
			pos    = start,
			status = 0,
		}
		code := transfer(h, &t, url, start - base)
		free_all(context.temp_allocator)

		sync.lock(&st.mutex)
		if st.gen != gen || st.stop {
			sync.unlock(&st.mutex)
			continue
		}
		ok := code == .E_OK && (t.status == 200 || t.status == 206 || (t.status == 416 && !st.dash))
		if t.status == 416 && st.length < 0 && !st.dash {
			st.length = st.win_end
			wake_post(st.wake)
		}
		if ok && st.dash {
			// A whole segment: on to the next. After the last the length is known.
			failures = 0
			st.seg_next += 1
			st.seg_base = st.win_end
			if st.seg_next < len(st.seg_starts) {
				st.seg_starts[st.seg_next] = st.win_end
			}
			if st.seg_next == len(st.seg_urls) {
				st.length = st.win_end
				wake_post(st.wake)
			}
		} else if ok && st.length >= 0 && st.win_end >= st.length {
			failures = 0
		} else if ok && t.pos > start {
			// The server closed early, as after a long pause. Go on from here.
			failures = 0
		} else {
			failures += 1
			msg: string
			if code != .E_OK {
				msg = string(curl.easy_strerror(code))
			} else {
				msg = fmt.tprintf("HTTP %d", t.status)
			}
			copy(st.error[:len(st.error) - 1], msg)
			st.error[min(len(msg), len(st.error) - 1)] = 0
			st.http_status = t.status if code == .E_OK else 0
			client_error := t.status >= 400 && t.status < 500 && t.status != 416
			if failures >= FETCH_RETRIES || client_error {
				log.warnf("audio: fetch failed at byte %d: %s", start, msg)
				st.failed = true
				sync.unlock(&st.mutex)
				wake_post(st.wake)
				continue
			}
			// Back off before trying again, unless a new request comes in.
			sync.cond_wait_with_timeout(&st.cond, &st.mutex, time.Duration(250 << uint(failures)) * time.Millisecond)
		}
		sync.unlock(&st.mutex)
	}
	curl.easy_cleanup(h)
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
}

// window_full says the fetcher must wait for the decoder: the window is
// full and none of its bytes are far enough behind the reader to drop.
// Caller holds the mutex.
@(private = "file")
window_full :: proc(st: ^Stream) -> bool {
	return st.win_end - keep_from(st) >= i64(len(st.buf))
}

// ring_read copies the bytes from file offset at into dst, which is no
// longer than buf.
@(private = "file")
ring_read :: proc(buf: []u8, at: i64, dst: []u8) {
	k := copy(dst, buf[at % i64(len(buf)):])
	copy(dst[k:], buf)
}

@(private = "file")
ring_write :: proc(buf: []u8, at: i64, src: []u8) {
	k := copy(buf[at % i64(len(buf)):], src)
	copy(buf, src[k:])
}

// keep_from is the oldest byte the window must still hold: KEEP_BEHIND
// before the reader, or less in a small window, which must keep most of
// itself for the bytes ahead. Caller holds the mutex.
@(private = "file")
keep_from :: proc(st: ^Stream) -> i64 {
	behind := min(KEEP_BEHIND, i64(len(st.buf)) / 4)
	return max(st.win_start, st.read_pos - behind)
}

@(private = "file")
transfer :: proc(h: ^curl.CURL, t: ^Transfer, url: string, start: i64) -> curl.code {
	curl.easy_reset(h)
	curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.easy_setopt(h, .NOSIGNAL, c.long(1))
	curl.easy_setopt(h, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(h, .CONNECTTIMEOUT, c.long(15))
	if ca := cacert.path(); ca != nil {
		curl.easy_setopt(h, .CAINFO, ca)
	}
	// A stalled connection, or one we left alone while paused, ends after
	// 30 s below 1 byte/s; the loop then resumes from where it got to.
	curl.easy_setopt(h, .LOW_SPEED_LIMIT, c.long(1))
	curl.easy_setopt(h, .LOW_SPEED_TIME, c.long(30))
	if start > 0 {
		curl.easy_setopt(h, .RANGE, strings.clone_to_cstring(fmt.tprintf("%d-", start), context.temp_allocator))
	}
	curl.easy_setopt(h, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(h, .WRITEDATA, t)
	curl.easy_setopt(h, .HEADERFUNCTION, header_callback)
	curl.easy_setopt(h, .HEADERDATA, t)
	curl.easy_setopt(h, .NOPROGRESS, c.long(0))
	curl.easy_setopt(h, .XFERINFOFUNCTION, progress_callback)
	curl.easy_setopt(h, .XFERINFODATA, t)
	return curl.easy_perform(h)
}

// Reads the status and the file length from Content-Range (206) or
// Content-Length (200).
@(private = "file")
header_callback :: proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	n := int(size * nitems)
	t := (^Transfer)(userdata)
	line := strings.trim_space(string(buffer[:n]))
	if strings.has_prefix(line, "HTTP/") {
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) >= 2 {
			t.status, _ = strconv.parse_int(parts[1])
		}
		return c.size_t(n)
	}
	name, _, value := strings.partition(line, ":")
	value = strings.trim_space(value)
	st := t.st
	if sync.atomic_load(&st.dash) {
		// Segment sizes say nothing about the stream's length.
		if strings.equal_fold(name, "content-length") && t.status == 200 {
			t.skip = t.pos - t.base
		}
		return c.size_t(n)
	}
	if strings.equal_fold(name, "content-range") && t.status == 206 {
		// bytes a-b/total
		if slash := strings.last_index_byte(value, '/'); slash >= 0 {
			if total, ok := strconv.parse_i64(value[slash + 1:]); ok {
				sync.guard(&st.mutex)
				if st.gen == t.gen {
					st.length = total
					wake_post(st.wake)
				}
			}
		}
	} else if strings.equal_fold(name, "content-length") && t.status == 200 {
		if total, ok := strconv.parse_i64(value); ok {
			sync.guard(&st.mutex)
			if st.gen == t.gen {
				st.length = total
				wake_post(st.wake)
			}
			// A 200 to a range request sends the file from the start.
			t.skip = t.pos
		}
	}
	return c.size_t(n)
}

@(private = "file")
write_callback :: proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	n := int(size * nitems)
	t := (^Transfer)(userdata)
	st := t.st
	if t.status != 200 && t.status != 206 {
		return c.size_t(n) // an error body; the status says what happened
	}
	data := buffer[:n]
	if t.skip > 0 {
		k := min(i64(len(data)), t.skip)
		data = data[k:]
		t.skip -= k
	}
	sync.lock(&st.mutex)
	defer sync.unlock(&st.mutex)
	if st.released && pages_reuse(st.buf) {
		st.released = false
	}
	cap := i64(len(st.buf))
	for len(data) > 0 {
		if st.gen != t.gen || st.stop {
			t.aborted = true
			return 0
		}
		if window_full(st) {
			sync.cond_wait(&st.cond, &st.mutex)
			continue
		}
		room := cap - (st.win_end - keep_from(st))
		k := min(room, i64(len(data)))
		ring_write(st.buf, st.win_end, data[:k])
		st.win_end += k
		st.win_start = max(st.win_start, st.win_end - cap)
		t.pos = st.win_end
		data = data[k:]
		wake_post(st.wake)
	}
	return c.size_t(n)
}

@(private = "file")
progress_callback :: proc "c" (userdata: rawptr, dltotal, dlnow, ultotal, ulnow: curl.off_t) -> c.int {
	t := (^Transfer)(userdata)
	st := t.st
	return 1 if sync.atomic_load(&st.gen) != t.gen || sync.atomic_load(&st.stop) else 0
}
