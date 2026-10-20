// Following artists: the set of followed artist ids the Follow buttons
// show. It comes with the liked tracks' ids, in the one favorites/ids
// answer a Liked_Ids job reads (see liked_fetch), and changes on a press
// at once, with one change per artist out to TIDAL at a time. With
// TIDALFAST_FAKE the set starts empty and a press only changes it locally.
package app

import "core:log"

// Followed_Set is the followed artists' ids, sorted ascending without
// duplicates, on the heap until sign-out. Until the first fetch lands it
// isn't known, and the buttons wait: an artist it lacks may be followed.
Followed_Set :: struct {
	ids:   [dynamic]i64,
	known: bool,
	edits: [dynamic]Toggle_Edit, // changes made while a Liked_Ids job is out, for its result
	out:   map[i64]Toggle_Out, // artists with a follow change out to TIDAL
}

// Follow_Job follows an artist on TIDAL, or unfollows them.
Follow_Job :: struct {
	artist: i64,
	on:     bool,
}

// followed_has says whether artist is followed.
followed_has :: proc(d: ^Data, artist: i64) -> bool {
	return ids_has(d.followed.ids[:], artist)
}

// followed_change sets whether artist is followed, and keeps the change for
// the result of a fetch that's out, which replays it over what TIDAL sent.
followed_change :: proc(d: ^Data, artist: i64, on: bool) {
	ids_put(&d.followed.ids, artist, on)
	edit_keep(d, &d.followed.edits, artist, on)
}

// follow_toggle flips the follow on artist, from the page's button. The
// button shows it at once. It goes to TIDAL now, or if a change to the
// artist is out, once follow_answer has that one's answer. With the fake
// data it only flips, and artist is the page's key (see artist_fake_key).
follow_toggle :: proc(s: ^State, artist: i64) {
	d := &s.data
	on := !followed_has(d, artist)
	if d.fake {
		ids_put(&d.followed.ids, artist, on)
		return
	}
	if artist <= 0 || !d.followed.known {
		return
	}
	send := toggle_want(&d.followed.out, artist, on, !on)
	followed_change(d, artist, on)
	if send {
		push_job(d, {payload = Follow_Job{artist = artist, on = on}})
	}
}

// follow_answer takes TIDAL's answer to the follow change out for artist,
// see toggle_answer.
follow_answer :: proc(d: ^Data, artist: i64, took: bool) {
	want, resend, found := toggle_answer(&d.followed.out, artist, took)
	if !found {
		return
	}
	// Even after a success: a fetch out may have listed the set before
	// TIDAL took the change.
	followed_change(d, artist, want)
	if resend {
		push_job(d, {payload = Follow_Job{artist = artist, on = want}})
	}
}

// follow_result takes a Follow job's answer.
follow_result :: proc(d: ^Data, res: ^Result, job: Follow_Job, failed: bool) {
	if failed {
		log.warnf("app: following or unfollowing an artist failed: %v", res.err)
		d.message = res.message
	}
	follow_answer(d, job.artist, !failed)
}

// followed_ids_result takes the followed artists of a Liked_Ids result. A
// failed fetch leaves the set as it is, known or not, and the next one
// goes when the sidebar's does.
followed_ids_result :: proc(d: ^Data, res: ^Result, failed: bool) {
	f := &d.followed
	if failed {
		clear(&f.edits)
		return
	}
	ids, _ := res.payload.(Liked_Ids_Result)
	ids_replace(&f.ids, ids.artists, &f.edits, f.out)
	f.known = true
}

// followed_clear frees the set, at sign-out and shut down.
followed_clear :: proc(d: ^Data) {
	delete(d.followed.ids)
	delete(d.followed.edits)
	delete(d.followed.out)
	d.followed = {}
}
