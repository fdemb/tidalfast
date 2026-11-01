package tidal_tests

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import stbi "vendor:stb/image"

import app "../src/app"
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

// Adds a cover of px and places it, as the app does when its pixels
// arrive, giving a new page a made-up texture handle.
@(private = "file")
add_ready :: proc(c: ^cover.Cache, id: string, px: int, frame: u64) -> ^cover.Entry {
	e := cover.want(c, .Album, id, px, px, frame, 1)
	placed, page := cover.place(c, e.key, frame, 0)
	if page != nil && page.texture == 0 {
		page.texture = render.Texture(1000 + frame)
	}
	return placed
}

@(test)
cover_pages_fill_then_reuse_the_least_recently_used :: proc(t: ^testing.T) {
	c := new(cover.Cache, context.temp_allocator)
	cols, side := cover.page_layout(80)
	testing.expect_value(t, cols, 8)
	testing.expect_value(t, side, 640)
	slots := cols * cols
	cover.init(c, 2 * cover.page_bytes(80))

	// Two pages' worth fit the budget: slots in order, the second page
	// opened when the first is full.
	for i in 0 ..< 2 * slots {
		e := add_ready(c, fmt.tprint(i), 80, u64(i + 1))
		testing.expect_value(t, int(e.page), i / slots)
		testing.expect_value(t, int(e.slot), i % slots)
	}
	testing.expect_value(t, c.bytes, 2 * cover.page_bytes(80))
	testing.expect_value(t, c.pages[0].texture, render.Texture(1001))
	e := cover.lookup(c, cover.key_of("9", 80))
	testing.expect_value(t, cover.src(c, e), render.Rect{80, 80, 80, 80})

	// Full: "1" is drawn again, so "0" and then "2" are the oldest, and the
	// new covers take their slots instead of a third page.
	frame := u64(2 * slots + 10)
	cover.want(c, .Album, "1", 80, 80, frame, 1)
	frame += render.FRAMES_IN_FLIGHT
	a := add_ready(c, "new a", 80, frame)
	b := add_ready(c, "new b", 80, frame)
	testing.expect_value(t, [2]u8{a.page, a.slot}, [2]u8{0, 0})
	testing.expect_value(t, [2]u8{b.page, b.slot}, [2]u8{0, 2})
	testing.expect(t, cover.lookup(c, cover.key_of("0", 80)) == nil)
	testing.expect(t, cover.lookup(c, cover.key_of("1", 80)) != nil)
	testing.expect_value(t, c.bytes, 2 * cover.page_bytes(80))
	testing.expect_value(t, c.ready, 2 * slots)
}

@(test)
cover_slots_drawn_lately_are_never_overwritten :: proc(t: ^testing.T) {
	c := new(cover.Cache, context.temp_allocator)
	cover.init(c, cover.page_bytes(80))
	slots := 64
	for i in 0 ..< slots {
		add_ready(c, fmt.tprint(i), 80, 10)
	}
	// Drawn two frames ago, so a frame in flight may still sample them:
	// the new cover opens a page over the budget instead.
	e := add_ready(c, "late", 80, 12)
	testing.expect_value(t, int(e.page), 1)
	testing.expect_value(t, c.bytes, 2 * cover.page_bytes(80))

	// trim gives back the page drawn longest ago, never one drawn in the
	// current frame.
	out: [4]render.Texture
	cover.want(c, .Album, "0", 80, 80, 13, 1)
	cover.want(c, .Album, "late", 80, 80, 13, 1)
	testing.expect_value(t, cover.trim(c, 13, out[:]), 0)
	cover.want(c, .Album, "0", 80, 80, 14, 1)
	testing.expect_value(t, cover.trim(c, 14, out[:]), 1)
	testing.expect_value(t, out[0], render.Texture(1012)) // the second page
	testing.expect(t, cover.lookup(c, cover.key_of("late", 80)) == nil)
	testing.expect_value(t, c.ready, slots)
	testing.expect_value(t, c.bytes, cover.page_bytes(80))
}

@(test)
cover_pages_hold_one_size_each :: proc(t: ^testing.T) {
	c := new(cover.Cache, context.temp_allocator)
	cover.init(c, 64 << 20)
	small := add_ready(c, "a", 80, 1)
	big := add_ready(c, "a", 184, 1) // the same cover in the header
	huge := add_ready(c, "b", 1280, 1)
	testing.expect(t, small.page != big.page && big.page != huge.page)
	cols, side := cover.page_layout(184)
	testing.expect_value(t, [2]int{cols, side}, [2]int{3, 552})
	cols, side = cover.page_layout(1280)
	testing.expect_value(t, [2]int{cols, side}, [2]int{1, 1280})
	testing.expect_value(t, c.bytes, cover.page_bytes(80) + cover.page_bytes(184) + cover.page_bytes(1280))

	// Removing a cover frees its slot for the next one of that size.
	cover.remove(c, small)
	again := add_ready(c, "c", 80, 2)
	testing.expect_value(t, [2]u8{again.page, again.slot}, [2]u8{0, 0})
	testing.expect_value(t, c.ready, 3)
}

@(test)
cover_cache_reuses_entries_when_full :: proc(t: ^testing.T) {
	c := new(cover.Cache, context.temp_allocator)
	cover.init(c, max(int))
	for i in 0 ..< cover.MAX_ENTRIES {
		testing.expect(t, cover.want(c, .Album, fmt.tprint(i), 80, 80, 1, 1) != nil)
	}
	// Full of entries nobody has loaded yet: a new one replaces the oldest
	// of those, but never one asked for in the same frame.
	testing.expect(t, cover.want(c, .Album, "late", 80, 80, 1, 1) == nil)
	testing.expect(t, cover.want(c, .Album, "next frame", 80, 80, 2, 1) != nil)
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

// A cover is scaled on the worker to the size it's drawn at.
@(test)
cover_decode_scales_to_size :: proc(t: ^testing.T) {
	src: [8 * 8 * 4]u8
	for &v, i in src {
		v = 255 if i % 4 == 3 || (i / 4) % 2 == 0 else 0 // alternate white and black columns
	}
	png := make([dynamic]u8, context.temp_allocator)
	write :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
		context = runtime.default_context()
		out := (^[dynamic]u8)(ctx)
		append(out, ..([^]u8)(data)[:size])
	}
	stbi.write_png_to_func(write, &png, 8, 8, 4, &src, 8 * 4)
	pixels, w, h, ok := cover.decode(png[:], 4)
	defer cover.free_pixels(pixels)
	testing.expect(t, ok)
	testing.expect_value(t, [2]int{w, h}, [2]int{4, 4})
	testing.expect_value(t, len(pixels), 4 * 4 * 4)
	// Averaged in linear light: half white is 188 in sRGB, not 128.
	testing.expect(t, pixels[4 * 5] > 170 && pixels[4 * 5] < 205, fmt.tprint(pixels[4 * 5]))
	testing.expect_value(t, pixels[4 * 5 + 3], 255)
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

// An idle worker gives back the whole pages of its temp block past what it
// keeps, and nothing when the block is smaller than that.
@(test)
temp_tail_is_whole_pages_past_keep :: proc(t: ^testing.T) {
	PAGE :: 16 << 10
	base := uintptr(0x1_0000_0000) + 48 // a block's base needn't be page aligned
	start, size := app.temp_tail(base, 4 << 20, 64 << 10, PAGE)
	testing.expect_value(t, uintptr(start), uintptr(0x1_0000_0000) + 5 * PAGE)
	testing.expect_value(t, size, uint(4 << 20) - 5 * PAGE)
	testing.expect_value(t, uintptr(start) % PAGE, 0)
	testing.expect_value(t, (uintptr(start) + uintptr(size)) % PAGE, 0)
	testing.expect(t, uintptr(start) + uintptr(size) <= base + (4 << 20))
	_, size = app.temp_tail(base, 64 << 10, 64 << 10, PAGE)
	testing.expect_value(t, size, 0)
}

@(private = "file")
png_of :: proc(src: []u8, w, h, channels: int) -> []u8 {
	png := make([dynamic]u8, context.temp_allocator)
	write :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
		context = runtime.default_context()
		out := (^[dynamic]u8)(ctx)
		append(out, ..([^]u8)(data)[:size])
	}
	stbi.write_png_to_func(write, &png, i32(w), i32(h), i32(channels), raw_data(src), i32(w * channels))
	return png[:]
}

// No cover is near this big, so decode refuses it from the header
// instead of allocating hundreds of megabytes on a worker.
@(test)
cover_decode_refuses_huge_images :: proc(t: ^testing.T) {
	w, h := 8192, 2049 // just over 4096 * 4096 pixels
	png := png_of(make([]u8, w * h, context.temp_allocator), w, h, 1)
	pixels, _, _, ok := cover.decode(png, 80)
	defer cover.free_pixels(pixels)
	testing.expect(t, !ok)
}

// A gray PNG with alpha comes out of stb_image with straight alpha like an
// RGBA one, so it decodes to the same pixels as the same image in RGBA,
// scaled or not.
@(test)
cover_decode_premultiplies_gray_alpha :: proc(t: ^testing.T) {
	gray: [4 * 4 * 2]u8
	rgba: [4 * 4 * 4]u8
	for i in 0 ..< 4 * 4 {
		gray[i * 2], gray[i * 2 + 1] = 128, 128
		rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = 128, 128, 128, 128
	}
	gray_png := png_of(gray[:], 4, 4, 2)
	rgba_png := png_of(rgba[:], 4, 4, 4)
	for px in ([]int{0, 2}) {
		got, w, h, ok := cover.decode(gray_png, px)
		defer cover.free_pixels(got)
		want, _, _, _ := cover.decode(rgba_png, px)
		defer cover.free_pixels(want)
		testing.expect(t, ok)
		testing.expect_value(t, [2]int{w, h}, [2]int{4, 4} if px == 0 else [2]int{px, px})
		testing.expect(t, slice.equal(got, want), fmt.tprint(px, got[:4], want[:4]))
	}
}

// A gray PNG whose tRNS chunk makes gray 200 transparent. stb_image counts
// the tRNS alpha as a channel, so decode premultiplies it and that pixel
// comes out all zero.
@(test)
cover_decode_premultiplies_trns :: proc(t: ^testing.T) {
	chunk :: proc(png: ^[dynamic]u8, kind: string, data: []u8) {
		be32 :: proc(png: ^[dynamic]u8, v: u32) {
			append(png, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
		}
		be32(png, u32(len(data)))
		start := len(png)
		append(png, kind)
		append(png, ..data)
		be32(png, hash.crc32(png[start:]))
	}
	// One row: filter 0, gray 200 (the transparent key), gray 100.
	row := [3]u8{0, 200, 100}
	// zlib header, one stored deflate block, Adler-32 of the row.
	idat := make([dynamic]u8, context.temp_allocator)
	append(&idat, 0x78, 0x01, 0x01, 3, 0, 0xfc, 0xff)
	append(&idat, ..row[:])
	adler := hash.adler32(row[:])
	append(&idat, u8(adler >> 24), u8(adler >> 16), u8(adler >> 8), u8(adler))
	png := make([dynamic]u8, context.temp_allocator)
	append(&png, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n')
	chunk(&png, "IHDR", {0, 0, 0, 2, 0, 0, 0, 1, 8, 0, 0, 0, 0})
	chunk(&png, "tRNS", {0, 200})
	chunk(&png, "IDAT", idat[:])
	chunk(&png, "IEND", nil)
	pixels, w, h, ok := cover.decode(png[:])
	defer cover.free_pixels(pixels)
	testing.expect(t, ok)
	testing.expect_value(t, [2]int{w, h}, [2]int{2, 1})
	if len(pixels) == 8 {
		testing.expect_value(t, [4]u8{pixels[0], pixels[1], pixels[2], pixels[3]}, [4]u8{0, 0, 0, 0})
		testing.expect_value(t, [4]u8{pixels[4], pixels[5], pixels[6], pixels[7]}, [4]u8{100, 100, 100, 255})
	}
}

@(private = "file")
Wait_Shared :: struct {
	q:        jobs.Queue(Test_Job, 1),
	work:     proc(sh: ^Wait_Shared),
	finished: bool,
	ok:       bool,
	stopped:  bool,
	popped:   int,
	ticket:   jobs.Ticket,
}

@(private = "file")
every_job :: proc(_: ^Test_Job, _: rawptr) -> bool {return true}

// blocks_until runs sh.work on a thread, checks it is still waiting after
// 20 ms, runs wake and waits up to 2 s for the work to return. On a timeout
// it stops the queue to free the thread and ends the test, so a lost wakeup
// fails the test instead of hanging it or running on against a stopped
// queue. A thread that ignores the stop as well is left running with sh, so
// sh is static and the thread comes from the heap rather than the test's
// allocator, which the test frees when it ends.
@(private = "file")
blocks_until :: proc(t: ^testing.T, sh: ^Wait_Shared, wake: proc(sh: ^Wait_Shared), loc := #caller_location) {
	finished_within :: proc(sh: ^Wait_Shared, d: time.Duration) -> bool {
		deadline := time.tick_add(time.tick_now(), d)
		for !sync.atomic_load(&sh.finished) {
			if time.tick_diff(time.tick_now(), deadline) <= 0 {
				return false
			}
			time.sleep(time.Millisecond)
		}
		return true
	}
	sync.atomic_store(&sh.finished, false)
	context.allocator = runtime.heap_allocator()
	worker := thread.create_and_start_with_poly_data(sh, proc(sh: ^Wait_Shared) {
		sh.work(sh)
		sync.atomic_store(&sh.finished, true)
	})
	time.sleep(20 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&sh.finished), "returned before the wakeup", loc = loc)
	wake(sh)
	if !finished_within(sh, 2 * time.Second) {
		jobs.stop(&sh.q)
		if finished_within(sh, 2 * time.Second) {
			thread.join(worker)
			thread.destroy(worker)
		}
		testing.fail_now(t, "no wakeup within 2 s", loc)
	}
	thread.join(worker)
	thread.destroy(worker)
}

// Every way room comes back wakes a push_wait, and every way an item comes
// in wakes a pop_wait_where waiting for that item.
@(test)
queue_waiters_wake_on_each_change :: proc(t: ^testing.T) {
	@(static) sh_storage: Wait_Shared
	sh := &sh_storage
	jobs.push(&sh.q, {1})
	sh.work = proc(sh: ^Wait_Shared) {sh.ok = jobs.push_wait(&sh.q, {2})}
	blocks_until(t, sh, proc(sh: ^Wait_Shared) {
		job, _ := jobs.try_pop(&sh.q)
		sh.popped = job.id
	})
	testing.expect(t, sh.ok)
	testing.expect_value(t, sh.popped, 1)
	job, _, _ := jobs.pop_wait(&sh.q)
	testing.expect_value(t, job.id, 2)
	blocks_until(t, sh, proc(sh: ^Wait_Shared) {jobs.done(&sh.q)})
	testing.expect(t, sh.ok)
	blocks_until(t, sh, proc(sh: ^Wait_Shared) {jobs.remove_if(&sh.q, every_job, nil)})
	testing.expect(t, sh.ok)

	sh.work = proc(sh: ^Wait_Shared) {
		is_seven :: proc(job: ^Test_Job) -> bool {return job.id == 7}
		job, _, ok, _ := jobs.pop_wait_where(&sh.q, is_seven, 5 * time.Second)
		sh.popped = job.id if ok else -1
	}
	jobs.remove_if(&sh.q, every_job, nil)
	sh.popped = 0
	blocks_until(t, sh, proc(sh: ^Wait_Shared) {jobs.push(&sh.q, {7})})
	testing.expect_value(t, sh.popped, 7)
	// requeue takes back an item popped with pop_wait, so finish the one the
	// worker popped and pop one here.
	jobs.done(&sh.q)
	jobs.push(&sh.q, {7})
	_, sh.ticket, _ = jobs.pop_wait(&sh.q)
	sh.popped = 0
	blocks_until(t, sh, proc(sh: ^Wait_Shared) {jobs.requeue(&sh.q, {7}, sh.ticket)})
	testing.expect_value(t, sh.popped, 7)
}

// stop wakes every kind of waiter.
@(test)
queue_stop_wakes_waiters :: proc(t: ^testing.T) {
	@(static) sh_storage: Wait_Shared
	sh := &sh_storage
	stop :: proc(sh: ^Wait_Shared) {jobs.stop(&sh.q)}

	sh.ok = true
	sh.work = proc(sh: ^Wait_Shared) {_, _, sh.ok = jobs.pop_wait(&sh.q)}
	blocks_until(t, sh, stop)
	testing.expect(t, !sh.ok)
	// Stopped: pushes fail until start.
	testing.expect(t, !jobs.push(&sh.q, {1}))
	jobs.start(&sh.q)
	testing.expect(t, jobs.push(&sh.q, {1}))

	sh.ok = true
	sh.work = proc(sh: ^Wait_Shared) {sh.ok = jobs.push_wait(&sh.q, {2})}
	blocks_until(t, sh, stop)
	testing.expect(t, !sh.ok)

	jobs.start(&sh.q)
	_, _ = jobs.try_pop(&sh.q)
	sh.work = proc(sh: ^Wait_Shared) {
		any_job :: proc(_: ^Test_Job) -> bool {return true}
		_, _, _, sh.stopped = jobs.pop_wait_where(&sh.q, any_job, 5 * time.Second)
	}
	blocks_until(t, sh, stop)
	testing.expect(t, sh.stopped)

	jobs.start(&sh.q)
	sh.stopped = false
	sh.work = proc(sh: ^Wait_Shared) {sh.stopped = jobs.sleep(&sh.q, 5 * time.Second)}
	blocks_until(t, sh, stop)
	testing.expect(t, sh.stopped)
}

// Giving pages back has to work on this OS, and they must be usable once taken
// back.
@(test)
pages_give_back_then_take_back :: proc(t: ^testing.T) {
	SIZE :: 4 * (16 << 10)
	block, err := virtual.reserve_and_commit(SIZE)
	testing.expect_value(t, err, nil)
	defer virtual.release(raw_data(block), SIZE)
	block[0] = 1
	testing.expect(t, app.pages_give_back(raw_data(block), SIZE), "pages given back")
	app.pages_take_back(raw_data(block), SIZE)
	block[0] = 2
	block[SIZE - 1] = 3
	testing.expect_value(t, block[0] + block[SIZE - 1], 5)
}
