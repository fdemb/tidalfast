// The library screen, laid out like spotifast: a resizable sidebar of
// playlists, the main view with the playlist's track table, and the 88 pt
// player bar along the bottom. The data comes from data.odin: TIDAL, or
// the fake data with TIDALFAST_FAKE=1.
package app

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"

import "../audio"
import "../render"
import "../text"
import "../ui"

// Neutral greys and a cyan accent.
WINDOW_BG :: render.Color{0x10 / 255.0, 0x10 / 255.0, 0x10 / 255.0, 1}
PANEL :: render.Color{0x16 / 255.0, 0x16 / 255.0, 0x16 / 255.0, 1}
SURFACE :: render.Color{0x1f / 255.0, 0x1f / 255.0, 0x1f / 255.0, 1}
SURFACE_ACTIVE :: render.Color{0x31 / 255.0, 0x31 / 255.0, 0x31 / 255.0, 1}
// Row highlights: a selected row, or the open playlist, is a step brighter
// than a hovered one. Solid, one set per background, because the renderer
// blends in linear light, where a few percent of white over a dark grey
// comes out far brighter than the same numbers in CSS.
Row_Colors :: struct {
	selected, hover, selected_hover: render.Color,
}

SIDEBAR_ROWS :: Row_Colors {
	selected       = {0x27 / 255.0, 0x27 / 255.0, 0x27 / 255.0, 1},
	hover          = {0x20 / 255.0, 0x20 / 255.0, 0x20 / 255.0, 1},
	selected_hover = {0x2e / 255.0, 0x2e / 255.0, 0x2e / 255.0, 1},
}

LIST_ROWS :: Row_Colors {
	selected       = {0x21 / 255.0, 0x21 / 255.0, 0x21 / 255.0, 1},
	hover          = {0x1a / 255.0, 0x1a / 255.0, 0x1a / 255.0, 1},
	selected_hover = {0x28 / 255.0, 0x28 / 255.0, 0x28 / 255.0, 1},
}

// row_highlight sets b's background and hover colour from colors.
row_highlight :: proc(b: ^ui.Box, colors: Row_Colors, selected: bool) {
	b.background = colors.selected if selected else {}
	b.hover_color = colors.selected_hover if selected else colors.hover
}
OUTLINE :: render.Color{0x2c / 255.0, 0x2c / 255.0, 0x2c / 255.0, 1}
TEXT :: render.Color{0xf3 / 255.0, 0xf3 / 255.0, 0xf3 / 255.0, 1}
SECONDARY :: render.Color{0xad / 255.0, 0xad / 255.0, 0xad / 255.0, 1}
DIM :: render.Color{0x74 / 255.0, 0x74 / 255.0, 0x74 / 255.0, 1}
ACCENT :: render.Color{0, 1, 1, 1}
PLAYBACK_ERROR :: render.Color{0xf0 / 255.0, 0x8a / 255.0, 0x6c / 255.0, 1}

SIDEBAR_MIN :: 210
SIDEBAR_MAX :: 600
SIDEBAR_DEFAULT :: 250
MAIN_MIN :: 360 // the sidebar stops growing before the main view gets narrower
HANDLE_W :: 5
PLAYER_BAR_H :: 88
TRACK_ROW_H :: 56
PLAYLIST_ROW_H :: 56
HEADER_H :: 34

Library :: struct {
	sidebar_w:     f32,
	drag_from_w:   f32, // sidebar width when the handle was pressed
	playlist:      int,
	selected:      int, // track row, -1 for none
	playing:       int, // the row playing in this list, -1 for none
	menu_row:      int, // the row the context menu is for
	menu_track:    i64, // row_key of menu_row when the menu opened
	menu_list:     u64, // list_gen when the menu opened
	list_gen:      u32, // goes up when a sidebar entry or another list opens
	drop_target:   int, // the playlist under a dragged row this frame, -1 for none
	status:        Status,
	status_track:  int,
	status_list:   int,
	top_row:       int, // the first row in view, last frame
	top_offset:    f32, // how far it was scrolled past
	anchor_row:    int, // scroll this row to the top, -1 for none; see rows_moved
	anchor_offset: f32,
}

Status :: enum u8 {
	None,
	Playing,
	Added,
	Copied,
	Copied_Artist, // the open artist's link
	Adding,
	Already_In,
	Add_Failed,
}

PLAYLISTS := [?]string {
	"Liked Songs",
	"Discover Weekly",
	"Release Radar",
	"Daily Mix 1",
	"Daily Mix 2",
	"Late Night Jazz",
	"Polskie hity",
	"Deep Focus",
	"Workout Bangers",
	"Coffee & Rain",
	"夜のドライブ",
	"K-Pop Rising",
	"أغاني عربية",
	"Indie Summer 2024",
	"Classical Essentials",
	"Road Trip 🚗",
	"Lo-fi Beats",
	"90s Rock Anthems",
	"Ambient Sleep",
	"Hebrew Classics",
	"Morning Acoustic",
	"Dance Floor Fillers",
	"Old School Hip Hop",
	"Film Scores",
	"Rainy Day Piano",
	"Synthwave Nights",
	"Bossa Nova Brasil",
	"Chill Electronic",
	"Sunday Brunch",
	"Party Mix",
	"Throwback Thursday",
	"Songs to Sing in the Car",
}

// Track_Columns is the width of each column in the track table; 0 hides it.
// The title takes what's left.
Track_Columns :: struct {
	number, cover, album, added, heart, duration, more: f32,
}

// track_columns follows spotifast: the album shows above 560 pt and the date
// added above 760, in lists that have one.
track_columns :: proc(width: f32, dated: bool) -> Track_Columns {
	return {
		number = 44,
		cover = 52,
		album = clamp(width * 0.28, 140, 360) if width > 560 else 0,
		added = 120 if dated && width > 760 else 0,
		heart = 36,
		duration = 56,
		more = 36,
	}
}

sidebar_limit :: proc(window_w: f32) -> f32 {
	return clamp(window_w - HANDLE_W - MAIN_MIN, SIDEBAR_MIN, SIDEBAR_MAX)
}

library_init :: proc(lib: ^Library) {
	lib^ = {
		sidebar_w   = SIDEBAR_DEFAULT,
		selected    = -1,
		playing     = -1,
		menu_row    = -1,
		drop_target = -1,
		anchor_row  = -1,
	}
}

draw_library :: proc(s: ^State, w, h: f32) {
	lib := &s.library
	ui.text_style(.Regular, 13, TEXT)
	lib.sidebar_w = clamp(lib.sidebar_w, SIDEBAR_MIN, sidebar_limit(w))
	lib.drop_target = -1

	bg := ui.box_make("", {.Draw_Background}, ui.fill(), ui.fill())
	bg.background = WINDOW_BG
	bg.child_axis = .Y
	ui.parent(bg)
	draw_login_notice(s)
	{
		ui.row("body", {}, ui.fill(), ui.fill())
		draw_sidebar(s)
		draw_sidebar_handle(s, w)
		draw_main_view(s, w - lib.sidebar_w - HANDLE_W)
	}
	draw_player_bar(s, w)
	draw_track_menu(s)
	draw_drag_ghost(s)
}

// draw_history_buttons is Back and Forward through the places visited
// (History), at the top of the sidebar.
draw_history_buttons :: proc(s: ^State) {
	ui.row("", {}, ui.fill(), ui.px(32))
	ui.spacer(ui.px(10))
	if history_button(text.ICON_CARET_LEFT + "###back", "Back", history_can_back(s)).clicked {
		pending_set(s, {kind = .Back})
	}
	ui.spacer(ui.px(2))
	if history_button(text.ICON_CARET_RIGHT + "###forward", "Forward", history_can_forward(s)).clicked {
		pending_set(s, {kind = .Forward})
	}
}

history_button :: proc(id, name: string, enabled: bool) -> ui.Signal {
	ui.column("", {}, ui.children_sum(), ui.fill())
	ui.spacer(ui.fill())
	flags := ui.Box_Flags{.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}
	if !enabled {
		flags += {.Disabled}
	}
	ui.text_style(.Icon, 16, TEXT if enabled else DIM)
	b := ui.box_make(id, flags, ui.px(24), ui.px(24))
	b.text_align = .Center
	b.radius = 12
	ui.accessible(b, .Button, name)
	ui.spacer(ui.fill())
	return ui.signal(b)
}

draw_sidebar :: proc(s: ^State) {
	lib := &s.library
	side := ui.column("sidebar", {.Draw_Background, .Clip}, ui.px(lib.sidebar_w), ui.fill())
	side.background = PANEL
	draw_history_buttons(s)
	{
		ui.row("", {}, ui.fill(), ui.px(40))
		ui.spacer(ui.px(16))
		ui.text_style(.Semibold, 15, TEXT)
		heading := ui.label("Your Library", ui.fill(), ui.fill())
		ui.accessible(heading, .Static_Text, heading.label)
		{
			ui.column("", {}, ui.children_sum(), ui.fill())
			ui.spacer(ui.fill())
			draw_settings_button(s)
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(10))
	}
	draw_search_field(s)
	list := ui.scroll_view("playlists", ui.fill(), ui.fill())
	ui.accessible(list, .List, "Playlists")
	for i in 0 ..< sidebar_count(s) {
		entry := sidebar_entry(s, i)
		item := ui.row(fmt.tprintf("##playlist%d", i), {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Draw_Border}, ui.fill(), ui.px(PLAYLIST_ROW_H))
		item.radius = 6
		current := lib.playlist == i && !s.search.browsing
		row_highlight(item, SIDEBAR_ROWS, current)
		ui.accessible(item, .Row, fmt.tprintf("%s, %s", entry.name, entry.subtitle), selected = current)
		if ui.drop_hover(item) {
			lib.drop_target = i
			item.border_color = ACCENT
		}
		if track, ok := ui.dropped(item); ok {
			add_to_list(s, int(track), i)
		}
		sig := ui.signal(item)
		if sig.clicked {
			pending_set(s, {kind = .Playlist, index = i})
		}
		ui.spacer(ui.px(10))
		cover_art(s, .Playlist, entry.image, entry.seed, 40, ui.px(40))
		ui.spacer(ui.px(12))
		ui.column("", {}, ui.fill(), ui.fill())
		ui.spacer(ui.px(10))
		ui.text_style(.Medium, 14, TEXT)
		ui.label(entry.name, ui.fill(), ui.px(19))
		ui.text_style(.Regular, 12, SECONDARY)
		ui.label(entry.subtitle, ui.fill(), ui.px(17))
	}
}

draw_sidebar_handle :: proc(s: ^State, window_w: f32) {
	lib := &s.library
	handle := ui.row("sidebar_handle", {.Clickable}, ui.px(HANDLE_W), ui.fill())
	sig := ui.signal(handle)
	if sig.pressed {
		lib.drag_from_w = lib.sidebar_w
	}
	if sig.held || sig.released {
		lib.sidebar_w = clamp(lib.drag_from_w + sig.drag_delta.x, SIDEBAR_MIN, sidebar_limit(window_w))
	}
	ui.spacer(ui.px(2))
	line := ui.box_make("", {.Draw_Background}, ui.px(1), ui.fill())
	t := max(handle.hot_t, handle.active_t)
	line.background = mix(OUTLINE, ACCENT, t)
}

draw_main_view :: proc(s: ^State, main_w: f32) {
	lib := &s.library
	// Only playlists and Liked Songs say when a track was added. The fake
	// data's .None is its playlists.
	source := s.search.fake_source if s.data.fake else s.data.view.source
	cols := track_columns(main_w, source in bit_set[Source]{.None, .Liked, .Playlist})
	// Durations are m:ss however long, so the widest has the longest
	// track's count of minute digits.
	cols.duration = max(cols.duration, ui.counter_width(.Regular, 13, fmt.tprintf("%d:00", max(s.data.view.longest / 60, 10))) + 2 * CELL_PAD)
	ui.column("main", {.Clip}, ui.fill(), ui.fill())
	if p := artist_place(s); p != nil {
		if _, table := p.artist_view.(Artist_Top_Tracks); !table {
			draw_artist(s, p, main_w)
			return
		}
	}

	{
		ui.row("", {}, ui.fill(), ui.px(124))
		ui.spacer(ui.px(24))
		if kind, image, show := view_cover(s); show {
			cover_art(s, kind, image, u32(lib.playlist) * 7919 + 13, 92, ui.px(92), 46 if kind == .Artist else 4)
			ui.spacer(ui.px(18))
		}
		ui.column("", {}, ui.fill(), ui.fill())
		ui.spacer(ui.px(26))
		ui.text_style(.Bold, 28, TEXT)
		title := ui.label(view_title(s), ui.fill(), ui.px(38))
		ui.accessible(title, .Static_Text, title.label)
		ui.text_style(.Regular, 13, SECONDARY)
		subtitle := ui.label(view_subtitle(s), ui.fill(), ui.px(20))
		ui.accessible(subtitle, .Static_Text, subtitle.label)
		ui.text_style(.Regular, 12, DIM)
		status := ui.label(status_text(s), ui.fill(), ui.px(18))
		ui.accessible(status, .Static_Text, status.label)
	}
	if search_showing(s) && !draw_search_tabs(s) {
		draw_found_list(s)
		return
	}

	{
		ui.row("", {}, ui.fill(), ui.px(HEADER_H))
		ui.text_style(.Regular, 12, SECONDARY)
		ui.spacer(ui.px(8))
		num := ui.label("#", ui.px(cols.number), ui.fill())
		num.text_align = .Center
		ui.spacer(ui.px(cols.cover))
		ui.label("Title", ui.fill(), ui.fill())
		header_cell("Album", cols.album, .Left)
		header_cell("Date added", cols.added, .Left)
		if cols.heart > 0 {
			ui.spacer(ui.px(cols.heart))
		}
		header_cell("Time", cols.duration, .Right)
		ui.spacer(ui.px(cols.more + 8 + ui.scroll_gutter("tracks")))
	}
	{
		ui.row("", {}, ui.fill(), ui.px(1))
		ui.spacer(ui.px(16))
		line := ui.box_make("", {.Draw_Background}, ui.fill(), ui.px(1))
		line.background = OUTLINE
		ui.spacer(ui.px(16))
	}

	list := ui.scroll_view("tracks", ui.fill(), ui.fill(), {.Focusable})
	ui.accessible(list, .Table, view_title(s))
	if s.bench.running && s.bench.ui {
		list.view_off.y = bench_offset(s, list.rect.h)
		list.view_off_target.y = list.view_off.y
	} else if s.data.bench.running {
		list.view_off.y = cover_bench_offset(s, list)
		list.view_off_target.y = list.view_off.y
	} else if lib.anchor_row >= 0 {
		list.view_off.y = f32(lib.anchor_row) * TRACK_ROW_H + lib.anchor_offset
		list.view_off_target.y = list.view_off.y
	}
	lib.anchor_row = -1
	lib.top_row = int(list.view_off.y / TRACK_ROW_H)
	lib.top_offset = list.view_off.y - f32(lib.top_row) * TRACK_ROW_H
	if table_keys(s, list, view_count(s)) {
		ui.scroll_to(list, f32(lib.selected) * TRACK_ROW_H, f32(lib.selected + 1) * TRACK_ROW_H)
	}

	{
		rows := ui.virtual_rows(list, view_count(s), TRACK_ROW_H)
		for i in rows.first ..< rows.last {
			track_row(s, i, cols)
		}
		cover_prefetch(s, rows.first - COVER_PREFETCH_ROWS, rows.first, 40)
		cover_prefetch(s, rows.last, rows.last + COVER_PREFETCH_ROWS, 40)
	}
}

header_cell :: proc(label: string, width: f32, align: ui.Align) {
	if width <= 0 {
		return
	}
	b := ui.label(label, ui.px(width), ui.fill())
	b.text_pad = CELL_PAD
	b.text_align = align
}

// table_keys moves the selection among the first count rows with the
// arrow keys while the table has the focus, and plays the selected row with
// Enter or Space. A row selected past count, as in an artist's full top
// tracks, isn't one of them. It returns true when the selection moved, for
// the caller to scroll it into view.
table_keys :: proc(s: ^State, list: ^ui.Box, count: int) -> (moved: bool) {
	lib := &s.library
	sel := lib.selected if lib.selected < count else -1
	if ui.signal(list).keyboard && sel >= 0 {
		play(s, sel)
	}
	if !ui.has_focus(list) {
		return
	}
	page := max(int(list.rect.h / TRACK_ROW_H) - 1, 1)
	moved = true
	switch {
	case ui.take_key(.Down):
		sel += 1
	case ui.take_key(.Up):
		sel = sel - 1 if sel >= 0 else 0
	case ui.take_key(.Page_Down):
		sel += page
	case ui.take_key(.Page_Up):
		sel -= page
	case ui.take_key(.Home):
		sel = 0
	case ui.take_key(.End):
		sel = count - 1
	case:
		moved = false
	}
	if moved {
		lib.selected = clamp(sel, 0, count - 1)
	}
	return
}

track_row :: proc(s: ^State, i: int, cols: Track_Columns) {
	lib := &s.library
	track := view_row(s, i)
	if track == nil {
		loading_row(i, cols)
		return
	}
	s.measure.rows += 1
	row := ui.row(fmt.tprintf("##track%d", i), {.Clickable, .Draw_Background, .Draw_Hot_Effects}, ui.fill(), ui.px(TRACK_ROW_H))
	row.radius = 6
	selected := lib.selected == i
	row_highlight(row, LIST_ROWS, selected)
	ui.accessible(row, .Row, fmt.tprintf("%s, %s, %s", track.title, track.artist, track.album), selected = selected)
	sig := ui.signal(row)
	if sig.pressed || sig.right_clicked {
		lib.selected = i
	}
	// A press from an assistive app comes as a keyboard click.
	if sig.double_clicked || (sig.clicked && sig.keyboard) {
		lib.selected = i
		play(s, i)
	}
	if sig.right_clicked {
		open_track_menu(s, i, ui.mouse())
	}
	if sig.dragging {
		ui.drag_begin(u64(i))
	}

	current := lib.playing == i
	ui.spacer(ui.px(8))
	{
		ui.text_style(.Regular, 14, ACCENT if current else SECONDARY)
		num := ui.label(fmt.tprint(i + 1), ui.px(cols.number), ui.fill())
		num.text_align = .Center
	}
	cover_art(s, .Album, track.cover, u32(i) * 2654435761 >> 7, 40, ui.px(cols.cover))
	{
		ui.column("", {}, ui.fill(), ui.fill())
		ui.spacer(ui.px(9))
		title := ui.label(track.title, ui.fill(), ui.px(20))
		title.text_pad = 4
		title.font = .Medium
		title.font_size = 14
		title.text_color = ACCENT if current else TEXT
		ui.accessible(title, .Static_Text, track.title)
		ui.text_style(.Regular, 13, SECONDARY)
		if k, link := artist_links(s, track.artist, track.artists, 4, ui.px(18), {.Click_On_Release}); row_link(s, i, link) {
			go_to_artist(s, i, k)
		}
	}
	ui.text_style(.Regular, 13, SECONDARY)
	if cols.album > 0 {
		ui.row("", {}, ui.px(cols.album), ui.fill())
		ui.spacer(ui.px(CELL_PAD - 4))
		if row_link(s, i, text_link(s, track.album, "###album", track.album_id != 0, ui.fill(), 4, {.Click_On_Release})) {
			go_to_album(s, i)
		}
	}
	cell(track.added, cols.added, .Left)
	key := i64(fake_row_index(s, i)) if s.data.fake else track.id
	liked := liked_has(&s.data, key)
	heart_sig := heart_button(fmt.tprintf("heart%d", i), liked, fmt.tprintf("%s %s", "Unlike" if liked else "Like", track.title), TEXT, max(row.hot_t, 1 if selected else 0), cols.heart)
	if heart_sig.clicked {
		lib.selected = i
		liked_toggle(s, key)
		ui.data_changed() // this frame drew the old heart
	}
	cell(track.duration, cols.duration, .Right)

	more, more_sig := icon_button("more", text.ICON_DOTS_THREE, .Icon, fmt.tprintf("More options for %s", track.title), TEXT, max(row.hot_t, 1 if selected else 0), cols.more)
	if more_sig.clicked {
		lib.selected = i
		open_track_menu(s, i, {more.rect.x, more.rect.y + more.rect.h})
	}
	ui.tooltip(more_sig, "More")
	ui.spacer(ui.px(8))
}

// icon_button is a square icon button of side, centred in the cell it sits
// in: the square is the click and hover area. hot is its opacity, so 0
// hides it while it still clicks. Returns the button's box for anything
// anchored to it, such as a menu. flags adds to the button's, such as
// Focusable for one outside a row.
icon_button :: proc(id, icon: string, font: text.Font, name: string, color: render.Color, hot: f32, side: f32, flags: ui.Box_Flags = {}) -> (^ui.Box, ui.Signal) {
	ui.column("", {}, ui.px(side), ui.fill())
	ui.spacer(ui.fill())
	b := ui.box_make(fmt.tprintf("%s###%s", icon, id), {.Clickable, .Draw_Text, .Draw_Hot_Effects} + flags, ui.px(side), ui.px(side))
	b.text_align = .Center
	b.font = font
	b.font_size = 16
	b.text_color = color
	b.radius = 6
	b.opacity = hot
	ui.accessible(b, .Button, name)
	ui.spacer(ui.fill())
	sig := ui.signal(b)
	return b, sig
}

// heart_button is a filled heart in the accent when the track is liked,
// and an outline in color at opacity hot otherwise (0 hides it, but it
// still clicks).
heart_button :: proc(id: string, liked: bool, name: string, color: render.Color, hot: f32, side: f32) -> ui.Signal {
	_, sig := icon_button(
		id,
		text.ICON_HEART_FILL if liked else text.ICON_HEART,
		.Icon_Fill if liked else .Icon,
		name,
		ACCENT if liked else color,
		1 if liked else hot,
		side,
	)
	ui.tooltip(sig, "Remove from Liked Songs" if liked else "Save to Liked Songs")
	return sig
}

// row_link takes the signal of a link in row i of the track table, and
// returns true when it was clicked. A press, a right click or a drag on it
// does what it does on the row, so the link must have Click_On_Release.
row_link :: proc(s: ^State, i: int, sig: ui.Signal) -> bool {
	if sig.pressed || sig.right_clicked {
		s.library.selected = i
	}
	if sig.right_clicked {
		open_track_menu(s, i, ui.mouse())
	}
	if sig.dragging {
		ui.drag_begin(u64(i))
	}
	return sig.clicked && !sig.dragging
}

// text_link is a link to an album or an artist when it has an id to open
// (the fake data goes by name), and plain text when it hasn't. It goes
// inside a row of its own, since it's only as wide as its text.
text_link :: proc(s: ^State, label, id: string, has_id: bool, height: ui.Size, pad: f32, flags: ui.Box_Flags = {}) -> ui.Signal {
	if !has_id && !s.data.fake {
		b := ui.label(label, ui.fill(), height)
		b.text_pad = pad
		ui.accessible(b, .Static_Text, label)
		return {}
	}
	return ui.link(fmt.tprintf("%s%s", label, id), TEXT, height, pad, flags)
}

// artist_links shows the artists in joined, each a link to its top tracks,
// with the commas between them as plain text. Without refs the whole
// string is one link for the fake data and text otherwise. When they don't
// fit, the one that crosses the edge ends in an ellipsis and the rest are
// left out. That goes by the box's width from the last layout, and the box
// clips, so in the frame after a resize nothing is drawn past it. sig is
// the signal of the link that was clicked, pressed or dragged, and k says
// which artist it is.
artist_links :: proc(s: ^State, joined: string, refs: []Artist_Ref, pad: f32, height := ui.Size{}, flags: ui.Box_Flags = {}) -> (k: int, sig: ui.Signal) {
	box := ui.row("###artists", {.Clip}, ui.fill(), height if height.kind != .Null else ui.fill())
	ui.spacer(ui.px(pad))
	room := box.rect.w - 2 * pad if box.rect.w > 0 else max(f32)
	x: f32
	for j in 0 ..< max(len(refs), 1) {
		name, linked := joined, s.data.fake
		if len(refs) > 0 {
			name, linked = artist_name(joined, refs[j]), refs[j].id != 0
		}
		if j > 0 {
			sep := ui.label(joined[refs[j - 1].end:refs[j].start], ui.text_size(0, 0), ui.fill())
			x += ui.text_width(sep.font, sep.font_size, sep.label)
		}
		b: ^ui.Box
		if linked {
			link := ui.link(fmt.tprintf("%s###artist%d", name, j), TEXT, ui.fill(), flags = flags)
			b = link.box
			if link.clicked || link.pressed || link.right_clicked || link.dragging {
				k, sig = j, link
			}
		} else {
			b = ui.label(name, ui.text_size(0, 0), ui.fill())
			ui.accessible(b, .Static_Text, name)
		}
		w := ui.text_width(b.font, b.font_size, name)
		if x + w > room {
			b.pref_size[.X] = ui.px(max(room - x, 0))
			break
		}
		x += w
	}
	return
}

// loading_row stands in for a row whose page hasn't arrived: its number
// and grey bars where the cover and text go.
loading_row :: proc(i: int, cols: Track_Columns) {
	ui.row(fmt.tprintf("##track%d", i), {}, ui.fill(), ui.px(TRACK_ROW_H))
	ui.spacer(ui.px(8))
	ui.text_style(.Regular, 14, DIM)
	num := ui.label(fmt.tprint(i + 1), ui.px(cols.number), ui.fill())
	num.text_align = .Center
	bar :: proc(w, h: f32, cell: ui.Size, color: render.Color) {
		ui.column("", {}, cell, ui.fill())
		ui.spacer(ui.fill())
		b := ui.box_make("", {.Draw_Background}, ui.px(w), ui.px(h))
		b.background = color
		b.radius = 4
		ui.spacer(ui.fill())
	}
	bar(40, 40, ui.px(cols.cover), SURFACE)
	ui.spacer(ui.px(4))
	bar(180, 12, ui.fill(), SURFACE)
}

cell :: proc(s: string, width: f32, align: ui.Align) -> ^ui.Box {
	if width <= 0 {
		return nil
	}
	b := ui.label(s, ui.px(width), ui.fill())
	b.text_pad = CELL_PAD
	b.text_align = align
	return b
}

CELL_PAD :: 12

// list_gen tells the open list from the lists before it.
list_gen :: proc(s: ^State) -> u64 {
	return u64(s.data.view.gen) << 32 | u64(s.library.list_gen)
}

// row_key tells row i of the open list from the other rows: its TIDAL id,
// or with the fake data its index in State.rows. -1 while it's loading.
row_key :: proc(s: ^State, i: int) -> i64 {
	row := view_row(s, i)
	if row == nil {
		return -1
	}
	return i64(fake_row_index(s, i)) if s.data.fake else row.id
}

// open_track_menu opens the track menu for row i, bound to the list and
// the track it was opened on.
open_track_menu :: proc(s: ^State, i: int, pos: [2]f32) {
	lib := &s.library
	lib.menu_row = i
	lib.menu_track = row_key(s, i)
	lib.menu_list = list_gen(s)
	ui.open_menu("track_menu", pos)
}

// track_menu_row is the row the track menu is for, or -1 when another list
// has replaced the one it opened on, or the row holds another track.
track_menu_row :: proc(s: ^State) -> int {
	lib := &s.library
	if lib.menu_list != list_gen(s) || row_key(s, lib.menu_row) != lib.menu_track {
		return -1
	}
	return lib.menu_row
}

// draw_track_menu offers what the row's data allows: the album and artist
// need their ids (the fake data goes by name), the link a TIDAL track id.
// Its actions wait for the end of the frame (see Pending): the player bar
// built above it shows the queue that Play replaces. It closes once its
// row is gone, and does nothing while it fades out.
draw_track_menu :: proc(s: ^State) {
	i := track_menu_row(s)
	if i < 0 && ui.menu_is_open("track_menu") {
		ui.close_menu()
	}
	row := view_row(s, i)
	if ui.menu("track_menu") {
		ui.text_style(.Regular, 13, TEXT)
		if ui.menu_item("Play").clicked && i >= 0 {
			pending_set(s, {kind = .Play, index = i})
		}
		fake := s.data.fake
		if row != nil && (fake || row.album_id != 0 || first_artist(row.artists) != 0) {
			ui.menu_separator()
		}
		if row != nil && (fake || row.album_id != 0) && ui.menu_item("Go to album").clicked {
			go_to_album(s, i)
		}
		if row != nil && (fake || len(row.artists) == 1) && ui.menu_item("Go to artist").clicked {
			go_to_artist(s, i)
		}
		// A song by several artists offers each of them.
		if row != nil && len(row.artists) > 1 {
			for a, k in row.artists {
				if a.id != 0 && ui.menu_item(fmt.tprintf("Go to %s###artist%d", artist_name(row.artist, a), k)).clicked {
					go_to_artist(s, i, k)
				}
			}
		}
		if row != nil && row.id > 0 {
			ui.menu_separator()
			if ui.menu_item("Copy song link").clicked {
				ui.copy_to_clipboard(track_link(row.id))
				set_status(s, .Copied, i)
			}
		}
	}
}

// draw_drag_ghost follows the mouse with the dragged row's title.
draw_drag_ghost :: proc(s: ^State) {
	lib := &s.library
	track, dragging := ui.drag_payload()
	if !dragging {
		return
	}
	ui.floating()
	ghost := ui.row("drag_ghost", {.Floating_X, .Floating_Y, .Draw_Background, .Draw_Shadow, .Draw_Border}, ui.px(260), ui.px(40))
	ghost.fixed_pos = ui.mouse() + {12, 10}
	ghost.background = SURFACE_ACTIVE
	ghost.border_color = ACCENT if lib.drop_target >= 0 else OUTLINE
	ghost.radius = 6
	ghost.opacity = 0.95
	ui.text_style(.Medium, 13, TEXT)
	row := view_row(s, int(track))
	b := ui.label(row.title if row != nil else "", ui.fill(), ui.fill())
	b.text_pad = 12
}

draw_player_bar :: proc(s: ^State, w: f32) {
	bar := ui.column("player", {.Draw_Background}, ui.fill(), ui.px(PLAYER_BAR_H))
	bar.background = PANEL
	line := ui.box_make("", {.Draw_Background}, ui.fill(), ui.px(1))
	line.background = OUTLINE
	ui.row("", {}, ui.fill(), ui.fill())
	side := clamp(w * 0.3, 200, 420)
	// Below about 670 pt the title gives up room before the progress bar.
	title_side := clamp(w * 0.3, 150, 420)
	ui.spacer(ui.px(16))

	item := playback_item(s)
	{
		ui.row("now_playing", {}, ui.px(title_side), ui.fill())
		title := "Nothing playing"
		if item != nil {
			title = item.title
			cover_art(s, .Album, item.cover, u32(s.playback.index) * 2654435761 >> 7, 56, ui.px(56))
			ui.spacer(ui.px(12))
		}
		ui.column("", {}, ui.fill(), ui.fill())
		ui.spacer(ui.fill())
		ui.text_style(.Medium, 14, TEXT)
		if item == nil {
			ui.accessible(ui.label(title, ui.fill(), ui.px(20)), .Static_Text, title)
		} else {
			ui.row("", {}, ui.fill(), ui.px(20))
			if text_link(s, title, "###album", item.album_id != 0, ui.fill(), 0).clicked {
				open_album(s, item.album_id, item.album, item.cover, item.row)
			}
			ui.spacer(ui.px(4))
			pb := &s.playback
			playing := i64(0)
			if pb.fake {
				playing = i64(item.row)
			} else if pb.index < len(pb.entries) {
				playing = pb.entries[pb.index].id
			}
			liked := liked_has(&s.data, playing)
			if heart_button("heart_bar", liked, "Unlike" if liked else "Like", SECONDARY, 1, 20).clicked {
				liked_toggle(s, playing)
				ui.data_changed()
			}
		}
		// A track that couldn't play says why in place of the artist, on
		// two lines when it's two sentences.
		msg := small_str(&s.playback.message)
		if msg == "" {
			ui.text_style(.Regular, 12, SECONDARY)
			if item == nil {
				ui.spacer(ui.px(18))
			} else if k, sig := artist_links(s, item.artist, item.artists, 0, ui.px(18)); sig.clicked {
				open_artist_of(s, item.artist, item.artists, k, item.row)
			}
		} else {
			ui.text_style(.Regular, 12, PLAYBACK_ERROR)
			first, rest := msg, ""
			if i := strings.index(msg, ". "); i >= 0 {
				first, rest = msg[:i + 1], msg[i + 2:]
			}
			ui.accessible(ui.label(first, ui.fill(), ui.px(16)), .Static_Text, msg)
			if rest != "" {
				ui.label(rest, ui.fill(), ui.px(16))
			}
		}
		ui.spacer(ui.fill())
	}

	{
		ui.column("transport", {}, ui.fill(), ui.fill())
		ui.spacer(ui.px(14))
		{
			ui.row("", {}, ui.fill(), ui.px(36))
			ui.spacer(ui.fill())
			shuffle := s.settings.shuffle
			shuffle_sig := toggle_button("shuffle", text.ICON_SHUFFLE, "Shuffle", "On" if shuffle else "Off", shuffle)
			if shuffle_sig.clicked {
				playback_set_shuffle(s, !shuffle)
				ui.data_changed() // this frame drew the old state
			}
			ui.tooltip(shuffle_sig, "Shuffle")
			ui.spacer(ui.px(16))
			prev := skip_button("prev", false)
			if prev.clicked {
				playback_previous(s)
			}
			ui.tooltip(prev, "Previous")
			ui.spacer(ui.px(16))
			playing := playback_playing(s)
			sig := play_button(playing)
			if sig.clicked {
				playback_toggle(s)
			}
			ui.tooltip(sig, "Pause" if playing else "Play")
			ui.spacer(ui.px(16))
			next := skip_button("next", true)
			if next.clicked {
				playback_next(s)
			}
			ui.tooltip(next, "Next")
			ui.spacer(ui.px(16))
			repeat := s.settings.repeat
			REPEAT_NAMES := [audio.Repeat]string {
				.Off = "Off",
				.All = "All",
				.One = "One",
			}
			repeat_sig := toggle_button("repeat", text.ICON_REPEAT_ONCE if repeat == .One else text.ICON_REPEAT, "Repeat", REPEAT_NAMES[repeat], repeat != .Off)
			if repeat_sig.clicked {
				playback_set_repeat(s, audio.Repeat((int(repeat) + 1) % len(audio.Repeat)))
				ui.data_changed()
			}
			ui.tooltip(repeat_sig, "Repeat one" if repeat == .One else "Repeat")
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(6))
		{
			// The times keep the width of the longest value the track can
			// show, so they never cut off or push the bar around; the bar
			// takes what's left.
			ui.row("", {}, ui.fill(), ui.px(16))
			ui.text_style(.Regular, 11, DIM)
			duration := playback_duration(s)
			position := playback_position(s)
			longest := clock(max(duration, position))
			at := ui.label(clock(position), ui.px(ui.counter_width(.Regular, 11, longest) + 2 * TIME_PAD), ui.fill())
			at.text_align = .Right
			at.text_pad = TIME_PAD
			draw_progress(s, position, duration, item != nil)
			left := "0:00"
			if item != nil {
				left = fmt.tprintf("-%s", clock(max(duration - position, 0)))
			}
			end := ui.label(left, ui.px(ui.counter_width(.Regular, 11, fmt.tprintf("-%s", longest)) + 2 * TIME_PAD), ui.fill())
			end.text_pad = TIME_PAD
		}
	}

	{
		// Laid out by hand so it fits in side at any window width: the volume
		// slider gives up room before anything else does.
		ui.row("extras", {}, ui.px(side), ui.fill())
		slider_w := clamp(side - OUTPUT_W - OUTPUT_GAP, 0, VOLUME_W)
		ui.spacer(ui.px(side - OUTPUT_W - OUTPUT_GAP - slider_w, 0))
		draw_output_button(s)
		draw_volume(s, slider_w)
	}
	ui.spacer(ui.px(16))
}

TIME_PAD :: 8 // between the times and the progress bar
OUTPUT_W :: 78 // the Output button
OUTPUT_GAP :: 12
VOLUME_W :: 110

// clock formats seconds as m:ss, or h:mm:ss from an hour.
clock :: proc(seconds: f64) -> string {
	t := int(max(seconds, 0))
	if t >= 3600 {
		return fmt.tprintf("%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
	}
	return fmt.tprintf("%d:%02d", t / 60, t % 60)
}

// progress_fraction is how much of the bar is filled: position over
// duration, both in seconds at the track's own rate, kept to [0, 1].
progress_fraction :: proc(position, duration: f64) -> f32 {
	if duration <= 0 || math.is_nan(position) {
		return 0
	}
	return f32(clamp(position / duration, 0, 1))
}

// draw_progress is the seek bar. Pressing or dragging shows that position
// straight away; letting go seeks there.
draw_progress :: proc(s: ^State, position, duration: f64, active: bool) {
	pb := &s.playback
	slider := ui.column("progress", {.Clickable} if active else {}, ui.fill(), ui.fill())
	ui.accessible(slider, .Slider, "Position", fmt.tprintf("%s of %s", clock(position), clock(duration)))
	sig := ui.signal(slider)
	if active && duration > 0 && slider.rect.w > 0 && (sig.held || sig.released) {
		frac := clamp((sig.mouse.x - slider.rect.x) / slider.rect.w, 0, 1)
		pb.drag_seconds = f64(frac) * duration
		pb.dragging = !sig.released
		if sig.released {
			playback_seek(s, pb.drag_seconds)
		}
	} else if !sig.held {
		pb.dragging = false
	}
	frac := progress_fraction(playback_position(s), duration)
	ui.spacer(ui.px(6))
	track := ui.row("", {.Draw_Background}, ui.fill(), ui.px(4))
	track.background = SURFACE_ACTIVE
	track.radius = 2
	level := ui.box_make("", {.Draw_Background}, ui.pct(frac, 1), ui.fill())
	level.background = mix(SECONDARY, ACCENT, max(slider.hot_t, slider.active_t))
	level.radius = 2
}

play_button :: proc(playing: bool) -> ui.Signal {
	ui.text_style(.Icon_Fill, 18, PANEL)
	id := text.ICON_PAUSE + "###play" if playing else text.ICON_PLAY + "###play"
	b := ui.box_make(id, {.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(36), ui.px(36))
	b.text_align = .Center
	b.background = TEXT
	b.radius = 18
	b.hover_color = {1, 1, 1, 0.5}
	b.active_color = {0, 0, 0, 0.15}
	ui.accessible(b, .Button, "Pause" if playing else "Play")
	return ui.signal(b)
}

skip_button :: proc(id: string, forward: bool) -> ui.Signal {
	ui.text_style(.Icon_Fill, 18, SECONDARY)
	icon := text.ICON_SKIP_FORWARD if forward else text.ICON_SKIP_BACK
	b := ui.box_make(fmt.tprintf("%s###%s", icon, id), {.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(36), ui.px(36))
	b.text_align = .Center
	b.radius = 18
	ui.accessible(b, .Button, "Next" if forward else "Previous")
	return ui.signal(b)
}

// toggle_button is a transport button lit while on.
toggle_button :: proc(id, icon, name, value: string, on: bool) -> ui.Signal {
	ui.text_style(.Icon, 18, ACCENT if on else SECONDARY)
	b := ui.box_make(fmt.tprintf("%s###%s", icon, id), {.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(36), ui.px(36))
	b.text_align = .Center
	b.radius = 18
	ui.accessible(b, .Button, name, value)
	return ui.signal(b)
}

// draw_volume is a slider: press or drag along it to set the volume. A
// press and release in one frame still counts, at the release.
draw_volume :: proc(s: ^State, width: f32) {
	slider := ui.column("volume", {.Clickable}, ui.px(width), ui.fill())
	ui.accessible(slider, .Slider, "Volume", fmt.tprintf("%d%%", int(math.round(s.settings.volume * 100))))
	sig := ui.signal(slider)
	if (sig.held || sig.released) && slider.rect.w > 0 {
		playback_set_volume(s, clamp((sig.mouse.x - slider.rect.x) / slider.rect.w, 0, 1), sig.released)
	}
	ui.spacer(ui.fill())
	{
		track := ui.row("", {.Draw_Background}, ui.fill(), ui.px(4))
		track.background = SURFACE_ACTIVE
		track.radius = 2
		level := ui.box_make("", {.Draw_Background}, ui.pct(s.settings.volume, 1), ui.fill())
		level.background = mix(SECONDARY, ACCENT, max(slider.hot_t, slider.active_t))
		level.radius = 2
	}
	ui.spacer(ui.fill())
}

play :: proc(s: ^State, i: int) {
	if view_row(s, i) == nil {
		return
	}
	playback_play_row(s, i)
	set_status(s, .Playing, i)
}

// row_playable says whether row i of the open list is loaded and can play.
row_playable :: proc(s: ^State, i: int) -> bool {
	row := view_row(s, i)
	return row != nil && (row.id != 0 || s.data.fake)
}

// play_ordered plays the row of a .Play. With an order it first sets
// shuffle to match, then plays the first row, or a loaded row picked at
// random. It returns false when there's nothing to play.
play_ordered :: proc(s: ^State, p: Pending) -> bool {
	i := p.index
	switch p.order {
	case .Keep:
	case .In_Order:
		i = 0
	case .Shuffled:
		// Each playable row is picked with the same chance, in one pass.
		seen := 0
		for j in 0 ..< view_count(s) {
			if row_playable(s, j) {
				seen += 1
				if rand.int_max(seen) == 0 {
					i = j
				}
			}
		}
	}
	if !row_playable(s, i) {
		return false
	}
	if p.order != .Keep && s.settings.shuffle != (p.order == .Shuffled) {
		playback_set_shuffle(s, p.order == .Shuffled)
	}
	play(s, i)
	return true
}

set_status :: proc(s: ^State, status: Status, track: int, list := -1) {
	s.library.status = status
	s.library.status_track = track
	s.library.status_list = list
}

status_text :: proc(s: ^State) -> string {
	lib := &s.library
	if status := data_status(s); status != "" {
		return status
	}
	if lib.status == .Copied_Artist {
		return fmt.tprintf("Copied the link to %s", view_title(s))
	}
	t := view_row(s, lib.status_track)
	if lib.status == .None || t == nil {
		return ""
	}
	switch lib.status {
	case .None:
	case .Playing:
		return fmt.tprintf("Playing %s by %s", t.title, t.artist)
	case .Adding:
		return fmt.tprintf("Adding %s to %s…", t.title, sidebar_entry(s, lib.status_list).name)
	case .Added:
		return fmt.tprintf("Added %s to %s", t.title, sidebar_entry(s, lib.status_list).name)
	case .Already_In:
		return fmt.tprintf("%s is already in %s", t.title, sidebar_entry(s, lib.status_list).name)
	case .Add_Failed:
		return fmt.tprintf("Couldn't add %s to %s", t.title, sidebar_entry(s, lib.status_list).name)
	case .Copied:
		return fmt.tprintf("Copied the link to %s", t.title)
	case .Copied_Artist:
	}
	return ""
}

// Pending is something the frame being built asked for that frees memory
// the frame still uses. Boxes and the accessibility tree borrow their
// strings until end_frame: from the open list's arena (its rows, and the
// row a menu is for), from the search results' arena and from the play
// queue's. So opening another list, closing the search or replacing the
// queue waits until the frame is done, and pending_apply does it then.
// The last one asked for in a frame wins.
Pending :: struct {
	kind:   Pending_Kind,
	source: Source, // .List
	// .Playlist: the sidebar entry. .Play: the row. .List with the fake
	// data: the row in State.rows whose album or artist to list.
	index:  int,
	id:     Small,
	name:   Small,
	image:  Small,
	hint:   int,
	// .List of .Artist: the page, its full top tracks or a shelf's grid.
	artist_view: Artist_View,
	order:  Play_Order, // .Play
}

// Play_Order is what Play and Shuffle on a page ask .Play for: the first
// row with shuffle off, or a random row with it on. Keep plays index and
// leaves shuffle as it is.
Play_Order :: enum u8 {
	Keep,
	In_Order,
	Shuffled,
}

Pending_Kind :: enum u8 {
	None,
	Playlist, // open a sidebar entry
	List, // open an album, an artist or a playlist that isn't in the sidebar
	Search, // search for id again
	Close_Search,
	Play,
	Back,
	Forward,
}

pending_set :: proc(s: ^State, p: Pending) {
	s.pending = p
}

// pending_apply does what the last frame asked for. Run it after the frame
// is drawn; it returns true when it changed something worth a frame.
pending_apply :: proc(s: ^State) -> bool {
	p := s.pending
	s.pending = {}
	switch p.kind {
	case .None:
		return false
	case .Playlist, .List, .Search:
		history_visit(s, p)
		place_go(s, &p)
	case .Close_Search:
		if search_showing(s) {
			history_visit(s, {kind = .Playlist, index = s.library.playlist})
		}
		search_close(s)
	case .Play:
		if !play_ordered(s, p) {
			return false
		}
	case .Back, .Forward:
		h := &s.history
		to := h.at - 1 if p.kind == .Back else h.at + 1
		if to < 0 || to >= h.count {
			return false
		}
		h.at = to
		place := h.places[to]
		place_go(s, &place)
	}
	ui.data_changed()
	return true
}

// place_go shows a place, a Pending of kind .Playlist, .List or .Search,
// without recording it in the history.
place_go :: proc(s: ^State, p: ^Pending) {
	search_stop(s)
	#partial switch p.kind {
	case .Playlist:
		select_playlist(s, playlist_index(s, p))
	case .List:
		open_list(s, p)
	case .Search:
		search_again(s, small_str(&p.id))
	}
}

HISTORY_MAX :: 50

// History is the places visited, oldest first; at is the one showing.
History :: struct {
	places: [HISTORY_MAX]Pending,
	count:  int,
	at:     int,
}

// history_visit records p as the place showing next, dropping the places
// Forward would have gone to. Searches in a row are one place, so typing a
// query leaves one entry however many times the debounce ran out.
history_visit :: proc(s: ^State, p: Pending) {
	h := &s.history
	if h.count == 0 {
		h.places[0] = playlist_place(s, s.library.playlist)
		h.count, h.at = 1, 0
	}
	p := p
	if p.kind == .Playlist {
		p = playlist_place(s, p.index)
	}
	now := &h.places[h.at]
	if now.kind == p.kind && now.source == p.source && now.index == p.index && now.id == p.id && same_artist_view(now.artist_view, p.artist_view) {
		return
	}
	if now.kind != .Search || p.kind != .Search {
		if h.at == HISTORY_MAX - 1 {
			copy(h.places[:], h.places[1:])
			h.at -= 1
		}
		h.at += 1
	}
	h.places[h.at] = p
	h.count = h.at + 1
}

// playlist_place is sidebar entry i as a place. A TIDAL playlist goes by
// its id, since the sidebar can change order before Back returns to it.
playlist_place :: proc(s: ^State, i: int) -> Pending {
	items := s.data.sidebar.items
	if s.data.fake || i < 1 || i > len(items) {
		return {kind = .Playlist, index = i}
	}
	return {kind = .Playlist, id = small(items[i - 1].id)}
}

// playlist_index is where a playlist place is in the sidebar now, -1 when
// it's gone.
playlist_index :: proc(s: ^State, p: ^Pending) -> int {
	if p.id.len == 0 {
		return p.index
	}
	for it, i in s.data.sidebar.items {
		if it.id == small_str(&p.id) {
			return i + 1
		}
	}
	return -1
}

history_can_back :: proc(s: ^State) -> bool {
	return s.history.at > 0
}

history_can_forward :: proc(s: ^State) -> bool {
	return s.history.at + 1 < s.history.count
}

mix :: proc(a, b: render.Color, t: f32) -> render.Color {
	return a + (b - a) * t
}
