package audio

import "core:math/rand"
import "core:slice"

// What the play queue needs to know about each entry to decide what comes
// next and which ReplayGain to use. The app keeps the rest.
Queue_Entry :: struct {
	id:        i64, // TIDAL track id, 0 when the entry can't be streamed
	album_id:  i64,
	track_num: int,
}

Repeat :: enum u8 {
	Off,
	All,
	One,
}

// The queue plays its entries in an order: every entry's index once, the
// list's own order unless shuffled (queue_order). The procs below take an
// entry index and give one back.

// queue_order fills order with the entries in head, then the rest of
// 0 ..< len(order) in list order, or shuffled when shuffle is set.
queue_order :: proc(order: []int, head: []int, shuffle: bool, gen := context.random_generator) {
	taken := make([]bool, len(order), context.temp_allocator)
	n := 0
	for i in head {
		if i >= 0 && i < len(order) && !taken[i] {
			taken[i] = true
			order[n] = i
			n += 1
		}
	}
	rest := n
	for i in 0 ..< len(order) {
		if !taken[i] {
			order[n] = i
			n += 1
		}
	}
	if shuffle {
		rand.shuffle(order[rest:], gen)
	}
}

// queue_next is the entry after i in order that can play, or -1; the first
// when i is -1. With wrap it goes round from the end, as far as i itself.
queue_next :: proc(entries: []Queue_Entry, order: []int, i: int, wrap := false) -> int {
	at := order_pos(order, i)
	for p in at + 1 ..< len(order) {
		if playable(entries, order[p]) {
			return order[p]
		}
	}
	if wrap {
		for p in 0 ..= at {
			if playable(entries, order[p]) {
				return order[p]
			}
		}
	}
	return -1
}

// queue_previous is the entry before i in order that can play, or -1.
queue_previous :: proc(entries: []Queue_Entry, order: []int, i: int) -> int {
	for p := order_pos(order, i) - 1; p >= 0; p -= 1 {
		if playable(entries, order[p]) {
			return order[p]
		}
	}
	return -1
}

// queue_after is what plays after entry i: i again on repeat one, unless
// the user asked to skip, else the next in order, going round on repeat.
queue_after :: proc(entries: []Queue_Entry, order: []int, i: int, repeat: Repeat, user: bool) -> int {
	if repeat == .One && !user && playable(entries, i) {
		return i
	}
	return queue_next(entries, order, i, wrap = repeat != .Off)
}

// PREVIOUS_RESTART is how far into a track "previous" restarts it instead
// of going back a track, in seconds.
PREVIOUS_RESTART :: 3

// queue_previous_action decides what "previous" does at position seconds
// into entry i: restart it (returns i) or go back.
queue_previous_action :: proc(entries: []Queue_Entry, order: []int, i: int, position: f64) -> int {
	if position >= PREVIOUS_RESTART {
		return i
	}
	prev := queue_previous(entries, order, i)
	return prev if prev >= 0 else i
}

// order_pos is where entry i is in order, or -1.
@(private = "file")
order_pos :: proc(order: []int, i: int) -> int {
	if i < 0 {
		return -1
	}
	p, _ := slice.linear_search(order, i)
	return p
}

@(private = "file")
playable :: proc(entries: []Queue_Entry, i: int) -> bool {
	return i >= 0 && i < len(entries) && entries[i].id != 0
}

// queue_gain_mode picks album gain when entry i is being played as part of
// its album in order: the entry next to it in order on either side is from
// the same album with the track number one away. Otherwise track gain, so
// a playlist of singles from different albums levels out, and so does a
// shuffled album.
queue_gain_mode :: proc(entries: []Queue_Entry, order: []int, i: int) -> Gain_Mode {
	if !playable(entries, i) || entries[i].album_id == 0 {
		return .Track
	}
	e := entries[i]
	at := order_pos(order, i)
	if at > 0 {
		p := entries[order[at - 1]]
		if p.album_id == e.album_id && p.track_num + 1 == e.track_num {
			return .Album
		}
	}
	if at >= 0 && at + 1 < len(order) {
		n := entries[order[at + 1]]
		if n.album_id == e.album_id && n.track_num == e.track_num + 1 {
			return .Album
		}
	}
	return .Track
}
