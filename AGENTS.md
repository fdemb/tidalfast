# Working on TIDALfast

TIDALfast is a native TIDAL client in Odin for macOS and Linux, with a first Windows build, and a small shell that owns the window: Obj-C on macOS (`shell/shell.m`), C on Wayland (`shell/shell_wayland.c`) and Win32 (`shell/shell_win32.c`, with `shell/common.c` shared with Wayland). Odin links the two into one executable, whose `main` in `src/app` hands the process to the shell. `docs/architecture.md` has the layout and the main decisions, and the other files in `docs/` have the details of every part. This file covers what an agent needs to check its own work, since you can't see the window or hear the audio.

## Build and test

```
./build.sh              # debug build/tidalfast
./build.sh release      # optimized
./build.sh measure      # the measurement app, mock server and tool in build/measure/
./build.sh dist         # TIDALfast.app and .dmg, or the AppImage, in build/dist/
./build.sh libs         # only the C libraries in third_party, into build/kbts, build/miniaudio and build/dr_flac
odin test tests         # run ./build.sh once first: it builds the C libraries
```

Keep `./build.sh` clean with `-vet -strict-style`. `odin test tests` runs without `-strict-style`.

Per-OS code lives in `_darwin.odin`, `_linux.odin` and `_windows.odin` files. Shared code doesn't import `core:sys/posix`; `src/sys` has threads, local time, the page size and file mappings for every OS. `odin check src/app -no-entry-point -vet -strict-style -target:darwin_arm64` (and `-target:linux_amd64`) type-checks the other OS's files without its SDK, so check both after touching shared code. For Windows, `odin check` refuses the target without an SDK, so build it: `WINDOWS_SDK=<xwin splat> ./build.sh windows` (`docs/windows.md`).

Odin dev-2026-10 crashes the compiler on any Obj-C method call (`missing procedure 'objc_lookUpClass'`). Call Obj-C through `objc_msgSend` casts as `src/render` does, call C frameworks (CoreText, CoreAudio, Security) through hand-written foreign declarations, or put Obj-C-only code in `shell.m`.

## Seeing what the app does

The window is often covered or the screen locked, and real input may not reach it. Use these instead of looking:

- **Frames.** `TIDALFAST_CAPTURE=/tmp/x.tga` writes every presented frame, and keeps the drawables full size while the window is covered, which the shell otherwise shrinks to a pixel. Convert with `sips -s format png /tmp/x.tga --out /tmp/x.png` (on Linux, `magick /tmp/x.tga /tmp/x.png`) and look at it, at 1:1 crops for text. Layout bugs only show up at some window widths, so capture narrow, medium and wide windows (about 820, 1100 and 1600 pt).
- **Input without a person.** `TIDALFAST_SHELL_TEST="3:key=cmd+f;3.5:commit=Jóga;5:capture=/tmp/a.tga;6:quit"` drives keys, input-method calls (`mark=`, `commit=`, `ime`), accessibility (`ax-dump`, `ax-press=`) and captures through the shell's real entry points. `capture=` needs `TIDALFAST_CAPTURE` set too. The full step list is above `setup_shell_test` in `shell.m`.
- **Data without an account.** `TIDALFAST_FAKE=1` gives 10,000 fake rows that play sine tones. It uses the default settings and saves none, unless `TIDALFAST_SETTINGS` names a file. For the real network path, run `tests/mock_tidal` and point a debug build at it with `TIDALFAST_API=http://127.0.0.1:<port>`; `TIDALFAST_PKCE_REDIRECT` logs in without a browser. The mock's flags (rate limits, revoked logins, hi-res DASH, AAC for the device client) are listed at the top of `tests/mock_tidal/main.odin`.
- **What's playing.** `TIDALFAST_STATUS_BAR=1` shows a line under the player bar: Playing, Paused or Ended with the track's title and artist, then the status (copied links, adds to playlists, list errors, TIDAL's rate limit). The views show none of this anywhere else, except errors, which also get a toast (`###toast`, a static text in `ax-dump`). It shows in captures and as a static text in `ax-dump`, so a test can check what's playing without listening.
- **Audio without speakers.** `TIDALFAST_AUDIO_NULL=1` plays to a null device in real time. `TIDALFAST_AUDIO_CAPTURE=/tmp/a.wav` records exactly what reaches the device; `tests/audio_check` (gapless) and `tests/bitperfect_check` compare it with the source.
- **Media keys and Now Playing.** `TIDALFAST_REMOTE_TEST` sends remote commands through the media key path, and `TIDALFAST_NOW_PLAYING_LOG=1` prints what macOS holds.
- **Logs.** The app logs through `core:log` to stderr, info and up. `TIDALFAST_LOG_HTTP=1` adds a debug line per TIDAL request, with the URL cut at its query by `tidal.url_for_log`.
- **Frame time.** `TIDALFAST_BENCH=1` (library), `=text` or `=covers` (live data, so set `TIDALFAST_API` to the mock with it) auto-scrolls and logs CPU time per frame; `measure frames` (see `docs/measuring.md`) runs it for the frame rate and the CPU and GPU time per frame. `TIDALFAST_OVERLAY=1` or the backtick key shows the overlay: frame and UI time, the GPU's time on macOS, draw calls, instances, memory.
- **Profiling.** `TIDALFAST_SPALL=path` writes a spall trace. `sample <pid>` has hung in this environment before; timers inside the code worked when it did.
- **Metal.** `MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1` turns on validation.
- **Linux without a display.** Run `weston --backend=headless` with its own `XDG_RUNTIME_DIR` and socket, and point the app at it with `WAYLAND_DISPLAY`. With a GPU, Weston needs `--renderer=gl`, or the Vulkan renderer finds no sRGB format and doesn't start. Without one, Mesa's lavapipe is a software Vulkan device. `size=w,h` in `TIDALFAST_SHELL_TEST` resizes the window, since nobody else will. On a desktop, run the app and the tests with throwaway `HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `XDG_RUNTIME_DIR`, in their own `dbus-run-session`. A temp `HOME` alone isn't enough, because desktops set the XDG variables and a keyring daemon started for the tests then writes into the user's real keyrings. `docs/linux.md` has the commands.
- **Windows without Windows.** `./build.sh windows` cross-builds `build/windows/tidalfast.exe` (`docs/windows.md`). Wine runs it, Hangover's Wine on ARM64 Linux, on an Xvfb with a Wine prefix of its own and `APPDATA` and `LOCALAPPDATA` pointed at a temp folder. Paths the app gets are Windows paths: `Z:\tmp\x.tga` for `/tmp/x.tga`. The shell test steps are the Linux ones, plus `move=x,y` and `click=x,y`, and `touchpad=dy` for a precision touchpad. Frame times under emulation mean nothing.

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

- **Keychain.** Never read, write or delete the real item, service `tidalfast`, and never log in to real TIDAL. Against the mock, use `TIDALFAST_KEYCHAIN=tidalfast-<task>-<random>` and delete it afterwards with `security delete-generic-password -s <name>`, or `secret-tool clear service <name>` on Linux. On Windows the login is a generic credential named `<name>/auth` (and `<name>/auth#1` and on for a long one); under Wine it lives in the throwaway prefix.
- **Processes.** The user may have the app running. Kill only processes you started, by PID, a headless Weston included. Never `pkill tidalfast`. Put throwaway builds outside `build/` (`-out:/tmp/...`), so the user's next launch doesn't pick them up.
- **Audio devices.** Bit-perfect mode changes the output device's sample rate and format and skips the volume. On Linux it forces PipeWire's graph rate while it plays. Test it only with the mock's -60 dBFS tracks, never with the fake tones. Afterwards, check that the default output device is back at its old nominal rate and physical format (`build/audio_top -once`, see `docs/playback.md`), and restore it if not.
- **Logs.** Never print tokens, Authorization headers, stream or CDN URLs, the pasted PKCE redirect or raw server text. Log error kinds, HTTP status and known codec names (`tidal.error_summary`).

## Conventions

- Commits: conventional, lowercase, a subject line only, no body, no Co-Authored-By.
- Code: plain handmade Odin, procedures and structs, comments only where they say something the code doesn't.
- First frames: a page's first frame must look like its second. While building, a box's `rect` and `view_bounds` are the last layout's, and zero on the frame the box first appears. Don't place or size anything from them. Give the build the sizes it needs in points (a scroll view's size, a text field's height) and let draw do the rest, as `draw_label` centres text in the final rect. Settle any state the frame depends on before the boxes that read it: send the search before choosing the view's top room, and pass `focus` to `text_field` instead of focusing it after. Reading `rect` is fine for input on a box already on screen, such as a click, a drag or a menu opened from a button. `tests/first_frame_test.odin` compares each page's first frame with the next, so add a new page to it.
- Docs and comments: plain direct English, sentence-case headings, no em dashes.
- `shell/platform.h` and `src/platform/platform.odin` are one ABI. Change both together and keep their size checks. `tests/abi_test.odin` compares every field's offset across the two; add a new shared struct to its list.
- Prove a bug fix with a test that fails on the commit before it.
