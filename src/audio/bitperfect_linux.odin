package audio

// Bit-perfect output on Linux, through a PipeWire stream. libpipewire is
// loaded at run time, so the app starts without it, and the Output menu
// says so when it's missing.
//
// The stream asks for the track's rate with node.rate and forces the graph
// to it with node.force-rate, the way bitperfect_darwin.odin sets the
// device's nominal rate. hal_configure then waits until the graph runs at
// that rate and refuses otherwise. At the same rate PipeWire passes the
// stream's samples through without resampling: 32-bit floats of v / 2^23,
// which PipeWire converts to the sink's integer format exactly. The
// resampler isn't disabled outright (resample.disable): the stream has to
// link while the graph still runs at the old rate, and it never plays a
// frame until the rates match.
//
// What this can't see: a sink whose hardware can't run at the graph's rate
// resamples inside PipeWire, and a software volume on the sink scales the
// samples. Other streams, such as notifications, are resampled to the
// graph's rate and mixed in while they play, as on macOS.
//
// Nothing on the device needs putting back: the graph goes back to its
// default rate once the stream is gone. So there is no Device_Change.

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:reflect"
import "core:sync"
import "core:time"

// BIT_PERFECT says whether this OS has bit-perfect output.
BIT_PERFECT :: true

// Hal is one open PipeWire stream.
Hal :: struct {
	device:      Device_ID,
	out:         ^Pw_Output, // heap; nil when closed
	format:      Stream_Description, // what the stream sends: 32-bit float
	channel_map: Channel_Map, // read by process; set while it's stopped
	settle_ms:   f64, // how long the graph took to reach the rate
}

// PIPEWIRE_DEFAULT is the only Device_ID here: whichever sink PipeWire
// links the stream to. PipeWire moves the stream when the default sink
// changes, so the player never has to.
PIPEWIRE_DEFAULT :: Device_ID(1)

// Pw_Output is what the stream's callbacks see. Heap-allocated, freed only
// after the stream is destroyed, when no callback runs any more.
@(private)
Pw_Output :: struct {
	loop:        rawptr, // pw_thread_loop
	stream:      rawptr, // pw_stream
	rate:        int,
	graph_rate:  u32, // the graph's rate as process last saw it, 0 before (atomic)
	running:     bool, // between hal_start and hal_stop (atomic)
	busy:        bool, // process is rendering (atomic)
	lost:        bool, // the stream failed or the graph left the rate (atomic)
	wrong_since: i64, // process: pw_time.now when the rate went wrong, 0 while right
	player:      ^Player,
	watch:       ^Device_Watch, // atomic; nil when unwatched
}

@(private = "file")
HAL_SETTLE_TIMEOUT :: 2 * time.Second

default_output_device :: proc() -> Device_ID {
	return PIPEWIRE_DEFAULT
}

// device_nominal_rate is 0: miniaudio converts to whatever the sound server
// runs at, and the player reports the track's rate instead.
device_nominal_rate :: proc(dev: Device_ID) -> f64 {
	return 0
}

device_name :: proc(dev: Device_ID) -> string {
	return "PipeWire's default output"
}

// hal_alive is false once the stream has failed, or the graph has left
// the track's rate for longer than it takes to switch.
hal_alive :: proc(h: ^Hal) -> bool {
	return h.out != nil && !sync.atomic_load(&h.out.lost)
}

// The default output needs no watching: PipeWire moves the stream itself.
watch_default_output :: proc(w: ^Device_Watch) -> bool {
	return false
}

unwatch_default_output :: proc(w: ^Device_Watch) {}

// watch_device tells w when hal_alive turns false.
watch_device :: proc(h: ^Hal, w: ^Device_Watch) -> bool {
	if h.out == nil {
		return false
	}
	sync.atomic_store(&h.out.watch, w)
	if sync.atomic_load(&h.out.lost) {
		watch_note(w, default_changed = false, device_changed = true)
	}
	return true
}

unwatch_device :: proc(h: ^Hal, w: ^Device_Watch) {
	if h.out != nil {
		sync.atomic_store(&h.out.watch, nil)
	}
}

// hal_configure opens a stream for rate and channels and waits off the
// main thread, up to HAL_SETTLE_TIMEOUT, until the graph runs at rate. Mono
// and stereo go out as stereo; more channels are refused. bits doesn't
// matter: a float holds up to 24 bits exactly. If the graph doesn't get
// there, ok is false and reason says why, short enough for a menu line.
hal_configure :: proc(h: ^Hal, dev: Device_ID, rate, channels, bits: int) -> (ok: bool, reason: string) {
	hal_close(h, false)
	if channels < 1 || channels > 2 {
		return false, fmt.tprintf("%d channels; PipeWire output is stereo", channels)
	}
	if !pw_load() {
		return false, "PipeWire isn't installed"
	}
	o := new(Pw_Output, runtime.heap_allocator())
	o.rate = rate
	h.out = o
	defer if !ok {
		hal_close(h, false)
	}
	o.loop = pw.thread_loop_new("tidalfast-pipewire", nil)
	if o.loop == nil {
		return false, "PipeWire didn't start"
	}
	items := [?]Spa_Dict_Item {
		{"media.type", "Audio"},
		{"media.category", "Playback"},
		{"media.role", "Music"},
		{"application.name", "TIDALfast"},
		{"node.name", "tidalfast"},
		{"node.rate", fmt.ctprintf("1/%d", rate)},
		{"node.force-rate", "0"},
		// Don't restore a stream volume saved for this app.
		{"state.restore-props", "false"},
	}
	dict := Spa_Dict {
		n_items = len(items),
		items   = &items[0],
	}
	o.stream = pw.stream_new_simple(pw.thread_loop_get_loop(o.loop), "TIDALfast", pw.properties_new_dict(&dict), &pw_events, o)
	if o.stream == nil {
		log.warn("audio: PipeWire refused a new stream")
		return false, "PipeWire refused the stream"
	}
	pod: [32]u64
	params := [1]rawptr{format_pod(&pod, rate)}
	if st := pw.stream_connect(o.stream, SPA_DIRECTION_OUTPUT, PW_ID_ANY, STREAM_FLAGS, &params[0], 1); st < 0 {
		log.warnf("audio: connecting the PipeWire stream failed (%d)", st)
		return false, "PipeWire refused the stream"
	}
	if pw.thread_loop_start(o.loop) < 0 {
		return false, "PipeWire didn't start"
	}
	begin := time.tick_now()
	for {
		if sync.atomic_load(&o.lost) {
			log.warn("audio: the PipeWire stream failed")
			return false, "PipeWire refused the stream"
		}
		graph := int(sync.atomic_load(&o.graph_rate))
		if graph == rate {
			break
		}
		if time.tick_since(begin) > HAL_SETTLE_TIMEOUT {
			if graph == 0 {
				log.warn("audio: the PipeWire stream didn't start")
				return false, "PipeWire didn't start the stream"
			}
			log.warnf("audio: PipeWire stayed at %d Hz instead of %d", graph, rate)
			return false, fmt.tprintf("PipeWire stayed at %s kHz", khz_text(graph))
		}
		time.sleep(2 * time.Millisecond)
	}
	h.settle_ms = time.duration_milliseconds(time.tick_since(begin))
	h.device = dev
	h.format = {
		sample_rate     = f64(rate),
		format_id       = FORMAT_LPCM,
		format_flags    = FLAG_FLOAT,
		bytes_per_frame = 2 * size_of(f32),
		channels        = 2,
		bits            = 32,
	}
	h.channel_map = channel_map_make(channels, {0, 1})
	// Idle until hal_start, so an output opened while paused costs no CPU.
	pw.thread_loop_lock(o.loop)
	pw.stream_set_active(o.stream, false)
	pw.thread_loop_unlock(o.loop)
	return true, ""
}

// hal_start lets process render p's ring (hal_render).
hal_start :: proc(h: ^Hal, p: ^Player) -> bool {
	o := h.out
	if o == nil {
		return false
	}
	o.player = p
	sync.atomic_store(&o.running, true)
	pw.thread_loop_lock(o.loop)
	pw.stream_set_active(o.stream, true)
	pw.thread_loop_unlock(o.loop)
	return true
}

// hal_stop stops rendering. When it returns process no longer touches the
// player, and the stream goes idle so a paused app uses no CPU.
hal_stop :: proc(h: ^Hal) {
	o := h.out
	if o == nil || o.stream == nil {
		return
	}
	sync.atomic_store(&o.running, false)
	for sync.atomic_load(&o.busy) {
		time.sleep(50 * time.Microsecond)
	}
	pw.thread_loop_lock(o.loop)
	pw.stream_set_active(o.stream, false)
	pw.thread_loop_unlock(o.loop)
}

// hal_close destroys the stream. restore doesn't matter: the graph's rate
// goes back by itself.
hal_close :: proc(h: ^Hal, restore: bool) {
	if o := h.out; o != nil {
		hal_stop(h)
		if o.loop != nil {
			if o.stream != nil {
				pw.thread_loop_lock(o.loop)
				pw.stream_destroy(o.stream)
				pw.thread_loop_unlock(o.loop)
			}
			pw.thread_loop_stop(o.loop)
			pw.thread_loop_destroy(o.loop)
		}
		free(o, runtime.heap_allocator())
	}
	h^ = {}
}

hal_device_change :: proc(h: ^Hal) -> Device_Change {
	return {}
}

device_change_undo :: proc(c: ^Device_Change) -> bool {
	return false
}

// pw_process runs on PipeWire's real-time thread for each buffer the
// stream needs. It keeps the IOProc's rules: no locks, allocation, logging
// or system calls. Until the graph runs at the track's rate it sends
// silence and leaves the ring alone; if the rate stays wrong while playing,
// the output is lost and the player opens it again.
@(private = "file")
pw_process :: proc "c" (data: rawptr) {
	o := (^Pw_Output)(data)
	b := pw.stream_dequeue_buffer(o.stream)
	if b == nil {
		return
	}
	d := &b.buffer.datas[0]
	stride := u32(2 * size_of(f32))
	frames := d.maxsize / stride
	if b.requested > 0 {
		frames = min(frames, u32(b.requested))
	}
	t: Pw_Time
	if pw.stream_get_time_n(o.stream, &t, size_of(t)) == 0 && t.rate_denom != 0 {
		sync.atomic_store(&o.graph_rate, t.rate_denom)
	}
	right := sync.atomic_load(&o.graph_rate) == u32(o.rate)
	if right || !sync.atomic_load(&o.running) {
		o.wrong_since = 0
	} else {
		if o.wrong_since == 0 {
			o.wrong_since = max(t.now, 1)
		} else if t.now - o.wrong_since > i64(HAL_SETTLE_TIMEOUT) {
			pw_lose(o)
		}
	}
	size: u32
	if d.data != nil {
		size = frames * stride
		sync.atomic_store(&o.busy, true)
		if right && sync.atomic_load(&o.running) {
			list := Audio_Buffer_List {
				count   = 1,
				buffers = {{channels = 2, size = size, data = d.data}},
			}
			hal_render(o.player, &list)
		} else {
			intrinsics.mem_zero(d.data, int(size))
		}
		sync.atomic_store(&o.busy, false)
	}
	d.chunk.offset = 0
	d.chunk.stride = i32(stride)
	d.chunk.size = size
	pw.stream_queue_buffer(o.stream, b)
}

// pw_state_changed runs on the loop's thread. A stream that fails, or stops
// streaming while it should play, has lost its sink.
@(private = "file")
pw_state_changed :: proc "c" (data: rawptr, old, state: i32, error: cstring) {
	o := (^Pw_Output)(data)
	if state == STREAM_STATE_ERROR || (old == STREAM_STATE_STREAMING && state < STREAM_STATE_PAUSED) {
		pw_lose(o)
	}
}

@(private = "file")
pw_lose :: proc "contextless" (o: ^Pw_Output) {
	if !sync.atomic_exchange(&o.lost, true) {
		if w := sync.atomic_load(&o.watch); w != nil {
			watch_note(w, default_changed = false, device_changed = true)
		}
	}
}

@(private = "file")
pw_events := Pw_Stream_Events {
	version       = 2,
	state_changed = pw_state_changed,
	process       = pw_process,
}

// format_pod writes the stream's one EnumFormat into buf as a SPA pod: raw
// 32-bit float audio, stereo, at rate. libspa builds these with inline
// header functions, so this is the same bytes by hand.
@(private = "file")
format_pod :: proc(buf: ^[32]u64, rate: int) -> rawptr {
	w := ([^]u32)(&buf[0])[:2 * len(buf)]
	n := 0
	put :: proc(w: []u32, n: ^int, v: ..u32) {
		for x in v {
			w[n^] = x
			n^ += 1
		}
		if n^ % 2 == 1 {
			w[n^] = 0
			n^ += 1
		}
	}
	put(w, &n, 0, SPA_TYPE_OBJECT, SPA_TYPE_OBJECT_FORMAT, SPA_PARAM_ENUM_FORMAT)
	put(w, &n, SPA_FORMAT_MEDIA_TYPE, 0, 4, SPA_TYPE_ID, SPA_MEDIA_TYPE_AUDIO)
	put(w, &n, SPA_FORMAT_MEDIA_SUBTYPE, 0, 4, SPA_TYPE_ID, SPA_MEDIA_SUBTYPE_RAW)
	put(w, &n, SPA_FORMAT_AUDIO_FORMAT, 0, 4, SPA_TYPE_ID, SPA_AUDIO_FORMAT_F32_LE)
	put(w, &n, SPA_FORMAT_AUDIO_RATE, 0, 4, SPA_TYPE_INT, u32(rate))
	put(w, &n, SPA_FORMAT_AUDIO_CHANNELS, 0, 4, SPA_TYPE_INT, 2)
	// An array pod: its child pod's header, then the values.
	put(w, &n, SPA_FORMAT_AUDIO_POSITION, 0, 8 + 2 * 4, SPA_TYPE_ARRAY, 4, SPA_TYPE_ID, SPA_AUDIO_CHANNEL_FL, SPA_AUDIO_CHANNEL_FR)
	w[0] = u32(n - 2) * 4 // the object's body, everything after its header
	return &buf[0]
}

// libpipewire, as far as the app uses it. Each field is pw_<name>.
@(private = "file")
Pw_Api :: struct {
	init:                  proc "c" (argc: ^i32, argv: rawptr),
	thread_loop_new:       proc "c" (name: cstring, props: rawptr) -> rawptr,
	thread_loop_destroy:   proc "c" (loop: rawptr),
	thread_loop_start:     proc "c" (loop: rawptr) -> i32,
	thread_loop_stop:      proc "c" (loop: rawptr),
	thread_loop_lock:      proc "c" (loop: rawptr),
	thread_loop_unlock:    proc "c" (loop: rawptr),
	thread_loop_get_loop:  proc "c" (loop: rawptr) -> rawptr,
	properties_new_dict:   proc "c" (dict: ^Spa_Dict) -> rawptr,
	stream_new_simple:     proc "c" (loop: rawptr, name: cstring, props: rawptr, events: ^Pw_Stream_Events, data: rawptr) -> rawptr,
	stream_destroy:        proc "c" (stream: rawptr),
	stream_connect:        proc "c" (stream: rawptr, direction: u32, target: u32, flags: u32, params: [^]rawptr, n_params: u32) -> i32,
	stream_set_active:     proc "c" (stream: rawptr, active: bool) -> i32,
	stream_dequeue_buffer: proc "c" (stream: rawptr) -> ^Pw_Buffer,
	stream_queue_buffer:   proc "c" (stream: rawptr, buffer: ^Pw_Buffer) -> i32,
	stream_get_time_n:     proc "c" (stream: rawptr, time: ^Pw_Time, size: uint) -> i32,
}

@(private = "file")
pw: Pw_Api

@(private = "file")
pw_loaded: Maybe(bool)

// pw_load loads libpipewire once. It's never unloaded: the stream's
// threads may outlive a hot reload's teardown by a moment.
@(private = "file")
pw_load :: proc() -> bool {
	if loaded, tried := pw_loaded.?; tried {
		return loaded
	}
	count, _ := dynlib.initialize_symbols(&pw, "libpipewire-0.3.so.0", "pw_")
	if count != reflect.struct_field_count(Pw_Api) {
		log.warnf("audio: libpipewire-0.3.so.0 isn't there or is too old: %s", dynlib.last_error())
		pw_loaded = false
		return false
	}
	pw.init(nil, nil)
	pw_loaded = true
	return true
}

// The C side, from PipeWire's headers. These layouts have been stable
// since 0.3.50; pw_buffer's requested field is from 0.3.49.

@(private = "file")
Spa_Dict_Item :: struct {
	key:   cstring,
	value: cstring,
}

@(private = "file")
Spa_Dict :: struct {
	flags:   u32,
	n_items: u32,
	items:   [^]Spa_Dict_Item,
}

@(private = "file")
Spa_Chunk :: struct {
	offset: u32,
	size:   u32,
	stride: i32,
	flags:  i32,
}

@(private = "file")
Spa_Data :: struct {
	type:      u32,
	flags:     u32,
	fd:        i64,
	mapoffset: u32,
	maxsize:   u32,
	data:      rawptr,
	chunk:     ^Spa_Chunk,
}

@(private = "file")
Spa_Buffer :: struct {
	n_metas: u32,
	n_datas: u32,
	metas:   rawptr,
	datas:   [^]Spa_Data,
}

// pw_buffer, up to the field the app reads. libpipewire owns it.
@(private = "file")
Pw_Buffer :: struct {
	buffer:    ^Spa_Buffer,
	user_data: rawptr,
	size:      u64,
	requested: u64,
}

// pw_time as of 0.3.0. pw_stream_get_time_n fills as much as size asks for.
@(private = "file")
Pw_Time :: struct {
	now:        i64,
	rate_num:   u32,
	rate_denom: u32,
	ticks:      u64,
	delay:      i64,
	queued:     u64,
}

@(private = "file")
Pw_Stream_Events :: struct {
	version:       u32,
	destroy:       rawptr,
	state_changed: proc "c" (data: rawptr, old, state: i32, error: cstring),
	control_info:  rawptr,
	io_changed:    rawptr,
	param_changed: rawptr,
	add_buffer:    rawptr,
	remove_buffer: rawptr,
	process:       proc "c" (data: rawptr),
	drained:       rawptr,
	command:       rawptr,
	trigger_done:  rawptr,
}

@(private = "file")
STREAM_STATE_ERROR :: -1
@(private = "file")
STREAM_STATE_PAUSED :: 2
@(private = "file")
STREAM_STATE_STREAMING :: 3

// PW_STREAM_FLAG_AUTOCONNECT | MAP_BUFFERS | RT_PROCESS
@(private = "file")
STREAM_FLAGS :: 1 << 0 | 1 << 2 | 1 << 4
@(private = "file")
SPA_DIRECTION_OUTPUT :: 1
@(private = "file")
PW_ID_ANY :: 0xffff_ffff

@(private = "file")
SPA_TYPE_ID :: 3
@(private = "file")
SPA_TYPE_INT :: 4
@(private = "file")
SPA_TYPE_ARRAY :: 13
@(private = "file")
SPA_TYPE_OBJECT :: 15
@(private = "file")
SPA_TYPE_OBJECT_FORMAT :: 0x40003
@(private = "file")
SPA_PARAM_ENUM_FORMAT :: 3
@(private = "file")
SPA_FORMAT_MEDIA_TYPE :: 1
@(private = "file")
SPA_FORMAT_MEDIA_SUBTYPE :: 2
@(private = "file")
SPA_FORMAT_AUDIO_FORMAT :: 0x10001
@(private = "file")
SPA_FORMAT_AUDIO_RATE :: 0x10003
@(private = "file")
SPA_FORMAT_AUDIO_CHANNELS :: 0x10004
@(private = "file")
SPA_FORMAT_AUDIO_POSITION :: 0x10005
@(private = "file")
SPA_MEDIA_TYPE_AUDIO :: 1
@(private = "file")
SPA_MEDIA_SUBTYPE_RAW :: 1
@(private = "file")
SPA_AUDIO_FORMAT_F32_LE :: 0x11b
@(private = "file")
SPA_AUDIO_CHANNEL_FL :: 3
@(private = "file")
SPA_AUDIO_CHANNEL_FR :: 4
