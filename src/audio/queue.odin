package audio

// What the play queue needs to know about each entry to decide what comes
// next and which ReplayGain to use. The app keeps the rest.
Queue_Entry :: struct {
	id:        i64, // TIDAL track id, 0 when the entry can't be streamed
	album_id:  i64,
	track_num: int,
}

// queue_next is the entry after current that can play, or -1.
queue_next :: proc(entries: []Queue_Entry, current: int) -> int {
	for i in current + 1 ..< len(entries) {
		if playable(entries[i]) {
			return i
		}
	}
	return -1
}

// queue_previous is the entry before current that can play, or -1.
queue_previous :: proc(entries: []Queue_Entry, current: int) -> int {
	for i := min(current, len(entries)) - 1; i >= 0; i -= 1 {
		if playable(entries[i]) {
			return i
		}
	}
	return -1
}

// PREVIOUS_RESTART is how far into a track "previous" restarts it instead
// of going back a track, in seconds.
PREVIOUS_RESTART :: 3

// queue_previous_action decides what "previous" does at position seconds
// into the current entry: restart it (returns current) or go back.
queue_previous_action :: proc(entries: []Queue_Entry, current: int, position: f64) -> int {
	if position >= PREVIOUS_RESTART {
		return current
	}
	prev := queue_previous(entries, current)
	return prev if prev >= 0 else current
}

@(private = "file")
playable :: proc(e: Queue_Entry) -> bool {
	return e.id != 0
}

// queue_gain_mode picks album gain when entry i is being played as part of
// its album in order: the entry next to it on either side is from the same
// album with the track number one away. Otherwise track gain, so a
// playlist of singles from different albums levels out.
queue_gain_mode :: proc(entries: []Queue_Entry, i: int) -> Gain_Mode {
	if i < 0 || i >= len(entries) || entries[i].album_id == 0 {
		return .Track
	}
	e := entries[i]
	if i > 0 {
		p := entries[i - 1]
		if p.album_id == e.album_id && p.track_num + 1 == e.track_num {
			return .Album
		}
	}
	if i + 1 < len(entries) {
		n := entries[i + 1]
		if n.album_id == e.album_id && n.track_num == e.track_num + 1 {
			return .Album
		}
	}
	return .Track
}
