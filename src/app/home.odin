package app

// The Home page, after TIDAL's and Spotify's: a greeting, the sidebar's
// first playlists as shortcut tiles, then shelves of albums, playlists and
// artists from TIDAL's home feed.
//
// The feed is one Home job: tidal.home's v2 feed, or the legacy pages/home
// when that fails, mapped into shelves (home_shelves) on the worker. The
// shelves are kept in memory with the arena they came in, for the account,
// and fetched again when Home is shown and they're older than HOME_STALE.
// Mixes are left out: their pictures are URLs rather than image ids, and
// opening one as a list would need a source of its own.
//
// With TIDALFAST_FAKE=1 the shelves are made from the fake rows and
// playlists when Home is first shown, with no job.

import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../text"
import "../tidal"
import "../ui"

HOME_SHELVES :: 12
HOME_STALE :: 10 * time.Minute
HOME_SHORTCUTS :: 8
SHORTCUT_H :: 56 // a tile, and its cover
SHORTCUT_GAP :: 8
SHORTCUT_WIDE :: 760 // the column's width from which tiles go four to a row

// Home_Place is the Home page as a place in the History.
Home_Place :: struct {}

Home_Status :: enum u8 {
	Idle, // not asked for, or asked again on the next home_want
	Loading,
	Ready,
	Failed, // with no shelves to show; a failed refresh keeps the old ones Ready
}

Home :: struct {
	status:  Home_Status,
	error:   Small, // why the last fetch failed
	fetched: time.Tick, // when the shelves came
	arena:   ^vmem.Arena, // owns shelves, adopted from the result
	shelves: []Home_Shelf,
}

Home_Shelf :: struct {
	title:  string,
	source: Source, // what its cards are and open: .Album, .Artist or .Playlist
	items:  []Found,
}

// Home_Job fetches the home feed.
Home_Job :: struct {}

Home_Result :: struct {
	shelves: []Home_Shelf, // in arena
}

// home_visit is Home being shown: it asks for the shelves if they never
// came, failed, or are older than HOME_STALE. With the fake data they're
// made at once.
home_visit :: proc(s: ^State) {
	h := &s.data.home
	if s.data.fake {
		if h.status == .Idle {
			home_fake(s)
		}
		return
	}
	stale := h.status == .Ready && time.tick_since(h.fetched) > HOME_STALE
	if h.status == .Failed || stale {
		h.status = .Idle
	}
	home_want(&s.data)
}

// home_want asks for the shelves when nothing has asked yet. Asking again
// sends nothing more, so the page can call it each frame.
home_want :: proc(d: ^Data) {
	h := &d.home
	if d.fake || d.account != .Signed_In || h.status != .Idle {
		return
	}
	h.status = .Loading
	push_job(d, {payload = Home_Job{}})
}

// home_retry asks again after a failure.
home_retry :: proc(d: ^Data) {
	if d.home.status == .Failed {
		d.home.status = .Idle
		home_want(d)
	}
}

home_result :: proc(d: ^Data, res: ^Result, failed: bool) {
	h := &d.home
	if h.status != .Loading {
		return
	}
	if failed {
		h.error = res.message
		h.status = .Ready if len(h.shelves) > 0 else .Failed
		return
	}
	answer, _ := res.payload.(Home_Result)
	arena_release(h.arena)
	h.arena = take(&res.arena)
	h.shelves = answer.shelves
	h.fetched = time.tick_now()
	h.status = .Ready
	h.error = {}
}

// home_job_dropped is a held Home job that won't be pushed: the next
// home_want asks again.
home_job_dropped :: proc(d: ^Data) {
	h := &d.home
	if h.status == .Loading {
		h.status = .Ready if len(h.shelves) > 0 else .Idle
	}
}

// home_clear frees the shelves, at sign-out and shut down.
home_clear :: proc(d: ^Data) {
	arena_release(d.home.arena)
	d.home = {}
}

// home_showing says whether the main view shows Home: the History's
// current place is Home. The open list stays as it was underneath.
home_showing :: proc(s: ^State) -> bool {
	h := &s.history
	if h.count == 0 {
		return false
	}
	_, ok := h.places[h.at].(Home_Place)
	return ok
}

// Drawing

// draw_home_entry is the Home row at the top of the sidebar, lit while
// Home shows.
draw_home_entry :: proc(s: ^State) {
	current := home_showing(s)
	ui.row("", {}, ui.fill(), ui.px(40))
	ui.spacer(ui.px(SIDEBAR_PAD))
	{
		b := ui.row("##home", {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects}, ui.fill(), ui.fill())
		b.radius = 6
		row_highlight(b, SIDEBAR_ROWS, current)
		ui.accessible(b, .Button, "Home", selected = current)
		if ui.signal(b).clicked {
			pending_set(s, Home_Place{})
		}
		ui.spacer(ui.px(ROW_PAD))
		ui.text_style(.Icon_Fill if current else .Icon, 20, TEXT)
		icon := ui.label(text.ICON_HOUSE_FILL if current else text.ICON_HOUSE, ui.px(40), ui.fill())
		icon.text_align = .Center
		ui.spacer(ui.px(12))
		ui.text_style(.Semibold, 15, TEXT)
		ui.label("Home", ui.fill(), ui.fill())
	}
	ui.spacer(ui.px(SIDEBAR_PAD))
}

// draw_home draws the page main_w wide: the greeting, the shortcuts, then
// the shelves, grey ones while they're on their way, or why they didn't
// come with a Retry.
draw_home :: proc(s: ^State, main_w: f32) {
	h := &s.data.home
	home_want(&s.data)
	content_w := min(main_w, CONTENT_MAX) - 2 * PAGE_PAD
	view := ui.scroll_view("home", ui.fill(), ui.fill(), inset_end = bar_inset(s))
	ui.accessible(view, .Group, "Home")
	centred(content_w)
	ui.spacer(ui.px(24))
	{
		ui.row("", {}, ui.fill(), ui.px(44))
		ui.spacer(ui.px(CARD_PAD))
		ui.text_style(.Bold, 32, TEXT)
		hello := greeting()
		ui.accessible(ui.label(hello, ui.fill(), ui.fill()), .Static_Text, hello)
	}
	ui.spacer(ui.px(16))
	draw_shortcuts(s, content_w)
	switch {
	case len(h.shelves) > 0:
		for shelf, i in h.shelves {
			sig := card_row(s, fmt.tprintf("home%d", i), shelf.title, shelf.items, shelf.source, content_w, view_all = false)
			if sig.clicked >= 0 {
				open_card(s, shelf.source, shelf.items[sig.clicked])
			}
		}
	case h.status == .Failed:
		ui.parent(section_title("For you"))
		ui.text_style(.Regular, 13, DIM)
		message := small_str(&h.error)
		ui.label(fmt.tprintf("Couldn't load: %s", message) if message != "" else "Couldn't load", ui.text_size(), ui.fill())
		ui.spacer(ui.px(8))
		if text_button("Retry###home_retry", "Retry loading Home").clicked {
			home_retry(&s.data)
			ui.data_changed()
		}
	case:
		for _ in 0 ..< 3 {
			shelf_placeholder("", content_w)
		}
	}
	ui.spacer(ui.px(48))
}

// greeting says good morning, afternoon or evening by the local time.
@(private = "file")
greeting :: proc() -> string {
	now := posix.time(nil)
	local: posix.tm
	posix.localtime_r(&now, &local)
	switch local.tm_hour {
	case 5 ..< 12:
		return "Good morning"
	case 12 ..< 18:
		return "Good afternoon"
	}
	return "Good evening"
}

// draw_shortcuts is the sidebar's first HOME_SHORTCUTS entries as tiles,
// four to a row in a wide column and two in a narrow one. A click opens
// the entry. The tiles share a keyed parent, so the arrows move through
// them as a grid.
@(private = "file")
draw_shortcuts :: proc(s: ^State, width: f32) {
	n := min(sidebar_count(s), HOME_SHORTCUTS)
	if n == 0 {
		return
	}
	inner := width - 2 * CARD_PAD
	cols := 4 if inner >= SHORTCUT_WIDE else 2
	tile_w := (inner - f32(cols - 1) * SHORTCUT_GAP) / f32(cols)
	grid := ui.column("shortcuts", {}, ui.fill(), ui.children_sum())
	ui.accessible(grid, .List, "Shortcuts")
	for first := 0; first < n; first += cols {
		if first > 0 {
			ui.spacer(ui.px(SHORTCUT_GAP))
		}
		ui.row("", {}, ui.fill(), ui.px(SHORTCUT_H))
		ui.spacer(ui.px(CARD_PAD))
		for i in first ..< min(first + cols, n) {
			if i > first {
				ui.spacer(ui.px(SHORTCUT_GAP))
			}
			if shortcut(s, i, tile_w).clicked {
				pending_set(s, Playlist_Place{index = i})
			}
		}
	}
}

@(private = "file")
shortcut :: proc(s: ^State, i: int, width: f32) -> ui.Signal {
	entry := sidebar_entry(s, i)
	b := ui.row(fmt.tprintf("##shortcut%d", i), {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects, .Clip}, ui.px(width), ui.px(SHORTCUT_H))
	b.radius = 6
	b.background = SURFACE
	b.hover_color = SURFACE_ACTIVE
	ui.accessible(b, .Button, entry.name)
	cover_art(s, .Playlist, entry.image, entry.seed, SHORTCUT_H, ui.px(SHORTCUT_H), 6)
	ui.spacer(ui.px(14))
	ui.text_style(.Semibold, 14, TEXT)
	ui.label(entry.name, ui.fill(), ui.fill())
	ui.spacer(ui.px(12))
	return ui.signal(b)
}

// The worker's side.

run_home :: proc(s: ^tidal.Session, res: ^Result, a: mem.Allocator) {
	page, err := tidal.home(s, false, context.temp_allocator)
	if err != nil {
		log.infof("home: the v2 feed failed (%s), asking for pages/home", tidal.error_summary(err, context.temp_allocator))
		page, err = tidal.home(s, true, context.temp_allocator)
	}
	if err != nil {
		fail(res, err)
		return
	}
	res.payload = Home_Result{home_shelves(page, a)}
}

// home_shelves turns a home page into shelves: its lists of albums,
// playlists and artists, at most HOME_SHELVES of them with SHELF_CARDS
// cards each. A list of mixed kinds keeps the kind of its first card it
// can show. Lists with nothing to show are left out. Strings go to a.
home_shelves :: proc(page: tidal.Page, a: mem.Allocator) -> []Home_Shelf {
	out := make([dynamic]Home_Shelf, 0, HOME_SHELVES, a)
	cards := make([dynamic]Found, 0, SHELF_CARDS, context.temp_allocator)
	for category in page.categories {
		if len(out) == HOME_SHELVES {
			break
		}
		list := category.(tidal.Item_List) or_continue
		clear(&cards)
		source := Source.None
		for item in list.items {
			if len(cards) == SHELF_CARDS {
				break
			}
			kind, f, ok := home_card(item)
			if !ok || (source != .None && kind != source) {
				continue
			}
			source = kind
			append(&cards, found_copy(f, a))
		}
		if len(cards) == 0 {
			continue
		}
		shelf := Home_Shelf {
			title  = strings.clone(list.title, a),
			source = source,
			items  = make([]Found, len(cards), a),
		}
		copy(shelf.items, cards[:])
		append(&out, shelf)
	}
	return out[:]
}

// home_card is an item of the feed as a card, if it's an album, playlist
// or artist with an id. Its strings are the item's.
@(private = "file")
home_card :: proc(item: tidal.Item) -> (source: Source, f: Found, ok: bool) {
	#partial switch v in item {
	case tidal.Album:
		if v.id == 0 {
			return
		}
		f = {id = v.id, name = v.name, image = v.cover, tracks = v.num_tracks}
		f.artist, f.artists = join_artists(v.artists, v.artist, context.temp_allocator)
		f.subtitle = f.artist if f.artist != "" else "Album"
		return .Album, f, true
	case tidal.Playlist:
		if v.id == "" {
			return
		}
		f = {uuid = v.id, name = v.name, image = v.square_picture, tracks = v.num_tracks, subtitle = "Playlist"}
		if v.num_tracks > 0 {
			f.subtitle = fmt.tprintf("Playlist · %d songs", v.num_tracks)
		}
		return .Playlist, f, true
	case tidal.Artist:
		if v.id == 0 {
			return
		}
		return .Artist, {id = v.id, name = v.name, image = v.picture, subtitle = "Artist"}, true
	}
	return
}

// Fake data

// home_fake makes the shelves from the fake rows and playlists, as
// fake artist pages are: a card's id is a row of its album or artist, or
// a playlist's sidebar entry, and covers are gradients.
@(private = "file")
home_fake :: proc(s: ^State) {
	h := &s.data.home
	arena := arena_new()
	if arena == nil {
		h.status = .Failed
		h.error = small("out of memory")
		return
	}
	a := vmem.arena_allocator(arena)
	shelves := make([dynamic]Home_Shelf, 0, 4, a)
	append(&shelves, Home_Shelf{"Recently played", .Album, fake_home_albums(s.rows, 0, 12, a)})
	append(&shelves, Home_Shelf{"Playlists for you", .Playlist, fake_home_playlists(a)})
	append(&shelves, Home_Shelf{"Artists you might like", .Artist, fake_home_artists(s.rows, 16, a)})
	append(&shelves, Home_Shelf{"New albums", .Album, fake_home_albums(s.rows, len(s.rows) / 2, 20, a)})
	h.arena = arena
	h.shelves = shelves[:]
	h.status = .Ready
	h.fetched = time.tick_now()
}

// FAKE_STRIDE spreads the cards over the fake rows, so a shelf isn't one
// artist's albums.
@(private = "file")
FAKE_STRIDE :: 37

@(private = "file")
fake_home_albums :: proc(rows: []Row, from, n: int, a: mem.Allocator) -> []Found {
	out := make([dynamic]Found, 0, n, a)
	next: for i := from; i < len(rows) && len(out) < n; i += FAKE_STRIDE {
		for f in out {
			if f.name == rows[i].album {
				continue next
			}
		}
		append(&out, Found{id = i64(i), name = rows[i].album, subtitle = rows[i].artist, artist = rows[i].artist})
	}
	return out[:]
}

@(private = "file")
fake_home_artists :: proc(rows: []Row, n: int, a: mem.Allocator) -> []Found {
	out := make([dynamic]Found, 0, n, a)
	next: for i := 11; i < len(rows) && len(out) < n; i += FAKE_STRIDE {
		for f in out {
			if f.name == rows[i].artist {
				continue next
			}
		}
		append(&out, Found{id = i64(i), name = rows[i].artist, subtitle = "Artist"})
	}
	return out[:]
}

@(private = "file")
fake_home_playlists :: proc(a: mem.Allocator) -> []Found {
	out := make([]Found, len(PLAYLISTS) - 1, a)
	for &f, i in out {
		f = {id = i64(i + 1), name = PLAYLISTS[i + 1], subtitle = "Playlist"}
	}
	return out
}
