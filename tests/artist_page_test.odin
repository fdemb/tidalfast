package tidal_tests

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/audio"
import "../src/platform"
import "../src/ui"

// has says whether the last frame's tree has a node of role labelled
// exactly label.
@(private = "file")
has :: proc(s: ^app.State, label: string, role: platform.Access_Role) -> bool {
	_, ok := exact(s, label, role)
	return ok
}

@(private = "file")
exact :: proc(s: ^app.State, label: string, role: platform.Access_Role) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == role && string(n.label) == label {
			return n, true
		}
	}
	return {}, false
}

// press_exact presses the first button labelled exactly label, which on
// the artist page is the page's own before the player bar's.
@(private = "file")
press_exact :: proc(t: ^testing.T, s: ^app.State, label: string, role := platform.Access_Role.Button, loc := #caller_location) -> platform.Event {
	n, ok := exact(s, label, role)
	testing.expectf(t, ok, "no %v %q", role, label, loc = loc)
	return {kind = .Access_Press, target = n.id}
}

@(private = "file")
enabled_exact :: proc(s: ^app.State, label: string) -> bool {
	n, ok := exact(s, label, .Button)
	return ok && .Disabled not_in n.flags
}

@(private = "file")
focused :: proc(s: ^app.State) -> string {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if .Focused in n.flags {
			return string(n.label)
		}
	}
	return ""
}

// settle draws frames until nothing moves.
@(private = "file")
settle :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, loc := #caller_location) {
	for _ in 0 ..< 100 {
		library_frame(t, s, f, dt = 1, loc = loc)
		if !f.animating {
			return
		}
	}
	testing.expect(t, false, "the frames settle", loc = loc)
}

// page_showing says whether the artist page is in the main view.
@(private = "file")
page_showing :: proc(s: ^app.State) -> bool {
	return has(s, "Top tracks", .Table)
}

// run_page_jobs runs the queued jobs an artist page and its lists send on
// this thread, against the mock, until no more come, and drops the rest.
@(private = "file")
run_page_jobs :: proc(s: ^app.State) {
	for {
		queued := data_jobs(&s.data)
		if len(queued) == 0 {
			return
		}
		for &job in queued {
			#partial switch _ in job.payload {
			case app.Artist_Job, app.Tracks_Job, app.Search_Job:
				run_now(s, job)
			case:
				app.job_free(&job)
			}
		}
	}
}

// open_artist_list opens a list with one song, by the artist id, whose
// link the tests press.
@(private = "file")
open_artist_list :: proc(s: ^app.State, id: i64) {
	name := fmt.tprintf("Artist %d", id)
	rows := []app.Row{{title = "A song", artist = name, album = "An album", duration = "3:00", id = 900, album_id = 10, artists = []app.Artist_Ref{{id = id, start = 0, end = i32(len(name))}}, seconds = 180}}
	app.view_open(&s.data, .Playlist, "uuid", "A playlist", "", len(rows))
	app.view_add_rows(&s.data.view, 0, len(rows), rows, len(rows))
}

// mock_page opens artist id's page from a song's artist link, with its
// parts and top tracks in from the mock.
@(private = "file")
mock_page :: proc(t: ^testing.T, s: ^app.State, f: ^Frame, id: i64) {
	open_artist_list(s, id)
	library_frame(t, s, f)
	library_frame(t, s, f)
	library_frame(t, s, f, press_exact(t, s, fmt.tprintf("Artist %d", id)))
	library_frame(t, s, f)
	run_page_jobs(s)
	library_frame(t, s, f)
	library_frame(t, s, f)
}

// fake_page opens the page of the artist of the fake data's first row from
// its link in the table.
@(private = "file")
fake_page :: proc(t: ^testing.T, s: ^app.State, f: ^Frame) -> string {
	library_frame(t, s, f)
	library_frame(t, s, f)
	name := s.rows[0].artist
	library_frame(t, s, f, press_exact(t, s, name))
	library_frame(t, s, f)
	library_frame(t, s, f)
	return name
}

@(private = "file")
count_buttons :: proc(s: ^app.State, label: string) -> int {
	nodes, _ := ui.access_tree(&s.ui)
	n := 0
	for node in nodes {
		if node.role == .Button && string(node.label) == label {
			n += 1
		}
	}
	return n
}

// An artist link in a song's row opens the artist's page: the name, Play
// and Shuffle beside the player bar's, the top tracks, and each shelf as a
// list.
@(test)
artist_link_opens_the_page :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)

	{
		s := library_state(true)
		defer library_state_free(s)
		f := Frame{fonts = &fonts, size = {1100, 2400}}
		name := fake_page(t, s, &f)
		testing.expect(t, has(s, name, .Static_Text), "the artist's name")
		testing.expect_value(t, count_buttons(s, "Play"), 2)
		testing.expect_value(t, count_buttons(s, "Shuffle"), 2)
		testing.expect(t, page_showing(s), "the top tracks")
		testing.expect(t, has(s, "Albums", .List), "the albums shelf")
		library_frame(t, s, &f, press_exact(t, s, "More"))
		library_frame(t, s, &f)
		library_frame(t, s, &f)
		testing.expect(t, ui.menu_is_open("artist_menu"), "More opens the menu")
		library_frame(t, s, &f, press(s, "Show all top tracks"))
		library_frame(t, s, &f)
		testing.expect(t, !page_showing(s), "the More menu shows all the top tracks")
		testing.expect(t, has(s, name, .Table), "the full top tracks")
	}

	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	open_artist_list(s, 7)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, "Artist 7"))
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "the page shows before its parts come")
	testing.expect(t, !enabled_exact(s, "Play"), "Play waits for the top tracks")
	run_page_jobs(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Artist 7", .Static_Text), "the artist's name")
	testing.expect(t, enabled_exact(s, "Play"), "Play once the top tracks are in")
	testing.expect_value(t, count_buttons(s, "Shuffle"), 2)
	testing.expect(t, has(s, "Top 1 of Artist 7, Artist 7, Album 7000", .Row), "the first top track")
	testing.expect(t, !has(s, "Top 6 of Artist 7, Artist 7, Album 7000", .Row), "five top tracks")
	for title in ([]string{"Albums", "EPs and singles", "Appears on", "Fans also like"}) {
		testing.expectf(t, has(s, title, .List), "the %s shelf", title)
	}
}

// The page, a shelf's grid and the full top tracks are places of their own:
// Back and Forward go through them, and moving among them keeps the open
// list, so the top tracks aren't asked for again.
@(test)
back_and_forward_through_an_artist :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	s.data.lists.memory = true
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	library_frame(t, s, &f)
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "seven"))
	library_frame(t, s, &f, dt = 1)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Results for “seven”", .Static_Text), "the search")

	library_frame(t, s, &f, press_exact(t, s, "Artist 7"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "the page")
	gen := s.data.view.gen
	asked := mock_count(&m, "GET /artists/7/toptracks")
	testing.expect_value(t, asked, 1)

	library_frame(t, s, &f, press_exact(t, s, "View all Albums"))
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "the grid in place of the page")
	testing.expect(t, has(s, "Albums", .List), "the grid")
	testing.expect(t, has(s, "Album 7000, 2020 · Album", .Button), "the grid's cards")
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Back from the grid goes to the page")

	library_frame(t, s, &f, press_exact(t, s, "View all Albums"))
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	first, _ := exact(s, "Album 7000, 2020 · Album", .Button)
	library_frame(t, s, &f, {kind = .Access_Focus, target = first.id})
	library_frame(t, s, &f, key(.Escape))
	testing.expect(t, !page_showing(s), "the first Escape only takes the focus off the card")
	library_frame(t, s, &f, key(.Escape))
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Escape in the grid goes back to the page")
	testing.expect_value(t, s.data.view.gen, gen)

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "Back from the page leaves it")
	testing.expect(t, has(s, "Results for “seven”", .Static_Text), "Back from the page goes to the search")
	library_frame(t, s, &f, press(s, "Forward"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Forward goes to the page again")

	gen = s.data.view.gen
	library_frame(t, s, &f, press_exact(t, s, "View all top tracks"))
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "the full top tracks in place of the page")
	testing.expect(t, has(s, "Artist 7", .Table), "the full top tracks")
	testing.expect(t, has(s, "Top 8 of Artist 7, Artist 7, Album 7000", .Row), "every top track")
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Back from the full top tracks goes to the page")
	testing.expect_value(t, s.data.view.gen, gen)
	run_page_jobs(s)
	testing.expect_value(t, mock_count(&m, "GET /artists/7/toptracks"), asked)
}

// A card on the Fans also like shelf opens that artist's page.
@(test)
similar_artist_opens_its_page :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	mock_page(t, s, &f, 7)
	library_frame(t, s, &f, press_exact(t, s, "Artist 8, Artist"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "a page")
	testing.expect(t, has(s, "Artist 8", .Static_Text), "Artist 8's page")
	testing.expect(t, has(s, "Top 1 of Artist 8, Artist 8, Album 8000", .Row), "Artist 8's top tracks")
	testing.expect(t, !has(s, "Artist 7", .Static_Text), "no longer Artist 7's")
}

// Play on a page turns shuffle off and plays from the first song; Shuffle
// turns it on and plays one of the songs. Playing a row leaves the setting
// as it is.
@(test)
play_and_shuffle_set_shuffle :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	s.playback.player = audio.create(proc "c" () {}, 0, null_output = true)
	defer app.playback_shutdown(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	name := fake_page(t, s, &f)
	songs := make(map[string]bool)
	for r in s.rows {
		if r.artist == name {
			songs[r.title] = true
		}
	}

	s.settings.shuffle = true
	library_frame(t, s, &f, press_exact(t, s, "Play"))
	testing.expect(t, !s.settings.shuffle, "Play turns shuffle off")
	item := app.playback_item(s)
	testing.expect(t, item != nil && item.title == app.view_row(s, 0).title, "Play plays the first song")

	library_frame(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, "Shuffle"))
	testing.expect(t, s.settings.shuffle, "Shuffle turns shuffle on")
	item = app.playback_item(s)
	testing.expect(t, item != nil && songs[item.title], "Shuffle plays one of the artist's songs")

	row := app.view_row(s, 1)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, fmt.tprintf("%s, %s, %s", row.title, row.artist, row.album), .Row))
	testing.expect(t, s.settings.shuffle, "a row leaves shuffle on")
	testing.expect_value(t, app.playback_item(s).title, row.title)
	s.settings.shuffle = false
	row = app.view_row(s, 2)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, fmt.tprintf("%s, %s, %s", row.title, row.artist, row.album), .Row))
	testing.expect(t, !s.settings.shuffle, "a row leaves shuffle off")
	testing.expect_value(t, app.playback_item(s).title, row.title)
}

// Left and Right move the focus along a shelf's cards, and its ‹ › buttons
// page it by whole cards.
@(test)
shelf_left_right_and_paging :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	mock_page(t, s, &f, 1)
	card :: proc(i: int) -> string {
		return fmt.tprintf("Album %d, 2020 · Album", 1000 + i)
	}

	first, ok := exact(s, card(0), .Button)
	testing.expect(t, ok, "the first album")
	library_frame(t, s, &f, {kind = .Access_Focus, target = first.id})
	testing.expect_value(t, focused(s), card(0))
	library_frame(t, s, &f, key(.Right))
	library_frame(t, s, &f)
	testing.expect_value(t, focused(s), card(1))
	library_frame(t, s, &f, key(.Right))
	library_frame(t, s, &f, key(.Left))
	library_frame(t, s, &f)
	testing.expect_value(t, focused(s), card(1))

	shelf, _ := exact(s, "Albums", .List)
	left_card :: proc(s: ^app.State, x: f32) -> int {
		for i in 0 ..< MOCK_ARTIST_ALBUMS {
			n, ok := exact(s, card(i), .Button)
			if ok && abs(n.frame[0] - x) < 0.5 {
				return i
			}
		}
		return -1
	}
	testing.expect_value(t, left_card(s, shelf.frame[0]), 0)
	testing.expect(t, !enabled_exact(s, "Previous page of Albums"), "nothing before the first page")
	// A page is as many whole cards as the shelf shows.
	c0, _ := exact(s, card(0), .Button)
	c1, _ := exact(s, card(1), .Button)
	pitch := c1.frame[0] - c0.frame[0]
	per_page := int((shelf.frame[2] + pitch - c0.frame[2]) / pitch)
	testing.expect(t, per_page >= 2, "a page holds more than one card")
	library_frame(t, s, &f, press_exact(t, s, "Next page of Albums"))
	settle(t, s, &f)
	testing.expect_value(t, left_card(s, shelf.frame[0]), per_page)
	library_frame(t, s, &f, press_exact(t, s, "Next page of Albums"))
	settle(t, s, &f)
	testing.expect_value(t, left_card(s, shelf.frame[0]), 2 * per_page)
	library_frame(t, s, &f, press_exact(t, s, "Previous page of Albums"))
	settle(t, s, &f)
	testing.expect_value(t, left_card(s, shelf.frame[0]), per_page)
}

// The biography is broken into lines once, not every frame, and again when
// the page gets wider.
@(test)
bio_wraps_once_per_width :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	fake_page(t, s, &f)
	// Fonts for the fake data's other scripts load in the background, and
	// each one that comes in breaks the biography into lines again.
	for same := 0; same < 5; {
		generation := fonts.state.generation
		time.sleep(20 * time.Millisecond)
		library_frame(t, s, &f)
		same = same + 1 if fonts.state.generation == generation else 0
	}
	testing.expect(t, has(s, "Read more", .Button), "the biography is longer than three lines")
	wraps := s.measure.bio_wraps
	for _ in 0 ..< 3 {
		library_frame(t, s, &f)
	}
	testing.expect_value(t, s.measure.bio_wraps, wraps)
	library_frame(t, s, &f, press_exact(t, s, "Read more"))
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Read less", .Button), "More shows the rest")
	testing.expect_value(t, s.measure.bio_wraps, wraps)
	f.size = {900, 2400}
	library_frame(t, s, &f)
	testing.expect_value(t, s.measure.bio_wraps, wraps + 1)
	library_frame(t, s, &f)
	testing.expect_value(t, s.measure.bio_wraps, wraps + 1)
}

// A page that has settled asks for no more frames.
@(test)
settled_page_is_idle :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	fake_page(t, s, &f)
	testing.expect(t, page_showing(s), "the page")
	settle(t, s, &f)
	library_frame(t, s, &f, dt = 1)
	testing.expect(t, !f.animating, "a settled page asks for no frames")
}

// Picking a sidebar playlist, or searching, leaves the artist page.
@(test)
leaving_the_artist_page :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	name := fake_page(t, s, &f)
	testing.expect(t, page_showing(s), "the page")
	library_frame(t, s, &f, press(s, "Discover Weekly"))
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "a playlist in place of the page")
	testing.expect(t, has(s, "Discover Weekly", .Static_Text), "the playlist")

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Back to the page")
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "Jóga"))
	library_frame(t, s, &f, dt = 1)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "the results in place of the page")
	testing.expect(t, has(s, "Results for “Jóga”", .Static_Text), "the results")
	testing.expect(t, !has(s, name, .Static_Text) || strings.contains(name, "Jóga"), "not the artist's name")
}



// Up and Down on the focused top tracks move the selection along them,
// rather than the focus to the buttons of the shelves below.
@(test)
top_tracks_arrows_move_the_selection :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	mock_page(t, s, &f, 7)
	down, up := left_click(s, "Top 1 of Artist 7, ")
	library_frame(t, s, &f, down, up)
	library_frame(t, s, &f)
	table, _ := exact(s, "Top tracks", .Table)
	library_frame(t, s, &f, {kind = .Access_Focus, target = table.id})
	library_frame(t, s, &f, key(.Down))
	library_frame(t, s, &f)
	testing.expect_value(t, focused(s), "Top tracks")
	second, _ := exact(s, "Top 2 of Artist 7, Artist 7, Album 7000", .Row)
	testing.expect(t, .Selected in second.flags, "Down selects the second track")
	library_frame(t, s, &f, key(.Up))
	library_frame(t, s, &f)
	first, _ := exact(s, "Top 1 of Artist 7, Artist 7, Album 7000", .Row)
	testing.expect(t, .Selected in first.flags, "Up selects the first again")
}

// A track selected in the full top tracks below the five the page shows
// isn't played by Enter on the page. The keyboard coming into the page's
// top tracks selects the first, since the table shows the focus only with
// its selected row, and Enter plays that.
@(test)
top_tracks_play_only_what_they_show :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	s.playback.player = audio.create(proc "c" () {}, 0, null_output = true)
	defer app.playback_shutdown(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	name := fake_page(t, s, &f)
	testing.expect(t, app.view_count(s) > app.TOP_TRACKS, "more top tracks than the page shows")
	library_frame(t, s, &f, press_exact(t, s, "View all top tracks"))
	library_frame(t, s, &f)
	full, ok := exact(s, name, .Table)
	testing.expect(t, ok, "the full top tracks")
	library_frame(t, s, &f, {kind = .Access_Focus, target = full.id})
	library_frame(t, s, &f, key(.End))
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Back to the page")

	table, _ := exact(s, "Top tracks", .Table)
	library_frame(t, s, &f, {kind = .Access_Focus, target = table.id})
	library_frame(t, s, &f)
	testing.expect_value(t, s.library.selected, 0)
	library_frame(t, s, &f, key(.Return))
	item := app.playback_item(s)
	testing.expect(t, item != nil && item.title == app.view_row(s, 0).title, "Enter plays the first track, not the one the page doesn't show")
}

// A search that fails before its results show leaves the search page
// saying so, and the history where it was. Going Back to a search that
// then fails leaves the artist page showing.
@(test)
abandoned_search_keeps_the_artist_page :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	library_frame(t, s, &f)
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "seven"))
	library_frame(t, s, &f, dt = 1)
	run_page_jobs(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, "Artist 7"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "the page")

	// The search page searches again for what's in the field.
	open_search(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "the search page in place of the artist page")
	testing.expect(t, has(s, "Results for “seven”", .Static_Text), "the search again")
	library_frame(t, s, &f, key(.A, {ui.PRIMARY}), key(.Backspace))
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Search TIDAL", .Static_Text), "the search page emptied")

	m.answers["/search"] = {500, `{"userMessage":"down"}`}
	library_frame(t, s, &f, type_text(&f, "zzz"))
	library_frame(t, s, &f, dt = 1)
	run_page_jobs(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Couldn't search for “zzz”", .Static_Text), "the search page after a failed search")
	testing.expect(t, !enabled(s, "Forward"), "nothing to go Forward to")

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Back from the search page to the artist page")

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "the page after Back to a search that failed")
	delete_key(&m.answers, "/search")
	library_frame(t, s, &f, press(s, "Forward"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Forward from the failed search to the page")
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Results for “seven”", .Static_Text), "Back to the search once it answers")
	testing.expect(t, enabled(s, "Forward"), "the page to go Forward to")
}


// Back and Forward step from the place they're heading to, so pressing
// them again walks the history whether or not a search on the way answers:
// from an artist's page, Back twice past a search that fails, or that
// hasn't answered yet, reaches the list before it.
@(test)
back_walks_past_a_search_that_hasnt_answered :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	library_frame(t, s, &f)
	open_search(t, s, &f)
	library_frame(t, s, &f, type_text(&f, "seven"))
	library_frame(t, s, &f, dt = 1)
	run_page_jobs(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, "Artist 7"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "the page")

	m.answers["/search"] = {500, `{"userMessage":"down"}`}
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "Back past a failed search leaves the page")
	testing.expect(t, !enabled(s, "Back"), "Back past a failed search reaches the first place")
	testing.expect(t, enabled(s, "Forward"), "the search to go Forward to")

	delete_key(&m.answers, "/search")
	library_frame(t, s, &f, press(s, "Forward"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Results for “seven”", .Static_Text), "Forward to the search")
	library_frame(t, s, &f, press(s, "Forward"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, page_showing(s), "Forward to the page")

	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	library_frame(t, s, &f, press(s, "Back"))
	library_frame(t, s, &f)
	run_page_jobs(s)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "Back twice before the search answers leaves the page")
	testing.expect(t, !has(s, "Results for “seven”", .Static_Text), "Back twice before the search answers passes it")
	testing.expect(t, !enabled(s, "Back"), "Back twice before the search answers reaches the first place")
}

// In a View all grid Down and Up move the focus by a row of cards, Left
// and Right by one card. A resize that changes how many cards fit in a row
// keeps the focused card focused, under the same accessibility id.
@(test)
grid_arrows_and_resize :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	mock_page(t, s, &f, 1)
	card :: proc(i: int) -> string {
		return fmt.tprintf("Album %d, 2020 · Album", 1000 + i)
	}
	per_row :: proc(s: ^app.State) -> int {
		c0, _ := exact(s, card(0), .Button)
		n := 0
		for i in 0 ..< MOCK_ARTIST_ALBUMS {
			c, ok := exact(s, card(i), .Button)
			if ok && c.frame[1] == c0.frame[1] {
				n += 1
			}
		}
		return n
	}
	library_frame(t, s, &f, press_exact(t, s, "View all Albums"))
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	cols := per_row(s)
	testing.expect(t, cols >= 2, "a row holds more than one card")

	first, _ := exact(s, card(0), .Button)
	library_frame(t, s, &f, {kind = .Access_Focus, target = first.id})
	library_frame(t, s, &f, key(.Down))
	library_frame(t, s, &f)
	testing.expect_value(t, focused(s), card(cols))
	library_frame(t, s, &f, key(.Right))
	library_frame(t, s, &f)
	testing.expect_value(t, focused(s), card(cols + 1))
	library_frame(t, s, &f, key(.Up))
	library_frame(t, s, &f)
	testing.expect_value(t, focused(s), card(1))
	library_frame(t, s, &f, key(.Down))
	library_frame(t, s, &f, key(.Left))
	library_frame(t, s, &f)
	testing.expect_value(t, focused(s), card(cols))

	before, _ := exact(s, card(cols), .Button)
	f.size = {820, 2400}
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, per_row(s) != cols, "the resize changes the cards in a row")
	after, _ := exact(s, card(cols), .Button)
	testing.expect_value(t, after.id, before.id)
	testing.expect_value(t, focused(s), card(cols))
}

// A biography paragraph without spaces, as Chinese and Japanese are
// written, and a link wider than the column break between characters, so
// no line is wider than the column and nothing is lost.
@(test)
bio_breaks_words_wider_than_the_column :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	cjk := strings.repeat("日本語の文章は単語の間に空白を入れずに書かれます。", 6)
	url := strings.concatenate({"https://example.com/", strings.repeat("long-path-", 30)})
	m.answers["/artists/7/bio"] = {200, fmt.aprintf(`{{"source":"mock","text":"%s<br/>Site: %s"}}`, cjk, url)}
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	mock_page(t, s, &f, 7)
	for same := 0; same < 5; {
		generation := fonts.state.generation
		time.sleep(20 * time.Millisecond)
		library_frame(t, s, &f)
		same = same + 1 if fonts.state.generation == generation else 0
	}
	testing.expect(t, has(s, "Read more", .Button), "the biography is longer than three lines")
	library_frame(t, s, &f, press_exact(t, s, "Read more"))
	library_frame(t, s, &f)

	bio := strings.concatenate({cjk, "\nSite: ", url})
	joined := strings.builder_make()
	lines := 0
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		label := string(n.label)
		if n.role != .Static_Text || label == "" || !strings.contains(bio, label) {
			continue
		}
		lines += 1
		strings.write_string(&joined, label)
		testing.expectf(t, n.frame[2] <= app.BIO_W - 2 * app.CARD_PAD - 48 + 0.5, "line %q is %v wide", label, n.frame[2])
	}
	testing.expect(t, lines > app.BIO_LINES, "more lines than show before Read more")
	testing.expect(t, strings.contains(strings.to_string(joined), cjk), "the whole paragraph without spaces")
	testing.expect(t, strings.contains(strings.to_string(joined), url), "the whole link")
}


// Breaking a long paragraph without spaces again at a new width, as a live
// resize does every frame, shapes a few runs, not a run per prefix tried
// on every line.
@(test)
bio_breaks_a_long_word_in_a_few_shapes :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	cjk := strings.repeat("日本語の文章は単語の間に空白を入れずに書かれます。", 80)
	m.answers["/artists/7/bio"] = {200, fmt.aprintf(`{{"source":"mock","text":"%s"}}`, cjk)}
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	mock_page(t, s, &f, 7)
	for same := 0; same < 5; {
		generation := fonts.state.generation
		time.sleep(20 * time.Millisecond)
		library_frame(t, s, &f)
		same = same + 1 if fonts.state.generation == generation else 0
	}
	testing.expect(t, has(s, "Read more", .Button), "the paragraph is longer than three lines")

	for width in ([]f32{820, 900, 860}) {
		wraps := s.measure.bio_wraps
		f.size = {width, 2400}
		library_frame(t, s, &f)
		testing.expectf(t, s.measure.bio_wraps == wraps + 1, "the biography breaks again at %v", width)
		testing.expectf(t, fonts.state.stats.shaped <= 10, "%d runs shaped at %v", fonts.state.stats.shaped, width)
	}
}

// Pressing More, from the keyboard or an assistive app, asks for the frame
// that shows the rest of the biography, and Less for the one that hides it.
@(test)
bio_more_asks_for_a_frame :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	fake_page(t, s, &f)
	settle(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, "Read more"))
	testing.expect(t, f.animating, "More asks for a frame")
	settle(t, s, &f)
	testing.expect(t, has(s, "Read less", .Button), "the rest shows")
	library_frame(t, s, &f, press_exact(t, s, "Read less"))
	testing.expect(t, f.animating, "Less asks for a frame")
}

// run_jobs runs the queued jobs of kinds against the mock, on this thread,
// until no more come, and drops the rest.
@(private = "file")
run_jobs :: proc(s: ^app.State, kinds: ..typeid) {
	for {
		queued := data_jobs(&s.data)
		if len(queued) == 0 {
			return
		}
		for &job in queued {
			if slice.contains(kinds, reflect.union_variant_typeid(job.payload)) {
				run_now(s, job)
			} else {
				app.job_free(&job)
			}
		}
	}
}

// sidebar_mock gives the mock an empty list of playlists, so the sidebar
// loads and sends the liked ids' fetch.
@(private = "file")
sidebar_mock :: proc(m: ^Mock) {
	m.answers["/users/123/playlistsAndFavoritePlaylists"] = {200, `{"limit":50,"offset":0,"totalNumberOfItems":0,"items":[]}`}
}

// The one favorites/ids request after sign-in fills both the hearts and
// the Follow button, which waits for it. An account with no liked songs
// sends it too, though the Liked Songs version it goes on hasn't moved.
@(test)
one_fetch_fills_the_hearts_and_the_follow_button :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)

	for no_liked in ([]bool{false, true}) {
		m: Mock
		mock_start(&m)
		defer mock_stop(&m)
		sidebar_mock(&m)
		append(&m.followed, 7)
		if no_liked {
			m.answers["/users/123/favorites/tracks"] = {200, `{"limit":1,"offset":0,"totalNumberOfItems":0,"items":[]}`}
		}
		s := library_state(false, &m)
		defer library_state_free(s)
		f := Frame{fonts = &fonts, size = {1100, 2400}}
		fetch: Maybe(app.Job)
		for &job in data_jobs(&s.data) {
			if _, sidebar := job.payload.(app.Playlists_Job); sidebar {
				run_now(s, job)
			} else {
				app.job_free(&job)
			}
		}
		for &job in data_jobs(&s.data) {
			if _, ids := job.payload.(app.Liked_Ids_Job); ids {
				fetch = job
			} else {
				app.job_free(&job)
			}
		}
		testing.expect_value(t, s.data.sidebar.liked_count, 0 if no_liked else MOCK_LIKED)
		job, sent := fetch.?
		if !testing.expect(t, sent, "the sidebar sends the liked ids' fetch") {
			continue
		}
		mock_page(t, s, &f, 7)
		testing.expect(t, has(s, "Follow", .Button) && !enabled_exact(s, "Follow"), "Follow waits for the set")
		run_now(s, job)
		library_frame(t, s, &f)
		library_frame(t, s, &f)
		testing.expect_value(t, mock_count(&m, "GET /users/123/favorites/ids"), 1)
		testing.expect(t, enabled_exact(s, "Following"), "the artist is followed")
		if !no_liked {
			testing.expect(t, has(s, "Unlike Top 1 of Artist 7", .Button), "the top track is liked")
		}
	}
}

// The page's Follow button follows the artist on TIDAL and reads Following
// at once; pressed again it unfollows.
@(test)
follow_button_follows_the_artist :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	sidebar_mock(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	run_jobs(s, app.Playlists_Job, app.Liked_Ids_Job)
	mock_page(t, s, &f, 7)

	testing.expect(t, enabled_exact(s, "Follow"), "Follow")
	library_frame(t, s, &f, press_exact(t, s, "Follow"))
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Following", .Button) && !has(s, "Follow", .Button), "Following at once")
	run_jobs(s, app.Follow_Job)
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Following", .Button), "Following once TIDAL took it")
	testing.expect(t, slice.contains(m.followed[:], 7), "followed on TIDAL")

	library_frame(t, s, &f, press_exact(t, s, "Following"))
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Follow", .Button), "Follow again")
	run_jobs(s, app.Follow_Job)
	testing.expect_value(t, len(m.followed), 0)
}

// The Follow button fits its label, narrower than Following, and Share next
// to it stays put when it toggles.
@(test)
follow_button_fits_its_label :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	sidebar_mock(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	run_jobs(s, app.Playlists_Job, app.Liked_Ids_Job)
	mock_page(t, s, &f, 7)

	follow, ok := exact(s, "Follow", .Button)
	share, share_ok := exact(s, "Share", .Button)
	if !testing.expect(t, ok && share_ok, "Follow and Share") {
		return
	}
	library_frame(t, s, &f, press_exact(t, s, "Follow"))
	library_frame(t, s, &f)
	following, following_ok := exact(s, "Following", .Button)
	shared, shared_ok := exact(s, "Share", .Button)
	if !testing.expect(t, following_ok && shared_ok, "Following and Share") {
		return
	}
	testing.expectf(t, follow.frame.x == following.frame.x, "Follow at %v, Following at %v", follow.frame.x, following.frame.x)
	testing.expectf(t, follow.frame.z < following.frame.z, "Follow is %v wide, Following %v", follow.frame.z, following.frame.z)
	testing.expectf(t, share.frame.x == shared.frame.x, "Share at %v, then %v", share.frame.x, shared.frame.x)
	testing.expectf(t, following.frame.x + following.frame.z < shared.frame.x, "Following ends at %v, Share starts at %v", following.frame.x + following.frame.z, shared.frame.x)
}

// Follow, unfollow, follow pressed before TIDAL answers send one change,
// and unfollow, follow after it send the second only once the first is
// answered. The button ends Following, and so does TIDAL.
@(test)
quick_presses_end_followed :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	sidebar_mock(&m)
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	run_jobs(s, app.Playlists_Job, app.Liked_Ids_Job)
	mock_page(t, s, &f, 7)

	for label in ([]string{"Follow", "Following", "Follow"}) {
		library_frame(t, s, &f, press_exact(t, s, label))
		library_frame(t, s, &f)
	}
	queued := data_jobs(&s.data)
	testing.expect_value(t, len(queued), 1)
	for &job in queued {
		run_now(s, job)
	}
	testing.expect_value(t, len(data_jobs(&s.data)), 0)

	for label in ([]string{"Following", "Follow"}) {
		library_frame(t, s, &f, press_exact(t, s, label))
		library_frame(t, s, &f)
	}
	for _ in 0 ..< 2 {
		queued = data_jobs(&s.data)
		testing.expect_value(t, len(queued), 1)
		for &job in queued {
			run_now(s, job)
		}
	}
	testing.expect_value(t, len(data_jobs(&s.data)), 0)
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Following", .Button), "the button ends Following")
	testing.expect(t, slice.contains(m.followed[:], 7), "TIDAL ends with the artist followed")
	testing.expect_value(t, mock_count(&m, "POST /users/123/favorites/artists"), 2)
	testing.expect_value(t, mock_count(&m, "DELETE /users/123/favorites/artists/7"), 1)
}

// TIDAL refuses the follow: the button goes back to Follow.
@(test)
refused_follow_puts_the_button_back :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	sidebar_mock(&m)
	m.answers["/users/123/favorites/artists"] = {403, `{"status":403,"userMessage":"no"}`}
	s := library_state(false, &m)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	run_jobs(s, app.Playlists_Job, app.Liked_Ids_Job)
	mock_page(t, s, &f, 7)

	library_frame(t, s, &f, press_exact(t, s, "Follow"))
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Following", .Button), "Following at once")
	run_jobs(s, app.Follow_Job)
	library_frame(t, s, &f)
	testing.expect(t, enabled_exact(s, "Follow"), "Follow again once TIDAL refused")
	testing.expect_value(t, len(m.followed), 0)
}

// With the fake data the button follows locally.
@(test)
fake_follow :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	fake_page(t, s, &f)
	library_frame(t, s, &f, press_exact(t, s, "Follow"))
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Following", .Button), "Following")
	library_frame(t, s, &f, press_exact(t, s, "Following"))
	library_frame(t, s, &f)
	testing.expect(t, has(s, "Follow", .Button), "Follow")
	testing.expect_value(t, len(data_jobs(&s.data)), 0)
}
