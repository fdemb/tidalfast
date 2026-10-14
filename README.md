# TIDALfast

A native macOS TIDAL client in Odin. A small Obj-C shell owns the window and talks to macOS. Everything else is an Odin dylib that the shell reloads while it runs. `docs/plan.md` has the plan and the phases.

```
shell/          Obj-C executable: window, CAMetalLayer, event queue, dylib loader
src/platform/   the ABI between shell and app (shell/platform.h mirrors it)
src/app/        the hot-reloaded app dylib
src/render/     Metal renderer
src/tidal/      TIDAL API library, see src/tidal/README.md
tests/          `odin test tests`
examples/cli/   CLI on top of src/tidal
```

## Building and running

```
./build.sh              # debug: build/tidalfast and build/app.dylib
./build.sh app          # rebuild only the dylib
./build.sh release      # optimized, hot reload off
./build/tidalfast
```

It needs macOS 14 or later, Odin and the Xcode command line tools. Shaders are compiled at runtime from source in `src/render`, so the Metal toolchain isn't needed.

Environment variables:

- `TIDALFAST_SPALL=path` writes a [spall](https://gravitymoth.com/spall/) trace of every frame to `path`.
- `TIDALFAST_LOG_EVENTS=1` prints every input event.
- `TIDALFAST_CAPTURE=path` writes each presented frame to `path` as a TGA. It's for checking output when you can't take screenshots.

The backtick key toggles the frame-time overlay, which plots the CPU time of the last 120 frames against 120 Hz and 60 Hz lines.

## Hot reload

Run `./build/tidalfast`, edit something in `src/`, then run `./build.sh app`. The running window picks up the change.

The shell watches `build/` with FSEvents. `build.sh` writes the dylib to a temp name and renames it into place, so the shell never sees a half-written file. When `app.dylib` changes, the shell copies it to a unique temp path and `dlopen`s the copy, which leaves the linker free to overwrite the original. If the new dylib's ABI version matches, the shell calls `unload` on the old app and `reload` on the new one, then redraws. A dylib that fails to load is skipped and the old one keeps running. If the shaders in the new dylib don't compile, the app logs the error and keeps drawing with the previous pipeline.

The app keeps its state in memory the shell allocates once: a persistent block and a frame block. `State` sits at the start of the persistent block, and the rest is an arena. The frame arena is `context.temp_allocator` and resets every frame. A reload doesn't touch either block, so state carries over.

What the app may keep across a reload:

- Plain data in `State` and in the persistent arena.
- Obj-C object pointers such as the Metal device, queue and layer. The Obj-C runtime owns them, not the dylib.

What it may not keep:

- Odin globals. Each loaded copy has its own.
- Procedure pointers, including `mem.Allocator` values and `[dynamic]` arrays and maps, which hold an allocator. Each entry point rebuilds the allocators from the arenas.
- Anything the dylib's own runtime allocated, such as the `os.File` behind the spall trace. The app keeps only the file descriptor.
- Data whose layout changed. On reload the app compares `State`'s size and `STATE_VERSION` with what it finds in memory. On a mismatch it resets `State` and leaks the old Metal objects. Bump `STATE_VERSION` when a field changes type or moves and the size happens to stay the same.

The old dylib is never unmapped. Odin uses thread-local storage, and macOS doesn't unload images that have it. Each reload leaks one image, which is fine for a dev session.

## Redraw policy

The shell draws only when something asks for a frame: input, a resize, a reload, or `request_redraw` from any thread. `request_redraw` sets a flag and calls `CFRunLoopWakeUp`. A run loop observer draws just before the main thread sleeps, so a burst of events becomes one frame. These frames don't depend on the display link, so they still happen while the window is hidden or the display sleeps.

If the app returns `animating = true`, the view's `CADisplayLink` adds a frame every vsync until the app returns false. The shell pauses the link while the window is minimized or fully covered, so a hidden animation costs no CPU. An idle window uses no CPU.

The shell merges mouse moves, and scroll events in the same phase, into one event with the summed delta. Phase changes such as a gesture beginning or ending keep their own event. If 1,024 events pile up before a frame, the shell draws a frame on the spot rather than drop any, so the app never misses a button or key release.
