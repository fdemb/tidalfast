package app

// The track list's header, after Spotify's album and playlist pages. It
// scrolls with the rows, in the same scroll view: the hero (the cover, the
// kind of list, its title and a line about it) over a wash of the cover's
// tint, then Play, Shuffle and More, then the column headings. Once Play
// has scrolled under the top, a bar with Play and the title is pinned
// there, with a copy of the headings under it. An album ends in a footer:
// its release date, its length and more by its artist.
//
// Every part has a fixed height (List_Header), so a frame knows where row 0
// is before it builds anything, and how far the header has collapsed comes
// from the scroll offset alone (header_collapse). Nothing animates on its
// own, so a still window draws nothing.

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strconv"
import "core:time"

import "../cover"
import "../render"
import "../text"
import "../ui"

HERO_PAD :: 24 // above and below the hero's cover
HERO_COVER_MIN :: 160
HERO_COVER_MAX :: 232
ACTIONS_H :: 88 // Play, Shuffle and More
LIST_PLAY :: 56 // the round Play button
COMPACT_H :: 64 // the pinned bar, under the titlebar
COMPACT_PLAY :: 44
TITLE_MAX :: 72
TITLE_MIN :: 28
// Points of scrolling over which the pinned bar's background, then its
// Play button and title, fade in.
BAR_FADE :: 48
BAR_CONTENT_FADE :: 24
FOOTER_TEXT_H :: 24 + 20 + 18 // a gap, the release date, the length
FOOTER_SHELF_H :: 32 + 36 + 8 + CARD_H // see section_title and card_row
FOOTER_END :: 48

// List_Header is where the parts of the header sit in the scroll view's
// content, from the top.
List_Header :: struct {
	under:   f32, // the titlebar over the hero's top
	hero:    f32, // the cover, title and meta line, under included; 0 for search results
	actions: f32,
	bar:     f32, // the pinned bar, under included; 0 for none
}

list_header :: proc(kind: List_Kind, main_w, under: f32) -> List_Header {
	if kind == .Search {
		return {}
	}
	side := clamp(main_w * 0.2, HERO_COVER_MIN, HERO_COVER_MAX)
	return {under = under, hero = under + side + 2 * HERO_PAD, actions = ACTIONS_H, bar = under + COMPACT_H}
}

// header_table_y is where the column headings are.
header_table_y :: proc(h: List_Header) -> f32 {
	return h.hero + h.actions
}

// header_rows_top is where row 0 is: under the headings, their line and
// the rows' padding.
header_rows_top :: proc(h: List_Header) -> f32 {
	return header_table_y(h) + HEADER_H + 1 + LIST_PAD_Y
}

// header_pinned_h is how much of the view's top the pinned bar and
// headings cover once the header has collapsed.
header_pinned_h :: proc(h: List_Header) -> f32 {
	return h.bar + HEADER_H + 1
}

// Header_Collapse is the header scrolled down by an offset: how far the
// pinned bar's background and then its Play button and title have faded
// in, and whether the headings are pinned under it.
Header_Collapse :: struct {
	bar, content: f32,
	pinned:       bool,
}

// header_collapse: the bar's background fades in as the hero's bottom
// reaches it, its content as Play goes under it, and the headings pin when
// they reach it. Without a bar, as for search results, the headings pin as
// soon as the view scrolls.
header_collapse :: proc(h: List_Header, offset: f32) -> (c: Header_Collapse) {
	c.pinned = offset > header_table_y(h) - h.bar
	if h.bar <= 0 {
		return
	}
	c.bar = clamp((offset - (h.hero - h.bar - BAR_FADE)) / BAR_FADE, 0, 1)
	c.content = clamp((offset - (header_table_y(h) - h.bar - BAR_CONTENT_FADE)) / BAR_CONTENT_FADE, 0, 1)
	return
}

// title_size is the hero title's font size: TITLE_MAX, or smaller so it
// fits width when it's wide at TITLE_MAX, in steps of 4 so resizing the
// window shapes it at few sizes, and no smaller than TITLE_MIN, below which
// its end is cut off.
title_size :: proc(wide, width: f32) -> f32 {
	if wide <= width || wide <= 0 {
		return TITLE_MAX
	}
	return clamp(math.floor(TITLE_MAX * width / wide / 4) * 4, TITLE_MIN, TITLE_MAX)
}

// list_duration is a list's length as Spotify writes it: "51 min 2 sec",
// or "3 hr 20 min" from an hour.
list_duration :: proc(seconds: int) -> string {
	t := max(seconds, 0)
	if t >= 3600 {
		return fmt.tprintf("%d hr %d min", t / 3600, t / 60 % 60)
	}
	return fmt.tprintf("%d min %d sec", t / 60, t % 60)
}

// Hero_Art is the hero's cover: an image id, or "" for the gradient from
// seed that stands in, as the sidebar's and the fake data's do.
Hero_Art :: struct {
	kind: cover.Kind,
	id:   string,
	seed: u32,
	side: f32, // points across; 0 without a hero
}

hero_art :: proc(s: ^State, kind: List_Kind, h: List_Header) -> (a: Hero_Art) {
	a.kind = .Artist if kind == .Artist else (.Album if kind == .Album else .Playlist)
	if k, id, show := view_cover(s); show {
		a.kind, a.id = k, id
	}
	// A sidebar entry's gradient is the one the sidebar shows.
	sidebar := s.search.fake_source == .None if s.data.fake else !s.search.browsing
	a.seed = u32(s.library.playlist) * 7919 + 13 if sidebar else hash.fnv32a(transmute([]u8)view_title(s))
	if h.hero > 0 {
		a.side = h.hero - h.under - 2 * HERO_PAD
	}
	return
}

// header_tint is the colour the header is washed with: the cover's tint
// once the cover has come, fading in with it, and before that or without
// one a colour of the stand-in gradient's hue.
header_tint :: proc(s: ^State, a: Hero_Art) -> render.Color {
	hue := f32(a.seed % 997) / 997
	c := hsv(hue, 0.5, 0.4)
	if a.side <= 0 {
		return c
	}
	e := cover_want(s, a.kind, a.id, a.side, PRIORITY_COVER)
	if e == nil || e.state != .Ready {
		return c
	}
	t := cover.alpha(e, s.ui.time)
	if t < 1 {
		ui.request_frame()
	}
	return mix(c, {f32(e.tint.r) / 255, f32(e.tint.g) / 255, f32(e.tint.b) / 255, 1}, t)
}

LIST_KIND_NAMES := [List_Kind]string {
	.Playlist = "Playlist",
	.Album    = "Album",
	.Artist   = "Top tracks",
	.Search   = "",
}

// draw_list_hero is the hero, width wide less the scrollbar's gutter.
// artist is the album's artist's page, for the album's year.
draw_list_hero :: proc(s: ^State, h: List_Header, kind: List_Kind, art: Hero_Art, tint: render.Color, width: f32, artist: ^Artist_Page) {
	hero := ui.column("hero", {.Draw_Background}, ui.fill(), ui.px(h.hero))
	hero.background = tint
	hero.gradient = mix(tint, WINDOW_BG, 0.45)
	ui.spacer(ui.px(h.under + HERO_PAD))
	ui.row("", {}, ui.fill(), ui.px(art.side))
	ui.spacer(ui.px(LIST_PAD + 8))
	{
		frame := ui.box_make("", {.Draw_Shadow}, ui.px(art.side), ui.px(art.side))
		frame.radius = art.side / 2 if art.kind == .Artist else 6
		ui.parent(frame)
		cover_art(s, art.kind, art.id, art.seed, art.side, ui.fill(), frame.radius)
	}
	ui.spacer(ui.px(24))
	ui.column("", {}, ui.fill(), ui.fill())
	ui.spacer(ui.fill())
	ui.text_style(.Medium, 13, TEXT)
	ui.label(LIST_KIND_NAMES[kind], ui.fill(), ui.px(20))
	title := view_title(s)
	room := width - (LIST_PAD + 8) - art.side - 24 - LIST_PAD
	size := title_size(ui.text_width(.Bold, TITLE_MAX, title), room)
	ui.text_style(.Bold, size, TEXT)
	t := ui.label(title, ui.fill(), ui.px(math.ceil(size * 1.25)))
	ui.accessible(t, .Static_Text, title)
	ui.spacer(ui.px(8))
	draw_list_meta(s, kind, artist)
	ui.spacer(ui.px(4))
}

// draw_list_meta is the line under the hero's title: for an album its
// artist, as a link, and its year, then for every list how many songs and
// how long.
draw_list_meta :: proc(s: ^State, kind: List_Kind, artist: ^Artist_Page) {
	ui.row("hero_meta", {}, ui.fill(), ui.px(20))
	color := mix(SECONDARY, TEXT, 0.6)
	sep := ""
	if kind == .Album {
		if row := view_row(s, 0); row != nil {
			// The album's artist is its first song's first artist.
			refs := row.artists[:min(len(row.artists), 1)]
			name := artist_name(row.artist, refs[0]) if len(refs) > 0 else row.artist
			ui.text_style(.Semibold, 13, TEXT)
			{
				ui.row("", {}, ui.px(ui.text_width(.Semibold, 13, name) + 1), ui.fill())
				if k, sig := artist_links(s, row.artist, refs, 0, ui.fill()); sig.clicked {
					open_artist_of(s, row.artist, row.artists, k, fake_row_index(s, 0))
				}
			}
			sep = " • "
		}
		if f := album_found(s, artist); f != nil && f.released != 0 {
			year, _ := release_date(f.released)
			ui.text_style(.Regular, 13, color)
			ui.label(fmt.tprintf("%s%d", sep, year), ui.text_size(), ui.fill())
			sep = " • "
		}
	}
	ui.text_style(.Regular, 13, color)
	songs := list_songs(s, kind)
	ui.accessible(ui.label(fmt.tprintf("%s%s", sep, songs), ui.fill(), ui.fill()), .Static_Text, songs)
}

// list_songs is how many songs the open list has and how long they play
// for, or how far it has loaded.
list_songs :: proc(s: ^State, kind: List_Kind) -> string {
	if !s.data.fake {
		v := &s.data.view
		if v.source == .None {
			return view_subtitle(s)
		}
		if !v.done {
			return fmt.tprintf("Loading, %d songs so far", v.loaded_rows)
		}
	}
	n := view_count(s)
	total := 0
	for i in 0 ..< n {
		if row := view_row(s, i); row != nil {
			total += row.seconds
		}
	}
	songs := "1 song" if n == 1 else fmt.tprintf("%d songs", n)
	return fmt.tprintf("%s, %s", songs, list_duration(total))
}

MONTH_NAMES := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

// release_date is a release's year, and its date as "June 12, 2026".
release_date :: proc(unix: i64) -> (year: int, date: string) {
	y, m, d := time.date(time.unix(unix, 0))
	return y, fmt.tprintf("%s %d, %d", MONTH_NAMES[int(m) - 1], d, y)
}

// draw_list_actions is Play, Shuffle and More, over the end of the
// header's wash, with the status line after them.
draw_list_actions :: proc(s: ^State, kind: List_Kind, h: List_Header, tint: render.Color) {
	row := ui.row("list_actions", {.Draw_Background}, ui.fill(), ui.px(h.actions))
	row.background = mix(tint, WINDOW_BG, 0.7)
	row.gradient = WINDOW_BG
	title := view_title(s)
	ui.spacer(ui.px(LIST_PAD + 8))
	list_play_button(s, "list_play", LIST_PLAY)
	ui.spacer(ui.px(20))
	shuffle, shuffle_sig := icon_button("list_shuffle", text.ICON_SHUFFLE, .Icon, fmt.tprintf("Shuffle %s", title), TEXT, 1, 44, {.Focusable})
	shuffle.font_size = 26
	shuffle.radius = 22
	shuffle.text_color = mix(SECONDARY, TEXT, shuffle.hot_t)
	if shuffle_sig.clicked {
		pending_set(s, Play_Row{order = .Shuffled})
	}
	ui.tooltip(shuffle_sig, "Shuffle")
	ui.spacer(ui.px(8))
	more, more_sig := icon_button("list_more", text.ICON_DOTS_THREE, .Icon, fmt.tprintf("More options for %s", title), TEXT, 1, 44, {.Focusable})
	more.font_size = 26
	more.radius = 22
	more.text_color = mix(SECONDARY, TEXT, more.hot_t)
	if more_sig.clicked {
		ui.open_menu("list_menu", {more.rect.x, more.rect.y + more.rect.h})
	}
	ui.tooltip(more_sig, "More")
	ui.spacer(ui.px(16))
	ui.text_style(.Regular, 12, DIM)
	status := ui.label(status_text(s), ui.fill(), ui.fill())
	ui.accessible(status, .Static_Text, status.label)
	ui.spacer(ui.px(LIST_PAD))
}

// list_play_button is the round Play button, side across: Play from the
// first song, or Pause and Play while a song of this list is playing.
list_play_button :: proc(s: ^State, id: string, side: f32) {
	lib := &s.library
	ours := lib.playing >= 0
	playing := ours && playback_playing(s)
	enabled := ours || row_playable(s, 0)
	ui.column("", {}, ui.px(side), ui.fill())
	ui.spacer(ui.fill())
	flags := ui.Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}
	if !enabled {
		flags += {.Disabled}
	}
	icon := text.ICON_PAUSE if playing else text.ICON_PLAY
	b := ui.box_make(fmt.tprintf("%s###%s", icon, id), flags, ui.px(side), ui.px(side))
	b.font = .Icon_Fill
	b.font_size = math.round(side * 0.4)
	b.text_color = WINDOW_BG
	b.text_align = .Center
	b.background = ACCENT
	b.radius = side / 2
	b.hover_color = {1, 1, 1, 0.3}
	b.active_color = {0, 0, 0, 0.15}
	b.opacity = 1 if enabled else 0.5
	ui.accessible(b, .Button, fmt.tprintf("%s %s", "Pause" if playing else "Play", view_title(s)))
	ui.spacer(ui.fill())
	sig := ui.signal(b)
	if sig.clicked {
		if ours {
			playback_toggle(s)
			ui.data_changed()
		} else {
			pending_set(s, Play_Row{order = .In_Order})
		}
	}
	ui.tooltip(sig, "Pause" if playing else "Play")
}

// draw_list_menu is the More button's menu: Play and Shuffle, an album's
// artist, and the list's link.
draw_list_menu :: proc(s: ^State, kind: List_Kind) {
	if !ui.menu("list_menu") {
		return
	}
	ui.text_style(.Regular, 13, TEXT)
	if ui.menu_item("Play").clicked {
		pending_set(s, Play_Row{order = .In_Order})
	}
	if ui.menu_item("Shuffle").clicked {
		pending_set(s, Play_Row{order = .Shuffled})
	}
	row := view_row(s, 0)
	if kind == .Album && row != nil && (s.data.fake || first_artist(row.artists) != 0) {
		ui.menu_separator()
		if ui.menu_item("Go to artist").clicked {
			open_artist_of(s, row.artist, row.artists, 0, fake_row_index(s, 0))
		}
	}
	if link, name := list_link(s); link != "" {
		ui.menu_separator()
		if ui.menu_item(name).clicked {
			ui.copy_to_clipboard(link)
			set_status(s, .Copied_Page, -1)
		}
	}
}

// list_link is the open list's address on tidal.com and the menu item that
// copies it, or "" for one without, such as Liked Songs.
list_link :: proc(s: ^State) -> (link, name: string) {
	v := &s.data.view
	if s.data.fake || v.id.len == 0 {
		return
	}
	id := small_str(&v.id)
	#partial switch v.source {
	case .Album:
		return fmt.tprintf("https://tidal.com/browse/album/%s", id), "Copy album link"
	case .Playlist:
		return fmt.tprintf("https://tidal.com/browse/playlist/%s", id), "Copy playlist link"
	case .Artist:
		return fmt.tprintf("https://tidal.com/browse/artist/%s", id), "Copy artist link"
	}
	return
}

// draw_pinned_header pins the bar and the headings to the top of list,
// which is the parent, once the header has scrolled under. It's built
// after the rows, so it's drawn over them and takes the clicks there.
draw_pinned_header :: proc(s: ^State, list: ^ui.Box, h: List_Header, cols: Track_Columns, tint: render.Color) {
	c := header_collapse(h, list.view_off.y)
	if c.bar <= 0 && !c.pinned {
		return
	}
	flags := ui.Box_Flags{.Floating_X, .Floating_Y}
	// Half faded in it doesn't hide the header under it, so it lets
	// clicks through to it.
	if c.bar >= 1 || c.pinned {
		flags += {.Clickable}
	}
	pin := ui.column("pinned", flags, ui.fill(), ui.children_sum())
	pin.fixed_pos = {0, list.view_off.y}
	if h.bar > 0 {
		bar := ui.column("", {.Draw_Background}, ui.fill(), ui.px(h.bar))
		bar.background = mix(tint, WINDOW_BG, 0.3)
		bar.background.a = c.bar
		ui.spacer(ui.px(h.under))
		if c.content > 0 {
			row := ui.row("", {}, ui.fill(), ui.px(COMPACT_H))
			row.opacity = c.content
			ui.spacer(ui.px(LIST_PAD + 8))
			list_play_button(s, "pinned_play", COMPACT_PLAY)
			ui.spacer(ui.px(14))
			ui.text_style(.Bold, 24, TEXT)
			ui.label(view_title(s), ui.fill(), ui.fill())
			// The status line, whose place in the actions is scrolled away.
			ui.text_style(.Regular, 12, DIM)
			ui.label(status_text(s), ui.text_size(16), ui.fill())
			ui.spacer(ui.px(LIST_PAD))
		}
	}
	if c.pinned {
		headings := ui.column("", {.Draw_Background}, ui.fill(), ui.children_sum())
		headings.background = PANEL
		table_header(cols)
	}
}

// album_artist_page is the cached page of the open album's artist, the
// first artist of its first song, cached first if it isn't and asked for
// its albums, EPs and singles. Nil until the first song has loaded.
album_artist_page :: proc(s: ^State) -> ^Artist_Page {
	row := view_row(s, 0)
	if row == nil {
		return nil
	}
	key, name := artist_fake_key(fake_row_index(s, 0)), row.artist
	if !s.data.fake {
		if len(row.artists) == 0 {
			return nil
		}
		key, name = row.artists[0].id, artist_name(row.artist, row.artists[0])
	}
	page := artist_find(&s.data, key)
	if page == nil {
		page = artist_visit(s, key, small(name), {})
	}
	artist_want(&s.data, page, {.Albums, .Singles})
	return page
}

// album_found is the open album among its artist's albums, EPs and
// singles, or nil. The fake data's go by name.
album_found :: proc(s: ^State, page: ^Artist_Page) -> ^Found {
	if page == nil {
		return nil
	}
	id, _ := strconv.parse_i64(small_str(&s.data.view.id))
	title := view_title(s)
	for part in ([2]Artist_Part{.Albums, .Singles}) {
		ready, ok := page.parts[part].(Artist_Ready)
		if !ok {
			continue
		}
		for &f in ready.content.(Artist_Cards).items {
			if (s.data.fake && f.name == title) || (!s.data.fake && f.id == id) {
				return &f
			}
		}
	}
	return nil
}

// more_by is the artist's albums but the open one, in the frame's memory.
@(private = "file")
more_by :: proc(s: ^State, page: ^Artist_Page, open: ^Found) -> []Found {
	if page == nil {
		return nil
	}
	ready, ok := page.parts[.Albums].(Artist_Ready)
	if !ok {
		return nil
	}
	items := ready.content.(Artist_Cards).items
	out := make([dynamic]Found, 0, len(items), context.temp_allocator)
	for &f in items {
		if &f != open {
			append(&out, f)
		}
	}
	return out[:]
}

// draw_album_footer is what comes after an album's last row, at top in the
// view's content: its release date and length, then a shelf of more by its
// artist. Out of view it's a spacer of its height.
draw_album_footer :: proc(s: ^State, list: ^ui.Box, artist: ^Artist_Page, top, width: f32) {
	found := album_found(s, artist)
	items := more_by(s, artist, found)
	height := f32(FOOTER_TEXT_H + FOOTER_END) + (FOOTER_SHELF_H if len(items) > 0 else 0)
	if list.view_off.y + list.rect.h < top {
		ui.spacer(ui.px(height))
		return
	}
	foot := ui.column("album_footer", {}, ui.fill(), ui.px(height))
	foot.pad.x = LIST_PAD
	ui.spacer(ui.px(24))
	{
		ui.row("", {}, ui.fill(), ui.px(20))
		ui.spacer(ui.px(CARD_PAD))
		if found != nil && found.released != 0 {
			_, date := release_date(found.released)
			ui.text_style(.Regular, 13, SECONDARY)
			ui.accessible(ui.label(date, ui.fill(), ui.fill()), .Static_Text, date)
		}
	}
	{
		ui.row("", {}, ui.fill(), ui.px(18))
		ui.spacer(ui.px(CARD_PAD))
		ui.text_style(.Regular, 12, DIM)
		ui.label(list_songs(s, .Album), ui.fill(), ui.fill())
	}
	if len(items) == 0 {
		return
	}
	name := small_str(&artist.name)
	sig := card_row(s, "more_by", fmt.tprintf("More by %s", name), items, .Album, width - 2 * LIST_PAD)
	if sig.clicked >= 0 {
		f := items[sig.clicked]
		open_album(s, f.id, f.name, f.image, int(f.id))
	}
	if sig.view_all {
		p := List_Place{source = .Artist, name = artist.name, artist_view = Artist_Grid{.Albums}}
		if s.data.fake {
			p.index = fake_row_index(s, 0)
		} else {
			p.id = small(fmt.tprint(artist.id))
		}
		pending_set(s, p)
	}
}
