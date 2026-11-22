// Bindings for the dr_flac procedures the app uses. dr_flac.h next to this
// file is dr_flac 0.13.3 from github.com/mackron/dr_libs (commit 69d777c).
// build.py compiles it from dr_flac.c, without stdio and Ogg.
package dr_flac

import "core:c"

// build.py points C_BUILD at another folder for a sanitizer build.
@(private)
C_BUILD :: #config(TIDALFAST_C_BUILD, "build")
@(private)
LIB :: "../../build/windows/dr_flac/dr_flac.lib" when ODIN_OS == .Windows else "../../" + C_BUILD + "/dr_flac/dr_flac.a"

when !#exists(LIB) {
	#panic(LIB + " is missing: run ./build.py first")
}

foreign import lib { LIB }

VERSION :: [3]u32{0, 13, 3}

// Flac is dr_flac's decoder. Only pointers to it are used.
Flac :: struct {}

Seek_Origin :: enum c.int {
	Set,
	Cur,
	End,
}

Read_Proc :: #type proc "c" (user: rawptr, out: rawptr, bytes: c.size_t) -> c.size_t
Seek_Proc :: #type proc "c" (user: rawptr, offset: c.int, origin: Seek_Origin) -> b32
Tell_Proc :: #type proc "c" (user: rawptr, cursor: ^i64) -> b32

@(default_calling_convention = "c", link_prefix = "drflac_")
foreign lib {
	// allocation is a drflac_allocation_callbacks, nil for malloc.
	open :: proc(on_read: Read_Proc, on_seek: Seek_Proc, on_tell: Tell_Proc, user: rawptr, allocation: rawptr) -> ^Flac ---
	open_memory :: proc(data: rawptr, size: c.size_t, allocation: rawptr) -> ^Flac ---
	close :: proc(flac: ^Flac) ---
	// read_pcm_frames_f32 writes interleaved floats, v / 2^(bits-1) for an
	// integer sample v, and returns the frames read: fewer at the end.
	read_pcm_frames_f32 :: proc(flac: ^Flac, frames: u64, out: [^]f32) -> u64 ---
	version :: proc(major, minor, revision: ^u32) ---
}

@(init, private)
version_check :: proc "contextless" () {
	v: [3]u32
	version(&v.x, &v.y, &v.z)
	if v != VERSION {
		panic_contextless("dr_flac version mismatch: run ./build.py")
	}
}
