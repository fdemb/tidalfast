package ui

import "../platform"

// Input is the mouse and keyboard state the shell's events add up to. The
// per-frame fields cover the events of the current frame only.
Input :: struct {
	mouse:        [2]f32, // points, last known position
	mouse_inside: bool,
	buttons:      platform.Mouse_Buttons, // held down now
	modifiers:    platform.Modifiers,

	// This frame. A click within one frame shows up in both pressed and
	// released while buttons doesn't change.
	pressed:      platform.Mouse_Buttons,
	released:     platform.Mouse_Buttons,
	press_pos:    [platform.Mouse_Button][2]f32, // where each button last went down
	release_pos:  [platform.Mouse_Button][2]f32, // where each button last came up
	scroll:       [2]f32, // points
}

// Wheel scrolls without precise deltas count in lines.
SCROLL_LINE :: 16

input_begin_frame :: proc(input: ^Input) {
	input.pressed = {}
	input.released = {}
	input.scroll = {}
}

input_apply :: proc(input: ^Input, e: platform.Event) {
	#partial switch e.kind {
	case .Mouse_Move:
		input.mouse = {e.x, e.y}
		input.mouse_inside = true
	case .Mouse_Leave:
		input.mouse_inside = false
	case .Mouse_Down:
		input.mouse = {e.x, e.y}
		input.buttons += {e.button}
		input.pressed += {e.button}
		input.press_pos[e.button] = input.mouse
	case .Mouse_Up:
		input.mouse = {e.x, e.y}
		input.buttons -= {e.button}
		input.released += {e.button}
		input.release_pos[e.button] = input.mouse
	case .Scroll:
		input.scroll += scroll_delta(e)
	}
	if e.kind != .Resize {
		input.modifiers = e.modifiers
	}
}

// scroll_delta is a scroll event's delta in points.
scroll_delta :: proc(e: platform.Event) -> [2]f32 {
	delta := [2]f32{e.dx, e.dy}
	if !e.precise {
		delta *= SCROLL_LINE
	}
	return delta
}

mouse_down :: proc(input: Input) -> bool {
	return input.buttons != {}
}
