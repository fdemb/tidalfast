package ui

import "../platform"

foreign import CoreGraphics "system:CoreGraphics.framework"

@(default_calling_convention = "c")
foreign CoreGraphics {
	CGEventSourceButtonState :: proc(state_id: i32, button: u32) -> bool ---
}

// kCGEventSourceStateCombinedSessionState: every event source in the login
// session, so it sees releases that went to other apps.
CG_EVENT_SOURCE_STATE_COMBINED :: 0

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
	press_pos:    [platform.Mouse_Button][2]f32, // where each button last went down
	release_pos:  [platform.Mouse_Button][2]f32, // where each button last came up
	scroll:       [2]f32, // points
}

// Wheel scrolls without precise deltas count in lines.
SCROLL_LINE :: 16

// macOS virtual key codes (kVK_*) the UI and the app use.
KEY_A :: 0
KEY_D :: 2
KEY_F :: 3
KEY_Z :: 6
KEY_X :: 7
KEY_C :: 8
KEY_V :: 9
KEY_E :: 14
KEY_L :: 37
KEY_BACKSPACE :: 51
KEY_KEYPAD_ENTER :: 76
KEY_FORWARD_DELETE :: 117
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

// hardware_buttons asks CoreGraphics which mouse buttons are down right now,
// whichever app got the events. Pass it to begin_frame.
hardware_buttons :: proc() -> (held: Mouse_Buttons) {
	for b in platform.Mouse_Button {
		// Mouse_Button's values are CGMouseButton's: left, right, center.
		if CGEventSourceButtonState(CG_EVENT_SOURCE_STATE_COMBINED, u32(b)) {
			held += {b}
		}
	}
	return
}

mouse_down :: proc(input: Input) -> bool {
	return input.buttons != {}
}
