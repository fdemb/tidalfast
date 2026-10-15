package app

// Playback on the UI thread's side: the play queue, resolving streams on
// the workers, handing tracks to src/audio, media commands, and Now Playing.
//
// Double-clicking a row snapshots the open list into the queue and plays
// from that row. Each track gets a serial. Its stream is resolved by a
// Stream job; the result goes to audio.play, or to audio.set_next when the
// player asks for the following track ahead of time, which is how gapless
// works. The player's status says which serial is audible, and when that is
// the next track's, the queue moves on.
//
// Hot reload: the audio callback, the decode thread and the fetch threads
// all run dylib code, so unload destroys the player (a short silence) and
// reload makes a new one and plays the same sources from where they were.
// The sources' URLs are in heap memory that outlives the dylib.
//
// With TIDALFAST_FAKE the fake rows play sine tones, 30 s each, so the
// player bar, queue and gapless switching work without an account.
//
// A PKCE login asks for HI_RES_LOSSLESS; a device-code login can only get
// LOSSLESS. Either may come back as DASH (see tidal.resolve_stream).

import "base:runtime"
import "core:fmt"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
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
	player:          ^audio.Player, // nil while the dylib is unloaded
	set_now_playing: proc "c" (info: ^platform.Now_Playing), // the shell's
	capture:         Small, // TIDALFAST_AUDIO_CAPTURE, for the first player only
	window:          int, // TIDALFAST_AUDIO_WINDOW_KB, in bytes
	null_output:     bool, // TIDALFAST_AUDIO_NULL: play to miniaudio's silent null device
	settings:        Settings, // bit-perfect and hog mode, see settings.odin
	settings_path:   string, // heap

	// The queue: a snapshot of a list, strings in arena.
	arena:           vmem.Arena,
	has_arena:       bool,
	items:           []Queue_Item,
	entries:         []audio.Queue_Entry,
	loaded:          int, // rows loaded when the snapshot was taken
	list_key:        u64, // list_key of the list the queue came from
	view_gen:        u32,
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
	resume_sample:   i64, // position kept across a reload
	seek_id:         u32, // waiting for this seek to show up in status
	seek_serial:     u64, // the source it's for; it's dropped once that isn't current
	seek_sample:     i64,
	seek_seconds:    f64,
	dragging:        bool, // the progress bar is held: show the drag position
	drag_seconds:    f64,
	volume_sent:     f32,
	message:         Small,
	error_seen:      u64,

	art:             Artwork, // the current track's, for Now Playing
	next_art:        Artwork, // the next track's, fetched with its stream
	np_key:          u64, // what was last sent to Now Playing

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
	pb.capture = small(os.get_env("TIDALFAST_AUDIO_CAPTURE", context.temp_allocator))
	pb.window = audio.STREAM_WINDOW
	if kb, ok := strconv.parse_int(os.get_env("TIDALFAST_AUDIO_WINDOW_KB", context.temp_allocator)); ok {
		pb.window = kb << 10
	}
	pb.null_output = os.get_env("TIDALFAST_AUDIO_NULL", context.temp_allocator) != ""
	if v, ok := strconv.parse_f32(os.get_env("TIDALFAST_VOLUME", context.temp_allocator)); ok {
		s.library.volume = clamp(v, 0, 1)
	}
	pb.settings_path = settings_default_path(runtime.heap_allocator())
	s.data.settings_path = strings.clone(pb.settings_path, runtime.heap_allocator())
	pb.settings, _ = settings_load(pb.settings_path)
	// The app died with a device switched to a track's rate. Put it back
	// before anything plays.
	if pb.settings.device.rate != 0 {
		audio.device_change_undo(&pb.settings.device)
		pb.settings.device = {}
		settings_queue(&s.data, pb.settings)
	}
	pb.player = audio.create(shell.request_redraw, s.library.volume, small_str(&pb.capture), pb.window, pb.null_output, output_of(pb.settings))
	pb.volume_sent = s.library.volume
}

playback_unload :: proc(s: ^State) {
	pb := &s.playback
	if pb.player == nil {
		return
	}
	st := audio.status(pb.player)
	pb.resume_sample = st.sample if st.serial == pb.cur.serial else pb.cur.at
	if pb.seek_id != 0 && pb.seek_serial == pb.cur.serial {
		pb.resume_sample = pb.seek_sample
	}
	audio.destroy(pb.player)
	pb.player = nil
}

playback_reload :: proc(s: ^State, shell: ^platform.Shell) {
	pb := &s.playback
	pb.set_now_playing = shell.set_now_playing
	pb.player = audio.create(shell.request_redraw, s.library.volume, window = pb.window, null_output = pb.null_output, output = output_of(pb.settings))
	// The new player's seek ids start again; a pending seek is in resume_sample.
	pb.seek_id = 0
	if pb.cur.resolved {
		pb.cur.at = pb.resume_sample
		audio.play(pb.player, source_of(pb, &pb.cur), pb.resume_sample, pb.paused)
	}
	if pb.next.resolved {
		audio.set_next(pb.player, source_of(pb, &pb.next))
	}
	pb.np_key = 0
}

playback_shutdown :: proc(s: ^State) {
	pb := &s.playback
	audio.destroy(pb.player)
	pb.player = nil
	// destroy put the device back.
	if pb.settings.device.rate != 0 {
		pb.settings.device = {}
		settings_queue(&s.data, pb.settings, now = true)
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
	delete(pb.settings_path, runtime.heap_allocator())
	pb.settings_path = ""
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

// queue_snapshot copies the open list into the queue.
@(private = "file")
queue_snapshot :: proc(s: ^State) {
	pb := &s.playback
	if pb.has_arena {
		vmem.arena_destroy(&pb.arena)
	}
	pb.has_arena = vmem.arena_init_growing(&pb.arena) == nil
	a := vmem.arena_allocator(&pb.arena)
	n := view_count(s)
	pb.items = make([]Queue_Item, n, a)
	pb.entries = make([]audio.Queue_Entry, n, a)
	pb.fake = s.data.fake
	pb.list_key = list_key(s)
	pb.view_gen = s.data.view.gen
	pb.loaded = s.data.view.loaded_rows
	for i in 0 ..< n {
		row := view_row(s, i)
		if row == nil {
			continue
		}
		pb.items[i] = {
			title   = strings.clone(row.title, a),
			artist  = strings.clone(row.artist, a),
			album   = strings.clone(row.album, a),
			cover   = strings.clone(row.cover, a),
			seconds = row.seconds,
		}
		pb.entries[i] = {id = row.id, album_id = row.album_id, track_num = row.track}
		if pb.fake {
			pb.entries[i].id = -i64(i + 1)
		}
	}
}

// playback_play_row plays row i of the open list, with the rest of the
// list queued after it. A track preloaded from the old queue isn't reused,
// even at the same row.
playback_play_row :: proc(s: ^State, i: int) {
	if row := view_row(s, i); row == nil || (row.id == 0 && !s.data.fake) {
		return
	}
	queue_snapshot(s)
	s.playback.queue_gen += 1
	start_item(s, i)
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
		capture         = pb.capture,
		window          = pb.window,
		null_output     = pb.null_output,
		settings        = pb.settings,
		settings_path   = pb.settings_path,
		volume_sent     = pb.volume_sent,
		serial          = pb.serial,
		queue_gen       = pb.queue_gen,
		index           = -1,
	}
	if pb.set_now_playing != nil {
		none: platform.Now_Playing
		pb.set_now_playing(&none)
	}
	s.library.playing = -1
}

// start_item makes queue item i the current track, from sample at.
@(private = "file")
start_item :: proc(s: ^State, i: int, at: i64 = 0) {
	pb := &s.playback
	if i < 0 || i >= len(pb.entries) || pb.entries[i].id == 0 {
		return
	}
	pb.index = i
	pb.paused = false
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
			audio.play(pb.player, source_of(pb, &pb.cur), at)
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
		audio.play(pb.player, {serial = pb.cur.serial}, at)
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
			audio.play(pb.player, source_of(pb, t), t.at)
		} else {
			audio.set_next(pb.player, source_of(pb, t))
		}
		return
	}
	push_job(&s.data, {kind = .Stream, key = u64(pb.entries[t.item].id), view = u32(t.serial)})
	request_artwork(s, t)
}

@(private = "file")
request_artwork :: proc(s: ^State, t: ^Track_Source) {
	pb := &s.playback
	if pb.fake || pb.items[t.item].cover == "" {
		return
	}
	push_job(&s.data, {kind = .Artwork, key = t.serial, size = ARTWORK_SIZE, fetch = ARTWORK_SIZE, id = small(pb.items[t.item].cover)}, PRIORITY_COVER)
}

// playback_result takes a Stream or Artwork job's result.
playback_result :: proc(s: ^State, res: ^Result) {
	pb := &s.playback
	if res.job.kind == .Artwork {
		a: ^Artwork
		switch res.job.key {
		case 0:
			return
		case pb.cur.serial:
			a = &pb.art
		case pb.next.serial:
			a = &pb.next_art
		case:
			return
		}
		if res.pixels == nil {
			return
		}
		artwork_free(a)
		a^ = {res.pixels, res.w, res.h, res.job.key}
		res.pixels = nil
		return
	}
	t: ^Track_Source
	switch u32(res.job.view) {
	case u32(pb.cur.serial):
		t = &pb.cur
	case u32(pb.next.serial):
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
			pb.message = small(lossy_message(small_str(&res.codec)))
			source_clear(&pb.cur)
			pb.paused = true
			return
		}
		pb.message = small(fmt.tprintf("Couldn't play %s: %s", title, small_str(&res.message)))
		skip_failed(s)
		return
	}
	info := res.stream
	mode := audio.queue_gain_mode(pb.entries, t.item)
	rg := audio.Replay_Gain{info.track_gain, info.track_peak, info.album_gain, info.album_peak}
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
	t.gain = audio.replay_gain_linear(rg, mode)
	t.rate = info.sample_rate
	t.resolved = true
	fmt.eprintfln("app: track %d resolved: %s %s%s, %d-bit %d Hz, %s gain %.2f dB -> x%.3f", info.track_id, tidal.quality_name(info.quality), tidal.codec_name(info.codec), fmt.tprintf(" in DASH, %d segments", len(info.segments)) if info.dash else "", info.bit_depth, info.sample_rate, mode, 20 * math.log10(f64(t.gain)), t.gain)
	if t == &pb.cur {
		audio.play(pb.player, source_of(pb, t), t.at, pb.paused)
	} else {
		audio.set_next(pb.player, source_of(pb, t))
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
	n := audio.queue_next(pb.entries, pb.index)
	if n < 0 {
		source_clear(&pb.cur)
		pb.paused = true
		return
	}
	msg := pb.message
	start_item(s, n)
	pb.message = msg
}

playback_next :: proc(s: ^State) {
	pb := &s.playback
	if n := audio.queue_next(pb.entries, pb.index); n >= 0 {
		start_item(s, n)
	}
}

playback_previous :: proc(s: ^State) {
	pb := &s.playback
	if pb.index < 0 {
		return
	}
	i := audio.queue_previous_action(pb.entries, pb.index, playback_position(s))
	if i == pb.index {
		playback_seek(s, 0)
	} else {
		start_item(s, i)
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
		if first := audio.queue_next(pb.entries, -1); first >= 0 {
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

playback_set_volume :: proc(s: ^State, v: f32) {
	pb := &s.playback
	if pb.player != nil && v != pb.volume_sent {
		audio.set_volume(pb.player, v)
		pb.volume_sent = v
	}
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

// playback_update runs once a frame after data_update: media commands,
// the player's status, the queue moving on, and Now Playing.
playback_update :: proc(s: ^State, events: []platform.Event) {
	pb := &s.playback
	if pb.player == nil {
		return
	}
	for e in events {
		if e.kind != .Media {
			continue
		}
		switch platform.Media_Command(e.key_code) {
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
		}
	}

	pb.status = audio.status(pb.player)
	st := &pb.status
	// Keep what bit-perfect output changed on the device on disk while it
	// lasts, so a start after a crash can put it back.
	if st.change != pb.settings.device {
		pb.settings.device = st.change
		settings_queue(&s.data, pb.settings)
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
	}
	// It wants the track after the current one.
	if st.want_next && pb.next.serial == 0 && st.serial == pb.cur.serial {
		if n := audio.queue_next(pb.entries, pb.index); n >= 0 && !next_failed(pb, n) {
			pb.serial += 1
			pb.next = {serial = pb.serial, queue = pb.queue_gen, item = n, track = pb.entries[n].id}
			resolve(s, &pb.next)
		}
	}
	// The queue ran out, or the next track wasn't ready in time.
	if st.state == .Ended && st.serial == pb.cur.serial && st.serial != 0 {
		if n := audio.queue_next(pb.entries, pb.index); n >= 0 && pb.next.serial == 0 {
			start_item(s, n)
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

	// Keep the queue in step with its list while pages arrive. A page that
	// came back short moves the rows after it up, and the queue's tracks
	// with them.
	if !pb.fake && pb.index >= 0 && pb.view_gen == s.data.view.gen && pb.loaded != s.data.view.loaded_rows {
		index := pb.index
		queue_snapshot(s)
		pb.index = queue_find(pb, pb.cur.track, index)
		pb.cur.item = pb.index
		if pb.next.serial != 0 {
			pb.next.item = queue_find(pb, pb.next.track, pb.next.item)
		}
		if pb.next_failed.serial != 0 {
			pb.next_failed.item = queue_find(pb, pb.next_failed.track, pb.next_failed.item)
		}
	}
	s.library.playing = playing_row(s)
	update_now_playing(s)
}

// next_failed says whether queue item i is the next track that failed to
// resolve in this queue.
@(private = "file")
next_failed :: proc(pb: ^Playback, i: int) -> bool {
	f := &pb.next_failed
	return f.serial != 0 && f.queue == pb.queue_gen && f.item == i && i < len(pb.entries) && f.track == pb.entries[i].id
}

// queue_find is the queue entry holding track: at, if it does, or else the
// nearest one before it, where a gap closing in the list moved it.
@(private = "file")
queue_find :: proc(pb: ^Playback, track: i64, at: int) -> int {
	if at >= 0 && at < len(pb.entries) && pb.entries[at].id == track {
		return at
	}
	for i := min(at, len(pb.entries) - 1); i >= 0; i -= 1 {
		if pb.entries[i].id == track {
			return i
		}
	}
	return at
}

// list_key names the open list: its kind and TIDAL id, or the search's
// query. A list opened again gets the same key, a different one another.
list_key :: proc(s: ^State) -> u64 {
	h: u64 = 14695981039346656037
	fnv :: proc(h: u64, b: u8) -> u64 {
		return (h ~ u64(b)) * 1099511628211
	}
	if s.data.fake {
		sr := &s.search
		h = fnv(h, u8(sr.fake_source))
		if sr.fake_source == .None {
			h = fnv(fnv(h, u8(s.library.playlist)), u8(s.library.playlist >> 8))
		}
		for b in transmute([]u8)small_str(&sr.fake_title) {
			h = fnv(h, b)
		}
		return h
	}
	v := &s.data.view
	if v.source == .None {
		return 0
	}
	h = fnv(h, u8(v.source))
	for b in transmute([]u8)small_str(&v.id) {
		h = fnv(h, b)
	}
	return h
}

// playing_row is the row of the open list that plays, or -1. Only the list
// the queue came from has one, so the same track in another list isn't
// lit. It's the queue's index while that row holds the track. After the
// list was opened again its rows may differ, so it's the first row with
// the track's id, looked for once each time the rows change.
playing_row :: proc(s: ^State) -> int {
	pb := &s.playback
	if pb.index < 0 || pb.index >= len(pb.entries) || pb.list_key != list_key(s) {
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

// update_now_playing tells macOS what plays when the track, its state, its
// length, a finished seek or the artwork changed. macOS moves the elapsed
// time along by itself from the rate.
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
