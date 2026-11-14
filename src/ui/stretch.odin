package ui

import "core:math"

import "../platform"

// A trackpad scroll past the end of a view moves the content a twentieth
// as far, and the content goes back when the fingers lift along an
// exponential curve. The view's offset stays inside the content, and drawn_off adds
// the stretch to it. Mouse wheels never stretch a view.

STRETCH_STIFFNESS :: 20 // points of overscroll per point of stretch
STRETCH_AMPLITUDE :: 0.31 // how far the speed at release carries the stretch on
STRETCH_PERIOD :: 1.6
STRETCH_MIN_PIXELS :: 10 // overscroll before the first stretch, so a stray move doesn't start one
STRETCH_VELOCITY_TIMEOUT :: 0.1 // seconds between two events past which the speed counts as 0

Stretch_State :: enum u8 {
	Inactive,
	Tracking, // fingers on the trackpad, or the momentum after them
	Bounce, // going back by itself
}

Stretch :: struct {
	amount:  [2]f32, // points past the start (negative) or the end
	pending: [2]f32, // overscroll short of STRETCH_MIN_PIXELS so far
	from:    [2]f32, // amount when the bounce began
	vel:     [2]f32, // points per second toward the end when the bounce began
	start:   f64,
	state:   Stretch_State,
}

// Gesture is the trackpad gesture as this frame's events left it.
Gesture :: struct {
	began:         bool, // fingers started scrolling this frame
	lifted:        bool, // fingers lifted, or a wheel turned
	momentum:      bool, // momentum moved this frame
	momentum_new:  bool, // momentum began this frame
	momentum_done: bool, // momentum ended this frame
	in_momentum:   bool, // the latest precise event was momentum
	vel:           [2]f32, // points per second toward the end, from the latest event
	vel_time:      f64, // that event's time, 0 for none
}

// gesture_event folds a scroll event into the frame's gesture. Velocity is
// the latest event's delta over the time since the one before, and skips
// the first momentum event, which macOS sends fast with a large delta.
@(private)
gesture_event :: proc(g: ^Gesture, e: platform.Event, d: [2]f32) {
	if !e.precise {
		if e.phase == .None && e.momentum_phase == .None {
			g.lifted = true
		}
		return
	}
	if e.phase == .Began {
		g.began = true
		g.vel = {}
		g.vel_time = 0
		g.in_momentum = false
	}
	if e.phase == .Ended || e.phase == .Cancelled {
		g.lifted = true
	}
	moving := e.momentum_phase == .Began || e.momentum_phase == .Changed
	if moving {
		g.momentum = true
	}
	if e.momentum_phase == .Began {
		g.momentum_new = true
	}
	if e.momentum_phase == .Ended || e.momentum_phase == .Cancelled {
		g.momentum_done = true
	}
	if (e.phase == .Changed || e.momentum_phase == .Changed) && (!moving || g.in_momentum) {
		dt := e.time - g.vel_time
		g.vel = -d / f32(dt) if g.vel_time > 0 && dt > 0 && dt < STRETCH_VELOCITY_TIMEOUT else {}
		g.vel_time = e.time
	}
	g.in_momentum = moving
}

// stretch_view runs a scroll view's rubber band for the frame. unused is the
// trackpad scroll toward the end that the view couldn't take, and limit how
// far the view scrolls.
@(private)
stretch_view :: proc(u: ^State, b: ^Box, unused, limit: [2]f32) {
	st := &b.stretch
	g := u.gesture
	ours := u.scroll_key[0] == b.key || u.scroll_key[1] == b.key
	scale := ui_scale(u)
	px := 1 / scale if scale > 0 else 1
	tracking := st.state == .Tracking

	// Fingers back on the trackpad catch a bounce where it is.
	if ours && g.began {
		st.state = .Tracking
		st.pending = {}
		tracking = true
	}

	if tracking {
		for axis in 0 ..< 2 {
			if unused[axis] == 0 {
				continue
			}
			over := unused[axis] + st.pending[axis]
			st.pending[axis] = 0
			if st.amount[axis] != 0 || abs(over) >= STRETCH_MIN_PIXELS * px {
				st.amount[axis] += over / STRETCH_STIFFNESS
			} else {
				st.pending[axis] = over
			}
		}
		// Scrolling back takes in the stretch before the view moves.
		for axis in 0 ..< 2 {
			a := st.amount[axis]
			off := b.view_off[axis]
			take: f32
			if a < 0 && off > 0 {
				take = -min(-a, off)
			} else if a > 0 && off < limit[axis] {
				take = min(a, limit[axis] - off)
			}
			b.view_off[axis] += take
			b.view_off_target[axis] += take
			st.amount[axis] -= take
		}
		left := u.scroll_latch[0] != b.key && u.scroll_latch[1] != b.key
		if ours && (g.lifted || g.momentum_done) || left {
			if st.amount == {} {
				st^ = {}
			} else {
				stretch_bounce(u, st)
			}
		} else if g.momentum && st.amount != {} {
			stretch_bounce(u, st)
		}
	}
	// Only momentum that begins after the view settles can stretch it. The
	// rest of a momentum that ran on through a bounce can't.
	if ours && g.momentum_new && st.state == .Inactive {
		st.state = .Tracking
	}

	if st.state == .Bounce {
		t := f32(u.time - st.start)
		a := (st.from + st.vel * t * STRETCH_AMPLITUDE) * math.exp(-t * STRETCH_STIFFNESS / STRETCH_PERIOD)
		// It settles from the next frame on, once the speed it began with
		// has had a frame to carry it out.
		if t > 0 && abs(a.x) < px && abs(a.y) < px {
			st^ = {}
		} else {
			st.amount = a
			u.animating = true
		}
	}
}

@(private)
stretch_bounce :: proc(u: ^State, st: ^Stretch) {
	st.state = .Bounce
	st.start = u.time
	st.from = st.amount
	st.vel = u.gesture.vel
	// The speed carries on only the axis that's stretched.
	for axis in 0 ..< 2 {
		if st.from[axis] == 0 {
			st.vel[axis] = 0
		}
	}
	u.animating = true
}
