# Working on TIDALfast

TIDALfast is a native TIDAL client in Odin for macOS and Linux, with a first Windows build, and a small shell that owns the window: Obj-C on macOS (`shell/shell_cocoa.m`), C on Wayland (`shell/shell_wayland.c`) and Win32 (`shell/shell_win32.c`), with `shell/common.c` shared by all three. Odin links the two into one executable, whose `main` in `src/app` hands the process to the shell. `docs/architecture.md` has the layout and the main decisions, and the other files in `docs/` have the details of every part. This file covers what an agent needs to check its own work, since you can't see the window or hear the audio.

## Build and test

```
./build.py              # debug build/tidalfast
./build.py release      # optimized
./build.py measure      # the measurement app, mock server and tool in build/measure/
./build.py dist         # TIDALfast.app and .dmg, or the AppImage, in build/dist/
./build.py libs         # only the C libraries in third_party, into build/kbts and build/dr_flac
./build.py test         # what the tests link, then odin test tests; odin's flags go after --
```

`--out DIR` puts a build in `DIR` in place of `build/`. Keep `./build.py` clean with `-vet -strict-style`. The tests run without `-strict-style`.

Per-OS code lives in `_darwin.odin`, `_linux.odin` and `_windows.odin` files. Shared code doesn't import `core:sys/posix`; `src/sys` has threads, local time, the page size and file mappings for every OS. CI (`.github/workflows/ci.yml`) builds and tests all three on every push and pull request, so push a branch to check shared code on the other systems.

`src/render` calls Metal through `vendor:darwin/Metal` and `vendor:darwin/QuartzCore` with Odin's Obj-C method calls (`device->newCommandQueue()`). C frameworks (CoreText, CoreAudio, Security) go through hand-written foreign declarations. `vendor:darwin/Metal` brings in `core:sys/darwin/CoreFoundation`, and Odin rejects a C function declared twice with different types, so a hand-written CoreFoundation declaration has to match that package's: `b8` for `Boolean`, `int` for `CFStringEncoding`.

## Seeing what the app does

The window is often covered or the screen locked, and real input may not reach it. Use these instead of looking:

- **Frames.** `TIDALFAST_CAPTURE=/tmp/x.tga` writes every presented frame, and keeps the drawables full size while the window is covered, which the shell otherwise shrinks to a pixel. Convert with `sips -s format png /tmp/x.tga --out /tmp/x.png` (on Linux, `magick /tmp/x.tga /tmp/x.png`) and look at it, at 1:1 crops for text. Layout bugs only show up at some window widths, so capture narrow, medium and wide windows (about 820, 1100 and 1600 pt).
- **Input without a person.** `TIDALFAST_SHELL_TEST="3:key=cmd+f;3.5:commit=Jóga;5:capture=/tmp/a.tga;6:quit"` drives keys, input-method calls (`mark=`, `commit=`, `ime`), accessibility (`ax-dump`, `ax-press=`) and captures through the shell's real entry points. `capture=` needs `TIDALFAST_CAPTURE` set too. The shared steps are listed above `test_step` in `shell/common.c`. Each OS adds its own above `os_test_step`: macOS `size=w,h`, `hide`, `unhide` and `menu=` in `shell_cocoa.m`, Linux `size=w,h`, `click=x,y`, `window` and the others in `shell_wayland.c`, and Windows the steps in `docs/windows.md`.
- **Data without an account.** `TIDALFAST_FAKE=1` gives 10,000 fake rows that play sine tones. It uses the default settings and saves none, unless `TIDALFAST_SETTINGS` names a file. For the real network path, run `tests/mock_tidal` and point a debug build at it with `TIDALFAST_API=http://127.0.0.1:<port>`; `TIDALFAST_PKCE_REDIRECT` logs in without a browser. The mock's flags (rate limits, revoked logins, hi-res DASH, AAC for the device client) are listed at the top of `tests/mock_tidal/main.odin`.
- **What's playing.** `TIDALFAST_STATUS_BAR=1` shows a line under the player bar: Playing, Paused or Ended with the track's title and artist, then the status (copied links, adds to playlists, list errors, TIDAL's rate limit). The views show none of this anywhere else, except errors, which also get a toast (`###toast`, a static text in `ax-dump`). It shows in captures and as a static text in `ax-dump`, so a test can check what's playing without listening.
- **Audio without speakers.** `TIDALFAST_AUDIO_NULL=1` plays to a null device in real time. `TIDALFAST_AUDIO_CAPTURE=/tmp/a.wav` records exactly what reaches the device; `tests/audio_check` (gapless) and `tests/bitperfect_check` compare it with the source.
- **Media keys and Now Playing.** `TIDALFAST_REMOTE_TEST` sends remote commands through the media key path, and `TIDALFAST_NOW_PLAYING_LOG=1` prints what the app sets, and on macOS and Windows what the system holds. On Linux, `playerctl -p tidalfast` (or `dbus-send`) asks the app's MPRIS server as a desktop would, inside the tests' own `dbus-run-session`.
- **Logs.** The app logs through `core:log` to stderr, info and up. `TIDALFAST_LOG_HTTP=1` adds a debug line per TIDAL request, with the URL cut at its query by `tidal.url_for_log`. A Windows release build without a console logs to `%LOCALAPPDATA%\tidalfast\tidalfast.log`.
- **Frame time.** `TIDALFAST_BENCH=1` (library), `=text` or `=covers` (live data, so set `TIDALFAST_API` to the mock with it) auto-scrolls and logs CPU time per frame; `measure frames` (see `docs/measuring.md`) runs it for the frame rate and the CPU and GPU time per frame. `TIDALFAST_OVERLAY=1` or the backtick key shows the overlay: frame and UI time, the GPU's time on macOS, draw calls, instances, memory.
- **Profiling.** `TIDALFAST_SPALL=path` writes a spall trace. `sample <pid>` has hung in this environment before; timers inside the code worked when it did.
- **Metal.** `MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1` turns on validation.
- **Direct3D 11.** `TIDALFAST_D3D11_DEBUG=1` makes the device with the debug layer, from Windows' optional Graphics Tools, and logs its messages through `core:log`. Without the layer installed it logs a warning and carries on. `TIDALFAST_D3D_BLT=1` makes a blt-model swap chain, which the compositor always composes and never hands to the display as an overlay plane, to tell a fault in that path from one in the frames.

## Measuring RAM and startup

When a change could move startup, memory or frame time, measure it against the code before it with `measure ab`. It runs two builds in one sitting, taking turns, and marks a change only when the paired runs agree:

```
./build.py measure                            # build/measure/: the app, the mock and the tool
./build/measure/measure ab <app a> <app b>    # add -memory for one memory run of each
```

How you get the two builds is up to you. With the mock setup both have to be measure builds. `./build.py measure --out /tmp/a` puts one in `/tmp/a/measure/app/tidalfast` and leaves `build/` alone. Judge on `ui_instructions` first: it moves least from run to run. Numbers from another day don't compare, since load and heat alone move times by tens of milliseconds. To judge memory, run `measure memory -runs=N` on each build. Footprint is what Activity Monitor shows, and on Apple silicon it includes GPU memory, so don't add the `ram` and `gpu` numbers together. `measure launches` reads the app's own log of real launches. `-real` uses the user's account and is only for the user to run. `docs/measuring.md` has the rest.

## Idle CPU

The app draws only on input, worker results or a running animation. After any change, check that an idle window uses 0% CPU: CPU time from `ps -o time= -p <pid>` shouldn't move over 10 s. Anything that animates must stop asking for frames once it settles.

## Things that hurt the user

- **Keychain.** Never read, write or delete the real item, service `tidalfast`, and never log in to real TIDAL. Against the mock, use `TIDALFAST_KEYCHAIN=tidalfast-<task>-<random>` and delete it afterwards with `security delete-generic-password -s <name>`, or `secret-tool clear service <name>` on Linux. On Windows the login is a generic credential named `<name>/auth` (and `<name>/auth#1` and on for a long one). On a Linux desktop, run the tests in their own `dbus-run-session` with throwaway `HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `XDG_RUNTIME_DIR`, or a keyring daemon started for them writes into the user's real keyrings (`docs/linux.md`).
- **Processes.** The user may have the app running. Kill only processes you started, by PID. Never `pkill tidalfast`. Put throwaway builds outside `build/` (`./build.py --out /tmp/...`), so the user's next launch doesn't pick them up.
- **Audio devices.** Bit-perfect mode changes the output device's sample rate and format and skips the volume. On Linux it forces PipeWire's graph rate while it plays. Test it only with the mock's -60 dBFS tracks, never with the fake tones. Afterwards, check that the default output device is back at its old nominal rate and physical format (`build/audio_top -once`, see `docs/playback.md`), and restore it if not.
- **Logs.** Never print tokens, Authorization headers, stream or CDN URLs, the pasted PKCE redirect or raw server text. Log error kinds, HTTP status and known codec names (`tidal.error_summary`).

## Conventions

- Commits: conventional, lowercase, a subject line only, no body, no Co-Authored-By.
- Code: plain handmade Odin, procedures and structs, comments only where they say something the code doesn't.
- First frames: a page's first frame must look like its second. While building, a box's `rect` and `view_bounds` are the last layout's, and zero on the frame the box first appears. Don't place or size anything from them. Give the build the sizes it needs in points (a scroll view's size, a text field's height) and let draw do the rest, as `draw_label` centres text in the final rect. Settle any state the frame depends on before the boxes that read it: send the search before choosing the view's top room, and pass `focus` to `text_field` instead of focusing it after. Reading `rect` is fine for input on a box already on screen, such as a click, a drag or a menu opened from a button. `tests/first_frame_test.odin` compares each page's first frame with the next, so add a new page to it.
- Docs and comments: plain direct English, sentence-case headings, no em dashes.
- `shell/platform.h` and `src/platform/platform.odin` are one ABI. Change both together and keep their size checks. `tests/abi_test.odin` compares every field's offset across the two; add a new shared struct to its list.
- Prove a bug fix with a test that fails on the commit before it.
