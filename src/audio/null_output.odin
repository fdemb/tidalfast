package audio

// The null device, for tests and measuring: a thread that asks the player
// for frames in real time, a period at a time as a device would, and throws
// them away. Nothing reaches a speaker; the capture file still gets every
// frame.

import "core:sync"
import "core:time"

import "../sys"

@(private = "file")
NULL_PERIOD :: 10 * time.Millisecond

@(private)
Null_Output :: struct {
	thread:  sys.Thread,
	started: bool, // the thread exists
	wake:    Wake, // the thread's, while nothing plays
	rate:    int, // read by the thread at each start (atomic)
	player:  ^Player,
	run:     u64, // counts the starts, so the thread tells one from the next (atomic)
	running: bool, // between null_start and null_stop (atomic)
	busy:    bool, // the thread is rendering (atomic)
	quit:    bool, // atomic
}

// null_open sets the rate the next start plays at. The device must be
// stopped.
@(private)
null_open :: proc(o: ^Null_Output, rate: int) {
	sync.atomic_store(&o.rate, rate)
}

// null_start has the thread render p's ring (mixer_render) at the rate, and
// starts the thread the first time.
@(private)
null_start :: proc(o: ^Null_Output, p: ^Player) -> bool {
	o.player = p
	if !o.started {
		if !sys.thread_start(&o.thread, null_main, o) {
			return false
		}
		o.started = true
	}
	// The thread reads run before running, so it never renders for this
	// start with the last one's clock.
	sync.atomic_add(&o.run, 1)
	sync.atomic_store(&o.running, true)
	wake_post(&o.wake)
	return true
}

// null_stop stops the rendering. When it returns the thread no longer
// touches the player, and it sleeps until the next start.
@(private)
null_stop :: proc(o: ^Null_Output) {
	sync.atomic_store(&o.running, false)
	for sync.atomic_load(&o.busy) {
		time.sleep(50 * time.Microsecond)
	}
}

// null_close ends the thread.
@(private)
null_close :: proc(o: ^Null_Output) {
	null_stop(o)
	if o.started {
		sync.atomic_store(&o.quit, true)
		wake_post(&o.wake)
		sys.thread_join(o.thread)
		o.started = false
	}
}

// null_main is the thread. While it plays it wakes every period and renders
// the whole periods that are due by the clock since the start, so the
// frames keep real time however late a wake-up comes.
@(private = "file")
null_main :: proc "c" (arg: rawptr) -> rawptr {
	o := (^Null_Output)(arg)
	for !sync.atomic_load(&o.quit) {
		if !sync.atomic_load(&o.running) {
			wake_wait(&o.wake)
			continue
		}
		run := sync.atomic_load(&o.run)
		p := o.player
		rate := i64(sync.atomic_load(&o.rate))
		period := max(rate * i64(NULL_PERIOD) / i64(time.Second), 1)
		period = min(period, i64(len(p.hal_scratch) / MAX_CHANNELS))
		begin := time.tick_now()
		done: i64
		for null_runs(o, run) {
			time.sleep(NULL_PERIOD)
			due := i64(f64(rate) * time.duration_seconds(time.tick_since(begin)))
			// After a long stall, such as the machine sleeping, the missed
			// frames aren't played in one burst.
			if due - done > rate {
				done = due - period
			}
			for due - done >= period {
				sync.atomic_store(&o.busy, true)
				live := null_runs(o, run)
				if live {
					mixer_render(p, raw_data(p.hal_scratch), u64(period))
				}
				sync.atomic_store(&o.busy, false)
				if !live {
					break
				}
				done += period
			}
		}
	}
	return nil
}

@(private = "file")
null_runs :: proc "contextless" (o: ^Null_Output, run: u64) -> bool {
	return sync.atomic_load(&o.run) == run && sync.atomic_load(&o.running) && !sync.atomic_load(&o.quit)
}
