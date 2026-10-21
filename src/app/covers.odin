package app

// Cover art in the UI. Drawing a cover asks the cache for it at the size it
// shows at on this display. After the frame is built, covers_schedule
// queues a job for each new one, drops queued jobs for covers no longer on
// screen and evicts the least recently used textures over the budget. A
// cover shows a placeholder until its texture arrives, then fades in.

import "../cover"
import "../jobs"
import "../render"
import "../ui"

COVER_PREFETCH_ROWS :: 4 // rows above and below the view whose covers load too
DATA_SLOTS :: 16 // job queue slots covers leave free for data jobs

// cover_art draws a cover size points square, centred in a cell of width
// cell_w. Without an image id it draws the fake data's gradient for seed.
// A radius of half the size draws it round, as artist pictures are.
cover_art :: proc(s: ^State, kind: cover.Kind, id: string, seed: u32, size: f32, cell_w: ui.Size, radius: f32 = 4) {
	ui.column("", {}, cell_w, ui.fill())
	ui.spacer(ui.fill())
	{
		ui.row("", {}, ui.fill(), ui.px(size))
		ui.set_next_radius(radius)
		b := ui.box_make("", {.Draw_Background}, ui.px(size), ui.px(size))
		if id == "" {
			hue := f32(seed % 997) / 997
			b.background = hsv(hue, 0.55, 0.75)
			b.gradient = hsv(hue + 0.08, 0.7, 0.35)
		} else {
			b.background = SURFACE_ACTIVE
			e := cover_want(s, kind, id, size, PRIORITY_COVER)
			measure_count_cover(s, e != nil && e.state == .Ready)
			if e != nil && e.state == .Ready {
				ui.parent(b)
				ui.set_next_radius(b.radius)
				img := ui.box_make("", {}, ui.fill(), ui.fill())
				img.texture = cover.texture(&s.data.covers, e)
				img.texture_src = cover.src(&s.data.covers, e)
				img.opacity = cover.alpha(e, s.ui.time)
				if img.opacity < 1 {
					ui.request_frame()
				}
			}
		}
	}
	ui.spacer(ui.fill())
}

cover_want :: proc(s: ^State, kind: cover.Kind, id: string, points: f32, priority: u8) -> ^cover.Entry {
	if s.data.fake || id == "" {
		return nil
	}
	px := int(points * s.renderer.scale + 0.5)
	fetch := cover.pick_size(kind, points, s.renderer.scale)
	return cover.want(&s.data.covers, kind, id, px, fetch, s.frame_count, priority)
}

// cover_prefetch asks for the covers of rows [first, last) without drawing
// them, behind the visible ones.
cover_prefetch :: proc(s: ^State, first, last: int, points: f32) {
	for i in max(first, 0) ..< min(last, view_count(s)) {
		if row := view_row(s, i); row != nil {
			cover_want(s, .Album, row.cover, points, PRIORITY_COVER_NEAR)
		}
	}
}

@(private = "file")
Stale_Covers :: struct {
	cache: ^cover.Cache,
	frame: u64,
}

@(private = "file")
drop_stale_cover :: proc(job: ^Job, data: rawptr) -> bool {
	p, is_cover := job.payload.(Cover_Job)
	if !is_cover {
		return false
	}
	st := (^Stale_Covers)(data)
	e := cover.lookup(st.cache, p.key)
	if e != nil && e.wanted_frame == st.frame {
		return false
	}
	if e != nil {
		cover.remove(st.cache, e)
	}
	return true
}

// covers_schedule runs after the frame is built. Covers scrolled away
// before a worker got to them are dropped from the queue; the ones a
// worker already has finish and stay in the cache.
covers_schedule :: proc(s: ^State) {
	d := &s.data
	if d.fake {
		return
	}
	frame := s.frame_count
	st := Stale_Covers{&d.covers, frame}
	jobs.remove_if(&d.queue, drop_stale_cover, &st)
	// A cover the queue has no room for stays Wanted and is pushed again
	// next frame.
	room := jobs.room(&d.queue) - DATA_SLOTS
	for &e in d.covers.entries {
		switch e.state {
		case .Free, .Queued, .Ready:
		case .Wanted:
			if e.wanted_frame != frame {
				cover.remove(&d.covers, &e)
				continue
			}
			job := Job {
				payload = Cover_Job{key = e.key, image = {id = small(cover.entry_id(&e)), size = e.px, fetch = e.fetch}},
			}
			if room > 0 && jobs.push(&d.queue, job, e.priority) {
				e.state = .Queued
				room -= 1
			}
		case .Failed:
			// Forgotten once off screen, so it's tried again when it comes
			// back, or after a while if it stays.
			if e.wanted_frame != frame {
				cover.remove(&d.covers, &e)
			} else if s.ui.time - e.ready_time > cover.RETRY_SECONDS {
				e.state = .Wanted
			}
		}
	}
	n := cover.trim(&d.covers, frame, d.evicted[:])
	for t in d.evicted[:n] {
		render.texture_destroy(&s.renderer, t)
	}
}
