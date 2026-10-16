# TIDALfast

A native macOS TIDAL client in Odin. A small Obj-C shell owns the window and talks to macOS. Everything else is an Odin dylib that the shell reloads while it runs. `docs/plan.md` has the plan and the phases, and the other files in `docs/` describe each part in detail.

```
shell/          Obj-C executable: window, CAMetalLayer, event queue, dylib loader, media keys and Now Playing,
                input methods, clipboard and accessibility
src/platform/   the ABI between shell and app (shell/platform.h mirrors it)
src/app/        the hot-reloaded app dylib
src/render/     renderer, with Metal as its backend (metal_darwin.odin)
src/text/       fonts, shaping (kb_text_shape), rasterizing (CoreText), glyph atlas
src/ui/         box tree, layout, input, animation, menus, tooltips and the text field
src/kbts/       kb_text_shape 2.21: C source and Odin bindings
assets/fonts/   Inter 4.1, static Regular/Medium/SemiBold/Bold, with its OFL licence
src/tidal/      TIDAL API library, see src/tidal/README.md
src/audio/      FLAC and DASH streaming, fMP4, decoding, miniaudio and CoreAudio HAL output, the play queue's rules, ReplayGain
src/jobs/       a thread-safe priority queue for jobs and results
src/cover/      cover sizes, decoding and the texture cache
src/os_services/  secret store (the Keychain), opening URLs, settings and cache folders, one file per OS
tests/          `odin test tests`
tests/mock_tidal/  a stand-in TIDAL server for running the app without an account
tests/audio_check/ compares a capture of the audio output with the source it came from
tests/bitperfect_check/ checks a bit-perfect capture against integer source WAVs, bit for bit
tests/dashgen/  cuts FLAC into TIDAL-style DASH (fMP4 segments and an MPD), for the mock and the tests
examples/cli/   CLI on top of src/tidal
```

## Building and running

```
./build.sh              # debug: build/tidalfast and build/app.dylib
./build.sh app          # rebuild only the dylib
./build.sh release      # optimized, hot reload off
./build/tidalfast
```

It needs macOS 14 or later, Odin and the Xcode command line tools. Run `./build.sh` once before `odin test tests`. `TIDALFAST_FAKE=1` runs the app on fake data without an account. The environment variables, keys and the patches to kb_text_shape are in [docs/building.md](docs/building.md).

## Docs

- [Building and running](docs/building.md): build details, the kb_text_shape patches, environment variables and debug keys
- [Renderer](docs/renderer.md): the instanced quad renderer, colour, textures and batching
- [Text](docs/text.md): fonts, shaping, fallback, right-to-left text and the glyph atlas
- [UI](docs/ui.md): the box tree, layout, input, scrolling, animation and the library screen
- [TIDAL data](docs/tidal-data.md): login, the Keychain, jobs and threads, memory, the list cache, covers and the mock server
- [Playback](docs/playback.md): streams, buffers, gapless, seeking, Now Playing, DASH, bit-perfect output and how to check it
- [Text input](docs/text-input.md): the text field, input methods and the platform ABI versions that came with them
- [Search](docs/search.md)
- [Accessibility](docs/accessibility.md)
- [Hot reload](docs/hot-reload.md)
- [Redraw policy](docs/redraw.md)
- [Measuring RAM and startup](docs/measuring.md): the measure tool, what the app prints and the baseline numbers
- [Plan](docs/plan.md): the plan and the phases
