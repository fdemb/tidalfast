package app

// Search, and the lists that aren't sidebar entries: search results, an
// album's tracks and an artist's top tracks.
//
// The field sits at the top of the sidebar; Cmd-F or Cmd-L focuses it.
// Each edit raises the query generation. Once typing has stopped for
// SEARCH_DEBOUNCE a Search job asks TIDAL for songs, albums, artists and
// playlists at once, and a result for an older generation is dropped. The
// songs open as the track list (Track_View with source .Search), so the
// table, covers, playing a row and the queue work as for a playlist, and
// further pages come as Tracks jobs. Albums, artists and playlists show as
// tabs above it and open their own lists. Clearing the field, or Escape,
// goes back to the sidebar's playlist.
//
// With TIDALFAST_FAKE=1 the search runs over the fake rows on the UI
// thread, and its lists are row indices instead of a Track_View.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import vmem "core:mem/virtual"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import "../cover"
import "../jobs"
import "../platform"
import "../tidal"
import "../ui"

SEARCH_DEBOUNCE :: 0.25 // seconds without typing before the request goes
SEARCH_PAGE :: 50
FOUND_MAX :: 50

Search_Tab :: enum u8 {
	Songs,
	Albums,
	Artists,
	Playlists,
}

// Found is an album, artist or playlist in the results.
Found :: struct {
	id:       i64, // album or artist
	uuid:     string, // playlist
	name:     string,
	subtitle: string,
	image:    string,
	tracks:   int,
	artist:   string, // an album's artists, also in subtitle
	artists:  []Artist_Ref,
}

FOUND_COVER := [Search_Tab]cover.Kind {
	.Songs     = .Album,
	.Albums    = .Album,
	.Artists   = .Artist,
	.Playlists = .Playlist,
}

Found_Lists :: struct {
	albums, artists, playlists: []Found,
}

Search :: struct {
	field:       ui.Text_Field,
	gen:         u32, // goes up with every edit; results for an older one are dropped
	due:         f64, // when the debounce ends, 0 when no request waits
	loading:     bool,
	query:       Small, // what the results are for
	tab:         Search_Tab,
	arena:       ^vmem.Arena, // owns found, adopted from the result
	found:       Found_Lists,
	error:       Small,
	// A list that isn't a sidebar entry is showing. Picking a sidebar entry
	// ends it.
	browsing:    bool,
	// The history place Back or Forward went to, which the history moves
	// to when its results show. nil for a new search.
	place:       Maybe(int),
	// The fake data's lists: indices into State.rows, and for the tabs
	// indices of rows (albums, artists) and of PLAYLISTS.
	fake:        []i32,
	fake_count:  int,
	fake_source: Source, // .None while the fake data shows a playlist
	fake_title:  Small,
	fake_found:  [3][FOUND_MAX]i32,
	fake_counts: [3]int,
}

search_init :: proc(s: ^State) {
	sr := &s.search
	sr.field.limit = len(Small{}.buf)
	if s.data.fake {
		sr.fake = make([]i32, len(s.rows))
	}
}

search_shutdown :: proc(s: ^State) {
	found_free(&s.search)
}

@(private = "file")
found_free :: proc(sr: ^Search) {
	arena_release(sr.arena)
	sr.arena = nil
	sr.found = {}
}

// draw_search_field is the field with the sidebar's width, and runs the
// search: the debounce, Cmd-F and Cmd-L, Return to search at once.
draw_search_field :: proc(s: ^State) {
	sr := &s.search
	ui.column("", {}, ui.fill(), ui.px(44))
	ui.spacer(ui.px(2))
	{
		ui.row("", {}, ui.fill(), ui.px(32))
		ui.spacer(ui.px(12))
		ui.text_style(.Regular, 13, TEXT)
		sig := ui.text_field("search", &sr.field, "Search", ui.fill(), ui.px(32))
		sig.box.background = SURFACE
		sig.box.border_color = ACCENT if sig.focused else OUTLINE
		ui.focus_shortcut(sig.box, .F, {ui.PRIMARY})
		ui.focus_shortcut(sig.box, .L, {ui.PRIMARY})
		ui.spacer(ui.px(12))
		// Return searches for the text it was pressed on. Edits after it in
		// the same frame start the debounce over, as they would in the next.
		submitted := strings.trim_space(sig.submitted_text)
		switch {
		case sig.submitted && submitted != "" && sig.submitted_text != ui.field_text(&sr.field):
			search_stop(s)
			search_send(s, submitted)
			search_edited(s)
		case sig.submitted && submitted != "":
			if sig.changed {
				search_edited(s)
			}
			sr.due = s.ui.time
		case sig.changed:
			search_edited(s)
		}
	}
	// Nothing goes while the input method is still composing.
	if sr.due > 0 && !sr.field.marked {
		if s.ui.time >= sr.due {
			search_send(s, search_query(s))
		} else {
			ui.wake_at(sr.due)
		}
	}
}

search_query :: proc(s: ^State) -> string {
	return strings.trim_space(ui.field_text(&s.search.field))
}

@(private = "file")
drop_search_jobs :: proc(job: ^Job, _: rawptr) -> bool {
	_, search := job.payload.(Search_Job)
	return search
}

// search_edited starts the debounce over. An empty field ends the search
// once the frame is done.
@(private = "file")
search_edited :: proc(s: ^State) {
	search_stop(s)
	if search_query(s) == "" {
		pending_set(s, {kind = .Close_Search})
		return
	}
	s.search.due = s.ui.time + SEARCH_DEBOUNCE
}

// search_stop forgets the search that's waiting or out: the debounce, the
// queued or held job, and the result, which arrives for an older generation.
search_stop :: proc(s: ^State) {
	sr := &s.search
	sr.gen += 1
	sr.due = 0
	sr.loading = false
	sr.place = nil
	if !s.data.fake {
		jobs.remove_if(&s.data.queue, drop_search_jobs, nil)
		held_remove_if(&s.data, drop_search_jobs, nil)
	}
}

@(private = "file")
search_send :: proc(s: ^State, q: string) {
	sr := &s.search
	sr.due = 0
	log.infof("search: \"%s\" (query %d)", q, sr.gen)
	if s.data.fake {
		fake_search(s, q)
		return
	}
	if s.data.account != .Signed_In || search_from_memory(s, q) {
		return
	}
	sr.loading = true
	push_job(&s.data, {payload = Search_Job{gen = sr.gen, query = small(q)}})
}

// search_go puts q in the field and searches for it, for Back and Forward
// to the search at history place at.
search_go :: proc(s: ^State, q: string, at: Maybe(int)) {
	search_stop(s)
	s.search.place = at
	ui.field_set_text(&s.search.field, q)
	search_send(s, q)
}

// search_shown records the results that just became the open list in the
// history: at the place Back or Forward went to, or as a new place. Until
// then the history stays at the place still showing, so a search cleared
// or failed before its results came leaves the history as it was.
@(private = "file")
search_shown :: proc(s: ^State) {
	sr := &s.search
	if at, ok := sr.place.?; ok {
		s.history.at = at
		sr.place = nil
		return
	}
	history_visit(s, {kind = .Search, id = sr.query})
}

// search_close leaves the results for the sidebar's playlist.
search_close :: proc(s: ^State) {
	sr := &s.search
	showing := sr.fake_source == .Search if s.data.fake else s.data.view.source == .Search
	if showing {
		select_playlist(s, s.library.playlist)
	}
	found_free(sr)
	sr.query = {}
	sr.error = {}
	sr.fake_counts = {}
}

// search_forget drops the query, its results and the field's text, for a
// sign-out: the next account doesn't see this one's search.
search_forget :: proc(s: ^State) {
	sr := &s.search
	search_stop(s)
	found_free(sr)
	ui.field_set_text(&sr.field, "")
	sr.query = {}
	sr.error = {}
	sr.browsing = false
}

// search_leave is for select_playlist: the sidebar's list replaces
// whatever was browsed.
search_leave :: proc(s: ^State) -> (was_browsing: bool) {
	sr := &s.search
	was_browsing = sr.browsing
	sr.browsing = false
	sr.fake_source = .None
	return
}

// search_result takes a Search job's result.
search_result :: proc(s: ^State, res: ^Result, job: Search_Job) {
	sr := &s.search
	if job.gen != sr.gen {
		return // for an older query
	}
	sr.loading = false
	if _, failed := res.err.?; failed {
		sr.error = res.message
		return
	}
	sr.error = {}
	found_free(sr)
	sr.arena = res.arena
	res.arena = nil
	sr.found = res.found
	sr.query = job.query
	q := small_str(&sr.query)
	log.infof("search: \"%s\": %d songs, %d albums, %d artists, %d playlists", q, len(res.rows), len(sr.found.albums), len(sr.found.artists), len(sr.found.playlists))

	browse_begin(s)
	d := &s.data
	view_close(d)
	v := &d.view
	v.source = .Search
	v.id = sr.query
	v.name = small(fmt.tprintf("Results for “%s”", q))
	view_init(v)
	if v.has_arena {
		v.found = found_clone(sr.found, vmem.arena_allocator(&v.arena))
	}
	view_add_rows(v, 0, SEARCH_PAGE, res.rows)
	v.next_offset = SEARCH_PAGE
	view_request_pages(d)
	list_loaded(d, v)
	search_shown(s)
}

// search_from_memory shows the results kept for q, if they're recent
// enough (list_stale), without asking TIDAL.
@(private = "file")
search_from_memory :: proc(s: ^State, q: string) -> bool {
	d := &s.data
	i := lru_find(d, .Search, q)
	if i < 0 {
		return false
	}
	e := &d.lists.entries[i].view
	if list_stale(.Search, {}, e.fetched, nil, unix_now()) {
		lru_drop(d, i)
		return false
	}
	sr := &s.search
	sr.loading = false
	sr.error = {}
	found_free(sr)
	sr.arena = arena_new()
	if sr.arena == nil {
		return false
	}
	sr.found = found_clone(e.found, vmem.arena_allocator(sr.arena))
	sr.query = small(q)
	browse_begin(s)
	// Out of memory first, so closing the open list can't drop it.
	kept := lru_remove(d, i)
	view_close(d)
	kept.gen = d.view.gen
	d.view = kept
	log.infof("search: \"%s\": %d songs from memory", q, d.view.count)
	search_shown(s)
	return true
}

// found_clone copies found lists into a.
found_clone :: proc(f: Found_Lists, a: runtime.Allocator) -> Found_Lists {
	clone :: proc(list: []Found, a: runtime.Allocator) -> []Found {
		out := make([]Found, len(list), a)
		for x, i in list {
			out[i] = x
			out[i].uuid = strings.clone(x.uuid, a)
			out[i].name = strings.clone(x.name, a)
			out[i].subtitle = strings.clone(x.subtitle, a)
			out[i].image = strings.clone(x.image, a)
			out[i].artist = strings.clone(x.artist, a)
			out[i].artists = slice.clone(x.artists, a)
		}
		return out
	}
	return {clone(f.albums, a), clone(f.artists, a), clone(f.playlists, a)}
}

// browse_begin resets the table's selection for a list that isn't a
// sidebar entry.
@(private = "file")
browse_begin :: proc(s: ^State) {
	lib := &s.library
	lib.selected = -1
	lib.playing = -1
	lib.status = .None
	lib.list_gen += 1
	s.search.browsing = true
}

// open_list opens an album's tracks, an artist's top tracks or a playlist
// that isn't in the sidebar, for pending_apply. With the fake data it lists
// the rows of an album or artist.
open_list :: proc(s: ^State, p: ^Pending) {
	if p.source == .Artist {
		artist_visit(s, artist_key(s, p), p.name, p.image)
		if artist_list_open(s, p) {
			return // the page, its full top tracks and its grids share it
		}
	}
	if s.data.fake {
		fake_filter(s, p.source, p.index)
		return
	}
	browse_begin(s)
	list_open(&s.data, p.source, small_str(&p.id), small_str(&p.name), small_str(&p.image), p.hint)
}

// go_to_album opens the album of row i once the frame is done.
go_to_album :: proc(s: ^State, i: int) {
	if row := view_row(s, i); row != nil {
		open_album(s, row.album_id, row.album, row.cover, fake_row_index(s, i))
	}
}

// go_to_artist opens artist k of row i once the frame is done. The fake
// data has one artist a row.
go_to_artist :: proc(s: ^State, i: int, k := 0) {
	row := view_row(s, i)
	if row == nil {
		return
	}
	open_artist_of(s, row.artist, row.artists, k, fake_row_index(s, i))
}

// open_album opens an album once the frame is done. The fake data goes by
// the album of row at in State.rows.
open_album :: proc(s: ^State, id: i64, name, image: string, at: int) {
	if s.data.fake {
		pending_set(s, {kind = .List, source = .Album, index = at})
	} else if id != 0 {
		pending_set(s, {kind = .List, source = .Album, id = small(fmt.tprint(id)), name = small(name), image = small(image)})
	}
}

open_artist :: proc(s: ^State, id: i64, name: string, at: int) {
	if s.data.fake {
		pending_set(s, {kind = .List, source = .Artist, index = at})
	} else if id != 0 {
		pending_set(s, {kind = .List, source = .Artist, id = small(fmt.tprint(id)), name = small(name)})
	}
}

// open_artist_of opens artist k of artists, or with the fake data the
// artist of row at in State.rows.
open_artist_of :: proc(s: ^State, joined: string, artists: []Artist_Ref, k: int, at: int) {
	if k < len(artists) {
		open_artist(s, artists[k].id, artist_name(joined, artists[k]), at)
	} else {
		open_artist(s, 0, joined, at)
	}
}

// track_link is what Copy song link puts on the clipboard.
track_link :: proc(id: i64) -> string {
	return fmt.tprintf("https://tidal.com/browse/track/%d", id)
}

// browse_header is the title and subtitle for a list that isn't a sidebar
// entry; ok is false for a sidebar entry.
browse_header :: proc(s: ^State) -> (title, subtitle: string, ok: bool) {
	sr := &s.search
	kinds := [Source]string {
		.None     = "",
		.Liked    = "Playlist",
		.Playlist = "Playlist",
		.Search   = "Search",
		.Album    = "Album",
		.Artist   = "Artist · Top tracks",
	}
	if s.data.fake {
		if sr.fake_source == .None {
			return
		}
		return small_str(&sr.fake_title), fmt.tprintf("%s · %d songs", kinds[sr.fake_source], sr.fake_count), true
	}
	v := &s.data.view
	if !sr.browsing || v.source == .None {
		return
	}
	title = small_str(&v.name)
	if !v.done {
		subtitle = fmt.tprintf("%s · loading, %d songs so far", kinds[v.source], v.loaded_rows)
	} else {
		subtitle = fmt.tprintf("%s · %d songs", kinds[v.source], v.count)
	}
	if v.source == .Search && (sr.loading || sr.due > 0) {
		subtitle = fmt.tprintf("%s · searching for “%s”", subtitle, search_query(s))
	}
	return title, subtitle, true
}

// search_showing says whether the search results are the open list.
search_showing :: proc(s: ^State) -> bool {
	if s.data.fake {
		return s.search.fake_source == .Search
	}
	return s.search.browsing && s.data.view.source == .Search
}

// search_status is a line for the header while a search is out or failed.
search_status :: proc(s: ^State) -> string {
	sr := &s.search
	if sr.error.len > 0 && search_query(s) != "" {
		return fmt.tprintf("Search failed: %s", small_str(&sr.error))
	}
	if (sr.loading || sr.due > 0) && !search_showing(s) {
		return fmt.tprintf("Searching for “%s”…", search_query(s))
	}
	return ""
}

// draw_search_tabs is the row of tabs over the search results. It returns
// false when a tab other than Songs is showing, in place of the table.
draw_search_tabs :: proc(s: ^State) -> (songs: bool) {
	sr := &s.search
	counts := [Search_Tab]int {
		.Songs     = view_count(s),
		.Albums    = found_count(s, .Albums),
		.Artists   = found_count(s, .Artists),
		.Playlists = found_count(s, .Playlists),
	}
	names := [Search_Tab]string {
		.Songs     = "Songs",
		.Albums    = "Albums",
		.Artists   = "Artists",
		.Playlists = "Playlists",
	}
	ui.spacer(ui.px(4))
	{
		ui.row("search_tabs", {}, ui.fill(), ui.px(30))
		ui.spacer(ui.px(20))
		for tab in Search_Tab {
			ui.text_style(.Medium, 13, TEXT if sr.tab == tab else SECONDARY)
			label := fmt.tprintf("%s  %d###tab%d", names[tab], counts[tab], int(tab))
			sig := ui.button(label, ui.text_size(12), ui.fill())
			sig.box.background = SURFACE_ACTIVE if sr.tab == tab else {}
			sig.box.radius = 15
			if sig.clicked {
				sr.tab = tab
			}
			ui.spacer(ui.px(6))
		}
	}
	ui.spacer(ui.px(6))
	return sr.tab == .Songs
}

@(private = "file")
found_count :: proc(s: ^State, tab: Search_Tab) -> int {
	sr := &s.search
	if s.data.fake {
		return sr.fake_counts[int(tab) - 1] if tab != .Songs else sr.fake_count
	}
	switch tab {
	case .Songs:
		return view_count(s)
	case .Albums:
		return len(sr.found.albums)
	case .Artists:
		return len(sr.found.artists)
	case .Playlists:
		return len(sr.found.playlists)
	}
	return 0
}

// found_at is item i of a tab other than Songs.
@(private = "file")
found_at :: proc(s: ^State, tab: Search_Tab, i: int) -> Found {
	sr := &s.search
	if !s.data.fake {
		switch tab {
		case .Songs:
		case .Albums:
			return sr.found.albums[i]
		case .Artists:
			return sr.found.artists[i]
		case .Playlists:
			return sr.found.playlists[i]
		}
		return {}
	}
	at := sr.fake_found[int(tab) - 1][i]
	#partial switch tab {
	case .Albums:
		row := &s.rows[at]
		return {id = i64(at), name = row.album, subtitle = fmt.tprintf("Album · %s", row.artist), artist = row.artist}
	case .Artists:
		return {id = i64(at), name = s.rows[at].artist, subtitle = "Artist"}
	case .Playlists:
		return {id = i64(at), name = PLAYLISTS[at], subtitle = "Playlist"}
	}
	return {}
}

// draw_found_list lists the albums, artists or playlists found. A click
// opens one.
draw_found_list :: proc(s: ^State) {
	sr := &s.search
	tab := sr.tab
	list := ui.scroll_view("found", ui.fill(), ui.fill())
	ui.accessible(list, .List, fmt.tprintf("%v", tab))
	n := found_count(s, tab)
	rows := ui.virtual_rows(list, n, TRACK_ROW_H)
	for i in rows.first ..< rows.last {
		f := found_at(s, tab, i)
		row := ui.row(fmt.tprintf("##found%d", i), {.Clickable, .Draw_Background, .Draw_Hot_Effects}, ui.fill(), ui.px(TRACK_ROW_H))
		row.radius = 6
		row_highlight(row, LIST_ROWS, false)
		ui.accessible(row, .Row, fmt.tprintf("%s, %s", f.name, f.subtitle))
		if ui.signal(row).clicked {
			open_found(s, tab, f)
		}
		ui.spacer(ui.px(16))
		kind := FOUND_COVER[tab]
		cover_art(s, kind, f.image, u32(i) * 2654435761 >> 7, 40, ui.px(52), 20 if kind == .Artist else 4)
		ui.spacer(ui.px(8))
		ui.column("", {}, ui.fill(), ui.fill())
		ui.spacer(ui.px(9))
		ui.text_style(.Medium, 14, TEXT)
		title := ui.label(f.name, ui.fill(), ui.px(20))
		title.text_pad = 4
		ui.text_style(.Regular, 13, SECONDARY)
		if tab == .Albums && f.artist != "" {
			ui.row("", {}, ui.fill(), ui.px(18))
			prefix := ui.label("Album ·", ui.text_size(), ui.fill())
			prefix.text_pad = 4
			// The fake data's album id is the row it's found at.
			if k, sig := artist_links(s, f.artist, f.artists, 0); sig.clicked {
				open_artist_of(s, f.artist, f.artists, k, int(f.id))
			}
		} else {
			sub := ui.label(f.subtitle, ui.fill(), ui.px(18))
			sub.text_pad = 4
		}
	}
}

// open_found opens a found album, artist or playlist once the frame is
// done. With the fake data an album's or artist's id is one of its rows,
// and a playlist's is its sidebar entry.
@(private = "file")
open_found :: proc(s: ^State, tab: Search_Tab, f: Found) {
	p := Pending {
		kind  = .List,
		name  = small(f.name),
		image = small(f.image),
		hint  = f.tracks,
	}
	#partial switch tab {
	case .Albums:
		p.source = .Album
		p.id = small(fmt.tprint(f.id))
	case .Artists:
		p.source = .Artist
		p.id = small(fmt.tprint(f.id))
		p.hint = 0
	case .Playlists:
		p.source = .Playlist
		p.id = small(f.uuid)
	}
	if s.data.fake {
		p.index = int(f.id)
		if tab == .Playlists {
			p.kind = .Playlist
		}
	}
	pending_set(s, p)
}

// view_cover is the cover the list header shows, if any.
view_cover :: proc(s: ^State) -> (kind: cover.Kind, id: string, show: bool) {
	v := &s.data.view
	if s.data.fake {
		return
	}
	#partial switch v.source {
	case .None, .Search:
		return
	case .Album:
		return .Album, small_str(&v.image), true
	case .Artist:
		// Opened from a row the list has no picture; the page's Info has.
		n, _ := strconv.parse_i64(small_str(&v.id))
		if page := artist_find(&s.data, n); page != nil && page.picture.len > 0 {
			return .Artist, small_str(&page.picture), true
		}
		return .Artist, small_str(&v.image), true
	}
	return .Playlist, small_str(&v.image), true
}

// The worker's side.

// found_lists turns TIDAL's search results into what the tabs show.
found_lists :: proc(r: tidal.Search_Results, a: runtime.Allocator) -> (out: Found_Lists) {
	albums := make([]Found, min(len(r.albums), FOUND_MAX), a)
	for &f, i in albums {
		al := r.albums[i]
		f = {id = al.id, name = al.name, image = al.cover, tracks = al.num_tracks}
		f.artist, f.artists = join_artists(al.artists, al.artist, a)
		f.subtitle = fmt.aprintf("Album · %s", f.artist, allocator = a) if f.artist != "" else "Album"
	}
	artists := make([]Found, min(len(r.artists), FOUND_MAX), a)
	for &f, i in artists {
		ar := r.artists[i]
		f = {id = ar.id, name = ar.name, image = ar.picture, subtitle = "Artist"}
	}
	playlists := make([]Found, min(len(r.playlists), FOUND_MAX), a)
	for &f, i in playlists {
		pl := r.playlists[i]
		f = {uuid = pl.id, name = pl.name, image = pl.square_picture, tracks = pl.num_tracks}
		f.subtitle = fmt.aprintf("Playlist · %d songs", pl.num_tracks, allocator = a)
	}
	return {albums, artists, playlists}
}

// more_tracks is a page of a list that isn't a sidebar entry, for a Tracks
// job: more search results, an album's tracks or an artist's top tracks.
more_tracks :: proc(s: ^tidal.Session, job: Tracks_Job, a: runtime.Allocator) -> (tracks: []tidal.Track, err: tidal.Error) {
	id := job.id
	key := small_str(&id)
	#partial switch job.source {
	case .Search:
		found := tidal.search(s, key, {.Track}, int(job.limit), int(job.offset), a) or_return
		return found.tracks, nil
	case .Album:
		n, _ := strconv.parse_i64(key)
		return tidal.album_tracks(s, n, int(job.limit), int(job.offset), allocator = a)
	case .Artist:
		n, _ := strconv.parse_i64(key)
		return tidal.artist_top_tracks(s, n, int(job.limit), int(job.offset), a)
	}
	return nil, nil
}

// Fake data

// fold lowercases s for matching without case.
@(private = "file")
fold :: proc(s: string) -> string {
	b := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for r in s {
		bytes, n := utf8.encode_rune(unicode.to_lower(r))
		append(&b, ..bytes[:n])
	}
	return string(b[:])
}

@(private = "file")
fake_add_found :: proc(s: ^State, kind: int, at: i32, name: proc(row: ^Row) -> string) {
	sr := &s.search
	if sr.fake_counts[kind] >= FOUND_MAX {
		return
	}
	for j in sr.fake_found[kind][:sr.fake_counts[kind]] {
		if name(&s.rows[j]) == name(&s.rows[at]) {
			return
		}
	}
	sr.fake_found[kind][sr.fake_counts[kind]] = at
	sr.fake_counts[kind] += 1
}

// fake_search finds the fake rows whose title, artist or album has q in
// it, and the albums, artists and playlists among them.
@(private = "file")
fake_search :: proc(s: ^State, q: string) {
	sr := &s.search
	needle := fold(q)
	sr.fake_count = 0
	sr.fake_counts = {}
	for &row, i in s.rows {
		if !strings.contains(fold(row.title), needle) && !strings.contains(fold(row.artist), needle) && !strings.contains(fold(row.album), needle) {
			continue
		}
		sr.fake[sr.fake_count] = i32(i)
		sr.fake_count += 1
		fake_add_found(s, 0, i32(i), proc(r: ^Row) -> string {return r.album})
		fake_add_found(s, 1, i32(i), proc(r: ^Row) -> string {return r.artist})
	}
	for name, i in PLAYLISTS {
		if strings.contains(fold(name), needle) && sr.fake_counts[2] < FOUND_MAX {
			sr.fake_found[2][sr.fake_counts[2]] = i32(i)
			sr.fake_counts[2] += 1
		}
	}
	browse_begin(s)
	sr.query = small(q)
	sr.fake_source = .Search
	sr.fake_title = small(fmt.tprintf("Results for “%s”", q))
	log.infof("search: \"%s\": %d songs, %d albums, %d artists, %d playlists", q, sr.fake_count, sr.fake_counts[0], sr.fake_counts[1], sr.fake_counts[2])
	search_shown(s)
}

// fake_filter lists the fake rows of the album or artist of row at.
@(private = "file")
fake_filter :: proc(s: ^State, source: Source, at: int) {
	sr := &s.search
	name := s.rows[at].album if source == .Album else s.rows[at].artist
	title := small(name)
	sr.fake_count = 0
	for &row, i in s.rows {
		if (source == .Album && row.album == name) || (source == .Artist && row.artist == name) {
			sr.fake[sr.fake_count] = i32(i)
			sr.fake_count += 1
		}
	}
	browse_begin(s)
	sr.fake_source = source
	sr.fake_title = title
}

// fake_row is row i of a fake list, or nil when no fake list is showing.
fake_row :: proc(s: ^State, i: int) -> (row: ^Row, listed: bool) {
	sr := &s.search
	if sr.fake_source == .None {
		return nil, false
	}
	if i < 0 || i >= sr.fake_count {
		return nil, true
	}
	return &s.rows[sr.fake[i]], true
}

// fake_row_index is the index in State.rows of row i of the open list.
fake_row_index :: proc(s: ^State, i: int) -> int {
	sr := &s.search
	return int(sr.fake[i]) if sr.fake_source != .None else i
}

fake_count :: proc(s: ^State) -> (n: int, listed: bool) {
	sr := &s.search
	return sr.fake_count, sr.fake_source != .None
}

// Shell

// shell_update tells the shell about the focused text field, the
// accessibility tree and the drag regions when they changed. Run it after ui.end_frame.
shell_update :: proc(s: ^State, shell: ^platform.Shell) {
	if input, changed := ui.text_input(&s.ui); changed && shell.set_text_input != nil {
		shell.set_text_input(&input)
	}
	nodes, h := ui.access_tree(&s.ui)
	if h != s.access_sent && shell.set_accessibility != nil {
		shell.set_accessibility(raw_data(nodes), u32(len(nodes)))
		s.access_sent = h
	}
	rects := ui.drag_regions(&s.ui)
	if dh := hash.fnv64a(mem.slice_to_bytes(rects)); dh != s.drag_sent && shell.set_drag_regions != nil {
		shell.set_drag_regions(cast([^][4]f32)raw_data(rects), u32(len(rects)))
		s.drag_sent = dh
	}
}
