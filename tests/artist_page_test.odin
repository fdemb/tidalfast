package tidal_tests

import "core:fmt"
import "core:mem"
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
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
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
	library_frame(t, s, &f, key(.F, {ui.PRIMARY}))
	library_frame(t, s, &f, type_text(&f, "Jóga"))
	library_frame(t, s, &f, dt = 1)
	library_frame(t, s, &f)
	testing.expect(t, !page_showing(s), "the results in place of the page")
	testing.expect(t, has(s, "Results for “Jóga”", .Static_Text), "the results")
	testing.expect(t, !has(s, name, .Static_Text) || strings.contains(name, "Jóga"), "not the artist's name")
}


