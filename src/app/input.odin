package app

import "../platform"

Mouse_Buttons :: bit_set[platform.Mouse_Button; u32]

// Input is the mouse and keyboard state the shell's events add up to. The
// per-frame fields cover the events of the current frame only.
Input :: struct {
	mouse:        [2]f32, // points, last known position
	mouse_inside: bool,
	buttons:      Mouse_Buttons, // held down now
	modifiers:    platform.Modifiers,

	// This frame. A click within one frame shows up in both pressed and
	// released while buttons doesn't change.
	pressed:      Mouse_Buttons,
	released:     Mouse_Buttons,
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
	case .Mouse_Up:
		input.mouse = {e.x, e.y}
		input.buttons -= {e.button}
		input.released += {e.button}
	case .Scroll:
		delta := [2]f32{e.dx, e.dy}
		if !e.precise {
			delta *= SCROLL_LINE
		}
		input.scroll += delta
	}
	if e.kind != .Resize {
		input.modifiers = e.modifiers
	}
}

mouse_down :: proc(input: Input) -> bool {
	return input.buttons != {}
}
