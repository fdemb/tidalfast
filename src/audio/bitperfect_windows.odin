package audio

// Bit-perfect output on Windows, through WASAPI exclusive mode. The stream
// opens the default output at the track's rate in a signed integer format
// at least as deep as the track, and the audio engine stays out of the way:
// no mixing, no resampling, no system volume. The decoder's floats are its
// integers over 2^31, so float_to_pcm turns them back into those integers
// exactly.
//
// While it plays, no other app can use the device; Windows lets the user
// forbid that in the device's Advanced properties, and then this refuses
// and miniaudio plays through the shared mode as when bit-perfect output
// is off. The device's own settings are never changed, so there is no
// Device_Change: the device is the shared mixer's again once the stream
// closes.
//
// With bit-perfect output off, miniaudio plays in shared mode, and the
// output menu shows the engine's mix rate and the device's format from the
// endpoint's properties.
//
// The interfaces are declared here as far as the app uses them: Odin's
// core:sys/windows has COM's basics but not the audio ones.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:sync"
import "core:time"
import win "core:sys/windows"

// BIT_PERFECT says whether this OS has bit-perfect output.
BIT_PERFECT :: true

// MIXER_NAME is what converts and mixes the apps' sound on this OS.
MIXER_NAME :: "Windows audio"

Hal :: struct {
	device:      Device_ID,
	out:         ^Wasapi_Output, // heap; nil when closed
	format:      Stream_Description, // what the device gets: signed integers
	channel_map: Channel_Map,
	settle_ms:   f64,
}

// Wasapi_Output is what the render thread sees. Heap-allocated, freed
// after the thread has stopped.
@(private)
Wasapi_Output :: struct {
	client:   ^IAudioClient,
	render:   ^IAudioRenderClient,
	event:    win.HANDLE, // the engine wants a buffer
	quit:     win.HANDLE,
	thread:   win.HANDLE,
	frames:   u32, // per buffer
	bytes:    int, // per sample in the device's format
	channels: int, // the device's
	scratch:  []f32, // frames * channels, the buffer as floats
	running:  bool, // between hal_start and hal_stop (atomic)
	busy:     bool, // the thread is filling a buffer (atomic)
	lost:     bool, // the device went away or stopped asking (atomic)
	player:   ^Player,
	watch:    ^Device_Watch, // atomic; nil when unwatched
}

// default_output_device names the default output endpoint by a hash of its
// ID, 0 when there is none.
default_output_device :: proc() -> Device_ID {
	dev := default_endpoint()
	if dev == nil {
		return 0
	}
	defer dev.vtbl.Release(dev)
	return endpoint_id(dev)
}

// device_nominal_rate is the shared mode's mix rate, what the engine
// resamples every app to.
device_nominal_rate :: proc(dev: Device_ID) -> f64 {
	d := default_endpoint()
	if d == nil {
		return 0
	}
	defer d.vtbl.Release(d)
	client := activate(d)
	if client == nil {
		return 0
	}
	defer client.vtbl.Release(client)
	mix: ^Wave_Format_Extensible
	if client.vtbl.GetMixFormat(client, &mix) < 0 || mix == nil {
		return 0
	}
	defer win.CoTaskMemFree(mix)
	return f64(mix.samples_per_sec)
}

// device_name is the default output's name as Windows shows it, valid
// until the next call.
device_name :: proc(dev: Device_ID) -> string {
	d := default_endpoint()
	if d == nil {
		return "Default output"
	}
	defer d.vtbl.Release(d)
	sync.guard(&name_mutex)
	n := endpoint_name(d, name_buf[:])
	return string(name_buf[:n]) if n > 0 else "Default output"
}

@(private = "file")
name_buf: [256]u8

@(private = "file")
name_mutex: sync.Mutex

// The engine's format can change only through the Sound settings, which
// the user does while nothing plays, so it isn't watched.
watch_format :: proc(dev: Device_ID, w: ^Device_Watch) -> bool {
	return false
}

unwatch_format :: proc(dev: Device_ID, w: ^Device_Watch) {}

// device_physical_format is the format the device runs at in shared mode,
// from the endpoint's properties.
device_physical_format :: proc(dev: Device_ID) -> (bits: int, float: bool, ok: bool) {
	d := default_endpoint()
	if d == nil {
		return
	}
	defer d.vtbl.Release(d)
	store: ^IPropertyStore
	if d.vtbl.OpenPropertyStore(d, STGM_READ, &store) < 0 || store == nil {
		return
	}
	defer store.vtbl.Release(store)
	key := PKEY_AudioEngine_DeviceFormat
	pv: Prop_Variant
	if store.vtbl.GetValue(store, &key, &pv) < 0 {
		return
	}
	defer PropVariantClear(&pv)
	if pv.vt != VT_BLOB || pv.b == 0 || u32(pv.a) < size_of(Wave_Format) {
		return
	}
	f := (^Wave_Format_Extensible)(uintptr(pv.b))
	bits = int(f.bits_per_sample)
	float = f.format_tag == WAVE_FORMAT_IEEE_FLOAT
	if f.format_tag == WAVE_FORMAT_EXTENSIBLE && u32(pv.a) >= size_of(Wave_Format_Extensible) {
		if f.valid_bits > 0 {
			bits = int(f.valid_bits)
		}
		float = f.sub_format == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
	}
	return bits, float, true
}

// hal_alive is false once the device has gone or stopped asking for
// samples while it should play.
hal_alive :: proc(h: ^Hal) -> bool {
	return h.out != nil && !sync.atomic_load(&h.out.lost)
}

// An exclusive stream stays on its device; a new default output takes over
// from the next track.
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

// hal_taken is always "": no other app can take a device held in exclusive
// mode.
hal_taken :: proc(h: ^Hal) -> string {
	return ""
}

unwatch_device :: proc(h: ^Hal, w: ^Device_Watch) {
	if h.out != nil {
		sync.atomic_store(&h.out.watch, nil)
	}
}

// hal_configure opens the default output in exclusive mode at rate, in
// the narrowest signed integer format of at least bits that the device
// takes. Mono and stereo go out as stereo; more channels are refused. If
// it can't, ok is false and reason says why, short enough for a menu line.
hal_configure :: proc(h: ^Hal, dev: Device_ID, rate, channels, bits: int) -> (ok: bool, reason: string) {
	hal_close(h, false)
	if channels < 1 || channels > 2 {
		return false, fmt.tprintf("%d channels; exclusive output is stereo", channels)
	}
	com_init()
	begin := time.tick_now()
	d := default_endpoint()
	if d == nil {
		return false, "No output device"
	}
	defer d.vtbl.Release(d)
	client := activate(d)
	if client == nil {
		return false, "Windows refused the device"
	}
	o := new(Wasapi_Output, runtime.heap_allocator())
	o.client = client
	o.channels = 2
	h.out = o
	defer if !ok {
		hal_close(h, false)
	}

	wf, found := pick_format(client, rate, o.channels, bits)
	if !found.ok {
		return false, found.reason
	}
	o.bytes = int(wf.bits_per_sample) / 8

	default_period, min_period: i64
	client.vtbl.GetDevicePeriod(client, &default_period, &min_period)
	period := default_period
	hr := client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period, period, &wf, nil)
	if hr == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED {
		// The buffer must be a whole number of the device's blocks: ask
		// again with the period the engine rounded to, on a new client.
		frames: u32
		client.vtbl.GetBufferSize(client, &frames)
		client.vtbl.Release(client)
		o.client = nil
		period = i64(10_000_000.0 * f64(frames) / f64(rate) + 0.5)
		client = activate(d)
		if client == nil {
			return false, "Windows refused the device"
		}
		o.client = client
		hr = client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, period, period, &wf, nil)
	}
	if hr < 0 {
		log.warnf("audio: exclusive mode at %d Hz refused (0x%8x)", rate, u32(hr))
		return false, refusal(hr)
	}
	if client.vtbl.GetBufferSize(client, &o.frames) < 0 || o.frames == 0 {
		return false, "Windows refused the device"
	}
	o.event = win.CreateEventW(nil, false, false, nil)
	o.quit = win.CreateEventW(nil, true, false, nil)
	if o.event == nil || o.quit == nil || client.vtbl.SetEventHandle(client, o.event) < 0 {
		return false, "Windows refused the device"
	}
	iid := IID_IAudioRenderClient
	if client.vtbl.GetService(client, &iid, (^rawptr)(&o.render)) < 0 || o.render == nil {
		return false, "Windows refused the device"
	}
	o.scratch = make([]f32, int(o.frames) * o.channels, runtime.heap_allocator())
	o.thread = win.CreateThread(nil, 0, render_main, o, 0, nil)
	if o.thread == nil {
		return false, "Windows refused the device"
	}

	h.device = endpoint_id(d)
	h.settle_ms = time.duration_milliseconds(time.tick_since(begin))
	h.format = {
		sample_rate     = f64(rate),
		format_id       = FORMAT_LPCM,
		format_flags    = FLAG_SIGNED,
		bytes_per_frame = u32(o.bytes * o.channels),
		channels        = u32(o.channels),
		bits            = u32(wf.valid_bits),
	}
	h.channel_map = channel_map_make(channels, {0, 1})
	return true, ""
}

// hal_start fills the first buffer and starts the stream; the render
// thread fills the rest (hal_render).
hal_start :: proc(h: ^Hal, p: ^Player) -> bool {
	o := h.out
	if o == nil {
		return false
	}
	o.player = p
	// The first buffer goes in before running is set, so the render thread,
	// which fills only while running, can't fill it at the same time.
	fill(o, prefill = true)
	sync.atomic_store(&o.running, true)
	if o.client.vtbl.Start(o.client) < 0 {
		sync.atomic_store(&o.running, false)
		return false
	}
	return true
}

// hal_stop stops the stream. When it returns the render thread no longer
// touches the player or the buffer, and a stopped stream sends no events,
// so the render thread sleeps until the next start.
hal_stop :: proc(h: ^Hal) {
	o := h.out
	if o == nil || o.client == nil {
		return
	}
	sync.atomic_store(&o.running, false)
	for sync.atomic_load(&o.busy) {
		time.sleep(50 * time.Microsecond)
	}
	o.client.vtbl.Stop(o.client)
	o.client.vtbl.Reset(o.client)
	// An event the engine sent before it stopped would wake the thread for
	// a buffer that isn't due.
	win.ResetEvent(o.event)
}

// hal_close ends the stream, which gives the device back to the shared
// mixer. restore doesn't matter: nothing on the device was changed.
hal_close :: proc(h: ^Hal, restore: bool) {
	if o := h.out; o != nil {
		hal_stop(h)
		if o.thread != nil {
			win.SetEvent(o.quit)
			win.WaitForSingleObject(o.thread, win.INFINITE)
			win.CloseHandle(o.thread)
		}
		if o.render != nil {
			o.render.vtbl.Release(o.render)
		}
		if o.client != nil {
			o.client.vtbl.Release(o.client)
		}
		if o.event != nil {
			win.CloseHandle(o.event)
		}
		if o.quit != nil {
			win.CloseHandle(o.quit)
		}
		delete(o.scratch, runtime.heap_allocator())
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

// render_main is the render thread: one buffer per event from the engine,
// as a "Pro Audio" task so the scheduler keeps it on time. A second
// without an event while playing means the device has stopped; while
// stopped it waits without a timeout.
@(private = "file")
render_main :: proc "system" (arg: rawptr) -> u32 {
	o := (^Wasapi_Output)(arg)
	win.CoInitializeEx(nil, .MULTITHREADED)
	task: u32
	mmcss := AvSetMmThreadCharacteristicsW(win.L("Pro Audio"), &task)
	handles := [2]win.HANDLE{o.event, o.quit}
	for {
		timeout: u32 = 1000 if sync.atomic_load(&o.running) else win.INFINITE
		r := win.WaitForMultipleObjects(2, &handles[0], false, timeout)
		if r == win.WAIT_OBJECT_0 + 1 {
			break
		}
		if r != win.WAIT_OBJECT_0 {
			if sync.atomic_load(&o.running) {
				lose(o)
			}
			continue
		}
		fill(o, prefill = false)
	}
	if mmcss != nil {
		AvRevertMmThreadCharacteristics(mmcss)
	}
	win.CoUninitialize()
	return 0
}

// fill hands the engine one buffer: the ring's frames while playing or for
// hal_start's prefill, silence otherwise. The render thread fills only
// while running. busy covers the whole of it, GetBuffer to ReleaseBuffer,
// so hal_stop doesn't reset the stream while a buffer is out. No locks,
// allocation or logging, as in an IOProc.
@(private = "file")
fill :: proc "contextless" (o: ^Wasapi_Output, prefill: bool) {
	sync.atomic_store(&o.busy, true)
	defer sync.atomic_store(&o.busy, false)
	playing := prefill || sync.atomic_load(&o.running)
	if !playing {
		return
	}
	data: [^]u8
	if hr := o.render.vtbl.GetBuffer(o.render, o.frames, &data); hr < 0 {
		// A buffer that's already full needs nothing; a wake that came late
		// across a stop and start can ask for one.
		if hr != AUDCLNT_E_BUFFER_TOO_LARGE {
			lose(o)
		}
		return
	}
	flags: u32
	if o.player != nil {
		list := Audio_Buffer_List {
			count   = 1,
			buffers = {{channels = u32(o.channels), size = o.frames * u32(o.channels) * size_of(f32), data = raw_data(o.scratch)}},
		}
		hal_render(o.player, &list)
		float_to_pcm(raw_data(o.scratch), data, int(o.frames) * o.channels, o.bytes)
	} else {
		flags = AUDCLNT_BUFFERFLAGS_SILENT
	}
	if o.render.vtbl.ReleaseBuffer(o.render, o.frames, flags) < 0 {
		lose(o)
	}
}

@(private = "file")
lose :: proc "contextless" (o: ^Wasapi_Output) {
	if !sync.atomic_exchange(&o.lost, true) {
		if w := sync.atomic_load(&o.watch); w != nil {
			watch_note(w, default_changed = false, device_changed = true)
		}
	}
}

@(private = "file")
Format_Pick :: struct {
	ok:     bool,
	reason: string,
}

// pick_format finds the narrowest signed integer format of at least bits
// that the device takes at rate in exclusive mode: 16 bits in 16, 24 in
// 24, 24 in 32, then 32 in 32.
@(private = "file")
pick_format :: proc(client: ^IAudioClient, rate, channels, bits: int) -> (wf: Wave_Format_Extensible, pick: Format_Pick) {
	Container :: struct {
		bits, valid: u16,
	}
	candidates := [?]Container{{16, 16}, {24, 24}, {32, 24}, {32, 32}}
	last: i32
	for c in candidates {
		if int(c.valid) < bits {
			continue
		}
		block := u16(channels) * c.bits / 8
		wf = {
			format_tag        = WAVE_FORMAT_EXTENSIBLE,
			channels          = u16(channels),
			samples_per_sec   = u32(rate),
			avg_bytes_per_sec = u32(rate) * u32(block),
			block_align       = block,
			bits_per_sample   = c.bits,
			size              = size_of(Wave_Format_Extensible) - size_of(Wave_Format),
			valid_bits        = c.valid,
			channel_mask      = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT,
			sub_format        = KSDATAFORMAT_SUBTYPE_PCM,
		}
		last = client.vtbl.IsFormatSupported(client, AUDCLNT_SHAREMODE_EXCLUSIVE, &wf, nil)
		if last == 0 {
			return wf, {ok = true}
		}
		if last == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED || last == AUDCLNT_E_DEVICE_IN_USE {
			break
		}
	}
	if last == AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED || last == AUDCLNT_E_DEVICE_IN_USE {
		return {}, {reason = refusal(last)}
	}
	return {}, {reason = fmt.tprintf("the device can't play %d-bit at %s kHz", bits, khz_text(rate))}
}

@(private = "file")
refusal :: proc(hr: i32) -> string {
	switch hr {
	case AUDCLNT_E_DEVICE_IN_USE:
		return "another app has the device to itself"
	case AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED:
		return "the device doesn't allow exclusive mode"
	case AUDCLNT_E_UNSUPPORTED_FORMAT:
		return "the device can't play this format"
	}
	return "Windows refused the device"
}

// com_init readies COM on this thread. The decode thread asks for it
// again on every open, which COM counts and allows.
@(private = "file")
com_init :: proc() {
	win.CoInitializeEx(nil, .MULTITHREADED)
}

@(private = "file")
default_endpoint :: proc() -> ^IMMDevice {
	com_init()
	clsid := CLSID_MMDeviceEnumerator
	iid := IID_IMMDeviceEnumerator
	e: ^IMMDeviceEnumerator
	if win.CoCreateInstance(&clsid, nil, win.CLSCTX_ALL, &iid, (^rawptr)(&e)) < 0 || e == nil {
		return nil
	}
	defer e.vtbl.Release(e)
	dev: ^IMMDevice
	if e.vtbl.GetDefaultAudioEndpoint(e, E_RENDER, E_MULTIMEDIA, &dev) < 0 {
		return nil
	}
	return dev
}

@(private = "file")
activate :: proc(dev: ^IMMDevice) -> ^IAudioClient {
	iid := IID_IAudioClient
	client: ^IAudioClient
	if dev.vtbl.Activate(dev, &iid, win.CLSCTX_ALL, nil, (^rawptr)(&client)) < 0 {
		return nil
	}
	return client
}

// endpoint_id hashes the endpoint's ID string, never 0.
@(private = "file")
endpoint_id :: proc(dev: ^IMMDevice) -> Device_ID {
	id: [^]u16
	if dev.vtbl.GetId(dev, &id) < 0 || id == nil {
		return 1
	}
	defer win.CoTaskMemFree(id)
	n := 0
	for id[n] != 0 {
		n += 1
	}
	return Device_ID(hash.fnv32a(([^]u8)(id)[:n * 2])) | 1
}

// endpoint_name writes the endpoint's friendly name into buf as UTF-8 and
// returns its length.
@(private = "file")
endpoint_name :: proc(dev: ^IMMDevice, buf: []u8) -> int {
	store: ^IPropertyStore
	if dev.vtbl.OpenPropertyStore(dev, STGM_READ, &store) < 0 || store == nil {
		return 0
	}
	defer store.vtbl.Release(store)
	key := PKEY_Device_FriendlyName
	pv: Prop_Variant
	if store.vtbl.GetValue(store, &key, &pv) < 0 {
		return 0
	}
	defer PropVariantClear(&pv)
	if pv.vt != VT_LPWSTR || pv.a == 0 {
		return 0
	}
	w := ([^]u16)(uintptr(pv.a))
	n := 0
	for w[n] != 0 {
		n += 1
	}
	return len(win.utf16_to_utf8(buf, w[:n]))
}

// WASAPI and the MMDevice API, as far as used here.

@(private = "file")
Wave_Format :: struct #packed {
	format_tag:        u16,
	channels:          u16,
	samples_per_sec:   u32,
	avg_bytes_per_sec: u32,
	block_align:       u16,
	bits_per_sample:   u16,
	size:              u16,
}

@(private = "file")
Wave_Format_Extensible :: struct #packed {
	using _:      Wave_Format,
	valid_bits:   u16,
	channel_mask: u32,
	sub_format:   win.GUID,
}
#assert(size_of(Wave_Format) == 18 && size_of(Wave_Format_Extensible) == 40)

// PROPVARIANT: the type, then a pointer or a BLOB's size and pointer.
@(private = "file")
Prop_Variant :: struct {
	vt:       u16,
	reserved: [3]u16,
	a, b:     u64,
}

@(private = "file")
Property_Key :: struct {
	fmtid: win.GUID,
	pid:   u32,
}

@(private = "file")
IMMDeviceEnumerator :: struct {
	vtbl: ^struct {
		using _:                 Unknown_Vtbl(IMMDeviceEnumerator),
		EnumAudioEndpoints:      rawptr,
		GetDefaultAudioEndpoint: proc "system" (this: ^IMMDeviceEnumerator, flow, role: u32, dev: ^^IMMDevice) -> i32,
	},
}

@(private = "file")
IMMDevice :: struct {
	vtbl: ^struct {
		using _:           Unknown_Vtbl(IMMDevice),
		Activate:          proc "system" (this: ^IMMDevice, iid: ^win.GUID, ctx: u32, params: rawptr, out: ^rawptr) -> i32,
		OpenPropertyStore: proc "system" (this: ^IMMDevice, access: u32, store: ^^IPropertyStore) -> i32,
		GetId:             proc "system" (this: ^IMMDevice, id: ^[^]u16) -> i32,
	},
}

@(private = "file")
IPropertyStore :: struct {
	vtbl: ^struct {
		using _:  Unknown_Vtbl(IPropertyStore),
		GetCount: rawptr,
		GetAt:    rawptr,
		GetValue: proc "system" (this: ^IPropertyStore, key: ^Property_Key, value: ^Prop_Variant) -> i32,
	},
}

@(private = "file")
IAudioClient :: struct {
	vtbl: ^struct {
		using _:           Unknown_Vtbl(IAudioClient),
		Initialize:        proc "system" (this: ^IAudioClient, mode, flags: u32, buffer, period: i64, format: ^Wave_Format_Extensible, session: ^win.GUID) -> i32,
		GetBufferSize:     proc "system" (this: ^IAudioClient, frames: ^u32) -> i32,
		GetStreamLatency:  rawptr,
		GetCurrentPadding: rawptr,
		IsFormatSupported: proc "system" (this: ^IAudioClient, mode: u32, format: ^Wave_Format_Extensible, closest: ^^Wave_Format_Extensible) -> i32,
		GetMixFormat:      proc "system" (this: ^IAudioClient, format: ^^Wave_Format_Extensible) -> i32,
		GetDevicePeriod:   proc "system" (this: ^IAudioClient, default_period, min_period: ^i64) -> i32,
		Start:             proc "system" (this: ^IAudioClient) -> i32,
		Stop:              proc "system" (this: ^IAudioClient) -> i32,
		Reset:             proc "system" (this: ^IAudioClient) -> i32,
		SetEventHandle:    proc "system" (this: ^IAudioClient, event: win.HANDLE) -> i32,
		GetService:        proc "system" (this: ^IAudioClient, iid: ^win.GUID, out: ^rawptr) -> i32,
	},
}

@(private = "file")
IAudioRenderClient :: struct {
	vtbl: ^struct {
		using _:       Unknown_Vtbl(IAudioRenderClient),
		GetBuffer:     proc "system" (this: ^IAudioRenderClient, frames: u32, data: ^[^]u8) -> i32,
		ReleaseBuffer: proc "system" (this: ^IAudioRenderClient, frames: u32, flags: u32) -> i32,
	},
}

@(private = "file")
Unknown_Vtbl :: struct($T: typeid) {
	QueryInterface: rawptr,
	AddRef:         proc "system" (this: ^T) -> u32,
	Release:        proc "system" (this: ^T) -> u32,
}

foreign import ole32 "system:Ole32.lib"
foreign import avrt "system:avrt.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign ole32 {
	PropVariantClear :: proc(pv: ^Prop_Variant) -> i32 ---
}

@(private = "file")
@(default_calling_convention = "system")
foreign avrt {
	AvSetMmThreadCharacteristicsW :: proc(task: win.wstring, index: ^u32) -> win.HANDLE ---
	AvRevertMmThreadCharacteristics :: proc(handle: win.HANDLE) -> win.BOOL ---
}

@(private = "file")
CLSID_MMDeviceEnumerator := win.GUID{0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
@(private = "file")
IID_IMMDeviceEnumerator := win.GUID{0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
@(private = "file")
IID_IAudioClient := win.GUID{0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}}
@(private = "file")
IID_IAudioRenderClient := win.GUID{0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}}
@(private = "file")
KSDATAFORMAT_SUBTYPE_PCM := win.GUID{0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
@(private = "file")
KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := win.GUID{0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
@(private = "file")
PKEY_Device_FriendlyName := Property_Key{{0xA45C254E, 0xDF1C, 0x4EFD, {0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0}}, 14}
@(private = "file")
PKEY_AudioEngine_DeviceFormat := Property_Key{{0xF19F064D, 0x082C, 0x4E27, {0xBC, 0x73, 0x68, 0x82, 0xA1, 0xBB, 0x8E, 0x4C}}, 0}

@(private = "file")
E_RENDER :: 0
@(private = "file")
E_MULTIMEDIA :: 1
@(private = "file")
STGM_READ :: 0
@(private = "file")
VT_LPWSTR :: 31
@(private = "file")
VT_BLOB :: 65
@(private = "file")
WAVE_FORMAT_IEEE_FLOAT :: 3
@(private = "file")
WAVE_FORMAT_EXTENSIBLE :: 0xFFFE
@(private = "file")
SPEAKER_FRONT_LEFT :: 0x1
@(private = "file")
SPEAKER_FRONT_RIGHT :: 0x2
@(private = "file")
AUDCLNT_SHAREMODE_EXCLUSIVE :: 1
@(private = "file")
AUDCLNT_STREAMFLAGS_EVENTCALLBACK :: 0x0004_0000
@(private = "file")
AUDCLNT_BUFFERFLAGS_SILENT :: 0x2

// AUDCLNT_E_* HRESULTs, 0x8889_00xx as signed.
@(private = "file")
AUDCLNT_E_DEVICE_INVALIDATED :: i32(-2004287484)
@(private = "file")
AUDCLNT_E_BUFFER_TOO_LARGE :: i32(-2004287482)
@(private = "file")
AUDCLNT_E_UNSUPPORTED_FORMAT :: i32(-2004287480)
@(private = "file")
AUDCLNT_E_DEVICE_IN_USE :: i32(-2004287478)
@(private = "file")
AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED :: i32(-2004287474)
@(private = "file")
AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED :: i32(-2004287463)
