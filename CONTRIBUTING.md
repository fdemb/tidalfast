# Contributing to TIDALfast

TIDALfast is written in Odin. A small shell owns the window and talks to the OS: Obj-C on macOS, C on Linux (Wayland). Everything else is Odin, linked with the shell into one executable. [docs/architecture.md](docs/architecture.md) has the layout and the main decisions, and the other files in `docs/` describe each part in detail. [AGENTS.md](AGENTS.md) lists the ways to check your work without looking at the window: frame captures, scripted input, fake data, a mock TIDAL server and audio captures.

## Building and running

```
./build.py              # debug: build/tidalfast
./build.py release      # optimized
./build.py dist         # TIDALfast.app and a .dmg on macOS, an AppImage on Linux
./build.py test         # what the tests link, then odin test tests
./build/tidalfast
```

It needs macOS 14 or later, Odin, Python 3 and the Xcode command line tools. Linux needs a few packages first; see [docs/linux.md](docs/linux.md). `TIDALFAST_FAKE=1` runs the app on fake data without an account. The environment variables, keys and the patches to kb_text_shape are in [docs/building.md](docs/building.md).

Keep `./build.py` clean with `-vet -strict-style`. Per-OS code lives in `_darwin.odin`, `_linux.odin` and `_windows.odin` files. CI builds and tests all three on every push and pull request, so a branch shows whether shared code still builds on the other systems.

## Layout

```
shell/          the platform side: window, event queue, input methods and clipboard. shell.m is
                the macOS one (CAMetalLayer, media keys, Now Playing, accessibility), shell_wayland.c the Linux one,
                shell_win32.c the Windows one, and common.c what those two share
src/platform/   the ABI between shell and app (shell/platform.h mirrors it)
src/app/        the app, with main
src/render/     renderer, with Metal (metal_darwin.odin) or Vulkan (vulkan.odin) as its backend
src/text/       fonts, shaping (kb_text_shape), rasterizing (CoreText or FreeType), glyph atlas
src/ui/         box tree, layout, input, animation, menus, tooltips and the text field
assets/fonts/   the Phosphor icon fonts (tools/icons.sh, MIT) and Noto Sans for Linux (tools/noto.sh, OFL)
src/tidal/      TIDAL API library, see src/tidal/README.md
src/audio/      FLAC and DASH streaming, fMP4, decoding, output through CoreAudio, PipeWire and WASAPI, the play queue's rules, ReplayGain
src/jobs/       a thread-safe priority queue for jobs and results
src/cover/      cover sizes, decoding and the texture cache
src/cacert/     the CA bundle for libcurl on Linux distributions it wasn't built for
src/os_services/  secret store (the Keychain), opening URLs, settings and cache folders, one file per OS
third_party/kbts/       kb_text_shape 2.21: C source and Odin bindings
third_party/dr_flac/    dr_flac 0.13.3: C source and Odin bindings
tests/          `odin test tests`
tests/mock_tidal/  a stand-in TIDAL server for running the app without an account
tests/audio_check/ compares a capture of the audio output with the source it came from
tests/bitperfect_check/ checks a bit-perfect capture against integer source WAVs, bit for bit
tests/dashgen/  cuts FLAC into TIDAL-style DASH (fMP4 segments and an MPD), for the mock and the tests
examples/cli/   CLI on top of src/tidal
packaging/      the icon, Info.plist and the Linux .desktop file for ./build.py dist
```

## Docs

- [Building and running](docs/building.md): build details, packaging and releases, the kb_text_shape patches, environment variables and debug keys
- [Linux](docs/linux.md): dependencies, the Wayland shell, Vulkan, fonts, what isn't done yet and checking it without a display
- [Renderer](docs/renderer.md): the instanced quad renderer, colour, textures and batching
- [Text](docs/text.md): fonts, shaping, fallback, right-to-left text and the glyph atlas
- [UI](docs/ui.md): the box tree, layout, input, scrolling, animation and the library screen
- [TIDAL data](docs/tidal-data.md): login, the Keychain, jobs and threads, memory, the list cache, covers and the mock server
- [Playback](docs/playback.md): streams, buffers, gapless, seeking, Now Playing, DASH, bit-perfect output and how to check it
- [Text input](docs/text-input.md): the text field, input methods and the platform ABI versions that came with them
- [Search](docs/search.md)
- [Accessibility](docs/accessibility.md)
- [Memory](docs/memory.md)
- [Redraw policy](docs/redraw.md)
- [Measuring RAM and startup](docs/measuring.md): the measure tool, what the app prints and where the memory went
- [Architecture](docs/architecture.md): the layout, the main decisions and what isn't done yet

## Pull requests

- Commits are conventional and lowercase, with a subject line only.
- Prove a bug fix with a test that fails on the commit before it.
- For a change that could move memory or startup, measure it against the code before it with `./build/measure/measure ab` and put the result in the pull request (see [Measuring RAM and startup](docs/measuring.md)).
- An idle window should use no CPU. Anything that animates must stop asking for frames once it settles.
- Code is plain Odin, procedures and structs, with comments only where they say something the code doesn't. Docs and comments are plain direct English with sentence-case headings.
