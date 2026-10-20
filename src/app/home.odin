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
import "core:time"

import "../tidal"

HOME_SHELVES :: 12
HOME_STALE :: 10 * time.Minute

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
