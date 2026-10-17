// Times what one list save and one queue save cost the UI thread: encoding
// the file that list_save and queue_save hand to the disk thread. The disk
// thread's part, filling in the file's sum, is timed on its own.
//
//     odin run tools/save_cost -o:speed
//     odin run tools/save_cost -o:speed -- -runs=15 -sizes=300,3000,10000
//
// The queue path copies the rows the way queue_file does, then encodes.
// Each run times one call per size and kind, the sizes and kinds taking
// turns, into a new heap block each time as in the app. -gap=100 sleeps
// before each call, as a save between idle frames comes on a cold cache. The blob is freed
// outside the timed region, since the disk thread frees it.
package save_cost

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import app "../../src/app"

Options :: struct {
	runs:  int `usage:"timed calls per size and kind (default 9)"`,
	sizes: string `usage:"comma-separated row counts (default 300,3000,10000)"`,
	gap:   int `usage:"milliseconds to sleep before each call, as saves come between idle frames (default 0)"`,
}

Kind :: enum {
	List,
	Queue,
}

Sample :: struct {
	ns:     [dynamic]i64,
	seal_ns: [dynamic]i64, // filling in the sum, on the disk thread
	make_ns: [dynamic]i64, // allocating and zeroing it, which writer_make does
	bytes:  int,
	allocs: int,
}

main :: proc() {
	opt := Options {
		runs  = 9,
		sizes = "300,3000,10000",
	}
	flags.parse_or_exit(&opt, os.args, .Unix)
	sizes: [dynamic]int
	for part in strings.split(opt.sizes, ",", context.temp_allocator) {
		n, ok := strconv.parse_int(part)
		if !ok || n <= 0 {
			fmt.eprintfln("save_cost: bad size %q", part)
			os.exit(2)
		}
		append(&sizes, n)
	}

	rows := make([][]app.Row, len(sizes))
	views := make([]app.Data, len(sizes))
	for n, i in sizes {
		rows[i] = make_rows(n)
		d := &views[i]
		app.view_open(d, .Liked, "", "Liked Songs", "", n)
		app.view_add_rows(&d.view, 0, n, rows[i], n)
		d.view.fetched = 1760000000
		d.view.version = {count = i64(n), newest = 1760000000}
		if d.view.count != n {
			fmt.eprintfln("save_cost: the view holds %d rows, not %d", d.view.count, n)
			os.exit(1)
		}
	}

	samples := make([][Kind]Sample, len(sizes))
	for i in 0 ..< len(sizes) {
		for k in Kind {
			samples[i][k].bytes, samples[i][k].allocs = count_allocs(&views[i], rows[i], k)
		}
	}
	sink: u64
	for run in -1 ..< opt.runs { // run -1 warms up and isn't kept
		for i in 0 ..< len(sizes) {
			for k in Kind {
				time.sleep(time.Duration(opt.gap) * time.Millisecond)
				blob, ns := timed_save(&views[i], rows[i], k)
				seal_ns := timed_seal(blob, k)
				sink += check(blob, sizes[i], k)
				delete(blob, runtime.heap_allocator())
				free_all(context.temp_allocator)
				make_ns := timed_make(samples[i][k].bytes, &sink)
				if run >= 0 {
					append(&samples[i][k].ns, ns)
					append(&samples[i][k].seal_ns, seal_ns)
					append(&samples[i][k].make_ns, make_ns)
				}
			}
		}
	}

	fmt.printfln("%-6s %6s %10s %10s %10s %10s %10s %10s %7s", "kind", "rows", "median ms", "min ms", "max ms", "seal ms", "make ms", "bytes", "allocs")
	for n, i in sizes {
		for k in Kind {
			s := &samples[i][k]
			slice.sort(s.ns[:])
			fmt.printfln(
				"%-6v %6s %10s %10s %10s %10s %10s %10s %7s",
				k,
				fmt.tprint(n),
				ms(s.ns[len(s.ns) / 2]),
				ms(s.ns[0]),
				ms(s.ns[len(s.ns) - 1]),
				ms(median(s.seal_ns[:])),
				ms(median(s.make_ns[:])),
				fmt.tprint(s.bytes),
				fmt.tprint(s.allocs),
			)
		}
	}
	fmt.printfln("%d timed calls per row, %d ms apart, all files read back (%x)", opt.runs, opt.gap, sink & 0xffff)
}

// timed_seal times the disk thread's part of a save.
timed_seal :: proc(blob: []u8, k: Kind) -> i64 {
	start := time.tick_now()
	switch k {
	case .List:
		app.file_seal(blob)
	case .Queue:
		app.queue_seal(blob)
	}
	return i64(time.tick_since(start))
}

// timed_make times allocating and zeroing the file on its own, outside the
// save's timed region, to show what limits it.

timed_make :: proc(n: int, sink: ^u64) -> i64 {
	start := time.tick_now()
	b := make([]u8, n)
	b[n - 1] = 1
	ns := i64(time.tick_since(start))
	sink^ += u64(b[n / 2])
	delete(b)
	return ns
}

median :: proc(ns: []i64) -> i64 {
	slice.sort(ns)
	return ns[len(ns) / 2]
}

timed_save :: proc(d: ^app.Data, rows: []app.Row, k: Kind) -> ([]u8, i64) {
	start := time.tick_now()
	blob := save(d, rows, k, runtime.heap_allocator())
	return blob, i64(time.tick_since(start))
}

save :: proc(d: ^app.Data, rows: []app.Row, k: Kind, allocator: runtime.Allocator) -> []u8 {
	switch k {
	case .List:
		return app.list_encode(&d.view, allocator)
	case .Queue:
		copied := make([]app.Row, len(rows), context.temp_allocator)
		for &r, i in rows {
			copied[i] = r
		}
		head := app.Queue_Header {
			index  = 3,
			sample = 44100 * 30,
			rate   = 44100,
		}
		return app.queue_encode(head, copied, allocator)
	}
	return nil
}

// count_allocs is the bytes save hands to the disk thread and the
// allocations it makes, on the heap and in the temp allocator.
count_allocs :: proc(d: ^app.Data, rows: []app.Row, k: Kind) -> (bytes, allocs: int) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	temp := context.temp_allocator
	context.temp_allocator = mem.tracking_allocator(&track)
	blob := save(d, rows, k, mem.tracking_allocator(&track))
	bytes = len(blob)
	allocs = int(track.total_allocation_count)
	delete(blob, mem.tracking_allocator(&track))
	context.temp_allocator = temp
	return
}

// check decodes the sealed file and fails unless it holds the n rows that
// went in, so a run can't time work that didn't happen.
check :: proc(blob: []u8, n: int, k: Kind) -> u64 {
	data, _ := mem.alloc_bytes_non_zeroed(len(blob), 16, context.temp_allocator)
	copy(data, blob)
	got: []app.Row
	err: app.File_Error
	switch k {
	case .List:
		_, got, err = app.list_decode(data, .Liked, "", context.temp_allocator)
	case .Queue:
		_, got, err = app.queue_decode(data, context.temp_allocator)
	}
	if err != .None || len(got) != n || got[n - 1].id != i64(n) || got[n - 1].title == "" {
		fmt.eprintfln("save_cost: %v file of %d rows read back as %d rows, %v", k, n, len(got), err)
		os.exit(1)
	}
	return hash.fnv64a(blob)
}

// make_rows is n rows with text of TIDAL's usual lengths, each string its
// own allocation as a page's are.
make_rows :: proc(n: int) -> []app.Row {
	rows := make([]app.Row, n)
	artists := []app.Artist_Ref{{id = 42, start = 0, end = len("Björk")}, {id = 43, start = len("Björk, "), end = len("Björk, Fairuz Al Haddad")}}
	for &r, i in rows {
		id := i64(i + 1)
		r = {
			title    = fmt.aprintf("Song number %d (Remastered 2011)", id),
			artist   = strings.clone("Björk, Fairuz Al Haddad"),
			album    = fmt.aprintf("An Album Called %d", id % 400),
			added    = strings.clone("Jan 5, 2026"),
			duration = strings.clone("3:05"),
			cover    = fmt.aprintf("0f1e2d3c-0000-4000-8000-%012d", id % 400),
			seconds  = 185 + int(id % 60),
			id       = id,
			album_id = id % 400 + 1,
			artists  = slice.clone(artists[:1 + int(id % 5 == 0)]),
			track    = int(id % 12) + 1,
		}
	}
	return rows
}

ms :: proc(ns: i64) -> string {
	return fmt.tprintf("%.3f", f64(ns) / 1e6)
}
