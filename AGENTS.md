# Working on TIDALfast

TIDALfast is a native TIDAL client in Odin for macOS and Linux, with a small shell that owns the window and loads the app as a hot-reloaded dylib (`src/app`): Obj-C on macOS (`shell/shell.m`), C on Wayland (`shell/shell_wayland.c`). `docs/architecture.md` has the layout and the main decisions, and the other files in `docs/` have the details of every part. This file covers what an agent needs to check its own work, since you can't see the window or hear the audio.

## Build and test

```
./build.sh              # debug shell + dylib in build/
./build.sh app          # dylib only; doesn't relink the shell
./build.sh release      # optimized, hot reload off
./build.sh measure      # the measurement app, mock server and tool in build/measure/
./build.sh dist         # TIDALfast.app and .dmg, or the AppImage, in build/dist/
odin test tests         # run ./build.sh once first: it builds build/kbts/kb_text_shape.a
```

Keep `./build.sh` clean with `-vet -strict-style`. `odin test tests` runs without `-strict-style`.

Per-OS code lives in `_darwin.odin` and `_linux.odin` files. `odin check src/app -no-entry-point -vet -strict-style -target:darwin_arm64` (and `-target:linux_amd64`) type-checks the other OS's files without its SDK, so check both after touching shared code.

Odin dev-2026-10 crashes the compiler on any Obj-C method call (`missing procedure 'objc_lookUpClass'`). Call Obj-C through `objc_msgSend` casts as `src/render` does, call C frameworks (CoreText, CoreAudio, Security) through hand-written foreign declarations, or put Obj-C-only code in `shell.m`.

## Seeing what the app does

The window is often covered or the screen locked, and real input may not reach it. Use these instead of looking:

- **Frames.** `TIDALFAST_CAPTURE=/tmp/x.tga` writes every presented frame, and keeps the drawables full size while the window is covered, which the shell otherwise shrinks to a pixel. Convert with `sips -s format png /tmp/x.tga --out /tmp/x.png` and look at it, at 1:1 crops for text. Layout bugs only show up at some window widths, so capture narrow, medium and wide windows (about 820, 1100 and 1600 pt).
- **Input without a person.** `TIDALFAST_SHELL_TEST="3:key=cmd+f;3.5:commit=Jóga;5:capture=/tmp/a.tga;6:quit"` drives keys, input-method calls (`mark=`, `commit=`, `ime`), accessibility (`ax-dump`, `ax-press=`) and captures through the shell's real entry points. `capture=` needs `TIDALFAST_CAPTURE` set too. The full step list is above `setup_shell_test` in `shell.m`.
- **Data without an account.** `TIDALFAST_FAKE=1` gives 10,000 fake rows that play sine tones. It uses the default settings and saves none, unless `TIDALFAST_SETTINGS` names a file. For the real network path, run `tests/mock_tidal` and point a debug build at it with `TIDALFAST_API=http://127.0.0.1:<port>`; `TIDALFAST_PKCE_REDIRECT` logs in without a browser. The mock's flags (rate limits, revoked logins, hi-res DASH, AAC for the device client) are listed at the top of `tests/mock_tidal/main.odin`.
- **What's playing.** `TIDALFAST_STATUS_BAR=1` shows a line under the player bar: Playing, Paused or Ended with the track's title and artist, then the status line (copied links, adds to playlists, list errors). It shows in captures and as a static text in `ax-dump`, so a test can check what's playing without listening.
- **Audio without speakers.** `TIDALFAST_AUDIO_NULL=1` plays to a null device in real time. `TIDALFAST_AUDIO_CAPTURE=/tmp/a.wav` records exactly what reaches the device; `tests/audio_check` (gapless) and `tests/bitperfect_check` compare it with the source.
- **Media keys and Now Playing.** `TIDALFAST_REMOTE_TEST` sends remote commands through the media key path, and `TIDALFAST_NOW_PLAYING_LOG=1` prints what macOS holds.
- **Logs.** The app logs through `core:log` to stderr, info and up. `TIDALFAST_LOG_HTTP=1` adds a debug line per TIDAL request, with the URL cut at its query by `tidal.url_for_log`.
- **Frame time.** `TIDALFAST_BENCH=1` (library), `=text` or `=covers` (live data, so set `TIDALFAST_API` to the mock with it) auto-scrolls and logs CPU time per frame; `measure frames` (see `docs/measuring.md`) runs it for the frame rate and the CPU and GPU time per frame. `TIDALFAST_OVERLAY=1` or the backtick key shows the overlay: frame and UI time, the GPU's time on macOS, draw calls, instances, memory.
- **Profiling.** `TIDALFAST_SPALL=path` writes a spall trace. `sample <pid>` has hung in this environment before; timers inside the code worked when it did.
- **Metal.** `MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1` turns on validation.
- **Linux without a display.** Run `weston --backend=headless` with its own `XDG_RUNTIME_DIR` and socket, and point the app at it with `WAYLAND_DISPLAY`. Mesa's lavapipe is a software Vulkan device. `size=w,h` in `TIDALFAST_SHELL_TEST` resizes the window, since nobody else will. `docs/linux.md` has the commands, including running the keychain test against a throwaway keyring in a private D-Bus session.

## Measuring RAM and startup

Run this before and after any change that could affect memory or startup:

```
./build.sh measure
./build/measure/measure all
./build/measure/measure compare docs/measure-baseline.json build/measure/<time>.json
```

To judge a change, `./build/measure/measure ab main` measures this checkout against main in one sitting, the two builds taking turns, and marks a change only when the paired runs agree. Its `ui_instructions` rows are the steadiest. A stored baseline from another day differs by tens of milliseconds on time alone. `measure launches` reads the app's own log of real launches.

`measure all` does 10 cold launches and a memory scenario (idle, a large list open, scrolled with covers, playing, idle again), with fake data and against its own mock. It prints medians and writes JSON. `compare` marks changes of 10% and at least 1 ms or MB. Footprint is what Activity Monitor shows, and on Apple silicon it includes GPU memory, so don't add the `ram` and `gpu` numbers together. The first launch after a build is slow because macOS checks the new binary's signature; the tool reports it separately. Update `docs/measure-baseline.json` and the numbers in `docs/measuring.md` when a change moves them on purpose. `-real` uses the user's account and is only for the user to run.

## Idle CPU

The app draws only on input, worker results or a running animation. After any change, check that an idle window uses 0% CPU: CPU time from `ps -o time= -p <pid>` shouldn't move over 10 s. Anything that animates must stop asking for frames once it settles.

## Things that hurt the user

- **Keychain.** Never read, write or delete the real item, service `tidalfast`, and never log in to real TIDAL. Against the mock, use `TIDALFAST_KEYCHAIN=tidalfast-<task>-<random>` and delete it afterwards with `security delete-generic-password -s <name>`. Relinking the shell changes its ad-hoc signature and makes macOS ask the user for Keychain access again, so don't change `shell/` or run a full `./build.sh` unless the change needs it.
- **Processes.** The user may have the app running. Kill only processes you started, by PID. Never `pkill tidalfast`. A running debug build hot-reloads `build/app.dylib`, so a dylib you build in the main checkout ends up in the user's app; put throwaway builds elsewhere (`-out:/tmp/...`).
- **Audio devices.** Bit-perfect mode changes the output device's sample rate and format, can hog it, and skips the volume. Test it only with the mock's -60 dBFS tracks, never with the fake tones. Afterwards, check that the default output device is back at its old nominal rate and physical format and not hogged, and restore it if not.
- **Logs.** Never print tokens, Authorization headers, stream or CDN URLs, the pasted PKCE redirect or raw server text. Log error kinds, HTTP status and known codec names (`tidal.error_summary`).

## Conventions

- Commits: conventional, lowercase, a subject line only, no body, no Co-Authored-By.
- Code: plain handmade Odin, procedures and structs, comments only where they say something the code doesn't.
- Docs and comments: plain direct English, sentence-case headings, no em dashes.
- `shell/platform.h` and `src/platform/platform.odin` are one ABI. Change both, keep their size checks, and bump the ABI version together. `tests/abi_test.odin` compares every field's offset across the two; add a new shared struct to its list.
- A reload resets `State` when its layout changes (`state_version` in `src/app/app.odin` hashes it). Bump `STATE_VERSION` when a reload must not reuse old state for another reason, such as a field whose meaning changed.
- Prove a bug fix with a test that fails on the commit before it.
