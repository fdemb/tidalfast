# TIDALfast

A native macOS TIDAL client in Odin. A small Obj-C shell owns the window and talks to macOS. Everything else is an Odin dylib that the shell reloads while it runs. `docs/plan.md` has the plan and the phases.

```
shell/          Obj-C executable: window, CAMetalLayer, event queue, dylib loader, media keys and Now Playing,
                input methods, clipboard and accessibility
src/platform/   the ABI between shell and app (shell/platform.h mirrors it)
src/app/        the hot-reloaded app dylib
src/render/     Metal renderer
src/text/       fonts, shaping (kb_text_shape), rasterizing (CoreText), glyph atlas
src/ui/         box tree, layout, input, animation, menus, tooltips and the text field
src/kbts/       kb_text_shape 2.21: C source and Odin bindings
assets/fonts/   Inter 4.1, static Regular/Medium/SemiBold/Bold, with its OFL licence
src/tidal/      TIDAL API library, see src/tidal/README.md
src/audio/      FLAC and DASH streaming, fMP4, decoding, miniaudio and CoreAudio HAL output, the play queue's rules, ReplayGain
src/jobs/       a thread-safe priority queue for jobs and results
src/cover/      cover sizes, decoding and the texture cache
src/mac/        Keychain and opening URLs, called straight from Odin
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

It needs macOS 14 or later, Odin and the Xcode command line tools. `build.sh` relinks the shell only when `shell/` changes or you switch between debug and release, for the Keychain's sake (see TIDAL data below). Shaders are compiled at runtime from source in `src/render`, so the Metal toolchain isn't needed.

`src/kbts` holds kb_text_shape's C source and a copy of Odin's `vendor:kb_text_shape` bindings that link `build/kbts/kb_text_shape.a`. `build.sh` compiles that archive when it's missing or older than the source, so nothing is written to the Odin install. Run `./build.sh` once before `odin test tests`. The project adds one function to `kb_text_shape.c`, `tidalfast_bidi_class`, which exports the library's Unicode bidi class table.

`kb_text_shape.h` is patched in two places:

- Hangul. `kbts__HangulSyllableInfo` tested `Codepoint == 0xAC00` where it meant `>=`, so U+AC00 (가) was the only precomposed syllable it recognized. That one was split into jamo and never put back together: the syllable's jamo were treated as not composable, so 가 came out as two jamo glyphs twice as wide. Every other syllable was passed through untouched. On top of that, every glyph the Hangul pass made had codepoint index 0. Now all of U+AC00 to U+D7A3 is recognized, a syllable's own jamo always recompose, and the new glyphs keep the syllable's index and config. Apple SD Gothic Neo's Hangul now matches CoreText's glyph for glyph.
- Inserted glyphs. The dotted circle added before a stray mark and the nikhahit split off Thai and Lao sara am got index 0. They now take the index of the character they're inserted for.

Environment variables:

- `TIDALFAST_FAKE=1` shows the fake library from phases 2 and 3 instead of logging in to TIDAL, for working on the UI without an account. Its rows play sine tones. `TIDALFAST_BENCH=1` and `=text` imply it.
- `TIDALFAST_API=url` sends every request, the login and cover downloads to `url` instead of TIDAL, for running against `tests/mock_tidal`. The login then goes in the Keychain under `tidalfast-mock`, so it never replaces a real one. Only debug builds and the `./build.sh measure` build read it, and only for `http` or `https` on `127.0.0.1`, `[::1]` or `localhost`. Anything else is ignored with a line on stderr. Whoever runs the server at `url` gets the tokens of the account that logs in, so a release build never sends them anywhere but TIDAL.
- `TIDALFAST_KEYCHAIN=name` keeps the mock login under `name` instead of `tidalfast-mock`. It only works together with `TIDALFAST_API`, and never with `tidalfast`. A build that reads an item another build wrote makes the Keychain ask for access, so test runs can give a build its own item.
- `TIDALFAST_OVERLAY=1` shows the frame-time overlay from the start.
- `TIDALFAST_VOLUME=0.2` sets the volume slider at start.
- `TIDALFAST_AUDIO_NULL=1` plays to miniaudio's null device: the audio callback runs in real time, but nothing reaches the speakers.
- `TIDALFAST_AUDIO_CAPTURE=path` writes every sample the audio callback hands the device, after ReplayGain and volume, to `path` as a 32-bit float WAV. In bit-perfect mode it's what the HAL IOProc hands CoreAudio. Only the first player after start captures, not the ones a hot reload makes. The header's sizes are filled in when the app quits; `tests/audio_check` and `tests/bitperfect_check` also read a file whose header still says 0. The header has the rate of the first device open; after a rate change the frames carry on at the new rate in the same file.
- `TIDALFAST_SETTINGS=path` keeps the output settings (bit-perfect, hog mode) in `path` instead of `~/Library/Application Support/tidalfast/settings.json`.
- `TIDALFAST_PKCE_REDIRECT=url`: with no saved login the app finishes the PKCE login (see Login) with this address at start, so a script can log in to `tests/mock_tidal` without a browser. Debug and `./build.sh measure` builds only.
- `TIDALFAST_AUDIO_WINDOW_KB=n` sets how much of each track is kept downloaded (8 MB by default). A small window sends seeks back to the network, for measuring them.
- `TIDALFAST_NOW_PLAYING_LOG=1` makes the shell print Now Playing as macOS holds it, read back from `MPNowPlayingInfoCenter`, after every update, and every remote command it gets.
- `TIDALFAST_REMOTE_TEST="8:play,12:seek=10,20:pause,24:next"` makes the shell send those remote commands that many seconds after launch, through the same path as the media keys. The commands are `play`, `pause`, `toggle`, `next`, `previous` and `seek=seconds`.
- `TIDALFAST_SPALL=path` writes a [spall](https://gravitymoth.com/spall/) trace of every frame to `path`.
- `TIDALFAST_LOG_EVENTS=1` prints every input event.
- `TIDALFAST_SHELL_TEST="2:key=cmd+f;3:mark=にほんご;4:commit=日本語;6:ax-dump"` runs steps against the shell's own entry points that many seconds after launch, for checking text input and accessibility without a person at the keyboard. Steps are separated by semicolons. `key=cmd+shift+z` sends a key down and up. `mark=text`, `commit=text` and `unmark` call the view's `setMarkedText`, `insertText` and `unmarkText` the way an input method does, and `ime` prints what the view answers to NSTextInputClient's questions. `ax-dump` prints the window's accessibility tree as AppKit hands it to an assistive app, and `ax-press=label` sends AXPress to the first element whose label or value starts with `label`. `mark-range=l,n,text` and `commit-range=l,n,text` give a replacement range in UTF-16 units, and `commit-marked=text` replaces whatever `markedRange` answers. `clean=hex` prints what the shell's `field_sanitize` makes of the bytes, in hex. Commands joined with `|` run together with no frame between them. `capture=path` copies the last `TIDALFAST_CAPTURE` frame to `path`, and `quit` quits. The comment above `setup_shell_test` in `shell.m` lists them.
- `TIDALFAST_CAPTURE=path` writes each presented frame to `path` as a TGA. It's for checking output when you can't take screenshots. Each frame goes to a temp file that's renamed over `path`, so copying `path` while the app runs gives a whole frame.
- `TIDALFAST_BENCH=1` scrolls the library's track table by itself and logs the CPU time per frame in three phases (see UI below). `TIDALFAST_BENCH=text` does the same for the text test list (see Text). `TIDALFAST_BENCH=covers` does it on live data while covers stream in (see TIDAL data). All of them keep asking for frames even when the window is covered.
- `TIDALFAST_MEASURE=1` prints startup marks and memory samples to stderr as `measure: {...}` lines. `=startup` also quits once the first track rows and their covers are drawn, and `=memory` runs the memory scenario and quits. `tools/measure` sets it; see Measuring RAM and startup.

The backtick key toggles the frame-time overlay. It's off unless `TIDALFAST_OVERLAY` or `TIDALFAST_BENCH` is set; the benches draw it so their numbers include it. It plots the CPU time of the last 120 frames against 120 Hz and 60 Hz lines. Under the plot are the last frame's total CPU time and the time spent building it (ui: everything before `end_frame`), its draw calls (blue dot) and instances (green dot), the text cache's run count and atlas pages, the keyed boxes in use, and the process's memory footprint (ram) and Metal's allocations (gpu), see Measuring RAM and startup. The app also logs draw calls and instances to stderr whenever they change.

The app opens on the library screen, or the login screen when there's no saved login. Cmd-F or Cmd-L focuses the search field (see Search). Cmd-1 goes back to the library, Cmd-2 shows the text test screen (specimen lines and a 10,000-row list) and Cmd-3 the phase 1 renderer test screen. F1 or Cmd-Shift-D outlines every UI box and shows the key, ID and size of the box under the mouse.

To run with Metal's validation layer, set `MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1`.

## Renderer

`src/render` draws everything as instances of one quad. Each instance is a rounded box drawn with a signed distance function in the fragment shader. It has four corner colours, four corner radii, a border width, an edge softness, a clip rect, and an optional texture with a source rect. A shadow is a soft-edged box drawn under the real one (`push_shadow`).

The API takes points. The renderer multiplies by the backing scale and rounds rect edges, clip rects and borders to whole pixels, so a 1 pt border is exactly 2 pixels at 2x.

Colours are sRGB with straight alpha, as a design tool shows them. The drawable is `BGRA8Unorm_sRGB`, so the GPU blends in linear space. The shader interpolates gradient colours in premultiplied sRGB, which matches CSS gradients, then converts to linear before blending. Glyph coverage blends in linear space the same way.

Textures come from `texture_create`, `texture_update` and `texture_destroy`. A `Texture` handle carries a generation, so a stale handle draws solid colour. The zero handle is a 1x1 white texture and means "no texture". Formats:

- `R8` is linear coverage for the glyph atlas. The texture swizzle makes it sample as premultiplied white.
- `RGBA8` and `BGRA8` take sRGB colour with alpha premultiplied in sRGB space. That's what a premultiplied `CGBitmapContext` produces, so CoreGraphics output (emoji, decoded images) goes in as is. Pass `mipmapped = true` for a texture drawn smaller than it is. Every update then regenerates the mips.

Colour textures are stored as `_sRGB` formats, and the GPU decodes sRGB before it filters. Uploading premultiplied sRGB bytes directly would decode `alpha * c` instead of giving `alpha * decode(c)`, which makes every translucent texel too dark: 50% white over black came out as 128 instead of 188. So each translucent texel is rewritten as the sRGB encoding of its premultiplied linear colour, `encode(decode(c / a) * a)`. The sample is then premultiplied linear, the same thing the shader makes from a solid colour, and filtering and mipmapping average the right values. Opaque and fully transparent texels don't change, so opaque cover art costs only a scan. The test screen has a black strip with 50% white three ways (an `RGBA8` texel, an `R8` texel and a solid rect), and all three read 188 in a capture.

The rewrite is `convert_premultiplied`, which works in place and touches no renderer state, so a decode worker can run it and pass `converted = true` to `texture_update`. Otherwise `texture_update` runs it on a copy when some texel is translucent. It reads a 256×256 table indexed by alpha and channel byte, built when the dylib loads; a test checks all 65,536 entries against the formula. A 2048×2048 texture with every texel translucent now takes 7 ms to convert and upload with mips, down from 216 ms, in an optimized build (179 ms, from 893 ms, in debug).

`texture_update` writes on the CPU straight away. A mipmapped texture remembers the command buffer of its last mip generation, which reads the whole base level, and the next write waits for it. The glyph atlas has no mips, so its writes never wait.

Batching: a draw call binds two textures, one colour (`RGBA8` or `BGRA8`) and one coverage (`R8`), and an instance flag says which one it samples. Solid instances don't sample, so they join whatever batch is open. A new draw call starts only when a textured instance needs a texture of its kind other than the one the batch already binds. So a list of covers from one page with their labels in the glyph atlas is one draw call. The mock's library took 37 draw calls a frame when each cover and the label next to it broke the batch, and takes 3 now. Clipping is per instance: the vertex shader cuts the quad down to the clip rect, so changing the clip never breaks a batch.

The instance buffer is triple buffered. Each frame writes into one of three shared `MTLBuffer`s and keeps its command buffer. When the slot comes round again, `begin_frame` waits for that command buffer, which has almost always finished already. If a frame pushes more instances than its buffer holds, that slot's buffer doubles, the frame's instances so far are copied over, and the frame keeps going. Each slot keeps its own size, so a slot that grew stays big and the others grow only when they need to.

## Text

`src/text` takes a string, a font (`.Regular`, `.Medium`, `.Semibold`, `.Bold`) and a size in points:

```odin
text.begin_frame(&s.text, r)                                  // once per frame
m := text.draw(&s.text, r, .Medium, 13, {x, y}, color, title, max_width = 280)
w := text.measure(&s.text, .Regular, 13, duration).width
run := text.shape(&s.text, .Regular, 13, label)               // keep and draw with draw_run
```

`pos` is the top left of the line box. `draw` returns the width actually drawn, the line height and ascent, and whether it truncated. `line_height` gives the box height without shaping anything.

The pipeline:

1. **Load.** The four Inter files are embedded with `#load`. Release builds use those bytes in place, handing CoreText a `CFData` that doesn't copy them: the shell never closes a dylib, and nothing reloads it. Debug builds, which hot reload replaces, copy them into the persistent arena first and give CoreText its own copy, as before. Each is parsed into kb_text_shape (`LoadFont` and `PlaceBlob` into our own memory, so the font holds no allocator) and handed to CoreText through `CTFontManagerCreateFontDescriptorFromData`. Both read the same bytes, so glyph IDs match.
2. **Shape.** `shape` hashes (string, font, size) and looks the run up in an open-addressing table. On a miss it decodes the string, finds fallback fonts for anything Inter lacks, picks the paragraph direction, shapes with the kb_text_shape context, fixes up bidi (below), and stores the glyphs in a pool: pen position, advance, offset, glyph ID, face and grapheme cluster, in visual order, in points. A run shaped while one of its fonts was still loading is marked pending, and `shape` shapes it again once fonts have arrived.
3. **Cache.** Runs remember the frame they were last used. Every 256 frames, runs not drawn for 600 frames go; if the table is three quarters full or the pool is, everything not drawn last frame goes. A sweep compacts the glyph pool. A `^Run` from `shape` is valid until the next `begin_frame`. If the cache is full mid-frame, the run lives in the frame arena for that frame and the next frame sweeps.
4. **Rasterize.** On first use at a pixel size and subpixel offset, a glyph is drawn with `CTFontDrawGlyphs` into a CGBitmapContext at physical pixel size: alpha-only (grayscale coverage) for normal glyphs, premultiplied BGRA for colour fonts. Antialiasing is on, font smoothing is off, subpixel positioning is on and CoreGraphics' own quantization is off, because we pick the offset. Rasterizing stops for the frame after 2 ms; the remaining glyphs show up over the next frames, and the app asks for another frame through `request_redraw`.
5. **Atlas.** `stb_rect_pack` packs bitmaps, with a one texel gap, into R8 pages (coverage) of up to 2048×2048 and BGRA pages (emoji) of up to 1024×1024. A page starts at a quarter of that side, 512×512 or 256×256, and doubles when a glyph doesn't fit: the GPU copies the old texture into the top left of the new one ahead of the next frame, and the packer starts over with that corner taken, so every glyph keeps its place. The old texture goes at the next `begin_frame`, since instances drawn earlier in the frame still sample it. The library's text at start fits in a 512×512 page, 256 KB instead of 4 MB. Scrolling the mock's 3,000-track list grows it to 1024×1024, and scrolling the fake data, with its scripts and emoji, ends with about 1.2 MB of glyph pages where it had two 4 MB pages. A full-size page that fills gets a new sibling, up to 8 pages. If they're all full, or the glyph table is three quarters full, the atlas starts over at the next `begin_frame`: old pages are destroyed rather than overwritten, since a frame in flight may still sample them.
6. **Draw.** The baseline is rounded to a whole pixel. Each glyph's pen x in pixels is split into a whole pixel and one of four quarter-pixel offsets (rounding to the nearest), and the bitmap for that offset is drawn one texel to one pixel, as a textured instance of the rect renderer. R8 coverage samples as premultiplied white, so it's tinted by the text colour and blended in linear light. Emoji are drawn untinted except for alpha.

Truncation uses the shaped advances and keeps or drops whole grapheme clusters, so a combining mark never stays without its base. A left-to-right paragraph keeps the clusters that fit before an ellipsis on the right. A right-to-left one keeps them from the right and puts the ellipsis on the left, which is its logical end. Spaces next to the ellipsis go.

Each glyph's cluster is the index of the first codepoint of its grapheme cluster, from kb_text_shape's grapheme segmentation (skipped for text below U+0300). Glyphs get their codepoint from kb_text_shape's index, or from CoreText's string indices on the `CTLine` path. Both are the true source index, so repeated characters get a cluster each.

All of it is plain data in `State`, the persistent arena and malloc'd font tables, plus CF objects, so it survives a hot reload. The kb_text_shape context stores a pointer to the library's internal allocator function, which lives in the dylib, so `reload` places the context afresh in the same memory. The font loader thread runs dylib code, so `unload` stops and joins it and `reload` starts it again; queued requests and finished results wait in `State` meanwhile. On an incompatible reload, `app_shutdown` calls `text.destroy`, which stops the loader, releases the CTFonts and bitmap contexts, unmaps fallback font files and destroys the atlas pages.

### Fallback fonts and emoji

For each codepoint Inter lacks (Inter's coverage is cached per BMP codepoint, since kb_text_shape's cmap lookup costs about half a microsecond), `CTFontCreateForString` names a font. Its file comes from `kCTFontURLAttribute` and is mapped with `mmap`, which matters for the 180 MB Apple Color Emoji. In a `.ttc` the right face is the one whose `name` table is byte for byte what CoreText returns for the font; kb_text_shape can't read the PostScript names in PingFang, so names don't work. The result is cached per (font, codepoint), and the face joins that font's fallback list. The cache never drops an entry, so a character no font has is asked for once per session; it starts at 4,096 slots and doubles when three quarters full. It used to drop new entries at that point instead, and then an unavailable character's answer had nowhere to go: it was asked for again on every reshape, and every answer woke the UI to reshape. Only the fallbacks a string needs go on kb_text_shape's font stack, under Inter.

All of that happens on a loader thread (`loader.odin`), because it took 4 to 22 ms on the UI thread the first time a script appeared (21 ms for Hebrew, which needs the font search below). The UI thread puts a request in a mutex-guarded queue and shapes without the font: those characters get Inter's missing glyph, which `draw_run` leaves blank, and the run is marked pending. The loader maps and parses the font into malloc'd memory, adds the face to a result list and calls the shell's `request_redraw`. The next `begin_frame` adds the face, and pending runs are shaped again when next asked for. The loader also handles fonts CoreText switches to inside a `CTLine` run. At start it loads the fallbacks for CJK, kana, Hangul, Arabic, Hebrew and emoji for each Inter weight.

Two things get in the way:

- kb_text_shape doesn't always read the same cmap as CoreText. In Lucida Grande, CoreText's pick for Hebrew, kb_text_shape finds no Hebrew. When CoreText's pick doesn't have the character as kb_text_shape sees it, `search_fallback` goes through every installed font that has it, upright first, then matching boldness, then `/System/Library/Fonts` before `Supplemental`, and takes the first that works. Hebrew ends up in Arial Hebrew.
- Some of macOS's own fonts have only Apple's `morx` tables and no OpenType `GSUB`: Geeza Pro (CoreText's Arabic font), Lucida Grande and Apple Color Emoji. kb_text_shape can't shape them, so Arabic wouldn't join and emoji sequences (ZWJ families, flags, keycaps, the rainbow flag) wouldn't combine. Runs that kb_text_shape puts in such a font are reshaped by CoreText (`CTLine` over the run's codepoints in the same `CTFont`), and the glyphs it returns are rasterized from the same file. Arabic in Geeza Pro joins and reads right to left, and emoji sequences come out as one glyph.

Apple Color Emoji has colour bitmaps (`kCTFontColorGlyphsTrait`), so its glyphs go into the BGRA pages as premultiplied sRGB, the format `texture_update` expects, and draw at the nearest whole pixel.

### Right-to-left text

What kb_text_shape (2.21, the copy in Odin dev-2026-10) does:

- Splits text into runs by direction, script and font.
- Shapes Arabic with joining (init, medi, fina forms) and mark positioning when the font has GSUB/GPOS. Hebrew works.
- Returns runs in logical order, with each right-to-left run's glyphs already reversed into visual order. Mirrors brackets inside right-to-left runs.

What it doesn't do:

- Its bidi class table leaves out the ranges UnicodeData.txt lists as First/Last pairs (Han, Hangul syllables, Tangut) and calls them neutral. So it got the paragraph direction wrong whenever such a character came first: "晴天 عيونك 🔥" and "밤편지 عيونك end" came out right to left. CJK runs next to Arabic could also come back right to left.
- No embedding levels and no reordering of runs: placing the runs left to right is up to the caller.
- Incomplete neutral resolution. Neutrals at the end of the text after right-to-left text come back right to left even in a left-to-right paragraph ("晴天 عيونك 🔥" put the emoji left of the Arabic). The bracket pair rule (N0) is missing: in "عيونك (Remix) 2024" the closing bracket and " 2024" came back as one left-to-right run.
- It reads OpenType only, not `morx` (see above).

What `shape_uncached` adds on top:

1. The paragraph direction comes from rules P2 and P3: the first strong character (L, R or AL), skipping text inside isolates, decides it, and left to right if there is none. `bidi_class` reads kb_text_shape's table and treats letters it calls neutral from U+3400 up as L. The direction goes to kb_text_shape's `ShapeBegin` and is used for run order and truncation.
2. Spaces and brackets at either logical end of a run are split into one-glyph runs, so they can be placed on their own.
3. Each run is classed as strong (has an L, R or AL character), number (EN or AN but nothing strong) or neutral. A strong run's direction is its first strong character's, not kb_text_shape's.
4. `resolve_levels` applies W7 (numbers after left-to-right text are left to right), N0 (bracket pairs), N1/N2 (other neutrals take the direction on both sides if it agrees, else the paragraph's) and I1/I2 (levels 0, 1, 2).
5. A run whose direction changed is reversed, and its brackets are swapped for the mirrored glyph or back.
6. `visual_order` applies L2: from the highest level down, reverse every stretch at that level or above.

With that, the specimen lines read as the Unicode algorithm says: "abc ابجد 123 هوز def", "Song שיר לשלום 2024 end" (the number lands left of the Hebrew), "2024 (Remix) عيونك", "abc (שלום) def", and the emoji stays at the end of "晴天 عيونك 🔥". Tests check the glyph order of these and a few more.

Limits: this works on whole runs, so it can't separate a number glued to letters inside one kb_text_shape run. Apart from the paragraph direction skipping isolates, it ignores explicit embeddings and isolates (LRE, RLI and the rest) and Arabic-Indic digits' special rules (AN). There's no line breaking yet, so L1 (trailing whitespace) doesn't apply. `Glyph.cluster` gives hit testing and cursor movement a codepoint index per glyph.

### Weight

At 2x with white text on the app's dark background, the rendered weight sits between CoreText's two modes. Summed brightness over "The quick brown fox jumps over" at 13 pt, against the same string drawn by CoreText into an opaque sRGB bitmap: ours 494k, CoreText without font smoothing 425k (it blends in gamma space, so it looks lighter), CoreText with font smoothing 569k. Glyph shapes and pixel placement match CoreText's; the difference is in edge brightness, from blending coverage in linear light. Dark text on a light background will look lighter than native for the same reason. Screen capture isn't permitted in the environment this was built in, so there's no comparison against a real AppKit window yet.

### Performance

`TIDALFAST_BENCH=text` on the 10,000-row list (about 25 rows in view, four labels each, plus the specimen panel and overlay, about 1,500 glyph instances), release build, Apple M1, 120 Hz display link. ui is the time spent building the frame, before `end_frame`:

| phase | what | ui avg | ui max |
|---|---|---|---|
| warm | scrolling back and forth over rows already shaped | 0.50 ms | 1.5 ms |
| cold | scrolling 6 rows per frame into rows never seen | 0.95 ms | 6.4 ms |
| jump | a whole new page of rows every frame | 1.32 ms | 3.9 ms |
| scripts | warm scrolling, plus a line in a new script every 30 frames | 0.57 ms | 3.2 to 4.2 ms |

The debug build is about five times slower (2.5 ms warm, 2.7 ms cold). The list itself takes about 0.1 to 0.25 ms warm. Cold frames are dominated by kb_text_shape, which costs about 0.4 µs per character (17 µs for "Bohemian Rhapsody (feat. Kendrick Lamar)"), and by CoreText shaping for Arabic and emoji runs (about 15 µs). The cold maximum is the phase's first frame, which jumps 1,000 rows and shapes about 80 runs at once. The warm maximum is a cache sweep, which runs every 256 frames and is counted in ui. An idle window still uses no CPU.

The scripts phase adds Thai, Devanagari, Georgian, Armenian, Ethiopic, Tamil, Khmer and Sinhala, none of which the prewarmed fonts cover, and logs each line's first frame and when it's first drawn with its font. With fonts loaded on the UI thread, those first frames took 5.8 to 21.9 ms. With the loader they take 0.4 to 2.1 ms, and the text appears one or two frames later, 8 to 18 ms after the line was added. The phase maximum is the frame after that, when CoreText rasterizes the new font's first glyphs within the raster budget.

## UI

`src/ui` is an immediate-mode UI after Ryan Fleury's box UI in raddebugger. Each frame the app builds a tree of boxes. `end_frame` lays it out, draws it with `render` and `text`, and records where every box landed. The next frame tests input against those rects, so a click goes to what was on screen.

```odin
ui.begin_frame(&s.ui, events, r, &s.text, w, h, time, ui.hardware_buttons())
{
	ui.row("body", {}, ui.fill(), ui.fill())          // parent until the end of the scope
	ui.label("Your Library", ui.text_size(), ui.px(52))
	if ui.button("Play##play").clicked { play() }
}
animating := ui.end_frame()                             // goes to the shell as Frame_Result.animating
```

### Boxes and keys

A box built with an ID string is keyed by an FNV-1a hash of the string, seeded with the key of its nearest keyed ancestor, so `"##row12"` in two lists gives two keys. `"Play##row12"` shows "Play" and hashes the whole string. `"Pause###play"` hashes only `"###play"`, so a label can change without the box losing its state. Keyed boxes come from a pool of 8,192 in the persistent arena, found through a 4,096-bucket chained hash table, with a free list. Each one keeps its rect, clipped rect, content size, scroll offset and animation values. `begin_frame` frees every box that wasn't built in the previous frame. A box with no ID (`ui.label`, spacers) lives in the frame arena for one frame and has no state. A key built twice in one frame makes the second box keyless instead. When the pool is full, new keyed boxes come from the frame arena with key 0 and keep no state. The UI logs that when it starts, at most once a second, and the overlay's last line turns red with the number of boxes that missed out.

`State` and every box are plain data: pointers into the persistent arena and the frame arena, no procedure pointers. The renderer and text pointers and the tree are set again by `begin_frame`, and the package keeps its current `State` in a thread-local pointer that `begin_frame` sets, so a hot reload carries the UI over. Strings given to boxes must live until `end_frame`. That holds for literals, the persistent arena and `fmt.tprintf`.

### Sizes and layout

Each box has a size per axis: `px(n)`, `text_size(pad)` (the label's width or line height plus `pad`), `pct(f)` of the nearest ancestor with a size of its own, or `children_sum()`. `fill()` is `pct(1, 0)`. Each size has a strictness: how much of it the box keeps when its parent has too little room. `layout.odin` runs Fleury's five passes per axis: standalone sizes (pixels, text), upwards-dependent (percentages, skipping ancestors sized by their children), downwards-dependent (children sums), violations, then positions. The violations pass runs from the root down, and before it solves a box's children it takes their percentages again from the box's final size. Without that, a `fill()` inside a `fill()` that its parent shrank kept the outer one's first size, and a strict `pct(f, 1)` inside it, like the progress bar's fill, came out as a share of the whole window. When the children along a box's child axis don't fit, each gives up `size * (1 - strictness)` in proportion until the overflow is gone. Across the axis a child larger than its parent is cut to fit. Scroll views allow overflow on their scroll axis and skip that step. A box with `Floating_X`/`Floating_Y` sits at `fixed_pos` outside the flow. So a row of `px(44)`, `fill()` and `px(56)` gives the middle box whatever is left.

### Input

`process_events` folds the frame's events into `Input` and walks them in order. The hit list from the last layout holds every keyed box that is clickable, focusable or scrolls, with its clipped rect, in drawing order. The hot box is the last clickable one under the mouse, so children beat parents and the floating layer beats everything. A press makes the hot box active for that button. A release over the active box is a click. While the left button is held only the active box can be hot. `ui.signal(box)` reports hovering, held, pressed, released, clicked, double-clicked (from the shell's click count), right-clicked (on mouse down, as macOS menus do, control-click included), dragging (past 4 pt, until the release) with the drag delta, and scroll. `Signal.mouse` is the current mouse while held and where the button came up when released, and the drag delta runs to the release too. A press and release in one frame, which happens when the events arrive between two frames, still reports both, so sliders and handles act on `held || released` with `Signal.mouse` rather than on `held` alone. `Input` keeps where each button last went down and came up.

A release can go missing, as when the mouse comes up in another app after the window lost focus. So the app passes `ui.hardware_buttons()`, which asks CoreGraphics (`CGEventSourceButtonState`) which buttons are down in the whole session, to `begin_frame`. A button held since an earlier frame that is up in hardware, with no event for it this frame, gets one more frame for its release to arrive, and then the UI lets go of it: no release, no click, and a drag it held ends without a drop. A hot reload lets go of every button the same way (`ui.cancel_pointer`). Without the hardware state, as in the tests, the UI goes by the events alone.

A clickable box also counts as hovering while its clickable child is hot, so a row stays lit under its own "more" button.

Keyboard: Tab and Shift-Tab move the focus through focusable boxes in drawing order, starting at the first or last when nothing has it. Up and Down move it among focusable boxes with the same keyed parent. Enter and Space click the focused box (`Signal.keyboard` says it came from a key). Escape cancels a drag, or else closes the menu, or else drops the focus. When the keyboard moves the focus, the nearest scroll view around the focused box scrolls the least it takes to show it. A press moves the focus to the box clicked, or its nearest focusable ancestor. Keys the UI doesn't use wait in a list for `ui.key_pressed(code, modifiers)`. Focus from the keyboard draws a ring; focus from a click doesn't.

### Scrolling

A trackpad gesture scrolls the view it started over until the next gesture, momentum included. A mouse wheel scrolls whatever is under the mouse. Trackpad deltas move the view straight away. macOS sends the momentum phase as more deltas, so the UI adds no inertia of its own. Wheel lines (16 pt each) move a target that the view eases toward. Both are clamped to the content size from the last layout while building, then again to the layout just done, since the content may have shrunk. `ui.virtual_rows(view, count, row_h)` builds only the rows in view, `floor(offset / row_h)` to `ceil((offset + height) / row_h)`, plus one row past each edge so the keyboard can move onto it, with a spacer above and below for the rest.

### Animation and redraws

`hot_t`, `active_t`, `focus_t`, `open_t` and the scroll offset ease toward their targets with `v += (target - v) * (1 - exp(-dt * k))`. The step is capped at 1/30 s, so the first frame after a long idle doesn't jump to the end. A value within its epsilon snaps to the target. Anything still moving sets `animating`, which `end_frame` returns and the app passes to the shell. A new keyed box asks for one more frame, since it has no rect to test input against yet, and so does a hot box that changed under a still mouse. So does a scroll view whose layout didn't match what its children were built for: its size changed (a taller window needs more virtual rows) or its offset had to be clamped (the content shrank). The next frame builds it right. At most 3 such frames come in a row, so a layout that never settles can't keep the window drawing. The count starts over in a frame with events or a new window size, and when the app calls `ui.data_changed()`, so the limit only stops retries with nothing new coming in. Tooltips keep frames coming during their half-second delay. Once everything settles, no more frames are asked for and the window goes back to 0% CPU.

### Floating layer

`ui.floating()` makes a second root the parent until the end of the scope. It is laid out after the main tree, drawn after it with no clip from it, and its boxes come last in the hit list, so they get input first. Menus, tooltips and the drag ghost live there. `ui.open_menu(id, pos)` opens a context menu and `if ui.menu(id) { ui.menu_item(...) }` builds it while it's open or fading out. The deferred end of `ui.menu` runs at the end of the `if`, so the items must go inside its block. Opening it moves the focus to its first item. While it's open, Tab and the arrows move only among its items and Enter and Space click only them, and closing it puts the focus back where it was. A left click outside the menu closes it and goes no further; a right click closes it and goes on, so it can open another. A menu fading out takes no input, and neither does one that closed while it was being built, as when an item was clicked: its boxes stay out of the hit list. A menu flips above the mouse when there's no room below. `ui.tooltip(signal, text)` shows text by the mouse once the box has been hovered for 0.5 s.

### Drag and drop

A source calls `ui.drag_begin(payload)` once its signal says dragging. From then on the UI owns the drag: any left release ends it, wherever the mouse is and whether or not the source box is still built, and Escape cancels it. Moving on with the button still held after Escape doesn't start a new one. `ui.drag_payload()` reports the drag while it goes on, for drawing a ghost. A target calls `ui.drop_hover(box)` to light up and `ui.dropped(box)`, which returns the payload in the frame a drag ends over the box. A drag that goes down, past 4 pt and up between two frames still drops: its source's signal says dragging and released, `drag_begin` takes it, and since targets built before the source have already asked, `dropped` returns it in the next frame, tested against the rects it was released over. The release asks for that frame.

### Drawing

Box flags pick what's drawn, in this order: shadow, background (optionally a vertical gradient), the hover and press overlays faded by `hot_t` and `active_t`, border, focus ring, label, then the children inside the box's clip if it has `Clip`. `opacity` multiplies the box and everything in it. A label is centred vertically, aligned left, centre or right inside `text_pad`, and truncated with an ellipsis to the box's width. A box whose clipped rect is empty draws nothing itself. Labels are shaped when drawn, through the text cache, unless the box is sized by its text, in which case layout shapes it first. Nothing in the UI allocates outside the frame arena after `ui.init`.

### The library screen

`src/app/library.odin` follows spotifast's layout and dark palette: a sidebar of 32 fake playlists, 250 pt wide by default, resized with a 5 pt handle between 210 and 600 pt (it stops growing once the main view would go below 360 pt). Next to it is the main view with the playlist header and the 10,000-row track table, and the 88 pt player bar runs along the bottom. Rows are 56 pt. The columns follow spotifast's `columns`, measured on the main view's width: #, cover and title always. Album shows above 560 pt (28% of the width, 140 to 360 pt), date added above 760 and added by above 920. Duration and the "more" button always show. Hovering lights a row; a click selects it; a double-click plays it (see Playback), and the row playing is lit. The queue remembers which list it came from (its kind and TIDAL id, or the search query), so the row stays lit after going to another list and back, and the same track in another list isn't lit. When the reopened list's rows differ, the first row with the playing track's id is lit. A right click or the "more" button opens a context menu with Play, Go to album, Go to artist and Copy song link (see Search). Dragging a row onto a playlist shows a ghost and a drop highlight. The drag goes through `ui.drag_begin` with the row index, so releasing after the row has scrolled out of view still ends it. With the table focused, the arrow keys, Page Up/Down and Home/End move the selection and scroll it into view, and Enter plays it. The player bar has previous, play/pause and next, a progress bar that seeks on click or drag and shows the drag position while held, elapsed and remaining time, and the volume slider. The times, the volume label and the table's Time column are as wide as the widest value their pattern can show, measured with Inter's widest digit, so they're never cut off; the progress bar and the volume slider take what's left. Rows whose page hasn't arrived yet show their number and grey bars. With `TIDALFAST_FAKE=1` the 32 playlists and 10,000 rows are the fake data again and covers are gradients.

### Performance

`TIDALFAST_BENCH=1`, release build, Apple M1, 1100×700 window, overlay on. About 10 rows and 1,000 to 1,800 instances in view. ui is everything before `render.end_frame`:

| phase | what | ui avg | ui max |
|---|---|---|---|
| warm | back and forth over rows already built | 0.70 to 0.75 ms | 1.9 ms |
| cold | 3 new rows a frame | 0.94 to 1.16 ms | 3.8 to 5.4 ms |
| jump | a new page every frame | 1.2 to 1.35 ms | 4.3 to 4.8 ms |

With the overlay off, warm is 0.53 to 0.60 ms. Of a warm frame, building the tree takes about 0.13 ms, layout about 0.1 ms, and drawing labels about 0.37 ms (89 labels, so about 4 µs each, inside `text.draw_run` and `render.push`). The cold maximum is the phase's first frame. It jumps 2,000 rows and meets emoji in Medium 14 for the first time. Timed inside `src/text`, that frame spends about 2 ms shaping 40 runs and the rest rasterizing 3 glyphs. Rasterizing the first Apple Color Emoji glyph took 6 ms, and the first line CoreText lays out in Geeza Pro (Arabic) 3.8 ms, against 30 to 200 µs for later lines at any size. The text loader now lays out and draws the character it loaded a fallback face for, on its own thread, which took the cold maximum from 9.3 to 11.9 ms down to 3.8 to 5.4 ms. What remains is per glyph: each emoji glyph costs 0.4 to 2.4 ms to rasterize, decoding its bitmap.

Shaping a run costs 60 to 280 µs. Most of it is kb_text_shape, not CoreText: `ShapeRun`, where kb_text_shape applies Inter's lookups, takes about 2 µs a character (130 to 170 µs for a 70 character title), and push, begin and end take about 1 µs. kb_text_shape keeps its shape configs in the context, so that isn't set up again per run. For text in morx-only fonts (Arabic in Geeza Pro, emoji) CoreText adds 30 to 200 µs per run in `CTLineCreateWithAttributedString`. Building the CFString and attribute dictionary costs 3 to 20 µs and the CTFont per size is cached.

## TIDAL data

`src/app/data.odin`, `workers.odin`, `covers.odin` and `login.odin` connect the library screen to TIDAL through `src/tidal`.

### Login

The login screen's main path is the PKCE login of TIDAL's Android phone client (`6BDSRdpK9hqEBTgU`). TIDAL decides the best stream a token gets by the OAuth client it was issued to, not by the subscription alone, and this is the only client of the ones below that TIDAL gives FLAC. A test with a real account showed what the device-code client gets instead: `playbackinfopostpaywall` answers with HTTP 200, but the manifest's codec is `MP4A`, AAC, for every track. The player doesn't decode AAC, so with that client nothing plays.

How the paste works:

1. With no saved login the screen shows a "Log in with TIDAL" button, two lines saying that TIDAL ends on a page that doesn't load and to paste that page's address here, a text field and "Continue". The app asks TIDAL for nothing until the user acts, and never opens the browser by itself: a window that launches a browser every time it starts without a login is rude, and scripts run it that way too.
2. The button opens `login.tidal.com/authorize` in the browser through LaunchServices (`LSOpenCFURLRef`), with the client id, the S256 challenge of a PKCE verifier, a client key, `appMode=android` and the redirect `https://tidal.com/android/login/auth`. The verifier and key live in `Data`, so a hot reload doesn't lose them.
3. After the login TIDAL redirects to that address, which shows an "Oops" page. Its address has `?code=...`. The user copies it from the address bar and pastes it in the field (Cmd-V, the phase 7 text field). The field holds up to 2,048 bytes; `FIELD_CAPACITY` went from 256 to 2,048 for it, since nobody documents how long TIDAL's codes get.
4. Return or "Continue" checks the address (`pkce_check`). Spaces and quotes around it go. It must start with the redirect, followed by `?` or `/`. An `error=` in it means TIDAL ended the login, and the screen says so with TIDAL's reason. Without a `code=` the screen asks for the whole address. Anything else gets "That isn't the address TIDAL ends on." Nothing goes to TIDAL until the address passes.
5. A `Login_Pkce` job trades the code and verifier for tokens. If the queue is full, the kind goes in `Data.retry` and the next frame pushes it again, so the login can't get lost. If TIDAL refuses the code, the field empties and the screen says to log in with TIDAL again, which makes a new verifier.

`TIDALFAST_PKCE_REDIRECT` (debug builds) finishes the login with the address it holds at start, so a script can log in to `tests/mock_tidal` without a browser.

The code in the address works once. If the exchange gets the tokens and loading the session then fails, the card says so and offers "Try again", which loads the session with the tokens the exchange got. A hot reload in between keeps them too, and the `Login_Pkce` job that was put back finishes with them. Only when there are no such tokens does it trade a code again.

The device-code login is still there, under "Log in with a code instead (AAC only, no lossless)". It shows a code and `link.tidal.com`, and "Open in your browser" opens the link with the code already in it. A worker polls TIDAL (`login_device_wait`) until the user approves, then the library loads. It waits the `interval` TIDAL gave between polls, 5 s longer after each `slow_down`. If the code expires a new one is fetched. If TIDAL can't be reached while the code is still good, the screen says so and the app checks once after 2 s, then 4, 8, 16 and 30 s between tries, never sooner than the interval, and goes back to normal polling as soon as TIDAL answers. A poll that goes back in the queue, after a 429 or a reload, keeps the interval it had reached, `slow_down` included, and waits that long from when it went back. Once a poll has the tokens the code is spent, so if loading the session then fails or waits out a backoff, the next try loads it with those tokens, however long ago the code expired. A 5xx or a 408 counts as not reaching TIDAL, while polling and while loading the session, so it gets the same retries. Anything else stops the login: the screen shows the error and a "Try again" button instead of the code. "Try again" loads the session with the tokens if the login has them, and asks for a new code if it doesn't. If TIDAL refuses the tokens, they go, and "Try again" starts over with a new code. "Log in with TIDAL instead" goes back to the PKCE login.

A login made with the device client, from the Keychain or just now, is recognised by its stored `client_id` (or `is_pkce` false in older items). The library then shows "This login can only stream AAC. Log in again for lossless." along the top, with "Log in with TIDAL" and "Not now". The user can browse meanwhile. "Log in with TIDAL" opens the login page and shows the login screen over the library, with "Back to your library". Pasting an address there ends the old account (its jobs go, as on a sign-out) but leaves its Keychain item until the new login overwrites it, so a PKCE login that fails doesn't lose the old one.

Each login attempt has a number (`Data.login_attempt`). It goes up when the user switches between the two logins, and when a sign-out starts a new login. `Login_Start`, `Login_Wait` and `Login_Pkce` jobs carry the number they were queued with, and the session knows the current one (`tidal.session_set_login_attempt`). A device-code poll that TIDAL approves after the user moved on to the PKCE login has its tokens dropped before they reach the session, so it can't replace a PKCE login that finished first, possibly of another account. Its result is ignored. A poll that was still queued doesn't poll at all. A device code that arrives after the user switched to the PKCE login is dropped too, so the PKCE screen stays. If the user is back on the code login by then, it asks for a code of its own.

The Keychain item stores `client_id`, the client the tokens were issued to. A refresh has to use it: the mock refuses a PKCE refresh token sent with another client id, and TIDAL rotates refresh tokens per client. Items saved before this go by their `is_pkce` flag.

What the reference clients say about client ids, checked October 2026:

| client id | flow | what it streams | who uses it |
|---|---|---|---|
| `fX2JxdmntZWK0ixT` | device code | `LOSSLESS` at best, 16/44.1 BTS | tidalapi's default `client_id`, and this app's device login; lumitide on Linux and macOS (which says it gets `HIGH` AAC with it) |
| `4N3n6Q1x95LL5K7p` | device code | `LOSSLESS` 16/44.1 | riptide and tiddl. riptide's notes say asking it for `HI_RES_LOSSLESS` on a `HIRES_LOSSLESS` track with a `HI_RES` subscription returns `LOSSLESS`, 16-bit 44.1 kHz |
| `6BDSRdpK9hqEBTgU` | PKCE, Android phone | `HI_RES_LOSSLESS`, as DASH | tidalapi's `client_id_pkce`, high-tide (PKCE only, it drops older non-PKCE logins), mare-player. mare-player measured that this client gets the hi-res FLAC tier and issues refresh tokens, and that it serves DASH for both FLAC tiers, `LOSSLESS` included. Its token response names it `TIDAL_Android_2.87.0` |
| `mhPVJJEBNRzVjr2p` | PKCE, Windows desktop, no secret | lossless FLAC | lumitide on Windows, with the `tidal://login/auth` redirect that only the desktop app can receive |

The PKCE scope is `r_usr+w_usr+w_sub`, as tidalapi sends it. mare-player found TIDAL accepts two redirects for the Android client, `https://tidal.com/android/login/auth` (the browser lands on it, so the user copies it) and `tidal://login/auth` (needs a URL scheme handler). Every other redirect it tried, `http://127.0.0.1` included, gets error 11102, so a local web server can't catch the code. A `tidal://` handler would remove the copy and paste, but needs the shell to register the scheme. Developer-portal credentials don't work at all: the device flow refuses them ("not a Limited Input Device client") and their tokens get 401 from `playbackinfopostpaywall`, per riptide. None of this has been tried against the real TIDAL from here; it's what the reference clients document.

### Keychain

The tokens go in the login Keychain as one generic password item: service `tidalfast`, account `auth`, label `TIDALfast`. Its data is JSON: token type, access and refresh tokens, expiry, session id, country code and user id. Nothing goes in a file.

`src/mac` calls Security's `SecItemAdd`, `SecItemUpdate`, `SecItemCopyMatching` and `SecItemDelete` directly from Odin with hand-written foreign declarations, along with the CoreFoundation calls to build their dictionaries. These are plain C functions, so they don't hit the compiler's Obj-C bug, and going through the shell would have meant a new ABI version for no gain. They're thread safe, which matters because the tokens are saved from workers.

`src/tidal` refreshes the access token one request at a time: concurrent requests that find it expired wait on one refresh (`refresh_access_token` holds `refresh_mutex`). TIDAL may send a new refresh token with each refresh and the old one stops working, so the session now calls `Session.on_auth_change` after every refresh and login, on the thread that did it, while still holding that mutex. The app's handler writes the item. So the Keychain always has the latest refresh token, and writes never overlap.

At start a worker reads the item and puts it in the session with `tidal.session_restore`, without asking TIDAL anything. An expired access token is refreshed by the first request. The app signs out (`sign_out` in `data.odin`), deleting the item and showing the login screen, in two cases. One is TIDAL turning the refresh token down: a 400 or 401 with the OAuth error `invalid_grant`. The other is a 401 to an API request that sent the tokens. A cover or a login job never signs out, since covers carry no token and a login job's 401 means the user denied it. Any other refresh failure, such as a 408, a 5xx, a 400 with another code or no answer at all, keeps the tokens. A rate-limited refresh waits out the backoff like any 429. For the rest the job goes back in the queue after 2 s, then 4, 8, 16 and 30 s, until a refresh works.

Several requests usually fail together when a login ends. Each job carries the auth generation it was queued in (`Data.auth_gen`), and `sign_out` raises it, so the first failure signs out and every later result from the old generation is dropped before anything looks at its error. `sign_out` also takes the old login's jobs out of the queue and calls `tidal.session_clear_auth`, which empties the session and cancels requests sent with the old tokens, in flight or not. A refresh that finishes after that doesn't store its tokens. Then exactly one new login starts. Saving and deleting the item happen under one mutex, and a save checks that the tokens it read still belong to the session's current login, so a late refresh of the old login can't bring the item back or overwrite the new one.

Reading happens on a worker for a reason. The login Keychain ties an item to the code signature of the program that made it. Our builds are ad-hoc signed and clang's output differs from build to build, so a rebuilt `build/tidalfast` counts as a different program, and macOS asks the user whether it may read the item. That dialog blocks the calling thread until it's answered. Meanwhile the library says it's reading the Keychain. To keep the dialog rare, `build.sh` relinks the shell only when `shell/` changes or the build mode does, so `./build.sh` and `./build.sh app` leave the binary, and its signature, alone. The data protection Keychain would avoid this, but it needs an entitlement, which needs a real signing identity (`-34018` without one). The `security` command line tool isn't on the item's access list either, so `security find-generic-password -w` prompts too; without `-w` it shows the item without reading it.

### API version

Everything goes through TIDAL's v1 API at `api.tidal.com/v1` using what `src/tidal` already has:

- `users/{id}/playlistsAndFavoritePlaylists` for the sidebar: playlists the user made and the ones they follow, 50 at a time.
- `users/{id}/favorites/tracks` for Liked Songs, newest first.
- `playlists/{id}/tracks` for a playlist.

The plan said v2 (`openapi.tidal.com`). The reference clients show v1 still works with a device-code token: lumitide logs in the same way and reads `users/{id}/favorites/tracks`, `users/{id}/playlists` and `playlists/{id}/items` from v1, and tidalapi (behind high-tide) has all three endpoints above. riptide moved to v2 and says it works, but riptide still needs v1 for playback, so v1 isn't going away for us either. v2 is JSON:API, where a playlist's tracks come back as references that need `include` and a second lookup per page, and `src/tidal` has none of that yet. v1 returns whole tracks with their album covers in one response. If TIDAL turns these endpoints off, `user_playlist_and_favorite_playlists`, `favorites_tracks` and `playlist_tracks` are the three calls to replace.

### Jobs and threads

Four worker threads (`WORKERS`) share two queues in `State`, both from `src/jobs`. The jobs queue goes from the UI thread to the workers. The results queue goes back. Each is a fixed array of 256 plain-data items behind a mutex and condition variable. Jobs come out by priority, then oldest first: data (sign-in, playlists, track pages) before visible covers, visible covers before the ones just outside the view. A job a worker has taken keeps its slot until it's done or put back, so a job cut short always has room to go back, however full the UI made the queue meanwhile. Covers leave 16 slots free for data jobs. If the queue refuses a data job anyway, its kind goes in `Data.retry` and the next frame pushes it again; a worker finishing a job frees a slot and asks for that frame. A refused cover stays wanted and is pushed again the same way. A job holds only fixed-size text (a playlist id, an image id, a device code) and numbers, so it never points into memory a view switch or a reload could free. A worker runs a job, pushes the result and calls the shell's `request_redraw`. The next frame takes results right after `ui.begin_frame`.

Kinds of job: `Restore` (read the Keychain), `Login_Start`, `Login_Wait`, `Login_Pkce` (finish the PKCE login with the pasted address), `Playlists`, `Tracks` (one page), `Cover`, `Stream` (resolve a track's stream, see Playback), `Artwork` (a cover for Now Playing, kept as pixels), `Search` (see Search) and `Save_Settings` (write the output settings, so a click never waits on the disk; see Output settings). `Tracks` also pages through search results, an album's tracks and an artist's top tracks.

Hot reload: `unload` sets the session's abort flag, which makes curl stop any transfer in flight (an `XFERINFOFUNCTION` that checks it) and `login_device_wait` return. Then it stops both queues and joins the workers. A worker whose job was cut short puts it back in the queue where it was. `unload` then copies the session's login state to a heap buffer, keeps the backoff's end and reason in `State`, and destroys the session, since a `tidal.Session` holds allocators and a curl handle pool made by this dylib. `reload` makes a new session, restores the login and the backoff, and starts new workers, which pick up the jobs that were put back. So a reload during a 30 minute anti-abuse hold doesn't end it. A device login that got its tokens but hadn't loaded the session when the reload came keeps them too: `reload` restores tokens without a user only then, and the `Login_Wait` that was put back finishes the login with them. Results that were waiting stay in their queue. A `Login_Wait` job holds the code's expiry as a time, not a duration, so a reload doesn't stretch it.

### Memory

Each job that returns data gets its own virtual-memory arena (`core:mem/virtual`), and `src/tidal` parses into it. Scratch memory is the worker's thread-local temp allocator, reset after each job, never the result allocator. The UI thread then:

- adopts the Playlists result's arena as the sidebar's, and destroys the previous one;
- copies a track page's rows into the open list's arena and destroys the page's;
- uploads a cover's pixels and frees them.

The open list's arena lives in `State` and is destroyed when another list opens, which gives its pages back. A worker's temp allocator is one 4 MB block, and parsing a page of tracks dirties about 750 KB of it; rolling it back keeps those pages. So a worker that finds the queue empty after a job gives back all but 64 KB of the block with `MADV_FREE_REUSABLE`, and takes it back with `MADV_FREE_REUSE` before its next job. On the mock that's about 2.3 MB after a list has loaded. Pages carry the list's generation number, so a page for a list that's been closed is dropped when it arrives.

The frame's boxes and its accessibility tree borrow strings from the open list, the search results and the play queue until `end_frame`. So nothing a frame does while it's being built may free them. A click that opens another list, closes the search or plays from the track menu goes in `State.pending`, and `pending_apply` does it once the frame is drawn, then asks for the next one. Results from the workers are handled at the start of a frame, before anything borrows from them. Debug builds keep the last closed list's arena, filled with `0xdb`, until the next list closes, so a string still borrowed from it shows up as garbage instead of passing for the next list's data. The tests turn the same thing on.

### Pages

A list opens with the track count TIDAL gave for it, so the table has its full height straight away and rows not yet loaded show as placeholders. The first page is 50 tracks so it shows sooner. The rest come 100 at a time, two pages in flight. Each page of Liked Songs or a playlist carries TIDAL's `totalNumberOfItems`, and the page that reaches it ends the list. TIDAL leaves tracks that can't be played out of their page but still counts them, so a page can come back short in the middle of a list. That's a gap: the rows after it move up, and later pages land where TIDAL's offset minus the gaps before it puts them. A list of 1,433 liked tracks with three unavailable shows 1,430 rows. Before this, a short page ended the list, which cut Liked Songs off at 149. Lists without a total (search, albums, artists) still end at a short page. Pages can arrive out of order, so the earliest end found stands: an empty page asked for past the end can't raise the count again, and rows past the end are dropped. If a list without a total turns out longer than TIDAL said, full pages keep raising the count and one more page is asked for at a time until a short one.

### Rate limits

`src/tidal` already backs off after a 429 (for `Retry-After`, or 60 s) or an anti-abuse 403 (for `Retry-After`, or 30 minutes), and refuses requests locally until then. All workers share one session, so they share that state. The OAuth endpoints go through it too: asking for a device code, polling for approval and refreshing the token. Covers go through it as well: `tidal.resource_get` downloads from `resources.tidal.com` with the session's backoff check and curl pool, without the API's token and parameters. A worker checks `backoff_remaining` before each job. While it's above zero, the worker puts the job back and sleeps until the backoff ends or the queue stops. A job refused with `Backing_Off`, or the one that got the 429 or 403, goes back in the queue too, instead of failing. The library's status line says how long TIDAL asked us to wait.

### Covers

1. Drawing a cover asks the cache (`src/cover`) for it at the size it's drawn at on this display, in pixels: the box's points times the backing scale. Track rows are 40 pt, so 80x80 at 2x; the 92 pt header is 184x184 and the 56 pt Now Playing cover 112x112. `pick_size` picks what to download: the smallest size TIDAL serves that's at least that many pixels, so 80x80 for rows, 320x320 for the header, and 160x160 for the sidebar's playlist images, the smallest TIDAL has for playlists. Rows within 4 of the view ask for theirs too, at a lower priority.
2. After the frame is built, `covers_schedule` queues a job for each cover asked for this frame with no job yet. Queued covers that weren't asked for this frame, because their rows scrolled away, come out of the queue. A worker that already has one finishes it, and the cover stays in the cache.
3. The worker downloads the JPEG, decodes it with `stb_image`, scales it to the drawn size with `stb_image_resize` (filtering in linear light) when the two differ, and runs `render.convert_premultiplied` on the pixels, so the upload can pass `converted = true`.
4. The UI thread copies it into a slot of a shared page. Uploads stop for the frame after 2 ms; what's left waits for the next frame.
5. A page is one RGBA8 texture holding a grid of covers of one pixel size, up to 8x8 and at most 640 texels across (one cover per page if it's wider): 64 row covers in 1.6 MB, 9 header covers in 1.2 MB. Every cover is drawn at exactly its pixel size, so no page needs mipmaps. A new cover takes a free slot of its size, or opens a page while the pages stay within 8 MB, or else takes the slot of the least recently drawn cover of its size. That cover can't have been drawn in the last three frames, which the GPU may still be drawing, so overwriting its slot never shows in a frame. If every cover of that size was drawn lately, a page opens over the budget, and after the frame the cache gives back whole pages until it's within budget again: the page whose newest cover was drawn longest ago first, never one with a cover drawn this frame. The cache keeps up to 2,048 entries.

One texture per cover cost far more than its pixels. With 571 covers loaded, Metal's allocations grew about 96 KB a cover for 25 KB of 80x80 pixels and a third more of mips. Pages also let a batch of covers share a draw call; see Renderer.

A cover shows a flat placeholder until its texture arrives, then fades in over 0.25 s. The fade asks for frames only until it finishes. A cover that failed is tried again once it has left the screen and comes back, or after 30 s. That includes a 401: cover downloads send no token, so their answer says nothing about the login.

Texture uploads don't wait on the GPU. Pages have no mips, and a mip generation is the only thing `texture_update` waits on.

### The mock server

`tests/mock_tidal` serves the device login (approved a few seconds after the first poll), token refresh that rotates the refresh token, the session and user, 1,433 liked tracks (at most 100 a page, with three unavailable ones left out of their pages but counted in `totalNumberOfItems`, as TIDAL does), 12 playlists (one with 3,000 tracks), their tracks, and covers drawn on request as JPEGs at any size. Flags set the long playlist's length, the login delay, the access token's lifetime, delays for pages and covers, a request to answer with 429, 429s for the first device code requests, `slow_down` answers to the first polls, a 429 to one poll of each code, a point after which it refuses the login with 401 until the next device login, and 401s to the first covers after each device login, held back for as long as you ask. It prints the time between polls. The comment at the top of `main.odin` lists them. It never prints tokens or Authorization headers, and neither does the app.

It answers `/search` too. Tracks of the long playlist match by title or artist, ignoring ASCII case, up to TIDAL's 300, with their albums and artists and the playlists whose names match. A query that matches nothing, such as 日本語, gets 120 made-up tracks named after it, so every query has results. `/albums/<id>/tracks` and `/artists/<id>/toptracks` return 12 and 20 made-up tracks. It logs each search with its query.

It also serves playback (see Playback below). Flags add a delay before every audio response (`-audio-delay=ms`), cap each audio connection's bandwidth (`-audio-rate=KB/s`), leave the SEEKTABLE out of the files (`-seektable=0`) and pick where the generated audio goes (`-audio-dir`).

For hi-res it serves the PKCE login (`/authorize` redirects straight to `/android/login/auth?code=...`, and the token endpoint takes an `authorization_code` grant only with the Android client's id, a verifier and that redirect) and a hi-res test album as liked tracks 4 to 6 (`hires.odin`): "Quiet Noise 16/44.1" as a BTS FLAC, then two 24/96 tracks of 10 and 6 seconds. Those come as DASH (`HI_RES_LOSSLESS`, an MPD with a `SegmentTemplate` and a `SegmentTimeline`, 4 second fMP4 segments under `/dash/`) when a PKCE login asks for `HI_RES_LOSSLESS`, and as the 16/44.1 file otherwise. All three are xorshift noise at about -60 dBFS, made as WAV, encoded with `afconvert` and cut by `tests/dashgen`. `-hires-only` makes them the only liked tracks, so playing through the list never reaches the loud test tones.

Like TIDAL, the mock gives the device-code login AAC: every `playbackinfopostpaywall` answer to it is HTTP 200 with a BTS manifest for `mp4a.40.2`. `-device-flac` gives it FLAC as before. The PKCE login gets FLAC: BTS for `LOSSLESS`, DASH for the 24/96 tracks at `HI_RES_LOSSLESS`. `-refuse-hires` answers `HI_RES_LOSSLESS` with a 403, and `-lossless-dash` sends the 16/44.1 track as DASH to a PKCE login, at `LOSSLESS` too, for the fallback.

```
odin build tests/mock_tidal -out:build/mock_tidal
./build/mock_tidal -port=8787
TIDALFAST_API=http://127.0.0.1:8787 ./build/tidalfast
```

### Performance

`TIDALFAST_BENCH=covers` against the mock (40 ms per cover), release build, Apple M1, 120 Hz, 1100x700 window. Once the sidebar loads it opens the longest playlist and waits for 300 rows. Then it scrolls one row a frame for 600 frames, so a new cover is wanted about every frame, then four rows a frame for 300 frames, so most covers are dropped before a worker gets to them, then holds still for 120 frames. Two runs:

| phase | ui avg | ui max | frame avg | frame max | covers uploaded | most uploads in a frame | longest results step |
|---|---|---|---|---|---|---|---|
| scroll | 0.74 to 0.78 ms | 2.9 to 3.8 ms | 8.27 ms | 9.8 to 10.5 ms | 410 | 4 (0.43 to 0.48 ms) | 1.2 to 1.3 ms |
| fast | 0.89 to 0.90 ms | 2.8 to 3.9 ms | 8.30 ms | 9.4 ms | 163 to 167 | 3 to 4 (0.70 to 0.93 ms) | 0.8 to 0.9 ms |
| settle | 0.61 to 0.64 ms | 0.9 to 1.0 ms | 8.30 ms | 9.4 to 9.5 ms | 0 to 1 | 1 | 0.4 ms |

Frame time includes waiting for the next drawable, so its average is the 120 Hz interval. The fake-data bench in the same build has frame maxima of 9.3 to 11.9 ms, so covers add no hitches. An upload of an 80x80 cover costs about 0.1 to 0.4 ms. The longest results step includes copying a page of 100 rows. The ui maximum comes from shaping text in rows seen for the first time, as in the fake-data bench. Afterwards the cache held about 590 covers in 21 MB, and the window went back to 0% CPU.

## Playback

`src/audio` plays FLAC at any rate and depth: TIDAL's `LOSSLESS` as one FLAC file, and `HI_RES_LOSSLESS` (up to 24-bit 192 kHz) as DASH. `src/app/player.odin` connects it to the queue, the player bar and the shell.

### Getting a stream

`tidal.resolve_stream(session, track_id, quality)` asks v1 `tracks/{id}/playbackinfopostpaywall` with `playbackmode=STREAM`, `assetpresentation=FULL` and an `audioquality`. The app calls it through `resolve_stream_flac`. A PKCE login asks for `HI_RES_LOSSLESS` first, and asks again for `LOSSLESS` if TIDAL refuses that tier: a 403, no stream at that tier, an encrypted one, or a lossy one in its place. That's riptide's rule; it found a 403 means the account isn't entitled to the tier, and that a `HI_RES_LOSSLESS` answer can carry AAC. A 401, a 429 or a 5xx isn't a refusal of the tier and fails the track as it is. The device-code login asks for `LOSSLESS` only. Either tier may come as either manifest: mare-player found the Android client gets DASH for `LOSSLESS` too. The answer carries one of two manifests:

- BTS (`application/vnd.tidal.bts`): base64 JSON with `mimeType` (`audio/flac`), `codecs`, `encryptionType` and `urls`. `resolve_stream` returns the first URL.
- DASH (`application/dash+xml`): a base64 MPD with one `Representation` (`codecs="flac"`, `mimeType="audio/mp4"`) and a `SegmentTemplate` with absolute `initialization` and `media` URLs (`$Number$` from `startNumber`, a token in the query) and a `SegmentTimeline`. `dash_info_from_mpd` expands the timeline (`t`, `d`, `r` repeat counts, `r="-1"` up to the next `t` or the end of the period) into segments with their start and length in `timescale` units. `resolve_stream` returns the initialization URL, the segments and the timescale.

Both come with the sample rate and bit depth and the ReplayGain fields `trackReplayGain`, `trackPeakAmplitude`, `albumReplayGain` and `albumPeakAmplitude`, the names tidalapi, riptide and the other reference clients read. It refuses encrypted streams (an `encryptionType` other than `NONE`, or a `ContentProtection` in the MPD) and anything that isn't FLAC. A non-FLAC manifest fails with `Lossy_Stream` and the codec as its detail. The player bar then says "TIDAL sent AAC for this login. Log in with TIDAL again for lossless." and playback stops on that track rather than failing through the queue, since every track comes the same way for that login. There's no AAC decoder. A missing gain is 0 dB and a missing peak 1.0. A track without album gain uses its track gain for both.

Resolving runs as a `Stream` job on the data workers. A stream that doesn't resolve is logged on stderr with the track id, the error kind, the HTTP status, TIDAL's `subStatus` if the body had a numeric one, and for `Lossy_Stream` the manifest's codec:

```
app: stream for track 900101 failed: Lossy_Stream, codec MP4A
app: stream for track 900101 at HI_RES_LOSSLESS failed, asking for LOSSLESS: Http, HTTP 403, subStatus 4005
```

What the server said (`userMessage`, `errors[].detail`, or the start of a body that isn't JSON) never goes to a log. A 500 from a CDN can echo a signed URL, and an error body can hold anything. That text stays in the error's detail for the player bar. `tidal.error_summary` builds the log line from the structured fields alone, and a codec or quality name gets in only if it's on a known list (`tidal.codec_name`, `tidal.quality_name`), so a manifest with a URL for a codec logs `codec unknown`. `src/tidal` follows the same rule on its own `log` calls: a failed login logs its HTTP status, a backoff its status and length, and an error response no body at all. Nothing logs a token, a stream URL, or the pasted PKCE address with its one-time code.

 Stream URLs expire, so when a download fails with a 4xx the app resolves the track once more and carries on from where it was.

### Threads and buffers

```
fetch thread per track slot --bytes--> Stream window --> decode thread --float frames--> Pcm_Ring --> audio callback --> device
```

- **Fetch.** Each of the two track slots, current and next, has a thread that downloads the file with curl into a 3 MB window: about 17 s of 16/44.1 FLAC and 5 s of 24/192, with the ring's 3 s after it. A DASH track is the initialization segment and then each media segment, fetched one after another into the same window as one run of bytes; see DASH below. The window slides forward as the decoder reads and keeps 256 KB behind the read position for short seeks back. Each request is an HTTP `Range` from where the window ends. When the window is full the thread blocks on a condition variable, so a paused track holds a connection and uses no CPU. If the server closes the connection, the thread resumes from where it got to. After 5 failures in a row, or a 4xx, the track fails. The window is a mapping of its own. When the slot's stream is cleared, by a stop, another track or none, its pages go back to the system with `MADV_FREE_REUSABLE` and stop counting against the app until bytes arrive again. It was 8 MB of heap that stayed dirty after playback stopped: after the mock's hi-res album played out, 5.9 MB of it was still counted, and none is now.
- **Decode.** One thread owns the slots and the device. It feeds dr_flac (`ma.decoder` with our own read and seek callbacks) the header bytes and then the file from whatever frame a seek started at, applies the track's ReplayGain and writes float frames into the ring. Commands and arriving bytes wake it through a semaphore. Nothing wakes it when the ring has room: while the device runs it also wakes on a timer, every 250 ms or sooner if a quarter of the ring (`LOW_WATER`) would play in less, and tops the ring up. While nothing plays (paused, stopped, or the queue ended) the device is stopped and it waits on the semaphore with no timeout.
- **Ring.** `Pcm_Ring` is a single-producer, single-consumer ring of 131,072 frames (3 s at 44.1 kHz) with atomic read and write positions. The decode thread drops everything not yet played by storing a flush position, which the callback skips to on its next call, so the writer never touches the reader's position. A queue of marks next to it says which track or seek starts at which ring position. The callback adopts each mark once it has read past it, so the status describes the frame being played.
- **Callback.** It copies frames out, ramps the volume over one buffer, adopts marks and publishes the current mark and position. It never locks, allocates, logs, waits or makes a system call, and it doesn't use the Odin context. For the seek latency log it reads `mach_absolute_time`, which reads the commpage. The mark's serial, seek id and end flag and the position go out in their own atomics under a sequence count that is odd while they change, and `status` reads them again if the count was odd or moved, so it never pairs one track's or seek's mark with another's position.
- **Main thread.** The app sends commands (`play`, `stop`, `seek`, `set_next`, `set_paused`) under a mutex that the decode thread holds only to copy them, and reads a `Status` snapshot each frame. Neither waits on the network or the device. The decode thread wakes the UI when the status changes, and four times a second while playing for the progress bar.

### Queue and gapless

Double-clicking a row copies the open list into the queue and plays from that row. The rows after it follow. Each new queue gets a generation, and a preloaded track is reused only if its generation, row and track id all match, so a row of a new list never plays bytes preloaded for the old one. The play button and the toggle media command start the selected row (or the first) when nothing is loaded, start the queue again from the top once it has played out, and otherwise pause or resume. Signing out, or TIDAL ending the session, stops the player and clears the queue and Now Playing. The volume stays. Next and previous move through the queue and skip rows without a track id. Previous restarts the track instead once it has played 3 seconds. The queue follows the list while its pages load.

About 30 seconds before the current track ends, or once all of it has downloaded, the player asks for the next track. The app resolves it and hands it over with `set_next`, and its fetch thread starts downloading. When the current track's decoder runs out, the decode thread writes the next track's first frames into the ring right after the last ones, with a mark between them, so the device sees one unbroken stream. When the mark plays, the queue moves on. If the next track's stream fails to resolve, the app remembers it by queue generation, row and track id and doesn't ask for it again while the current track plays, even though the player keeps asking for a next track. When the current track ends that track becomes current, gets one more try, and if it fails again the player bar says why and the queue skips on. A new queue forgets it. If the next track has a different sample rate or channel count (or bit depth, in bit-perfect mode), the decode thread lets the ring play out and reopens the device, which leaves a short gap. While it waits it wakes as soon as the ring should be empty instead of every 250 ms, so the gap is the device's re-clock and little else (see Bit-perfect output).

### ReplayGain and volume

In bit-perfect mode neither applies (see below). Otherwise a track gets album gain when it plays as part of its album in order: the queue entry before or after it is from the same album, with the track number one away. Otherwise it gets track gain, so a playlist of singles plays at an even level. The factor is `10^(gain/20)`, lowered to `1/peak` if it would push the peak over full scale. The decode thread applies it. The volume slider applies after it, in the callback, as the cube of the slider's position, so half way is about -18 dB.

### Seeking

A seek shows its position in the player bar at once. It names the track it's for, and the decode thread drops it if that track no longer plays; `play` also drops a seek it hasn't applied yet, so a new track never starts at the old one's seek position. The player bar stops showing the target as soon as its track isn't current, including when the audio moved on to the next track before the seek arrived. The decode thread then looks for the frame to start from. It brackets the target with the SEEKTABLE's points, or with the first frame and the end of the file when there is no SEEKTABLE. It guesses a byte offset in proportion and looks there for a frame header that the next header confirms: sync code, CRC-8, and the next frame starting where this one's samples end. It narrows the bracket until it has a frame no more than 0.3 s before the target, decodes from there and drops the samples before the target. A guess outside the downloaded window empties it and starts a new range request at that offset, and playback goes on from those bytes. A seek inside the window doesn't touch the network.

Measured from the seek command to the first sample at the new position leaving the callback, against the mock with `-audio-delay=50 -audio-rate=400` (50 ms before each audio response, 400 KB/s per connection, about three times the stream's bitrate) and `TIDALFAST_AUDIO_WINDOW_KB=512`, seven seeks each:

| file | latencies |
|---|---|
| with SEEKTABLE | 25, 62, 101, 109, 113, 142, 278 ms |
| without | 12, 101, 103, 105, 108, 142, 311 ms |

After the callback stopped waking the decode thread, the same setup with SEEKTABLE gave 9, 96, 102, 102, 122, 132 and 300 ms.

The slowest in both is a seek to 18.7 s in a 20 s track, which needed a second probe. With the default window (8 MB then, 3 MB now) the whole mock track is already downloaded, and a seek took 9 ms. Seven seeks into the first album track while it downloads at 400 KB/s, six of them past what had arrived, took 105 to 142 ms with the 3 MB window and 101 to 140 ms with 8 MB, and the one inside the window 10 ms with either. Allowing up to 1 s before the target instead of 0.3 s made seeks that landed far from a seekpoint take 380 to 400 ms, since that second had to download and decode before being thrown away. The player logs each seek's latency to stderr.

### Media keys and Now Playing

`MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are Obj-C classes, and Odin dev-2026-10 crashes compiling Obj-C method calls, so both live in `shell/shell.m`. The shell enables play, pause, toggle, next, previous and `changePlaybackPosition`, and turns each command into an `EVENT_MEDIA` event: `key_code` is the `Media_Command`, `dx` the position for a seek. The app handles them in `playback_update`, the same way as the player bar's buttons.

The app calls `Shell.set_now_playing` with the title, artist, album, duration, elapsed time, state and the cover as RGBA pixels, which an `Artwork` job fetches at 640x640. It calls it only when one of those changes, since macOS moves the elapsed time along by itself from the playback rate. The shell copies everything before it returns and rebuilds the artwork only when `artwork_key` changes. Now Playing came with platform ABI version 2; text input and accessibility made it version 3 (see Text input). Every struct the two sides share has a size check on both sides.

### Hot reload

The callback, the decode thread and the fetch threads all run dylib code. `unload` destroys the player: it stops and closes the device, joins the threads and frees the decoders. In bit-perfect mode that also puts the device back to the rate and format it had and releases hog mode, so a reload never leaves it changed with nobody to restore it. `reload` makes a new player and plays the same tracks from where they were, or from a seek's target if the seek hadn't landed yet; their URLs, and a DASH track's segment URLs, live in heap memory, not in the dylib. So a reload leaves a short silence, and the next track's download starts over. Moving the callback into the shell would avoid the silence, but the shell would need its own ring and its own marks and positions, and decoding would still stop for the reload. A short silence while developing costs less. Two reloads during playback, one right after a gapless track change, resumed at the right position.

### DASH and fMP4

A DASH slot's stream fetches URL 0, the initialization segment, then the media segments in order, each with a plain GET (and a `Range` to resume one the server cut short). Offsets count from 0 at the segment the stream last started from; it can't seek by byte, only start again at a segment (`stream_restart_segment`).

`src/audio/fmp4.odin` parses what's in it. The initialization segment's `moov` box leads to `trak/mdia/minf/stbl/stsd`, whose `fLaC` sample entry holds a `dfLa` box: FLAC's metadata blocks as they'd follow `fLaC` in a file. `parse_mp4_init` returns `"fLaC"` plus those blocks, the last one flagged last, and `mdhd`'s timescale, the track id and `trex`'s defaults. Each media segment is an optional `styp`, a `moof` and an `mdat`. `parse_mp4_moof` reads `tfhd` (track, default sample size, base offset), `tfdt` (the fragment's first sample in the track's timescale) and every `trun`'s sample sizes and data offset, which can carry on from the previous `trun`. A FLAC sample is one FLAC frame.

Data offsets count from the base ISO 14496-12 gives the `traf`: an explicit `base_data_offset` counts from the first byte of the segment file, which the stream records for each segment as it fetches them (`stream_segment_start`); `default-base-is-moof`, or neither flag in the first `traf`, counts from the `moof`. A later `traf` with neither flag would start where the previous `traf`'s data ended, which needs the other tracks' sample sizes, so it's refused with an error that says so.

Segments come from the network, so nothing in a `moof` is trusted. The demuxer reads the header of the `mdat` after each `moof` before parsing it, and every sample must lie inside that `mdat`. A `trun`'s count is checked against its own table and, when the sizes come from defaults, against what's left of the `mdat` (`count * default_size`), all before anything is appended. One fragment holds at most 65,536 samples (a 4 s segment of 192 kHz FLAC has about 190). Box sizes are checked against what holds them, 64-bit sizes above `max(i64)` are refused, and an `mdat` that runs to the end of the segment (size 0) after a `moof` is refused rather than guessed at. A broken box fails the track with the reason in the player bar. `tests/hires_test.odin` checks all of this on hand-made boxes and on 20,000 randomly damaged ones.

The decoder sees the same thing as for a FLAC file: `fLaC` and the metadata blocks (with the sample count zeroed, as for a seek), then frames. The demuxer behind it (`demux_read`) walks the boxes in order, reads each `moof`, then copies its samples out of the `mdat` that follows, and skips any other box. dr_flac decodes 24-bit samples to `v / 2^23` in float, which a 32-bit float holds exactly, so nothing on the way changes a bit.

A seek finds the segment whose start is at or before the target (`dash_segment_index`, a binary search over the timeline's starts converted to samples), starts the stream again at it, decodes from its first frame and drops the frames before the target. The first `moof`'s `tfdt` then says exactly which sample its first frame is, and that, not the MPD's arithmetic, sets how many to drop. A DASH seek always costs one segment request.

### Bit-perfect output

Off, miniaudio plays at the track's rate into an AudioUnit, and CoreAudio converts to whatever rate the device runs at and mixes with other apps. On, `src/audio/coreaudio.odin` takes the device itself through the CoreAudio HAL, which is a C API (`AudioObjectGetPropertyData`, `AudioObjectSetPropertyData`, `AudioDeviceCreateIOProcID`, `AudioDeviceStart`), declared by hand in Odin:

1. At the first track, it remembers the device's nominal rate and its output stream's physical format, to restore them.
2. With hog mode on, it takes `kAudioDevicePropertyHogMode`. Setting that property toggles it, whatever the value, so it's set only when nobody holds it and released only when this process does.
3. If `kAudioDevicePropertyAvailableNominalSampleRates` has the track's rate, it sets `kAudioDevicePropertyNominalSampleRate`, and a physical format (`kAudioStreamPropertyPhysicalFormat`) at that rate with the track's channels that holds every bit of the track: signed integers of exactly the track's bit depth if the device has them, then the smallest integer depth above it, then 32-bit float, which holds up to 24 bits exactly. A device with only 16-bit formats has nothing for a 24-bit track. It then polls every 2 ms on the decode thread, for at most 2 s, until the device reports the rate, that physical format, and a 32-bit float virtual format at the rate.
4. An IOProc fills the device's buffers from the ring (`hal_fill`). Each buffer is checked: one without data is skipped, frames come from the buffer that holds the fewest so every channel gets the same ones, and whatever is left of a buffer, frames the ring didn't have or bytes past the last whole frame, is zeroed. Mono and stereo go on the device's preferred stereo pair (`kAudioDevicePropertyPreferredChannelsForStereo`, read when the device opens), mono on both, and other device channels are silent. One interleaved buffer that already has the ring's layout is written in place; anything else, such as one buffer per channel, goes through a scratch buffer. It keeps the callback's rules: no locks, allocation, logging or system calls.

ReplayGain and the volume slider are skipped: the decode thread doesn't multiply, and the IOProc copies with a gain of exactly 1. No dither, no conversion. The IOProc sees the virtual format, 32-bit float, and the HAL converts that to the physical format. A float holding `v / 2^23` converts to the 24-bit integer `v` exactly, and the same for 16 bits. If any step above fails (a 192 kHz track on speakers that stop at 96, no format deep enough, a format or rate the device refuses or doesn't report back), the device is put back as it was and miniaudio plays that track, converted, with no ReplayGain. The Output menu then says "Not bit-perfect" and why, such as "no 24-bit format at 96 kHz".

The device it uses is the default output when the first track opens it, and it stays that device until the output is restored. While this app hogs it, it's no longer the system's default, so asking again would find another device.

The device gets its rate, format and hog mode back when bit-perfect output is turned off, on a hot reload and when the app quits (`app_shutdown`). The shell turns SIGTERM, SIGINT (Ctrl-C in the terminal) and SIGHUP (the terminal closing) into a normal quit on the main queue, so they reach `app_shutdown` too. Between tracks it isn't restored, only switched.

SIGKILL and a crash can't be caught. macOS releases hog mode with the process, but the nominal rate and physical format stay where the last track set them. So while a device is switched, the settings file also holds a `device_change` record: the device's UID, the rate and physical format it had, and the rate the app set. The decode thread publishes it in the player's status and the app saves it as soon as it changes. On a normal quit it goes away. At the next start, if the record is there, the device with that UID still runs at the rate the app set and nobody has changed it since, the app puts the old rate and format back before anything plays, then drops the record. The record is written a frame or so after the switch, so a crash in that window leaves nothing to restore from.

The decode thread also watches the device. A listener on its `kAudioDevicePropertyDeviceIsAlive` and one on the system's default output only note what changed and wake the decode thread. CoreAudio may still be running a listener after `AudioObjectRemovePropertyListener` returns, so a listener touches only the player's `Device_Watch`: the flags it sets and the semaphore it posts both live there, and the decode thread sleeps on that semaphore. The watch is never freed. After the player is destroyed nobody waits on it, and a late post does nothing. When the device has gone, as when a USB DAC is unplugged mid-track, the decode thread stops and destroys the dead output without trying to restore anything on it, and plays on from the audible position on whatever is now the default output. If nothing can open, the track fails and the player bar says so. When the default output moves to another device while this one isn't hogged, the device is put back and the track moves to the new default the same way. A hogged device stops being the default, so the default moving then is no reason to leave. miniaudio follows the default output by itself.

Gapless still works at the same rate: the ring doesn't care. A rate change lets the ring play out, stops the IOProc, sets the new rate and starts it again. The player logs the time from the last IOProc call with the old track's frames to the first with the new one's.

### Output settings

The player bar has an "Output" button, left of the volume. In bit-perfect mode it says "Bit-perfect", or the format the device plays, such as `24/96`, in green. It opens a menu with "Bit-perfect output" and, when that's on, "Hog mode", and a line saying what reaches the device. A change goes to the player at once: it closes the device (restoring it) and plays on from the audible position through the new output, since the ring's frames went through the old one's gain. The settings go in `~/Library/Application Support/tidalfast/settings.json` (`{"bit_perfect": true, "hog": false}`, plus `device_change` while a device is switched, see above) and are read when the app starts. Hog mode only counts with bit-perfect output.

Saving goes through `settings_queue`: it makes the settings the newest, with a generation number, and has a worker save them. A save holds a mutex for the whole write, reads the newest settings when it starts, and skips the write if the file already has that generation. So with four workers there's still one write at a time, older settings never land after newer ones, and a burst of clicks makes few writes. Each write goes to a temp file of its own name, which is synced and renamed over the file. The path the workers use is Data's own copy, freed only after the workers have stopped.

### Checking hi-res and bit-perfect output

`tests/bitperfect_check` reads a capture and the integer WAVs the tracks were made from, finds each track in the capture, compares every sample's bits and reports the silence between tracks. Against the mock's hi-res album on a MacBook Air's built-in speakers:

```
./build/mock_tidal -port=8787 -hires-only
echo '{"bit_perfect": true, "hog": true}' > /tmp/settings.json
TIDALFAST_API=http://127.0.0.1:8787 TIDALFAST_KEYCHAIN=tidalfast-p6-test \
    TIDALFAST_PKCE_REDIRECT='http://127.0.0.1:8787/android/login/auth?code=mock-pkce-code-1' \
    TIDALFAST_SETTINGS=/tmp/settings.json TIDALFAST_AUDIO_CAPTURE=/tmp/cap.wav \
    TIDALFAST_REMOTE_TEST=8:play ./build/tidalfast       # Ctrl-C after about 40 s
odin run tests/bitperfect_check -- /tmp/cap.wav /tmp/tidalfast-mock-audio/hires-{a,b,c}-source.wav
security delete-generic-password -s tidalfast-p6-test
```

After the review fixes the same run gave 0 samples different in all three tracks, the 96 to 96 kHz change gapless again, and 480 frames between the 44.1 and 96 kHz tracks. Ctrl-C (SIGINT) after the album put the speakers back to 48 kHz and 32-bit float and released hog mode, and the settings file lost its `device_change`. A run killed with SIGKILL during the 24/96 track left the speakers at 96 kHz with hog mode released and the record on disk; the next start put them back to 48 kHz before anything played and dropped the record. Paused, the app's CPU time didn't move in 10 s.

What it showed:

- The speakers offer 44.1, 48, 88.2 and 96 kHz, all as 2-channel 32-bit float only, and ran at 48 kHz before. A second process reading `kAudioDevicePropertyNominalSampleRate` every 2 ms saw 48000, then 44100 when the 16/44.1 track started, 96000 when the first 24/96 track started, and 48000 again when the app quit, with hog mode held by the app's pid from the first track to the quit and released after.
- All three tracks reached the IOProc unchanged: 352,800 frames of 16/44.1, then 960,000 and 576,000 frames of 24/96, 0 samples different, in runs with hog mode off and on, and with a pause in the middle.
- 44.1 to 96 kHz: 36 to 40 ms from the IOProc's last call with 44.1 kHz frames to its first with 96 kHz ones, of which setting the rate took 10 to 15 ms. The 96 to 96 kHz change between the two hi-res tracks was gapless: no frame between them.
- A hot reload (`./build.sh app`) during the 24/96 track with hog mode on put the speakers back to 48 kHz, then the new player took them back to 96 kHz with hog mode and played on. Quitting restored 48 kHz.
- Paused, the app used no CPU: its CPU time didn't move in 10 s.

`tests/hires_test.odin` checks the parts without a device: the MPD's timeline with repeat counts and jumps, the `moov`/`dfLa`/`moof`/`trun` parsing (64-bit box sizes, default sizes, `trun`s without a data offset), 24-bit samples through fMP4 and dr_flac with no bit changed, segment lookup for seeks, a DASH track played by the player on the null device in bit-perfect mode with every sample exact and a seek into the second segment starting exactly at its target, turning bit-perfect on mid-track, the PKCE redirect parsing and exchange against the test mock, the Keychain's client id, and the settings file. Since the review it also checks `moof` bounds on hand-made and randomly damaged boxes, both base offset rules and a DASH track with an explicit `base_data_offset` played bit for bit, `hal_fill` against buffer lists of several shapes, the choice of a physical format deep enough, the Output menu's reason, a simulated device loss (`audio.simulate_device_loss`, test builds only), four threads saving settings at once while another reads the file, and the settings path outliving `playback_shutdown`. `tests/login_test.odin` checks that a superseded device login is dropped and that a PKCE login retries with its tokens, before and after a reload. `tests/android_login_test.odin` checks the address validation, the login screen's states (PKCE first, a bad address, a good one, a failed exchange, the switch to a code), a `Login_Pkce` the full queue refused going out again, the AAC notice for a device-client login and logging in again over it, the AAC line in the player bar, the quality fallback against the test mock, a device code that arrives after the switch to the PKCE login, a next track that fails to resolve being asked for once and not again until it's current, and that hostile error bodies (a signed URL in `userMessage`, `errors[].detail`, a non-JSON body, an anti-abuse 403 and a manifest's codec) never reach the app's stream error line or what `src/tidal` logs.

Against `tests/mock_tidal -hires-only`, a device login made with "Log in with a code instead" (through `TIDALFAST_SHELL_TEST`'s `ax-press`) showed the AAC notice, and play put the AAC line in the player bar, with the `Lossy_Stream` line on stderr. Started again with that login in the Keychain, the notice was there from the start. A PKCE login through `TIDALFAST_PKCE_REDIRECT` played the album: 16/44.1 BTS, then both 24/96 tracks as DASH. With `-refuse-hires -lossless-dash` each track logged the 403 and played as `LOSSLESS` FLAC in DASH.

Not checked here, for want of an account or a DAC:

- That TIDAL still gives the Android client hi-res, and the real MPDs and segments. The MPD parser follows the shape of the TIDAL manifest in `tests/tidal_test.odin`, and a `ContentProtection` or `mp4a` answer is refused rather than played.
- A device with integer physical formats: picking a 24-bit integer format for a 24-bit track, and falling back with "Not bit-perfect" on a 16-bit-only device, are written and tested only against made-up format lists, since the built-in speakers are float only. So is anything above 96 kHz. A device with more than one output buffer or more channels than the track is tested only with made-up buffer lists.
- Unplugging a DAC mid-track and the default output changing: the listeners are registered against the real HAL, but the handling is tested only through `simulate_device_loss`, since this machine has no second output to switch to.
- What a USB DAC does while it re-clocks (some click or mute for longer), and how long it takes.
- Another app holding hog mode.

### Without an account

- The mock's first three liked tracks are a live album: three FLAC files cut from one continuous sine sweep with a little noise, at lengths that aren't whole FLAC frames, with an album gain of -6.02 dB and different track gains. Every other track plays one of four tones. The mock makes them at start as WAV, encodes them with `afconvert -f flac -d flac`, and adds a SEEKTABLE with a point every 2 s and a PADDING block, which afconvert leaves out. It serves the files with `Range` support.
- `TIDALFAST_FAKE=1` plays a 30-second sine tone for each fake row, so the player bar, queue, seeking and Now Playing work without any server.

To check gapless playback, play the album through with `TIDALFAST_AUDIO_CAPTURE` and compare the capture with the sweep:

```
./build/mock_tidal -port=8787
TIDALFAST_API=http://127.0.0.1:8787 TIDALFAST_KEYCHAIN=tidalfast-gapless-test \
    TIDALFAST_PKCE_REDIRECT='http://127.0.0.1:8787/android/login/auth?code=mock-pkce-code-1' \
    TIDALFAST_AUDIO_NULL=1 TIDALFAST_AUDIO_CAPTURE=/tmp/cap.wav \
    TIDALFAST_REMOTE_TEST=8:play ./build/tidalfast     # quit after about 60 s
security delete-generic-password -s tidalfast-gapless-test
odin run tests/audio_check -o:speed -- /tmp/cap.wav /tmp/tidalfast-mock-audio/album-source.wav 883234 1633711
```

`audio_check` finds where the sweep starts in the capture, fits the gain, and compares every frame after the first buffer's volume ramp with the source times that gain. A gap, a repeated or dropped frame, or a gain change at a track boundary fails it. The numbers after the files are the boundaries' source frames, which it reports on. It passes: 2,163,136 frames (49.05 s) across both boundaries, 0 samples off, a largest error of 6.3e-9 (float rounding), at x0.1715, which is the album gain of x0.5 times the default volume of 0.7 cubed.

`tests/player_test.odin` sends media commands through `playback_update` with the fake data on the null device, and checks the queue, the player's position after a seek, and what goes to Now Playing. It also checks that a new list's row doesn't take the old list's preloaded track that the toggle starts playback from idle and after the end, and that a seek still pending when the track changes or the app reloads doesn't pin the player bar. `tests/audio_test.odin` checks on the null device that `play` drops a pending seek, that `status` never pairs a mark with another mark's position, that the callback never posts the decode thread's semaphore, and that a listener still running after its player is destroyed touches nothing the player owned.

### CPU

Apple M1, the mock album playing to the null device: 1.5% with an optimized dylib and about 4% with a debug one, mostly the four UI frames a second for the progress bar. Paused, the device is stopped and the decode thread sleeps on its semaphore: 0.0%.

Measured again after the callback stopped waking the decode thread, with CPU time from `ps`: the fake tones with an optimized dylib use 0.20 s in 15 s of playing (1.3%), and nothing in 7 s idle before playing or 20 s paused. The mock album with a debug dylib uses 2.3 to 3.6%, and nothing in 20 s paused once the next track's download has filled its window.

## Text input

### The text field

`ui.text_field(id, &field, placeholder, width, height)` is a single-line text field. Its state is a `ui.Text_Field` the app keeps: up to 256 bytes of UTF-8 in a fixed buffer, the cursor and the selection's anchor, the input method's marked text and the undo stacks. It's plain data, so it survives a hot reload, and `edit.odin` holds the editing on its own, which the tests drive without a window.

Every offset is a byte offset on a grapheme cluster boundary. The boundaries come from `text.grapheme_starts`, the same segmentation the renderer uses, so Backspace removes a whole 가, a whole jamo syllable, a ZWJ family or a flag with its two regional indicators, and an Arabic letter with its marks. The one exception is a replacement range from the input method, which the field takes by codepoint as the shell's mirror does (see below), so an input method that replaces part of a cluster leaves the cursor inside it. kb_text_shape broke before the last pictograph of a ZWJ sequence (👨‍👩‍ and 👧), so `grapheme_starts` now joins them as rule GB11 says, which fixes truncation of such titles too.

With the focus, the field takes:

- Left and Right by cluster, Option by word, Command to either end, and Up, Down, Home and End to either end. Shift extends the selection. Word movement skips separators, then goes over letters and digits.
- Backspace and Delete by cluster, Option by word, Command to the end of the line.
- Cmd-A, Cmd-C, Cmd-X, Cmd-V, Cmd-Z and Shift-Cmd-Z, Control-A and Control-E.
- Clicks: one places the cursor (Shift extends), two select a word, three select everything, and dragging selects by cluster, or by word after a double-click.
- Return reports `submitted`. Escape clears the text, and a second Escape gives up the focus.

Undo keeps whole snapshots, 32 deep. Typing right after typing joins one step, and so do Backspaces in a row and Deletes in a row. Moving the cursor or clicking ends the step, and cut, paste and word or line deletes are steps of their own. A composition belongs to the step of the typing before it.

Pasted and typed text becomes one line: a run of line breaks and tabs (LF, CR, tab, NEL, U+2028, U+2029) becomes one space, or none at the start of the text, and the other C0 and C1 controls, DEL, U+FFFD and invalid UTF-8 go. A paste that doesn't fit is cut at a cluster boundary. Text from the input method that doesn't fit goes in whole or not at all.

Keys, text and focus changes reach the field in the order they came, even within one frame. Text typed before a Tab goes in, though the field has lost the focus by the time it's built. After Escape gives up the focus, the frame's text goes nowhere unless something gives the focus back. `ui.focus_shortcut(box, key, modifiers)` makes a key give a field the focus with its text selected, at its place among the events, so Cmd-F followed by typing in the same frame replaces the text. `Field_Signal.submitted_text` is the text when Return was pressed.

The field draws its insides as floating boxes: the selection, the text moved left by `scroll` to keep the caret in view, the marked text's underline (thin under the composition, thick under the clause the input method has selected) and the caret. Positions come from the shaped run. Each cluster's left and right edge is the extent of its glyphs. A cluster without a glyph of its own, as inside a ligature, shares the one before it. A cluster reads right to left when the next cluster sits to its left. The caret goes on a cluster's leading edge, so mixed Arabic and Latin text draws with bidi while the cursor moves in logical order.

The caret blinks every 0.53 s through `ui.wake_at`, only while the window has the keyboard (`Frame_Input.key_window`). Without the keyboard it's hidden and asks for no frames.

### Keys, text and the input method

While a text field has the focus, the UI keeps Return, Space, the arrows and Escape for it instead of clicking or moving the focus. Tab still moves the focus.

The shell's view is an `NSTextInputClient`. After each frame the app tells the shell about the focused field through `Shell.set_text_input`: its text, selection and marked range in bytes, and a rect for the marked text or the caret, or nil when no field has the focus. It sends changes, and it also sends the state after the field takes text or marked text from the shell, even if nothing changed. While a field has the focus, `keyDown` goes through the view's input context:

- Text it inserts (`insertText`) reaches the app as a `Text` event, and the key doesn't.
- Marked text (`setMarkedText`, `unmarkText`) reaches it as `Marked_Text` and `Unmark_Text` events, and the key doesn't. While there is marked text every key belongs to the input method.
- Keys it turns into commands (arrows, Delete, Return, Escape, Tab) reach the app as key events, which the field handles. So do Command shortcuts, which skip the input context.

Event text lives in a byte buffer that comes with the frame's events (`Frame_Input.text`). A text event carries an offset and length into it, and an optional replacement range in bytes, as when the accent menu replaces the letter typed before it.

Input methods ask questions synchronously, often right after `setMarkedText` and before the app has had a frame. So the shell keeps a mirror of the field, applies every edit it sends on to the mirror too, and answers `selectedRange`, `markedRange`, `hasMarkedText` and `attributedSubstringForProposedRange` from it. It converts between the app's UTF-8 bytes and AppKit's UTF-16 units and never lands between a surrogate pair's halves. The mirror and the field have to make the same edit, but Cocoa's composed character sequences and the app's grapheme clusters differ, so they use rules that need no segmentation:

- Text is cleaned byte for byte the same way: `field_sanitize` in the shell, `sanitize` in `src/ui/edit.odin`. Both decode UTF-8 the way Odin's `utf8.decode_rune` does, dropping an invalid sequence a byte at a time. `test_edit_sanitize_table` holds the outputs the shell printed for the same inputs (`clean=` below).
- A replacement range is clamped to the text and each end moved back to the start of its codepoint. The input method's selection inside marked text is clamped to the cleaned text and moved back the same way.
- If the cleaned text doesn't fit the limit (`Text_Input.limit`, in bytes) in place of the range, the whole edit is refused. A refused `setMarkedText` changes nothing. A refused `insertText` ends the composition as it was, as `unmarkText` does.

So with the search field at 115 of 119 bytes, marking "a‍👩" (8 bytes) changes neither, and a commit after it goes where the caret was. The app's next state replaces the mirror after every edit anyway. `firstRectForCharacterRange` returns the marked text's rect in screen coordinates, so the candidate window opens under the composition. When the app ends a composition itself, as when the field loses the focus, the shell calls `discardMarkedText` so the input method forgets it.

The clipboard goes through `Shell.set_clipboard` and `Shell.get_clipboard`, which use `NSPasteboard`. `ui.copy_to_clipboard` puts a string on it from anywhere in the UI.

### Platform ABI version 3

- `Event` grew to 88 bytes: text offset and length, a replacement range, the input method's selection inside marked text, and a `target` node id. New kinds: `Text`, `Marked_Text`, `Unmark_Text`, `Access_Press` and `Access_Focus`.
- `Frame_Input` (48 bytes) carries the text buffer and whether the window is key.
- `Frame_Result` (8 bytes) has `wake_after`.
- `Shell` (64 bytes) adds `set_text_input`, `set_clipboard`, `get_clipboard` and `set_accessibility`.
- New structs: `Text_Input` (48 bytes) and `Access_Node` (56 bytes). `Text_Input.limit` took the place of a padding field, so a shell or app that leaves it 0 means no limit, and the version stays 3.

## Search

The search field sits at the top of the sidebar. Cmd-F or Cmd-L focuses it with its text selected, and text typed after it in the same frame replaces the text.

Every edit raises the query generation and throws out queued Search jobs. Once typing has stopped for 250 ms (`SEARCH_DEBOUNCE`, a `ui.wake_at`, not a running timer), a `Search` job asks TIDAL's `search` for songs, albums, artists and playlists in one request, 50 of each. Nothing goes while the input method still has marked text, so composing にほんご doesn't search for each kana. Return searches at once, for the text it was pressed on: an edit after it in the same frame starts the debounce over, as it would in the next frame. A result whose generation isn't the latest is dropped, and the auth generation drops results from a login that has ended, as for every job. The app logs each query it sends and what came back.

The songs become the open track list, a `Track_View` with source `.Search`. So covers, double-click to play, the queue, the playing row and Enter work as in a playlist, and more songs load as `Tracks` jobs that page through `search` with only tracks, up to TIDAL's 300. The old results stay on screen until the new ones arrive. Tabs above the table switch to the albums, artists and playlists found, shown as rows. A click opens an album's tracks (`albums/{id}/tracks`), an artist's top tracks (`artists/{id}/toptracks`) or a playlist, each as a track list of its own. Picking a sidebar entry goes back to it. Clearing the field, by deleting the text or with Escape, closes the search and opens the sidebar's playlist again if the results were showing.

Opening any list, from the sidebar, the tabs or the track menu, ends a search that's still waiting for its debounce or its answer. The generation goes up and the queued Search job goes, so the answer can't bring the results back over the list. The text stays in the field, and Return searches for it again.

The track menu's Go to album and Go to artist open the same lists, from the row's album and first artist ids. The menu offers them only when the row has those ids. Copy song link puts `https://tidal.com/browse/track/<id>` on the clipboard. The menu belongs to the list and the track it was opened on: when another list replaces that list (a search result, a sidebar entry, an album), or the row holds another track, the menu closes and its actions do nothing. Add to queue is gone from the menu until the player has a queue API to call.

With `TIDALFAST_FAKE=1` the search runs over the 10,000 fake rows on the UI thread. It matches title, artist or album, ignoring case, and its albums and artists are the distinct albums and artists of the matching songs, up to 50 of each. "Jóga" matches 145 songs by title, from 26 albums and 34 artists. Going to an album or artist lists the fake rows with that name.

## Accessibility

Boxes say what assistive apps should see with `ui.accessible(box, role, label, value)`. `ui.button`, menus and menu items do it themselves. `end_frame` walks the tree after layout and flattens every box with a role into a list of `Access_Node`s, parents first, with their clipped rects, focus and selection. A box clipped away, and everything inside a clipping box clipped away, stays out, so the virtualized track table only ever gives the rows in view. Keyed boxes use their key as the node id. The rest get one from their parent's id and their place among its nodes, which stays put while the tree does. The app hashes the list and calls `Shell.set_accessibility` only when the hash changes.

What's exposed: the search field (`AXTextField` with the text as its value), the sidebar (`AXList` of `AXRow`s), the track table (`AXTable` whose `AXRow`s are labelled "title, artist, album" and hold one `AXStaticText` each, and the "More options for title" button that opens the track menu, on the selected row), the search tabs and the found lists, the headings and status line, the player bar's buttons and its two sliders with their values, the login screen's buttons, and context menus.

The shell copies the nodes. It makes `NSAccessibilityElement`s from them only once an assistive app has asked the view for its children or hit-tested it, and after every change from then on. So without VoiceOver running a changed tree costs one copy. Elements are kept by node id, so VoiceOver stays on an element while it moves or changes, and frames are turned into screen coordinates when asked for. After a change the shell posts a layout change, a focus change when the focused node is a new one, and a value change for a focused text field. AXPress on a button, row or menu item comes to the app as an `Access_Press` event, which the UI treats as a keyboard click: buttons click, sidebar rows open their playlist and track rows play. Setting the focus comes as `Access_Focus`.

### Checking it

There is no human or VoiceOver in the loop here, so the checks run the shell's own entry points:

```
./build/mock_tidal -port=8787
TIDALFAST_API=http://127.0.0.1:8787 TIDALFAST_KEYCHAIN=tidalfast-p7-test TIDALFAST_AUDIO_NULL=1 \
    TIDALFAST_CAPTURE=/tmp/cap.tga \
    TIDALFAST_SHELL_TEST="10:key=cmd+f;10.5:mark=にほんご;11.2:ime;11.3:capture=/tmp/marked.tga;12:commit=日本語;14:capture=/tmp/results.tga;14.5:ax-dump;15:ax-press=日本語 1,;16.5:quit" \
    ./build/tidalfast
security delete-generic-password -s tidalfast-p7-test
```

The mock approves the login after about 3 s. `ime` printed `text "にほんご", marked {0, 4}, selected {4, 0}` and a rect under the field. After the commit the app logged `search: "日本語"`, the mock answered 50 of 120 tracks, and the second page came as a tracks-only search at offset 50. `ax-dump` listed the `AXTextField` with the value 日本語, the playlists list, the search tabs as buttons, the table with seven rows of title, artist and album, and the player's Previous, Play and Next buttons. `ax-press` on the first row played it.

An `AXUIElementCreateApplication` walk from another process needs the Accessibility permission, which the environment this was built in doesn't grant (`AXIsProcessTrusted` returns false). `ax-dump` reads the tree in process instead, from the window down through AppKit's NSAccessibility calls, the same path an assistive app's requests take.

## Hot reload

Run `./build/tidalfast`, edit something in `src/`, then run `./build.sh app`. The running window picks up the change.

The shell watches `build/` with FSEvents. `build.sh` writes the dylib to a temp name and renames it into place, so the shell never sees a half-written file. When `app.dylib` changes, the shell copies it to a unique temp path and `dlopen`s the copy, which leaves the linker free to overwrite the original. Release builds have no watcher and open `app.dylib` in place: macOS checks the signature of a file it hasn't seen on every `dlopen`, so a fresh copy took about 100 ms to open at each launch, against under 10 ms for the same file again. If the new dylib's ABI version matches, the shell calls `unload` on the old app and `reload` on the new one, then redraws. The old dylib stays open. A dylib that fails to load is skipped and the old one keeps running. If the shaders in the new dylib don't compile, the app logs the error and keeps drawing with the previous pipeline.

The app keeps its state in memory the shell allocates once: a persistent block and a frame block. `State` sits at the start of the persistent block, and the rest is an arena. The frame arena is `context.temp_allocator` and resets every frame. A reload doesn't touch either block, so state carries over. The persistent arena never zeroes what it hands out: it only moves forward through pages nobody has written, since resetting `State` maps fresh zero pages over the whole block. Zeroing touched every page of the 23 MB of caches made at start (the shaper's 8 MB, the glyph pool, the box table), most of which are never written, and made them count against the app's memory.

What the app may keep across a reload:

- Plain data in `State` and in the persistent arena.
- Obj-C object pointers such as the Metal device, queue and layer. The Obj-C runtime owns them, not the dylib.
- `State_Header.release`, and the shell's `request_redraw` that the text loader keeps. See below.

What it may not keep:

- Odin globals. Each loaded copy has its own.
- Other procedure pointers, including `mem.Allocator` values and `[dynamic]` arrays and maps, which hold an allocator. Each entry point rebuilds the allocators from the arenas.
- Running threads. The text loader thread, the data workers and the audio player's threads run dylib code, so `unload` joins them and `reload` starts new ones. The audio callback is dylib code too, so the device stops for a reload; see Playback.
- Anything the dylib's own runtime allocated, such as the `os.File` behind the spall trace. The app keeps only the file descriptor.
- Data whose layout changed. Bump `STATE_VERSION` when a field changes type or moves and the size happens to stay the same.

`State` starts with `State_Header`: a magic number, the version, the size, and `release`, which frees everything that `State` owns (the Metal queue, pipeline, textures, instance buffers and in-flight command buffers, the text system's CF objects and mapped font files, and the spall file). Every version of the app sets `release` to its own `app_shutdown` on init and on reload. When a new dylib finds a different version or size, it can't read the old `State`, but it can read the header, so it calls `release` and runs the old code against the old layout before it resets `State`. Never change `State_Header`: it's how one version finds another's cleanup.

The magic number (`STATE_MAGIC`, "TFSTATE1") came with the text phase. Builds before it had a header without one, or none at all, and in those the bytes where `release` sits now can be an arena pointer: calling it crashed the shell with SIGBUS. So when the magic doesn't match, the app trusts nothing in the old `State`. It logs that, resets without calling anything, and leaks what the old state held.

That only works because the shell never closes an old dylib, so the old `release` stays callable. macOS wouldn't unmap an Odin dylib anyway, since it uses thread-local storage. Each reload leaks one image, which is fine for a dev session.

## Redraw policy

The shell draws only when something asks for a frame: input, a resize, a reload, or `request_redraw` from any thread. `request_redraw` sets a flag and calls `CFRunLoopWakeUp`. A run loop observer draws just before the main thread sleeps, so a burst of events becomes one frame.

A frame can also ask for a frame later without animating: `Frame_Result.wake_after` is how many seconds from now, and the shell arms a one-shot run loop timer that calls `request_redraw`. The caret's blink and the search's debounce use it, through `ui.wake_at`, so a focused text field draws twice a second instead of every vsync.

If the app returns `animating = true`, the view's `CADisplayLink` adds a frame every vsync until the app returns false. The shell pauses the link while the window is minimized or fully covered, so a hidden animation costs no CPU. An idle window uses no CPU.

While the link runs, a pending redraw waits for the next tick instead of drawing straight away. Drawing between ticks would present more than once per refresh, and with sustained input that runs out of drawables and blocks the main thread in `nextDrawable`. The wait has a limit: if no tick arrives within two refresh intervals of the last one, as when the display sleeps, a timer wakes the run loop and the observer draws directly. The same happens at once when the link is paused. So explicit redraws still happen while the window is hidden or the display is off. Resizes are the exception and always draw synchronously, so the window never shows a stretched frame.

The layer keeps three drawables while the link runs and two while it's paused. Each is the window's size in pixels, about 12 MB at 1100x700 points on a 2x display. Frames drawn on demand need only two, one on screen and one being drawn. The layer lets go of the third in its next `nextDrawable`, so when the count drops the shell asks for one more frame, and an idle window holds 12 MB less. Frames on every tick need three. With two drawables all the time, one library bench run in five locked into waiting most of a refresh in `nextDrawable` on every frame: frame times averaged 16.5 ms instead of 1.5 to 2.1 ms, though the UI took the same 1 to 2 ms to build them. With three while the link runs, none of six runs did.

The shell merges mouse moves, and scroll events in the same phase, into one event with the summed delta. Phase changes such as a gesture beginning or ending keep their own event. The queue grows as needed and never drops an event, so the app never misses a button or key release.

## Measuring RAM and startup

```
./build.sh measure
./build/measure/measure startup     # 10 cold launches with the fake data, then 10 against the mock
./build/measure/measure memory      # the memory scenario, once with each
./build/measure/measure all         # both
./build/measure/measure compare docs/measure-baseline.json build/measure/20261015-114141.json
```

`./build.sh measure` builds an optimized app in `build/measure/app` (its own shell and dylib, hot reload off), `tests/mock_tidal` and the tool. The app is the release build plus `TIDALFAST_MOCK_API`, which lets it read `TIDALFAST_API` and `TIDALFAST_PKCE_REDIRECT`. The real release build never reads them (see TIDAL data), so it can't run against the mock.

Each run is a cold launch with `TIDALFAST_MEASURE` set, `TIDALFAST_AUDIO_NULL=1` and a settings file of its own, so bit-perfect output is off and your settings stay as they are. Other `TIDALFAST_` variables in your environment are dropped. The tool prints a table per scenario and setup, writes `build/measure/<time>.json`, and keeps each run's stderr in `build/measure/logs-<time>/`. Flags: `-runs=N`, `-setup=fake` or `mock` or `fake,mock`, `-app=path`, `-timeout=seconds` and `-out=path`.

The setups:

- `fake` runs with `TIDALFAST_FAKE=1`: no account, no network, 10,000 fake rows.
- `mock` starts its own `mock_tidal` on a free loopback port and logs in with `TIDALFAST_PKCE_REDIRECT` under a Keychain item called `tidalfast-measure-` and a random suffix. So the first run logs in and later runs read the login from the Keychain, as you would. The tool deletes the item at the end with `security delete-generic-password`. Deleting it from the tool itself fails with -25244, because the item's access list names the app.
- `-real` runs `build/tidalfast` against your own account and your `tidalfast` Keychain item. Build it with `./build.sh release` first. It's for you to run by hand: macOS may ask for Keychain access, and the memory scenario plays a track from your longest list to the null device.

`measure compare a.json b.json` prints every number in both files with its change. A time or size that changed by 10% and at least 1 ms or MB is marked `worse` or `better`. Startup times move a few percent from run to run, so compare medians from the same machine.

### What the app prints

With `TIDALFAST_MEASURE` set, the shell and the app print lines like these to stderr:

```
measure: {"mark":"main","ms":10.4}
measure: {"mark":"tracks","ms":312.1,"footprint":84210000,"resident":137700000,"gpu":32100000,...}
measure: {"sample":"scrolled","ms":31291.9,...,"fonts_mapped_bytes":630429612,"fonts_resident":31195136}
```

`ms` is milliseconds since the kernel started the process (`p_starttime` from `sysctl` `KERN_PROC_PID`), so time spent in dyld before `main` counts. The lines never hold tokens or addresses. `=1` prints the marks and nothing more. `=startup` quits once it reaches `tracks`. `=memory` runs the memory scenario and quits. The tool sets the mode.

The startup marks, in order:

| mark | what has happened |
|---|---|
| `main` | the shell's `main` started: dyld has loaded the executable and its frameworks |
| `launched` | `applicationDidFinishLaunching`: AppKit is set up |
| `dylib` | the app dylib is copied and opened |
| `init` | the app's `init` returned: renderer, shaders, Inter, caches, workers |
| `window` | the window is ordered front |
| `first_frame` | the first frame is committed and its drawable presented |
| `library` | the first frame with the sidebar's playlists (fake: the first frame) |
| `tracks` | the first frame with track rows and every cover on screen ready |

"Presented" means the app called `presentDrawable` and committed. The frame reaches the display a vsync or two later.

Samples carry the same memory numbers as the marks plus the mapped fonts. The memory scenario takes one after each of these stages:

1. `startup_idle`: the library is up and its covers are in, then 5 s with nothing happening.
2. `list_open`: the longest list is open with every row loaded: the mock's 3,000-track playlist, or the fake data's 10,000 rows. 3 s to settle.
3. `scrolled`: the bench's auto-scroll went through it (`TIDALFAST_BENCH=covers` on the mock: 600 rows one a frame, then 1,200 four a frame; the library bench on the fake data), covers loading as it went. 3 s to settle.
4. `playing`: 30 s after playback started on the first playable row.
5. `idle_after`: playback stopped, then 10 s, which shows what stays allocated.

Then it quits through SIGTERM, the same path as Ctrl-C, so shutdown runs.

### The numbers

- **footprint** is `phys_footprint` from `task_info(TASK_VM_INFO)`. It's what Activity Monitor's Memory column shows and what macOS counts against the app under memory pressure: dirty memory the app owns, compressed or swapped memory included. On Apple silicon it includes Metal's allocations, since the GPU uses the same RAM. So gpu is part of footprint, not on top of it.
- **resident** is the pages in RAM right now, clean ones included. That takes in the code of the app and every framework it touched, and mapped files. Pages of a mapped file that nobody wrote to are clean: the kernel can drop them and read them back from disk, so they count toward resident but not footprint.
- **gpu** is the Metal device's `currentAllocatedSize`: glyph atlas pages, cover pages, instance buffers, the drawables' textures.
- **fonts map** and **fonts res** are the fallback fonts the text loader mapped with `mmap`, and how much of them is resident (from `mincore`). Apple Color Emoji alone is 180 MB of file, but only the pages of glyphs drawn get read in. Those pages count toward resident and not footprint.
- The rest is the app's own accounting: `arena` (the persistent arena's used bytes), `frame_peak` (the frame arena's high-water mark), `atlas_pages`, `runs` (shaped runs in the text cache), `covers` and `cover_bytes` (the cover cache's entries and its pages' bytes), `rows` and `view_bytes` (the open list and its arena).

Measuring costs nothing with `TIDALFAST_MEASURE` unset: the app counts drawn rows and covers in the frame it's building, which is two additions each. With it set, marks and samples come from frames that happen anyway. Only the memory scenario starts a thread, which samples once a second (`tick` lines) and wakes the UI when a stage's wait is over. A sample costs a few milliseconds because of `mincore` over 600 MB of fonts, so marks leave that out. An idle window shows 0 CPU time over 10 s with it unset and with `=1`.

The frame-time overlay (backtick) shows footprint and gpu under the frame times.

### Baseline

`docs/measure-baseline.json`, from `./build/measure/measure all` on a MacBook Air (M1, 8 GB, MacBookAir10,1), macOS 27.0.1, 1100x700 window at 2x. MB is 2^20 bytes.

Startup, in ms since the process started. Run 1 is on its own. The other 9 runs give the median and range.

| mark | fake run 1 | fake median (min to max) | mock run 1 | mock median (min to max) |
|---|---|---|---|---|
| main | 7.2 | 10.4 (7.9 to 11.9) | 11.5 | 10.1 (7.7 to 13.9) |
| launched | 92.3 | 98.0 (86.6 to 100.5) | 98.7 | 99.3 (91.1 to 102.5) |
| dylib | 231.2 | 234.1 (227.9 to 247.3) | 338.3 | 261.5 (248.0 to 274.3) |
| init | 249.5 | 249.9 (244.0 to 270.2) | 354.5 | 285.7 (272.8 to 295.8) |
| window | 254.8 | 255.4 (249.4 to 275.8) | 359.7 | 291.4 (278.6 to 303.1) |
| first_frame | 301.6 | 306.2 (300.1 to 334.5) | 408.8 | 345.5 (330.2 to 353.3) |
| library | 301.6 | 306.3 (300.1 to 334.5) | 464.0 | 351.1 (337.9 to 361.4) |
| tracks | 308.9 | 312.1 (304.8 to 338.9) | 695.0 | 581.4 (548.6 to 595.5) |

At `tracks` the footprint is 80 MB with the fake data and 118 MB with the mock, gpu 31 and 47 MB.

The baseline's fake run 1 came after earlier runs of the same build, so it shows no first-run cost. Straight after a build the first launch reaches `main` at about 170 to 300 ms instead of 10, while macOS checks the new binary's signature. The mock's run 1 also logs in.

Memory, MB:

| stage | fake footprint | resident | gpu | mock footprint | resident | gpu | mock covers |
|---|---|---|---|---|---|---|---|
| startup_idle | 104.0 | 134.2 | 43.3 | 113.7 | 144.0 | 47.2 | 22 |
| list_open | 104.0 | 134.2 | 43.3 | 116.3 | 146.2 | 49.2 | 37 |
| scrolled | 110.0 | 139.9 | 47.3 | 173.6 | 194.6 | 102.8 | 608 (21.5 MB) |
| playing | 115.8 | 143.7 | 47.3 | 189.5 | 208.2 | 103.3 | 610 |
| idle_after | 111.6 | 142.5 | 47.3 | 184.4 | 206.1 | 103.3 | 610 |

The peak footprint was 128 MB with the fake data and 198 MB with the mock. Fallback fonts: 601 MB mapped, 29 to 30 MB of it resident.

What stands out:

- Between `launched` and `dylib` the shell spends about 140 ms. It copies the dylib to a temp file and opens the copy, so hot reload can replace the original, and it does that in release builds too. A file macOS hasn't seen gets its signature checked on every `dlopen`: opening a fresh copy of `app.dylib` takes about 100 ms, opening the same file again takes 7 to 9 ms. Opening the dylib in place when hot reload is off would save about 90 ms of the 310.
- From `main` to `launched` is about 85 ms of AppKit setup before the app's code runs.
- Covers dominate memory growth on the mock. During the scroll gpu went up 54 MB for 571 more covers, about 96 KB each, while the cover cache grew by 18.6 MB of base levels, about 33 KB each (most are 80x80, 25 KB). Mips add a third, so most of the rest is likely Metal rounding each small texture's allocation up. Footprint rose by the same amount, since GPU memory is part of it.
- Playback adds about 6 MB of footprint with the fake data and 16 MB on the mock, and 10 s after it stops only 4 to 5 MB of that is gone.
- The 43 MB of GPU memory before any cover loads isn't broken down here. A coverage atlas page alone is 4 MB.
- The persistent arena holds 23 MB in every setup and doesn't grow.
