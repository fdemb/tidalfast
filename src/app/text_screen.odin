package app

import "core:fmt"
import "core:log"
import "core:math"
import "core:time"

import "../render"
import "../text"

ROW_H :: 28
LIST_X :: 440

TEXT_COLOR :: render.Color{0.93, 0.93, 0.93, 1}
DIM_COLOR :: render.Color{0.64, 0.64, 0.64, 1}

// draw_text_screen draws specimen lines on the left (scripts, weights,
// sizes, emoji and truncation) and the ROW_COUNT row list on the right.
// Only the rows in view are drawn, so the cost doesn't depend on ROW_COUNT.
draw_text_screen :: proc(s: ^State, w, h: f32) {
	r := &s.renderer
	if s.rows == nil {
		s.rows = make_rows(persistent_allocator(s)) // only the fake data makes them at start
	}
	render.push_rect(r, {0, 0, w, h}, {0.07, 0.07, 0.08, 1})

	x: f32 = 24
	y: f32 = 20
	line :: proc(s: ^State, x: f32, y: ^f32, font: text.Font, size: f32, str: string, max_width: f32 = 0, color := TEXT_COLOR) {
		m := text.draw(&s.text, &s.renderer, font, size, {x, y^}, color, str, max_width)
		y^ += m.height + 6
	}
	line(s, x, &y, .Semibold, 20, "TIDALfast text")
	line(s, x, &y, .Regular, 13, "The quick brown fox jumps over the lazy dog. 0123456789")
	line(s, x, &y, .Regular, 11, "Small 11: Hamburg Sinfonietta, Björk, Sigur Rós, Łódź")
	for font, i in ([4]text.Font{.Regular, .Medium, .Semibold, .Bold}) {
		names := [4]string{"Regular", "Medium", "SemiBold", "Bold"}
		line(s, x, &y, font, 15, fmt.tprintf("%s 15: Hyperballad, Avril 14th", names[i]))
	}
	line(s, x, &y, .Regular, 24, "Big 24: Ça plane pour moi")
	line(s, x, &y, .Regular, 15, "CJK: 夜に駆ける 千本桜 月亮代表我的心 밤편지")
	line(s, x, &y, .Regular, 15, "Arabic: أنا لحبيبي · إنت عمري")
	line(s, x, &y, .Regular, 15, "Hebrew: ירושלים של זהב")
	line(s, x, &y, .Regular, 15, "Mixed: abc ابجد 123 هوز def")
	line(s, x, &y, .Regular, 15, "Mixed: Song שיר לשלום 2024 end")
	line(s, x, &y, .Regular, 15, "عيونك (Remix) 2024")
	line(s, x, &y, .Regular, 15, "abc (שלום) def, שלום (abc) עולם")
	line(s, x, &y, .Regular, 15, "Emoji: 😀 🎵 👨‍👩‍👧 🇵🇱 🏳️‍🌈 ❤️ 1️⃣")
	line(s, x, &y, .Bold, 15, "Bold fallback: 晴天 عيونك 🔥")

	// Truncation, with the box the text has to fit in.
	box_w: f32 = 260
	for str in ([3]string{"A very long title that will never fit in this narrow column", "Symphony No. 9 in D Minor, Op. 125: IV. Presto", "إنت عمري يا حبيبي يا نور العين يا ساكن خيالي يا أغلى من عيني"}) {
		render.push_rect(r, {x - 2, y - 2, box_w + 4, 22}, {1, 1, 1, 0.12}, 3, 1)
		line(s, x, &y, .Medium, 13, str, box_w)
		y += 6
	}
	if s.bench.running && !s.bench.ui && BENCH_PHASES[s.bench.phase].name == "scripts" {
		b := &s.bench
		count := min(b.frame / SCRIPT_FRAMES + 1, len(BENCH_SCRIPTS))
		if b.frame % SCRIPT_FRAMES == 0 {
			b.script_added = time.tick_now()
			b.script_frame = b.frame
		}
		for str, i in BENCH_SCRIPTS[:count] {
			run := text.shape(&s.text, .Regular, 15, str)
			y += text.draw_run(&s.text, r, run, {x, y}, TEXT_COLOR).height + 6
			if i == count - 1 && !run.pending && b.script_frame >= 0 {
				log.infof("bench: scripts: %s drawn with its font %d frames, %.1f ms after it was added", str, b.frame - b.script_frame, time.duration_milliseconds(time.tick_since(b.script_added)))
				b.script_frame = -1
			}
		}
	}
	draw_list(s, {LIST_X, 0, w - LIST_X, h})
}

draw_list :: proc(s: ^State, list: render.Rect) {
	r := &s.renderer
	t := &s.text
	render.push_rect(r, list, {0.10, 0.10, 0.12, 1})

	max_offset := max(f32(ROW_COUNT * ROW_H) - list.h, 0)
	if s.bench.running && !s.bench.ui {
		s.dev.scroll.y = -bench_offset(s, list.h)
	}
	s.dev.scroll.y = clamp(s.dev.scroll.y, -max_offset, 0)
	offset := -s.dev.scroll.y

	title_w: f32 = 280
	artist_w: f32 = 190
	line_h := text.line_height(t, .Regular, 13)
	render.push_clip(r, list)
	first := int(offset / ROW_H)
	last := min(int((offset + list.h) / ROW_H) + 1, ROW_COUNT)
	for i in first ..< last {
		y := list.y + f32(i) * ROW_H - offset
		if i % 2 == 1 {
			render.push_rect(r, {list.x, y, list.w, ROW_H}, {1, 1, 1, 0.03})
		}
		row := s.rows[i]
		ty := y + (ROW_H - line_h) / 2
		x := list.x + 16
		number := fmt.tprint(i + 1)
		text.draw(t, r, .Regular, 13, {x + 36 - text.measure(t, .Regular, 13, number).width, ty}, DIM_COLOR, number)
		x += 52
		text.draw(t, r, .Medium, 13, {x, ty}, TEXT_COLOR, row.title, title_w)
		x += title_w + 16
		text.draw(t, r, .Regular, 13, {x, ty}, DIM_COLOR, row.artist, artist_w)
		d := text.measure(t, .Regular, 13, row.duration)
		text.draw(t, r, .Regular, 13, {list.x + list.w - 20 - d.width, ty}, DIM_COLOR, row.duration)
	}
	render.pop_clip(r)
}

// TIDALFAST_BENCH=1 scrolls the list by itself and logs the time spent
// building each frame (ui) and the whole frame, per phase: warm goes back
// and forth over rows already shaped, cold scrolls steadily into rows never
// seen, jump shows a whole new page every frame, and scripts scrolls while
// adding a line in a script no font loaded so far covers every SCRIPT_FRAMES
// frames, logging the frame that adds it.
Bench :: struct {
	running:    bool,
	ui:         bool, // the library's track table instead of the text list
	phase:      int,
	frame:      int,
	count:      int,
	ui_sum:     f64,
	ui_max:     f32,
	frame_sum:  f64,
	frame_max:  f32,
	shaped:     int,
	rasterized: int,
	// scripts phase: when the latest line was added, -1 once it's drawn
	// with its font.
	script_added: time.Tick,
	script_frame: int,
}

Bench_Phase :: struct {
	name:   string,
	frames: int,
	skip:   int, // frames not measured, while the cache warms up
}

// The library bench: warm scrolls back and forth over rows already built,
// cold scrolls 3 rows a frame into rows never seen, jump shows a new page
// every frame.
UI_BENCH_PHASES := [?]Bench_Phase{{"settle", 60, 60}, {"warm", 360, 120}, {"cold", 300, 0}, {"jump", 200, 0}}

BENCH_PHASES := [?]Bench_Phase{{"settle", 60, 60}, {"warm", 360, 120}, {"cold", 300, 0}, {"jump", 200, 0}, {"scripts", SCRIPT_FRAMES * len(BENCH_SCRIPTS), 0}}

SCRIPT_FRAMES :: 30

// Scripts the specimen lines and the list don't use.
BENCH_SCRIPTS := [?]string{"Thai: เพลงรัก", "Devanagari: प्रेम गीत", "Georgian: სიყვარული", "Armenian: Սեր", "Ethiopic: ፍቅር", "Tamil: காதல்", "Khmer: ស្នេហា", "Sinhala: ආදරය"}

bench_phases :: proc(b: ^Bench) -> []Bench_Phase {
	return UI_BENCH_PHASES[:] if b.ui else BENCH_PHASES[:]
}

bench_offset :: proc(s: ^State, page: f32) -> f32 {
	f := f32(s.bench.frame)
	if s.bench.ui {
		switch UI_BENCH_PHASES[s.bench.phase].name {
		case "warm":
			return 600 + 600 * (1 - math.cos(f * 2 * math.PI / 120))
		case "cold":
			return 2000 * TRACK_ROW_H + f * 3 * TRACK_ROW_H
		case "jump":
			return 4000 * TRACK_ROW_H + f * page
		}
		return 0
	}
	switch BENCH_PHASES[s.bench.phase].name {
	case "warm":
		return 300 + 300 * (1 - math.cos(f * 2 * math.PI / 120))
	case "cold":
		return 1000 * ROW_H + f * 6 * ROW_H
	case "jump":
		return 4000 * ROW_H + f * page
	case "scripts":
		return 300 + 300 * (1 - math.cos(f * 2 * math.PI / 120))
	}
	return 0
}

bench_record :: proc(s: ^State, frame_ms: f32) {
	b := &s.bench
	phases := bench_phases(b)
	phase := phases[b.phase]
	if b.frame >= phase.skip {
		b.count += 1
		b.ui_sum += f64(s.ui_ms)
		b.ui_max = max(b.ui_max, s.ui_ms)
		b.frame_sum += f64(frame_ms)
		b.frame_max = max(b.frame_max, frame_ms)
		b.shaped += s.text.stats.shaped
		b.rasterized += s.text.stats.rasterized
	}
	if phase.name == "scripts" && b.frame % SCRIPT_FRAMES == 0 {
		log.infof("bench: scripts: added %s: ui %.3f ms, frame %.3f ms", BENCH_SCRIPTS[b.frame / SCRIPT_FRAMES], s.ui_ms, frame_ms)
	}
	b.frame += 1
	if b.frame < phase.frames {
		return
	}
	if b.count > 0 {
		log.infof("bench: %s: ui avg %.3f ms, max %.3f ms; frame avg %.3f ms, max %.3f ms; %d frames, %d runs shaped, %d glyphs rasterized",
			phase.name, b.ui_sum / f64(b.count), b.ui_max, b.frame_sum / f64(b.count), b.frame_max, b.count, b.shaped, b.rasterized)
	}
	b^ = {running = b.phase + 1 < len(phases), phase = b.phase + 1, ui = b.ui}
	if !b.running {
		log.info("bench: done")
	}
}
