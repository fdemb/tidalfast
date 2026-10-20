package app

// What the hearts (liked.odin) and the Follow buttons (followed.odin)
// share: a sorted set of ids, the changes made while a Liked_Ids job is
// out, and one change per id out to TIDAL at a time.

import "base:runtime"
import "core:slice"

// Toggle_Out is an id whose change is out to TIDAL. Only one change per id
// is out at a time: the workers could send two in either order, and the app
// couldn't tell which one TIDAL kept. A click while one is out only changes
// want, which goes once the change out is answered.
Toggle_Out :: struct {
	confirmed: bool, // on, as TIDAL last had it
	sent:      bool, // what the change out asks for
	want:      bool, // what the heart or button shows
}

// Toggle_Edit is a change made while a Liked_Ids job is out. Its result
// replays the change over what TIDAL sent.
Toggle_Edit :: struct {
	id: i64,
	on: bool,
}

// ids_has says whether id is in ids, sorted ascending.
ids_has :: proc(ids: []i64, id: i64) -> bool {
	_, found := slice.binary_search(ids, id)
	return found
}

// ids_put sets whether id is in ids, keeping them sorted ascending without
// duplicates. The ids grow on the heap.
ids_put :: proc(ids: ^[dynamic]i64, id: i64, on: bool) {
	at, found := slice.binary_search(ids[:], id)
	switch {
	case on && !found:
		if ids^ == nil {
			ids^ = make([dynamic]i64, 0, 64, runtime.heap_allocator())
		}
		inject_at(ids, at, id)
	case !on && found:
		ordered_remove(ids, at)
	}
}

// ids_replace makes ids a copy of fetched, then puts back what TIDAL may
// not have had when it listed them: the edits made while the fetch was out,
// and the changes still out, some of which went before it did.
ids_replace :: proc(ids: ^[dynamic]i64, fetched: []i64, edits: ^[dynamic]Toggle_Edit, out: map[i64]Toggle_Out) {
	delete(ids^)
	ids^ = make([dynamic]i64, 0, len(fetched), runtime.heap_allocator())
	append(ids, ..fetched)
	for e in edits {
		ids_put(ids, e.id, e.on)
	}
	clear(edits)
	for id, o in out {
		ids_put(ids, id, o.want)
	}
}

// edit_keep keeps a change for the result of the Liked_Ids job out, if one
// is.
edit_keep :: proc(d: ^Data, edits: ^[dynamic]Toggle_Edit, id: i64, on: bool) {
	if !d.liked.loading {
		return
	}
	if edits^ == nil {
		edits^ = make([dynamic]Toggle_Edit, runtime.heap_allocator())
	}
	append(edits, Toggle_Edit{id, on})
}

// toggle_want records that id should be on, from a click; current is
// whether it is now. It returns true when no change for id is out, so the
// caller sends this one. Otherwise it goes once toggle_answer has the
// answer to the one out.
toggle_want :: proc(out: ^map[i64]Toggle_Out, id: i64, on, current: bool) -> (send: bool) {
	if o, ok := &out[id]; ok {
		o.want = on
		return false
	}
	if out^ == nil {
		out^ = make(map[i64]Toggle_Out, runtime.heap_allocator())
	}
	out[id] = {confirmed = current, sent = on, want = on}
	return true
}

// toggle_answer takes TIDAL's answer to the change out for id, or took is
// false for a refusal or a change dropped before it went. A refusal takes
// the clicks since back too, so the heart or button shows what TIDAL has.
// found is false when no change was out. Otherwise want is what to show,
// and resend says it isn't what TIDAL has, so the caller sends it as the
// next change. When it is, id is no longer out.
toggle_answer :: proc(out: ^map[i64]Toggle_Out, id: i64, took: bool) -> (want, resend, found: bool) {
	o, ok := &out[id]
	if !ok {
		return
	}
	if took {
		o.confirmed = o.sent
	} else {
		o.want = o.confirmed
	}
	want = o.want
	if o.want == o.confirmed {
		delete_key(out, id)
		return want, false, true
	}
	o.sent = o.want
	return want, true, true
}
