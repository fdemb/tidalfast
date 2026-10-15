// The library screen, laid out like spotifast: a resizable sidebar of
// playlists, the main view with the playlist's track table, and the 88 pt
// player bar along the bottom. The data comes from data.odin: TIDAL, or
// the fake data with TIDALFAST_FAKE=1.
package app

import "core:fmt"
import "core:math"

import "../render"
import "../ui"

// spotifast's dark palette.
WINDOW_BG :: render.Color{0x0f / 255.0, 0x11 / 255.0, 0x14 / 255.0, 1}
PANEL :: render.Color{0x15 / 255.0, 0x18 / 255.0, 0x1c / 255.0, 1}
SURFACE :: render.Color{0x1d / 255.0, 0x21 / 255.0, 0x27 / 255.0, 1}
SURFACE_ACTIVE :: render.Color{0x2f / 255.0, 0x35 / 255.0, 0x3f / 255.0, 1}
OUTLINE :: render.Color{0x2a / 255.0, 0x30 / 255.0, 0x38 / 255.0, 1}
TEXT :: render.Color{0xf2 / 255.0, 0xf4 / 255.0, 0xf6 / 255.0, 1}
SECONDARY :: render.Color{0xa9 / 255.0, 0xb1 / 255.0, 0xbc / 255.0, 1}
DIM :: render.Color{0x6e / 255.0, 0x77 / 255.0, 0x84 / 255.0, 1}
ACCENT :: render.Color{0x1e / 255.0, 0xd7 / 255.0, 0x60 / 255.0, 1}
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
	volume:        f32,
	menu_row:      int, // the row the context menu is for
	drop_target:   int, // the playlist under a dragged row this frame, -1 for none
	status:        Status,
	status_track:  int,
	status_list:   int,
}

Status :: enum u8 {
	None,
	Playing,
	Queued,
	Added,
	Album,
	Artist,
	Copied,
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
	number, cover, album, added_by, added, duration, more: f32,
}

// track_columns follows spotifast: the album shows above 560 pt, the date
// added above 760 and who added it above 920.
track_columns :: proc(width: f32) -> Track_Columns {
	return {
		number = 44,
		cover = 52,
		album = clamp(width * 0.28, 140, 360) if width > 560 else 0,
		added_by = 130 if width > 920 else 0,
		added = 120 if width > 760 else 0,
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
		volume      = 0.7,
		menu_row    = -1,
		drop_target = -1,
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

draw_sidebar :: proc(s: ^State) {
	lib := &s.library
	side := ui.column("sidebar", {.Draw_Background, .Clip}, ui.px(lib.sidebar_w), ui.fill())
	side.background = PANEL
	{
		ui.row("", {}, ui.fill(), ui.px(52))
		ui.spacer(ui.px(16))
		ui.text_style(.Semibold, 15, TEXT)
		ui.label("Your Library", ui.fill(), ui.fill())
	}
	ui.scroll_view("playlists", ui.fill(), ui.fill())
	for i in 0 ..< sidebar_count(s) {
		entry := sidebar_entry(s, i)
		item := ui.row(fmt.tprintf("##playlist%d", i), {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Draw_Border}, ui.fill(), ui.px(PLAYLIST_ROW_H))
		item.radius = 6
		if lib.playlist == i {
			item.background = SURFACE_ACTIVE
		}
		if ui.drop_hover(item) {
			lib.drop_target = i
			item.border_color = ACCENT
		}
		if track, ok := ui.dropped(item); ok {
			set_status(s, .Added, int(track), i)
		}
		sig := ui.signal(item)
		if sig.clicked {
			select_playlist(s, i)
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
	cols := track_columns(main_w)
	ui.column("main", {.Clip}, ui.fill(), ui.fill())

	{
		ui.row("", {}, ui.fill(), ui.px(124))
		ui.spacer(ui.px(24))
		if !s.data.fake && s.data.view.source != .None {
			cover_art(s, .Playlist, small_str(&s.data.view.image), u32(lib.playlist) * 7919 + 13, 92, ui.px(92))
			ui.spacer(ui.px(18))
		}
		ui.column("", {}, ui.fill(), ui.fill())
		ui.spacer(ui.px(26))
		ui.text_style(.Bold, 28, TEXT)
		ui.label(view_title(s), ui.fill(), ui.px(38))
		ui.text_style(.Regular, 13, SECONDARY)
		ui.label(view_subtitle(s, main_w), ui.fill(), ui.px(20))
		ui.text_style(.Regular, 12, DIM)
		ui.label(status_text(s), ui.fill(), ui.px(18))
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
		header_cell("Added by", cols.added_by, .Left)
		header_cell("Date added", cols.added, .Left)
		header_cell("Time", cols.duration, .Right)
		ui.spacer(ui.px(cols.more + 8))
	}
	{
		ui.row("", {}, ui.fill(), ui.px(1))
		ui.spacer(ui.px(16))
		line := ui.box_make("", {.Draw_Background}, ui.fill(), ui.px(1))
		line.background = OUTLINE
		ui.spacer(ui.px(16))
	}

	list := ui.scroll_view("tracks", ui.fill(), ui.fill(), {.Focusable})
	if s.bench.running && s.bench.ui {
		list.view_off.y = bench_offset(s, list.rect.h)
		list.view_off_target.y = list.view_off.y
	} else if s.data.bench.running {
		list.view_off.y = cover_bench_offset(s, list)
		list.view_off_target.y = list.view_off.y
	}
	table_keys(s, list)
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
	b.text_pad = 12
	b.text_align = align
}

// table_keys moves the selection with the arrow keys while the table has
// the focus, and plays the selected row with Enter or Space.
table_keys :: proc(s: ^State, list: ^ui.Box) {
	lib := &s.library
	if ui.signal(list).keyboard && lib.selected >= 0 {
		play(s, lib.selected)
	}
	if !ui.has_focus(list) {
		return
	}
	page := max(int(list.rect.h / TRACK_ROW_H) - 1, 1)
	sel := lib.selected
	moved := true
	switch {
	case ui.key_pressed(ui.KEY_DOWN):
		sel += 1
	case ui.key_pressed(ui.KEY_UP):
		sel = sel - 1 if sel >= 0 else 0
	case ui.key_pressed(ui.KEY_PAGE_DOWN):
		sel += page
	case ui.key_pressed(ui.KEY_PAGE_UP):
		sel -= page
	case ui.key_pressed(ui.KEY_HOME):
		sel = 0
	case ui.key_pressed(ui.KEY_END):
		sel = view_count(s) - 1
	case:
		moved = false
	}
	if moved {
		lib.selected = clamp(sel, 0, view_count(s) - 1)
		ui.scroll_to(list, f32(lib.selected) * TRACK_ROW_H, f32(lib.selected + 1) * TRACK_ROW_H)
	}
}

track_row :: proc(s: ^State, i: int, cols: Track_Columns) {
	lib := &s.library
	track := view_row(s, i)
	if track == nil {
		loading_row(i, cols)
		return
	}
	row := ui.row(fmt.tprintf("##track%d", i), {.Clickable, .Draw_Background, .Draw_Hot_Effects}, ui.fill(), ui.px(TRACK_ROW_H))
	row.radius = 6
	row.hover_color = {1, 1, 1, 0.05}
	selected := lib.selected == i
	if selected {
		row.background = {SECONDARY.r, SECONDARY.g, SECONDARY.b, 0.2}
	}
	sig := ui.signal(row)
	if sig.pressed || sig.right_clicked {
		lib.selected = i
	}
	if sig.double_clicked {
		play(s, i)
	}
	if sig.right_clicked {
		lib.menu_row = i
		ui.open_menu("track_menu", ui.mouse())
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
		artist := ui.label(track.artist, ui.fill(), ui.px(18))
		artist.text_pad = 4
		artist.text_color = SECONDARY
	}
	ui.text_style(.Regular, 13, SECONDARY)
	cell(track.album, cols.album, .Left)
	cell(track.added_by, cols.added_by, .Left)
	cell(track.added, cols.added, .Left)
	cell(track.duration, cols.duration, .Right)

	more := ui.box_make("…##more", {.Clickable, .Draw_Text, .Draw_Hot_Effects}, ui.px(cols.more), ui.fill())
	more.text_align = .Center
	more.font_size = 16
	more.text_color = TEXT
	more.radius = 6
	more.opacity = max(row.hot_t, 1 if selected else 0)
	more_sig := ui.signal(more)
	if more_sig.clicked {
		lib.selected = i
		lib.menu_row = i
		ui.open_menu("track_menu", {more.rect.x, more.rect.y + more.rect.h})
	}
	ui.tooltip(more_sig, fmt.tprintf("More options for %s", track.title))
	ui.spacer(ui.px(8))
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

cell :: proc(s: string, width: f32, align: ui.Align) {
	if width <= 0 {
		return
	}
	b := ui.label(s, ui.px(width), ui.fill())
	b.text_pad = 12
	b.text_align = align
}

draw_track_menu :: proc(s: ^State) {
	i := s.library.menu_row
	if ui.menu("track_menu") {
		ui.text_style(.Regular, 13, TEXT)
		if ui.menu_item("Play").clicked {
			play(s, i)
		}
		if ui.menu_item("Add to queue").clicked {
			set_status(s, .Queued, i)
		}
		ui.menu_separator()
		if ui.menu_item("Go to album").clicked {
			set_status(s, .Album, i)
		}
		if ui.menu_item("Go to artist").clicked {
			set_status(s, .Artist, i)
		}
		ui.menu_separator()
		if ui.menu_item("Copy song link").clicked {
			set_status(s, .Copied, i)
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
	lib := &s.library
	bar := ui.column("player", {.Draw_Background}, ui.fill(), ui.px(PLAYER_BAR_H))
	bar.background = PANEL
	line := ui.box_make("", {.Draw_Background}, ui.fill(), ui.px(1))
	line.background = OUTLINE
	ui.row("", {}, ui.fill(), ui.fill())
	side := clamp(w * 0.3, 200, 420)
	ui.spacer(ui.px(16))

	item := playback_item(s)
	{
		ui.row("now_playing", {}, ui.px(side), ui.fill())
		title, artist := "Nothing playing", "Double-click a song to play it"
		if item != nil {
			title, artist = item.title, item.artist
			cover_art(s, .Album, item.cover, u32(s.playback.index) * 2654435761 >> 7, 56, ui.px(56))
			ui.spacer(ui.px(12))
		}
		ui.column("", {}, ui.fill(), ui.fill())
		ui.spacer(ui.fill())
		ui.text_style(.Medium, 14, TEXT)
		ui.label(title, ui.fill(), ui.px(20))
		// A track that couldn't play says why in place of the artist.
		color := SECONDARY
		if msg := small_str(&s.playback.message); msg != "" {
			artist, color = msg, PLAYBACK_ERROR
		}
		ui.text_style(.Regular, 12, color)
		ui.label(artist, ui.fill(), ui.px(18))
		ui.spacer(ui.fill())
	}

	{
		ui.column("transport", {}, ui.fill(), ui.fill())
		ui.spacer(ui.px(14))
		{
			ui.row("", {}, ui.fill(), ui.px(36))
			ui.spacer(ui.fill())
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
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(6))
		{
			ui.row("", {}, ui.fill(), ui.px(16))
			ui.text_style(.Regular, 11, DIM)
			duration := playback_duration(s)
			at := ui.label(clock(playback_position(s)), ui.px(44), ui.fill())
			at.text_align = .Right
			at.text_pad = 8
			draw_progress(s, duration, item != nil)
			left := "0:00"
			if item != nil {
				left = fmt.tprintf("-%s", clock(max(duration - playback_position(s), 0)))
			}
			end := ui.label(left, ui.px(44), ui.fill())
			end.text_pad = 8
		}
	}

	{
		ui.row("extras", {}, ui.px(side), ui.fill())
		ui.spacer(ui.fill())
		ui.text_style(.Regular, 12, SECONDARY)
		ui.label(fmt.tprintf("Volume %d%%", int(math.round(lib.volume * 100))), ui.px(84), ui.fill())
		draw_volume(s)
	}
	ui.spacer(ui.px(16))
}

// clock formats seconds as m:ss, or h:mm:ss from an hour.
clock :: proc(seconds: f64) -> string {
	t := int(max(seconds, 0))
	if t >= 3600 {
		return fmt.tprintf("%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
	}
	return fmt.tprintf("%d:%02d", t / 60, t % 60)
}

// draw_progress is the seek bar. Pressing or dragging shows that position
// straight away; letting go seeks there.
draw_progress :: proc(s: ^State, duration: f64, active: bool) {
	pb := &s.playback
	slider := ui.column("progress", {.Clickable} if active else {}, ui.fill(), ui.fill())
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
	frac := f32(0)
	if duration > 0 {
		frac = f32(clamp(playback_position(s) / duration, 0, 1))
	}
	ui.spacer(ui.px(6))
	track := ui.row("", {.Draw_Background}, ui.fill(), ui.px(4))
	track.background = SURFACE_ACTIVE
	track.radius = 2
	level := ui.box_make("", {.Draw_Background}, ui.pct(frac, 1), ui.fill())
	level.background = mix(SECONDARY, ACCENT, max(slider.hot_t, slider.active_t))
	level.radius = 2
}

// The transport glyphs are Inter's triangles and plain rects: the media
// symbols in the Unicode blocks come out as colour emoji.

play_button :: proc(playing: bool) -> ui.Signal {
	b := ui.row("play", {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(36), ui.px(36))
	b.background = TEXT
	b.radius = 18
	b.hover_color = {1, 1, 1, 0.5}
	b.active_color = {0, 0, 0, 0.15}
	if playing {
		ui.spacer(ui.fill())
		pause_bar()
		ui.spacer(ui.px(4))
		pause_bar()
		ui.spacer(ui.fill())
	} else {
		ui.spacer(ui.px(2))
		ui.text_style(.Bold, 14, PANEL)
		icon := ui.label("▶", ui.fill(), ui.fill())
		icon.text_align = .Center
	}
	return ui.signal(b)
}

pause_bar :: proc() {
	ui.column("", {}, ui.px(4), ui.fill())
	ui.spacer(ui.fill())
	bar := ui.box_make("", {.Draw_Background}, ui.fill(), ui.px(14))
	bar.background = PANEL
	bar.radius = 1
	ui.spacer(ui.fill())
}

skip_button :: proc(id: string, forward: bool) -> ui.Signal {
	b := ui.row(id, {.Clickable, .Focusable, .Draw_Hot_Effects, .Draw_Active_Effects}, ui.px(36), ui.px(36))
	b.radius = 18
	ui.spacer(ui.fill())
	if forward {
		skip_glyph("▶")
		skip_stop()
	} else {
		skip_stop()
		skip_glyph("◀")
	}
	ui.spacer(ui.fill())
	return ui.signal(b)
}

skip_glyph :: proc(s: string) {
	ui.text_style(.Regular, 12, SECONDARY)
	ui.label(s, ui.text_size(), ui.fill())
}

skip_stop :: proc() {
	ui.column("", {}, ui.px(2), ui.fill())
	ui.spacer(ui.fill())
	bar := ui.box_make("", {.Draw_Background}, ui.fill(), ui.px(11))
	bar.background = SECONDARY
	ui.spacer(ui.fill())
}

// draw_volume is a slider: press or drag along it to set the volume. A
// press and release in one frame still counts, at the release.
draw_volume :: proc(s: ^State) {
	lib := &s.library
	slider := ui.column("volume", {.Clickable}, ui.px(110), ui.fill())
	sig := ui.signal(slider)
	if (sig.held || sig.released) && slider.rect.w > 0 {
		lib.volume = clamp((sig.mouse.x - slider.rect.x) / slider.rect.w, 0, 1)
		playback_set_volume(s, lib.volume)
	}
	ui.spacer(ui.fill())
	{
		track := ui.row("", {.Draw_Background}, ui.fill(), ui.px(4))
		track.background = SURFACE_ACTIVE
		track.radius = 2
		level := ui.box_make("", {.Draw_Background}, ui.pct(lib.volume, 1), ui.fill())
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
	t := view_row(s, lib.status_track)
	if lib.status == .None || t == nil {
		return "Double-click to play, right-click for more, drag a song onto a playlist"
	}
	switch lib.status {
	case .None:
	case .Playing:
		return fmt.tprintf("Playing %s by %s", t.title, t.artist)
	case .Queued:
		return fmt.tprintf("Added %s to the queue", t.title)
	case .Added:
		return fmt.tprintf("Added %s to %s", t.title, sidebar_entry(s, lib.status_list).name)
	case .Album:
		return fmt.tprintf("Would open %s", t.album)
	case .Artist:
		return fmt.tprintf("Would open %s", t.artist)
	case .Copied:
		return fmt.tprintf("Copied the link to %s", t.title)
	}
	return ""
}

mix :: proc(a, b: render.Color, t: f32) -> render.Color {
	return a + (b - a) * t
}
