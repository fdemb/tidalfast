# Hot reload

Run `./build/tidalfast`, edit something in `src/`, then run `./build.sh app`. The running window picks up the change.

The shell watches `build/` with FSEvents. `build.sh` writes the dylib to a temp name and renames it into place, so the shell never sees a half-written file. When `app.dylib` changes, the shell copies it to a unique temp path and `dlopen`s the copy, which leaves the linker free to overwrite the original. Release builds have no watcher and open `app.dylib` in place: macOS checks the signature of a file it hasn't seen on every `dlopen`, so a fresh copy took about 100 ms to open at each launch, against under 10 ms for the same file again. If the new dylib's ABI version matches, the shell calls `unload` on the old app and `reload` on the new one, then redraws. The old dylib stays open. A dylib that fails to load is skipped and the old one keeps running. If the shaders in the new dylib don't compile, the app logs the error and keeps drawing with the previous pipeline.

The app keeps its state in memory the shell allocates once: a persistent block and a frame block. `State` sits at the start of the persistent block, and the rest is an arena. The frame arena is `context.temp_allocator` and resets every frame. A reload doesn't touch either block, so state carries over. The persistent arena never zeroes what it hands out: it only moves forward through pages nobody has written, since resetting `State` maps fresh zero pages over the whole block. Zeroing touched every page of the 23 MB of caches made at start (the shaper's 8 MB, the glyph pool, the box table), most of which are never written, and made them count against the app's memory.

What the app may keep across a reload:

- Plain data in `State` and in the persistent arena.
- Obj-C object pointers such as the Metal device, queue and layer. The Obj-C runtime owns them, not the dylib.
- `State_Header.release`, and the shell's `request_redraw` that the text loader keeps. See below.

What it may not keep:

- Odin globals. Each loaded copy has its own.
- Other procedure pointers, including `mem.Allocator` values and `[dynamic]` arrays and maps, which hold an allocator. Each entry point rebuilds the allocators from the arenas.
- Running threads. The text loader thread, the data workers and the audio player's threads run dylib code, so `unload` joins them and `reload` starts new ones. The audio callback is dylib code too, so the device stops for a reload; see [Playback](playback.md).
- Anything the dylib's own runtime allocated, such as the `os.File` behind the spall trace. The app keeps only the file descriptor.
- Data whose layout changed. Bump `STATE_VERSION` when a field changes type or moves and the size happens to stay the same.

`State` starts with `State_Header`: a magic number, the version, the size, and `release`, which frees everything that `State` owns (the Metal queue, pipeline, textures, instance buffers and in-flight command buffers, the text system's CF objects and mapped font files, and the spall file). Every version of the app sets `release` to its own `app_shutdown` on init and on reload. When a new dylib finds a different version or size, it can't read the old `State`, but it can read the header, so it calls `release` and runs the old code against the old layout before it resets `State`. Never change `State_Header`: it's how one version finds another's cleanup.

The magic number (`STATE_MAGIC`, "TFSTATE1") came with the text phase. Builds before it had a header without one, or none at all, and in those the bytes where `release` sits now can be an arena pointer: calling it crashed the shell with SIGBUS. So when the magic doesn't match, the app trusts nothing in the old `State`. It logs that, resets without calling anything, and leaks what the old state held.

That only works because the shell never closes an old dylib, so the old `release` stays callable. macOS wouldn't unmap an Odin dylib anyway, since it uses thread-local storage. Each reload leaks one image, which is fine for a dev session.
