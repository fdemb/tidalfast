# Building and running

```
./build.sh              # debug: build/tidalfast and build/app.dylib
./build.sh app          # rebuild only the dylib
./build.sh release      # optimized, hot reload off
./build/tidalfast
```

On macOS it needs macOS 14 or later, Odin and the Xcode command line tools; [linux.md](linux.md) has what Linux needs. `build.sh` relinks the shell only when `shell/` changes or you switch between debug and release, for the Keychain's sake (see [Keychain](tidal-data.md#keychain)). Shaders are compiled at runtime from source in `src/render`, so the Metal toolchain isn't needed.

`src/kbts` holds kb_text_shape's C source and a copy of Odin's `vendor:kb_text_shape` bindings that link `build/kbts/kb_text_shape.a`. `build.sh` compiles that archive when it's missing or older than the source, so nothing is written to the Odin install. Run `./build.sh` once before `odin test tests`. The project adds one function to `kb_text_shape.c`, `tidalfast_bidi_class`, which exports the library's Unicode bidi class table.

`kb_text_shape.h` is patched in three places:

- Hangul. `kbts__HangulSyllableInfo` tested `Codepoint == 0xAC00` where it meant `>=`, so U+AC00 (가) was the only precomposed syllable it recognized. That one was split into jamo and never put back together: the syllable's jamo were treated as not composable, so 가 came out as two jamo glyphs twice as wide. Every other syllable was passed through untouched. On top of that, every glyph the Hangul pass made had codepoint index 0. Now all of U+AC00 to U+D7A3 is recognized, a syllable's own jamo always recompose, and the new glyphs keep the syllable's index and config. Apple SD Gothic Neo's Hangul now matches CoreText's glyph for glyph.
- Inserted glyphs. The dotted circle added before a stray mark and the nikhahit split off Thai and Lao sara am got index 0. They now take the index of the character they're inserted for.
- Font coverage. `kbts_FontCoverageTestCodepoint` asked the font for a glyph for every codepoint of a cluster, default ignorables included, so a font that doesn't map U+FE0F didn't cover 🏳️‍🌈 or 1️⃣ and the cluster went to Inter as missing glyphs. Noto Color Emoji is such a font. The shaper hides default ignorables anyway, so the test now skips them.

The app logs through `core:log` to stderr, at info level and up, with the level, time and source line. Errors say what failed and its HTTP status or OS code, never tokens, URLs with their query or what the server sent.

Environment variables:

- `TIDALFAST_FAKE=1` shows the fake library from phases 2 and 3 instead of logging in to TIDAL, for working on the UI without an account. Its rows play sine tones. `TIDALFAST_BENCH=1` and `=text` imply it.
- `TIDALFAST_API=url` sends every request, the login and cover downloads to `url` instead of TIDAL, for running against `tests/mock_tidal`. The login then goes in the Keychain under `tidalfast-mock`, so it never replaces a real one. Only debug builds and the `./build.sh measure` build read it, and only for `http` or `https` on `127.0.0.1`, `[::1]` or `localhost`. Anything else is ignored with a line on stderr. Whoever runs the server at `url` gets the tokens of the account that logs in, so a release build never sends them anywhere but TIDAL.
- `TIDALFAST_KEYCHAIN=name` keeps the mock login under `name` instead of `tidalfast-mock`. It only works together with `TIDALFAST_API`, and never with `tidalfast`. A build that reads an item another build wrote makes the Keychain ask for access, so test runs can give a build its own item.
- `TIDALFAST_OVERLAY=1` shows the frame-time overlay from the start.
- `TIDALFAST_VOLUME=0.2` sets the volume slider at start.
- `TIDALFAST_AUDIO_NULL=1` plays to miniaudio's null device: the audio callback runs in real time, but nothing reaches the speakers.
- `TIDALFAST_AUDIO_CAPTURE=path` writes every sample the audio callback hands the device, after ReplayGain and volume, to `path` as a 32-bit float WAV. In bit-perfect mode it's what the HAL IOProc hands CoreAudio. Only the first player after start captures, not the ones a hot reload makes. The header's sizes are filled in when the app quits; `tests/audio_check` and `tests/bitperfect_check` also read a file whose header still says 0. The header has the rate of the first device open; after a rate change the frames carry on at the new rate in the same file.
- `TIDALFAST_SETTINGS=path` keeps the settings (bit-perfect, hog mode, scrollbars) in `path` instead of `~/Library/Application Support/tidalfast/settings.json`.
- `TIDALFAST_CACHE=dir` keeps the list cache's files in `dir/<user id>` instead of `~/Library/Caches/tidalfast/<user id>` (see [The list cache](tidal-data.md#the-list-cache)). Against `TIDALFAST_API` the default is `~/Library/Caches/tidalfast-mock`, so a mock never writes into a real account's cache.
- `TIDALFAST_PKCE_REDIRECT=url`: with no saved login the app finishes the PKCE login (see [Login](tidal-data.md#login)) with this address at start, so a script can log in to `tests/mock_tidal` without a browser. Debug and `./build.sh measure` builds only.
- `TIDALFAST_AUDIO_WINDOW_KB=n` sets how much of each track is kept downloaded (8 MB by default). A small window sends seeks back to the network, for measuring them.
- `TIDALFAST_NOW_PLAYING_LOG=1` makes the shell print Now Playing as macOS holds it, read back from `MPNowPlayingInfoCenter`, after every update, and every remote command it gets.
- `TIDALFAST_REMOTE_TEST="8:play,12:seek=10,20:pause,24:next"` makes the shell send those remote commands that many seconds after launch, through the same path as the media keys. The commands are `play`, `pause`, `toggle`, `next`, `previous` and `seek=seconds`.
- `TIDALFAST_SPALL=path` writes a [spall](https://gravitymoth.com/spall/) trace of every frame to `path`.
- `TIDALFAST_LOG_EVENTS=1` prints every input event.
- `TIDALFAST_LOG_HTTP=1` logs at debug level: a line per TIDAL request with its method, URL without the query, status, size and time, plus the TIDAL library's other debug lines, such as token refreshes. For each stream it also logs the playback info's quality and format and an outline of the DASH manifest: element and attribute names, value shapes with digits as 9, and only the length of URLs and long values.
- `TIDALFAST_LOG_RENDER=1` prints the draw calls and instances whenever they change, which while scrolling is about every frame.
- `TIDALFAST_SHELL_TEST="2:key=cmd+f;3:mark=にほんご;4:commit=日本語;6:ax-dump"` runs steps against the shell's own entry points that many seconds after launch, for checking text input and accessibility without a person at the keyboard. Steps are separated by semicolons. `key=cmd+shift+z` sends a key down and up. `mark=text`, `commit=text` and `unmark` call the view's `setMarkedText`, `insertText` and `unmarkText` the way an input method does, and `ime` prints what the view answers to NSTextInputClient's questions. `ax-dump` prints the window's accessibility tree as AppKit hands it to an assistive app, and `ax-press=label` sends AXPress to the first element whose label or value starts with `label`. `mark-range=l,n,text` and `commit-range=l,n,text` give a replacement range in UTF-16 units, and `commit-marked=text` replaces whatever `markedRange` answers. `clean=hex` prints what the shell's `field_sanitize` makes of the bytes, in hex. Commands joined with `|` run together with no frame between them. `capture=path` copies the last `TIDALFAST_CAPTURE` frame to `path`, and `quit` quits. On Linux, `size=w,h` makes the window w by h points, since a compositor with no person at it never resizes one. The comment above `setup_shell_test` in `shell.m` (and in `shell_wayland.c`) lists them.
- `TIDALFAST_CAPTURE=path` writes each presented frame to `path` as a TGA. It's for checking output when you can't take screenshots. Each frame goes to a temp file that's renamed over `path`, so copying `path` while the app runs gives a whole frame.
- `TIDALFAST_BENCH=1` scrolls the library's track table by itself and logs the CPU time per frame in three phases (see [UI](ui.md#performance)). `TIDALFAST_BENCH=text` does the same for the text test list (see [Text](text.md#performance)). `TIDALFAST_BENCH=covers` does it on live data while covers stream in (see [TIDAL data](tidal-data.md#performance)). All of them keep asking for frames even when the window is covered.
- `TIDALFAST_MEASURE=1` prints startup marks and memory samples to stderr as `measure: {...}` lines. `=startup` also quits once the first track rows and their covers are drawn, and `=memory` runs the memory scenario and quits. `tools/measure` sets it; see [Measuring RAM and startup](measuring.md).

The backtick key toggles the frame-time overlay. It's off unless `TIDALFAST_OVERLAY` or `TIDALFAST_BENCH` is set; the benches draw it so their numbers include it. It plots the CPU time of the last 120 frames against 120 Hz and 60 Hz lines. Under the plot are the last frame's total CPU time and the time spent building it (ui: everything before `end_frame`), its draw calls (blue dot) and instances (green dot), the text cache's run count and atlas pages, the keyed boxes in use, and the process's memory footprint (ram) and Metal's allocations (gpu), see [Measuring RAM and startup](measuring.md). `TIDALFAST_LOG_RENDER=1` also logs draw calls and instances to stderr whenever they change.

The app opens on the library screen, or the login screen when there's no saved login. Cmd-F or Cmd-L focuses the search field (see [Search](search.md)). Cmd-1 goes back to the library, Cmd-2 shows the text test screen (specimen lines and a 10,000-row list) and Cmd-3 the phase 1 renderer test screen. F1 or Cmd-Shift-D outlines every UI box and shows the key, ID and size of the box under the mouse.

To run with Metal's validation layer, set `MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1`.
