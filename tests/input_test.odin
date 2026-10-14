package tidal_tests

import "core:testing"

import app "../src/app"
import "../src/platform"

@(test)
test_mouse_buttons_tracked_separately :: proc(t: ^testing.T) {
	input: app.Input
	press :: proc(input: ^app.Input, kind: platform.Event_Kind, button: platform.Mouse_Button) {
		app.input_apply(input, {kind = kind, button = button})
	}

	app.input_begin_frame(&input)
	press(&input, .Mouse_Down, .Left)
	press(&input, .Mouse_Down, .Right)
	press(&input, .Mouse_Up, .Right)
	testing.expect_value(t, input.buttons, app.Mouse_Buttons{.Left})
	testing.expect_value(t, input.pressed, app.Mouse_Buttons{.Left, .Right})
	testing.expect_value(t, input.released, app.Mouse_Buttons{.Right})
	testing.expect(t, app.mouse_down(input))

	app.input_begin_frame(&input)
	testing.expect_value(t, input.pressed, app.Mouse_Buttons{})
	press(&input, .Mouse_Up, .Left)
	testing.expect_value(t, input.buttons, app.Mouse_Buttons{})
	testing.expect_value(t, input.released, app.Mouse_Buttons{.Left})
	testing.expect(t, !app.mouse_down(input))
}
