# TIDALfast plan: Odin, handmade UI, macOS first

A native TIDAL client. Odin for the app, a small Obj-C shell for the parts of macOS that need it, a handmade immediate-mode UI in the style of Ryan Fleury's box UI, Metal for drawing.

## Layout

```
shell/          Obj-C: NSApplication, window, CAMetalLayer, event queue, dylib loader, IME, media keys, Keychain
src/platform/   types shared by the shell and Odin (events, the app API table, shell callbacks)
src/app/        the hot-reloaded app dylib: frame loop, views, app state
src/render/     instanced Metal rect renderer
src/text/       font loading, shaping (kb_text_shape), rasterizing (CoreText), glyph atlas
src/ui/         box tree, layout, interaction, animation
src/tidal/      the TIDAL API library (package `tidal`)
src/audio/      decoding, playback, CoreAudio device control
tests/          `odin test tests`
examples/cli/   CLI on top of src/tidal
build.sh        builds everything; `./build.sh app` rebuilds only the dylib for hot reload
```

The API library is one component. Only `src/app` knows about all the others.

## Reference code

Read-only checkouts in `~/.t3/scratch/2026-10-14-please-analyze-how-spotifast-is-056039c4/src/`. Read them for ideas; don't copy code wholesale.

- `raddebugger/src/render/` and `raddebugger/src/ui/`: `R_Rect2DInst` (in `render_core.mdesk`), the D3D11 rect shader, and Fleury's box UI and layout passes. There's no Metal backend, so port the D3D11 shader.
- `raddebugger/src/font_provider/`, `font_cache/`: glyph cache and atlas design.
- `spotifast/`: the Rust/egui Spotify client this app follows for layout (sidebar, 88 px player bar, track table columns at 560/760/920 px), `virtual_rows`, worker channels with `request_repaint`.
- `fastframe/`: spotifast's egui base.
- `tidalapi/` (Python), `tidal-sdk-web/`, `riptide/`, `lumitide/`, `mare-player/`, `high-tide/`: other TIDAL clients. Check them for login flows, playbackinfo, DASH and hi-res handling.

## Decisions

- **Platform shell.** An Obj-C `shell.m` owns `NSApplication`, the window and the `CAMetalLayer`. IME (`NSTextInputClient`), media keys and Now Playing (`MPRemoteCommandCenter`, `MPNowPlayingInfoCenter`), Keychain, clipboard and drag and drop live there too.
- **Hot reload.** The app is a dylib that the shell reloads when it changes. State lives in memory the shell owns, so a reload keeps it.
- **Memory.** Arenas. A per-frame arena holds the box tree and temporary strings and resets every frame. Persistent arenas hold caches and app data.
- **Renderer.** One instanced Metal pipeline. Each instance is a rect with corner radii, border width, edge softness (shadows), two colours for gradients, a clip rect, and a texture and UV rect. Glyphs, cover art, rounded boxes and shadows all go through it. Fleury's `R_Rect2DInst` in raddebugger's `src/render/` is the reference.
- **Threads.** The main thread runs UI and rendering. Workers handle network and image decoding; miniaudio runs its own audio thread. Workers send results over queues and wake the main thread with `CFRunLoopWakeUp`.
- **Redraw policy.** Redraw only on input, on worker results, or while an animation runs. Otherwise sleep.

## Phases

### 0. Shell and loop

Window, `CAMetalLayer` at Retina scale, an event queue from Obj-C into Odin (mouse, scroll with trackpad phases, keys, resize), redraw on demand, dylib hot reload, a frame-time overlay. `core:prof/spall` for profiling.
Done when: you can edit a colour in Odin, save, and see it change without restarting, and an idle window uses 0% CPU.

### 1. Renderer

The instanced rect pipeline with an SDF rounded-box shader, clip rects, textured quads, gradients and shadows. Triple-buffer the instance buffer.
Done when: a test screen with a few hundred rounded, shadowed, gradient rects renders in one draw call per texture.

### 2. Text

- Load Inter from memory into kb_text_shape, and into CoreText through `CTFontManagerCreateFontDescriptorFromData`. Shape and rasterize from the same font file, or glyph IDs won't match.
- Rasterize with `CTFontDrawGlyphs` into a `CGBitmapContext` at physical pixel size, grayscale, 4 subpixel x-offsets, packed with `stb/rect_pack` into an R8 atlas.
- Cache shaped runs by (string hash, font, size).
- Truncate with an ellipsis using the glyph advances.
- Fallback: `CTFontCreateForString` finds a font for missing characters. Get its file through `kCTFontURLAttribute` and load that into kb_text_shape too. Apple Color Emoji goes into a second BGRA atlas.

Done when: a 10,000-row list of mixed Latin, CJK, Arabic and emoji titles scrolls at the display's refresh rate with UI CPU time under 1 ms per frame. Check how kb_text_shape handles right-to-left runs.

### 3. UI core (Fleury boxes)

Boxes keyed by a hash of their ID with a hash table that keeps state across frames. Size kinds (pixels, text, parent percent, children sum) with strictness. The five layout passes per axis. Interaction tested against the previous frame's rects, with hot/active tracking. Animation by easing stored values toward targets. Scroll views with clipping. Virtualized rows. A floating layer for menus, tooltips and the drag ghost. Keyboard focus navigation.
Done when: a Spotify-style shell works (resizable sidebar, main view, 88 px player bar) with a track table that adds and drops columns at 560/760/920 px, plus a debug toggle that outlines every box.

### 4. TIDAL API and data

Device-code login first, Android-client PKCE later for hi-res. Tokens in the Keychain, keeping the rotated refresh token, refreshing one request at a time. v2 `openapi.tidal.com` for library, playlists and albums. HTTPS through `vendor:curl` on worker threads. A `Retry-After`/backoff gate. Cover art: fetch, decode with `stb/image` on a worker, upload with mipmaps, LRU texture cache.
Done when: you can log in, see your playlists, and open one with covers loading in without stutter.

### 5. Playback, lossless 16/44.1

`resolve_stream(track_id, quality)` over v1 `playbackinfopostpaywall`. The BTS manifest gives a FLAC URL; stream it through a ring buffer into miniaudio's decoder. Queue, seek, gapless preloading, ReplayGain, Now Playing and media keys through the shell.
Done when: a live album plays gaplessly, media keys work, and seeking is instant.

### 6. Hi-res and bit-perfect

DASH MPD parsing with `SegmentTimeline`, a small fMP4 parser (`moov` → `dfLa`, `moof`/`mdat`) feeding FLAC frames to the decoder. Per-track sample-rate switching through `kAudioDevicePropertyNominalSampleRate`, optional hog mode, and a bypass of volume and EQ when bit-perfect is on.
Done when: a 24/96 track reaches the DAC at 96 kHz unchanged, and a 44.1 → 96 change between tracks re-clocks with only a short gap.

### 7. Text input, search, polish

Single-line text field with cursor, selection, clipboard, undo and IME marked text. Search. Context menus. Basic accessibility through `NSAccessibility` or AccessKit's C API.
Done when: you can search in Japanese with the system IME, and VoiceOver reads the track list.

Windows comes later (DirectWrite, D3D11, WASAPI exclusive). Keep platform code behind shell procedures and the renderer interface.

## Pitfalls

- Mismatched glyph IDs between kb_text_shape and CoreText if they load different font files.
- Retina blur: rasterize at physical pixel sizes and snap text to whole physical pixels.
- Thin text: `CGContextSetShouldSmoothFonts(false)` and blend coverage in linear space.
- One frame of input lag from last frame's rects. Rebuild right after input when it matters.
- Never wait on curl, disk or the audio device on the main thread.
- Phases 0–3 are a UI toolkit. Don't build widgets TIDALfast doesn't need yet.
