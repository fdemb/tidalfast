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
// The queue and where it was are kept on disk with the account's lists,
// so the next start shows the same track, paused at the same place
// (queue_save, playback_restore).
//
// With TIDALFAST_FAKE the fake rows play sine tones, 30 s each, so the
// player bar, queue and gapless switching work without an account.
//
// A PKCE login asks for HI_RES_LOSSLESS; a device-code login can only get
// LOSSLESS. Either may come back as DASH (see tidal.resolve_stream).

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import vmem "core:mem/virtual"
import "core:os"
import "core:slice"
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
	album_id:                    i64,
	artists:                     []Artist_Ref,
	row:                         int, // with the fake data, its row in State.rows
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

	// The queue: a snapshot of a list, strings in arena.
	arena:           vmem.Arena,
	has_arena:       bool,
	items:           []Queue_Item,
	entries:         []audio.Queue_Entry,
	order:           []int, // the items in play order, see queue_reorder
	loaded:          int, // rows loaded when the snapshot was taken
	list_key:        u64, // list_key of the list the queue came from
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
	save_key:        u64, // what the queue's file was last written for

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
	s.data.launch_log_path = launch_log_path(runtime.heap_allocator())
	if v, ok := strconv.parse_f32(os.get_env("TIDALFAST_VOLUME", context.temp_allocator)); ok {
		s.volume_before_override = s.settings.volume
		s.settings.volume = clamp(v, 0, 1)
	}
	when !audio.BIT_PERFECT {
		s.settings.bit_perfect, s.settings.hog = false, false
	}
	// The app died with a device switched to a track's rate. Put it back
	// before anything plays.
	if s.settings.device.rate != 0 {
		audio.device_change_undo(&s.settings.device)
		s.settings.device = {}
		settings_queue(&s.data, settings_to_save(s))
	}
	pb.player = audio.create(shell.request_redraw, s.settings.volume, small_str(&pb.capture), pb.window, pb.null_output, output_of(s.settings))
	pb.volume_sent = s.settings.volume
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
	pb.player = audio.create(shell.request_redraw, s.settings.volume, window = pb.window, null_output = pb.null_output, output = output_of(s.settings))
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
	if pb.player != nil && pb.index >= 0 && disk_on(&s.data) {
		pb.status = audio.status(pb.player)
		queue_write_now(&s.data, queue_file(pb, context.temp_allocator))
	}
	audio.destroy(pb.player)
	pb.player = nil
	// destroy put the device back.
	if s.settings.device.rate != 0 {
		s.settings.device = {}
		settings_queue(&s.data, settings_to_save(s), now = true)
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

// queue_snapshot copies v, the open list or the one the queue follows,
// into the queue. The fake data has only the open list.
@(private = "file")
queue_snapshot :: proc(s: ^State, v: ^Track_View) {
	pb := &s.playback
	n := view_count(s) if s.data.fake else v.count
	a := queue_reset(pb, n)
	pb.fake = s.data.fake
	s.data.queue_view = v.gen
	pb.loaded = v.loaded_rows
	for i in 0 ..< n {
		row := view_row(s, i) if s.data.fake else list_row(v, i)
		if row == nil {
			continue
		}
		queue_fill(pb, i, row, a)
		pb.items[i].row = fake_row_index(s, i)
		if pb.fake {
			pb.entries[i].id = -i64(i + 1)
		}
	}
}

// queue_reset makes a new, empty queue of n items, and returns its
// arena's allocator.
@(private = "file")
queue_reset :: proc(pb: ^Playback, n: int) -> runtime.Allocator {
	if pb.has_arena {
		vmem.arena_destroy(&pb.arena)
	}
	pb.has_arena = vmem.arena_init_growing(&pb.arena) == nil
	a := vmem.arena_allocator(&pb.arena)
	pb.items = make([]Queue_Item, n, a)
	pb.entries = make([]audio.Queue_Entry, n, a)
	pb.order = make([]int, n, a)
	audio.queue_order(pb.order, nil, false)
	return a
}

// queue_reorder puts the queue in list order, or with shuffle on, the
// items in head and then the rest shuffled.
@(private = "file")
queue_reorder :: proc(s: ^State, head: []int) {
	shuffle := s.settings.shuffle
	audio.queue_order(s.playback.order, head if shuffle else nil, shuffle)
}

// queue_fill makes queue item i row, its strings copied with a.
@(private = "file")
queue_fill :: proc(pb: ^Playback, i: int, row: ^Row, a: runtime.Allocator) {
	pb.items[i] = {
		title    = strings.clone(row.title, a),
		artist   = strings.clone(row.artist, a),
		album    = strings.clone(row.album, a),
		cover    = strings.clone(row.cover, a),
		seconds  = row.seconds,
		album_id = row.album_id,
		artists  = slice.clone(row.artists, a),
	}
	pb.entries[i] = {id = row.id, album_id = row.album_id, track_num = row.track}
}

// playback_play_row plays row i of the open list, with the rest of the
// list queued after it. A track preloaded from the old queue isn't reused,
// even at the same row.
playback_play_row :: proc(s: ^State, i: int) {
	if !row_playable(s, i) {
		return
	}
	queue_snapshot(s, &s.data.view)
	s.playback.list_key = list_key(s)
	queue_reorder(s, {i})
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
		volume_sent     = pb.volume_sent,
		serial          = pb.serial,
		queue_gen       = pb.queue_gen,
		save_key        = pb.save_key,
		index           = -1,
	}
	if pb.set_now_playing != nil {
		none: platform.Now_Playing
		pb.set_now_playing(&none)
	}
	s.library.playing = -1
}

// start_item makes queue item i the current track, from sample at, and
// plays it unless paused is set.
@(private = "file")
start_item :: proc(s: ^State, i: int, at: i64 = 0, paused := false) {
	pb := &s.playback
	if i < 0 || i >= len(pb.entries) || pb.entries[i].id == 0 {
		return
	}
	pb.index = i
	pb.paused = paused
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
			audio.play(pb.player, source_of(pb, &pb.cur), at, paused)
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
		audio.play(pb.player, {serial = pb.cur.serial}, at, paused)
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
			audio.play(pb.player, source_of(pb, t), t.at, pb.paused)
		} else {
			audio.set_next(pb.player, source_of(pb, t))
		}
		return
	}
	push_job(&s.data, {payload = Stream_Job{track = pb.entries[t.item].id, serial = t.serial}})
	request_artwork(s, t)
}

@(private = "file")
request_artwork :: proc(s: ^State, t: ^Track_Source) {
	pb := &s.playback
	if pb.fake || pb.items[t.item].cover == "" {
		return
	}
	image := Image_Job{id = small(pb.items[t.item].cover), size = ARTWORK_SIZE, fetch = ARTWORK_SIZE}
	push_job(&s.data, {payload = Artwork_Job{serial = t.serial, image = image}}, PRIORITY_COVER)
}

// artwork_result takes an Artwork job's result.
artwork_result :: proc(s: ^State, res: ^Result, job: Artwork_Job) {
	pb := &s.playback
	a: ^Artwork
	switch job.serial {
	case 0:
		return
	case pb.cur.serial:
		a = &pb.art
	case pb.next.serial:
		a = &pb.next_art
	case:
		return
	}
	img, ok := &res.payload.(Image_Result)
	if !ok || img.pixels == nil {
		return
	}
	artwork_free(a)
	a^ = {take(&img.pixels), img.w, img.h, job.serial}
}

// stream_result takes a Stream job's result.
stream_result :: proc(s: ^State, res: ^Result, job: Stream_Job) {
	pb := &s.playback
	t: ^Track_Source
	switch job.serial {
	case pb.cur.serial:
		t = &pb.cur
	case pb.next.serial:
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
			stream, _ := res.payload.(Stream_Result)
			pb.message = small(lossy_message(small_str(&stream.codec)))
			stop_current(pb)
			return
		}
		pb.message = small(fmt.tprintf("Couldn't play %s: %s", title, small_str(&res.message)))
		skip_failed(s)
		return
	}
	stream, _ := res.payload.(Stream_Result)
	info := stream.info
	mode := audio.queue_gain_mode(pb.entries, pb.order, t.item)
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
	// A restored position is in the rate it was saved at.
	if t.rate > 0 && info.sample_rate > 0 && t.rate != info.sample_rate {
		t.at = t.at * i64(info.sample_rate) / i64(t.rate)
	}
	t.rate = info.sample_rate
	t.resolved = true
	log.infof("app: track %d resolved: %s %s%s, %d-bit %d Hz, %s gain %.2f dB -> x%.3f", info.track_id, tidal.quality_name(info.quality), tidal.codec_name(info.codec), fmt.tprintf(" in DASH, %d segments", len(info.segments)) if info.dash else "", info.bit_depth, info.sample_rate, mode, 20 * math.log10(f64(t.gain)), t.gain)
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
	// Not round again on repeat: a queue where nothing plays would go on
	// asking for streams.
	n := audio.queue_next(pb.entries, pb.order, pb.index)
	if n < 0 {
		stop_current(pb)
		return
	}
	msg := pb.message
	start_item(s, n, paused = pb.paused)
	pb.message = msg
}

// stop_current drops the current track after a failure that ends playback.
// The player was playing its placeholder's silence, so it stops too.
@(private = "file")
stop_current :: proc(pb: ^Playback) {
	source_clear(&pb.cur)
	pb.paused = true
	audio.stop(pb.player)
}

playback_next :: proc(s: ^State) {
	pb := &s.playback
	if n := audio.queue_after(pb.entries, pb.order, pb.index, s.settings.repeat, user = true); n >= 0 {
		start_item(s, n)
	}
}

playback_previous :: proc(s: ^State) {
	pb := &s.playback
	if pb.index < 0 {
		return
	}
	i := audio.queue_previous_action(pb.entries, pb.order, pb.index, playback_position(s))
	if i == pb.index {
		playback_seek(s, 0)
	} else {
		start_item(s, i)
	}
}

// playback_set_shuffle turns shuffle on or off. Turning it on shuffles
// what's after the current track; off goes back to list order from it.
playback_set_shuffle :: proc(s: ^State, on: bool) {
	pb := &s.playback
	s.settings.shuffle = on
	settings_queue(&s.data, settings_to_save(s))
	if pb.index >= 0 {
		queue_reorder(s, {pb.index})
		next_drop(pb)
	}
}

playback_set_repeat :: proc(s: ^State, repeat: audio.Repeat) {
	pb := &s.playback
	s.settings.repeat = repeat
	settings_queue(&s.data, settings_to_save(s))
	next_drop(pb)
}

// next_drop forgets the preloaded next track after what comes next has
// changed. The player then asks for the next one again.
@(private = "file")
next_drop :: proc(pb: ^Playback) {
	if pb.next.serial == 0 || pb.status.serial == pb.next.serial {
		return
	}
	source_clear(&pb.next)
	artwork_free(&pb.next_art)
	audio.set_next(pb.player, {})
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
		if first := audio.queue_next(pb.entries, pb.order, -1); first >= 0 {
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
		// The silent placeholder holds the position status reports.
		if !pb.fake {
			audio.play(pb.player, {serial = pb.cur.serial}, sample, pb.paused)
		}
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

// playback_set_volume sets the volume, and saves it when save is set, as
// at the end of a drag.
playback_set_volume :: proc(s: ^State, v: f32, save: bool) {
	pb := &s.playback
	s.settings.volume = v
	if pb.player != nil && v != pb.volume_sent {
		audio.set_volume(pb.player, v)
		pb.volume_sent = v
	}
	if save {
		s.volume_before_override = nil
		settings_queue(&s.data, s.settings)
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

// playback_media runs the media commands among events.
playback_media :: proc(s: ^State, events: []platform.Event) {
	for e in events {
		if e.kind != .Media {
			continue
		}
		switch e.media {
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
}

// playback_observe takes in the player's status: it keeps the device
// change on disk, settles seeks, and moves the queue on.
playback_observe :: proc(s: ^State, status: audio.Status) {
	pb := &s.playback
	pb.status = status
	st := &pb.status
	// Keep what bit-perfect output changed on the device on disk while it
	// lasts, so a start after a crash can put it back.
	if st.change != s.settings.device {
		s.settings.device = st.change
		settings_queue(&s.data, settings_to_save(s))
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
		if n := audio.queue_after(pb.entries, pb.order, pb.index, s.settings.repeat, user = false); n >= 0 && !next_failed(pb, n) {
			pb.serial += 1
			pb.next = {serial = pb.serial, queue = pb.queue_gen, item = n, track = pb.entries[n].id}
			resolve(s, &pb.next)
		}
	}
	// The queue ran out, or the next track wasn't ready in time.
	if st.state == .Ended && st.serial == pb.cur.serial && st.serial != 0 {
		if n := audio.queue_after(pb.entries, pb.order, pb.index, s.settings.repeat, user = false); n >= 0 && pb.next.serial == 0 {
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
}

// playback_update runs once a frame after data_update: media commands,
// the player's status, the queue moving on, and Now Playing.
playback_update :: proc(s: ^State, events: []platform.Event) {
	pb := &s.playback
	if pb.player == nil {
		return
	}
	playback_media(s, events)
	playback_observe(s, audio.status(pb.player))

	// Keep the queue in step with its list while pages arrive, whether or
	// not the list is still open. A page that came back short moves the
	// rows after it up, and the queue's tracks with them.
	d := &s.data
	if v := queue_list(d); !pb.fake && pb.index >= 0 && v != nil && pb.loaded != v.loaded_rows {
		index := pb.index
		played := order_played(s)
		queue_snapshot(s, v)
		pb.index = queue_find(pb, pb.cur.track, index)
		pb.cur.item = pb.index
		if pb.next.serial != 0 {
			pb.next.item = queue_find(pb, pb.next.track, pb.next.item)
		}
		if pb.next_failed.serial != 0 {
			pb.next_failed.item = queue_find(pb, pb.next_failed.track, pb.next_failed.item)
		}
		head := make([]int, len(played), context.temp_allocator)
		for p, i in played {
			head[i] = queue_find(pb, p.track, p.item)
		}
		queue_reorder(s, head)
	}
	if q := &d.queued; q.source != .None && (q.gen != d.queue_view || q.done && q.in_flight == 0 && (pb.index < 0 || pb.loaded == q.loaded_rows)) {
		queued_drop(d)
	}
	s.library.playing = playing_row(s)
	update_now_playing(s)
	queue_save(s)
}

@(private = "file")
Queue_Place :: struct {
	item:  int,
	track: i64,
}

// order_played is the queue's items in play order up to the current one,
// then the next if it's chosen, by track and item. When pages move items,
// the order keeps those and shuffles the rest again.
@(private = "file")
order_played :: proc(s: ^State) -> []Queue_Place {
	if !s.settings.shuffle {
		return nil
	}
	pb := &s.playback
	out := make([dynamic]Queue_Place, context.temp_allocator)
	for i in pb.order {
		append(&out, Queue_Place{i, pb.entries[i].id})
		if i == pb.index {
			break
		}
	}
	if pb.next.serial != 0 {
		append(&out, Queue_Place{pb.next.item, pb.next.track})
	}
	return out[:]
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

// queue_save writes the queue's file when what it holds changes: the
// queue, its current track, pause, a finished seek or the end. The running
// position isn't one of those; playback_shutdown writes the last one. A
// queue that stopped is deleted, so it doesn't come back.
@(private = "file")
queue_save :: proc(s: ^State) {
	pb := &s.playback
	if pb.fake {
		return
	}
	key: u64
	if pb.index >= 0 {
		key = 14695981039346656037
		ended := pb.status.state == .Ended && pb.status.serial == pb.cur.serial
		count, loaded := u64(len(pb.entries)), u64(pb.loaded)
		if v := queue_list(&s.data); v != nil && v.error.len == 0 && !view_complete(v) {
			count, loaded = 0, floor_pow2(loaded)
		}
		for v in ([]u64{u64(pb.queue_gen), count, loaded, u64(pb.index), u64(pb.cur.track), u64(pb.paused), u64(pb.status.seek_id), u64(ended)}) {
			key = (key ~ v) * 1099511628211
		}
	}
	if key == pb.save_key {
		return
	}
	pb.save_key = key
	if key == 0 {
		disk_push(&s.data, {op = .Delete_Queue})
		return
	}
	disk_push(&s.data, {op = .Write_Queue, blob = queue_file(pb, runtime.heap_allocator())})
}

@(private = "file")
floor_pow2 :: proc(n: u64) -> u64 {
	return 0 if n == 0 else 1 << (63 - intrinsics.count_leading_zeros(n))
}

// queue_file is the queue as its file, at the current position.
@(private = "file")
queue_file :: proc(pb: ^Playback, allocator: runtime.Allocator) -> []u8 {
	st := &pb.status
	head := Queue_Header {
		index    = i64(pb.index),
		sample   = pb.cur.at,
		rate     = i64(pb.cur.rate),
		list_key = pb.list_key,
	}
	if st.serial != 0 && st.serial == pb.cur.serial {
		head.sample = st.sample
		if st.rate > 0 {
			head.rate = i64(st.rate)
		}
		if st.state == .Ended {
			head.sample = 0
		}
	}
	if pb.seek_id != 0 && pb.seek_serial == pb.cur.serial {
		head.sample = pb.seek_sample
	}
	rows := make([]Row, len(pb.items), context.temp_allocator)
	for &it, i in pb.items {
		e := pb.entries[i]
		rows[i] = {
			title    = it.title,
			artist   = it.artist,
			album    = it.album,
			cover    = it.cover,
			seconds  = it.seconds,
			id       = e.id,
			album_id = it.album_id,
			artists  = it.artists,
			track    = e.track_num,
		}
	}
	return queue_encode(head, rows, allocator)
}

// playback_restore takes the queue's file read at sign-in: the queue comes
// back with its track paused where it was, its stream resolving so play
// starts at once.
playback_restore :: proc(s: ^State, file: Queue_File_Result) {
	pb := &s.playback
	if pb.index >= 0 || s.data.fake || pb.player == nil || len(file.rows) == 0 {
		return
	}
	head := file.header
	a := queue_reset(pb, len(file.rows))
	for &row, i in file.rows {
		queue_fill(pb, i, &row, a)
	}
	pb.fake = false
	pb.list_key = head.list_key
	// A gen no view is given, so playback_update never takes the queue
	// for a snapshot of the open list.
	s.data.queue_view = view_gen(&s.data)
	pb.loaded = len(file.rows)
	pb.queue_gen += 1
	i := int(head.index)
	at := head.sample
	if i < 0 || i >= len(pb.entries) || pb.entries[i].id == 0 {
		i = audio.queue_next(pb.entries, pb.order, clamp(i, 0, len(pb.entries)) - 1)
		at = 0
	}
	if i < 0 {
		queue_reset(pb, 0)
		return
	}
	queue_reorder(s, {i})
	start_item(s, i, max(at, 0), paused = true)
	pb.cur.rate = int(head.rate)
	log.infof("app: resumed the queue at item %d of %d, %.1f s in", i, len(pb.entries), playback_position(s))
}
