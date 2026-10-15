package tidal

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:sync"
import "core:thread"

PAGE_CHUNK_SIZE :: 50
PAGE_WORKERS :: 2

@(private = "file")
Page_Job :: struct {
	s:          ^Session,
	r:          Request,
	total:      int,
	chunk_size: int,
	next_chunk: int, // atomic
	bodies:     [][]u8,
	err:        Error,
	err_mutex:  sync.Mutex,
	logger:     runtime.Logger,
}

// fetch_pages requests [0, total) in chunks of chunk_size with `workers`
// threads. Bodies are heap-allocated, in order. A failed chunk fails the
// whole call.
@(private)
fetch_pages :: proc(s: ^Session, r: Request, total: int, chunk_size := PAGE_CHUNK_SIZE, workers := PAGE_WORKERS) -> (bodies: [][]u8, err: Error) {
	if total <= 0 {
		return nil, nil
	}
	job := Page_Job {
		s          = s,
		r          = r,
		total      = total,
		chunk_size = chunk_size,
		bodies     = make([][]u8, (total + chunk_size - 1) / chunk_size, runtime.heap_allocator()),
		logger     = context.logger,
	}

	worker :: proc(job: ^Page_Job) {
		context.logger = job.logger
		heap := runtime.heap_allocator()
		for {
			chunk := sync.atomic_add(&job.next_chunk, 1)
			if chunk >= len(job.bodies) {
				return
			}
			sync.mutex_lock(&job.err_mutex)
			failed := job.err != nil
			sync.mutex_unlock(&job.err_mutex)
			if failed {
				return
			}
			offset := chunk * job.chunk_size
			params := make([dynamic]Param, 0, len(job.r.params) + 2, context.temp_allocator)
			append(&params, ..job.r.params)
			append(&params, Param{"limit", fmt.tprint(min(job.chunk_size, job.total - offset))})
			append(&params, Param{"offset", fmt.tprint(offset)})
			r := job.r
			r.params = params[:]

			resp, err := request(job.s, r, heap)
			if err != nil {
				log.errorf("Failed to fetch %s (offset=%d): %s", r.path, offset, error_summary(err, context.temp_allocator))
				delete(resp.body, heap)
				delete(resp.etag, heap)
				sync.guard(&job.err_mutex)
				if job.err == nil {
					job.err = err
				}
				return
			}
			delete(resp.etag, heap)
			job.bodies[chunk] = resp.body
			free_all(context.temp_allocator)
		}
	}

	threads := make([dynamic]^thread.Thread, 0, workers, context.temp_allocator)
	for _ in 0 ..< max(1, workers) {
		append(&threads, thread.create_and_start_with_poly_data(&job, worker, init_context = context))
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	if job.err != nil {
		free_bodies(job.bodies)
		return nil, job.err
	}
	return job.bodies, nil
}

@(private)
free_bodies :: proc(bodies: [][]u8) {
	heap := runtime.heap_allocator()
	for b in bodies {
		delete(b, heap)
	}
	delete(bodies, heap)
}

// paginate fetches `total` items of a list endpoint in parallel and parses
// them, in order, into allocator.
@(private)
paginate :: proc(s: ^Session, r: Request, total: int, $T: typeid, parse: proc(p: ^Parser, obj: json.Object) -> T, allocator: Allocator) -> (items: []T, err: Error) {
	bodies := fetch_pages(s, r, total) or_return
	defer free_bodies(bodies)

	p := parser_make(s, allocator)
	out := make([dynamic]T, 0, total, allocator)
	for body in bodies {
		v, jerr := json.parse(body, .JSON, true, context.temp_allocator)
		obj, ok := v.(json.Object)
		if jerr != nil || !ok {
			return nil, make_error(.Bad_Response, "Expected a JSON object", detail = string(body))
		}
		map_items_into(&p, obj, &out, parse)
	}
	return out[:], nil
}
