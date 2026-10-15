package app

// TIDALFAST_BENCH=covers, for running against tests/mock_tidal: once the
// sidebar loads it opens the longest playlist, waits for its first rows,
// then scrolls the track table by itself while covers stream in, and logs
// the frame times and cover upload times of each phase.

import "core:log"

import "../ui"

Cover_Bench :: struct {
	phase:     int,
	frame:     int,
	count:     int,
	ui_sum:    f64,
	ui_max:    f32,
	frame_sum: f64,
	frame_max: f32,
	uploads:   int, // covers uploaded this phase
	upload_ms: f32, // this frame's time in data_update, uploads included
	data_max:  f32, // the phase's longest data_update
	frame_uploads: int, // covers uploaded this frame
	most_uploads:  int, // the phase's most in one frame
	busiest_ms:    f32, // data_update in that frame
	running:   bool,
}

// wait: until the playlist is open with rows to scroll through. scroll: one
// row a frame, a new cover about every frame. fast: four rows a frame, so
// most covers are asked for and dropped before a worker gets to them.
// settle: still, while the last covers arrive and fade in.
COVER_BENCH_PHASES := [?]Bench_Phase{{"wait", 0, 0}, {"scroll", 600, 0}, {"fast", 300, 0}, {"settle", 120, 0}}

COVER_BENCH_MIN_ROWS :: 300

cover_bench_offset :: proc(s: ^State, list: ^ui.Box) -> f32 {
	b := &s.data.bench
	f := f32(b.frame)
	switch COVER_BENCH_PHASES[b.phase].name {
	case "scroll":
		return f * TRACK_ROW_H
	case "fast":
		return (600 + f * 4) * TRACK_ROW_H
	case "settle":
		return (600 + 300 * 4) * TRACK_ROW_H
	}
	return 0
}

cover_bench_record :: proc(s: ^State, frame_ms: f32) {
	d := &s.data
	b := &d.bench
	phase := COVER_BENCH_PHASES[b.phase]
	if phase.name == "wait" {
		if d.view.source == .None || d.view.source == .Liked {
			longest, most := -1, -1
			for item, i in d.sidebar.items {
				if item.tracks > most {
					longest, most = i, item.tracks
				}
			}
			if longest >= 0 {
				select_playlist(s, longest + 1)
			}
		} else if d.view.loaded_rows >= COVER_BENCH_MIN_ROWS || d.view.done {
			log.infof("bench: covers: %s, %d of %d rows loaded after %d frames", small_str(&d.view.name), d.view.loaded_rows, d.view.count, b.frame)
			b^ = {running = true, phase = 1}
		}
		b.frame += 1
		return
	}
	b.count += 1
	b.ui_sum += f64(s.ui_ms)
	b.ui_max = max(b.ui_max, s.ui_ms)
	b.frame_sum += f64(frame_ms)
	b.frame_max = max(b.frame_max, frame_ms)
	b.data_max = max(b.data_max, b.upload_ms)
	if b.frame_uploads > b.most_uploads {
		b.most_uploads = b.frame_uploads
		b.busiest_ms = b.upload_ms
	}
	b.frame_uploads = 0
	b.frame += 1
	if b.frame < phase.frames {
		return
	}
	log.infof("bench: covers: %s: ui avg %.3f ms, max %.3f ms; frame avg %.3f ms, max %.3f ms; %d frames; %d covers uploaded, results max %.3f ms a frame, at most %d uploads in a frame (%.3f ms); cache %d covers, %.1f MB",
		phase.name, b.ui_sum / f64(b.count), b.ui_max, b.frame_sum / f64(b.count), b.frame_max, b.count, b.uploads, b.data_max, b.most_uploads, b.busiest_ms, d.covers.used, f64(d.covers.bytes) / (1 << 20))
	b^ = {running = b.phase + 1 < len(COVER_BENCH_PHASES), phase = b.phase + 1}
	if !b.running {
		log.info("bench: done")
	}
}
