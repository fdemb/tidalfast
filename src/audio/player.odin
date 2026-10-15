package audio

// The player: one decode thread, a fetch thread per track slot, and the
// device's audio callback.
//
//     fetch threads --bytes--> Stream windows --> decode thread --frames--> Pcm_Ring --> audio callback
//
// The decode thread owns the slots, the decoders and the device. It reads a
// slot's bytes through dr_flac, applies the track's ReplayGain and writes
// float frames into the ring. The callback copies frames out and applies the
// volume. It never locks, allocates, logs or makes a system call: the ring
// and the marks are lock-free, and it doesn't wake the decode thread. While
// the device runs, the decode thread wakes on a timer instead and tops the
// ring up; when nothing plays it sleeps until a command or bytes arrive.
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
// A DASH track (TIDAL's hi-res) arrives as fragmented MP4 segments. The
// fetch thread downloads them in order into the same kind of window, and
// the decoder sees the FLAC stream inside: "fLaC" and the metadata blocks
// from the initialization segment, then the frames from each fragment
// (fmp4.odin). A seek starts again at the segment holding the target.
//
// Output goes through miniaudio, which plays at whatever rate the device
// runs at and converts. In bit-perfect mode it goes to the CoreAudio HAL
// instead (coreaudio.odin): the device is switched to the track's rate,
// ReplayGain and the volume are skipped, and the samples reach the device
// as they were decoded. A rate change between tracks lets the ring play
// out, re-clocks the device and starts again: a short gap. Tracks at the
// same rate stay gapless.
//
// All of it runs code from the app dylib, so the app destroys the player
// before a hot reload and makes a new one after. See src/app/player.odin.

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
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
LOW_WATER :: RING_FRAMES / 4 // the decode thread checks the ring before this much has played

foreign import libsystem "system:System"

@(private = "file")
Timebase :: struct {
	numer, denom: u32,
}

@(private = "file", default_calling_convention = "c")
foreign libsystem {
	// Reads the commpage, so the audio callback can call it: no system call.
	mach_absolute_time :: proc() -> u64 ---
	mach_timebase_info :: proc(info: ^Timebase) -> c.int ---
}

Source_Kind :: enum u8 {
	None,
	Flac, // a FLAC file over HTTP
	Dash, // FLAC in fragmented MP4 segments over HTTP
	Tone, // a sine wave, for TIDALFAST_FAKE
}

// Segment is a DASH media segment: its URL and its first sample, in the
// source's timescale.
Segment :: struct {
	url:   string,
	start: i64,
}

// Source is one track for the player. The app picks a serial for each,
// unique and increasing; the status reports serials so the app can tell
// which track is audible.
Source :: struct {
	kind:      Source_Kind,
	serial:    u64,
	url:       string, // Flac: the file; Dash: the initialization segment; copied
	segments:  []Segment, // Dash; copied
	timescale: i64, // Dash: units of Segment.start per second
	dash_end:  i64, // Dash: the end of the last segment, in timescale units
	gain:      f32, // linear, ReplayGain already worked out
	seconds:   f64, // the length the app knows, used until the file says
	tone_hz:   f32,
}

// Output is how the player reaches the device.
Output :: struct {
	bit_perfect: bool, // HAL output at the track's rate, no gain or volume
	hog:         bool, // with bit_perfect: take the device for this app alone
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
	bits:        int, // the audible source's bit depth, 0 if unknown
	device:      Device_Info,
	change:      Device_Change, // what bit-perfect output has changed on a device, rate 0 for nothing
	losses:      u32, // times the output device went away or moved and the output reopened
}

// Device_Info describes the open output.
Device_Info :: struct {
	bit_perfect: bool, // the HAL path is in use: no conversion, gain or volume
	hogged:      bool,
	rate:        int, // the device's rate, 0 when closed
	bits:        int, // the physical format's bits per sample
	float:       bool, // the physical format is floating point
	// Why bit-perfect output was asked for and isn't in use.
	reason:      [64]u8,
	reason_len:  int,
}

device_reason :: proc(d: ^Device_Info) -> string {
	return string(d.reason[:d.reason_len])
}

// Device_Watch is where the CoreAudio listeners leave their news for the
// decode thread, and the semaphore the decode thread sleeps on. A listener
// may still be running after it's removed, so it touches nothing but the
// watch, and the watch is never freed. Clearing a pointer to the Player
// before removal wouldn't do: a listener that loaded it just before could
// still post to the freed Player. Once the player is destroyed nobody
// waits on the semaphore, and a late post to it does nothing.
@(private)
Device_Watch :: struct {
	sema:            sync.Atomic_Sema, // the decode thread's wake-up: commands, fetch threads, listeners
	device_changed:  bool, // the HAL device's alive state changed (atomic)
	default_changed: bool, // the system's default output changed (atomic)
	lost_for_test:   bool, // simulate_device_loss (atomic)
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
	source:      Source, // its url and segments aren't kept: the stream has them
	stream:      Stream,
	decoder:     ^ma.decoder, // heap, nil when closed
	vpos:        i64, // dr_flac's position in the stream it sees: header, then frames from frame_off
	frame_off:   i64,
	next_sample: i64, // sample of the next frame the decoder returns
	discard:     i64, // frames to drop before output, after a seek
	rate:        int,
	channels:    int,
	bits:        int,
	total:       i64,
	finished:    bool, // nothing more to decode
	interrupted: bool,
	failed:      bool,
	dash:        Dash_Demux,
}

// Dash_Demux follows a DASH slot's byte stream box by box and hands the
// decoder the FLAC frames in it. Offsets are the stream's, which start at
// 0 at the segment the stream last started from.
@(private)
Dash_Demux :: struct {
	starts:      [dynamic]i64, // each media segment's first sample, in the source's timescale; heap
	init:        Mp4_Init, // flac_head is in stream.head instead
	pos:         i64, // the next box header
	moof:        i64, // where the current fragment's moof starts
	covered:     i64, // where its samples end
	samples:     [dynamic]Mp4_Sample, // the current fragment's; heap
	sample:      int, // the next one to read
	consumed:    i64, // bytes of it read
	fpos:        i64, // frame bytes handed out since the decoder opened
	after_init:  bool, // the stream is right after the init segment, at the first media segment
	target:      i64, // the sample the decoder was opened for
	synced:      bool, // the first fragment's tfdt has set next_sample
	box:         [dynamic]u8, // a moof being read; heap
}

@(private)
Commands :: struct {
	play:         Maybe(Source),
	play_at:      i64,
	play_paused:  bool,
	seek:         Maybe(i64),
	seek_serial:  u64, // the source the seek is for; it's dropped if that isn't playing
	seek_id:      u32,
	next:         Maybe(Source), // kind None clears it
	paused:       Maybe(bool),
	output:       Maybe(Output),
	quit:         bool,
	seek_tick:    u64, // mach_absolute_time
}

Player :: struct {
	wake_ui:         proc "c" (),
	logger:          runtime.Logger, // the creator's, for the decode thread
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
	output:          Output,
	hal:             Hal,
	hal_scratch:     []f32, // for devices whose buffers don't match the ring's layout
	watch:           ^Device_Watch, // heap, never freed
	alive_device:    Audio_Object_ID, // the device whose alive state is listened to, 0 for none
	using_hal:       bool, // the open device is hal, not miniaudio's
	device_open:     bool,
	device_running:  bool,
	device_rate:     int,
	device_channels: int,
	device_bits:     int,
	draining:        bool, // a format change waits for the ring to play out
	reclock_from:    u64, // mach_absolute_time of the old device's last frames, at a re-clock
	reclock_rates:   [2]int,
	end_pushed:      bool,
	scratch:         []f32,
	ui_tick:         i64,
	ui_mark:         u64,
	seek_tick:       u64, // mach_absolute_time of the last seek command
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
	// stopped), read by anyone. pub_seq is odd while pub_mark, the current
	// mark's fields and pub_sample change; see published.
	cb_gain:         f32,
	bypass:          bool, // bit-perfect: the callback leaves the volume out
	first_tick:      u64, // mach_absolute_time of the first callback with frames since the device opened
	last_tick:       u64, // and of the latest
	pub_seq:         u64,
	pub_mark:        u64, // marks adopted so far; the current one is pub_mark-1
	pub_serial:      u64, // the current mark's serial, seek_id and end
	pub_mark_seek:   u32,
	pub_end:         bool,
	pub_sample:      i64,
	pub_seek_tick:   u64, // mach_absolute_time of the first frame after the last seek mark
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
create :: proc(wake_ui: proc "c" (), volume: f32, capture_path := "", window := STREAM_WINDOW, null_output := false, output := Output{}) -> ^Player {
	heap := runtime.heap_allocator()
	p := new(Player, heap)
	p.wake_ui = wake_ui
	p.logger = context.logger
	p.null_output = null_output
	p.output = output
	p.capture_fd = -1
	set_volume(p, volume)
	p.scratch = make([]f32, CHUNK * 8, heap)
	p.hal_scratch = make([]f32, HAL_MAX_FRAMES * 8, heap)
	p.device = new(ma.device, heap)
	p.watch = new(Device_Watch, heap)
	if !null_output {
		listen(SYSTEM_OBJECT, PROP_DEFAULT_OUTPUT, device_listener, p.watch)
	}
	if capture_path != "" {
		p.capture_fd = posix.open(strings.clone_to_cstring(capture_path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if p.capture_fd >= 0 {
			cap_data := make([]f32, CAPTURE_FRAMES * 8, heap)
			ring_init(&p.capture, cap_data, CAPTURE_FRAMES, 2)
			log.info("audio: capturing output to", capture_path)
		}
	}
	for &sl in p.slots {
		sl.player = p
		sl.dash.starts = make([dynamic]i64, heap)
		sl.dash.samples = make([dynamic]Mp4_Sample, heap)
		sl.dash.box = make([dynamic]u8, heap)
		stream_init(&sl.stream, &p.watch.sema, max(window, 64 << 10))
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
	sync.atomic_sema_post(&p.watch.sema)
	posix.pthread_join(p.thread)
	if !p.null_output {
		unlisten(SYSTEM_OBJECT, PROP_DEFAULT_OUTPUT, device_listener, p.watch)
	}
	heap := runtime.heap_allocator()
	for &sl in p.slots {
		slot_close(&sl)
		stream_destroy(&sl.stream)
		delete(sl.dash.starts)
		delete(sl.dash.samples)
		delete(sl.dash.box)
	}
	commands_free(&p.cmd)
	source_free(&p.pending_next)
	delete(p.scratch, heap)
	delete(p.hal_scratch, heap)
	delete(p.pcm_data, heap)
	delete(p.capture.data, heap)
	free(p.device, heap)
	free(p, heap)
}

// play replaces whatever plays with source, from sample at. The audio
// stops at once; the new track starts when its first bytes arrive. A seek
// not yet applied goes with the track it was for.
play :: proc(p: ^Player, source: Source, at: i64 = 0, paused := false) {
	sync.lock(&p.cmd_mutex)
	commands_free(&p.cmd)
	p.cmd.play = source_clone(source)
	p.cmd.play_at = at
	p.cmd.play_paused = paused
	p.cmd.paused = nil
	p.cmd.seek = nil
	sync.unlock(&p.cmd_mutex)
	post(p)
}

// stop ends playback and lets the device stop. The status goes back to
// Idle with serial 0.
stop :: proc(p: ^Player) {
	play(p, {}, 0, true)
}

// seek moves the source with this serial to sample, if it is the one
// playing when the command runs. Returns an id that Status.seek_id reaches
// once the audio is from the new position.
seek :: proc(p: ^Player, serial: u64, sample: i64) -> u32 {
	p.next_seek_id += 1
	sync.lock(&p.cmd_mutex)
	p.cmd.seek = sample
	p.cmd.seek_serial = serial
	p.cmd.seek_id = p.next_seek_id
	p.cmd.seek_tick = mach_absolute_time()
	sync.unlock(&p.cmd_mutex)
	post(p)
	return p.next_seek_id
}

// set_next gives the track that follows the current one, for gapless
// playback. A source of kind None clears it.
set_next :: proc(p: ^Player, source: Source) {
	sync.lock(&p.cmd_mutex)
	if old, ok := p.cmd.next.?; ok {
		source_free(&old)
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

// set_output switches between miniaudio and bit-perfect output. The
// current track goes on from where it is, through the new output.
set_output :: proc(p: ^Player, o: Output) {
	sync.lock(&p.cmd_mutex)
	p.cmd.output = o
	sync.unlock(&p.cmd_mutex)
	post(p)
}

when ODIN_TEST {
	// simulate_device_loss makes the decode thread act as if the output
	// device had gone away, as the alive listener would.
	simulate_device_loss :: proc(p: ^Player) {
		sync.atomic_store(&p.watch.lost_for_test, true)
		sync.atomic_sema_post(&p.watch.sema)
	}

	// listener_watch is what CoreAudio hands p's listeners, kept after p
	// is destroyed.
	listener_watch :: proc(p: ^Player) -> rawptr {
		return p.watch
	}

	// run_listener runs the default output listener as CoreAudio would.
	run_listener :: proc "c" (watch: rawptr) {
		address := Property_Address{selector = PROP_DEFAULT_OUTPUT}
		device_listener(SYSTEM_OBJECT, 1, &address, watch)
	}
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
	m, sample := published(p)
	if m.serial != 0 {
		s.serial = m.serial
		s.seek_id = m.seek_id
		if m.end {
			s.state = .Ended
		}
	}
	// Just after a track change the decode thread may not have caught up.
	if s.serial != format_of {
		s.rate, s.total, s.bits = 0, 0, 0
	}
	s.sample = sample
	s.underruns = sync.atomic_load(&p.underruns)
	return s
}

// published reads the callback's current mark and position as one pair.
// The callback makes pub_seq odd before it changes them and even after, so
// a read that saw an odd or changed count tries again. It reads the mark's
// fields from their own atomics, not from the queue, whose slots the decode
// thread reuses.
@(private = "file")
published :: proc(p: ^Player) -> (m: Mark, sample: i64) {
	for {
		seq := sync.atomic_load(&p.pub_seq)
		if seq & 1 != 0 {
			intrinsics.cpu_relax()
			continue
		}
		m.serial = sync.atomic_load(&p.pub_serial)
		m.seek_id = sync.atomic_load(&p.pub_mark_seek)
		m.end = sync.atomic_load(&p.pub_end)
		sample = sync.atomic_load(&p.pub_sample)
		intrinsics.atomic_thread_fence(.Seq_Cst)
		if sync.atomic_load(&p.pub_seq) == seq {
			return
		}
	}
}

// seek_latency returns the time from the last seek command to the first
// frame of audio from the new position, once that frame has played.
seek_latency :: proc(p: ^Player) -> (id: u32, d: time.Duration, ok: bool) {
	id = sync.atomic_load(&p.pub_seek_id)
	t := sync.atomic_load(&p.pub_seek_tick)
	if id == 0 || t == 0 || t < p.seek_tick {
		return
	}
	tb: Timebase
	mach_timebase_info(&tb)
	return id, time.Duration((t - p.seek_tick) * u64(tb.numer) / u64(tb.denom)), true
}

@(private = "file")
post :: proc(p: ^Player) {
	sync.atomic_store(&p.cmd_pending, true)
	sync.atomic_sema_post(&p.watch.sema)
}

// source_clone copies s with its URL and segments on the heap.
source_clone :: proc(s: Source) -> Source {
	heap := runtime.heap_allocator()
	c := s
	c.url = strings.clone(s.url, heap)
	c.segments = nil
	if len(s.segments) > 0 {
		c.segments = make([]Segment, len(s.segments), heap)
		for seg, i in s.segments {
			c.segments[i] = {strings.clone(seg.url, heap), seg.start}
		}
	}
	return c
}

// source_free frees what source_clone copied.
source_free :: proc(s: ^Source) {
	heap := runtime.heap_allocator()
	delete(s.url, heap)
	for seg in s.segments {
		delete(seg.url, heap)
	}
	delete(s.segments, heap)
	s.url = ""
	s.segments = nil
}

@(private = "file")
commands_free :: proc(c: ^Commands) {
	if s, ok := &c.play.?; ok {
		source_free(s)
	}
	if s, ok := &c.next.?; ok {
		source_free(s)
	}
	c.play = nil
	c.next = nil
}

// The decode thread.

@(private = "file")
decode_main :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	p := (^Player)(arg)
	context.logger = p.logger
	for {
		if !run_commands(p, true) {
			break
		}
		check_device(p)
		busy := step(p)
		after_step(p)
		free_all(context.temp_allocator)
		if busy {
			continue
		}
		if p.device_running {
			// The callback doesn't wake this thread, so the wait is short
			// enough that the ring never plays down past LOW_WATER.
			wait := TICK
			if p.device_rate > 0 {
				wait = min(wait, time.Duration(f64(LOW_WATER) / f64(p.device_rate) * f64(time.Second)))
			}
			// At a format change, come back as soon as the ring has played
			// out, so the gap is no longer than it must be.
			if p.draining && p.device_rate > 0 {
				left := f64(ring_buffered(&p.pcm)) / f64(p.device_rate)
				wait = min(wait, time.Duration(left * f64(time.Second)) + time.Millisecond)
			}
			sync.atomic_sema_wait_with_timeout(&p.watch.sema, wait)
		} else {
			sync.atomic_sema_wait(&p.watch.sema)
		}
	}
	device_close(p, restore = true)
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
	if !heavy && (c.quit || c.play != nil || c.seek != nil || c.output != nil) {
		sync.unlock(&p.cmd_mutex)
		return false
	}
	sync.atomic_store(&p.cmd_pending, false)
	quit := c.quit
	play_src, has_play := c.play.?
	play_at, play_paused := c.play_at, c.play_paused
	seek_to, has_seek := c.seek.?
	seek_serial, seek_id, seek_tick := c.seek_serial, c.seek_id, c.seek_tick
	next, has_next := c.next.?
	paused, has_paused := c.paused.?
	output, has_output := c.output.?
	c.play, c.seek, c.next, c.paused, c.output = nil, nil, nil, nil, nil
	sync.unlock(&p.cmd_mutex)

	if quit {
		source_free(&play_src)
		source_free(&next)
		return false
	}
	if has_output && output != p.output {
		do_set_output(p, output)
	}
	if has_play {
		do_play(p, play_src, play_at, play_paused)
		source_free(&play_src)
	}
	if has_next {
		do_set_next(p, next)
		source_free(&next)
	}
	if has_seek {
		do_seek(p, seek_serial, seek_to, seek_id, seek_tick)
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
			slot_assign(&sl, {})
		}
		slot_assign(&p.slots[p.cur], src)
	}
	p.prev_alive = false
	source_free(&p.pending_next)
	p.pending_next = {}
	p.has_pending = false
	p.paused = paused
	p.end_pushed = false
	sl := &p.slots[p.cur]
	sl.discard = 0
	sl.finished = false
	sl.next_sample = at
	// serial 0 is stop: an end mark, so the device stops and the status
	// says Idle.
	mark_push(&p.marks, {at = sync.atomic_load(&p.pcm.write), serial = src.serial, sample = at, end = src.serial == 0})
	ring_flush(&p.pcm)
	if !p.device_running {
		bookkeep_stopped(p)
	}
	sync.lock(&p.status_mutex)
	p.st.state = .Paused if paused else .Playing
	if src.serial == 0 {
		p.st.state = .Idle
	}
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

// slot_assign gives sl a new source, or none, and starts its download.
@(private = "file")
slot_assign :: proc(sl: ^Slot, src: Source) {
	slot_close(sl)
	stream_clear(&sl.stream)
	sl.source = src
	sl.source.url = ""
	sl.source.segments = nil
	sl.finished = false
	sl.next_sample = 0
	sl.discard = 0
	sl.rate, sl.channels, sl.bits, sl.total = 0, 0, 0, 0
	clear(&sl.dash.starts)
	switch src.kind {
	case .Flac:
		stream_open(&sl.stream, src.url)
	case .Dash:
		urls := make([]string, len(src.segments) + 1, context.temp_allocator)
		urls[0] = src.url
		for seg, i in src.segments {
			urls[i + 1] = seg.url
			append(&sl.dash.starts, seg.start)
		}
		stream_open_segments(&sl.stream, urls)
	case .None, .Tone:
	}
}

@(private = "file")
do_set_next :: proc(p: ^Player, src: Source) {
	if p.prev_alive {
		source_free(&p.pending_next)
		p.pending_next = source_clone(src)
		p.has_pending = true
		return
	}
	other := &p.slots[1 - p.cur]
	if other.source.serial == src.serial && src.kind != .None {
		return
	}
	slot_assign(other, src)
	sync.lock(&p.status_mutex)
	p.st.next_serial = src.serial
	p.st.want_next = false
	sync.unlock(&p.status_mutex)
}

// do_set_output closes the device, which puts it back as it was if bit-
// perfect output had changed it, and plays on from the audible position:
// what's in the ring went through the old output's gain.
@(private = "file")
do_set_output :: proc(p: ^Player, o: Output) {
	m, sample := published(p)
	p.output = o
	device_close(p, restore = true)
	if m.serial != 0 && !m.end {
		do_seek(p, m.serial, sample, m.seek_id, 0)
	}
	p.wake_ui()
}

// device_listener is the CoreAudio listener for the default output and the
// HAL device's alive state. It only notes what changed and wakes the
// decode thread, which runs check_device.
@(private = "file")
device_listener :: proc "c" (id: Audio_Object_ID, count: u32, addresses: [^]Property_Address, client: rawptr) -> OS_Status {
	w := (^Device_Watch)(client)
	for a in addresses[:count] {
		if a.selector == PROP_DEFAULT_OUTPUT {
			sync.atomic_store(&w.default_changed, true)
		} else {
			sync.atomic_store(&w.device_changed, true)
		}
	}
	sync.atomic_sema_post(&w.sema)
	return 0
}

// check_device acts on what the listeners saw. If the HAL device went
// away, its output closes with nothing restored: there's nothing left to
// restore. If the system's default output moved to another device while
// this one isn't hogged, the device is put back and let go. Hogging a
// device takes it out of the system's choices, so the default moving then
// is no reason to leave. miniaudio follows the default output by itself. Either way the track plays on from the audible position on the
// default output as it is now; if that can't open, the track fails and the
// player bar says so.
@(private = "file")
check_device :: proc(p: ^Player) {
	w := p.watch
	changed := sync.atomic_exchange(&w.device_changed, false)
	moved := sync.atomic_exchange(&w.default_changed, false)
	lost := sync.atomic_exchange(&w.lost_for_test, false)
	if !p.device_open {
		return
	}
	if p.using_hal {
		lost = lost || (changed && !device_alive(p.hal.device))
		moved = moved && !p.hal.hogged && default_output_device() != p.hal.device
	} else {
		moved = false
	}
	if !lost && !moved {
		return
	}
	m, sample := published(p)
	if lost {
		log.warn("audio: the output device went away")
		device_close(p)
		p.hal = {}
	} else {
		log.info("audio: the default output changed, moving to it")
		device_close(p, restore = true)
	}
	update_change(p)
	sync.lock(&p.status_mutex)
	p.st.losses += 1
	sync.unlock(&p.status_mutex)
	if m.serial != 0 && !m.end {
		do_seek(p, m.serial, sample, m.seek_id, 0)
	}
	p.wake_ui()
}

// update_change publishes what bit-perfect output has changed on the
// device, for the app to keep on disk.
@(private = "file")
update_change :: proc(p: ^Player) {
	c: Device_Change
	h := &p.hal
	if h.device != 0 && h.has_orig && h.rate != 0 {
		c.uid_len = copy(c.uid[:], device_uid(h.device))
		c.orig_rate = h.orig_rate
		c.orig_format = h.orig_format
		c.rate = f64(h.rate)
	}
	sync.lock(&p.status_mutex)
	changed := c != p.st.change
	p.st.change = c
	sync.unlock(&p.status_mutex)
	if changed {
		p.wake_ui()
	}
}

@(private = "file")
do_seek :: proc(p: ^Player, serial: u64, target: i64, id: u32, tick: u64) {
	audible := current_mark(p).serial
	back := p.prev_alive && p.slots[1 - p.cur].source.serial == audible && audible == serial
	if !back && p.slots[p.cur].source.serial != serial {
		return // for a track that no longer plays
	}
	p.seek_tick = tick
	// A seek in the tail of the previous track, after the next has started
	// decoding: go back to it.
	if back {
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
	if (sl.source.kind == .Flac || sl.source.kind == .Dash) && sl.decoder == nil {
		if !slot_open(p, sl) {
			return true // a command interrupted it, or it failed and advance comes next
		}
	} else if sl.source.kind == .Tone && sl.rate == 0 {
		sl.rate, sl.channels, sl.bits = 44100, 2, 16
		sl.total = i64(sl.source.seconds * 44100)
	}
	if !format_ready(p, sl) {
		return false
	}
	if ring_free_frames(&p.pcm) < CHUNK {
		return false // the timed wait in decode_main comes back
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

// format_ready opens the device for the slot's rate and channels, and in
// bit-perfect mode its bit depth. A change waits until the ring has played
// out, then reopens: a short gap.
@(private = "file")
format_ready :: proc(p: ^Player, sl: ^Slot) -> bool {
	bits := sl.bits if p.output.bit_perfect else p.device_bits
	if p.device_open && p.device_rate == sl.rate && p.device_channels == sl.channels && p.device_bits == bits {
		return true
	}
	if p.device_running && ring_buffered(&p.pcm) > 0 {
		p.draining = true
		return false // decode_main's wait comes back once it has played out
	}
	p.draining = false
	// Paused at the change: what's left of the old track would play at the
	// wrong rate, so it goes.
	ring_flush(&p.pcm)
	if p.device_open && p.using_hal {
		p.reclock_from = sync.atomic_load(&p.last_tick)
		p.reclock_rates = {p.device_rate, sl.rate}
	}
	device_close(p)
	opened := device_open(p, sl.rate, sl.channels, sl.bits)
	if !p.using_hal {
		p.reclock_from = 0
	}
	if !opened {
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
	// The audible mark may be the end while a newer one, a track played
	// just as the queue ran out, waits in the ring: that keeps it going.
	newer := sync.atomic_load(&p.marks.write) != sync.atomic_load(&p.pub_mark)
	want := !p.paused && (!current_mark(p).end || newer)
	if want && !p.device_running {
		ring_skip_flush(&p.pcm)
		if p.using_hal {
			p.device_running = hal_start(&p.hal, hal_io_proc, p)
		} else if ma.device_start(p.device) == .SUCCESS {
			p.device_running = true
		}
	} else if !want && p.device_running {
		if p.using_hal {
			hal_stop(&p.hal)
		} else {
			ma.device_stop(p.device)
		}
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
			source_free(&pn)
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
		p.st.bits = cur.bits
		p.st_serial = m.serial
	}
	sync.unlock(&p.status_mutex)

	capture_drain(p)

	if p.reclock_from != 0 {
		if first := sync.atomic_load(&p.first_tick); first != 0 && first > p.reclock_from {
			p.wake_ui()
			log.infof("audio: re-clocked %d -> %d Hz: %.1f ms from the last callback at the old rate to the first at the new; the rate change took %.1f ms", p.reclock_rates[0], p.reclock_rates[1], ticks_ms(first - p.reclock_from), p.hal.settle_ms)
			p.reclock_from = 0
		}
	}

	if id, d, ok := seek_latency(p); ok && id != p.seek_logged {
		p.seek_logged = id
		log.infof("audio: seek %d: %.1f ms to the first frame from the new position", id, time.duration_milliseconds(d))
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
	log.errorf("audio: track %d failed: %s", sl.source.serial, msg)
	p.wake_ui()
}

// slot_open reads the FLAC header, finds the frame to start from for
// next_sample and opens the decoder there. False if interrupted by a
// command or failed (then finished is set).
@(private = "file")
slot_open :: proc(p: ^Player, sl: ^Slot) -> bool {
	if sl.source.kind == .Dash {
		return slot_open_dash(p, sl)
	}
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
	sl.bits = h.info.bits
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
	return decoder_open(p, sl)
}

// decoder_open starts dr_flac on the slot's stream as vread presents it.
@(private = "file")
decoder_open :: proc(p: ^Player, sl: ^Slot) -> bool {
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

// slot_open_dash reads the initialization segment the first time, then
// starts the decoder at the media segment holding next_sample. The first
// fragment's tfdt says exactly which sample its first frame is, and the
// frames before the target are dropped.
@(private = "file")
slot_open_dash :: proc(p: ^Player, sl: ^Slot) -> bool {
	st := &sl.stream
	dm := &sl.dash
	sl.failed = false
	if !st.has_header {
		if !read_init(p, sl) {
			return false
		}
	}
	h := &st.header
	sl.rate = h.info.sample_rate
	sl.channels = h.info.channels
	sl.bits = h.info.bits
	sl.total = h.info.total_samples
	if sl.total == 0 && sl.source.timescale > 0 {
		sl.total = sl.source.dash_end * i64(sl.rate) / sl.source.timescale
	}
	if sl.total == 0 {
		sl.total = i64(sl.source.seconds * f64(sl.rate))
	}
	target := clamp(sl.next_sample, 0, max(sl.total, 0))
	k := dash_segment_index(dm.starts[:], sl.source.timescale, sl.rate, target)
	start := dash_segment_sample(dm.starts[:], sl.source.timescale, sl.rate, k)
	if !(dm.after_init && k == 0) {
		stream_restart_segment(st, k + 1) // url 0 is the initialization segment
		dm.pos = 0
	}
	dm.after_init = false
	dm.moof, dm.covered, dm.sample, dm.consumed, dm.fpos = 0, 0, 0, 0, 0
	clear(&dm.samples)
	dm.target = target
	dm.synced = false
	sl.next_sample = start
	sl.discard = target - start
	sl.vpos = 0
	return decoder_open(p, sl)
}

// read_init reads the initialization segment at the start of a freshly
// opened DASH stream and keeps "fLaC" and the metadata blocks from its dfLa
// as the slot's header.
@(private = "file")
read_init :: proc(p: ^Player, sl: ^Slot) -> bool {
	st := &sl.stream
	dm := &sl.dash
	heap := runtime.heap_allocator()
	buf := make([dynamic]u8, 0, 16 << 10, heap)
	defer delete(buf)
	chunk: [4096]u8
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
		init, used, ist := parse_mp4_init(buf[:], heap)
		switch ist {
		case .Ok:
			head := init.flac_head
			init.flac_head = nil
			if parse_flac_header(head, &st.header) != .Ok {
				delete(head, heap)
				slot_fail(p, sl, 0, "the FLAC header in the MP4 is broken")
				return false
			}
			// As in read_header: the decoder mustn't stop at a sample count
			// counted from wherever it starts.
			s := st.header.streaminfo
			head[s + 13] &= 0xf0
			head[s + 14], head[s + 15], head[s + 16], head[s + 17] = 0, 0, 0, 0
			st.head = head
			st.has_header = true
			dm.init = init
			dm.pos = i64(used)
			dm.after_init = true
			return true
		case .Invalid:
			slot_fail(p, sl, 0, "not FLAC in MP4")
			return false
		case .Need_More:
			if res == .Eof {
				slot_fail(p, sl, 0, "the stream ends inside its initialization segment")
				return false
			}
		}
	}
}

// demux_read fills dst with the FLAC frames of the slot's fragments, in
// order: it reads each moof for the sizes of its samples and copies them
// out of the mdat that follows. Other boxes are skipped.
@(private = "file")
demux_read :: proc(p: ^Player, sl: ^Slot, dst: []u8) -> (n: int, res: Read_Result) {
	st := &sl.stream
	dm := &sl.dash
	for n < len(dst) {
		if dm.sample < len(dm.samples) {
			smp := dm.samples[dm.sample]
			want := min(i64(len(dst) - n), i64(smp.size) - dm.consumed)
			got, r := stream_read(st, dm.moof + smp.offset + dm.consumed, dst[n:n + int(want)], interrupt, p)
			n += got
			dm.consumed += i64(got)
			dm.fpos += i64(got)
			if dm.consumed == i64(smp.size) {
				dm.sample += 1
				dm.consumed = 0
			}
			if r != .Ok {
				return n, r
			}
			continue
		}
		if len(dm.samples) > 0 {
			clear(&dm.samples)
			dm.sample = 0
			dm.pos = max(dm.pos, dm.covered)
		}
		box, r := read_box_header(p, sl, dm.pos)
		if r != .Ok {
			return n, r
		}
		size := box.size
		switch {
		case box.kind == mp4_fourcc("moof"):
			if size < 0 || size > MP4_MAX_BOX {
				slot_fail(p, sl, 0, "a moof box is too big")
				return n, .Failed
			}
			resize(&dm.box, int(size))
			got, rr := stream_read(st, dm.pos, dm.box[:], interrupt, p)
			if rr != .Ok {
				return n, rr
			}
			assert(got == int(size))
			// The samples must be in the mdat right after the moof, which
			// bounds how many there can be.
			mdat, mr := read_box_header(p, sl, dm.pos + size)
			if mr != .Ok {
				if mr == .Eof {
					slot_fail(p, sl, 0, "a moof box without its mdat")
					return n, .Failed
				}
				return n, mr
			}
			if mdat.kind != mp4_fourcc("mdat") || mdat.size < 0 || mdat.size > max(i64) / 2 - (dm.pos + size) {
				slot_fail(p, sl, 0, "a moof box isn't followed by an mdat of known size")
				return n, .Failed
			}
			moof_at := dm.pos - stream_segment_start(st, dm.pos)
			frag, fst := parse_mp4_moof(dm.box[:], &dm.init, &dm.samples, size + i64(mdat.header), size + mdat.size, moof_at)
			if fst != .Ok {
				slot_fail(p, sl, 0, fmt.tprintf("a moof box is broken: %s", frag.reason))
				return n, .Failed
			}
			dm.moof = dm.pos
			dm.pos += size
			dm.covered = dm.pos + mdat.size
			if !dm.synced && frag.has_base_time && dm.init.timescale > 0 {
				// The fragment says which sample it starts at.
				first := i64(frag.base_time) * i64(sl.rate) / i64(dm.init.timescale)
				if first <= dm.target {
					sl.next_sample = first
					sl.discard = dm.target - first
				}
			}
			dm.synced = true
		case box.kind == mp4_fourcc("mdat") && dm.pos >= dm.covered:
			// No moof described it: take the whole payload as frames.
			if size < 0 {
				size = max(i64) / 2
			}
			if size - i64(box.header) > i64(max(u32)) {
				slot_fail(p, sl, 0, "an mdat box is too big")
				return n, .Failed
			}
			dm.moof = dm.pos
			append(&dm.samples, Mp4_Sample{offset = i64(box.header), size = u32(size - i64(box.header))})
			dm.pos += size
			dm.covered = dm.pos
			dm.synced = true
		case:
			if size < 0 {
				return n, .Eof
			}
			if size > max(i64) / 2 - dm.pos {
				slot_fail(p, sl, 0, "an MP4 box is too big")
				return n, .Failed
			}
			dm.pos += size
		}
	}
	return n, .Ok
}

// read_box_header reads the box header at offset, Eof if the stream ends
// there.
@(private = "file")
read_box_header :: proc(p: ^Player, sl: ^Slot, offset: i64) -> (box: Mp4_Box, res: Read_Result) {
	hdr: [16]u8
	got, r := stream_read(&sl.stream, offset, hdr[:8], interrupt, p)
	if r == .Eof || (r == .Ok && got < 8) {
		return {}, .Eof
	}
	if r != .Ok {
		return {}, r
	}
	b, bst := mp4_box_header(hdr[:8])
	if bst == .Need_More {
		got, r = stream_read(&sl.stream, offset + 8, hdr[8:16], interrupt, p)
		if r != .Ok {
			return {}, .Eof if r == .Eof else r
		}
		b, bst = mp4_box_header(hdr[:])
	}
	if bst != .Ok {
		slot_fail(p, sl, 0, "broken MP4 box")
		return {}, .Failed
	}
	return b, .Ok
}

// dash_segment_index is the media segment holding sample target: the last
// whose start, given in timescale units, is at or before it.
dash_segment_index :: proc(starts: []i64, timescale: i64, rate: int, target: i64) -> int {
	lo, hi := 0, len(starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if dash_segment_sample(starts, timescale, rate, mid) <= target {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return max(lo, 0)
}

// dash_segment_sample is segment k's first sample at rate.
dash_segment_sample :: proc(starts: []i64, timescale: i64, rate: int, k: int) -> i64 {
	if k < 0 || k >= len(starts) || timescale <= 0 {
		return 0
	}
	return starts[k] * i64(rate) / timescale
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
	if done < len(dst) && sl.source.kind == .Dash {
		// The frames come out of the fragments in order, so the decoder can
		// only go on from where it is, or skip ahead.
		dm := &sl.dash
		res := Read_Result.Ok
		for dm.fpos < sl.vpos - head && res == .Ok {
			skip: [4096]u8
			_, res = demux_read(sl.player, sl, skip[:min(i64(len(skip)), sl.vpos - head - dm.fpos)])
		}
		if dm.fpos > sl.vpos - head {
			log.warnf("audio: the decoder went back in a DASH stream (%d -> %d)", dm.fpos, sl.vpos - head)
			res = .Failed
		}
		got := 0
		if res == .Ok {
			got, res = demux_read(sl.player, sl, dst[done:])
		}
		done += got
		sl.vpos += i64(got)
		#partial switch res {
		case .Interrupted:
			sl.interrupted = true
		case .Failed:
			if !sl.failed {
				status, msg := stream_error(st, make([]u8, 96, context.temp_allocator))
				slot_fail(sl.player, sl, status, fmt.tprintf("download failed: %s", msg))
			}
		}
	} else if done < len(dst) {
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
	if !p.output.bit_perfect {
		for &v in out {
			v *= sl.source.gain
		}
	}
	ring_write(&p.pcm, out)
	sl.next_sample += i64(frames)
}

// The device.

HAL_MAX_FRAMES :: 8192 // per IOProc call, when the device's buffers need rearranging

@(private = "file")
device_open :: proc(p: ^Player, rate, channels, bits: int) -> bool {
	heap := runtime.heap_allocator()
	if p.pcm.channels != channels {
		delete(p.pcm_data, heap)
		p.pcm_data = make([]f32, RING_FRAMES * channels, heap)
		w := p.pcm.write
		ring_init(&p.pcm, p.pcm_data, RING_FRAMES, channels)
		// Positions carry on, so marks pushed before still line up.
		p.pcm.write, p.pcm.read, p.pcm.flush_to = w, w, w
	}
	sync.atomic_store(&p.first_tick, 0)
	sync.atomic_store(&p.last_tick, 0)
	sync.atomic_store(&p.bypass, p.output.bit_perfect)
	info := Device_Info {
		rate = rate,
		bits = 32,
		float = true,
	}
	hal_ok, reason := false, ""
	if p.output.bit_perfect && !p.null_output {
		hal_ok, reason = hal_open(p, rate, channels, bits)
	}
	if hal_ok {
		info = {
			bit_perfect = true,
			hogged      = p.hal.hogged,
			rate        = rate,
			bits        = int(p.hal.format.bits),
			float       = p.hal.format.format_flags & FLAG_FLOAT != 0,
		}
	} else {
		info.reason_len = copy(info.reason[:], reason)
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
				log.errorf("audio: no null backend: %v", r)
				free(p.null_ctx, heap)
				p.null_ctx = nil
				return false
			}
		}
		if r := ma.device_init(p.null_ctx, &cfg, p.device); r != .SUCCESS {
			log.errorf("audio: device_init failed: %v", r)
			return false
		}
		if !p.null_output {
			info.rate = int(device_nominal_rate(default_output_device()))
		}
		log.infof("audio: %s device open at %d Hz, %d channels", "null" if p.null_output else "output", rate, channels)
	}
	p.device_open = true
	p.device_rate = rate
	p.device_channels = channels
	p.device_bits = bits
	sync.lock(&p.status_mutex)
	p.st.device = info
	sync.unlock(&p.status_mutex)
	update_change(p)
	capture_begin(p, rate, channels)
	return true
}

// hal_open readies the default output device for bit-perfect playback. On
// failure the device is put back as it was, and miniaudio plays instead;
// reason says why.
@(private = "file")
hal_open :: proc(p: ^Player, rate, channels, bits: int) -> (ok: bool, reason: string) {
	// The device the last track played on, until the output is restored.
	// While we hog it, it is no longer the system's default output, so
	// asking for the default again would find another device.
	dev := p.hal.device if p.hal.device != 0 else default_output_device()
	// The IOProc writes the virtual format, 32-bit float, and the HAL
	// converts it to the physical one: exact for an integer format at least
	// as deep as the source, or 32-bit float for up to 24 bits.
	ok, reason = hal_configure(&p.hal, dev, rate, channels, bits, p.output.hog)
	if !ok {
		hal_close(&p.hal, restore = true)
		log.warnf("audio: no bit-perfect output at %d Hz (%s); the system mixer converts it", rate, reason)
		return
	}
	p.hal.channel_map = channel_map_make(channels, device_stereo_channels(dev))
	if listen(dev, PROP_ALIVE, device_listener, p.watch) {
		p.alive_device = dev
	}
	p.using_hal = true
	log.infof("audio: bit-perfect output on %s: %s%s, set in %.1f ms", device_name(dev), format_name(p.hal.format), ", hog mode" if p.hal.hogged else "", p.hal.settle_ms)
	return true, ""
}

// device_close stops and closes the device. With restore, a device that
// bit-perfect output changed gets its rate, format and hog mode back;
// without it they stay for the next track.
@(private = "file")
device_close :: proc(p: ^Player, restore := false) {
	if p.alive_device != 0 {
		unlisten(p.alive_device, PROP_ALIVE, device_listener, p.watch)
		p.alive_device = 0
	}
	if p.device_open {
		if p.using_hal {
			hal_close(&p.hal, restore)
		} else {
			ma.device_uninit(p.device)
		}
		p.device_open = false
		p.device_running = false
		p.using_hal = false
		p.device_rate = 0
		bookkeep_stopped(p)
		sync.lock(&p.status_mutex)
		p.st.device = {}
		sync.unlock(&p.status_mutex)
	}
	if restore {
		hal_close(&p.hal, true)
		update_change(p)
	}
}

// bookkeep_stopped does the callback's bookkeeping while the device is
// stopped, so a seek or a new track shows up in the status.
@(private = "file")
bookkeep_stopped :: proc(p: ^Player) {
	ring_skip_flush(&p.pcm)
	publish(p, sync.atomic_load(&p.pcm.read))
}

// publish adopts the marks up to ring position rd and stores the position.
// The count goes odd before mark_advance, which frees the old mark's slot.
@(private = "file")
publish :: proc "contextless" (p: ^Player, rd: u64) -> bool {
	sync.atomic_add(&p.pub_seq, 1)
	changed := mark_advance(&p.marks, rd)
	m := p.marks.cur
	sync.atomic_store(&p.pub_sample, m.sample + i64(rd - min(rd, m.at)) if !m.end else m.sample)
	sync.atomic_store(&p.pub_serial, m.serial)
	sync.atomic_store(&p.pub_mark_seek, m.seek_id)
	sync.atomic_store(&p.pub_end, m.end)
	sync.atomic_store(&p.pub_mark, sync.atomic_load(&p.marks.read))
	sync.atomic_add(&p.pub_seq, 1)
	return changed
}

// miniaudio's callback. Bit-perfect mode on miniaudio (the null device, or
// a rate the HAL couldn't do) leaves the volume out too.
@(private = "file")
audio_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	p := (^Player)(device.pUserData)
	out := ([^]f32)(output)
	ch := u64(p.pcm.channels)
	target := transmute(f32)sync.atomic_load(&p.volume_bits)
	if sync.atomic_load(&p.bypass) {
		target, p.cb_gain = 1, 1
	}
	n := ring_read(&p.pcm, out, u64(frame_count), p.cb_gain, target)
	p.cb_gain = target
	for i in n * ch ..< u64(frame_count) * ch {
		out[i] = 0
	}
	after_render(p, out, u64(frame_count), n)
}

// hal_io_proc is the HAL's IOProc: the ring's frames as they are, into
// the device's buffers (hal_fill). It keeps the callback's rules: no locks,
// allocation or system calls.
@(private = "file")
hal_io_proc :: proc "c" (device: Audio_Object_ID, now: rawptr, input: ^Audio_Buffer_List, input_time: rawptr, output: ^Audio_Buffer_List, output_time: rawptr, client: rawptr) -> OS_Status {
	p := (^Player)(client)
	frames, n, out := hal_fill(output, &p.pcm, p.hal_scratch, &p.hal.channel_map)
	after_render(p, out, frames, n)
	return 0
}

// after_render is the callbacks' bookkeeping once out has frame_count
// frames, n of them from the ring: marks, the position, underruns, the
// seek latency, the re-clock times and the capture.
@(private = "file")
after_render :: proc "contextless" (p: ^Player, out: [^]f32, frame_count, n: u64) {
	ch := u64(p.pcm.channels)
	before := p.marks.cur.seek_id
	publish(p, sync.atomic_load(&p.pcm.read))
	m := p.marks.cur
	if n < frame_count && !m.end {
		sync.atomic_add(&p.underruns, 1)
	}
	// The first frames of a seek: note when, for the latency log.
	if m.seek_id != before {
		sync.atomic_store(&p.pub_seek_tick, 0)
	}
	if n > 0 {
		t := mach_absolute_time()
		if m.seek_id != 0 && sync.atomic_load(&p.pub_seek_tick) == 0 {
			sync.atomic_store(&p.pub_seek_tick, t)
			sync.atomic_store(&p.pub_seek_id, m.seek_id)
		}
		if sync.atomic_load(&p.first_tick) == 0 {
			sync.atomic_store(&p.first_tick, t)
		}
		sync.atomic_store(&p.last_tick, t)
	}
	if p.capture.capacity > 0 && p.capture.channels == int(ch) {
		ring_write(&p.capture, out[:frame_count * ch])
	}
}

@(private = "file")
ticks_ms :: proc(ticks: u64) -> f64 {
	tb: Timebase
	mach_timebase_info(&tb)
	return f64(ticks) * f64(tb.numer) / f64(tb.denom) / 1e6
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
