// The settings page, which Settings in the user menu shows: a column of
// titled cards, each a list of rows with a setting's name and what it does
// on the left and its control on the right. A setting with a few choices
// has them side by side in one control, and one that's on or off has a
// switch.
package app

import "core:fmt"

import "../audio"
import "../render"
import "../ui"

SETTINGS_MAX :: 720 // the column, centred in wider windows
SETTINGS_ROW_H :: 60
SETTINGS_ROW_PAD :: 16
SETTINGS_CONTROL_H :: 30
SWITCH_W :: 36
SWITCH_H :: 20
SWITCH_KNOB :: 14
SWITCH_KNOB_OFF :: render.Color{0xc8 / 255.0, 0xc8 / 255.0, 0xc8 / 255.0, 1}

// Settings_Place is the settings page as a place in the History.
Settings_Place :: struct {}

// settings_showing says whether the main view shows the settings page. The
// open list stays as it was underneath.
settings_showing :: proc(s: ^State) -> bool {
	h := &s.history
	if h.count == 0 {
		return false
	}
	_, ok := h.places[h.at].(Settings_Place)
	return ok
}

// draw_settings draws the page main_w wide and view_h tall.
draw_settings :: proc(s: ^State, main_w, view_h: f32) {
	d := &s.data
	content_w := min(main_w, SETTINGS_MAX + 2 * PAGE_PAD) - 2 * PAGE_PAD
	view := ui.scroll_view("settings", ui.px(main_w), ui.px(view_h), inset_end = bar_inset(s), bar_top = window_bar_top(s))
	history_scroll(s, view)
	ui.accessible(view, .Group, "Settings")
	nav_float(s, view.view_off.y)
	centred(content_w)
	ui.spacer(ui.px(max(nav_reserve(s) + 8, 24)))
	{
		ui.text_style(.Bold, 32, TEXT)
		ui.accessible(ui.label("Settings", ui.fill(), ui.px(44)), .Static_Text, "Settings")
	}

	{
		settings_card("Appearance")
		{
			settings_row("Scrollbars", "Show while scrolling, always or never")
			settings_choices("scrollbars")
			for mode in ui.Scrollbars {
				name := fmt.tprint(mode)
				if settings_choice(name, fmt.tprintf("%s scrollbars", name), s.settings.scrollbars == mode) {
					s.settings.scrollbars = mode
					settings_queue(d, settings_to_save(s))
				}
			}
		}
		if render.BACKDROPS {
			settings_separator()
			settings_row("Player bar", "Blur the lists under it or sit below them")
			settings_choices("bar")
			for mode in Player_Bar {
				name := fmt.tprint(mode)
				if settings_choice(name, fmt.tprintf("%s player bar", name), s.settings.bar == mode) {
					s.settings.bar = mode
					settings_queue(d, settings_to_save(s))
				}
			}
		}
		if s.window.decorations {
			settings_separator()
			settings_row("Title bar", "The desktop's or TIDALfast's own")
			settings_choices("title_bar")
			for mode in Title_Bar {
				name := title_bar_name(mode)
				if settings_choice(name, fmt.tprintf("%s title bar", name), s.settings.title_bar == mode) {
					s.settings.title_bar = mode
					settings_queue(d, settings_to_save(s))
				}
			}
		}
	}

	when audio.BIT_PERFECT {
		{
			settings_card("Playback")
			settings_row("Bit-perfect output", "Each track at its own sample rate and bit depth, past the volume")
			if settings_switch("Bit-perfect output", s.settings.bit_perfect) {
				st := s.settings
				st.bit_perfect = !st.bit_perfect
				settings_set(s, st)
			}
		}
	}

	if d.account == .Signed_In && !d.fake {
		settings_card("Account")
		name := small_str(&d.profile.name)
		settings_row(name if name != "" else "TIDAL", "Signed in to TIDAL")
		if settings_button("Log out###settings_log_out", "Log out") {
			pending_set(s, Log_Out{})
		}
	}
	ui.spacer(ui.px(48))
}

// settings_card is a section's title and under it the card its rows go in,
// the parent until the end of the scope.
@(private = "file", deferred_none = ui.pop_parent)
settings_card :: proc(title: string) {
	ui.spacer(ui.px(24))
	{
		ui.row("", {}, ui.fill(), ui.px(28))
		ui.spacer(ui.px(4))
		ui.text_style(.Semibold, 12, QUIET)
		ui.accessible(ui.label(title, ui.fill(), ui.fill()), .Static_Text, title)
	}
	ui.set_next_background(PANEL)
	ui.set_next_border_color(OUTLINE)
	ui.set_next_radius(10)
	card := ui.box_make("", {.Draw_Background, .Draw_Border}, ui.fill(), ui.children_sum())
	card.child_axis = .Y
	ui.push_parent(card)
}

// settings_row is a row of a card with a setting's name and a line about
// it. The row is the parent until the end of the scope, for the control at
// its end.
@(private = "file", deferred_none = settings_row_end)
settings_row :: proc(name, about: string) {
	r := ui.box_make("", {}, ui.fill(), ui.px(SETTINGS_ROW_H))
	r.child_axis = .X
	ui.push_parent(r)
	ui.spacer(ui.px(SETTINGS_ROW_PAD))
	{
		// The two lines, 33 pt, centred in the row.
		ui.column("", {}, ui.fill(), ui.fill()).pad.y = (SETTINGS_ROW_H - 33) / 2
		ui.text_style(.Medium, 13, TEXT)
		ui.accessible(ui.label(name, ui.fill(), ui.px(16)), .Static_Text, name)
		ui.spacer(ui.px(2))
		ui.text_style(.Regular, 12, QUIET)
		ui.accessible(ui.label(about, ui.fill(), ui.px(15)), .Static_Text, about)
	}
	ui.spacer(ui.px(SETTINGS_ROW_PAD))
}

@(private = "file")
settings_row_end :: proc() {
	ui.spacer(ui.px(SETTINGS_ROW_PAD))
	ui.pop_parent()
}

// settings_separator is the line between two rows of a card.
@(private = "file")
settings_separator :: proc() {
	ui.row("", {}, ui.fill(), ui.px(1))
	ui.spacer(ui.px(SETTINGS_ROW_PAD))
	ui.set_next_background(OUTLINE)
	ui.box_make("", {.Draw_Background}, ui.fill(), ui.fill())
	ui.spacer(ui.px(SETTINGS_ROW_PAD))
}

// settings_choices is a control whose choices sit side by side, the one
// chosen raised. It is the parent until the end of the scope, for
// settings_choice. The choices share its key, so Left and Right move
// through them.
@(private = "file", deferred_none = settings_choices_end)
settings_choices :: proc(id: string) {
	c := ui.box_make("", {}, ui.children_sum(), ui.fill())
	c.child_axis = .Y
	ui.push_parent(c)
	ui.spacer(ui.fill())
	ui.set_next_background(SURFACE)
	ui.set_next_radius(8)
	group := ui.box_make(id, {.Draw_Background}, ui.children_sum(), ui.px(SETTINGS_CONTROL_H))
	group.child_axis = .X
	group.pad = {2, 2}
	ui.push_parent(group)
}

@(private = "file")
settings_choices_end :: proc() {
	ui.pop_parent()
	ui.spacer(ui.fill())
	ui.pop_parent()
}

// settings_choice is one choice of a settings_choices. label is what
// assistive apps read, which says what the choice is of. It returns
// whether it was clicked while another was chosen.
@(private = "file")
settings_choice :: proc(name, label: string, chosen: bool) -> bool {
	ui.text_style(.Medium, 12, TEXT if chosen else SECONDARY)
	ui.set_next_text_align(.Center)
	ui.set_next_radius(6)
	flags := ui.Box_Flags{.Clickable, .Focusable, .Draw_Text}
	if chosen {
		ui.set_next_background(SURFACE_ACTIVE)
		ui.set_next_shadow(SIDEBAR_SELECTED_SHADOW)
		flags += {.Draw_Background, .Draw_Shadow}
	}
	b := ui.box_make(fmt.tprintf("%s###%s", name, label), flags, ui.text_size(28), ui.fill())
	if !chosen {
		b.text_color = mix(SECONDARY, TEXT, b.hot_t)
	}
	ui.accessible(b, .Button, label, selected = chosen)
	return ui.signal(b).clicked && !chosen
}

// settings_switch is a switch, lit in the accent with its knob at the
// right while on. It returns whether it was clicked.
@(private = "file")
settings_switch :: proc(label: string, on: bool) -> bool {
	ui.column("", {}, ui.px(SWITCH_W), ui.fill())
	ui.spacer(ui.fill())
	clicked: bool
	{
		ui.set_next_radius(SWITCH_H / 2)
		b := ui.row(fmt.tprintf("###switch_%s", label), {.Clickable, .Focusable, .Draw_Background}, ui.px(SWITCH_W), ui.px(SWITCH_H))
		t := ui.slide(b, on)
		b.background = mix(mix(SURFACE_ACTIVE, DIM, b.hot_t * 0.3), ACCENT, t)
		ui.accessible(b, .Button, label, value = "On" if on else "Off", selected = on)
		clicked = ui.signal(b).clicked
		inset: f32 = (SWITCH_H - SWITCH_KNOB) / 2
		ui.spacer(ui.px(inset + t * (SWITCH_W - SWITCH_KNOB - 2 * inset)))
		ui.column("", {.Center_Children}, ui.px(SWITCH_KNOB), ui.fill())
		ui.set_next_background(mix(SWITCH_KNOB_OFF, WINDOW_BG, t))
		ui.set_next_radius(SWITCH_KNOB / 2)
		ui.box_make("", {.Draw_Background}, ui.px(SWITCH_KNOB), ui.px(SWITCH_KNOB))
	}
	ui.spacer(ui.fill())
	return clicked
}

// settings_button is a button at the end of a row; name is what assistive
// apps read. It returns whether it was clicked.
@(private = "file")
settings_button :: proc(id, name: string) -> bool {
	ui.column("", {}, ui.children_sum(), ui.fill())
	ui.spacer(ui.fill())
	ui.text_style(.Medium, 12, TEXT)
	ui.set_next_text_align(.Center)
	ui.set_next_radius(8)
	ui.set_next_background(SURFACE)
	ui.set_next_hover_color(SURFACE_ACTIVE)
	b := ui.box_make(id, {.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects}, ui.text_size(28), ui.px(SETTINGS_CONTROL_H))
	ui.accessible(b, .Button, name)
	ui.spacer(ui.fill())
	return ui.signal(b).clicked
}
