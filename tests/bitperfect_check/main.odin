// Checks a capture from TIDALFAST_AUDIO_CAPTURE against the integer WAVs
// the tracks were made from, bit for bit:
//
//     odin run tests/bitperfect_check -- capture.wav a-source.wav b-source.wav ...
//
// Each source must appear whole in the capture, in order, as v / 2^(bits-1)
// in 32-bit float, which is what bit-perfect output hands the device. It
// reports where each one starts, how many samples differ (0 when nothing
// touched them) and the silence between one and the next. The capture's
// header gives the rate of the first device open only, so frame counts
// between tracks at different rates are just that: frames.
package bitperfect_check

import "core:fmt"
import "core:os"

Wav :: struct {
	rate, channels, bits: int,
	float:                bool,
	data:                 []u8,
}

read_wav :: proc(path: string) -> (w: Wav, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(data) < 44 || string(data[0:4]) != "RIFF" {
		return
	}
	le16 :: proc(b: []u8) -> int {return int(b[0]) | int(b[1]) << 8}
	le32 :: proc(b: []u8) -> int {return le16(b) | le16(b[2:]) << 16}
	pos := 12
	for pos + 8 <= len(data) {
		id, size := string(data[pos:pos + 4]), le32(data[pos + 4:])
		body := data[pos + 8:]
		switch id {
		case "fmt ":
			w.float = le16(body) == 3
			w.channels = le16(body[2:])
			w.rate = le32(body[4:])
			w.bits = le16(body[14:])
		case "data":
			// A capture still being written says 0.
			n := len(body) if size == 0 else min(size, len(body))
			w.data = body[:n]
			return w, w.channels > 0
		}
		pos += 8 + size + (size & 1)
	}
	return
}

// samples returns the WAV as the floats bit-perfect output would carry.
samples :: proc(w: Wav) -> []f32 {
	if w.float {
		return ([^]f32)(raw_data(w.data))[:len(w.data) / 4]
	}
	bytes := w.bits / 8
	out := make([]f32, len(w.data) / bytes)
	for &v, i in out {
		x: i32
		for b in 0 ..< bytes {
			x |= i32(w.data[i * bytes + b]) << uint(8 * b)
		}
		x = x << uint(32 - w.bits) >> uint(32 - w.bits) // sign extend
		v = f32(f64(x) / f64(i64(1) << uint(w.bits - 1)))
	}
	return out
}

find :: proc(hay, needle: []f32, from: int) -> int {
	outer: for i in from ..= len(hay) - len(needle) {
		for n, k in needle {
			if transmute(u32)hay[i + k] != transmute(u32)n {
				continue outer
			}
		}
		return i
	}
	return -1
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: bitperfect_check capture.wav source.wav ...")
		os.exit(2)
	}
	cap, ok := read_wav(os.args[1])
	if !ok || !cap.float {
		fmt.eprintln("the capture isn't a float WAV")
		os.exit(2)
	}
	got := samples(cap)
	ch := cap.channels
	fmt.printfln("capture: %d frames, header rate %d", len(got) / ch, cap.rate)
	pos := 0
	prev_end := -1
	failed := false
	for path in os.args[2:] {
		src, sok := read_wav(path)
		if !sok || src.channels != ch {
			fmt.eprintfln("%s: can't read it, or its channels differ", path)
			os.exit(2)
		}
		want := samples(src)
		at := find(got, want[:min(len(want), 4096)], pos)
		if at < 0 {
			fmt.printfln("%s (%d-bit %d Hz): not found", path, src.bits, src.rate)
			failed = true
			continue
		}
		differ := 0
		first_bad := -1
		for w, i in want {
			if at + i >= len(got) || transmute(u32)got[at + i] != transmute(u32)w {
				if first_bad < 0 {
					first_bad = i / ch
				}
				differ += 1
			}
		}
		fmt.printfln("%s (%d-bit %d Hz): starts at frame %d, %d frames, %d samples differ%s", path, src.bits, src.rate, at / ch, len(want) / ch, differ, fmt.tprintf(" (first at frame %d)", first_bad) if differ > 0 else "")
		if prev_end >= 0 {
			fmt.printfln("    %d frames between it and the track before", (at - prev_end) / ch)
		}
		failed ||= differ > 0
		pos = at + len(want)
		prev_end = pos
	}
	os.exit(1 if failed else 0)
}
