// Following artists: the set of followed artist ids the Follow buttons
// show. It comes with the liked tracks' ids, in the one favorites/ids
// answer a Liked_Ids job reads (see liked_fetch), and changes on a press
// at once, with one change per artist out to TIDAL at a time. With
// TIDALFAST_FAKE the set starts empty and a press only changes it locally.
package app

import "base:runtime"
import "core:log"
import "core:slice"

// Followed_Set is the followed artists' ids, sorted ascending without
// duplicates, on the heap until sign-out. Until the first fetch lands it
// isn't known, and the buttons wait: an artist it lacks may be followed.
Followed_Set :: struct {
	ids:   [dynamic]i64,
	known: bool,
	edits: [dynamic]Liked_Edit, // changes made while a Liked_Ids job is out, for its result
	out:   map[i64]Follow_Out, // artists with a follow change out to TIDAL
}

// Follow_Out is an artist whose follow change is out to TIDAL. Only one
// change per artist is out at a time: the workers could send two in either
// order, and the app couldn't tell which one TIDAL kept. A press while one
// is out only changes want, which goes once the change out is answered.
Follow_Out :: struct {
	confirmed: bool, // followed, as TIDAL last had it
	sent:      bool, // what the change out asks for
	want:      bool, // what the button shows
}

// Follow_Job follows an artist on TIDAL, or unfollows them.
Follow_Job :: struct {
	artist: i64,
	on:     bool,
}

// followed_has says whether artist is followed.
followed_has :: proc(d: ^Data, artist: i64) -> bool {
	_, found := slice.binary_search(d.followed.ids[:], artist)
	return found
}

// followed_put sets whether artist is followed, keeping the ids sorted.
followed_put :: proc(d: ^Data, artist: i64, on: bool) {
	f := &d.followed
	at, found := slice.binary_search(f.ids[:], artist)
	switch {
	case on && !found:
		if f.ids == nil {
			f.ids = make([dynamic]i64, 0, 16, runtime.heap_allocator())
		}
		inject_at(&f.ids, at, artist)
	case !on && found:
		ordered_remove(&f.ids, at)
	}
}

// followed_change is followed_put that keeps the change for the result of
// a fetch that's out, which replays it over what TIDAL sent.
followed_change :: proc(d: ^Data, artist: i64, on: bool) {
	followed_put(d, artist, on)
	if d.liked.loading {
		if d.followed.edits == nil {
			d.followed.edits = make([dynamic]Liked_Edit, runtime.heap_allocator())
		}
		append(&d.followed.edits, Liked_Edit{artist, on})
	}
}

// follow_toggle flips the follow on artist, from the page's button. The
// button shows it at once. It goes to TIDAL now, or if a change to the
// artist is out, once follow_answer has that one's answer. With the fake
// data it only flips, and artist is the page's key (see artist_fake_key).
follow_toggle :: proc(s: ^State, artist: i64) {
	d := &s.data
	on := !followed_has(d, artist)
	if d.fake {
		followed_put(d, artist, on)
		return
	}
	if artist <= 0 || !d.followed.known {
		return
	}
	if o, ok := &d.followed.out[artist]; ok {
		o.want = on
		followed_change(d, artist, on)
		return
	}
	if d.followed.out == nil {
		d.followed.out = make(map[i64]Follow_Out, runtime.heap_allocator())
	}
	d.followed.out[artist] = {confirmed = !on, sent = on, want = on}
	followed_change(d, artist, on)
	push_job(d, {payload = Follow_Job{artist = artist, on = on}})
}

// follow_answer takes TIDAL's answer to the follow change out for artist,
// or took is false for a refusal or a change dropped before it went. A
// refusal takes the presses since back too, so the button shows what
// TIDAL has; after a success the button's newer want goes out.
follow_answer :: proc(d: ^Data, artist: i64, took: bool) {
	o, ok := d.followed.out[artist]
	if !ok {
		return
	}
	if took {
		o.confirmed = o.sent
	} else {
		o.want = o.confirmed
	}
	// Even after a success: a fetch out may have listed the set before
	// TIDAL took the change.
	followed_change(d, artist, o.want)
	if o.want == o.confirmed {
		delete_key(&d.followed.out, artist)
		return
	}
	o.sent = o.want
	d.followed.out[artist] = o
	push_job(d, {payload = Follow_Job{artist = artist, on = o.sent}})
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
	delete(f.ids)
	f.ids = make([dynamic]i64, 0, len(res.followed), runtime.heap_allocator())
	append(&f.ids, ..res.followed)
	f.known = true
	for e in f.edits {
		followed_put(d, e.id, e.on)
	}
	clear(&f.edits)
	// A change that went out before the fetch did isn't among the edits.
	for artist, o in f.out {
		followed_put(d, artist, o.want)
	}
}

// followed_clear frees the set, at sign-out and shut down.
followed_clear :: proc(d: ^Data) {
	delete(d.followed.ids)
	delete(d.followed.edits)
	delete(d.followed.out)
	d.followed = {}
}
