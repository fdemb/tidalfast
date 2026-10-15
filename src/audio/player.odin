package audio

// The player: one decode thread, a fetch thread per track slot, and the
// device's audio callback.
//
//     fetch threads --bytes--> Stream windows --> decode thread --frames--> Pcm_Ring --> audio callback
//
// The decode thread owns the slots, the decoders and the device. It reads a
// slot's bytes through dr_flac, applies the track's ReplayGain and writes
// float frames into the ring. The callback copies frames out, applies the
// volume and never blocks or allocates: the ring and the marks are lock-free,
// and it wakes the decode thread with a futex post only when it has freed a
// quarter of the ring and the thread said it's waiting for room.
//
// Two slots hold the current track and the next one. The next one's bytes
// download while the current plays, and its first frames go into the ring
// right after the current's last ones, so the device sees one unbroken
// stream: gapless. A mark in the ring says where each track (or seek)
// starts, and the callback publishes which mark it is playing.
//
// The app talks to the player through commands (play, seek, pause, next,
// volume) that never block on the network or the device, and reads a
// Status snapshot.
//
// All of it runs code from the app dylib, so the app destroys the player
// before a hot reload and makes a new one after. See src/app/player.odin.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import ma "vendor:miniaudio"

RING_FRAMES :: 1 << 17 // about 3 s at 44.1 kHz
CHUNK :: 4096 // frames decoded per step
CAPTURE_FRAMES :: 1 << 19 // about 12 s at 44.1 kHz
TICK :: 250 * time.Millisecond // how often a playing player wakes the UI
WANT_NEXT_SECONDS :: 30 // ask for the next track this long before the end at the latest
NEAR_SECONDS :: 0.3 // a seek decodes and drops at most about this much

Source_Kind :: enum u8 {
	None,
	Flac, // a FLAC file over HTTP
	Tone, // a sine wave, for TIDALFAST_FAKE
}

// Source is one track for the player. The app picks a serial for each,
// unique and increasing; the status reports serials so the app can tell
// which track is audible.
Source :: struct {
	kind:    Source_Kind,
	serial:  u64,
	url:     string, // Flac; copied
	gain:    f32, // linear, ReplayGain already worked out
	seconds: f64, // the length the app knows, used until the file says
	tone_hz: f32,
}

Play_State :: enum u8 {
	Idle,
	Playing,
	Paused,
	Ended,
}

Status :: struct {
	serial:      u64, // the audible source, 0 for none
	sample:      i64, // its position
	rate:        int,
	total:       i64, // its length in samples, 0 if unknown
	seek_id:     u32, // the last seek the audio reflects
	state:       Play_State,
	buffering:   bool, // waiting for data with nothing to play
	want_next:   bool, // the current track is nearly loaded: send set_next
	next_serial: u64, // the source set_next gave, 0 for none
	error:       Error_Info,
	underruns:   u64,
}

Error_Info :: struct {
	serial:      u64, // the source that failed, 0 for none
	http_status: int,
	len:         int,
	buf:         [96]u8,
}

error_text :: proc(e: ^Error_Info) -> string {
	return string(e.buf[:e.len])
}

@(private)
Slot :: struct {
	player:      ^Player,
	source:      Source,
	stream:      Stream,
	decoder:     ^ma.decoder, // heap, nil when closed
	vpos:        i64, // dr_flac's position in the stream it sees: header, then frames from frame_off
	frame_off:   i64,
	next_sample: i64, // sample of the next frame the decoder returns
	discard:     i64, // frames to drop before output, after a seek
	rate:        int,
	channels:    int,
	total:       i64,
	finished:    bool, // nothing more to decode
	interrupted: bool,
	failed:      bool,
}

@(private)
Commands :: struct {
	play:         Maybe(Source),
	play_at:      i64,
	play_paused:  bool,
	seek:         Maybe(i64),
	seek_id:      u32,
	next:         Maybe(Source), // kind None clears it
	paused:       Maybe(bool),
	quit:         bool,
	seek_tick:    time.Tick,
}

Player :: struct {
	wake_ui:         proc "c" (),
	sema:            sync.Atomic_Sema,
	thread:          posix.pthread_t,
	cmd_mutex:       sync.Mutex,
	cmd:             Commands,
	cmd_pending:     bool,
	next_seek_id:    u32, // main thread
	volume_bits:     u32, // f32 bits; atomic

	// Decode thread.
	slots:           [2]Slot,
	cur:             int,
	prev_alive:      bool, // slots[1-cur] is the previous track, its tail still audible
	pending_next:    Source, // a set_next that waits for the tail to finish
	has_pending:     bool,
	paused:          bool,
	device:          ^ma.device,
	null_output:     bool, // miniaudio's null backend: real-time callbacks, no sound
	null_ctx:        ^ma.context_type, // heap, for null_output
	device_open:     bool,
	device_running:  bool,
	device_rate:     int,
	device_channels: int,
	end_pushed:      bool,
	scratch:         []f32,
	ui_tick:         i64,
	ui_mark:         u64,
	seek_tick:       time.Tick,
	seek_logged:     u32,
	capture_fd:      posix.FD,
	capture_frames:  i64,
	capture_rate:    int,
	capture_ch:      int,

	// The ring and the marks, shared with the callback.
	pcm:             Pcm_Ring,
	pcm_data:        []f32,
	marks:           Mark_Queue,
	capture:         Pcm_Ring,
	capturing:       bool,

	// Written by the callback (or the decode thread while the device is
	// stopped), read by anyone.
	cb_gain:         f32,
	waiting_space:   bool,
	pub_mark:        u64, // marks adopted so far; the current one is pub_mark-1
	pub_sample:      i64,
	pub_seek_tick:   i64, // tick of the first frame after the last seek mark
	pub_seek_id:     u32,
	underruns:       u64,

	// Written by the decode thread under status_mutex.
	status_mutex:    sync.Mutex,
	st:              Status,
	st_serial:       u64, // the source st.rate and st.total are for
}

// create starts a player. wake_ui is called from the decode thread when
// the status changes, and every TICK while playing. With capture_path set,
// every frame the callback sends to the device also goes to that file as a
// 32-bit float WAV. window is each track's download window in bytes. With
// null_output the callback runs on miniaudio's null device, in real time
// but silent, for tests.
create :: proc(wake_ui: proc "c" (), volume: f32, capture_path := "", window := STREAM_WINDOW, null_output := false) -> ^Player {
	heap := runtime.heap_allocator()
	p := new(Player, heap)
	p.wake_ui = wake_ui
	p.null_output = null_output
	p.capture_fd = -1
	set_volume(p, volume)
	p.scratch = make([]f32, CHUNK * 8, heap)
	p.device = new(ma.device, heap)
	if capture_path != "" {
		p.capture_fd = posix.open(strings.clone_to_cstring(capture_path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if p.capture_fd >= 0 {
			cap_data := make([]f32, CAPTURE_FRAMES * 8, heap)
			ring_init(&p.capture, cap_data, CAPTURE_FRAMES, 2)
			fmt.eprintln("audio: capturing output to", capture_path)
		}
	}
	for &sl in p.slots {
		sl.player = p
		stream_init(&sl.stream, &p.sema, max(window, 64 << 10))
	}
	posix.pthread_create(&p.thread, nil, decode_main, p)
	return p
}

// destroy stops everything: the device, the decode thread and the fetch
// threads. Returns once none of them runs any more.
destroy :: proc(p: ^Player) {
	if p == nil {
		return
	}
	sync.lock(&p.cmd_mutex)
	p.cmd.quit = true
	sync.unlock(&p.cmd_mutex)
	sync.atomic_store(&p.cmd_pending, true)
	sync.atomic_sema_post(&p.sema)
	posix.pthread_join(p.thread)
	heap := runtime.heap_allocator()
	for &sl in p.slots {
		slot_close(&sl)
		stream_destroy(&sl.stream)
	}
	commands_free(&p.cmd)
	delete(p.pending_next.url, heap)
	delete(p.scratch, heap)
	delete(p.pcm_data, heap)
	delete(p.capture.data, heap)
	free(p.device, heap)
	free(p, heap)
}

// play replaces whatever plays with source, from sample at. The audio
// stops at once; the new track starts when its first bytes arrive.
play :: proc(p: ^Player, source: Source, at: i64 = 0, paused := false) {
	sync.lock(&p.cmd_mutex)
	commands_free(&p.cmd)
	p.cmd.play = source_clone(source)
	p.cmd.play_at = at
	p.cmd.play_paused = paused
	p.cmd.paused = nil
	sync.unlock(&p.cmd_mutex)
	post(p)
}

// seek moves the current track to sample. Returns an id that Status.seek_id
// reaches once the audio is from the new position.
seek :: proc(p: ^Player, sample: i64) -> u32 {
	p.next_seek_id += 1
	sync.lock(&p.cmd_mutex)
	p.cmd.seek = sample
	p.cmd.seek_id = p.next_seek_id
	p.cmd.seek_tick = time.tick_now()
	sync.unlock(&p.cmd_mutex)
	post(p)
	return p.next_seek_id
}

// set_next gives the track that follows the current one, for gapless
// playback. A source of kind None clears it.
set_next :: proc(p: ^Player, source: Source) {
	sync.lock(&p.cmd_mutex)
	if old, ok := p.cmd.next.?; ok {
		delete(old.url, runtime.heap_allocator())
	}
	p.cmd.next = source_clone(source)
	sync.unlock(&p.cmd_mutex)
	post(p)
}

set_paused :: proc(p: ^Player, paused: bool) {
	sync.lock(&p.cmd_mutex)
	p.cmd.paused = paused
	sync.unlock(&p.cmd_mutex)
	post(p)
}

// set_volume takes the slider's 0 to 1. The callback ramps to it over one
// buffer, so moving the slider doesn't click.
set_volume :: proc(p: ^Player, v: f32) {
	sync.atomic_store(&p.volume_bits, transmute(u32)volume_gain(v))
}

status :: proc(p: ^Player) -> Status {
	sync.lock(&p.status_mutex)
	s := p.st
	format_of := p.st_serial
	sync.unlock(&p.status_mutex)
	if m := current_mark(p); m.serial != 0 {
		s.serial = m.serial
		s.seek_id = m.seek_id
		if m.end {
			s.state = .Ended
		}
	}
	// Just after a track change the decode thread may not have caught up.
	if s.serial != format_of {
		s.rate, s.total = 0, 0
	}
	s.sample = sync.atomic_load(&p.pub_sample)
	s.underruns = sync.atomic_load(&p.underruns)
	return s
}

// seek_latency returns the time from the last seek command to the first
// frame of audio from the new position, once that frame has played.
seek_latency :: proc(p: ^Player) -> (id: u32, d: time.Duration, ok: bool) {
	id = sync.atomic_load(&p.pub_seek_id)
	t := sync.atomic_load(&p.pub_seek_tick)
	if id == 0 || t == 0 {
		return
	}
	return id, time.tick_diff(p.seek_tick, time.Tick{t}), true
}

@(private = "file")
post :: proc(p: ^Player) {
	sync.atomic_store(&p.cmd_pending, true)
	sync.atomic_sema_post(&p.sema)
}

@(private = "file")
source_clone :: proc(s: Source) -> Source {
	c := s
	c.url = strings.clone(s.url, runtime.heap_allocator())
	return c
}

@(private = "file")
commands_free :: proc(c: ^Commands) {
	heap := runtime.heap_allocator()
	if s, ok := c.play.?; ok {
		delete(s.url, heap)
	}
	if s, ok := c.next.?; ok {
		delete(s.url, heap)
	}
	c.play = nil
	c.next = nil
}

// The decode thread.

@(private = "file")
decode_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	p := (^Player)(arg)
	for {
		if !run_commands(p, true) {
			break
		}
		busy := step(p)
		after_step(p)
		free_all(context.temp_allocator)
		if busy {
			continue
		}
		if p.device_running {
			sync.atomic_sema_wait_with_timeout(&p.sema, TICK)
		} else {
			sync.atomic_sema_wait(&p.sema)
		}
	}
	device_close(p)
	if p.null_ctx != nil {
		ma.context_uninit(p.null_ctx)
		free(p.null_ctx, runtime.heap_allocator())
	}
	capture_close(p)
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	return nil
}

// run_commands applies pending commands. With heavy false (inside a read
// that waits for bytes) it applies only those that don't touch the current
// decoder, and returns false if a heavy one waits, so the read gives up.
// With heavy true it returns false on quit.
@(private = "file")
run_commands :: proc(p: ^Player, heavy: bool) -> bool {
	if !sync.atomic_load(&p.cmd_pending) {
		return true
	}
	sync.lock(&p.cmd_mutex)
	c := &p.cmd
	if !heavy && (c.quit || c.play != nil || c.seek != nil) {
		sync.unlock(&p.cmd_mutex)
		return false
	}
	sync.atomic_store(&p.cmd_pending, false)
	quit := c.quit
	play_src, has_play := c.play.?
	play_at, play_paused := c.play_at, c.play_paused
	seek_to, has_seek := c.seek.?
	seek_id, seek_tick := c.seek_id, c.seek_tick
	next, has_next := c.next.?
	paused, has_paused := c.paused.?
	c.play, c.seek, c.next, c.paused = nil, nil, nil, nil
	sync.unlock(&p.cmd_mutex)

	heap := runtime.heap_allocator()
	if quit {
		delete(play_src.url, heap)
		delete(next.url, heap)
		return false
	}
	if has_play {
		do_play(p, play_src, play_at, play_paused)
		delete(play_src.url, heap)
	}
	if has_next {
		do_set_next(p, next)
		delete(next.url, heap)
	}
	if has_seek {
		p.seek_tick = seek_tick
		do_seek(p, seek_to, seek_id)
	}
	if has_paused {
		p.paused = paused
		update_device(p)
		status_set(p, proc(s: ^Status, p: ^Player) {s.state = .Paused if p.paused else .Playing})
	}
	return true
}

@(private = "file")
status_set :: proc(p: ^Player, f: proc(s: ^Status, p: ^Player)) {
	sync.lock(&p.status_mutex)
	f(&p.st, p)
	sync.unlock(&p.status_mutex)
	p.wake_ui()
}

@(private = "file")
do_play :: proc(p: ^Player, src: Source, at: i64, paused: bool) {
	other := &p.slots[1 - p.cur]
	// The preloaded next track: keep its bytes.
	if !p.prev_alive && other.source.kind != .None && other.source.serial == src.serial {
		slot_close(&p.slots[p.cur])
		stream_clear(&p.slots[p.cur].stream)
		p.slots[p.cur].source = {}
		p.cur = 1 - p.cur
	} else {
		for &sl in p.slots {
			slot_close(&sl)
			stream_clear(&sl.stream)
			sl.source = {}
		}
		sl := &p.slots[p.cur]
		sl.source = src
		sl.source.url = ""
		if src.kind == .Flac {
			stream_open(&sl.stream, src.url)
		}
	}
	p.prev_alive = false
	delete(p.pending_next.url, runtime.heap_allocator())
	p.pending_next = {}
	p.has_pending = false
	p.paused = paused
	p.end_pushed = false
	sl := &p.slots[p.cur]
	sl.discard = 0
	sl.finished = false
	sl.next_sample = at
	mark_push(&p.marks, {at = sync.atomic_load(&p.pcm.write), serial = src.serial, sample = at})
	ring_flush(&p.pcm)
	if !p.device_running {
		bookkeep_stopped(p)
	}
	sync.lock(&p.status_mutex)
	p.st.state = .Paused if paused else .Playing
	p.st.next_serial = 0
	p.st.want_next = false
	p.st.error = {}
	p.st.rate = 0
	p.st.total = 0
	p.st_serial = src.serial
	sync.unlock(&p.status_mutex)
	update_device(p)
	p.wake_ui()
}

@(private = "file")
do_set_next :: proc(p: ^Player, src: Source) {
	heap := runtime.heap_allocator()
	if p.prev_alive {
		delete(p.pending_next.url, heap)
		p.pending_next = source_clone(src)
		p.has_pending = true
		return
	}
	other := &p.slots[1 - p.cur]
	if other.source.serial == src.serial && src.kind != .None {
		return
	}
	slot_close(other)
	stream_clear(&other.stream)
	other.source = src
	other.source.url = ""
	other.finished = false
	other.next_sample = 0
	other.discard = 0
	if src.kind == .Flac {
		stream_open(&other.stream, src.url)
	}
	sync.lock(&p.status_mutex)
	p.st.next_serial = src.serial
	p.st.want_next = false
	sync.unlock(&p.status_mutex)
}

@(private = "file")
do_seek :: proc(p: ^Player, target: i64, id: u32) {
	audible := current_mark(p).serial
	// A seek in the tail of the previous track, after the next has started
	// decoding: go back to it.
	if p.prev_alive && p.slots[1 - p.cur].source.serial == audible {
		nxt := &p.slots[p.cur]
		slot_close(nxt)
		nxt.finished = false
		nxt.next_sample = 0
		p.cur = 1 - p.cur
		p.prev_alive = false
		sync.lock(&p.status_mutex)
		p.st.next_serial = nxt.source.serial
		sync.unlock(&p.status_mutex)
	}
	sl := &p.slots[p.cur]
	if sl.source.kind == .None {
		return
	}
	at := max(target, 0)
	if sl.total > 0 {
		at = min(at, sl.total)
	}
	slot_close(sl)
	sl.finished = false
	sl.next_sample = at
	p.end_pushed = false
	mark_push(&p.marks, {at = sync.atomic_load(&p.pcm.write), serial = sl.source.serial, sample = at, seek_id = id})
	ring_flush(&p.pcm)
	if !p.device_running {
		bookkeep_stopped(p)
	}
	p.wake_ui()
}

// step does one unit of work and says whether there is more to do right
// away. It returns false when waiting: for room in the ring, for commands,
// or for nothing at all.
@(private = "file")
step :: proc(p: ^Player) -> bool {
	sl := &p.slots[p.cur]
	if sl.source.kind == .None {
		return false
	}
	if sl.finished {
		return advance(p)
	}
	if sl.source.kind == .Flac && sl.decoder == nil {
		if !slot_open(p, sl) {
			return true // a command interrupted it, or it failed and advance comes next
		}
	} else if sl.source.kind == .Tone && sl.rate == 0 {
		sl.rate, sl.channels = 44100, 2
		sl.total = i64(sl.source.seconds * 44100)
	}
	if !format_ready(p, sl) {
		return false
	}
	if ring_free_frames(&p.pcm) < CHUNK {
		sync.atomic_store(&p.waiting_space, true)
		// The callback may have freed room between the check and the flag.
		return ring_free_frames(&p.pcm) >= CHUNK
	}
	decode_chunk(p, sl)
	return true
}

// advance moves to the next slot once the current one has nothing left.
@(private = "file")
advance :: proc(p: ^Player) -> bool {
	other := &p.slots[1 - p.cur]
	if !p.prev_alive && other.source.kind != .None {
		p.cur = 1 - p.cur
		p.prev_alive = true
		nxt := &p.slots[p.cur]
		nxt.next_sample = 0
		nxt.finished = false
		mark_push(&p.marks, {at = sync.atomic_load(&p.pcm.write), serial = nxt.source.serial})
		p.end_pushed = false
		sync.lock(&p.status_mutex)
		p.st.next_serial = 0
		p.st.want_next = false
		sync.unlock(&p.status_mutex)
		// The end may have played already and stopped the device.
		if !p.device_running {
			bookkeep_stopped(p)
		}
		update_device(p)
		return true
	}
	if !p.end_pushed && !p.prev_alive {
		cur := &p.slots[p.cur]
		mark_push(&p.marks, {at = sync.atomic_load(&p.pcm.write), serial = cur.source.serial, sample = cur.next_sample, end = true})
		p.end_pushed = true
	}
	return false
}

// format_ready opens the device for the slot's rate and channels. A change
// waits until the ring has played out, then reopens: a short gap.
@(private = "file")
format_ready :: proc(p: ^Player, sl: ^Slot) -> bool {
	if p.device_open && p.device_rate == sl.rate && p.device_channels == sl.channels {
		return true
	}
	if p.device_running && ring_buffered(&p.pcm) > 0 {
		return false // the TICK wait comes back to check
	}
	// Paused at the change: what's left of the old track would play at the
	// wrong rate, so it goes.
	ring_flush(&p.pcm)
	device_close(p)
	if !device_open(p, sl.rate, sl.channels) {
		slot_fail(p, sl, 0, "couldn't open the audio device")
		return false
	}
	update_device(p)
	return true
}

// update_device starts or stops the device to match the pause state and
// whether anything is left to play.
@(private = "file")
update_device :: proc(p: ^Player) {
	if !p.device_open {
		return
	}
	want := !p.paused && !current_mark(p).end
	if want && !p.device_running {
		ring_skip_flush(&p.pcm)
		if ma.device_start(p.device) == .SUCCESS {
			p.device_running = true
		}
	} else if !want && p.device_running {
		ma.device_stop(p.device)
		p.device_running = false
		bookkeep_stopped(p)
	}
}

@(private = "file")
current_mark :: proc(p: ^Player) -> Mark {
	n := sync.atomic_load(&p.pub_mark)
	return p.marks.items[(n - 1) % MARKS] if n > 0 else {}
}

// after_step publishes status, drains the capture, frees the previous
// track's slot once its tail has played, wakes the UI on a new mark or every
// TICK while playing, and stops the device at the end of the queue.
@(private = "file")
after_step :: proc(p: ^Player) {
	m := current_mark(p)
	cur := &p.slots[p.cur]
	if p.prev_alive && m.serial == cur.source.serial {
		other := &p.slots[1 - p.cur]
		slot_close(other)
		stream_clear(&other.stream)
		other.source = {}
		p.prev_alive = false
		if p.has_pending {
			pn := p.pending_next
			p.pending_next = {}
			p.has_pending = false
			do_set_next(p, pn)
			delete(pn.url, runtime.heap_allocator())
		}
	}
	if m.end && p.device_running && ring_buffered(&p.pcm) == 0 {
		update_device(p)
	}

	want := false
	if cur.source.kind != .None && !p.prev_alive && p.slots[1 - p.cur].source.kind == .None && cur.rate > 0 {
		left := f64(cur.total - cur.next_sample) / f64(cur.rate)
		want = (cur.source.kind == .Flac && stream_done(&cur.stream)) || (cur.total > 0 && left < WANT_NEXT_SECONDS) || cur.finished
	}
	sync.lock(&p.status_mutex)
	changed := want != p.st.want_next
	p.st.want_next = want
	p.st.buffering = p.device_running && ring_buffered(&p.pcm) == 0 && !m.end
	if cur.rate > 0 && cur.source.serial == m.serial {
		p.st.rate = cur.rate
		p.st.total = cur.total
		p.st_serial = m.serial
	}
	sync.unlock(&p.status_mutex)

	capture_drain(p)

	if id, d, ok := seek_latency(p); ok && id != p.seek_logged {
		p.seek_logged = id
		fmt.eprintfln("audio: seek %d: %.1f ms to the first frame from the new position", id, time.duration_milliseconds(d))
	}

	n := sync.atomic_load(&p.pub_mark)
	rate := max(cur.rate, 1)
	tick := sync.atomic_load(&p.pub_sample) * 4 / i64(rate)
	if changed || n != p.ui_mark || (p.device_running && tick != p.ui_tick) {
		p.ui_mark = n
		p.ui_tick = tick
		p.wake_ui()
	}
}

@(private = "file")
slot_fail :: proc(p: ^Player, sl: ^Slot, http_status: int, msg: string) {
	sl.failed = true
	sl.finished = true
	sync.lock(&p.status_mutex)
	e := &p.st.error
	e.serial = sl.source.serial
	e.http_status = http_status
	e.len = copy(e.buf[:], msg)
	sync.unlock(&p.status_mutex)
	fmt.eprintfln("audio: track %d failed: %s", sl.source.serial, msg)
	p.wake_ui()
}

// slot_open reads the FLAC header, finds the frame to start from for
// next_sample and opens the decoder there. False if interrupted by a
// command or failed (then finished is set).
@(private = "file")
slot_open :: proc(p: ^Player, sl: ^Slot) -> bool {
	st := &sl.stream
	sl.failed = false
	if !st.has_header {
		if !read_header(p, sl) {
			return false
		}
	}
	h := &st.header
	sl.rate = h.info.sample_rate
	sl.channels = h.info.channels
	sl.total = h.info.total_samples
	if sl.total == 0 {
		sl.total = i64(sl.source.seconds * f64(sl.rate))
		h.info.total_samples = sl.total
	}
	target := clamp(sl.next_sample, 0, max(sl.total, 0))
	frame_off, frame_sample := i64(h.audio_start), i64(0)
	if target > 0 {
		off, sample, ok := find_start(p, sl, target)
		if !ok {
			return false
		}
		frame_off, frame_sample = off, sample
	}
	sl.frame_off = frame_off
	sl.next_sample = frame_sample
	sl.discard = target - frame_sample
	sl.vpos = 0
	stream_restart(st, frame_off)

	dec := new(ma.decoder, runtime.heap_allocator())
	cfg := ma.decoder_config_init(.f32, 0, 0)
	cfg.encodingFormat = .flac
	if r := ma.decoder_init(vread, vseek, sl, &cfg, dec); r != .SUCCESS {
		free(dec, runtime.heap_allocator())
		if sl.interrupted {
			sl.interrupted = false
			return false
		}
		if !sl.failed {
			slot_fail(p, sl, 0, fmt.tprintf("can't decode this FLAC (%v)", r))
		}
		return false
	}
	sl.decoder = dec
	return true
}

@(private = "file")
slot_close :: proc(sl: ^Slot) {
	if sl.decoder != nil {
		ma.decoder_uninit(sl.decoder)
		free(sl.decoder, runtime.heap_allocator())
		sl.decoder = nil
	}
	sl.interrupted = false
}

// read_header reads the metadata blocks from the start of the file.
@(private = "file")
read_header :: proc(p: ^Player, sl: ^Slot) -> bool {
	st := &sl.stream
	heap := runtime.heap_allocator()
	buf := make([dynamic]u8, 0, 64 << 10, heap)
	defer delete(buf)
	chunk: [16 << 10]u8
	for {
		n, res := stream_read(st, i64(len(buf)), chunk[:], interrupt, p)
		append(&buf, ..chunk[:n])
		#partial switch res {
		case .Interrupted:
			return false
		case .Failed:
			status, msg := stream_error(st, chunk[:96])
			slot_fail(p, sl, status, fmt.tprintf("download failed: %s", msg))
			return false
		}
		switch parse_flac_header(buf[:], &st.header) {
		case .Ok:
			h := &st.header
			// The decoder sees the header and then frames from wherever a
			// seek put us. It must not stop at the file's sample count
			// counted from the first frame it sees, so that goes to 0
			// (unknown) in its copy.
			st.head = make([]u8, h.audio_start, heap)
			copy(st.head, buf[:h.audio_start])
			s := h.streaminfo
			st.head[s + 13] &= 0xf0
			st.head[s + 14], st.head[s + 15], st.head[s + 16], st.head[s + 17] = 0, 0, 0, 0
			st.has_header = true
			return true
		case .Invalid:
			slot_fail(p, sl, 0, "not a FLAC file")
			return false
		case .Need_More:
			if res == .Eof {
				slot_fail(p, sl, 0, "the file ends inside its header")
				return false
			}
		}
	}
}

// find_start finds the frame to decode from for target: the last frame
// that starts at or before it, within about NEAR_SECONDS. It narrows a
// bracket (seekpoints, or the whole file) by probing guessed offsets for a
// frame header. Usually the first probe lands, and its bytes are the ones
// playback then continues from, so a seek costs one request.
@(private = "file")
find_start :: proc(p: ^Player, sl: ^Slot, target: i64) -> (offset, sample: i64, ok: bool) {
	st := &sl.stream
	h := &st.header
	length := st.length if st.length > 0 else i64(h.audio_start) + sl.total * i64(h.info.channels * h.info.bits / 8)
	b := seek_bounds(h, target, length)
	near := i64(NEAR_SECONDS * f64(h.info.sample_rate))
	lead := i64(h.info.sample_rate / 10)
	buf := make([dynamic]u8, 0, 64 << 10, context.temp_allocator)
	for _ in 0 ..< 8 {
		if target - b.lo_sample <= near {
			break
		}
		guess := seek_guess(b, target, lead)
		if guess <= b.lo_offset || guess >= b.hi_offset {
			break
		}
		clear(&buf)
		found := false
		for len(buf) < 1 << 20 {
			chunk: [16 << 10]u8
			n, res := stream_read(st, guess + i64(len(buf)), chunk[:], interrupt, p)
			append(&buf, ..chunk[:n])
			if res == .Interrupted {
				return 0, 0, false
			}
			if res == .Failed {
				status, msg := stream_error(st, chunk[:96])
				slot_fail(p, sl, status, fmt.tprintf("download failed: %s", msg))
				return 0, 0, false
			}
			rel, s, fst := find_frame(buf[:], h.info, res == .Eof)
			if fst == .Ok {
				seek_update(&b, target, s, guess + i64(rel))
				found = true
				break
			}
			if fst == .Invalid || res == .Eof {
				break
			}
		}
		if !found {
			// No frame between the guess and the upper bound: the frame
			// before it is the one.
			b.hi_offset = guess
			continue
		}
		lead *= 2
	}
	return b.lo_offset, b.lo_sample, true
}

// interrupt runs while a read waits for bytes: light commands go through,
// a heavy one makes the read give up.
@(private = "file")
interrupt :: proc(data: rawptr) -> bool {
	p := (^Player)(data)
	return !run_commands(p, false)
}

// dr_flac's view of a slot: the header, then the file from frame_off on.

@(private = "file")
vread :: proc "c" (dec: ^ma.decoder, out: rawptr, n: c.size_t, read: ^c.size_t) -> ma.result {
	context = runtime.default_context()
	sl := (^Slot)(dec.pUserData)
	st := &sl.stream
	dst := ([^]u8)(out)[:n]
	done := 0
	head := i64(len(st.head))
	if sl.vpos < head {
		k := copy(dst, st.head[sl.vpos:])
		done += k
		sl.vpos += i64(k)
	}
	if done < len(dst) {
		got, res := stream_read(st, sl.frame_off + sl.vpos - head, dst[done:], interrupt, sl.player)
		done += got
		sl.vpos += i64(got)
		#partial switch res {
		case .Interrupted:
			sl.interrupted = true
		case .Failed:
			status, msg := stream_error(st, make([]u8, 96, context.temp_allocator))
			slot_fail(sl.player, sl, status, fmt.tprintf("download failed: %s", msg))
		}
	}
	read^ = c.size_t(done)
	return .SUCCESS if done > 0 else .AT_END
}

@(private = "file")
vseek :: proc "c" (dec: ^ma.decoder, offset: i64, origin: ma.seek_origin) -> ma.result {
	sl := (^Slot)(dec.pUserData)
	switch origin {
	case .start:
		sl.vpos = offset
	case .current:
		sl.vpos += offset
	case .end:
		return .INVALID_OPERATION
	}
	return .SUCCESS
}

@(private = "file")
decode_chunk :: proc(p: ^Player, sl: ^Slot) {
	ch := sl.channels
	buf := p.scratch[:CHUNK * ch]
	frames: u64
	if sl.source.kind == .Tone {
		frames = u64(min(i64(CHUNK), sl.total - sl.next_sample))
		w := 2 * math.PI * f64(sl.source.tone_hz) / f64(sl.rate)
		for i in 0 ..< int(frames) {
			v := f32(0.2 * math.sin(w * f64(sl.next_sample + i64(i))))
			for c in 0 ..< ch {
				buf[i * ch + c] = v
			}
		}
	} else {
		ma.decoder_read_pcm_frames(sl.decoder, raw_data(buf), CHUNK, &frames)
		if sl.interrupted {
			// A command cut the read short; the decoder is reopened for it.
			sl.interrupted = false
			slot_close(sl)
			return
		}
	}
	if frames == 0 {
		sl.finished = true
		return
	}
	out := buf[:int(frames) * ch]
	drop := min(sl.discard, i64(frames))
	sl.discard -= drop
	out = out[int(drop) * ch:]
	for &v in out {
		v *= sl.source.gain
	}
	ring_write(&p.pcm, out)
	sl.next_sample += i64(frames)
}

// The device.

@(private = "file")
device_open :: proc(p: ^Player, rate, channels: int) -> bool {
	heap := runtime.heap_allocator()
	if p.pcm.channels != channels {
		delete(p.pcm_data, heap)
		p.pcm_data = make([]f32, RING_FRAMES * channels, heap)
		w := p.pcm.write
		ring_init(&p.pcm, p.pcm_data, RING_FRAMES, channels)
		// Positions carry on, so marks pushed before still line up.
		p.pcm.write, p.pcm.read, p.pcm.flush_to = w, w, w
	}
	cfg := ma.device_config_init(.playback)
	cfg.playback.format = .f32
	cfg.playback.channels = u32(channels)
	cfg.sampleRate = u32(rate)
	cfg.dataCallback = audio_callback
	cfg.pUserData = p
	cfg.noPreSilencedOutputBuffer = true
	if p.null_output && p.null_ctx == nil {
		p.null_ctx = new(ma.context_type, heap)
		backends := [1]ma.backend{.null}
		if r := ma.context_init(&backends[0], 1, nil, p.null_ctx); r != .SUCCESS {
			fmt.eprintfln("audio: no null backend: %v", r)
			free(p.null_ctx, heap)
			p.null_ctx = nil
			return false
		}
	}
	if r := ma.device_init(p.null_ctx, &cfg, p.device); r != .SUCCESS {
		fmt.eprintfln("audio: device_init failed: %v", r)
		return false
	}
	p.device_open = true
	p.device_rate = rate
	p.device_channels = channels
	capture_begin(p, rate, channels)
	fmt.eprintfln("audio: %s device open at %d Hz, %d channels", "null" if p.null_output else "output", rate, channels)
	return true
}

@(private = "file")
device_close :: proc(p: ^Player) {
	if !p.device_open {
		return
	}
	ma.device_uninit(p.device)
	p.device_open = false
	p.device_running = false
	bookkeep_stopped(p)
}

// bookkeep_stopped does the callback's bookkeeping while the device is
// stopped, so a seek or a new track shows up in the status.
@(private = "file")
bookkeep_stopped :: proc(p: ^Player) {
	ring_skip_flush(&p.pcm)
	publish(p, sync.atomic_load(&p.pcm.read))
}

// publish adopts the marks up to ring position rd and stores the position.
@(private = "file")
publish :: proc "contextless" (p: ^Player, rd: u64) -> bool {
	changed := mark_advance(&p.marks, rd)
	m := p.marks.cur
	sync.atomic_store(&p.pub_sample, m.sample + i64(rd - min(rd, m.at)) if !m.end else m.sample)
	sync.atomic_store(&p.pub_mark, sync.atomic_load(&p.marks.read))
	return changed
}

@(private = "file")
audio_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	p := (^Player)(device.pUserData)
	out := ([^]f32)(output)
	ch := u64(p.pcm.channels)
	target := transmute(f32)sync.atomic_load(&p.volume_bits)
	n := ring_read(&p.pcm, out, u64(frame_count), p.cb_gain, target)
	p.cb_gain = target
	for i in n * ch ..< u64(frame_count) * ch {
		out[i] = 0
	}
	before := p.marks.cur.seek_id
	publish(p, sync.atomic_load(&p.pcm.read))
	m := p.marks.cur
	if n < u64(frame_count) && !m.end {
		sync.atomic_add(&p.underruns, 1)
	}
	// The first frames of a seek: note when, for the latency log.
	if m.seek_id != before {
		sync.atomic_store(&p.pub_seek_tick, 0)
	}
	if m.seek_id != 0 && n > 0 && sync.atomic_load(&p.pub_seek_tick) == 0 {
		sync.atomic_store(&p.pub_seek_tick, time.tick_now()._nsec)
		sync.atomic_store(&p.pub_seek_id, m.seek_id)
	}
	if p.capture.capacity > 0 && p.capture.channels == int(ch) {
		ring_write(&p.capture, out[:u64(frame_count) * ch])
	}
	if sync.atomic_load(&p.waiting_space) && ring_free_frames(&p.pcm) >= RING_FRAMES / 4 {
		sync.atomic_store(&p.waiting_space, false)
		sync.atomic_sema_post(&p.sema)
	}
}

// The capture file: a WAV of 32-bit floats, with sizes filled in when it
// closes.

@(private = "file")
capture_begin :: proc(p: ^Player, rate, channels: int) {
	if p.capture_fd < 0 || p.capture_rate != 0 {
		return
	}
	p.capture_rate = rate
	p.capture_ch = channels
	p.capture.channels = channels
	header := wav_header(rate, channels, 0)
	posix.write(p.capture_fd, raw_data(header[:]), len(header))
}

@(private = "file")
capture_drain :: proc(p: ^Player) {
	if p.capture_fd < 0 || p.capture_rate == 0 {
		return
	}
	buf: [CHUNK * 2]f32
	for {
		frames := u64(len(buf) / p.capture_ch)
		n := ring_read(&p.capture, raw_data(buf[:]), frames, 1, 1)
		if n == 0 {
			break
		}
		posix.write(p.capture_fd, ([^]u8)(raw_data(buf[:])), uint(n) * uint(p.capture_ch) * size_of(f32))
		p.capture_frames += i64(n)
	}
}

@(private = "file")
capture_close :: proc(p: ^Player) {
	if p.capture_fd < 0 {
		return
	}
	capture_drain(p)
	if p.capture_rate != 0 {
		header := wav_header(p.capture_rate, p.capture_ch, p.capture_frames)
		posix.lseek(p.capture_fd, 0, .SET)
		posix.write(p.capture_fd, raw_data(header[:]), len(header))
	}
	posix.close(p.capture_fd)
	p.capture_fd = -1
}

// wav_header is a 44-byte header for IEEE float samples.
wav_header :: proc(rate, channels: int, frames: i64) -> [44]u8 {
	h: [44]u8
	data := u32(frames * i64(channels) * 4)
	put32 :: proc(b: []u8, v: u32) {
		b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
	put16 :: proc(b: []u8, v: u16) {
		b[0], b[1] = u8(v), u8(v >> 8)
	}
	copy(h[0:], "RIFF")
	put32(h[4:], 36 + data)
	copy(h[8:], "WAVEfmt ")
	put32(h[16:], 16)
	put16(h[20:], 3) // IEEE float
	put16(h[22:], u16(channels))
	put32(h[24:], u32(rate))
	put32(h[28:], u32(rate * channels * 4))
	put16(h[32:], u16(channels * 4))
	put16(h[34:], 32)
	copy(h[36:], "data")
	put32(h[40:], data)
	return h
}
