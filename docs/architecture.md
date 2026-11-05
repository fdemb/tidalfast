# TIDALfast architecture

A native TIDAL client for macOS, Linux and, in a first build, Windows. Odin for the app, a small shell for the parts of the OS that need it (Obj-C on macOS, C on Wayland and Win32), a handmade immediate-mode UI in the style of Ryan Fleury's box UI, and Metal or Vulkan for drawing.

## Layout

```
shell/            the shell: window, GPU layer, event queue, IME, media keys, secrets. shell.m on macOS, shell_wayland.c on Linux,
                  shell_win32.c on Windows, with common.c for what the last two share
src/platform/     types shared by the shell and Odin (events, frame input, shell callbacks)
src/app/          the app: main, frame loop, views, app state
src/render/       instanced rect renderer, Metal on macOS and Vulkan on Linux and Windows
src/text/         font loading, shaping (kb_text_shape), rasterizing (CoreText, FreeType), glyph atlas
src/ui/           box tree, layout, interaction, animation
src/tidal/        the TIDAL API library (package `tidal`)
src/audio/        decoding, playback, CoreAudio and PipeWire device control
src/jobs/         bounded priority queues between the UI thread and the workers, plain data
src/cover/        cover art sizes, decoding on a worker, and the texture cache
src/cacert/       where libcurl finds CA certificates on Linux when its built-in path is missing
src/os_services/  secret store (Keychain, libsecret, Credential Manager), opening URLs, settings and cache paths
src/sys/          threads, local time, page size and file mappings for shared code, per OS
third_party/      C libraries with their Odin bindings, which build.sh compiles into build/<name>: kbts (kb_text_shape), miniaudio and dr_flac.
                  The Windows build adds FreeType, from its release, and keeps its libraries in build/windows
tests/            `odin test tests`
examples/cli/     CLI on top of src/tidal
tools/measure/    startup and memory measurement (docs/measuring.md)
tools/save_cost/  times what a list save and a queue save cost the UI thread
tools/audio_top/  macOS's pw-top: each output device's rate and formats, and the processes playing to it
tools/icons.sh    cuts the Phosphor icon fonts down to the icons the app draws
tools/icon.sh     renders the app icon in packaging/ for macOS and Linux
tools/winsdk_case.sh  makes the Windows SDK from xwin usable on a case-sensitive file system
packaging/        Info.plist, the .desktop file and the app icon for `./build.sh dist`
build.sh          builds everything; `./build.sh dist` packages a release
.github/          the release workflow: a v* tag publishes the .dmg and the AppImage
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
- **One executable.** `build.sh` compiles the shell to an object and Odin links it into the app. The app's `main` calls `shell_main`, and the shell calls `app_init`, `app_frame` and `app_shutdown`, declared in `platform.h`. State lives in memory the shell maps, see [Memory](memory.md).
- **Memory.** Arenas. A per-frame arena holds the box tree and temporary strings and resets every frame. Persistent arenas hold caches and app data.
- **Renderer.** One instanced pipeline. Each instance is a rect with corner radii, border width, edge softness (shadows), two colours for gradients, a clip rect, and a texture and UV rect. Glyphs, cover art, rounded boxes and shadows all go through it. Fleury's `R_Rect2DInst` in raddebugger's `src/render/` is the reference.
- **Threads.** The main thread runs UI and rendering. Workers handle network and image decoding; miniaudio runs its own audio thread. Workers send results over queues and wake the main thread with `CFRunLoopWakeUp` on macOS, an eventfd on Linux and an event on Windows.
- **Redraw policy.** Redraw only on input, on worker results, or while an animation runs. Otherwise sleep.

## Not done yet

- Linux: MPRIS for media keys and Now Playing, AT-SPI for screen readers, and client-side decorations for compositors without xdg-decoration, such as GNOME.
- Windows: the System Media Transport Controls, UI Automation and packaging. [windows.md](windows.md) lists the rest.

## Pitfalls

- Mismatched glyph IDs between kb_text_shape and the rasterizer if they load different font files.
- Retina blur: rasterize at physical pixel sizes and snap text to whole physical pixels.
- Thin text: `CGContextSetShouldSmoothFonts(false)` and blend coverage in linear space.
- One frame of input lag from last frame's rects. Rebuild right after input when it matters.
- Never wait on curl, disk or the audio device on the main thread.
- `src/ui` is a toolkit for this app only. Don't build widgets TIDALfast doesn't need yet.
