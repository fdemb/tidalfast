package tidal_tests

// The Linux shell's touchpad model (shell/scroll.c), which follows GTK 4's
// GtkScrolledWindow. Each test is one part of what docs/linux.md describes.

import "core:math"
import "core:testing"

@(private = "file")
C_BUILD :: #config(TIDALFAST_C_BUILD, "build")
@(private = "file")
SCROLL_OBJ :: "../" + C_BUILD + "/shell/scroll.o"

when !#exists(SCROLL_OBJ) {
	#panic("build/shell/scroll.o is missing: run ./build.py first")
}

foreign import scroll_c {SCROLL_OBJ, "system:m"}

@(private = "file")
Scroll_Sample :: struct {
	dx, dy: f64,
	ms:     u32,
}

@(private = "file")
Scroll_Kinetic :: struct {
	history: [256]Scroll_Sample,
	count:   i32,
	running: bool,
	start:   f64,
	v0:      [2]f64,
	done:    [2]f64,
	carry:   [2]f64,
}

@(private = "file")
Scroll_Step :: enum i32 {
	Idle,
	Moving,
	Finished,
}

@(private = "file")
@(default_calling_convention = "c")
foreign scroll_c {
	scroll_begin :: proc(k: ^Scroll_Kinetic, now: f64) ---
	scroll_finger :: proc(k: ^Scroll_Kinetic, d: ^[2]f64, ms: u32) ---
	scroll_release :: proc(k: ^Scroll_Kinetic, ms: u32, now: f64) -> bool ---
	scroll_hold :: proc(k: ^Scroll_Kinetic, now: f64) ---
	scroll_cancel :: proc(k: ^Scroll_Kinetic) ---
	scroll_step :: proc(k: ^Scroll_Kinetic, now: f64, d: ^[2]f64) -> Scroll_Step ---
}

// A swipe of frames every 8 ms, each moving dy as libinput sends it, from
// ms; returns the points the app was sent.
@(private = "file")
swipe :: proc(k: ^Scroll_Kinetic, dy: f64, frames: int, ms: u32, now: f64) -> f64 {
	scroll_begin(k, now)
	sent: f64
	for i in 0 ..< frames {
		d := [2]f64{0, dy}
		scroll_finger(k, &d, ms + u32(i) * 8)
		sent += d.y
	}
	return sent
}

// Steps the glide at 60 Hz from now until it ends; returns its distance.
@(private = "file")
glide_all :: proc(k: ^Scroll_Kinetic, now: f64) -> (total: f64, frames: int) {
	t := now
	for {
		t += 1.0 / 60
		d: [2]f64
		step := scroll_step(k, t, &d)
		total += d.y
		frames += 1
		if step != .Moving || frames > 10_000 {
			return
		}
	}
}

@(test)
test_scroll_fingers_scale_by_a_constant :: proc(t: ^testing.T) {
	// GTK scales surface deltas by 2.5 at any speed, with no gain of its own.
	k: Scroll_Kinetic
	testing.expect_value(t, swipe(&k, 1, 1, 0, 0), 2.5)
	k = {}
	testing.expect_value(t, swipe(&k, 40, 1, 0, 0), 100)
}

@(test)
test_scroll_release_speed_comes_from_event_times :: proc(t: ^testing.T) {
	// 11 frames 8 ms apart of 4 points (10 scaled), then the lift 8 ms after
	// the last: 110 points over 88 ms.
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 1000, 5)
	testing.expect(t, scroll_release(&k, 1088, 5))
	testing.expect_value(t, k.v0.y, 1250)

	// When the app reads the events doesn't matter, only their times.
	k = {}
	swipe(&k, 4, 11, 1000, 0)
	scroll_release(&k, 1088, 123)
	testing.expect_value(t, k.v0.y, 1250)
}

@(test)
test_scroll_only_the_last_150ms_count :: proc(t: ^testing.T) {
	// A slow start doesn't dilute a fast end: frames older than 150 ms
	// before the lift drop out.
	k: Scroll_Kinetic
	scroll_begin(&k, 0)
	for i in 0 ..< 50 {
		d := [2]f64{0, 0.4}
		scroll_finger(&k, &d, u32(i) * 8)
	}
	for i in 0 ..< 10 {
		d := [2]f64{0, 8}
		scroll_finger(&k, &d, 400 + u32(i) * 8)
	}
	scroll_release(&k, 480, 0)
	// Within [330, 480]: the slow frames from 336 to 392 (8 of 1 point)
	// and the 10 fast ones of 20 points, over 144 ms.
	testing.expect(t, math.abs(k.v0.y - 208.0 * 1000 / 144) < 1e-9)
}

@(test)
test_scroll_fingers_that_stop_before_lifting_leave_no_momentum :: proc(t: ^testing.T) {
	k: Scroll_Kinetic
	swipe(&k, 10, 10, 0, 0)
	testing.expect(t, !scroll_release(&k, 72 + 200, 0))
	d: [2]f64
	testing.expect_value(t, scroll_step(&k, 1, &d), Scroll_Step.Idle)
}

@(test)
test_scroll_glide_follows_gtk_curve :: proc(t: ^testing.T) {
	// GTK's glide: v0 / 4 * (1 - e^(-4t)), so 1250 pt/s goes 312.5 points.
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 0, 0)
	scroll_release(&k, 88, 10)
	d: [2]f64
	testing.expect_value(t, scroll_step(&k, 10.25, &d), Scroll_Step.Moving)
	testing.expect(t, math.abs(d.y - 312.5 * (1 - math.exp(-1.0))) < 1e-9)
	total, _ := glide_all(&k, 10.25)
	testing.expect(t, math.abs(d.y + total - 312.5) < 1e-9)
}

@(test)
test_scroll_glide_depends_on_frame_times_only :: proc(t: ^testing.T) {
	// However the frames fall, the glide is where the curve says at each.
	a, b: Scroll_Kinetic
	swipe(&a, 4, 11, 0, 0)
	swipe(&b, 4, 11, 0, 0)
	scroll_release(&a, 88, 0)
	scroll_release(&b, 88, 0)
	da, db: [2]f64
	sum_a, sum_b: f64
	for f in 1 ..= 30 {
		scroll_step(&a, f64(f) / 60, &da)
		sum_a += da.y
	}
	for f in ([]f64{0.003, 0.021, 0.022, 0.31, 0.4, 0.5}) {
		scroll_step(&b, f, &db)
		sum_b += db.y
	}
	testing.expect(t, math.abs(sum_a - sum_b) < 1e-9)
}

@(test)
test_scroll_glide_ends_with_its_whole_distance :: proc(t: ^testing.T) {
	k: Scroll_Kinetic
	swipe(&k, -4, 11, 0, 0)
	scroll_release(&k, 88, 0)
	total, frames := glide_all(&k, 0)
	testing.expect(t, math.abs(total + 312.5) < 1e-9)
	// It stops once under a quarter point is left: ln(1250 / 4 / 0.25) / 4
	// is about 1.78 s.
	testing.expect(t, frames > 100 && frames < 110, "the glide should end after about 1.8 s")
	d: [2]f64
	testing.expect_value(t, scroll_step(&k, 100, &d), Scroll_Step.Idle)
}

@(test)
test_scroll_hold_stops_the_glide :: proc(t: ^testing.T) {
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 0, 0)
	scroll_release(&k, 88, 0)
	d: [2]f64
	scroll_step(&k, 0.1, &d)
	scroll_hold(&k, 0.1)
	testing.expect_value(t, scroll_step(&k, 0.2, &d), Scroll_Step.Idle)
	testing.expect_value(t, d, [2]f64{})
}

@(test)
test_scroll_flings_add_up :: proc(t: ^testing.T) {
	// A second fling while the first glides adds the first's current speed,
	// as GTK's velocity accumulation: v + c * min((v - 0.33c) / (0.67c), 6).
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 0, 0)
	scroll_release(&k, 88, 0)
	c := 1250 * math.exp(-4 * 0.2)
	swipe(&k, 4, 11, 200, 0.2)
	scroll_release(&k, 288, 0.3)
	m := (1250 - 0.33 * c) / (c - 0.33 * c)
	testing.expect(t, math.abs(k.v0.y - (1250 + c * min(m, 6))) < 1e-6)
}

@(test)
test_scroll_a_glide_at_rest_adds_nothing :: proc(t: ^testing.T) {
	// No frame stepped the first glide to its end, as for a hidden window,
	// but by 5 s it would have stopped, so the next fling starts afresh.
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 0, 0)
	scroll_release(&k, 88, 0)
	swipe(&k, 4, 11, 5000, 5)
	scroll_release(&k, 5088, 5)
	testing.expect_value(t, k.v0.y, 1250)
}

@(test)
test_scroll_flings_against_the_glide_dont_add :: proc(t: ^testing.T) {
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 0, 0)
	scroll_release(&k, 88, 0)
	swipe(&k, -4, 11, 200, 0.2)
	scroll_release(&k, 288, 0.3)
	testing.expect_value(t, k.v0.y, -1250)
}

@(test)
test_scroll_a_hold_keeps_the_speed_for_the_next_fling :: proc(t: ^testing.T) {
	// GTK keeps an interrupted glide's speed until the next release.
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 0, 0)
	scroll_release(&k, 88, 0)
	scroll_hold(&k, 0.2)
	swipe(&k, 4, 11, 300, 0.3)
	scroll_release(&k, 388, 0.4)
	testing.expect(t, k.v0.y > 1250)
}

@(test)
test_scroll_a_wheel_forgets_the_speed :: proc(t: ^testing.T) {
	k: Scroll_Kinetic
	swipe(&k, 4, 11, 0, 0)
	scroll_release(&k, 88, 0)
	scroll_cancel(&k)
	swipe(&k, 4, 11, 300, 0.3)
	scroll_release(&k, 388, 0.4)
	testing.expect_value(t, k.v0.y, 1250)
}

@(test)
test_scroll_history_survives_the_clock_wrapping :: proc(t: ^testing.T) {
	k: Scroll_Kinetic
	first := max(u32) - 40
	swipe(&k, 4, 11, first, 0)
	testing.expect(t, scroll_release(&k, first + 88, 0))
	testing.expect_value(t, k.v0.y, 1250)
}
