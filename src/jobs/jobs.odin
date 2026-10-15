// A bounded priority queue for handing plain-data items between threads.
// The app keeps two in State: jobs from the UI thread to the workers, and
// results from the workers back to the UI thread.
//
// Everything in Queue is plain data in a fixed array, with no allocator or
// procedure pointer, so a queue survives a hot reload with its items in it.
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
	cond:     sync.Cond, // an item arrived, room was freed, or stop
	items:    [N]T,
	tickets:  [N]Ticket,
	count:    int,
	next_seq: u64,
	busy:     int, // popped and not yet marked done
	stopped:  bool,
}

// push adds item unless the queue is full or stopped.
push :: proc(q: ^Queue($T, $N), item: T, priority: u8 = 0) -> bool {
	sync.guard(&q.mutex)
	if q.count == N || q.stopped {
		return false
	}
	add(q, item, {priority, q.next_seq})
	q.next_seq += 1
	return true
}

// push_wait adds item, waiting for room. False if the queue stopped first.
push_wait :: proc(q: ^Queue($T, $N), item: T, priority: u8 = 0) -> bool {
	sync.guard(&q.mutex)
	for q.count == N && !q.stopped {
		sync.cond_wait(&q.cond, &q.mutex)
	}
	if q.stopped {
		return false
	}
	add(q, item, {priority, q.next_seq})
	q.next_seq += 1
	return true
}

// requeue puts back an item popped with ticket and marks it done. It goes
// in even when the queue is stopped, so work interrupted by a stop is still
// there when the queue starts again. False only if the queue is full.
requeue :: proc(q: ^Queue($T, $N), item: T, ticket: Ticket) -> bool {
	sync.guard(&q.mutex)
	q.busy -= 1
	if q.count == N {
		sync.cond_broadcast(&q.cond)
		return false
	}
	add(q, item, ticket)
	return true
}

@(private)
add :: proc(q: ^Queue($T, $N), item: T, ticket: Ticket) {
	q.items[q.count] = item
	q.tickets[q.count] = ticket
	q.count += 1
	sync.cond_broadcast(&q.cond)
}

// pop_wait takes the next item, waiting for one. ok is false once the
// queue is stopped. Call done or requeue when finished with the item.
pop_wait :: proc(q: ^Queue($T, $N)) -> (item: T, ticket: Ticket, ok: bool) {
	sync.guard(&q.mutex)
	for q.count == 0 && !q.stopped {
		sync.cond_wait(&q.cond, &q.mutex)
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
	return item, true
}

@(private)
take :: proc(q: ^Queue($T, $N)) -> (item: T, ticket: Ticket) {
	best := 0
	for i in 1 ..< q.count {
		a, b := q.tickets[i], q.tickets[best]
		if a.priority < b.priority || (a.priority == b.priority && a.seq < b.seq) {
			best = i
		}
	}
	item, ticket = q.items[best], q.tickets[best]
	q.count -= 1
	q.items[best] = q.items[q.count]
	q.tickets[best] = q.tickets[q.count]
	sync.cond_broadcast(&q.cond)
	return
}

// done marks an item from pop_wait as finished.
done :: proc(q: ^Queue($T, $N)) {
	sync.guard(&q.mutex)
	q.busy -= 1
	sync.cond_broadcast(&q.cond)
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
		sync.cond_broadcast(&q.cond)
	}
	return removed
}

// stop wakes every waiter and makes pop_wait, push and push_wait fail
// until start. Queued items stay.
stop :: proc(q: ^Queue($T, $N)) {
	sync.guard(&q.mutex)
	q.stopped = true
	sync.cond_broadcast(&q.cond)
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
		sync.cond_wait_with_timeout(&q.cond, &q.mutex, left)
	}
	return q.stopped
}

// pending returns how many items are queued and how many are being worked on.
pending :: proc(q: ^Queue($T, $N)) -> (queued, busy: int) {
	sync.guard(&q.mutex)
	return q.count, q.busy
}
