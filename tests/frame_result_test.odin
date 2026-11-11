package tidal_tests

import "core:testing"

import app "../src/app"
import "../src/render"

// A frame the renderer couldn't show went nowhere, and nothing paced it: a
// present that returns at once for a covered window, or no device at all.
// Animating then would draw as fast as the CPU goes. The app stops, and
// asks for a frame after the renderer's poll or render.HIDDEN_POLL.
@(test)
hidden_frames_stop_animating :: proc(t: ^testing.T) {
	r := new(render.Renderer, context.temp_allocator)

	shown := app.frame_result(r, true, 0.5)
	testing.expect(t, bool(shown.animating))
	testing.expect_value(t, shown.wake_after, 0.5)

	// Covered, after a frame that went up: nothing to look again for
	// unless the app wanted another frame.
	r.hidden = true
	idle := app.frame_result(r, false, 0)
	testing.expect(t, !idle.animating)
	testing.expect_value(t, idle.wake_after, 0)
	moving := app.frame_result(r, true, 0)
	testing.expect(t, !moving.animating)
	testing.expect_value(t, moving.wake_after, f32(render.HIDDEN_POLL))
	caret := app.frame_result(r, true, 0.1)
	testing.expect_value(t, caret.wake_after, 0.1)

	// A frame that wasn't drawn at all: the renderer's poll, even when the
	// app wants nothing new, but not later than the app asked.
	r.poll_after = 1
	missed := app.frame_result(r, false, 0)
	testing.expect(t, !missed.animating)
	testing.expect_value(t, missed.wake_after, 1)
	testing.expect_value(t, app.frame_result(r, false, 0.3).wake_after, 0.3)
	testing.expect_value(t, app.frame_result(r, true, 0).wake_after, f32(render.HIDDEN_POLL))
}
