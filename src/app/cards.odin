package app

// Shelves of cards, as on TIDAL's artist pages: a titled row of square
// covers, round for artists, with a title and a subtitle under each, that
// scrolls sideways with a trackpad, Shift and the wheel, Left and Right
// once a card has the focus, or the ‹ › buttons by the title. View all
// shows the whole shelf as a grid (card_grid).

import "core:fmt"
import "core:hash"
import "core:math"

import "../cover"
import "../text"
import "../ui"

CARD_SIZE :: 160 // the cover
CARD_PAD :: 8 // around the cover and text, where the hover shows
CARD_W :: CARD_SIZE + 2 * CARD_PAD
CARD_H :: CARD_SIZE + CARD_TEXT_H + 2 * CARD_PAD
CARD_TEXT_H :: 50 // under the cover: a gap, the title and the subtitle
CARD_GAP :: 8
CARD_PITCH :: CARD_W + CARD_GAP
GRID_ROW_GAP :: 8
// A shelf builds at most this many cards, every one focusable, so Left and
// Right never land on one that isn't there. View all shows the rest.
SHELF_CARDS :: 50

Shelf_Signal :: struct {
	clicked:  int, // the card clicked, -1 for none
	view_all: bool,
}

// section_title is a heading over the top tracks or a shelf. It returns the
// row, so the caller can add buttons at its right with ui.parent.
section_title :: proc(title: string) -> ^ui.Box {
	ui.spacer(ui.px(32))
	r := ui.row("", {}, ui.fill(), ui.px(36))
	ui.spacer(ui.px(CARD_PAD))
	ui.text_style(.Bold, 20, TEXT)
	t := ui.label(title, ui.text_size(), ui.fill())
	ui.accessible(t, .Static_Text, title)
	ui.spacer(ui.fill())
	return r
}

// text_button is a button that's only its text, such as View all; name is
// what assistive apps read.
text_button :: proc(id, name: string) -> ui.Signal {
	ui.column("", {}, ui.children_sum(), ui.fill())
	ui.spacer(ui.fill())
	ui.text_style(.Semibold, 13, SECONDARY)
	ui.set_next_text_pad(8)
	ui.set_next_text_align(.Center)
	ui.set_next_radius(6)
	b := ui.box_make(id, {.Clickable, .Focusable, .Draw_Text}, ui.text_size(16), ui.px(28))
	b.text_color = mix(SECONDARY, TEXT, ui.hover_t(b))
	ui.accessible(b, .Button, name)
	ui.spacer(ui.fill())
	return ui.signal(b)
}

// page_button is a round ‹ or › button that pages a shelf.
@(private = "file")
page_button :: proc(id, icon, name: string, enabled: bool) -> ui.Signal {
	ui.radius(14)
	ui.background(SURFACE)
	ui.hover_color(SURFACE_ACTIVE)
	_, sig := icon_button(id, icon, .Icon, name, TEXT if enabled else DIM, 1, 28, {.Focusable, .Draw_Background} if enabled else {.Draw_Background, .Disabled}, size = 14)
	return sig
}

// card_row is a shelf of items width wide: its title, then up to
// SHELF_CARDS cards in a row that scrolls sideways. A card out of view is
// built empty, for the focus to move to. id names the shelf among its
// siblings; source says what the items are, .Album, .Artist or .Playlist.
// Without view_all the shelf has no View all.
card_row :: proc(s: ^State, id, title: string, items: []Found, source: Source, width: f32, view_all := true) -> (sig: Shelf_Signal) {
	sig.clicked = -1
	n := min(len(items), SHELF_CARDS)
	content := f32(n) * CARD_PITCH - CARD_GAP
	key := fmt.tprintf("%s##shelf", id)
	// Where the row is scrolling to, for the buttons.
	off, view_w: f32 = 0, max(width, 1)
	if prev := ui.find(key); prev != nil {
		off = prev.view_off_target.x
	}
	page := max(math.floor((view_w + CARD_GAP) / CARD_PITCH), 1) * CARD_PITCH
	move: f32
	{
		ui.parent(section_title(title))
		if content > view_w + 0.5 {
			if page_button(fmt.tprintf("%s_prev", id), text.ICON_CARET_LEFT, fmt.tprintf("Previous page of %s", title), off > 0.5).clicked {
				move = -page
			}
			ui.spacer(ui.px(6))
			if page_button(fmt.tprintf("%s_next", id), text.ICON_CARET_RIGHT, fmt.tprintf("Next page of %s", title), off + view_w < content - 0.5).clicked {
				move = page
			}
			ui.spacer(ui.px(6))
		}
		if view_all && text_button(fmt.tprintf("View all###%s_all", id), fmt.tprintf("View all %s", title)).clicked {
			sig.view_all = true
		}
	}
	ui.spacer(ui.px(8))
	view := ui.box_make(key, {.View_Scroll, .Clip, .Allow_Overflow_X}, ui.px(width), ui.px(CARD_H))
	view.child_axis = .X
	ui.accessible(view, .List, title)
	if move != 0 {
		view.view_off_target.x = clamp(math.round((off + move) / CARD_PITCH) * CARD_PITCH, 0, max(content - view_w, 0))
		ui.request_frame()
	}
	ui.parent(view)
	first := int(view.view_off.x / CARD_PITCH) - 1
	last := int(math.ceil((view.view_off.x + view_w) / CARD_PITCH)) + 1
	kind := card_cover(source)
	for i in 0 ..< n {
		if card(s, i, items[i], kind, i >= first && i < last).clicked {
			sig.clicked = i
		}
		if i < n - 1 {
			ui.spacer(ui.px(CARD_GAP))
		}
	}
	return
}

// card_cover is the kind of cover a card of source shows.
@(private = "file")
card_cover :: proc(source: Source) -> cover.Kind {
	#partial switch source {
	case .Artist:
		return .Artist
	case .Playlist:
		return .Playlist
	}
	return .Album
}

// card is one cover with its title and subtitle under it. Without filled
// it's an empty box of the same size with the same name.
@(private = "file")
card :: proc(s: ^State, i: int, f: Found, kind: cover.Kind, filled: bool) -> ui.Signal {
	ui.set_next_radius(8)
	row_highlight(LIST_ROWS, false)
	b := ui.column(fmt.tprintf("##card%d", i), {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Instant_Hover}, ui.px(CARD_W), ui.px(CARD_H))
	ui.accessible(b, .Button, f.name if f.subtitle == "" else fmt.tprintf("%s, %s", f.name, f.subtitle))
	if !filled {
		return ui.signal(b)
	}
	round := kind == .Artist
	ui.spacer(ui.px(CARD_PAD))
	{
		ui.row("", {}, ui.fill(), ui.px(CARD_SIZE))
		ui.spacer(ui.px(CARD_PAD))
		cover_art(s, kind, f.image, hash.fnv32a(transmute([]u8)f.name), CARD_SIZE, ui.px(CARD_SIZE), CARD_SIZE / 2 if round else 6)
	}
	ui.spacer(ui.px(10))
	ui.text_pad(CARD_PAD)
	ui.text_align(.Center if round else .Left)
	ui.text_style(.Medium, 14, TEXT)
	ui.label(f.name, ui.fill(), ui.px(20))
	ui.text_style(.Regular, 12, SECONDARY)
	ui.label(f.subtitle, ui.fill(), ui.px(18))
	return ui.signal(b)
}

// card_grid lays items out in rows in a view width wide and height tall
// that scrolls down. Only the rows in view are built. It returns the card
// clicked, or -1.
card_grid :: proc(s: ^State, id, title: string, items: []Found, source: Source, width, height: f32) -> (clicked: int) {
	clicked = -1
	cols := max(int((width + CARD_GAP) / CARD_PITCH), 1)
	n := len(items)
	row_h := f32(CARD_H + GRID_ROW_GAP)
	kind := card_cover(source)
	view := ui.scroll_view(id, ui.px(width), ui.px(height), inset_end = bar_inset(s))
	history_scroll(s, view)
	ui.accessible(view, .List, title)
	rows := ui.virtual_rows(view, (n + cols - 1) / cols, row_h)
	for r in rows.first ..< rows.last {
		// Unkeyed, so a card's key and the arrow keys' group are the
		// view's, whatever row a resize puts it in.
		ui.row("", {}, ui.fill(), ui.px(row_h))
		for i in r * cols ..< min((r + 1) * cols, n) {
			if card(s, i, items[i], kind, true).clicked {
				clicked = i
			}
			ui.spacer(ui.px(CARD_GAP))
		}
	}
	return
}
