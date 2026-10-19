package tidal_tests

import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"

import "../src/app"
import "../src/cover"
import "../src/jobs"

// A State whose session talks to the mock, with a keychain in memory.
// Workers aren't started.
@(private = "file")
artist_state :: proc(m: ^Mock) -> ^app.State {
	s := new(app.State)
	d := &s.data
	test_keychain(d)
	if m != nil {
		d.api = app.small(m.base_url)
	}
	d.wake = proc "c" () {}
	app.session_open(d)
	return s
}

@(private = "file")
artist_state_free :: proc(s: ^app.State) {
	app.data_shutdown(s)
	test_state_free(s)
	free(s)
}

// artist_jobs empties the queue and returns the Artist jobs in it.
@(private = "file")
artist_jobs :: proc(d: ^app.Data) -> [dynamic]app.Job {
	out := make([dynamic]app.Job, context.temp_allocator)
	for job in data_jobs(d) {
		if _, ok := job.payload.(app.Artist_Job); ok {
			append(&out, job)
		}
	}
	return out
}

@(private = "file")
visit :: proc(s: ^app.State, id: i64) -> ^app.Artist_Page {
	page := app.artist_visit(s, id, {}, {})
	app.artist_want(&s.data, page)
	return page
}

@(private = "file")
part_ready :: proc(page: ^app.Artist_Page, part: app.Artist_Part) -> bool {
	_, ok := page.parts[part].(app.Artist_Ready)
	return ok
}

@(private = "file")
part_waiting :: proc(page: ^app.Artist_Page, part: app.Artist_Part) -> bool {
	_, ok := page.parts[part].(app.Artist_Waiting)
	return ok
}

@(private = "file")
part_failed :: proc(page: ^app.Artist_Page, part: app.Artist_Part) -> bool {
	_, ok := page.parts[part].(app.Artist_Failed)
	return ok
}

@(private = "file")
bio_of :: proc(page: ^app.Artist_Page) -> string {
	ready, ok := page.parts[.Bio].(app.Artist_Ready)
	if !ok {
		return ""
	}
	return ready.content.(app.Artist_Bio).text
}

@(private = "file")
cards_of :: proc(page: ^app.Artist_Page, part: app.Artist_Part) -> []app.Found {
	ready, ok := page.parts[part].(app.Artist_Ready)
	if !ok {
		return nil
	}
	return ready.content.(app.Artist_Cards).items
}

// An artist page's parts come and fail on their own: with the biography
// late and the albums failing, the rest show, and a later visit asks only
// for the albums again.
@(test)
artist_parts_arrive_independently :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	m.answers["/artists/7/albums"] = {500, `{"userMessage":"down"}`}
	s := artist_state(&m)
	defer artist_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)

	page := visit(s, 7)
	bio: app.Job
	sent := 0
	for job in artist_jobs(d) {
		if job.payload.(app.Artist_Job).part == .Bio {
			bio = job
			continue
		}
		run_now(s, job)
		sent += 1
	}
	testing.expect_value(t, sent, len(app.Artist_Part) - 1)
	for part in ([]app.Artist_Part{.Info, .Singles, .Appears, .Similar}) {
		testing.expectf(t, part_ready(page, part), "%v is in", part)
	}
	testing.expect(t, part_failed(page, .Albums), "the albums failed")
	testing.expect(t, part_waiting(page, .Bio), "the biography is still on its way")
	testing.expect_value(t, app.small_str(&page.name), "Artist 7")
	testing.expect_value(t, len(cards_of(page, .Similar)), 3)

	run_now(s, bio)
	testing.expect_value(t, bio_of(page), "Artist 7 plays with Artist 8.\nSecond line.")
	testing.expect(t, part_failed(page, .Albums), "the albums stay failed until the page is opened again")

	delete_key(&m.answers, "/artists/7/albums")
	page = visit(s, 7)
	again := artist_jobs(d)
	if !testing.expect_value(t, len(again), 1) {
		return
	}
	testing.expect_value(t, again[0].payload.(app.Artist_Job).part, app.Artist_Part.Albums)
	run_now(s, again[0])
	testing.expect_value(t, len(cards_of(page, .Albums)), 9)
	testing.expect_value(t, len(artist_jobs(d)), 0)
	app.artist_want(d, page)
	testing.expect_value(t, len(artist_jobs(d)), 0)
}

// A shelf longer than a page is asked for page by page until a short one.
@(test)
artist_albums_page_until_short :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := artist_state(&m)
	defer artist_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)

	page := visit(s, 1)
	for job in artist_jobs(d) {
		if job.payload.(app.Artist_Job).part == .Albums {
			run_now(s, job)
		}
	}
	cards := cards_of(page, .Albums)
	if !testing.expect_value(t, len(cards), MOCK_ARTIST_ALBUMS) {
		return
	}
	testing.expect_value(t, cards[0].name, "Album 1000")
	testing.expect_value(t, cards[MOCK_ARTIST_ALBUMS - 1].name, "Album 1072")
	testing.expect_value(t, cards[0].subtitle, "2020 · Album")
	testing.expect_value(t, cards[0].artist, "Artist 1")
	offsets := make([dynamic]string, context.temp_allocator)
	for r in m.requests {
		if strings.has_prefix(r, "GET /artists/1/albums") {
			_, _, query := strings.partition(r, "offset=")
			offset, _, _ := strings.partition(query, "&")
			append(&offsets, offset)
		}
	}
	slice.sort(offsets[:])
	testing.expect(t, slice.equal(offsets[:], []string{"0", "50"}), "two pages, from 0 and 50")
}

// An answer for a page that was evicted and opened again is dropped, and
// the new page fills from its own.
@(test)
artist_old_answer_after_reopen_is_dropped :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := artist_state(&m)
	defer artist_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)

	visit(s, 1)
	old := artist_jobs(d)
	for id in 2 ..= app.ARTIST_CACHE + 1 {
		visit(s, i64(id))
	}
	artist_jobs(d)
	testing.expect(t, app.artist_find(d, 1) == nil, "the first page was evicted")

	page := visit(s, 1)
	fresh := artist_jobs(d)
	for job in old {
		run_now(s, job)
	}
	for part in app.Artist_Part {
		testing.expectf(t, part_waiting(page, part), "%v still waits for its own answer", part)
	}
	for job in fresh {
		run_now(s, job)
	}
	for part in app.Artist_Part {
		testing.expectf(t, part_ready(page, part), "%v is in", part)
	}
	testing.expect_value(t, len(cards_of(page, .Albums)), MOCK_ARTIST_ALBUMS)
}

// Artist jobs filling the hold list push each other out instead of ending
// the app, and a part pushed out is asked for again by the next
// artist_want, once each.
@(test)
artist_jobs_on_a_full_hold_list :: proc(t: ^testing.T) {
	s := artist_state(nil)
	defer artist_state_free(s)
	d := &s.data
	for jobs.push(&d.queue, app.Job{payload = app.Cover_Job{}}, app.PRIORITY_COVER) {}
	sign_in(s)

	PAGES :: 4
	for id in 1 ..= PAGES {
		visit(s, i64(id))
	}
	dropped := 0
	for id in 1 ..= PAGES {
		page := app.artist_find(d, i64(id))
		for part in app.Artist_Part {
			if page.parts[part] == nil {
				dropped += 1
			}
		}
	}
	testing.expect(t, dropped > 0, "the hold list was full")

	for _ in 0 ..< 64 {
		jobs.try_pop(&d.queue)
	}
	app.data_retry(d)
	for id in 1 ..= PAGES {
		app.artist_want(d, app.artist_find(d, i64(id)))
	}
	asked := make(map[app.Artist_Job]int, context.temp_allocator)
	for job in artist_jobs(d) {
		asked[job.payload.(app.Artist_Job)] += 1
	}
	testing.expect_value(t, len(asked), PAGES * len(app.Artist_Part))
	for job, n in asked {
		testing.expectf(t, n == 1, "%v asked for once, not %d times", job, n)
	}
	for id in 1 ..= PAGES {
		page := app.artist_find(d, i64(id))
		for part in app.Artist_Part {
			testing.expectf(t, part_waiting(page, part), "artist %d's %v is out", id, part)
		}
	}
}

// After a sign-out no page of the account that ended shows again, even
// when an answer for it comes late.
@(test)
artist_page_gone_after_sign_out :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := artist_state(&m)
	defer artist_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)

	visit(s, 7)
	out := artist_jobs(d)
	run_now(s, out[0])
	testing.expect(t, app.artist_find(d, 7) != nil)
	app.account_end(s)
	for job in out[1:] {
		run_now(s, job)
	}
	testing.expect(t, app.artist_find(d, 7) == nil, "the page went with the account")
}

// A page keeps its parts' strings in the arenas their results came in,
// after the results are freed.
@(test)
artist_page_owns_its_memory :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := artist_state(&m)
	defer artist_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)

	page := visit(s, 7)
	for job in artist_jobs(d) {
		run_now(s, job)
	}
	testing.expect_value(t, bio_of(page), "Artist 7 plays with Artist 8.\nSecond line.")
	albums := cards_of(page, .Albums)
	if testing.expect(t, len(albums) > 0) {
		testing.expect_value(t, albums[0].name, "Album 7000")
	}
}

// TIDAL answers 404 for an artist without a biography: an empty one, not
// a part that failed.
@(test)
artist_without_bio :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	m.answers["/artists/7/bio"] = {404, `{"status":404,"subStatus":2001,"userMessage":"Biography not found"}`}
	s := artist_state(&m)
	defer artist_state_free(s)
	d := &s.data
	sign_in(s)
	data_jobs(d)

	page := visit(s, 7)
	for job in artist_jobs(d) {
		run_now(s, job)
	}
	testing.expect(t, part_ready(page, .Bio), "no biography is a biography")
	testing.expect_value(t, bio_of(page), "")
}

// With the fake data a visit fills the page from the fake rows at once,
// with nothing sent.
@(test)
artist_fake_page :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	s := new(app.State)
	defer artist_state_free(s)
	s.data.fake = true
	s.data.account = .Fake
	s.rows = app.make_rows()

	at := 42
	page := visit(s, app.artist_fake_key(at))
	queued, _ := jobs.pending(&s.data.queue)
	testing.expect_value(t, queued, 0)
	testing.expect_value(t, app.small_str(&page.name), s.rows[at].artist)
	for part in app.Artist_Part {
		testing.expectf(t, part_ready(page, part), "%v is in", part)
	}
	testing.expect(t, strings.has_prefix(bio_of(page), s.rows[at].artist), "the biography names the artist")
	albums := len(cards_of(page, .Albums)) + len(cards_of(page, .Singles))
	testing.expect(t, albums > 0, "the artist has albums")
	for f in cards_of(page, .Albums) {
		testing.expect_value(t, s.rows[f.id].artist, s.rows[at].artist)
	}
}

@(test)
clean_bio_keeps_the_text :: proc(t: ^testing.T) {
	clean :: proc(bio: string) -> string {
		return app.clean_bio(bio, context.temp_allocator)
	}
	testing.expect_value(t, clean(`Hi [wimpLink artistId="1"]Name[/wimpLink] and [wimpLink albumId="2"]Album[/wimpLink].`), "Hi Name and Album.")
	testing.expect_value(t, clean("a<br/>b<br />c<br>d"), "a\nb\nc\nd")
	testing.expect_value(t, clean(`start [wimpLink artistId="3" never closes`), `start [wimpLink artistId="3" never closes`)
	testing.expect_value(t, clean("<br"), "<br")
	testing.expect_value(t, clean("Björk [wimpLink artistId=\"4\"]Sigur Rós[/wimpLink]"), "Björk Sigur Rós")
}

// Artist pictures come only in the sizes TIDAL serves for artists.
@(test)
artist_picture_sizes :: proc(t: ^testing.T) {
	sizes := []int{160, 320, 480, 750}
	for scale in ([]f32{1, 2, 3}) {
		for points := f32(1); points < 1000; points += 7 {
			size := cover.pick_size(.Artist, points, scale)
			testing.expectf(t, slice.contains(sizes, size), "%v pt at %vx picked %d", points, scale, size)
		}
	}
	testing.expect_value(t, cover.pick_size(.Artist, 40, 2), 160)
	testing.expect_value(t, cover.pick_size(.Artist, 300, 2), 750)
}
