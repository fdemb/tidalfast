package tidal_tests

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import stbi "vendor:stb/image"

import "../src/cover"
import "../src/jobs"
import "../src/render"
import tidal "../src/tidal"

Test_Job :: struct {
	id: int,
}

@(test)
queue_pops_by_priority_then_age :: proc(t: ^testing.T) {
	q: jobs.Queue(Test_Job, 8)
	jobs.push(&q, {1}, 2)
	jobs.push(&q, {2}, 1)
	jobs.push(&q, {3}, 2)
	jobs.push(&q, {4}, 1)
	order: [4]int
	for &o in order {
		job, _, ok := jobs.pop_wait(&q)
		testing.expect(t, ok)
		o = job.id
		jobs.done(&q)
	}
	testing.expect_value(t, order, [4]int{2, 4, 1, 3})
}

@(test)
queue_requeue_keeps_place :: proc(t: ^testing.T) {
	q: jobs.Queue(Test_Job, 8)
	jobs.push(&q, {1})
	jobs.push(&q, {2})
	first, ticket, _ := jobs.pop_wait(&q)
	jobs.push(&q, {3})
	_, busy := jobs.pending(&q)
	testing.expect_value(t, busy, 1)
	// A job cut short goes back ahead of everything pushed after it.
	jobs.requeue(&q, first, ticket)
	queued, busy_after := jobs.pending(&q)
	testing.expect_value(t, queued, 3)
	testing.expect_value(t, busy_after, 0)
	again, _ := jobs.try_pop(&q)
	testing.expect_value(t, again.id, 1)
}

@(test)
queue_full_and_remove_if :: proc(t: ^testing.T) {
	q: jobs.Queue(Test_Job, 4)
	for i in 0 ..< 4 {
		testing.expect(t, jobs.push(&q, {i}))
	}
	testing.expect(t, !jobs.push(&q, {9}))
	odd :: proc(job: ^Test_Job, _: rawptr) -> bool {
		return job.id % 2 == 1
	}
	testing.expect_value(t, jobs.remove_if(&q, odd, nil), 2)
	queued, _ := jobs.pending(&q)
	testing.expect_value(t, queued, 2)
	a, _ := jobs.try_pop(&q)
	b, _ := jobs.try_pop(&q)
	testing.expect_value(t, a.id, 0)
	testing.expect_value(t, b.id, 2)
}

@(test)
queue_stop_wakes_waiters :: proc(t: ^testing.T) {
	Shared :: struct {
		q:      jobs.Queue(Test_Job, 2),
		popped: bool, // pop_wait returned ok
		done:   bool,
	}
	sh: Shared
	worker := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		_, _, ok := jobs.pop_wait(&sh.q)
		sh.popped = ok
		sync.atomic_store(&sh.done, true)
	})
	time.sleep(20 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&sh.done))
	jobs.stop(&sh.q)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, !sh.popped)
	// Stopped: pushes fail until start, but requeue still goes in.
	testing.expect(t, !jobs.push(&sh.q, {1}))
	jobs.start(&sh.q)
	testing.expect(t, jobs.push(&sh.q, {1}))
}

@(test)
queue_push_wait_blocks_until_room :: proc(t: ^testing.T) {
	Shared :: struct {
		q:      jobs.Queue(Test_Job, 1),
		pushed: bool,
	}
	sh: Shared
	jobs.push(&sh.q, {1})
	worker := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		ok := jobs.push_wait(&sh.q, {2})
		sync.atomic_store(&sh.pushed, ok)
	})
	time.sleep(20 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&sh.pushed))
	first, _ := jobs.try_pop(&sh.q)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, first.id, 1)
	testing.expect(t, sh.pushed)
	second, _ := jobs.try_pop(&sh.q)
	testing.expect_value(t, second.id, 2)
}

@(test)
cover_size_matches_display :: proc(t: ^testing.T) {
	testing.expect_value(t, cover.pick_size(.Album, 40, 2), 80) // track rows at 2x
	testing.expect_value(t, cover.pick_size(.Album, 40, 1), 80) // nothing smaller
	testing.expect_value(t, cover.pick_size(.Album, 56, 2), 160)
	testing.expect_value(t, cover.pick_size(.Album, 92, 2), 320) // the header
	testing.expect_value(t, cover.pick_size(.Album, 320, 2), 640)
	testing.expect_value(t, cover.pick_size(.Album, 2000, 2), 1280) // the largest there is
	testing.expect_value(t, cover.pick_size(.Playlist, 40, 2), 160) // playlists start at 160
	testing.expect_value(t, cover.pick_size(.Playlist, 240, 2), 480)
	url := cover.url("https://resources.tidal.com/images/%s/%dx%d.jpg", "9a56f482-e9cf-46c3-bb21-82710e7854d4", 80, context.temp_allocator)
	testing.expect_value(t, url, "https://resources.tidal.com/images/9a56f482/e9cf/46c3/bb21/82710e7854d4/80x80.jpg")
}

// Adds a cover, marks it uploaded with a made-up texture handle, as the app
// does when a result arrives.
@(private = "file")
add_ready :: proc(c: ^cover.Cache, id: string, frame: u64) -> u64 {
	e := cover.want(c, .Album, id, 80, frame, 1)
	key := e.key
	cover.set_ready(c, key, render.Texture(frame), 80, 80, 0)
	return key
}

@(test)
cover_cache_evicts_least_recently_used :: proc(t: ^testing.T) {
	c := new(cover.Cache, context.temp_allocator)
	cover.init(c, 3 * cover.texture_bytes(80, 80))
	a := add_ready(c, "a", 1)
	b := add_ready(c, "b", 2)
	add_ready(c, "c", 3)
	// a is drawn again, so b is now the oldest.
	cover.want(c, .Album, "a", 80, 4, 1)
	add_ready(c, "d", 5)
	testing.expect_value(t, c.bytes, 4 * cover.texture_bytes(80, 80))

	out: [8]render.Texture
	n := cover.evict(c, 5, out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out[0], render.Texture(2))
	testing.expect(t, cover.lookup(c, b) == nil)
	testing.expect(t, cover.lookup(c, a) != nil)
	testing.expect_value(t, c.bytes, 3 * cover.texture_bytes(80, 80))
	testing.expect_value(t, c.used, 3)

	// Nothing drawn in the current frame is evicted, even over budget.
	c.budget = 0
	for id in ([]string{"a", "c", "d"}) {
		cover.want(c, .Album, id, 80, 6, 1)
	}
	testing.expect_value(t, cover.evict(c, 6, out[:]), 0)
	testing.expect_value(t, cover.evict(c, 7, out[:]), 3)
	testing.expect_value(t, c.used, 0)
	testing.expect_value(t, c.bytes, 0)
}

@(test)
cover_cache_reuses_entries_when_full :: proc(t: ^testing.T) {
	c := new(cover.Cache, context.temp_allocator)
	cover.init(c, max(int))
	for i in 0 ..< cover.MAX_ENTRIES {
		testing.expect(t, cover.want(c, .Album, fmt.tprint(i), 80, 1, 1) != nil)
	}
	// Full of entries nobody has loaded yet: a new one replaces the oldest
	// of those, but never one asked for in the same frame.
	testing.expect(t, cover.want(c, .Album, "late", 80, 1, 1) == nil)
	testing.expect(t, cover.want(c, .Album, "next frame", 80, 2, 1) != nil)
	testing.expect_value(t, c.used, cover.MAX_ENTRIES)
}

@(test)
cover_decode_premultiplies :: proc(t: ^testing.T) {
	// 2x1 PNG: opaque red, then white at alpha 128.
	src := [8]u8{255, 0, 0, 255, 255, 255, 255, 128}
	png := make([dynamic]u8, context.temp_allocator)
	write :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
		context = runtime.default_context()
		out := (^[dynamic]u8)(ctx)
		append(out, ..([^]u8)(data)[:size])
	}
	stbi.write_png_to_func(write, &png, 2, 1, 4, &src, 8)
	pixels, w, h, ok := cover.decode(png[:])
	defer cover.free_pixels(pixels)
	testing.expect(t, ok)
	testing.expect_value(t, w, 2)
	testing.expect_value(t, h, 1)
	testing.expect_value(t, [4]u8{pixels[0], pixels[1], pixels[2], pixels[3]}, [4]u8{255, 0, 0, 255})
	// Premultiplied in linear light and encoded back to sRGB: 188, not 128.
	testing.expect_value(t, [4]u8{pixels[4], pixels[5], pixels[6], pixels[7]}, [4]u8{188, 188, 188, 128})
}

@(test)
backoff_gate_holds_back_requests :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	s.config.api_v1_location = m.base_url

	_, err := tidal.request(s, {method = .GET, path = "limited"}, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Too_Many_Requests))
	wait := tidal.backoff_remaining(s)
	testing.expect(t, wait > 0.8 && wait <= 1, fmt.tprint(wait))

	// Held back locally: neither API requests nor cover downloads reach
	// the server until Retry-After has passed.
	sent := mock_count(&m, "GET /")
	_, err = tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Backing_Off))
	_, err = tidal.resource_get(s, fmt.tprintf("%secho", m.base_url), context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Backing_Off))
	testing.expect_value(t, mock_count(&m, "GET /"), sent)

	time.sleep(time.Duration((wait + 0.05) * f64(time.Second)))
	testing.expect_value(t, tidal.backoff_remaining(s), 0)
	_, err = tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, mock_count(&m, "GET /echo"), 1)
}

@(test)
refresh_keeps_rotated_token_and_reports_it :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	s.config.api_v1_location = m.base_url
	s.config.api_oauth2_token = fmt.tprintf("%stoken", m.base_url)
	Seen :: struct {
		calls:   int,
		refresh: [32]u8,
	}
	seen: Seen
	s.on_auth_change_data = &seen
	s.on_auth_change = proc(s: ^tidal.Session, data: rawptr) {
		seen := (^Seen)(data)
		seen.calls += 1
		copy(seen.refresh[:], tidal.session_auth(s, context.temp_allocator).refresh_token)
	}
	// Restored from storage with an access token that has run out.
	tidal.session_restore(s, {token_type = "Bearer", access_token = "old", refresh_token = "refresh-0", expiry_time = time.time_add(time.now(), -time.Hour), user_id = 123, user_kind = .Logged_In_User})

	_, err := tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.refreshes, 1)
	testing.expect_value(t, seen.calls, 1)
	testing.expect_value(t, string(cstring(&seen.refresh[0])), "refresh-1")
	a := tidal.session_auth(s, context.temp_allocator)
	testing.expect_value(t, a.access_token, "access-1")
	testing.expect_value(t, a.refresh_token, "refresh-1")
	testing.expect_value(t, a.user_id, 123)

	// The token is fresh now: no second refresh.
	_, err = tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.refreshes, 1)
}

@(test)
abort_cancels_requests :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	s.config.api_v1_location = m.base_url
	tidal.session_abort(s, true)
	_, err := tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect(t, tidal.is_error(err, .Cancelled))
	testing.expect_value(t, mock_count(&m, "GET /echo"), 0)
	tidal.session_abort(s, false)
	_, err = tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
}
