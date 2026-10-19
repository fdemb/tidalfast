package app

// The artist page, after TIDAL's: the artist's picture across the top with
// the name and the start of the biography over it, Play and Shuffle, Share
// and More, the top tracks, then a shelf for each part of the page that has
// cards (artist_part_spec). The data is in artist_data.odin.
//
// The page, its full top tracks (Artist_Top_Tracks) and a shelf's grid
// (Artist_Grid) are places in the History, told apart by
// Pending.artist_view, so Back and Forward go through them. All three show
// the open list, the artist's top tracks, which moving between them keeps.
// What shows is worked out from the place and the open list each frame
// (artist_place), so nothing has to be reset on leaving.

import "core:fmt"
import "core:hash"
import "base:runtime"
import "core:strconv"
import "core:strings"

import "../cover"
import "../text"
import "../ui"

HERO_H :: 340
HERO_PX :: 750 // the largest artist picture TIDAL serves
CONTENT_MAX :: 1280 // the page's column, centred in wider windows
PAGE_PAD :: 32
TOP_TRACKS :: 5
BIO_LINES :: 3 // shown until More
BIO_LINE_H :: 20
BIO_W :: 720
BIO_FONT :: text.Font.Regular
BIO_SIZE :: 13

// Artist_View is which of an artist's places a .List of .Artist is: nil
// for the page.
Artist_View :: union {
	Artist_Top_Tracks,
	Artist_Grid,
}

Artist_Top_Tracks :: struct {}

Artist_Grid :: struct {
	part: Artist_Part, // a shelf's, whose spec has a source
}

same_artist_view :: proc(a, b: Artist_View) -> bool {
	switch x in a {
	case nil:
		return b == nil
	case Artist_Top_Tracks:
		_, ok := b.(Artist_Top_Tracks)
		return ok
	case Artist_Grid:
		y, ok := b.(Artist_Grid)
		return ok && y.part == x.part
	}
	return false
}

// Bio_Layout is the biography broken into lines, kept with its page until
// the width, the font, the scale or the text changes. More and Less only
// change how many of them show.
Bio_Layout :: struct {
	lines:      [dynamic]Bio_Line, // on the heap
	valid:      bool,
	width:      f32,
	size:       f32,
	scale:      f32,
	font:       text.Font,
	generation: u64, // the text system's
	open:       bool, // More was pressed
}

Bio_Line :: struct {
	start, end: int, // bytes of the biography
}

bio_free :: proc(b: ^Bio_Layout) {
	delete(b.lines)
	b^ = {}
}

// artist_key is the page key of an artist place.
artist_key :: proc(s: ^State, p: ^Pending) -> i64 {
	if s.data.fake {
		return artist_fake_key(p.index)
	}
	id, _ := strconv.parse_i64(small_str(&p.id))
	return id
}

// artist_list_open says whether the open list is the top tracks of the
// artist of place p.
artist_list_open :: proc(s: ^State, p: ^Pending) -> bool {
	if s.data.fake {
		sr := &s.search
		return sr.fake_source == .Artist && p.index >= 0 && p.index < len(s.rows) && small_str(&sr.fake_title) == s.rows[p.index].artist
	}
	v := &s.data.view
	return s.search.browsing && v.source == .Artist && small_str(&v.id) == small_str(&p.id)
}

// artist_place is the artist place showing, or nil when the main view
// shows something else.
artist_place :: proc(s: ^State) -> ^Pending {
	h := &s.history
	if h.count == 0 {
		return nil
	}
	p := &h.places[h.at]
	if p.kind != .List || p.source != .Artist || !artist_list_open(s, p) {
		return nil
	}
	return p
}

// artist_view_place is the artist place p as view.
artist_view_place :: proc(p: Pending, view: Artist_View) -> Pending {
	p := p
	p.artist_view = view
	return p
}

artist_link :: proc(id: i64) -> string {
	return fmt.tprintf("https://tidal.com/browse/artist/%d", id)
}

// open_card opens an album, or an artist's page, once the frame is done.
// With the fake data a card's id is a row of that album or artist.
@(private = "file")
open_card :: proc(s: ^State, source: Source, f: Found) {
	if source == .Artist {
		open_artist(s, f.id, f.name, int(f.id))
	} else {
		open_album(s, f.id, f.name, f.image, int(f.id))
	}
}

// Drawing

// draw_artist draws the place p of the main view, main_w wide: the page or
// a grid. The full top tracks are the table, which draw_main_view draws.
draw_artist :: proc(s: ^State, p: ^Pending, main_w: f32) {
	page := artist_find(&s.data, artist_key(s, p))
	if page == nil {
		return
	}
	artist_want(&s.data, page)
	// After the page, whose More button opens it this frame.
	defer draw_artist_menu(s, p, page)
	content_w := min(main_w, CONTENT_MAX) - 2 * PAGE_PAD
	if grid, ok := p.artist_view.(Artist_Grid); ok {
		draw_artist_grid(s, page, grid.part, content_w)
		return
	}
	view := ui.scroll_view(fmt.tprintf("artist##%d", page.id), ui.fill(), ui.fill())
	ui.accessible(view, .Group, small_str(&page.name))
	draw_artist_hero(s, page, main_w, content_w)
	centred(content_w)
	draw_artist_actions(s, p, page)
	draw_top_tracks(s, p, view, content_w)
	for part in Artist_Part {
		spec := artist_part_spec(part)
		if spec.source == .None {
			continue
		}
		id := fmt.tprintf("shelf%d", int(part))
		switch state in page.parts[part] {
		case Artist_Ready:
			items := state.content.(Artist_Cards).items
			if len(items) == 0 {
				continue
			}
			sig := card_row(s, id, spec.title, items, spec.source, content_w)
			if sig.view_all {
				pending_set(s, artist_view_place(p^, Artist_Grid{part}))
			}
			if sig.clicked >= 0 {
				open_card(s, spec.source, items[sig.clicked])
			}
		case Artist_Failed:
			if part_failed(s, page, part, spec.title, id) {
				return
			}
		case Artist_Waiting, nil:
			shelf_placeholder(spec.title, content_w)
		}
	}
	ui.spacer(ui.px(48))
}

// part_failed says why a part didn't come, with a Retry. It returns true
// when Retry was pressed: the part is asked for again, and the message it
// showed is gone, so the caller builds no more of the page this frame.
@(private = "file")
part_failed :: proc(s: ^State, page: ^Artist_Page, part: Artist_Part, title, id: string) -> bool {
	failed := page.parts[part].(Artist_Failed)
	ui.parent(section_title(title))
	ui.text_style(.Regular, 13, DIM)
	message := strings.clone(small_str(&failed.message), context.temp_allocator)
	ui.label(fmt.tprintf("Couldn't load: %s", message) if message != "" else "Couldn't load", ui.text_size(), ui.fill())
	ui.spacer(ui.px(8))
	if text_button(fmt.tprintf("Retry###%s_retry", id), fmt.tprintf("Retry %s", title)).clicked {
		artist_retry(&s.data, page.id, part)
		ui.data_changed()
		return true
	}
	return false
}

// shelf_placeholder stands in for a shelf on its way: its title and grey
// squares where the covers go.
@(private = "file")
shelf_placeholder :: proc(title: string, width: f32) {
	section_title(title)
	ui.spacer(ui.px(8))
	ui.row("", {.Clip}, ui.fill(), ui.px(CARD_H))
	for _ in 0 ..< max(int((width + CARD_GAP) / CARD_PITCH), 1) {
		ui.column("", {}, ui.px(CARD_W), ui.fill())
		ui.spacer(ui.px(CARD_PAD))
		{
			ui.row("", {}, ui.fill(), ui.px(CARD_SIZE))
			ui.spacer(ui.px(CARD_PAD))
			b := ui.box_make("", {.Draw_Background}, ui.px(CARD_SIZE), ui.px(CARD_SIZE))
			b.background = SURFACE
			b.radius = 6
		}
		ui.spacer(ui.px(CARD_GAP))
	}
}

@(private = "file")
centred_end :: proc(_: ^ui.Box) {
	ui.pop_parent()
	ui.spacer(ui.fill())
	ui.pop_parent()
}

// centred is a column width wide in the middle of the parent, and the
// parent until the end of the scope.
@(deferred_out = centred_end)
centred :: proc(width: f32) -> ^ui.Box {
	r := ui.box_make("", {}, ui.fill(), ui.children_sum())
	r.child_axis = .X
	ui.push_parent(r)
	ui.spacer(ui.fill())
	c := ui.box_make("", {}, ui.px(width), ui.children_sum())
	c.child_axis = .Y
	ui.push_parent(c)
	return c
}

@(private = "file")
artist_bio :: proc(page: ^Artist_Page) -> string {
	ready, ok := page.parts[.Bio].(Artist_Ready)
	if !ok {
		return ""
	}
	return ready.content.(Artist_Bio).text
}

// artist_bio_lines is the page's biography broken into lines no wider than
// width, at spaces and line breaks, and inside a word wider than the line
// between grapheme clusters, from the page's Bio_Layout when it's still
// good.
artist_bio_lines :: proc(s: ^State, page: ^Artist_Page, width: f32) -> []Bio_Line {
	l := &page.bio
	generation := s.ui.texts.generation if s.ui.texts != nil else 0
	scale := s.renderer.scale
	if l.valid && l.width == width && l.font == BIO_FONT && l.size == BIO_SIZE && l.scale == scale && l.generation == generation {
		return l.lines[:]
	}
	if l.lines == nil {
		l.lines = make([dynamic]Bio_Line, 0, 16, runtime.heap_allocator())
	}
	clear(&l.lines)
	l.valid, l.width, l.font, l.size, l.scale, l.generation = true, width, BIO_FONT, BIO_SIZE, scale, generation
	s.measure.bio_wraps += 1
	bio := artist_bio(page)
	space := ui.text_width(BIO_FONT, BIO_SIZE, " ")
	rest := bio
	for paragraph in strings.split_lines_iterator(&rest) {
		p := strings.trim_space(paragraph)
		if p == "" {
			continue
		}
		base := int(uintptr(raw_data(p)) - uintptr(raw_data(bio)))
		start, end := 0, 0
		line_w: f32
		words := p
		at := 0
		for word in strings.split_iterator(&words, " ") {
			word_start, word_end := at, at + len(word)
			at = word_end + 1
			if word == "" {
				continue
			}
			w := ui.text_width(BIO_FONT, BIO_SIZE, word)
			if end > start && line_w + space + w <= width {
				line_w += space + w
				end = word_end
				continue
			}
			if end > start {
				append(&l.lines, Bio_Line{base + start, base + end})
			}
			start = word_start
			for w > width {
				cut := start + bio_fit(p[start:word_end], width)
				append(&l.lines, Bio_Line{base + start, base + cut})
				start = cut
				w = ui.text_width(BIO_FONT, BIO_SIZE, p[start:word_end])
			}
			end, line_w = word_end, w
		}
		if end > start {
			append(&l.lines, Bio_Line{base + start, base + end})
		}
	}
	return l.lines[:]
}

// bio_fit is how many bytes of word, in whole grapheme clusters, fit in
// width: at least one cluster, so a line always moves on.
@(private = "file")
bio_fit :: proc(word: string, width: f32) -> int {
	bounds := ui.cluster_bounds(word)
	lo, hi := 1, len(bounds) - 1 // bounds[lo] fits, bounds[hi + 1] doesn't
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if ui.text_width(BIO_FONT, BIO_SIZE, word[:bounds[mid]]) <= width {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return bounds[lo]
}

@(private = "file")
draw_artist_hero :: proc(s: ^State, page: ^Artist_Page, main_w, content_w: f32) {
	bio := artist_bio(page)
	lines := artist_bio_lines(s, page, min(content_w, BIO_W) - 2 * CARD_PAD - 48)
	shown := len(lines) if page.bio.open else min(len(lines), BIO_LINES)
	hero_h := HERO_H + f32(max(shown - BIO_LINES, 0)) * BIO_LINE_H
	ui.column("hero", {.Clip}, ui.fill(), ui.px(hero_h))
	hero_background(s, page, main_w, hero_h)
	ui.spacer(ui.fill())
	{
		centred(content_w)
		ui.row("", {}, ui.fill(), ui.px(56))
		ui.spacer(ui.px(CARD_PAD))
		ui.text_style(.Bold, 44, TEXT)
		name := ui.label(small_str(&page.name), ui.fill(), ui.fill())
		ui.accessible(name, .Static_Text, name.label)
	}
	ui.spacer(ui.px(6))
	{
		centred(content_w)
		for line, i in lines[:shown] {
			ui.row("", {}, ui.fill(), ui.px(BIO_LINE_H))
			ui.spacer(ui.px(CARD_PAD))
			ui.text_style(BIO_FONT, BIO_SIZE, mix(SECONDARY, TEXT, 0.4))
			last := i == shown - 1 && len(lines) > BIO_LINES
			t := bio[line.start:line.end]
			if last && !page.bio.open {
				t = fmt.tprintf("%s…", t)
			}
			ui.accessible(ui.label(t, ui.text_size(), ui.fill()), .Static_Text, t)
			if last {
				ui.spacer(ui.px(6))
				ui.text_style(.Semibold, 13, TEXT)
				more := ui.box_make("Less###bio_more" if page.bio.open else "More###bio_more", {.Clickable, .Focusable, .Draw_Text, .Draw_Hot_Underline}, ui.text_size(), ui.fill())
				ui.accessible(more, .Button, "Read less" if page.bio.open else "Read more")
				if ui.signal(more).clicked {
					page.bio.open = !page.bio.open
					ui.request_frame() // this frame's lines are the old count
				}
			}
		}
	}
	ui.spacer(ui.px(24))
}

// hero_background paints the header behind the name, w by h: the artist's
// picture across it, darkened so the name reads, fading to the window's
// background at the bottom. Without a picture, as with the fake data, a
// gradient from the name stands in.
@(private = "file")
hero_background :: proc(s: ^State, page: ^Artist_Page, w, h: f32) {
	layer :: proc(w, h: f32) -> ^ui.Box {
		return ui.box_make("", {.Floating_X, .Floating_Y, .Draw_Background}, ui.px(w), ui.px(h))
	}
	picture := small_str(&page.picture)
	if s.data.fake || picture == "" {
		hue := f32(hash.fnv32a(transmute([]u8)small_str(&page.name)) % 997) / 997
		wash := layer(w, h)
		wash.background = hsv(hue, 0.45, 0.45)
		wash.gradient = hsv(hue + 0.08, 0.6, 0.12)
	} else {
		base := layer(w, h)
		base.background = PANEL
		e := cover.want(&s.data.covers, .Artist, picture, HERO_PX, HERO_PX, s.frame_count, PRIORITY_COVER)
		if e != nil && e.state == .Ready {
			// The square picture's band as wide as the header, a little
			// above the middle, where faces tend to be.
			src := cover.src(&s.data.covers, e)
			band := min(src.h * h / max(w, 1), src.h)
			img := layer(w, h)
			img.texture = cover.texture(&s.data.covers, e)
			img.texture_src = {src.x, src.y + (src.h - band) * 0.35, src.w, band}
			img.opacity = cover.alpha(e, s.ui.time)
			if img.opacity < 1 {
				ui.request_frame()
			}
		}
		dim := layer(w, h)
		dim.background = {0, 0, 0, 0.45}
	}
	fade := layer(w, h * 0.6)
	fade.fixed_pos = {0, h * 0.4}
	fade.gradient = WINDOW_BG
}

// pill is a round-ended button with an icon and a label, light for the
// main action.
@(private = "file")
pill :: proc(id, icon, label: string, light, enabled: bool) -> ui.Signal {
	flags := ui.Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects}
	if !enabled {
		flags += {.Disabled}
	}
	b := ui.row(id, flags, ui.children_sum(), ui.px(40))
	b.radius = 20
	b.background = TEXT if light else SURFACE
	b.hover_color = SECONDARY if light else SURFACE_ACTIVE
	b.opacity = 1 if enabled else 0.5
	ui.accessible(b, .Button, label)
	fg := WINDOW_BG if light else TEXT
	ui.spacer(ui.px(18))
	ui.text_style(.Icon_Fill if light else .Icon, 16, fg)
	glyph := ui.label(icon, ui.px(18), ui.fill())
	glyph.text_align = .Center
	ui.spacer(ui.px(8))
	ui.text_style(.Semibold, 14, fg)
	ui.label(label, ui.text_size(), ui.fill())
	ui.spacer(ui.px(20))
	return ui.signal(b)
}

@(private = "file")
draw_artist_actions :: proc(s: ^State, p: ^Pending, page: ^Artist_Page) {
	playable := row_playable(s, 0)
	ui.spacer(ui.px(4))
	{
		ui.row("artist_actions", {}, ui.fill(), ui.px(44))
		ui.spacer(ui.px(CARD_PAD))
		{
			ui.column("", {}, ui.children_sum(), ui.fill())
			ui.spacer(ui.fill())
			if pill("artist_play", text.ICON_PLAY, "Play", true, playable).clicked {
				pending_set(s, {kind = .Play, order = .In_Order})
			}
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(10))
		{
			ui.column("", {}, ui.children_sum(), ui.fill())
			ui.spacer(ui.fill())
			if pill("artist_shuffle", text.ICON_SHUFFLE, "Shuffle", false, playable).clicked {
				pending_set(s, {kind = .Play, order = .Shuffled})
			}
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(10))
		if !s.data.fake {
			b, sig := icon_button("artist_share", text.ICON_SHARE_NETWORK, .Icon, "Share", TEXT, 1, 40, {.Focusable})
			b.radius = 20
			if sig.clicked {
				ui.copy_to_clipboard(artist_link(page.id))
				set_status(s, .Copied_Artist, -1)
			}
			ui.tooltip(sig, "Copy artist link")
			ui.spacer(ui.px(4))
		}
		more, more_sig := icon_button("artist_more", text.ICON_DOTS_THREE, .Icon, "More", TEXT, 1, 40, {.Focusable})
		more.radius = 20
		if more_sig.clicked {
			ui.open_menu("artist_menu", {more.rect.x, more.rect.y + more.rect.h})
		}
		ui.tooltip(more_sig, "More")
	}
	{
		ui.row("", {}, ui.fill(), ui.px(24))
		ui.spacer(ui.px(CARD_PAD))
		ui.text_style(.Regular, 12, DIM)
		status := ui.label(status_text(s), ui.fill(), ui.fill())
		ui.accessible(status, .Static_Text, status.label)
	}
}

@(private = "file")
draw_artist_menu :: proc(s: ^State, p: ^Pending, page: ^Artist_Page) {
	if ui.menu("artist_menu") {
		ui.text_style(.Regular, 13, TEXT)
		playable := row_playable(s, 0)
		if ui.menu_item("Play").clicked && playable {
			pending_set(s, {kind = .Play, order = .In_Order})
		}
		if ui.menu_item("Shuffle").clicked && playable {
			pending_set(s, {kind = .Play, order = .Shuffled})
		}
		if ui.menu_item("Show all top tracks").clicked {
			pending_set(s, artist_view_place(p^, Artist_Top_Tracks{}))
		}
		if !s.data.fake {
			ui.menu_separator()
			if ui.menu_item("Copy artist link").clicked {
				ui.copy_to_clipboard(artist_link(page.id))
				set_status(s, .Copied_Artist, -1)
			}
		}
	}
}

// draw_top_tracks is the first TOP_TRACKS rows of the open list, as the
// table draws them. view is the page's scroll view, which the keyboard's
// selection scrolls.
@(private = "file")
draw_top_tracks :: proc(s: ^State, p: ^Pending, view: ^ui.Box, width: f32) {
	n := view_count(s)
	{
		ui.parent(section_title("Top tracks"))
		if n > TOP_TRACKS && text_button("View all###top_all", "View all top tracks").clicked {
			pending_set(s, artist_view_place(p^, Artist_Top_Tracks{}))
		}
	}
	ui.spacer(ui.px(8))
	shown := min(n, TOP_TRACKS)
	if !s.data.fake && n == 0 && !s.data.view.done {
		shown = TOP_TRACKS // loading: the rows stand empty
	}
	cols := track_columns(width, false)
	// A keyed parent of its own, so the arrow keys find no other box to
	// move the focus to and reach table_keys.
	ui.column("top_tracks_group", {}, ui.fill(), ui.children_sum())
	list := ui.column("top_tracks", {.Focusable}, ui.fill(), ui.px(f32(shown) * TRACK_ROW_H))
	ui.accessible(list, .Table, "Top tracks")
	if table_keys(s, list, min(n, TOP_TRACKS)) {
		top := list.rect.y - view.rect.y + view.view_off.y
		sel := f32(s.library.selected)
		ui.scroll_to(view, top + sel * TRACK_ROW_H, top + (sel + 1) * TRACK_ROW_H)
	}
	for i in 0 ..< shown {
		track_row(s, i, cols)
	}
}

@(private = "file")
draw_artist_grid :: proc(s: ^State, page: ^Artist_Page, part: Artist_Part, content_w: f32) {
	spec := artist_part_spec(part)
	{
		centred(content_w)
		ui.spacer(ui.px(24))
		ui.row("", {}, ui.fill(), ui.px(44))
		_, back := icon_button("grid_back", text.ICON_CARET_LEFT, .Icon, "Back", TEXT, 1, 36, {.Focusable, .Draw_Background})
		back.box.radius = 18
		back.box.background = SURFACE
		back.box.hover_color = SURFACE_ACTIVE
		if back.clicked || ui.take_key(.Escape) {
			pending_set(s, {kind = .Back})
		}
		ui.spacer(ui.px(14))
		ui.column("", {}, ui.fill(), ui.fill())
		ui.text_style(.Regular, 12, SECONDARY)
		ui.label(small_str(&page.name), ui.fill(), ui.px(18))
		ui.text_style(.Bold, 20, TEXT)
		title := ui.label(spec.title, ui.fill(), ui.px(26))
		ui.accessible(title, .Static_Text, title.label)
	}
	ui.spacer(ui.px(16))
	ui.row("", {}, ui.fill(), ui.fill())
	ui.spacer(ui.fill())
	{
		ui.column("", {}, ui.px(content_w), ui.fill())
		#partial switch state in page.parts[part] {
		case Artist_Ready:
			items := state.content.(Artist_Cards).items
			if clicked := card_grid(s, fmt.tprintf("grid##%d_%d", page.id, int(part)), spec.title, items, spec.source, content_w); clicked >= 0 {
				open_card(s, spec.source, items[clicked])
			}
		case Artist_Failed:
			part_failed(s, page, part, spec.title, fmt.tprintf("grid%d", int(part)))
		}
	}
	ui.spacer(ui.fill())
}
