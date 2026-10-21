// The error toast: the current error, if any, in a box over the bottom of
// the window for TOAST_SECONDS after it appears. Everything else the
// status says shows only in the status bar (TIDALFAST_STATUS_BAR).
package app

import "core:fmt"
import "core:hash"
import "core:math"

import "../render"
import "../tidal"
import "../ui"

TOAST_SECONDS :: 6
TOAST_MAX_W :: 520
TOAST_GAP :: 16 // between the toast and the player bar
TOAST_BG :: render.Color{0x3a / 255.0, 0x1d / 255.0, 0x1a / 255.0, 1}
TOAST_BORDER :: render.Color{0x5c / 255.0, 0x2c / 255.0, 0x26 / 255.0, 1}

Error_Source :: enum u8 {
	None,
	Rate_Limit,
	List,
	Search,
	Add,
	Data, // Data.message: the sidebar, following, settings, the Keychain
}

// Toast is the error it shows and since when. An error is new when its
// source or text changes, except a rate limit, whose text counts down.
Toast :: struct {
	source:    Error_Source,
	text_hash: u32,
	since:     f64,
	dismissed: bool,
	text:      Small, // kept while it fades out after the error has gone
}

// current_error is the error the app would tell the user about now, the
// most pressing first.
current_error :: proc(s: ^State) -> (source: Error_Source, text: string) {
	d := &s.data
	if !d.fake && d.session != nil {
		if wait := tidal.backoff_remaining(d.session); wait > 0 {
			return .Rate_Limit, fmt.tprintf("TIDAL asked us to slow down. Trying again in %d s.", int(wait + 0.5))
		}
		if d.view.error.len > 0 {
			return .List, small_str(&d.view.error)
		}
		if s.search.error.len > 0 && search_query(s) != "" {
			return .Search, fmt.tprintf("Search failed: %s", small_str(&s.search.error))
		}
		if d.message.len > 0 {
			return .Data, small_str(&d.message)
		}
	}
	lib := &s.library
	if lib.status == .Add_Failed {
		if t := view_row(s, lib.status_track); t != nil {
			return .Add, fmt.tprintf("Couldn't add %s to %s", t.title, sidebar_entry(s, lib.status_list).name)
		}
	}
	return .None, ""
}

// draw_toast shows the current error over the views, above the player bar
// at bottom, for TOAST_SECONDS, longer while the mouse is on it. A click
// dismisses it.
draw_toast :: proc(s: ^State, w, bottom: f32) {
	source, text := current_error(s)
	toast := &s.toast
	text_hash := hash.fnv32a(transmute([]u8)text) if source != .Rate_Limit else 0
	now := s.ui.time
	if source != toast.source || text_hash != toast.text_hash {
		toast^ = {source = source, text_hash = text_hash, since = now}
	}
	if source != .None {
		toast.text = small(text)
	}
	box := ui.box_lookup(&s.ui, ui.key_from_string(0, "###toast"))
	hovered := box != nil && box.hot_t > 0
	shown := source != .None && !toast.dismissed && (hovered || now < toast.since + TOAST_SECONDS)
	if shown && !hovered {
		ui.wake_at(toast.since + TOAST_SECONDS)
	}
	if source == .Rate_Limit && shown {
		ui.wake_at(math.floor(now) + 1) // the countdown
	}
	if !shown && (box == nil || box.open_t == 0) {
		return
	}

	ui.floating()
	label := small_str(&toast.text)
	ui.text_style(.Medium, 13, TEXT)
	width := min(ui.text_width(.Medium, 13, label) + 32, TOAST_MAX_W, w - 32)
	b := ui.box_make("###toast", {.Floating_X, .Floating_Y, .Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Draw_Text}, ui.px(width), ui.px(44))
	b.label = label
	b.text_pad = 16
	b.background = TOAST_BG
	b.border_color = TOAST_BORDER
	b.radius = 8
	b.open_t = ui.approach(&s.ui, b.open_t, 1 if shown else 0, 1 - math.exp(-s.ui.dt * 20), 0.01)
	b.opacity = b.open_t
	b.fixed_pos = {math.floor((w - width) / 2), bottom - TOAST_GAP - 44 + (1 - b.open_t) * 8}
	ui.accessible(b, .Static_Text, b.label)
	if ui.signal(b).clicked {
		toast.dismissed = true
	}
}
