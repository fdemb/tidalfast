// Liking a track: the set of liked track ids the hearts show, and how the
// set is fetched and toggled. With TIDALFAST_FAKE the set starts empty and
// toggling it only changes it locally.
package app

import "base:runtime"
import "core:log"

// Liked_Set is the liked tracks' ids, sorted ascending without duplicates,
// at the Liked Songs version they were fetched at. The ids live on the
// heap, and go at sign-out like everything else of the account's.
Liked_Set :: struct {
	ids:     [dynamic]i64, // sorted ascending, no duplicates
	version: List_Version, // the sidebar's Liked Songs version these came at
	loading: bool, // a Liked_Ids job is out
	edits:   [dynamic]Liked_Edit, // toggles made while it's out, for its result
	out:     map[i64]Heart_Out, // tracks with a heart change out to TIDAL
}

// Heart_Out is a track whose heart change is out to TIDAL. Only one change
// per track is out at a time: the workers could send two in either order,
// and the app couldn't tell which one TIDAL kept. A click while one is out
// only changes want, which goes once the change out is answered.
Heart_Out :: struct {
	confirmed: bool, // liked, as TIDAL last had it
	sent:      bool, // what the change out asks for
	want:      bool, // what the heart shows
}

Liked_Edit :: struct {
	id: i64,
	on: bool,
}

// liked_has says whether track id is liked, by binary search. Rows call it
// as they draw, a handful of times a frame.
liked_has :: proc(d: ^Data, id: i64) -> bool {
	lo, hi := 0, len(d.liked.ids)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case d.liked.ids[mid] < id:
			lo = mid + 1
		case d.liked.ids[mid] > id:
			hi = mid
		case:
			return true
		}
	}
	return false
}

// liked_put sets whether track id is liked, keeping the ids sorted. The
// ids grow on the heap: the set lasts as long as State does, and it's
// updated before the job that tells TIDAL goes out.
liked_put :: proc(d: ^Data, id: i64, on: bool) {
	if id == 0 && !d.fake {
		return
	}
	lo, hi := 0, len(d.liked.ids)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case d.liked.ids[mid] < id:
			lo = mid + 1
		case d.liked.ids[mid] > id:
			hi = mid
		case:
			if !on {
				ordered_remove(&d.liked.ids, mid)
			}
			return
		}
	}
	if on {
		if d.liked.ids == nil {
			d.liked.ids = make([dynamic]i64, 0, 64, runtime.heap_allocator())
		}
		inject_at(&d.liked.ids, lo, id)
	}
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
	delete(d.liked.ids)
	ids := make([dynamic]i64, 0, len(res.liked_ids), runtime.heap_allocator())
	append(&ids, ..res.liked_ids)
	d.liked.ids = ids
	d.liked.version = res.version
	// TIDAL may have answered before these reached it.
	for e in d.liked.edits {
		liked_put(d, e.id, e.on)
	}
	clear(&d.liked.edits)
	// A change that went out before the fetch did isn't among the edits.
	for id, h in d.liked.out {
		liked_put(d, id, h.want)
	}
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
	if h, ok := &d.liked.out[track]; ok {
		h.want = on
		liked_change(d, track, on)
		return
	}
	if d.liked.out == nil {
		d.liked.out = make(map[i64]Heart_Out, runtime.heap_allocator())
	}
	d.liked.out[track] = {confirmed = liked_has(d, track), sent = on, want = on}
	liked_change(d, track, on)
	push_job(d, {payload = Add_Track_Job{track = track, source = .Liked, remove = !on}})
}

// liked_answer takes TIDAL's answer to the heart change out for track, or
// took is false for a refusal or a change dropped before it went. It
// returns whether the heart's newer want went out in its place.
liked_answer :: proc(d: ^Data, track: i64, took: bool) -> (resent: bool) {
	h, ok := d.liked.out[track]
	if !ok {
		return false
	}
	if took {
		h.confirmed = h.sent
		// A fetch out may have listed the set before TIDAL took it.
		liked_change(d, track, h.want)
	} else {
		// Clicks since go too: the heart shows what TIDAL has.
		h.want = h.confirmed
		liked_change(d, track, h.want)
	}
	if h.want == h.confirmed {
		delete_key(&d.liked.out, track)
		return false
	}
	h.sent = h.want
	d.liked.out[track] = h
	push_job(d, {payload = Add_Track_Job{track = track, source = .Liked, remove = !h.sent}})
	return true
}

// liked_change sets whether track id is liked, and keeps the change for
// the result of a fetch that's out, which replays it over what TIDAL sent.
liked_change :: proc(d: ^Data, id: i64, on: bool) {
	liked_put(d, id, on)
	if d.liked.loading {
		if d.liked.edits == nil {
			d.liked.edits = make([dynamic]Liked_Edit, runtime.heap_allocator())
		}
		append(&d.liked.edits, Liked_Edit{id, on})
	}
}
