package tidal_tests

import "core:testing"

import "../src/ui"
import "../src/platform"

@(test)
test_mouse_buttons_tracked_separately :: proc(t: ^testing.T) {
	input: ui.Input
	press :: proc(input: ^ui.Input, kind: platform.Event_Kind, button: platform.Mouse_Button) {
		ui.input_apply(input, {kind = kind, button = button})
	}

	ui.input_begin_frame(&input)
	press(&input, .Mouse_Down, .Left)
	press(&input, .Mouse_Down, .Right)
	press(&input, .Mouse_Up, .Right)
	testing.expect_value(t, input.buttons, ui.Mouse_Buttons{.Left})
	testing.expect_value(t, input.pressed, ui.Mouse_Buttons{.Left, .Right})
	testing.expect_value(t, input.released, ui.Mouse_Buttons{.Right})
	testing.expect(t, ui.mouse_down(input))

	ui.input_begin_frame(&input)
	testing.expect_value(t, input.pressed, ui.Mouse_Buttons{})
	press(&input, .Mouse_Up, .Left)
	testing.expect_value(t, input.buttons, ui.Mouse_Buttons{})
	testing.expect_value(t, input.released, ui.Mouse_Buttons{.Left})
	testing.expect(t, !ui.mouse_down(input))
}
