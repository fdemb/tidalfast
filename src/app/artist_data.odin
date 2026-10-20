package app

// The artist pages' data: the artist, the biography and the shelves of
// albums, EPs and singles, what the artist appears on and similar
// artists. The top tracks aren't here: they're the open list
// (list_open(.Artist, ...)), cached as any list is.
//
// Each part of a page is its own Artist job, so parts arrive, fail and are
// asked for again on their own. A page's parts are kept with the arena
// their result came in, for the session, ARTIST_CACHE pages of them; the
// one visited longest ago goes to make room. A page has a generation that
// is never reused, and its jobs carry it, so an answer for an evicted page
// can't land in a page opened again for the same artist.
//
// With TIDALFAST_FAKE=1 a page is made from the fake rows on the UI thread
// when it's visited: the artist's rows are its tracks, their albums its
// albums, EPs and singles, and the artists of the other rows on those
// albums the similar artists.

import "core:fmt"
import "core:hash"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:time"

import "../tidal"

ARTIST_CACHE :: 8
ARTIST_PAGE_SIZE :: 50 // albums asked for at a time
ARTIST_CARDS_MAX :: 500 // cards a shelf keeps, so one huge catalog can't send requests without end

Artist_Part :: enum u8 {
	Info,
	Bio,
	Albums,
	Singles,
	Appears,
	Similar,
}

Artist_Cache :: struct {
	pages:    [ARTIST_CACHE]Artist_Page,
	next_gen: u64,
	visits:   u64, // goes up with every visit, for Artist_Page.used
}

Artist_Page :: struct {
	id:            i64, // 0 for a free slot; the fake data's are negative, see artist_fake_key
	gen:           u64,
	used:          u64, // the visit it was last opened in
	name, picture: Small, // what it was opened with, then the Info part's
	parts:         [Artist_Part]Artist_Part_State,
	bio:           Bio_Layout, // the biography's lines, see artist.odin
}

// Artist_Part_State is nil before it's asked for, and again after a held
// job for it was dropped, so the next artist_want asks again.
Artist_Part_State :: union {
	Artist_Waiting,
	Artist_Ready,
	Artist_Failed,
}

Artist_Waiting :: struct {}

Artist_Failed :: struct {
	message: Small,
}

Artist_Ready :: struct {
	arena:   ^vmem.Arena, // the result's, freed only with arena_release
	content: Artist_Content,
}

Artist_Content :: union {
	Artist_Info,
	Artist_Bio,
	Artist_Cards,
}

Artist_Info :: struct {
	name, picture: Small,
}

Artist_Bio :: struct {
	text: string, // "" for an artist without one
}

Artist_Cards :: struct {
	items: []Found,
}

// Artist_Job asks for one part of an artist's page.
Artist_Job :: struct {
	artist: i64,
	gen:    u64, // the page's
	part:   Artist_Part,
}

Artist_Load :: #type proc(s: ^tidal.Session, id: i64, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error)

Artist_Part_Spec :: struct {
	title:  string,
	source: Source, // what a card opens; .None for a part that isn't a shelf
	load:   Artist_Load,
}

artist_part_spec :: proc(part: Artist_Part) -> Artist_Part_Spec {
	switch part {
	case .Info:
		return {"Artist", .None, artist_load_info}
	case .Bio:
		return {"Biography", .None, artist_load_bio}
	case .Albums:
		return {"Albums", .Album, artist_load_albums}
	case .Singles:
		return {"EPs and singles", .Album, artist_load_singles}
	case .Appears:
		return {"Appears on", .Album, artist_load_appears}
	case .Similar:
		return {"Fans also like", .Artist, artist_load_similar}
	}
	return {}
}

// artist_fake_key is the page key of the artist of fake row at.
artist_fake_key :: proc(at: int) -> i64 {
	return -(i64(at) + 1)
}

// artist_visit opens the page of artist id: the cached one, or a new one in
// the slot visited longest ago. A part that failed is asked for again by
// the next artist_want. With the fake data the page is filled at once.
artist_visit :: proc(s: ^State, id: i64, name, picture: Small) -> ^Artist_Page {
	c := &s.data.artists
	page := artist_find(&s.data, id)
	if page == nil {
		page = &c.pages[0]
		for &p in c.pages {
			if p.used < page.used {
				page = &p
			}
		}
		artist_page_free(page)
		c.next_gen += 1
		page^ = {
			id      = id,
			gen     = c.next_gen,
			name    = name,
			picture = picture,
		}
	}
	if page.picture.len == 0 {
		page.picture = picture
	}
	c.visits += 1
	page.used = c.visits
	for &state in page.parts {
		if _, failed := state.(Artist_Failed); failed {
			state = nil
		}
	}
	if s.data.fake && id < 0 && int(-id - 1) < len(s.rows) {
		for part in Artist_Part {
			if page.parts[part] == nil {
				artist_fake_part(page, s.rows, int(-id - 1), part)
			}
		}
	}
	return page
}

// artist_want asks for each part of page not asked for yet. Asking again
// sends nothing more.
artist_want :: proc(d: ^Data, page: ^Artist_Page) {
	if d.account != .Signed_In {
		return
	}
	for part in Artist_Part {
		if page.parts[part] != nil {
			continue
		}
		// Waiting first: push_job may drop a held job of this page, and
		// that sets its part back to nil.
		page.parts[part] = Artist_Waiting{}
		push_job(d, {payload = Artist_Job{artist = page.id, gen = page.gen, part = part}})
	}
}

artist_find :: proc(d: ^Data, id: i64) -> ^Artist_Page {
	if id == 0 {
		return nil
	}
	for &p in d.artists.pages {
		if p.id == id {
			return &p
		}
	}
	return nil
}

// artist_retry asks again for a part of a cached page that failed.
artist_retry :: proc(d: ^Data, id: i64, part: Artist_Part) {
	page := artist_find(d, id)
	if page == nil {
		return
	}
	if _, failed := page.parts[part].(Artist_Failed); failed {
		page.parts[part] = nil
		artist_want(d, page)
	}
}

// artist_waiting is the page an Artist job is still out for, or nil.
artist_waiting :: proc(d: ^Data, job: Artist_Job) -> ^Artist_Page {
	page := artist_find(d, job.artist)
	if page == nil || page.gen != job.gen {
		return nil
	}
	if _, waiting := page.parts[job.part].(Artist_Waiting); !waiting {
		return nil
	}
	return page
}

// artist_result takes an Artist job's result into its page, adopting its
// arena, if the page still waits for it.
artist_result :: proc(d: ^Data, res: ^Result, job: Artist_Job) {
	page := artist_waiting(d, job)
	if page == nil {
		return
	}
	if _, failed := res.err.?; failed {
		page.parts[job.part] = Artist_Failed{res.message}
		return
	}
	part, _ := res.payload.(Artist_Result)
	artist_ready(page, job.part, res.arena, part.content)
	res.arena = nil
	v := &d.view
	if _, info := part.content.(Artist_Info); info && v.source == .Artist && small_str(&v.id) == fmt.tprint(job.artist) {
		v.name = page.name
		v.image = page.picture
	}
}

// artist_ready puts a part's content in its page, which takes its arena.
@(private = "file")
artist_ready :: proc(page: ^Artist_Page, part: Artist_Part, arena: ^vmem.Arena, content: Artist_Content) {
	if info, ok := content.(Artist_Info); ok {
		page.name = info.name
		if info.picture.len > 0 {
			page.picture = info.picture
		}
	}
	if part == .Bio {
		page.bio.valid = false
	}
	page.parts[part] = Artist_Ready{arena, content}
}

// artist_job_dropped sets the part of a held job that won't be pushed back
// to nil, so the next artist_want asks for it again.
artist_job_dropped :: proc(d: ^Data, job: Artist_Job) {
	if page := artist_waiting(d, job); page != nil {
		page.parts[job.part] = nil
	}
}

@(private = "file")
artist_page_free :: proc(page: ^Artist_Page) {
	for &state in page.parts {
		if ready, ok := state.(Artist_Ready); ok {
			arena_release(ready.arena)
		}
	}
	bio_free(&page.bio)
	page^ = {}
}

// artist_clear frees every page, at sign-out and shut down. Generations go
// on from where they were, so no answer from before matches a new page.
artist_clear :: proc(d: ^Data) {
	for &p in d.artists.pages {
		artist_page_free(&p)
	}
}

// The worker's side.

@(private = "file")
artist_load_info :: proc(s: ^tidal.Session, id: i64, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error) {
	ar := tidal.artist_get(s, id, context.temp_allocator) or_return
	return Artist_Info{small(ar.name), small(ar.picture)}, nil
}

// artist_load_bio is the biography without its markup. TIDAL answers 404
// for an artist without one, which is an empty biography, not a failure.
@(private = "file")
artist_load_bio :: proc(s: ^tidal.Session, id: i64, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error) {
	bio: string
	bio, err = tidal.artist_bio(s, id, context.temp_allocator)
	if e, failed := err.?; failed {
		if e.kind == .Object_Not_Found {
			return Artist_Bio{}, nil
		}
		return
	}
	return Artist_Bio{clean_bio(bio, a)}, nil
}

@(private = "file")
artist_load_albums :: proc(s: ^tidal.Session, id: i64, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error) {
	return album_pages(s, id, .Albums, a)
}

@(private = "file")
artist_load_singles :: proc(s: ^tidal.Session, id: i64, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error) {
	return album_pages(s, id, .Singles, a)
}

@(private = "file")
artist_load_appears :: proc(s: ^tidal.Session, id: i64, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error) {
	return album_pages(s, id, .Appears, a)
}

@(private = "file")
artist_load_similar :: proc(s: ^tidal.Session, id: i64, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error) {
	artists := tidal.artist_similar(s, id, a) or_return
	cards := make([]Found, min(len(artists), ARTIST_CARDS_MAX), a)
	for &f, i in cards {
		ar := artists[i]
		f = {id = ar.id, name = ar.name, image = ar.picture, subtitle = "Artist"}
	}
	return Artist_Cards{cards}, nil
}

// album_pages asks for a shelf's albums ARTIST_PAGE_SIZE at a time until a
// page comes back short, up to ARTIST_CARDS_MAX.
@(private = "file")
album_pages :: proc(s: ^tidal.Session, id: i64, part: Artist_Part, a: mem.Allocator) -> (content: Artist_Content, err: tidal.Error) {
	cards := make([dynamic]Found, 0, ARTIST_PAGE_SIZE, a)
	for len(cards) < ARTIST_CARDS_MAX {
		offset := len(cards)
		albums: []tidal.Album
		#partial switch part {
		case .Albums:
			albums, err = tidal.artist_albums(s, id, ARTIST_PAGE_SIZE, offset, a)
		case .Singles:
			albums, err = tidal.artist_ep_singles(s, id, ARTIST_PAGE_SIZE, offset, a)
		case .Appears:
			albums, err = tidal.artist_other(s, id, ARTIST_PAGE_SIZE, offset, a)
		}
		if err != nil {
			return
		}
		for al in albums[:min(len(albums), ARTIST_CARDS_MAX - len(cards))] {
			append(&cards, album_card(al, a))
		}
		if len(albums) < ARTIST_PAGE_SIZE {
			break
		}
	}
	return Artist_Cards{cards[:]}, nil
}

// album_card is an album as a card whose subtitle is its year and kind,
// such as "2025 · EP".
@(private = "file")
album_card :: proc(al: tidal.Album, a: mem.Allocator) -> (f: Found) {
	kind := "Album"
	switch al.type {
	case "EP":
		kind = "EP"
	case "SINGLE":
		kind = "Single"
	}
	f = {id = al.id, name = al.name, image = al.cover, tracks = al.num_tracks, subtitle = kind}
	f.artist, f.artists = join_artists(al.artists, al.artist, a)
	date, ok := al.release_date.?
	if !ok {
		date, ok = al.tidal_release_date.?
	}
	if ok {
		y, _, _ := time.date(date)
		f.subtitle = fmt.aprintf("%d · %s", y, kind, allocator = a)
	}
	return
}

// clean_bio takes the markup out of a TIDAL biography: [wimpLink
// artistId="1"]Name[/wimpLink] becomes Name, and <br/> a line break. A tag
// that never closes is kept as text, so nothing after it is lost.
clean_bio :: proc(bio: string, a: mem.Allocator) -> string {
	b := strings.builder_make(0, len(bio), a)
	rest := bio
	for len(rest) > 0 {
		switch {
		case strings.has_prefix(rest, "[wimpLink"), strings.has_prefix(rest, "[/wimpLink"):
			end := strings.index_byte(rest, ']')
			if end < 0 {
				strings.write_string(&b, rest)
				rest = ""
				continue
			}
			rest = rest[end + 1:]
		case strings.has_prefix(rest, "<br/>"), strings.has_prefix(rest, "<br />"), strings.has_prefix(rest, "<br>"):
			strings.write_byte(&b, '\n')
			rest = rest[strings.index_byte(rest, '>') + 1:]
		case:
			strings.write_byte(&b, rest[0])
			rest = rest[1:]
		}
	}
	return strings.to_string(b)
}

// Fake data

// artist_fake_part makes a part of the page for the artist of fake row at,
// in an arena of its own as a result's would be.
@(private = "file")
artist_fake_part :: proc(page: ^Artist_Page, rows: []Row, at: int, part: Artist_Part) {
	arena := arena_new()
	if arena == nil {
		page.parts[part] = Artist_Failed{small("out of memory")}
		return
	}
	a := vmem.arena_allocator(arena)
	name := rows[at].artist
	content: Artist_Content
	switch part {
	case .Info:
		content = Artist_Info{name = small(name)}
	case .Bio:
		content = Artist_Bio{fmt.aprintf("%s is one of the artists in the fake data, made up for working on the app without a TIDAL account. Every song here is a sine tone thirty seconds long, and every album cover a gradient picked from its name.\nThe albums, EPs and singles below are the albums of this artist's rows: the ones with more songs than most count as albums, the rest as EPs and singles. Fans also like lists the artists of the other songs on those albums.", name, allocator = a)}
	case .Albums, .Singles:
		content = Artist_Cards{fake_albums(rows, name, part == .Singles, a)}
	case .Appears:
		content = Artist_Cards{fake_appears(rows, name, a)}
	case .Similar:
		content = Artist_Cards{fake_similar(rows, name, a)}
	}
	artist_ready(page, part, arena, content)
}

@(private = "file")
Fake_Album :: struct {
	row, n: int, // its first row of the artist's, and how many it has
}

// fake_artist_albums lists the albums of the artist's rows.
@(private = "file")
fake_artist_albums :: proc(rows: []Row, name: string) -> []Fake_Album {
	albums := make([dynamic]Fake_Album, 0, 64, context.temp_allocator)
	outer: for &row, i in rows {
		if row.artist != name {
			continue
		}
		for &al in albums {
			if rows[al.row].album == row.album {
				al.n += 1
				continue outer
			}
		}
		append(&albums, Fake_Album{i, 1})
	}
	return albums[:]
}

@(private = "file")
fake_year :: proc(album: string) -> int {
	return 1990 + int(hash.fnv32a(transmute([]u8)album) % 35)
}

// fake_albums is the artist's albums, or its EPs and singles: the fake
// albums hold the artist's rows about evenly, so the ones under the
// average count as EPs and singles.
@(private = "file")
fake_albums :: proc(rows: []Row, name: string, singles: bool, a: mem.Allocator) -> []Found {
	albums := fake_artist_albums(rows, name)
	average := 0
	for al in albums {
		average += al.n
	}
	average /= max(len(albums), 1)
	out := make([dynamic]Found, 0, len(albums), a)
	for al in albums {
		if (al.n < average) != singles {
			continue
		}
		album := rows[al.row].album
		kind := "Album" if !singles else ("EP" if al.n * 2 > average else "Single")
		append(&out, Found{id = i64(al.row), name = album, subtitle = fmt.aprintf("%d · %s", fake_year(album), kind, allocator = a), tracks = al.n})
	}
	return out[:]
}

// fake_similar is who else is on the artist's first albums.
@(private = "file")
fake_similar :: proc(rows: []Row, name: string, a: mem.Allocator) -> []Found {
	albums := fake_artist_albums(rows, name)
	out := make([dynamic]Found, 0, 16, a)
	for al in albums[:min(len(albums), 8)] {
		album := rows[al.row].album
		next: for &row, i in rows {
			if row.album != album || row.artist == name || len(out) >= 16 {
				continue
			}
			for f in out {
				if f.name == row.artist {
					continue next
				}
			}
			append(&out, Found{id = i64(i), name = row.artist, subtitle = "Artist"})
		}
	}
	return out[:]
}

// fake_appears is the albums of other artists' songs that feature someone,
// as the fake data has no guests of its own.
@(private = "file")
fake_appears :: proc(rows: []Row, name: string, a: mem.Allocator) -> []Found {
	out := make([dynamic]Found, 0, 12, a)
	feat: for &row, i in rows {
		if len(out) >= 12 {
			break
		}
		if row.artist == name || !strings.contains(row.title, "feat.") {
			continue
		}
		for f in out {
			if f.name == row.album {
				continue feat
			}
		}
		append(&out, Found{id = i64(i), name = row.album, subtitle = fmt.aprintf("%d · Album", fake_year(row.album), allocator = a)})
	}
	return out[:]
}
