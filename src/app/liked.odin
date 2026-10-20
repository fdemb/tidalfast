// Liking a track: the set of liked track ids the hearts show, and how the
// set is fetched and toggled. With TIDALFAST_FAKE the set starts empty and
// toggling it only changes it locally.
package app

import "core:log"

// Liked_Set is the liked tracks' ids, sorted ascending without duplicates,
// at the Liked Songs version they were fetched at. The ids live on the
// heap, and go at sign-out like everything else of the account's.
Liked_Set :: struct {
	ids:     [dynamic]i64, // sorted ascending, no duplicates
	version: List_Version, // the sidebar's Liked Songs version these came at
	loading: bool, // a Liked_Ids job is out
	edits:   [dynamic]Toggle_Edit, // toggles made while it's out, for its result
	out:     map[i64]Toggle_Out, // tracks with a heart change out to TIDAL
}

// liked_has says whether track id is liked. Rows call it as they draw, a
// handful of times a frame.
liked_has :: proc(d: ^Data, id: i64) -> bool {
	return ids_has(d.liked.ids[:], id)
}

// liked_put sets whether track id is liked. The set is updated before the
// job that tells TIDAL goes out.
liked_put :: proc(d: ^Data, id: i64, on: bool) {
	if id == 0 && !d.fake {
		return
	}
	ids_put(&d.liked.ids, id, on)
}

// liked_fetch fetches the whole set when the sidebar's version moved on
// from the one the set was taken at, or the followed artists, which come
// with it, aren't known yet, and no fetch is out. It runs after the
// sidebar comes from TIDAL, at sign-in and when it's refreshed later.
liked_fetch :: proc(d: ^Data) {
	if d.fake || d.liked.loading || !d.sidebar.loaded || d.sidebar.liked_count < 0 {
		return
	}
	v := List_Version{count = i64(d.sidebar.liked_count), newest = d.sidebar.liked_newest}
	if v == d.liked.version && d.followed.known {
		return
	}
	d.liked.loading = true
	push_job(d, {payload = Liked_Ids_Job{version = v}})
}

// liked_ids_result takes a Liked_Ids: the worker's ids and version, copied
// here. A failed fetch leaves the set as it is, older than the sidebar now
// says, so it goes again the next time the sidebar does.
liked_ids_result :: proc(d: ^Data, res: ^Result, failed: bool) {
	d.liked.loading = false
	if failed {
		clear(&d.liked.edits)
		if err, ok := res.err.?; ok {
			log.warnf("app: fetching the liked tracks failed: %v", err)
		}
		return
	}
	// The whole set goes: a track that came off liked since the set was
	// taken stays out this way too.
	ids, _ := res.payload.(Liked_Ids_Result)
	ids_replace(&d.liked.ids, ids.tracks, &d.liked.edits, d.liked.out)
	d.liked.version = ids.version
}

// liked_clear frees the set, at sign-out and shut down.
liked_clear :: proc(d: ^Data) {
	delete(d.liked.ids)
	delete(d.liked.edits)
	delete(d.liked.out)
	d.liked = {}
}

// liked_toggle flips the heart on a track, see liked_want. With the fake
// data it only flips. track is the TIDAL id, or with the fake data the
// row's key (see row_key).
liked_toggle :: proc(s: ^State, track: i64) {
	d := &s.data
	if track < 0 || (track == 0 && !d.fake) {
		return
	}
	on := !liked_has(d, track)
	if d.fake {
		liked_change(d, track, on)
		return
	}
	liked_want(d, track, on)
}

// liked_want sets the heart on track, from a click or a drop on Liked
// Songs. The heart shows it at once. It goes to TIDAL now, or if a change
// to the track is out, once liked_answer has that one's answer.
liked_want :: proc(d: ^Data, track: i64, on: bool) {
	send := toggle_want(&d.liked.out, track, on, liked_has(d, track))
	liked_change(d, track, on)
	if send {
		push_job(d, {payload = Add_Track_Job{track = track, source = .Liked, remove = !on}})
	}
}

// liked_answer takes TIDAL's answer to the heart change out for track, see
// toggle_answer. It returns whether the heart's newer want went out in its
// place.
liked_answer :: proc(d: ^Data, track: i64, took: bool) -> (resent: bool) {
	want, resend, found := toggle_answer(&d.liked.out, track, took)
	if !found {
		return false
	}
	// Even after a success: a fetch out may have listed the set before
	// TIDAL took the change.
	liked_change(d, track, want)
	if resend {
		push_job(d, {payload = Add_Track_Job{track = track, source = .Liked, remove = !want}})
	}
	return resend
}

// liked_change sets whether track id is liked, and keeps the change for
// the result of a fetch that's out, which replays it over what TIDAL sent.
liked_change :: proc(d: ^Data, id: i64, on: bool) {
	liked_put(d, id, on)
	edit_keep(d, &d.liked.edits, id, on)
}
