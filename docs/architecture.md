# TIDALfast architecture

A native TIDAL client for macOS and Linux. Odin for the app, a small shell for the parts of the OS that need it (Obj-C on macOS, C on Wayland), a handmade immediate-mode UI in the style of Ryan Fleury's box UI, and Metal or Vulkan for drawing.

## Layout

```
shell/            the shell: window, GPU layer, event queue, dylib loader, IME, media keys, secrets. shell.m on macOS, shell_wayland.c on Linux
src/platform/     types shared by the shell and Odin (events, the app API table, shell callbacks)
src/app/          the hot-reloaded app dylib: frame loop, views, app state
src/render/       instanced rect renderer, Metal on macOS and Vulkan on Linux
src/text/         font loading, shaping (kb_text_shape), rasterizing (CoreText, FreeType), glyph atlas
src/ui/           box tree, layout, interaction, animation
src/tidal/        the TIDAL API library (package `tidal`)
src/audio/        decoding, playback, CoreAudio device control
src/jobs/         bounded priority queues between the UI thread and the workers, plain data that survives a hot reload
src/cover/        cover art sizes, decoding on a worker, and the texture cache
src/os_services/  secret store (Keychain, libsecret), opening URLs, settings and cache paths
src/kbts/         kb_text_shape's C source and Odin bindings, which build.sh compiles into build/kbts
tests/            `odin test tests`
examples/cli/     CLI on top of src/tidal
tools/measure/    startup and memory measurement (docs/measuring.md)
tools/save_cost/  times what a list save and a queue save cost the UI thread
tools/icons.sh    cuts the Phosphor icon fonts down to the icons the app draws
build.sh          builds everything; `./build.sh app` rebuilds only the dylib for hot reload
```

The API library is one component. Only `src/app` knows about all the others.

## Reference code

Read-only checkouts in `~/.t3/scratch/2026-10-14-please-analyze-how-spotifast-is-056039c4/src/`. Read them for ideas; don't copy code wholesale.

- `raddebugger/src/render/` and `raddebugger/src/ui/`: `R_Rect2DInst` (in `render_core.mdesk`), the D3D11 rect shader, and Fleury's box UI and layout passes.
- `raddebugger/src/font_provider/`, `font_cache/`: glyph cache and atlas design.
- `spotifast/`: the Rust/egui Spotify client this app follows for layout (sidebar, 88 px player bar, track table columns at 560/760/920 px), `virtual_rows`, worker channels with `request_repaint`.
- `fastframe/`: spotifast's egui base.
- `tidalapi/` (Python), `tidal-sdk-web/`, `riptide/`, `lumitide/`, `mare-player/`, `high-tide/`: other TIDAL clients. Check them for login flows, playbackinfo, DASH and hi-res handling.

## Decisions

- **Platform shell.** The shell owns the window and the GPU layer. On macOS that's `NSApplication` and a `CAMetalLayer`, with IME (`NSTextInputClient`), media keys and Now Playing (`MPRemoteCommandCenter`, `MPNowPlayingInfoCenter`), Keychain, clipboard and drag and drop in `shell.m` too. `docs/linux.md` covers the Wayland shell.
- **Hot reload.** The app is a dylib that the shell reloads when it changes. State lives in memory the shell owns, so a reload keeps it.
- **Memory.** Arenas. A per-frame arena holds the box tree and temporary strings and resets every frame. Persistent arenas hold caches and app data.
- **Renderer.** One instanced pipeline. Each instance is a rect with corner radii, border width, edge softness (shadows), two colours for gradients, a clip rect, and a texture and UV rect. Glyphs, cover art, rounded boxes and shadows all go through it. Fleury's `R_Rect2DInst` in raddebugger's `src/render/` is the reference.
- **Threads.** The main thread runs UI and rendering. Workers handle network and image decoding; miniaudio runs its own audio thread. Workers send results over queues and wake the main thread with `CFRunLoopWakeUp` on macOS and an eventfd on Linux.
- **Redraw policy.** Redraw only on input, on worker results, or while an animation runs. Otherwise sleep.

## Not done yet

- Linux: bit-perfect output (ALSA `hw:` devices or PipeWire), MPRIS for media keys and Now Playing, AT-SPI for screen readers, and client-side decorations for compositors without xdg-decoration, such as GNOME.
- Windows: DirectWrite, D3D11 and WASAPI exclusive. Keep platform code behind shell procedures and the renderer interface so it can be added.

## Pitfalls

- Mismatched glyph IDs between kb_text_shape and the rasterizer if they load different font files.
- Retina blur: rasterize at physical pixel sizes and snap text to whole physical pixels.
- Thin text: `CGContextSetShouldSmoothFonts(false)` and blend coverage in linear space.
- One frame of input lag from last frame's rects. Rebuild right after input when it matters.
- Never wait on curl, disk or the audio device on the main thread.
- `src/ui` is a toolkit for this app only. Don't build widgets TIDALfast doesn't need yet.
