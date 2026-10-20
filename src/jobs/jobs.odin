// A bounded priority queue for handing plain-data items between threads.
// The app keeps two in State: jobs from the UI thread to the workers, and
// results from the workers back to the UI thread.
//
// Everything in Queue is plain data in a fixed array, with no allocator or
// procedure pointer, so a queue survives a hot reload with its items in it.
//
// An item popped with pop_wait keeps its slot until done or requeue, so N
// counts queued and busy items together. That way requeue always has room:
// work cut short can't be lost because something else filled the queue.
package jobs

import "core:sync"
import "core:time"

// Ticket says where an item stood in the queue: lower priority values come
// out first, and within one priority the older item. requeue puts an item
// back where its ticket says, ahead of anything pushed after it.
Ticket :: struct {
	priority: u8,
	seq:      u64,
}

Queue :: struct($T: typeid, $N: int) {
	mutex:    sync.Mutex,
	arrived:  sync.Cond, // an item arrived, or stop
	freed:    sync.Cond, // room was freed, or stop
	halted:   sync.Cond, // stop, for sleep
	items:    [N]T,
	tickets:  [N]Ticket,
	count:    int,
	next_seq: u64,
	busy:     int, // popped with pop_wait and not yet done or requeued
	stopped:  bool,
}

// push adds item unless the queue is full or stopped. Full counts busy
// items.
push :: proc(q: ^Queue($T, $N), item: T, priority: u8 = 0) -> bool {
	sync.guard(&q.mutex)
	if q.count + q.busy >= N || q.stopped {
		return false
	}
	add(q, item, {priority, q.next_seq})
	q.next_seq += 1
	return true
}

// push_wait adds item, waiting for room. False if the queue stopped first.
push_wait :: proc(q: ^Queue($T, $N), item: T, priority: u8 = 0) -> bool {
	sync.guard(&q.mutex)
	for q.count + q.busy >= N && !q.stopped {
		sync.cond_wait(&q.freed, &q.mutex)
	}
	if q.stopped {
		return false
	}
	add(q, item, {priority, q.next_seq})
	q.next_seq += 1
	return true
}

// requeue puts back an item popped with ticket, in the slot it kept. It
// goes in even when the queue is stopped, so work interrupted by a stop is
// still there when the queue starts again.
requeue :: proc(q: ^Queue($T, $N), item: T, ticket: Ticket) {
	sync.guard(&q.mutex)
	assert(q.busy > 0 && q.count < N, "jobs: requeue without a pop_wait")
	q.busy -= 1
	add(q, item, ticket)
}

@(private)
add :: proc(q: ^Queue($T, $N), item: T, ticket: Ticket) {
	q.items[q.count] = item
	q.tickets[q.count] = ticket
	q.count += 1
	sync.cond_broadcast(&q.arrived)
}

// pop_wait takes the next item, waiting for one. ok is false once the
// queue is stopped. Call done or requeue when finished with the item.
pop_wait :: proc(q: ^Queue($T, $N)) -> (item: T, ticket: Ticket, ok: bool) {
	sync.guard(&q.mutex)
	for q.count == 0 && !q.stopped {
		sync.cond_wait(&q.arrived, &q.mutex)
	}
	if q.stopped {
		return
	}
	item, ticket = take(q)
	q.busy += 1
	return item, ticket, true
}

// try_pop takes the next item if there is one, without waiting and without
// counting it as busy.
try_pop :: proc(q: ^Queue($T, $N)) -> (item: T, ok: bool) {
	sync.guard(&q.mutex)
	if q.count == 0 {
		return
	}
	item, _ = take(q)
	sync.cond_broadcast(&q.freed)
	return item, true
}

// pop_wait_where is pop_wait for the items wanted says yes to, waiting at
// most d for one. ok is false if none came in time or the queue stopped;
// stopped says which. wanted runs with the queue locked.
pop_wait_where :: proc(q: ^Queue($T, $N), wanted: proc(item: ^T) -> bool, d: time.Duration) -> (item: T, ticket: Ticket, ok, stopped: bool) {
	sync.guard(&q.mutex)
	deadline := time.tick_add(time.tick_now(), d)
	for !q.stopped {
		if at := next_where(q, wanted); at >= 0 {
			item, ticket = take_at(q, at)
			q.busy += 1
			return item, ticket, true, false
		}
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 {
			return
		}
		sync.cond_wait_with_timeout(&q.arrived, &q.mutex, left)
	}
	stopped = true
	return
}

@(private)
take :: proc(q: ^Queue($T, $N)) -> (item: T, ticket: Ticket) {
	return take_at(q, next_where(q, nil))
}

// next_where is the index of the item that comes out next among those
// wanted says yes to, all of them if it's nil. -1 if there's none.
@(private)
next_where :: proc(q: ^Queue($T, $N), wanted: proc(item: ^T) -> bool) -> int {
	best := -1
	for i in 0 ..< q.count {
		if wanted != nil && !wanted(&q.items[i]) {
			continue
		}
		if best < 0 {
			best = i
			continue
		}
		a, b := q.tickets[i], q.tickets[best]
		if a.priority < b.priority || (a.priority == b.priority && a.seq < b.seq) {
			best = i
		}
	}
	return best
}

@(private)
take_at :: proc(q: ^Queue($T, $N), best: int) -> (item: T, ticket: Ticket) {
	item, ticket = q.items[best], q.tickets[best]
	q.count -= 1
	q.items[best] = q.items[q.count]
	q.tickets[best] = q.tickets[q.count]
	return
}

// done marks an item from pop_wait as finished.
done :: proc(q: ^Queue($T, $N)) {
	sync.guard(&q.mutex)
	q.busy -= 1
	sync.cond_broadcast(&q.freed)
}

// remove_if drops every queued item for which pred returns true and
// returns how many it dropped. pred runs with the queue locked, so it
// must not touch the queue.
remove_if :: proc(q: ^Queue($T, $N), pred: proc(item: ^T, data: rawptr) -> bool, data: rawptr) -> int {
	sync.guard(&q.mutex)
	removed := 0
	for i := 0; i < q.count; {
		if pred(&q.items[i], data) {
			q.count -= 1
			q.items[i] = q.items[q.count]
			q.tickets[i] = q.tickets[q.count]
			removed += 1
		} else {
			i += 1
		}
	}
	if removed > 0 {
		sync.cond_broadcast(&q.freed)
	}
	return removed
}

// stop wakes every waiter and makes pop_wait, push and push_wait fail
// until start. Queued items stay.
stop :: proc(q: ^Queue($T, $N)) {
	sync.guard(&q.mutex)
	q.stopped = true
	sync.cond_broadcast(&q.arrived)
	sync.cond_broadcast(&q.freed)
	sync.cond_broadcast(&q.halted)
}

start :: proc(q: ^Queue($T, $N)) {
	sync.guard(&q.mutex)
	q.stopped = false
}

// sleep waits for d or until the queue stops, whichever is first. True if
// the queue stopped.
sleep :: proc(q: ^Queue($T, $N), d: time.Duration) -> bool {
	sync.guard(&q.mutex)
	deadline := time.tick_add(time.tick_now(), d)
	for !q.stopped {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 {
			break
		}
		sync.cond_wait_with_timeout(&q.halted, &q.mutex, left)
	}
	return q.stopped
}

// room returns how many more items push would take.
room :: proc(q: ^Queue($T, $N)) -> int {
	sync.guard(&q.mutex)
	return N - q.count - q.busy
}

// pending returns how many items are queued and how many are being worked on.
pending :: proc(q: ^Queue($T, $N)) -> (queued, busy: int) {
	sync.guard(&q.mutex)
	return q.count, q.busy
}
