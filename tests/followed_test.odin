package tidal_tests

// The followed artists the Follow button shows: one change per artist out
// to TIDAL, and what a fetch of the set does to changes made around it.

import "core:testing"

import app "../src/app"
import "../src/jobs"
import "../src/tidal"

// follow_state is a signed-in State whose followed set came with followed
// in it. Its jobs wait in the queue until a test answers them.
@(private = "file")
follow_state :: proc(followed: ..i64) -> ^app.State {
	s := new(app.State)
	test_keychain(&s.data)
	app.session_open(&s.data)
	sign_in(s)
	data_jobs(&s.data)
	fetch_lands(s, ..followed)
	return s
}

@(private = "file")
follow_state_free :: proc(s: ^app.State) {
	app.data_shutdown(s)
	test_state_free(s)
	free(s)
}

// fetch_lands hands the app a Liked_Ids result that lists followed.
@(private = "file")
fetch_lands :: proc(s: ^app.State, followed: ..i64) {
	res := app.Result {
		job = {auth = s.data.auth_gen, payload = app.Liked_Ids_Job{}},
		followed = followed,
	}
	app.handle_result(s, &res, 0)
}

// follow_jobs empties the queue and returns the follow changes in it.
@(private = "file")
follow_jobs :: proc(d: ^app.Data) -> [dynamic]app.Job {
	out := make([dynamic]app.Job, context.temp_allocator)
	for job in data_jobs(d) {
		if _, follow := job.payload.(app.Follow_Job); follow {
			append(&out, job)
		}
	}
	return out
}

// answer hands the app TIDAL's answer to a follow change: taken, or with
// took false refused.
@(private = "file")
answer :: proc(s: ^app.State, job: app.Job, took: bool) {
	res := app.Result {
		job = job,
	}
	if !took {
		res.err = tidal.Error_Kind.Network
	}
	app.handle_result(s, &res, 0)
}

// Follow, unfollow, follow before TIDAL answers: one change is out at a
// time, and once the first is taken the button already says what TIDAL
// has, so nothing more goes. Unfollow, follow then sends the follow once
// the unfollow is taken.
@(test)
one_follow_change_out_at_a_time :: proc(t: ^testing.T) {
	s := follow_state()
	defer follow_state_free(s)
	d := &s.data

	app.follow_toggle(s, 7)
	app.follow_toggle(s, 7)
	app.follow_toggle(s, 7)
	sent := follow_jobs(d)
	if !testing.expect_value(t, len(sent), 1) {
		return
	}
	testing.expect(t, sent[0].payload.(app.Follow_Job).on)
	answer(s, sent[0], true)
	testing.expect_value(t, len(follow_jobs(d)), 0)
	testing.expect(t, app.followed_has(d, 7))

	app.follow_toggle(s, 7)
	app.follow_toggle(s, 7)
	sent = follow_jobs(d)
	if !testing.expect_value(t, len(sent), 1) {
		return
	}
	testing.expect(t, !sent[0].payload.(app.Follow_Job).on)
	answer(s, sent[0], true)
	sent = follow_jobs(d)
	if !testing.expect_value(t, len(sent), 1) {
		return
	}
	testing.expect(t, sent[0].payload.(app.Follow_Job).on)
	answer(s, sent[0], true)
	testing.expect_value(t, len(follow_jobs(d)), 0)
	testing.expect(t, app.followed_has(d, 7))
}

// TIDAL refuses a follow, with an unfollow pressed after it: the button
// goes back to what TIDAL has and nothing more goes.
@(test)
refused_follow_goes_back :: proc(t: ^testing.T) {
	s := follow_state()
	defer follow_state_free(s)
	d := &s.data

	app.follow_toggle(s, 7)
	testing.expect(t, app.followed_has(d, 7))
	app.follow_toggle(s, 7)
	app.follow_toggle(s, 7)
	sent := follow_jobs(d)
	testing.expect_value(t, len(sent), 1)
	for job in sent {
		answer(s, job, false)
	}
	testing.expect(t, !app.followed_has(d, 7))
	testing.expect_value(t, len(follow_jobs(d)), 0)
}

// A follow whose job is pushed out of a full hold list never reached
// TIDAL, so its button goes back, and a fetch out doesn't bring it back.
@(test)
follow_dropped_from_the_hold_list :: proc(t: ^testing.T) {
	s := follow_state()
	defer follow_state_free(s)
	d := &s.data
	for jobs.push(&d.queue, app.Job{payload = app.Cover_Job{}}, app.PRIORITY_COVER) {}

	d.liked.loading = true
	for artist in 1 ..= app.HELD_JOBS + 1 {
		app.follow_toggle(s, i64(artist))
	}
	testing.expect(t, !app.followed_has(d, 1), "the oldest follow was dropped and its button put back")
	testing.expect(t, app.followed_has(d, 2))
	fetch_lands(s)
	testing.expect(t, !app.followed_has(d, 1), "the fetch didn't replay the dropped follow")
	testing.expect(t, app.followed_has(d, i64(app.HELD_JOBS + 1)))
}

// A fetch that lists the set before TIDAL took a follow lands after it:
// the follow stays, whether TIDAL answered while the fetch was out, or the
// follow is still out when the fetch lands, pressed before or during it.
@(test)
follow_stays_through_an_older_fetch :: proc(t: ^testing.T) {
	s := follow_state(5)
	defer follow_state_free(s)
	d := &s.data

	app.follow_toggle(s, 7)
	job := follow_jobs(d)[0]
	d.liked.loading = true
	answer(s, job, true)
	fetch_lands(s, 5)
	testing.expect(t, app.followed_has(d, 7), "answered while the fetch was out")

	app.follow_toggle(s, 8)
	d.liked.loading = true
	fetch_lands(s, 5)
	testing.expect(t, app.followed_has(d, 8), "pressed before the fetch, still out when it lands")

	d.liked.loading = true
	app.follow_toggle(s, 9)
	fetch_lands(s, 5)
	testing.expect(t, app.followed_has(d, 9), "pressed during the fetch, still out when it lands")
	testing.expect(t, app.followed_has(d, 5))
}

// Signing out forgets the followed artists, and the answer to a follow out
// then does nothing.
@(test)
sign_out_clears_the_followed :: proc(t: ^testing.T) {
	s := follow_state(5)
	defer follow_state_free(s)
	d := &s.data

	app.follow_toggle(s, 7)
	job := follow_jobs(d)[0]
	app.sign_out(s, "")
	testing.expect(t, !app.followed_has(d, 5))
	testing.expect(t, !app.followed_has(d, 7))
	testing.expect(t, !d.followed.known)
	answer(s, job, true)
	testing.expect(t, !app.followed_has(d, 7))
	app.follow_toggle(s, 7)
	testing.expect(t, !app.followed_has(d, 7), "no button takes a press before the set is known")
	testing.expect_value(t, len(follow_jobs(d)), 0)
}

// A fetch that fails while a follow is out leaves the follow showing and
// out, and the set known: its answer then settles it as usual.
@(test)
follow_out_through_a_failed_fetch :: proc(t: ^testing.T) {
	s := follow_state()
	defer follow_state_free(s)
	d := &s.data

	app.follow_toggle(s, 7)
	sent := follow_jobs(d)
	d.liked.loading = true
	failed := app.Result {
		job = {auth = d.auth_gen, payload = app.Liked_Ids_Job{}},
		err = tidal.Error_Kind.Network,
	}
	app.handle_result(s, &failed, 0)
	testing.expect(t, d.followed.known)
	testing.expect(t, app.followed_has(d, 7), "the follow still shows")
	answer(s, sent[0], true)
	testing.expect(t, app.followed_has(d, 7))
	testing.expect_value(t, len(follow_jobs(d)), 0)
}
