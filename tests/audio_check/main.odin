// Checks a capture of the player's output (TIDALFAST_AUDIO_CAPTURE) against
// the 16-bit source it was encoded from (the mock's album-source.wav):
//
//     odin run tests/audio_check -o:speed -- capture.wav /tmp/tidalfast-mock-audio/album-source.wav [boundary ...]
//
// It finds where the source starts in the capture, works out the gain the
// player applied (ReplayGain times volume), and then compares every frame
// to the source times that gain. A gap, a dropped or repeated frame, or a
// gain change at a track boundary shows up as a mismatch. Boundaries are
// source frame numbers; for each, it prints the error in the frames around
// it. Exits 1 on any mismatch.
package audio_check

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"

Wav :: struct {
	rate, channels: int,
	float:          bool,
	data:           []u8,
}

read_wav :: proc(path: string) -> (w: Wav, ok: bool) {
	bytes, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(bytes) < 44 || string(bytes[0:4]) != "RIFF" {
		return
	}
	u16le :: proc(b: []u8) -> int {return int(b[0]) | int(b[1]) << 8}
	u32le :: proc(b: []u8) -> int {return int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16 | int(b[3]) << 24}
	pos := 12
	for pos + 8 <= len(bytes) {
		id := string(bytes[pos:pos + 4])
		size := u32le(bytes[pos + 4:])
		body := bytes[pos + 8:]
		switch id {
		case "fmt ":
			w.float = u16le(body) == 3
			w.channels = u16le(body[2:])
			w.rate = u32le(body[4:])
		case "data":
			// A capture cut short has a zero size; take the rest of the file.
			n := size if size > 0 && size <= len(body) else len(body)
			w.data = body[:n]
			return w, true
		}
		pos += 8 + size
	}
	return
}

frame_count :: proc(w: Wav) -> int {
	return len(w.data) / (w.channels * (4 if w.float else 2))
}

sample :: proc(w: Wav, frame, ch: int) -> f64 {
	i := frame * w.channels + ch
	if w.float {
		b := w.data[i * 4:]
		bits := u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
		return f64(transmute(f32)bits)
	}
	b := w.data[i * 2:]
	return f64(i16(u16(b[0]) | u16(b[1]) << 8)) / 32768
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: audio_check capture.wav source.wav [boundary frame ...]")
		os.exit(2)
	}
	cap, ok1 := read_wav(os.args[1])
	src, ok2 := read_wav(os.args[2])
	if !ok1 || !ok2 || cap.channels != src.channels {
		fmt.eprintln("audio_check: can't read the files, or their channel counts differ")
		os.exit(2)
	}
	nc, ns := frame_count(cap), frame_count(src)
	fmt.printfln("capture: %d frames (%.2f s) at %d Hz; source: %d frames (%.2f s)", nc, f64(nc) / f64(cap.rate), cap.rate, ns, f64(ns) / f64(src.rate))

	// The first sound in the capture.
	c0 := 0
	for c0 < nc && sample(cap, c0, 0) == 0 && sample(cap, c0, 1) == 0 {
		c0 += 1
	}
	if c0 == nc {
		fmt.println("FAIL: the capture is silent")
		os.exit(1)
	}
	// The volume ramps in over the first buffer, so line up and measure
	// the gain a little later.
	SKIP :: 4096
	WIN :: 256
	a := c0 + SKIP
	best_k, best_err, best_g := -1, max(f64), 0.0
	for k in 0 ..< ns - SKIP - WIN {
		g, e := fit(cap, src, a, k + SKIP, WIN)
		if e < best_err {
			best_k, best_err, best_g = k, e, g
			if e < 1e-12 {
				break
			}
		}
	}
	fmt.printfln("source frame %d starts at capture frame %d; gain x%.6f (%.2f dB), fit error %.3g", best_k, c0, best_g, 20 * math.log10(best_g), best_err)

	// Every frame after the ramp, until either file ends or the capture
	// goes silent at the end of the queue.
	TOL :: 2e-6
	mismatches, first_bad := 0, -1
	max_err := 0.0
	last := 0
	for j in SKIP ..< min(nc - c0, ns - best_k) {
		for ch in 0 ..< cap.channels {
			e := abs(sample(cap, c0 + j, ch) - best_g * sample(src, best_k + j, ch))
			max_err = max(max_err, e)
			if e > TOL {
				mismatches += 1
				if first_bad < 0 {
					first_bad = best_k + j
				}
			}
		}
		last = best_k + j
	}
	fmt.printfln("compared source frames %d to %d (%.2f s): max error %.3g, %d samples off", best_k + SKIP, last, f64(last - best_k - SKIP) / f64(src.rate), max_err, mismatches)
	for arg in os.args[3:] {
		b, _ := strconv.parse_int(arg)
		worst := 0.0
		for j in max(b - 64, best_k + SKIP) ..< min(b + 64, last + 1) {
			for ch in 0 ..< cap.channels {
				worst = max(worst, abs(sample(cap, c0 + j - best_k, ch) - best_g * sample(src, j, ch)))
			}
		}
		covered := b > best_k + SKIP && b < last
		fmt.printfln("boundary at source frame %d (%.3f s): %s, max error within 64 frames %.3g", b, f64(b) / f64(src.rate), "played through" if covered else "NOT COVERED", worst)
		if !covered {
			mismatches += 1
		}
	}
	if mismatches > 0 {
		if first_bad >= 0 {
			fmt.printfln("FAIL: first mismatch at source frame %d (%.3f s)", first_bad, f64(first_bad) / f64(src.rate))
		} else {
			fmt.println("FAIL")
		}
		os.exit(1)
	}
	fmt.println("PASS: the capture is the source, sample for sample, times one gain")
}

// fit finds the gain g that best maps src[k:k+n] onto cap[c:c+n] and
// returns it with the mean squared error left.
fit :: proc(cap, src: Wav, c, k, n: int) -> (g, err: f64) {
	cs, ss: f64
	for j in 0 ..< n {
		for ch in 0 ..< cap.channels {
			x, y := sample(src, k + j, ch), sample(cap, c + j, ch)
			cs += x * y
			ss += x * x
		}
	}
	if ss == 0 {
		return 0, max(f64)
	}
	g = cs / ss
	for j in 0 ..< n {
		for ch in 0 ..< cap.channels {
			d := sample(cap, c + j, ch) - g * sample(src, k + j, ch)
			err += d * d
		}
	}
	return g, err / f64(n * cap.channels)
}
