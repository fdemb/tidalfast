package audio

import "base:intrinsics"

// Pcm_Ring carries decoded frames from the decode thread (the only writer)
// to the audio callback (the only reader) without locks. Positions are frame
// counts that only grow; a frame's slot is its position modulo the capacity,
// which is a power of two.
//
// The writer can drop everything not yet played by storing its own write
// position in flush_to. The reader skips up to it on its next call, so the
// writer never touches read.
Pcm_Ring :: struct {
	data:     []f32, // capacity * channels samples
	capacity: u64, // frames
	channels: int,
	write:    u64, // written by the writer only
	read:     u64, // written by the reader only
	flush_to: u64, // written by the writer, read by the reader
}

ring_init :: proc(r: ^Pcm_Ring, data: []f32, capacity: u64, channels: int) {
	assert(capacity & (capacity - 1) == 0)
	assert(u64(len(data)) >= capacity * u64(channels))
	r^ = {
		data     = data,
		capacity = capacity,
		channels = channels,
	}
}

// ring_free_frames is the room the writer has. Frames the reader hasn't
// skipped yet after a flush still count as taken.
ring_free_frames :: proc "contextless" (r: ^Pcm_Ring) -> u64 {
	w := intrinsics.atomic_load_explicit(&r.write, .Relaxed)
	rd := intrinsics.atomic_load_explicit(&r.read, .Acquire)
	return r.capacity - (w - rd)
}

// ring_buffered is what the reader has left to play.
ring_buffered :: proc "contextless" (r: ^Pcm_Ring) -> u64 {
	w := intrinsics.atomic_load_explicit(&r.write, .Acquire)
	rd := intrinsics.atomic_load_explicit(&r.read, .Relaxed)
	f := intrinsics.atomic_load_explicit(&r.flush_to, .Acquire)
	return w - max(rd, f)
}

// ring_write copies up to len(frames)/channels frames in and returns how
// many fit.
ring_write :: proc "contextless" (r: ^Pcm_Ring, frames: []f32) -> u64 {
	ch := u64(r.channels)
	n := min(u64(len(frames)) / ch, ring_free_frames(r))
	w := intrinsics.atomic_load_explicit(&r.write, .Relaxed)
	for i in 0 ..< n {
		slot := ((w + i) & (r.capacity - 1)) * ch
		for c in 0 ..< ch {
			r.data[slot + c] = frames[i * ch + c]
		}
	}
	intrinsics.atomic_store_explicit(&r.write, w + n, .Release)
	return n
}

// ring_flush drops every frame not yet read. Returns the position the next
// write lands at, which is where the reader resumes.
ring_flush :: proc "contextless" (r: ^Pcm_Ring) -> u64 {
	w := intrinsics.atomic_load_explicit(&r.write, .Relaxed)
	intrinsics.atomic_store_explicit(&r.flush_to, w, .Release)
	return w
}

// ring_read is the reader's side: it first skips to a flush, then copies up
// to frame_count frames into out, scaled by a gain that moves linearly from
// gain_from to gain_to across the frames copied. Returns how many it
// copied; the caller fills the rest.
ring_read :: proc "contextless" (r: ^Pcm_Ring, out: [^]f32, frame_count: u64, gain_from, gain_to: f32) -> u64 {
	rd := intrinsics.atomic_load_explicit(&r.read, .Relaxed)
	if f := intrinsics.atomic_load_explicit(&r.flush_to, .Acquire); f > rd {
		rd = f
	}
	w := intrinsics.atomic_load_explicit(&r.write, .Acquire)
	n := min(frame_count, w - rd)
	ch := u64(r.channels)
	step := (gain_to - gain_from) / f32(max(n, 1))
	g := gain_from
	for i in 0 ..< n {
		slot := ((rd + i) & (r.capacity - 1)) * ch
		g += step
		for c in 0 ..< ch {
			out[i * ch + c] = r.data[slot + c] * g
		}
	}
	intrinsics.atomic_store_explicit(&r.read, rd + n, .Release)
	return n
}

// ring_skip_flush applies a pending flush from the writer's thread. Only
// call it while the reader is not running, as when the device is stopped.
ring_skip_flush :: proc "contextless" (r: ^Pcm_Ring) {
	rd := intrinsics.atomic_load_explicit(&r.read, .Relaxed)
	if f := intrinsics.atomic_load_explicit(&r.flush_to, .Acquire); f > rd {
		intrinsics.atomic_store_explicit(&r.read, f, .Release)
	}
}

// Mark says what the frames from ring position `at` on are: which source,
// and which of its samples the first one is. The decode thread pushes one
// when it starts a source or lands a seek; the reader adopts each mark
// once it has read past its position.
Mark :: struct {
	at:      u64,
	serial:  u64,
	sample:  i64,
	seek_id: u32,
	end:     bool, // nothing follows: the queue ran out
}

MARKS :: 64

Mark_Queue :: struct {
	items: [MARKS]Mark,
	write: u64,
	read:  u64,
	cur:   Mark, // the reader's current mark
}

// mark_push fails only if the reader is MARKS-1 marks behind, which needs
// that many seeks or track starts within one ring's worth of audio. The
// slot of the mark the reader adopted last stays untouched, so others can
// read it.
mark_push :: proc "contextless" (q: ^Mark_Queue, m: Mark) -> bool {
	w := intrinsics.atomic_load_explicit(&q.write, .Relaxed)
	if w - intrinsics.atomic_load_explicit(&q.read, .Acquire) >= MARKS - 1 {
		return false
	}
	q.items[w % MARKS] = m
	intrinsics.atomic_store_explicit(&q.write, w + 1, .Release)
	return true
}

// mark_advance is the reader's side: adopt every mark at or before
// position. True if the current mark changed.
mark_advance :: proc "contextless" (q: ^Mark_Queue, position: u64) -> bool {
	changed := false
	rd := intrinsics.atomic_load_explicit(&q.read, .Relaxed)
	w := intrinsics.atomic_load_explicit(&q.write, .Acquire)
	for rd < w && q.items[rd % MARKS].at <= position {
		q.cur = q.items[rd % MARKS]
		rd += 1
		changed = true
	}
	intrinsics.atomic_store_explicit(&q.read, rd, .Release)
	return changed
}
