package audio

// Output on Linux, through a PipeWire stream. libpipewire is loaded at run
// time, so the app starts without it, and a track then fails with a line
// that says it's missing. There is no other way to a sound card here.
//
// With bit-perfect output off (mixer_open) the stream sends floats at the
// track's rate with the track's channels, and PipeWire resamples them to
// the graph's rate, mixes them down or up to the sink's channels and
// applies the stream's volume.
//
// With it on (hal_configure) the stream asks for the track's rate with
// node.rate and forces the graph to it with node.force-rate, the way
// bitperfect_darwin.odin sets the device's nominal rate. It then waits until
// the graph runs at
// that rate and refuses otherwise. At the same rate PipeWire passes the
// stream's samples through without resampling: 32-bit floats of v / 2^23,
// which PipeWire converts to the sink's integer format exactly. The
// resampler isn't disabled outright (resample.disable): the stream has to
// link while the graph still runs at the old rate, and it never plays a
// frame until the rates match.
//
// Before forcing a rate it asks the registry what the default sink is
// (pw_default_sink), and refuses unless it's a sound card's own node. A
// filter chain processes every sample, so it can't be bit-perfect anyway,
// and it may offer rates the card behind it can't run: Asahi's speaker
// DSP offers 88.2 kHz, the speakers ran at 96 kHz instead, and their
// protection daemon read nonsense and locked them.
//
// What this can't see: a card that can't run at the graph's rate
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

// MIXER_NAME is what converts and mixes the apps' sound on this OS.
MIXER_NAME :: "PipeWire"

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
	channels:    int, // the stream's
	shared:      bool, // the graph may run at another rate: floats at the volume (mixer_render)
	state:       i32, // the stream's state as state_changed last saw it (atomic)
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

// device_nominal_rate is 0: PipeWire converts to whatever the graph runs
// at, and the player reports the track's rate instead.
device_nominal_rate :: proc(dev: Device_ID) -> f64 {
	return 0
}

device_name :: proc(dev: Device_ID) -> string {
	return "Default output"
}

// watch_format does nothing: the graph's rate is checked in the stream's
// process callback, and a sink has no rate to read from here.
watch_format :: proc(dev: Device_ID, w: ^Device_Watch) -> bool {
	return false
}

unwatch_format :: proc(dev: Device_ID, w: ^Device_Watch) {}

// device_physical_format is unknown: the sink's format is PipeWire's.
device_physical_format :: proc(dev: Device_ID) -> (bits: int, float: bool, ok: bool) {
	return
}

// hal_alive is false once the stream has failed, or the graph has left
// the track's rate for longer than it takes to switch.
hal_alive :: proc(h: ^Hal) -> bool {
	return h.out != nil && !sync.atomic_load(&h.out.lost)
}

// MIXER_FOLLOWS_DEFAULT says whether mixer_open's stream moves to a new
// default output by itself.
MIXER_FOLLOWS_DEFAULT :: true

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

// hal_taken is always "": a graph that leaves the stream's rate makes
// hal_alive false instead.
hal_taken :: proc(h: ^Hal) -> string {
	return ""
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
	if channels < 1 || channels > 2 {
		hal_close(h, false)
		return false, fmt.tprintf("%d channels; PipeWire output is stereo", channels)
	}
	if !pw_load() {
		hal_close(h, false)
		return false, "PipeWire isn't installed"
	}
	// Nothing may force the graph's rate before this says the sink can take it.
	sink, queried := pw_default_sink()
	if !queried {
		hal_close(h, false)
		return false, "PipeWire didn't say what the output is"
	}
	if allowed, refusal := sink_allows_bit_perfect(sink); !allowed {
		hal_close(h, false)
		return false, refusal
	}
	ok, reason = stream_open(h, nil, rate, 2, shared = false)
	if ok {
		h.device = dev
		h.channel_map = channel_map_make(channels, {0, 1})
	}
	return
}

// mixer_open opens a stream for floats at rate with the track's channels,
// whatever rate the graph runs at, and waits up to HAL_SETTLE_TIMEOUT for
// PipeWire to link it. w hears when the stream fails or loses its sink. If
// it can't open, ok is false and reason says why, short enough for the
// player bar.
mixer_open :: proc(h: ^Hal, w: ^Device_Watch, rate, channels: int) -> (ok: bool, reason: string) {
	if channels < 1 || channels > MAX_CHANNELS {
		hal_close(h, false)
		return false, fmt.tprintf("no output for %d channels", channels)
	}
	ok, reason = stream_open(h, w, rate, channels, shared = true)
	if ok {
		h.device = PIPEWIRE_DEFAULT
	}
	return
}

// stream_open is what hal_configure and mixer_open share: a stream of
// channels at rate, left idle. A shared one is ready once it's linked;
// otherwise the graph must reach the rate.
@(private = "file")
stream_open :: proc(h: ^Hal, w: ^Device_Watch, rate, channels: int, shared: bool) -> (ok: bool, reason: string) {
	hal_close(h, false)
	if !pw_load() {
		return false, "PipeWire isn't installed"
	}
	o := new(Pw_Output, runtime.heap_allocator())
	o.rate = rate
	o.channels = channels
	o.shared = shared
	o.watch = w
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
		// The rest is bit-perfect output's.
		{"node.rate", fmt.ctprintf("1/%d", rate)},
		{"node.force-rate", "0"},
		// Don't restore a stream volume saved for this app.
		{"state.restore-props", "false"},
	}
	dict := Spa_Dict {
		n_items = len(items) - 3 if shared else len(items),
		items   = &items[0],
	}
	o.stream = pw.stream_new_simple(pw.thread_loop_get_loop(o.loop), "TIDALfast", pw.properties_new_dict(&dict), &pw_events, o)
	if o.stream == nil {
		log.warn("audio: PipeWire refused a new stream")
		return false, "PipeWire refused the stream"
	}
	pod: [32]u64
	params := [1]rawptr{format_pod(&pod, rate, channels)}
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
		if graph == rate || (shared && sync.atomic_load(&o.state) >= STREAM_STATE_PAUSED) {
			break
		}
		if time.tick_since(begin) > HAL_SETTLE_TIMEOUT {
			if graph == 0 || shared {
				log.warn("audio: the PipeWire stream didn't start")
				return false, "PipeWire didn't start the stream"
			}
			log.warnf("audio: PipeWire stayed at %d Hz instead of %d", graph, rate)
			return false, fmt.tprintf("PipeWire stayed at %s kHz", khz_text(graph))
		}
		time.sleep(2 * time.Millisecond)
	}
	h.settle_ms = time.duration_milliseconds(time.tick_since(begin))
	h.format = {
		sample_rate     = f64(rate),
		format_id       = FORMAT_LPCM,
		format_flags    = FLAG_FLOAT,
		bytes_per_frame = u32(channels) * size_of(f32),
		channels        = u32(channels),
		bits            = 32,
	}
	// Idle until hal_start, so an output opened while paused costs no CPU.
	pw.thread_loop_lock(o.loop)
	pw.stream_set_active(o.stream, false)
	pw.thread_loop_unlock(o.loop)
	return true, ""
}

// hal_start lets process render p's ring (hal_render, or mixer_render for
// a shared stream).
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
// or system calls. A bit-perfect stream sends silence and leaves the ring
// alone until the graph runs at the track's rate; if the rate stays wrong
// while playing, the output is lost and the player opens it again. A shared
// stream plays at any graph rate.
@(private = "file")
pw_process :: proc "c" (data: rawptr) {
	o := (^Pw_Output)(data)
	b := pw.stream_dequeue_buffer(o.stream)
	if b == nil {
		return
	}
	d := &b.buffer.datas[0]
	stride := u32(o.channels) * size_of(f32)
	frames := d.maxsize / stride
	if b.requested > 0 {
		frames = min(frames, u32(b.requested))
	}
	t: Pw_Time
	if pw.stream_get_time_n(o.stream, &t, size_of(t)) == 0 && t.rate_denom != 0 {
		sync.atomic_store(&o.graph_rate, t.rate_denom)
	}
	right := o.shared || sync.atomic_load(&o.graph_rate) == u32(o.rate)
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
		if right && sync.atomic_load(&o.running) && o.shared {
			mixer_render(o.player, ([^]f32)(d.data), u64(frames))
		} else if right && sync.atomic_load(&o.running) {
			list := Audio_Buffer_List {
				count   = 1,
				buffers = {{channels = u32(o.channels), size = size, data = d.data}},
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
	sync.atomic_store(&o.state, state)
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
// 32-bit float audio of 1 to 8 channels at rate, the channels where FLAC
// has them. libspa builds these with inline header functions, so this is
// the same bytes by hand.
@(private = "file")
format_pod :: proc(buf: ^[32]u64, rate, channels: int) -> rawptr {
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
	put(w, &n, SPA_FORMAT_AUDIO_CHANNELS, 0, 4, SPA_TYPE_INT, u32(channels))
	// An array pod: its child pod's header, then the values.
	put(w, &n, SPA_FORMAT_AUDIO_POSITION, 0, u32(8 + channels * 4), SPA_TYPE_ARRAY, 4, SPA_TYPE_ID)
	positions := CHANNEL_POSITIONS[channels - 1]
	put(w, &n, ..positions[:channels])
	w[0] = u32(n - 2) * 4 // the object's body, everything after its header
	return &buf[0]
}

// Pw_Sink is what PipeWire's registry says about the default sink.
Pw_Sink :: struct {
	found:      bool, // a sink has the default sink's name
	has_device: bool, // it's a device's node, not a filter or a virtual sink
	device_api: string, // the device's, such as "alsa" or "bluez5"
}

// sink_allows_bit_perfect says whether forcing the graph to a track's rate
// sends its samples to a sound card unchanged. Only a node of an ALSA
// device does: a filter chain processes the samples and may offer rates
// its card can't run, and Bluetooth encodes them again.
sink_allows_bit_perfect :: proc(s: Pw_Sink) -> (ok: bool, reason: string) {
	switch {
	case !s.found:
		return false, "PipeWire has no default output"
	case !s.has_device:
		return false, "the output is a filter or virtual sink, not a sound card"
	case s.device_api == "bluez5":
		return false, "Bluetooth output isn't bit-perfect"
	case s.device_api != "alsa":
		return false, "the output isn't a sound card"
	}
	return true, ""
}

// default_sink_name reads the node name out of the default metadata's
// value for default.audio.sink, a JSON object such as {"name":"x"}. Node
// names have no quotes or escapes in them. "" if there's none.
default_sink_name :: proc "contextless" (value: string) -> string {
	key := `"name"`
	for i := 0; i + len(key) <= len(value); i += 1 {
		if value[i:i + len(key)] != key {
			continue
		}
		j := i + len(key)
		for j < len(value) && (value[j] == ' ' || value[j] == '\t') {
			j += 1
		}
		if j >= len(value) || value[j] != ':' {
			return ""
		}
		j += 1
		for j < len(value) && (value[j] == ' ' || value[j] == '\t') {
			j += 1
		}
		if j >= len(value) || value[j] != '"' {
			return ""
		}
		j += 1
		for k := j; k < len(value); k += 1 {
			if value[k] == '"' {
				return value[j:k]
			}
		}
		return ""
	}
	return ""
}

@(private = "file")
QUERY_TIMEOUT :: time.Second

@(private = "file")
QUERY_MAX :: 64

// Pw_Query is what the registry and metadata callbacks fill in, on the
// query's loop thread. Fixed arrays, so the callbacks don't allocate.
@(private = "file")
Pw_Query :: struct {
	core_hook:     Spa_Hook,
	registry_hook: Spa_Hook,
	metadata_hook: Spa_Hook,
	done:          i32, // the last sync answered (atomic)
	metadata_id:   u32, // the "default" metadata, PW_ID_ANY until seen
	sink:          [256]u8,
	sink_len:      int,
	sinks:         [QUERY_MAX]Query_Sink,
	n_sinks:       int,
	devices:       [QUERY_MAX]Query_Device,
	n_devices:     int,
}

@(private = "file")
Query_Sink :: struct {
	name:      [256]u8,
	name_len:  int,
	device_id: u32, // PW_ID_ANY without a device
}

@(private = "file")
Query_Device :: struct {
	id:      u32,
	api:     [32]u8,
	api_len: int,
}

// pw_default_sink asks PipeWire's registry for the default sink and its
// device, reading only. queried is false if PipeWire didn't answer in time.
pw_default_sink :: proc() -> (sink: Pw_Sink, queried: bool) {
	if !pw_load() {
		return
	}
	q := new(Pw_Query, runtime.heap_allocator())
	defer free(q, runtime.heap_allocator())
	q.metadata_id = PW_ID_ANY
	q.done = -1
	loop := pw.thread_loop_new("tidalfast-pipewire-query", nil)
	if loop == nil {
		return
	}
	defer pw.thread_loop_destroy(loop)
	ctx := pw.context_new(pw.thread_loop_get_loop(loop), nil, 0)
	if ctx == nil {
		return
	}
	defer pw.context_destroy(ctx)
	if pw.thread_loop_start(loop) < 0 {
		return
	}
	defer pw.thread_loop_stop(loop)

	pw.thread_loop_lock(loop)
	core := pw.context_connect(ctx, nil, 0)
	if core == nil {
		pw.thread_loop_unlock(loop)
		return
	}
	registry, metadata: rawptr
	defer {
		pw.thread_loop_lock(loop)
		hook_remove(&q.metadata_hook)
		hook_remove(&q.registry_hook)
		hook_remove(&q.core_hook)
		if metadata != nil {
			pw.proxy_destroy(metadata)
		}
		if registry != nil {
			pw.proxy_destroy(registry)
		}
		pw.core_disconnect(core)
		pw.thread_loop_unlock(loop)
	}
	cm, cd := methods(core, Pw_Core_Methods)
	cm.add_listener(cd, &q.core_hook, &query_core_events, q)
	registry = cm.get_registry(cd, PW_VERSION_REGISTRY, 0)
	if registry == nil {
		pw.thread_loop_unlock(loop)
		return
	}
	rm, rd := methods(registry, Pw_Registry_Methods)
	rm.add_listener(rd, &q.registry_hook, &query_registry_events, q)
	seq := cm.sync(cd, PW_ID_CORE, 0)
	pw.thread_loop_unlock(loop)
	if !query_wait(q, seq) {
		return
	}

	// The registry has listed every global; now the default sink's name.
	pw.thread_loop_lock(loop)
	if q.metadata_id != PW_ID_ANY {
		metadata = rm.bind(rd, q.metadata_id, "PipeWire:Interface:Metadata", PW_VERSION_METADATA, 0)
	}
	if metadata == nil {
		pw.thread_loop_unlock(loop)
		return {}, true
	}
	mm, md := methods(metadata, Pw_Metadata_Methods)
	mm.add_listener(md, &q.metadata_hook, &query_metadata_events, q)
	seq = cm.sync(cd, PW_ID_CORE, 0)
	pw.thread_loop_unlock(loop)
	if !query_wait(q, seq) {
		return
	}

	name := string(q.sink[:q.sink_len])
	for &s in q.sinks[:q.n_sinks] {
		if name == "" || string(s.name[:s.name_len]) != name {
			continue
		}
		sink.found = true
		if s.device_id == PW_ID_ANY {
			break
		}
		sink.has_device = true
		for &d in q.devices[:q.n_devices] {
			if d.id == s.device_id {
				sink.device_api = device_api_name(string(d.api[:d.api_len]))
			}
		}
		break
	}
	return sink, true
}

// device_api_name gives an API name that outlives the query.
@(private = "file")
device_api_name :: proc(api: string) -> string {
	switch api {
	case "alsa":
		return "alsa"
	case "bluez5":
		return "bluez5"
	case "":
		return ""
	}
	return "other"
}

@(private = "file")
query_wait :: proc(q: ^Pw_Query, seq: i32) -> bool {
	if seq < 0 {
		return false
	}
	begin := time.tick_now()
	for sync.atomic_load(&q.done) != seq {
		if time.tick_since(begin) > QUERY_TIMEOUT {
			log.warn("audio: PipeWire's registry didn't answer")
			return false
		}
		time.sleep(time.Millisecond)
	}
	return true
}

@(private = "file")
methods :: proc(object: rawptr, $T: typeid) -> (^T, rawptr) {
	i := (^Spa_Interface)(object)
	return (^T)(i.cb.funcs), i.cb.data
}

// hook_remove is spa_hook_remove, an inline function in spa/utils/hook.h.
@(private = "file")
hook_remove :: proc(h: ^Spa_Hook) {
	if h.link.prev != nil {
		h.link.prev.next = h.link.next
		h.link.next.prev = h.link.prev
		h.link = {}
	}
	if h.removed != nil {
		h.removed(h)
	}
}

@(private = "file")
dict_get :: proc "contextless" (d: ^Spa_Dict, key: string) -> string {
	if d == nil {
		return ""
	}
	for i in 0 ..< d.n_items {
		item := d.items[i]
		if item.key != nil && string(item.key) == key {
			return string(item.value) if item.value != nil else ""
		}
	}
	return ""
}

@(private = "file")
parse_id :: proc "contextless" (s: string) -> (id: u32, ok: bool) {
	if s == "" || len(s) > 9 {
		return
	}
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return
		}
		id = id * 10 + u32(c - '0')
	}
	return id, true
}

@(private = "file")
query_done :: proc "c" (data: rawptr, id: u32, seq: i32) {
	if id == PW_ID_CORE {
		sync.atomic_store(&(^Pw_Query)(data).done, seq)
	}
}

@(private = "file")
query_global :: proc "c" (data: rawptr, id, permissions: u32, type: cstring, version: u32, props: ^Spa_Dict) {
	q := (^Pw_Query)(data)
	switch string(type) {
	case "PipeWire:Interface:Metadata":
		if dict_get(props, "metadata.name") == "default" {
			q.metadata_id = id
		}
	case "PipeWire:Interface:Node":
		if dict_get(props, "media.class") != "Audio/Sink" || q.n_sinks == QUERY_MAX {
			return
		}
		s := &q.sinks[q.n_sinks]
		s.name_len = copy(s.name[:], dict_get(props, "node.name"))
		s.device_id = PW_ID_ANY
		if dev, ok := parse_id(dict_get(props, "device.id")); ok {
			s.device_id = dev
		}
		q.n_sinks += 1
	case "PipeWire:Interface:Device":
		if q.n_devices == QUERY_MAX {
			return
		}
		d := &q.devices[q.n_devices]
		d.id = id
		d.api_len = copy(d.api[:], dict_get(props, "device.api"))
		q.n_devices += 1
	}
}

@(private = "file")
query_property :: proc "c" (data: rawptr, subject: u32, key, type, value: cstring) -> i32 {
	q := (^Pw_Query)(data)
	if subject == PW_ID_CORE && key != nil && string(key) == "default.audio.sink" {
		q.sink_len = 0
		if value != nil {
			q.sink_len = copy(q.sink[:], default_sink_name(string(value)))
		}
	}
	return 0
}

@(private = "file")
query_core_events := Pw_Core_Events {
	done = query_done,
}

@(private = "file")
query_registry_events := Pw_Registry_Events {
	global = query_global,
}

@(private = "file")
query_metadata_events := Pw_Metadata_Events {
	property = query_property,
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
	context_new:           proc "c" (loop: rawptr, props: rawptr, user_data_size: uint) -> rawptr,
	context_connect:       proc "c" (ctx: rawptr, props: rawptr, user_data_size: uint) -> rawptr,
	context_destroy:       proc "c" (ctx: rawptr),
	core_disconnect:       proc "c" (core: rawptr) -> i32,
	proxy_destroy:         proc "c" (proxy: rawptr),
}

@(private = "file")
pw: Pw_Api

@(private = "file")
pw_loaded: Maybe(bool)

// pw_load loads libpipewire once. It's never unloaded: the stream's
// threads may outlive the player's teardown by a moment.
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
Spa_List :: struct {
	next: ^Spa_List,
	prev: ^Spa_List,
}

@(private = "file")
Spa_Callbacks :: struct {
	funcs: rawptr,
	data:  rawptr,
}

@(private = "file")
Spa_Interface :: struct {
	type:    cstring,
	version: u32,
	cb:      Spa_Callbacks,
}

@(private = "file")
Spa_Hook :: struct {
	link:    Spa_List,
	cb:      Spa_Callbacks,
	removed: proc "c" (hook: ^Spa_Hook),
	priv:    rawptr,
}

// A pw_core, pw_registry or pw_metadata proxy starts with its spa_interface,
// whose funcs are these methods. pipewire/core.h and extensions/metadata.h
// call them through inline functions.
@(private = "file")
Pw_Core_Methods :: struct {
	version:       u32,
	add_listener:  proc "c" (object: rawptr, listener: ^Spa_Hook, events: rawptr, data: rawptr) -> i32,
	hello:         rawptr,
	sync:          proc "c" (object: rawptr, id: u32, seq: i32) -> i32,
	pong:          rawptr,
	error:         rawptr,
	get_registry:  proc "c" (object: rawptr, version: u32, user_data_size: uint) -> rawptr,
	create_object: rawptr,
	destroy:       rawptr,
}

@(private = "file")
Pw_Registry_Methods :: struct {
	version:      u32,
	add_listener: proc "c" (object: rawptr, listener: ^Spa_Hook, events: rawptr, data: rawptr) -> i32,
	bind:         proc "c" (object: rawptr, id: u32, type: cstring, version: u32, user_data_size: uint) -> rawptr,
	destroy:      rawptr,
}

@(private = "file")
Pw_Metadata_Methods :: struct {
	version:      u32,
	add_listener: proc "c" (object: rawptr, listener: ^Spa_Hook, events: rawptr, data: rawptr) -> i32,
	set_property: rawptr,
	clear:        rawptr,
}

// Version 0 of each: no events after these.
@(private = "file")
Pw_Core_Events :: struct {
	version:    u32,
	info:       rawptr,
	done:       proc "c" (data: rawptr, id: u32, seq: i32),
	ping:       rawptr,
	error:      rawptr,
	remove_id:  rawptr,
	bound_id:   rawptr,
	add_mem:    rawptr,
	remove_mem: rawptr,
}

@(private = "file")
Pw_Registry_Events :: struct {
	version:       u32,
	global:        proc "c" (data: rawptr, id, permissions: u32, type: cstring, version: u32, props: ^Spa_Dict),
	global_remove: rawptr,
}

@(private = "file")
Pw_Metadata_Events :: struct {
	version:  u32,
	property: proc "c" (data: rawptr, subject: u32, key, type, value: cstring) -> i32,
}

@(private = "file")
PW_ID_CORE :: 0
@(private = "file")
PW_VERSION_REGISTRY :: 3
@(private = "file")
PW_VERSION_METADATA :: 3

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

// SPA_AUDIO_CHANNEL_*: where each channel of a FLAC stream of 1 to 8
// channels plays.
@(private = "file")
MONO :: 2
@(private = "file")
FL :: 3
@(private = "file")
FR :: 4
@(private = "file")
FC :: 5
@(private = "file")
LFE :: 6
@(private = "file")
SL :: 7
@(private = "file")
SR :: 8
@(private = "file")
RC :: 11
@(private = "file")
RL :: 12
@(private = "file")
RR :: 13

@(private = "file")
CHANNEL_POSITIONS := [8][8]u32 {
	{MONO, 0, 0, 0, 0, 0, 0, 0},
	{FL, FR, 0, 0, 0, 0, 0, 0},
	{FL, FR, FC, 0, 0, 0, 0, 0},
	{FL, FR, RL, RR, 0, 0, 0, 0},
	{FL, FR, FC, RL, RR, 0, 0, 0},
	{FL, FR, FC, LFE, RL, RR, 0, 0},
	{FL, FR, FC, LFE, RC, SL, SR, 0},
	{FL, FR, FC, LFE, RL, RR, SL, SR},
}
