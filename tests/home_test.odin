package tidal_tests

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:testing"

import "../src/app"
import "../src/jobs"
import "../src/platform"
import "../src/tidal"
import "../src/ui"

@(private = "file")
artists_list :: proc(title: string, n: int) -> tidal.Item_List {
	items := make([]tidal.Item, n, context.temp_allocator)
	for &it, i in items {
		it = tidal.Artist{id = i64(i + 1), name = fmt.tprintf("Artist %d", i + 1), picture = "pic"}
	}
	return {title = title, items = items}
}

// A home page's lists become shelves of albums, playlists and artists:
// anything else goes, a list with nothing left goes, a mixed list keeps
// the kind of its first card, and shelves and cards are capped.
@(test)
home_page_maps_to_shelves :: proc(t: ^testing.T) {
	albums := make([]tidal.Item, app.SHELF_CARDS + 10, context.temp_allocator)
	albums[0] = tidal.Album{id = 0, name = "No id"}
	for i in 1 ..< len(albums) {
		albums[i] = tidal.Album{id = i64(i), name = fmt.tprintf("Album %d", i), cover = "cover", artists = {{id = 9, name = "Björk"}}}
	}
	cats := make([dynamic]tidal.Page_Category, context.temp_allocator)
	append(&cats, tidal.Item_List{title = "New albums", items = albums})
	append(&cats, tidal.Item_List{title = "Only tracks and mixes", items = {tidal.Track{id = 1}, tidal.Mix{id = "m"}}})
	append(&cats, tidal.Page_Links{title = "Genres"})
	append(&cats, tidal.Item_List{title = "Empty"})
	append(&cats, tidal.Item_List{title = "Mixed", items = {tidal.Mix{id = "m"}, tidal.Playlist{id = "p1", name = "One", num_tracks = 3}, tidal.Album{id = 4, name = "Not a playlist"}, tidal.Playlist{name = "No id"}, tidal.Playlist{id = "p2", name = "Two"}}})
	for i in 0 ..< 20 {
		append(&cats, artists_list(fmt.tprintf("Artists %d", i), 3))
	}

	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	shelves := app.home_shelves({categories = cats[:]}, vmem.arena_allocator(&arena))
	free_all(context.temp_allocator)

	if !testing.expect_value(t, len(shelves), app.HOME_SHELVES) {
		return
	}
	first := shelves[0]
	testing.expect_value(t, first.title, "New albums")
	testing.expect_value(t, first.source, app.Source.Album)
	testing.expect_value(t, len(first.items), app.SHELF_CARDS)
	testing.expect_value(t, first.items[0].id, i64(1))
	testing.expect_value(t, first.items[0].subtitle, "Björk")
	testing.expect_value(t, first.items[0].image, "cover")
	testing.expect_value(t, first.items[0].artists[0].id, i64(9))

	mixed := shelves[1]
	testing.expect_value(t, mixed.title, "Mixed")
	testing.expect_value(t, mixed.source, app.Source.Playlist)
	if testing.expect_value(t, len(mixed.items), 2) {
		testing.expect_value(t, mixed.items[0].uuid, "p1")
		testing.expect_value(t, mixed.items[0].subtitle, "Playlist · 3 songs")
		testing.expect_value(t, mixed.items[1].uuid, "p2")
		testing.expect_value(t, mixed.items[1].subtitle, "Playlist")
	}
	testing.expect_value(t, shelves[2].title, "Artists 0")
	testing.expect_value(t, shelves[2].source, app.Source.Artist)
	testing.expect_value(t, shelves[len(shelves) - 1].title, "Artists 9")
}

@(private = "file")
home_state :: proc(m: ^Mock) -> ^app.State {
	s := new(app.State)
	d := &s.data
	test_keychain(d)
	d.api = app.small(m.base_url)
	d.wake = proc "c" () {}
	app.session_open(d)
	sign_in(s)
	data_jobs(d)
	return s
}

@(private = "file")
home_state_free :: proc(s: ^app.State) {
	app.data_shutdown(s)
	test_state_free(s)
	free(s)
}

// home_job runs the queued Home job, and fails the test if there's none.
@(private = "file")
home_job :: proc(t: ^testing.T, s: ^app.State, loc := #caller_location) -> bool {
	for job in data_jobs(&s.data) {
		if _, ok := job.payload.(app.Home_Job); ok {
			run_now(s, job)
			return true
		}
	}
	testing.expect(t, false, "a Home job is queued", loc = loc)
	return false
}

// Home asks once for the v2 feed and shows its shelves; showing it again
// while they're fresh asks for nothing.
@(test)
home_fetches_the_feed :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	m.answers["/v2/home/feed/static"] = {200, `{"items":[` +
		`{"type":"HORIZONTAL_LIST","title":"For you","items":[{"type":"MIX","data":{"id":"m1"}},{"type":"PLAYLIST","data":{"uuid":"p1","title":"Mock Mix","numberOfTracks":3,"squareImage":"sq"}}]},` +
		`{"type":"TRACK_LIST","title":"Tracks","items":[{"type":"TRACK","data":{"id":5,"title":"t"}}]},` +
		`{"type":"HORIZONTAL_LIST","title":"Albums","items":[{"type":"ALBUM","data":{"id":12,"title":"Twelve","cover":"c","artists":[{"id":3,"name":"Three"}]}}]}]}`}
	s := home_state(&m)
	defer home_state_free(s)
	d := &s.data

	app.home_visit(s)
	app.home_want(d)
	if !home_job(t, s) {
		return
	}
	h := &d.home
	testing.expect_value(t, h.status, app.Home_Status.Ready)
	if testing.expect_value(t, len(h.shelves), 2) {
		testing.expect_value(t, h.shelves[0].title, "For you")
		testing.expect_value(t, h.shelves[0].items[0].uuid, "p1")
		testing.expect_value(t, h.shelves[1].items[0].name, "Twelve")
		testing.expect_value(t, h.shelves[1].items[0].subtitle, "Three")
	}
	app.home_visit(s)
	testing.expect_value(t, len(data_jobs(d)), 0)
}

// When the v2 feed fails, the legacy pages/home stands in. When both fail,
// Home says so, and Retry asks again.
@(test)
home_falls_back_then_fails :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	m.answers["/v2/home/feed/static"] = {500, `{"userMessage":"down"}`}
	m.answers["/pages/home"] = {200, `{"title":"Home","rows":[{"modules":[{"type":"ALBUM_LIST","title":"New albums","pagedList":{"items":[{"id":1,"title":"One","cover":"c"},{"id":2,"title":"Two","cover":"c"}]}}]}]}`}
	s := home_state(&m)
	defer home_state_free(s)
	d := &s.data
	h := &d.home

	app.home_visit(s)
	if !home_job(t, s) {
		return
	}
	testing.expect_value(t, h.status, app.Home_Status.Ready)
	if testing.expect_value(t, len(h.shelves), 1) {
		testing.expect_value(t, h.shelves[0].title, "New albums")
		testing.expect_value(t, len(h.shelves[0].items), 2)
	}

	app.home_clear(d)
	m.answers["/pages/home"] = {500, `{"userMessage":"down"}`}
	app.home_visit(s)
	if !home_job(t, s) {
		return
	}
	testing.expect_value(t, h.status, app.Home_Status.Failed)
	testing.expect(t, h.error.len > 0, "the error is kept")
	app.home_retry(d)
	testing.expect_value(t, h.status, app.Home_Status.Loading)
	queued, _ := jobs.pending(&d.queue)
	testing.expect_value(t, queued, 1)
}

@(private = "file")
home_node :: proc(s: ^app.State, label: string, role: platform.Access_Role) -> (platform.Access_Node, bool) {
	nodes, _ := ui.access_tree(&s.ui)
	for n in nodes {
		if n.role == role && string(n.label) == label {
			return n, true
		}
	}
	return {}, false
}

@(private = "file")
home_press :: proc(t: ^testing.T, s: ^app.State, label: string, loc := #caller_location) -> platform.Event {
	n, ok := home_node(s, label, .Button)
	testing.expectf(t, ok, "no button %q", label, loc = loc)
	return {kind = .Access_Press, target = n.id}
}

// With the fake data, Home in the sidebar shows the greeting, eight
// shortcuts and the shelves. A shortcut opens its playlist, a card its
// album, and Back comes back to Home.
@(test)
home_page_opens_from_the_sidebar :: proc(t: ^testing.T) {
	fonts: Fonts
	if !testing.expect(t, fonts_init(&fonts)) {
		return
	}
	defer fonts_destroy(&fonts)
	context.allocator = mem.arena_allocator(&fonts.arena)
	s := library_state(true)
	defer library_state_free(s)
	f := Frame{fonts = &fonts, size = {1100, 2400}}
	library_frame(t, s, &f)
	library_frame(t, s, &f, home_press(t, s, "Home"))
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, app.home_showing(s), "Home shows")
	library_frame(t, s, &f)
	testing.expect(t, !f.animating, "Home asks for no frames once it settles")
	_, greeted := access_node(s, "Good ")
	testing.expect(t, greeted, "the greeting")
	for i in 0 ..< 8 {
		_, ok := home_node(s, app.PLAYLISTS[i], .Button)
		testing.expectf(t, ok, "shortcut %d", i)
	}
	_, ninth := home_node(s, app.PLAYLISTS[8], .Button)
	testing.expect(t, !ninth, "eight shortcuts")
	for title in ([]string{"Recently played", "Playlists for you", "Artists you might like", "New albums"}) {
		_, ok := home_node(s, title, .List)
		testing.expectf(t, ok, "the %s shelf", title)
	}
	_, view_all := access_node(s, "View all")
	testing.expect(t, !view_all, "Home's shelves have no View all")

	library_frame(t, s, &f, home_press(t, s, app.PLAYLISTS[2]))
	library_frame(t, s, &f)
	testing.expect(t, !app.home_showing(s), "a shortcut leaves Home")
	testing.expect_value(t, s.library.playlist, 2)

	app.pending_set(s, app.Go_Back{})
	app.pending_apply(s)
	library_frame(t, s, &f)
	library_frame(t, s, &f)
	testing.expect(t, app.home_showing(s), "Back comes back to Home")

	album := s.data.home.shelves[0].items[0]
	library_frame(t, s, &f, home_press(t, s, fmt.tprintf("%s, %s", album.name, album.subtitle)))
	library_frame(t, s, &f)
	testing.expect(t, !app.home_showing(s), "a card leaves Home")
	testing.expect_value(t, app.view_title(s), album.name)
}
