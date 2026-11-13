package app

// The track list's header, laid out like Spotify's album and playlist
// pages and drawn like the artist page. It scrolls with the rows, in the
// same scroll view: the hero (the cover, the kind of list, its title and a
// line about it), then Play, Shuffle and More, then the column headings.
// Once Play has scrolled under the top, a bar with the cover, the title and
// Play is pinned there, after Back and Forward, with a copy of the headings
// under it. Search results have their title as the hero and their tabs as
// the actions, which pin with the headings under a bar of their own. An
// album ends in a footer:
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
import "../text"
import "../ui"

HERO_PAD :: 24 // above and below the hero's cover, without Back and Forward above it
HERO_COVER_MIN :: 160
HERO_COVER_MAX :: 232
ACTIONS_H :: 72 // Play, Shuffle and More
COMPACT_H :: NAV_H // the pinned bar without Back and Forward over it; with them it's as tall as their room
COMPACT_COVER :: 40
COMPACT_PLAY :: 36 // the pinned bar's round Play button
TITLE_SIZE :: 32
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
	hero:        f32, // the cover, title and meta line
	nav:         f32, // the room above the cover for Back and Forward, or 0
	actions:     f32,
	bar:         f32, // the pinned bar; 0 for none
	pin_actions: bool, // the actions pin with the headings: the search results' tabs
}

// list_header is the header's parts for a main view main_w wide, with nav
// kept above the cover for Back and Forward (nav_reserve). They run under
// the titlebar's strip, which only takes the presses that miss their
// controls (ui.cut_drag_regions).
list_header :: proc(kind: List_Kind, main_w, nav: f32) -> List_Header {
	if kind == .Search {
		return search_list_header(nav)
	}
	side := clamp(main_w * 0.2, HERO_COVER_MIN, HERO_COVER_MAX)
	return {hero = hero_top(nav) + side + HERO_PAD, nav = nav, actions = ACTIONS_H, bar = nav if nav > 0 else COMPACT_H}
}

// search_list_header is the search results' header: their title and what
// was found under the room for Back, Forward and the search field, then the
// tabs. The bar pinned in that room is only a background, since the field
// is there; the tabs pin under it with the headings.
search_list_header :: proc(nav: f32) -> List_Header {
	return {hero = nav + SEARCH_HEADER_H, nav = nav, actions = SEARCH_TABS_H, bar = nav, pin_actions = true}
}

// hero_top is the room above the hero's cover.
hero_top :: proc(nav: f32) -> f32 {
	return max(nav + HERO_PAD / 2, HERO_PAD)
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
// headings, and the tabs with them, cover once the header has collapsed.
header_pinned_h :: proc(h: List_Header) -> f32 {
	return h.bar + (h.actions if h.pin_actions else 0) + HEADER_H + 1
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
// they reach it. The search results' tabs pin, with the headings, when
// they reach it, and their bar has no content.
header_collapse :: proc(h: List_Header, offset: f32) -> (c: Header_Collapse) {
	c.pinned = offset > (h.hero if h.pin_actions else header_table_y(h)) - h.bar
	if h.bar <= 0 {
		return
	}
	c.bar = clamp((offset - (h.hero - h.bar - BAR_FADE)) / BAR_FADE, 0, 1)
	if h.pin_actions {
		return
	}
	c.content = clamp((offset - (header_table_y(h) - h.bar - BAR_CONTENT_FADE)) / BAR_CONTENT_FADE, 0, 1)
	return
}

// list_duration is a list's length as Spotify writes it: "51 min 2 sec",
// or "3 hr 20 min" from an hour.
list_duration :: proc(seconds: int) -> string {
	t := max(seconds, 0)
	if t >= 3600 {
		return cat(num(t / 3600), " hr ", num(t / 60 % 60), " min")
	}
	return cat(num(t / 60), " min ", num(t % 60), " sec")
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
		a.side = h.hero - hero_top(h.nav) - HERO_PAD
	}
	return
}

LIST_KIND_NAMES := [List_Kind]string {
	.Playlist = "PLAYLIST",
	.Album    = "ALBUM",
	.Artist   = "TOP TRACKS",
	.Search   = "",
}

// draw_list_hero is the hero, width wide less the scrollbar's gutter.
// artist is the album's artist's page, for the album's year.
draw_list_hero :: proc(s: ^State, h: List_Header, kind: List_Kind, art: Hero_Art, artist: ^Artist_Page) {
	ui.column("hero", {}, ui.fill(), ui.px(h.hero))
	ui.spacer(ui.px(hero_top(h.nav)))
	ui.row("", {}, ui.fill(), ui.px(art.side))
	ui.spacer(ui.px(LIST_PAD + 8))
	{
		ui.set_next_radius(art.side / 2 if art.kind == .Artist else 4)
		frame := ui.box_make("", {.Draw_Shadow}, ui.px(art.side), ui.px(art.side))
		ui.parent(frame)
		cover_art(s, art.kind, art.id, art.seed, art.side, ui.fill(), frame.radius, HERO_COVER_MAX)
	}
	ui.spacer(ui.px(24))
	ui.column("", {}, ui.fill(), ui.fill())
	ui.spacer(ui.fill())
	ui.text_style(.Semibold, 11, DIM)
	ui.label(LIST_KIND_NAMES[kind], ui.fill(), ui.px(18))
	ui.spacer(ui.px(4))
	title := view_title(s)
	ui.text_style(.Bold, TITLE_SIZE, TEXT)
	t := ui.label(title, ui.fill(), ui.px(TITLE_SIZE * 1.25))
	ui.accessible(t, .Static_Text, title)
	ui.spacer(ui.px(10))
	draw_list_meta(s, kind, artist)
	ui.spacer(ui.fill())
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
			ui.label(cat(sep, num(year)), ui.text_size(), ui.fill())
			sep = " • "
		}
	}
	ui.text_style(.Regular, 13, color)
	songs := list_songs(s, kind)
	ui.accessible(ui.label(cat(sep, songs), ui.fill(), ui.fill()), .Static_Text, songs)
}

// list_songs is how many songs the open list has and how long they play
// for, or how far it has loaded. The rows are summed again only when the
// list changes, not on every frame the header is drawn.
list_songs :: proc(s: ^State, kind: List_Kind) -> string {
	if !s.data.fake {
		v := &s.data.view
		if v.source == .None {
			return view_subtitle(s)
		}
		if view_loading(v) {
			return cat("Loading, ", songs(v.loaded_rows), " so far")
		}
	}
	n := view_count(s)
	v := &s.data.view
	total := &s.library.songs
	key := [4]u64{list_gen(s), u64(n), u64(v.loaded_rows), u64(v.moved)}
	if key != total.key {
		total^ = {key = key}
		for i in 0 ..< n {
			if row := view_row(s, i); row != nil {
				total.seconds += row.seconds
			}
		}
	}
	return cat(songs(n), ", ", list_duration(total.seconds))
}

MONTH_NAMES := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

// release_date is a release's year, and its date as "June 12, 2026".
release_date :: proc(unix: i64) -> (year: int, date: string) {
	y, m, d := time.date(time.unix(unix, 0))
	return y, fmt.tprintf("%s %d, %d", MONTH_NAMES[int(m) - 1], d, y)
}

// draw_list_actions is Play, Shuffle and More, as pills like the artist
// page's.
draw_list_actions :: proc(s: ^State, kind: List_Kind, h: List_Header) {
	ui.row("list_actions", {}, ui.fill(), ui.px(h.actions))
	title := view_title(s)
	ui.spacer(ui.px(LIST_PAD + 8))
	{
		ui.column("", {}, ui.children_sum(), ui.fill())
		ui.spacer(ui.fill())
		ours, playing, enabled := list_play_state(s)
		label := "Pause" if playing else "Play"
		icon := text.ICON_PAUSE if playing else text.ICON_PLAY
		if pill("list_play", icon, label, true, enabled, cat(label, " ", title)).clicked {
			list_play(s, ours)
		}
		ui.spacer(ui.fill())
	}
	ui.spacer(ui.px(12))
	{
		ui.column("", {}, ui.children_sum(), ui.fill())
		ui.spacer(ui.fill())
		if pill("list_shuffle", text.ICON_SHUFFLE, "Shuffle", false, row_playable(s, 0), cat("Shuffle ", title)).clicked {
			pending_set(s, Play_Row{order = .Shuffled})
		}
		ui.spacer(ui.fill())
	}
	ui.spacer(ui.px(8))
	ui.radius(20)
	more, more_sig := icon_button("list_more", text.ICON_DOTS_THREE, .Icon, cat("More options for ", title), TEXT, 1, 40, {.Focusable})
	if more_sig.clicked {
		ui.open_menu("list_menu", {more.rect.x, more.rect.y + more.rect.h})
	}
	ui.tooltip(more_sig, "More")
}

// list_play_state is whether a song of the open list is what's playing,
// whether it's playing now, and whether Play can do anything.
list_play_state :: proc(s: ^State) -> (ours, playing, enabled: bool) {
	ours = s.library.playing >= 0
	playing = ours && playback_playing(s)
	enabled = ours || row_playable(s, 0)
	return
}

// list_play plays the open list from the top, or pauses or resumes it
// while one of its songs is playing.
list_play :: proc(s: ^State, ours: bool) {
	if ours {
		playback_toggle(s)
		ui.data_changed()
	} else {
		pending_set(s, Play_Row{order = .In_Order})
	}
}

// list_play_button is the pinned bar's round Play button, side across.
list_play_button :: proc(s: ^State, id: string, side: f32) {
	ours, playing, enabled := list_play_state(s)
	ui.column("", {}, ui.px(side), ui.fill())
	ui.spacer(ui.fill())
	flags := ui.Box_Flags{.Clickable, .Focusable, .Draw_Background, .Draw_Text, .Draw_Hot_Effects, .Draw_Active_Effects}
	if !enabled {
		flags += {.Disabled}
	}
	icon := text.ICON_PAUSE if playing else text.ICON_PLAY
	ui.set_next_font(.Icon_Fill)
	ui.set_next_font_size(math.round(side * 0.4))
	ui.set_next_text_color(WINDOW_BG)
	ui.set_next_text_align(.Center)
	ui.set_next_background(TEXT)
	ui.set_next_radius(side / 2)
	ui.set_next_hover_color(SECONDARY)
	ui.set_next_active_color({0, 0, 0, 0.15})
	b := ui.box_make(id, flags, ui.px(side), ui.px(side))
	b.label = icon
	b.opacity = 1 if enabled else 0.5
	ui.accessible(b, .Button, cat("Pause " if playing else "Play ", view_title(s)))
	ui.spacer(ui.fill())
	sig := ui.signal(b)
	if sig.clicked {
		list_play(s, ours)
	}
	ui.tooltip(sig, "Pause" if playing else "Play")
}

// draw_list_menu is the More button's menu: Play and Shuffle, an album's
// artist, and the list's link.
draw_list_menu :: proc(s: ^State, kind: List_Kind) {
	if ui.menu("list_menu") {
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
// which is the parent, once the header has scrolled under, and the search
// results' tabs with them. The found albums, artists and playlists have no
// headings. It's built after the rows, so it's drawn over them and takes
// the clicks there.
draw_pinned_header :: proc(s: ^State, list: ^ui.Box, h: List_Header, cols: Track_Columns, art: Hero_Art, headings := true) {
	c := header_collapse(h, list.view_off.y)
	nav_float(s, list.view_off.y, c.bar)
	if c.bar <= 0 && !c.pinned {
		return
	}
	flags := ui.Box_Flags{.Floating_X, .Floating_Y}
	// Half faded in it doesn't hide the header under it, so it lets
	// clicks through to it.
	if c.bar >= 1 || c.pinned {
		flags += {.Clickable, .Click_Shield}
	}
	pin := ui.column("pinned", flags, ui.fill(), ui.children_sum())
	pin.fixed_pos = {0, ui.view_offset(list).y}
	if h.bar > 0 {
		ui.set_next_background({PANEL.r, PANEL.g, PANEL.b, c.bar})
		ui.column("", {.Draw_Background}, ui.fill(), ui.px(h.bar))
		if c.content > 0 {
			row := ui.row("", {}, ui.fill(), ui.fill())
			row.opacity = c.content
			ui.spacer(ui.px(NAV_PAD + NAV_W + 12 if h.nav > 0 else LIST_PAD + 8))
			radius: f32 = COMPACT_COVER / 2 if art.kind == .Artist else 4
			cover_art(s, art.kind, art.id, art.seed, COMPACT_COVER, ui.px(COMPACT_COVER), radius)
			ui.spacer(ui.px(12))
			ui.text_style(.Semibold, 16, TEXT)
			ui.label(view_title(s), ui.fill(), ui.fill())
			ui.spacer(ui.px(12))
			list_play_button(s, "pinned_play", COMPACT_PLAY)
			// Clear of the window's buttons, at the top with Back and Forward.
			ui.spacer(ui.px(LIST_PAD + 8 + (window_buttons_w(s) if h.nav > 0 else 0)))
		}
	}
	if c.pinned {
		ui.set_next_background(PANEL)
		ui.column("", {.Draw_Background}, ui.fill(), ui.children_sum())
		if h.pin_actions {
			draw_search_tabs(s)
		}
		if headings {
			table_header(cols, pinned = true)
		}
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
// artist. Out of view it's a spacer of its height. list is the view,
// view_h tall.
draw_album_footer :: proc(s: ^State, list: ^ui.Box, view_h: f32, artist: ^Artist_Page, top, width: f32) {
	found := album_found(s, artist)
	items := more_by(s, artist, found)
	height := f32(FOOTER_TEXT_H + FOOTER_END) + (FOOTER_SHELF_H if len(items) > 0 else 0)
	if list.view_off.y + view_h < top {
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
