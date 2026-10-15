package ui

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

// macOS virtual key codes (kVK_*) the UI and the app use.
KEY_D :: 2
KEY_1 :: 18
KEY_2 :: 19
KEY_3 :: 20
KEY_RETURN :: 36
KEY_TAB :: 48
KEY_SPACE :: 49
KEY_GRAVE :: 50
KEY_ESCAPE :: 53
KEY_F1 :: 122
KEY_HOME :: 115
KEY_PAGE_UP :: 116
KEY_END :: 119
KEY_PAGE_DOWN :: 121
KEY_LEFT :: 123
KEY_RIGHT :: 124
KEY_DOWN :: 125
KEY_UP :: 126

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
