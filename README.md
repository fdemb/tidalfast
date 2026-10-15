# TIDALfast

A native macOS TIDAL client in Odin. A small Obj-C shell owns the window and talks to macOS. Everything else is an Odin dylib that the shell reloads while it runs. `docs/plan.md` has the plan and the phases.

```
shell/          Obj-C executable: window, CAMetalLayer, event queue, dylib loader, media keys and Now Playing
src/platform/   the ABI between shell and app (shell/platform.h mirrors it)
src/app/        the hot-reloaded app dylib
src/render/     Metal renderer
src/text/       fonts, shaping (kb_text_shape), rasterizing (CoreText), glyph atlas
src/ui/         box tree, layout, input, animation, menus and tooltips
src/kbts/       kb_text_shape 2.21: C source and Odin bindings
assets/fonts/   Inter 4.1, static Regular/Medium/SemiBold/Bold, with its OFL licence
src/tidal/      TIDAL API library, see src/tidal/README.md
src/audio/      FLAC and DASH streaming, fMP4, decoding, miniaudio and CoreAudio HAL output, the play queue's rules, ReplayGain
src/jobs/       a thread-safe priority queue for jobs and results
src/cover/      cover sizes, decoding and the texture cache
src/mac/        Keychain, opening URLs and reading the clipboard, called straight from Odin
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
- `TIDALFAST_API=url` sends every request, the login and cover downloads to `url` instead of TIDAL, for running against `tests/mock_tidal`. The login then goes in the Keychain under `tidalfast-mock`, so it never replaces a real one. Only debug builds read it, and only for `http` or `https` on `127.0.0.1`, `[::1]` or `localhost`. Anything else is ignored with a line on stderr. Whoever runs the server at `url` gets the tokens of the account that logs in, so a release build never sends them anywhere but TIDAL.
- `TIDALFAST_KEYCHAIN=name` keeps the mock login under `name` instead of `tidalfast-mock`. It only works together with `TIDALFAST_API`, and never with `tidalfast`. A build that reads an item another build wrote makes the Keychain ask for access, so test runs can give a build its own item.
- `TIDALFAST_OVERLAY=1` shows the frame-time overlay from the start.
- `TIDALFAST_VOLUME=0.2` sets the volume slider at start.
- `TIDALFAST_AUDIO_NULL=1` plays to miniaudio's null device: the audio callback runs in real time, but nothing reaches the speakers.
- `TIDALFAST_AUDIO_CAPTURE=path` writes every sample the audio callback hands the device, after ReplayGain and volume, to `path` as a 32-bit float WAV. In bit-perfect mode it's what the HAL IOProc hands CoreAudio. Only the first player after start captures, not the ones a hot reload makes. The header's sizes are filled in when the app quits; `tests/audio_check` and `tests/bitperfect_check` also read a file whose header still says 0. The header has the rate of the first device open; after a rate change the frames carry on at the new rate in the same file.
- `TIDALFAST_SETTINGS=path` keeps the output settings (bit-perfect, hog mode) in `path` instead of `~/Library/Application Support/tidalfast/settings.json`.
- `TIDALFAST_PKCE_REDIRECT=url` stands in for the clipboard in the hi-res login (see Login). With no saved login the app finishes the hi-res login with it at start, so a script can log in to `tests/mock_tidal` without a browser. Debug builds only.
- `TIDALFAST_AUDIO_WINDOW_KB=n` sets how much of each track is kept downloaded (8 MB by default). A small window sends seeks back to the network, for measuring them.
- `TIDALFAST_NOW_PLAYING_LOG=1` makes the shell print Now Playing as macOS holds it, read back from `MPNowPlayingInfoCenter`, after every update, and every remote command it gets.
- `TIDALFAST_REMOTE_TEST="8:play,12:seek=10,20:pause,24:next"` makes the shell send those remote commands that many seconds after launch, through the same path as the media keys. The commands are `play`, `pause`, `toggle`, `next`, `previous` and `seek=seconds`.
- `TIDALFAST_SPALL=path` writes a [spall](https://gravitymoth.com/spall/) trace of every frame to `path`.
- `TIDALFAST_LOG_EVENTS=1` prints every input event.
- `TIDALFAST_CAPTURE=path` writes each presented frame to `path` as a TGA. It's for checking output when you can't take screenshots. Each frame goes to a temp file that's renamed over `path`, so copying `path` while the app runs gives a whole frame.
- `TIDALFAST_BENCH=1` scrolls the library's track table by itself and logs the CPU time per frame in three phases (see UI below). `TIDALFAST_BENCH=text` does the same for the text test list (see Text). `TIDALFAST_BENCH=covers` does it on live data while covers stream in (see TIDAL data). All of them keep asking for frames even when the window is covered.

The backtick key toggles the frame-time overlay. It's off unless `TIDALFAST_OVERLAY` or `TIDALFAST_BENCH` is set; the benches draw it so their numbers include it. It plots the CPU time of the last 120 frames against 120 Hz and 60 Hz lines. Under the plot are the last frame's total CPU time and the time spent building it (ui: everything before `end_frame`), its draw calls (blue dot) and instances (green dot), and the text cache's run count and atlas pages. The app also logs draw calls and instances to stderr whenever they change.

The app opens on the library screen, or the login screen when there's no saved login. Cmd-1 goes back to it, Cmd-2 shows the text test screen (specimen lines and a 10,000-row list) and Cmd-3 the phase 1 renderer test screen. F1 or Cmd-Shift-D outlines every UI box and shows the key, ID and size of the box under the mouse.

To run with Metal's validation layer, set `MTL_DEBUG_LAYER=1 METAL_DEVICE_WRAPPER_TYPE=1`.

## Renderer

`src/render` draws everything as instances of one quad. Each instance is a rounded box drawn with a signed distance function in the fragment shader. It has four corner colours, four corner radii, a border width, an edge softness, a clip rect, and an optional texture with a source rect. A shadow is a soft-edged box drawn under the real one (`push_shadow`).

The API takes points. The renderer multiplies by the backing scale and rounds rect edges, clip rects and borders to whole pixels, so a 1 pt border is exactly 2 pixels at 2x.

Colours are sRGB with straight alpha, as a design tool shows them. The drawable is `BGRA8Unorm_sRGB`, so the GPU blends in linear space. The shader interpolates gradient colours in premultiplied sRGB, which matches CSS gradients, then converts to linear before blending. Glyph coverage blends in linear space the same way.

Textures come from `texture_create`, `texture_update` and `texture_destroy`. A `Texture` handle carries a generation, so a stale handle draws solid colour. The zero handle is a 1x1 white texture and means "no texture". Formats:

- `R8` is linear coverage for the glyph atlas. The texture swizzle makes it sample as premultiplied white.
- `RGBA8` and `BGRA8` take sRGB colour with alpha premultiplied in sRGB space. That's what a premultiplied `CGBitmapContext` produces, so CoreGraphics output (emoji, decoded images) goes in as is. Pass `mipmapped = true` for cover art. Every update then regenerates the mips.

Colour textures are stored as `_sRGB` formats, and the GPU decodes sRGB before it filters. Uploading premultiplied sRGB bytes directly would decode `alpha * c` instead of giving `alpha * decode(c)`, which makes every translucent texel too dark: 50% white over black came out as 128 instead of 188. So each translucent texel is rewritten as the sRGB encoding of its premultiplied linear colour, `encode(decode(c / a) * a)`. The sample is then premultiplied linear, the same thing the shader makes from a solid colour, and filtering and mipmapping average the right values. Opaque and fully transparent texels don't change, so opaque cover art costs only a scan. The test screen has a black strip with 50% white three ways (an `RGBA8` texel, an `R8` texel and a solid rect), and all three read 188 in a capture.

The rewrite is `convert_premultiplied`, which works in place and touches no renderer state, so a decode worker can run it and pass `converted = true` to `texture_update`. Otherwise `texture_update` runs it on a copy when some texel is translucent. It reads a 256×256 table indexed by alpha and channel byte, built when the dylib loads; a test checks all 65,536 entries against the formula. A 2048×2048 texture with every texel translucent now takes 7 ms to convert and upload with mips, down from 216 ms, in an optimized build (179 ms, from 893 ms, in debug).

`texture_update` writes on the CPU straight away. A mipmapped texture remembers the command buffer of its last mip generation, which reads the whole base level, and the next write waits for it. The glyph atlas has no mips, so its writes never wait.

Batching: solid instances don't sample, so they join whatever batch is open. A new draw call starts only when a textured instance needs a different texture from the one the batch already binds. The test screen uses three textures, so it's three draw calls. Clipping is per instance: the vertex shader cuts the quad down to the clip rect, so changing the clip never breaks a batch.

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

1. **Load.** The four Inter files are embedded with `#load` and copied into the persistent arena. Each is parsed into kb_text_shape (`LoadFont` and `PlaceBlob` into our own memory, so the font holds no allocator) and handed to CoreText through `CTFontManagerCreateFontDescriptorFromData`. Both read the same bytes, so glyph IDs match.
2. **Shape.** `shape` hashes (string, font, size) and looks the run up in an open-addressing table. On a miss it decodes the string, finds fallback fonts for anything Inter lacks, picks the paragraph direction, shapes with the kb_text_shape context, fixes up bidi (below), and stores the glyphs in a pool: pen position, advance, offset, glyph ID, face and grapheme cluster, in visual order, in points. A run shaped while one of its fonts was still loading is marked pending, and `shape` shapes it again once fonts have arrived.
3. **Cache.** Runs remember the frame they were last used. Every 256 frames, runs not drawn for 600 frames go; if the table is three quarters full or the pool is, everything not drawn last frame goes. A sweep compacts the glyph pool. A `^Run` from `shape` is valid until the next `begin_frame`. If the cache is full mid-frame, the run lives in the frame arena for that frame and the next frame sweeps.
4. **Rasterize.** On first use at a pixel size and subpixel offset, a glyph is drawn with `CTFontDrawGlyphs` into a CGBitmapContext at physical pixel size: alpha-only (grayscale coverage) for normal glyphs, premultiplied BGRA for colour fonts. Antialiasing is on, font smoothing is off, subpixel positioning is on and CoreGraphics' own quantization is off, because we pick the offset. Rasterizing stops for the frame after 2 ms; the remaining glyphs show up over the next frames, and the app asks for another frame through `request_redraw`.
5. **Atlas.** `stb_rect_pack` packs bitmaps, with a one texel gap, into 2048×2048 R8 pages (coverage) and 1024×1024 BGRA pages (emoji). A full page gets a new sibling, up to 8 pages. If they're all full, or the glyph table is three quarters full, the atlas starts over at the next `begin_frame`: old pages are destroyed rather than overwritten, since a frame in flight may still sample them.
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

Each box has a size per axis: `px(n)`, `text_size(pad)` (the label's width or line height plus `pad`), `pct(f)` of the nearest ancestor with a size of its own, or `children_sum()`. `fill()` is `pct(1, 0)`. Each size has a strictness: how much of it the box keeps when its parent has too little room. `layout.odin` runs Fleury's five passes per axis: standalone sizes (pixels, text), upwards-dependent (percentages, skipping ancestors sized by their children), downwards-dependent (children sums), violations, then positions. When the children along a box's child axis don't fit, each gives up `size * (1 - strictness)` in proportion until the overflow is gone. Across the axis a child larger than its parent is cut to fit. Scroll views allow overflow on their scroll axis and skip that step. A box with `Floating_X`/`Floating_Y` sits at `fixed_pos` outside the flow. So a row of `px(44)`, `fill()` and `px(56)` gives the middle box whatever is left.

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

`src/app/library.odin` follows spotifast's layout and dark palette: a sidebar of 32 fake playlists, 250 pt wide by default, resized with a 5 pt handle between 210 and 600 pt (it stops growing once the main view would go below 360 pt). Next to it is the main view with the playlist header and the 10,000-row track table, and the 88 pt player bar runs along the bottom. Rows are 56 pt. The columns follow spotifast's `columns`, measured on the main view's width: #, cover and title always. Album shows above 560 pt (28% of the width, 140 to 360 pt), date added above 760 and added by above 920. Duration and the "more" button always show. Hovering lights a row; a click selects it; a double-click plays it (see Playback), and the row playing is lit. A right click or the "more" button opens a context menu. Dragging a row onto a playlist shows a ghost and a drop highlight. The drag goes through `ui.drag_begin` with the row index, so releasing after the row has scrolled out of view still ends it. With the table focused, the arrow keys, Page Up/Down and Home/End move the selection and scroll it into view, and Enter plays it. The player bar has previous, play/pause and next, a progress bar that seeks on click or drag and shows the drag position while held, elapsed and remaining time, and the volume slider. Rows whose page hasn't arrived yet show their number and grey bars. With `TIDALFAST_FAKE=1` the 32 playlists and 10,000 rows are the fake data again and covers are gradients.

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

With no saved login the app shows a login screen and asks TIDAL for a device code straight away. It shows the code and `link.tidal.com`. "Open in your browser" opens the link with the code already in it, through LaunchServices (`LSOpenCFURLRef`). The app doesn't open the browser on its own: a window that launches a browser every time it starts without a login is rude, and scripts run it that way too. A worker polls TIDAL (`login_device_wait`) until the user approves, then the library loads. It waits the `interval` TIDAL gave between polls, 5 s longer after each `slow_down`. If the code expires a new one is fetched. If TIDAL can't be reached while the code is still good, the screen says so and the app checks once after 2 s, then 4, 8, 16 and 30 s between tries, never sooner than the interval, and goes back to normal polling as soon as TIDAL answers. A poll that goes back in the queue, after a 429 or a reload, keeps the interval it had reached, `slow_down` included, and waits that long from when it went back. Once a poll has the tokens the code is spent, so if loading the session then fails or waits out a backoff, the next try loads it with those tokens, however long ago the code expired. A 5xx or a 408 counts as not reaching TIDAL, while polling and while loading the session, so it gets the same retries. Anything else stops the login: the screen shows the error and a "Try again" button instead of the code. "Try again" loads the session with the tokens if the login has them, and asks for a new code if it doesn't. If TIDAL refuses the tokens, they go, and "Try again" starts over with a new code.

This is TIDAL's device login for limited-input clients. It never gets hi-res; see below.

### Hi-res login

TIDAL decides the best stream a token gets by the OAuth client it was issued to, not by the subscription alone. "Log in for hi-res" on the login screen runs the PKCE login of TIDAL's Android phone client instead:

1. The app makes a fresh PKCE verifier and client key, keeps them in `Data` so a hot reload doesn't lose them, and opens `login.tidal.com/authorize` in the browser with the client id, the S256 challenge, `appMode=android` and the redirect `https://tidal.com/android/login/auth`. The device-code poll stops meanwhile; "Use a code instead" starts it again.
2. After the login TIDAL redirects to that address, which shows an "Oops" page. Its address has `?code=...`.
3. The user copies the address and clicks "Paste the address". The app reads the clipboard with the Pasteboard Manager (`PasteboardCopyItemFlavorData` in HIServices, a C API, so no Obj-C and no ABI change), checks that it starts with the redirect and has a code, and a `Login_Pkce` job trades the code and verifier for tokens.

The paste button stands in for a text field until there is one; once the phase 7 text field is merged, the address should go in a field on this card. `TIDALFAST_PKCE_REDIRECT` replaces the clipboard in debug builds.

The code in the address works once. If the exchange gets the tokens and loading the session then fails, the card says so and offers "Try again", which loads the session with the tokens the exchange got. A hot reload in between keeps them too, and the `Login_Pkce` job that was put back finishes with them. Only when there are no such tokens does it trade a code again.

Each login attempt has a number (`Data.login_attempt`). It goes up when the user switches to the hi-res login or back to the code, and when a sign-out starts a new login. `Login_Wait` and `Login_Pkce` jobs carry the number they were queued with, and the session knows the current one (`tidal.session_set_login_attempt`). A device-code poll that TIDAL approves after the user moved on to the hi-res login has its tokens dropped before they reach the session, so it can't replace a hi-res login that finished first, possibly of another account. Its result is ignored. A poll that was still queued doesn't poll at all.

The Keychain item now also stores `client_id`, the client the tokens were issued to. A refresh has to use it: the mock refuses a PKCE refresh token sent with another client id, and TIDAL rotates refresh tokens per client. Items saved before this go by their `is_pkce` flag. A Stream job asks for `HI_RES_LOSSLESS` when the login is PKCE and `LOSSLESS` otherwise.

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

Kinds of job: `Restore` (read the Keychain), `Login_Start`, `Login_Wait`, `Login_Pkce` (finish the hi-res login with the pasted address), `Playlists`, `Tracks` (one page), `Cover`, `Stream` (resolve a track's stream, see Playback), `Artwork` (a cover for Now Playing, kept as pixels) and `Save_Settings` (write the output settings, so a click never waits on the disk; see Output settings).

Hot reload: `unload` sets the session's abort flag, which makes curl stop any transfer in flight (an `XFERINFOFUNCTION` that checks it) and `login_device_wait` return. Then it stops both queues and joins the workers. A worker whose job was cut short puts it back in the queue where it was. `unload` then copies the session's login state to a heap buffer, keeps the backoff's end and reason in `State`, and destroys the session, since a `tidal.Session` holds allocators and a curl handle pool made by this dylib. `reload` makes a new session, restores the login and the backoff, and starts new workers, which pick up the jobs that were put back. So a reload during a 30 minute anti-abuse hold doesn't end it. A device login that got its tokens but hadn't loaded the session when the reload came keeps them too: `reload` restores tokens without a user only then, and the `Login_Wait` that was put back finishes the login with them. Results that were waiting stay in their queue. A `Login_Wait` job holds the code's expiry as a time, not a duration, so a reload doesn't stretch it.

### Memory

Each job that returns data gets its own virtual-memory arena (`core:mem/virtual`), and `src/tidal` parses into it. Scratch memory is the worker's thread-local temp allocator, reset after each job, never the result allocator. The UI thread then:

- adopts the Playlists result's arena as the sidebar's, and destroys the previous one;
- copies a track page's rows into the open list's arena and destroys the page's;
- uploads a cover's pixels and frees them.

The open list's arena lives in `State` and is destroyed when another list opens. Pages carry the list's generation number, so a page for a list that's been closed is dropped when it arrives.

### Pages

A list opens with the track count TIDAL gave for it, so the table has its full height straight away and rows not yet loaded show as placeholders. The first page is 50 tracks so it shows sooner. The rest come 100 at a time, two pages in flight. A short page means the list has ended. Pages can arrive out of order, so the earliest end any short page gives stands: an empty page asked for past the end can't raise the count again, and rows past the end are dropped. If the list turns out longer than TIDAL said, full pages keep raising the count and one more page is asked for at a time until a short one.

### Rate limits

`src/tidal` already backs off after a 429 (for `Retry-After`, or 60 s) or an anti-abuse 403 (for `Retry-After`, or 30 minutes), and refuses requests locally until then. All workers share one session, so they share that state. The OAuth endpoints go through it too: asking for a device code, polling for approval and refreshing the token. Covers go through it as well: `tidal.resource_get` downloads from `resources.tidal.com` with the session's backoff check and curl pool, without the API's token and parameters. A worker checks `backoff_remaining` before each job. While it's above zero, the worker puts the job back and sleeps until the backoff ends or the queue stops. A job refused with `Backing_Off`, or the one that got the 429 or 403, goes back in the queue too, instead of failing. The library's status line says how long TIDAL asked us to wait.

### Covers

1. Drawing a cover asks the cache (`src/cover`) for it at the size it's shown on this display: `pick_size` takes the smallest size TIDAL serves that's at least the box's points times the backing scale. Track rows are 40 pt, so 80x80 at 2x. The 92 pt header asks for 320x320, and the sidebar's playlist images start at 160x160, the smallest TIDAL has for playlists. Rows within 4 of the view ask for theirs too, at a lower priority.
2. After the frame is built, `covers_schedule` queues a job for each cover asked for this frame with no job yet. Queued covers that weren't asked for this frame, because their rows scrolled away, come out of the queue. A worker that already has one finishes it, and the cover stays in the cache.
3. The worker downloads the JPEG, decodes it with `stb_image`, and runs `render.convert_premultiplied` on the pixels, so the upload can pass `converted = true`.
4. The UI thread uploads it as a mipmapped RGBA8 texture. Uploads stop for the frame after 2 ms; what's left waits for the next frame.
5. The cache keeps up to 2,048 covers within 48 MB of texture memory, counting the mips. Over that, it destroys the least recently drawn textures, never one drawn in the current frame.

A cover shows a flat placeholder until its texture arrives, then fades in over 0.25 s. The fade asks for frames only until it finishes. A cover that failed is tried again once it has left the screen and comes back, or after 30 s. That includes a 401: cover downloads send no token, so their answer says nothing about the login.

Texture uploads don't wait on the GPU. A new texture has no earlier mip generation to wait for, which is the only thing `texture_update` waits on.

### The mock server

`tests/mock_tidal` serves the device login (approved a few seconds after the first poll), token refresh that rotates the refresh token, the session and user, 240 liked tracks, 12 playlists (one with 3,000 tracks), their tracks, and covers drawn on request as JPEGs at any size. Flags set the long playlist's length, the login delay, the access token's lifetime, delays for pages and covers, a request to answer with 429, 429s for the first device code requests, `slow_down` answers to the first polls, a 429 to one poll of each code, a point after which it refuses the login with 401 until the next device login, and 401s to the first covers after each device login, held back for as long as you ask. It prints the time between polls. The comment at the top of `main.odin` lists them. It never prints tokens or Authorization headers, and neither does the app.

It also serves playback (see Playback below). Flags add a delay before every audio response (`-audio-delay=ms`), cap each audio connection's bandwidth (`-audio-rate=KB/s`), leave the SEEKTABLE out of the files (`-seektable=0`) and pick where the generated audio goes (`-audio-dir`).

For hi-res it serves the PKCE login (`/authorize` redirects straight to `/android/login/auth?code=...`, and the token endpoint takes an `authorization_code` grant only with the Android client's id, a verifier and that redirect) and a hi-res test album as liked tracks 4 to 6 (`hires.odin`): "Quiet Noise 16/44.1" as a BTS FLAC, then two 24/96 tracks of 10 and 6 seconds. Those come as DASH (`HI_RES_LOSSLESS`, an MPD with a `SegmentTemplate` and a `SegmentTimeline`, 4 second fMP4 segments under `/dash/`) when a PKCE login asks for `HI_RES_LOSSLESS`, and as the 16/44.1 file otherwise. All three are xorshift noise at about -60 dBFS, made as WAV, encoded with `afconvert` and cut by `tests/dashgen`. `-hires-only` makes them the only liked tracks, so playing through the list never reaches the loud test tones.

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

`tidal.resolve_stream(session, track_id, quality)` asks v1 `tracks/{id}/playbackinfopostpaywall` with `playbackmode=STREAM`, `assetpresentation=FULL` and `audioquality=LOSSLESS`, or `HI_RES_LOSSLESS` after a hi-res login. The answer carries one of two manifests:

- BTS (`application/vnd.tidal.bts`): base64 JSON with `mimeType` (`audio/flac`), `codecs`, `encryptionType` and `urls`. `resolve_stream` returns the first URL.
- DASH (`application/dash+xml`): a base64 MPD with one `Representation` (`codecs="flac"`, `mimeType="audio/mp4"`) and a `SegmentTemplate` with absolute `initialization` and `media` URLs (`$Number$` from `startNumber`, a token in the query) and a `SegmentTimeline`. `dash_info_from_mpd` expands the timeline (`t`, `d`, `r` repeat counts, `r="-1"` up to the next `t` or the end of the period) into segments with their start and length in `timescale` units. `resolve_stream` returns the initialization URL, the segments and the timescale.

Both come with the sample rate and bit depth and the ReplayGain fields `trackReplayGain`, `trackPeakAmplitude`, `albumReplayGain` and `albumPeakAmplitude`, the names tidalapi, riptide and the other reference clients read. It refuses encrypted streams (an `encryptionType` other than `NONE`, or a `ContentProtection` in the MPD) and anything that isn't FLAC, such as the AAC some `HI_RES_LOSSLESS` answers carry. A missing gain is 0 dB and a missing peak 1.0. A track without album gain uses its track gain for both.

Resolving runs as a `Stream` job on the data workers. Stream URLs expire, so when a download fails with a 4xx the app resolves the track once more and carries on from where it was.

### Threads and buffers

```
fetch thread per track slot --bytes--> Stream window --> decode thread --float frames--> Pcm_Ring --> audio callback --> device
```

- **Fetch.** Each of the two track slots, current and next, has a thread that downloads the file with curl into an 8 MB window. A DASH track is the initialization segment and then each media segment, fetched one after another into the same window as one run of bytes; see DASH below. The window slides forward as the decoder reads and keeps 256 KB behind the read position for short seeks back. Each request is an HTTP `Range` from where the window ends. When the window is full the thread blocks on a condition variable, so a paused track holds a connection and uses no CPU. If the server closes the connection, the thread resumes from where it got to. After 5 failures in a row, or a 4xx, the track fails.
- **Decode.** One thread owns the slots and the device. It feeds dr_flac (`ma.decoder` with our own read and seek callbacks) the header bytes and then the file from whatever frame a seek started at, applies the track's ReplayGain and writes float frames into the ring. Commands and arriving bytes wake it through a semaphore. Nothing wakes it when the ring has room: while the device runs it also wakes on a timer, every 250 ms or sooner if a quarter of the ring (`LOW_WATER`) would play in less, and tops the ring up. While nothing plays (paused, stopped, or the queue ended) the device is stopped and it waits on the semaphore with no timeout.
- **Ring.** `Pcm_Ring` is a single-producer, single-consumer ring of 131,072 frames (3 s at 44.1 kHz) with atomic read and write positions. The decode thread drops everything not yet played by storing a flush position, which the callback skips to on its next call, so the writer never touches the reader's position. A queue of marks next to it says which track or seek starts at which ring position. The callback adopts each mark once it has read past it, so the status describes the frame being played.
- **Callback.** It copies frames out, ramps the volume over one buffer, adopts marks and publishes the current mark and position. It never locks, allocates, logs, waits or makes a system call, and it doesn't use the Odin context. For the seek latency log it reads `mach_absolute_time`, which reads the commpage. The mark and position go out under a sequence count that is odd while they change, and `status` reads them again if the count was odd or moved, so it never pairs one track's or seek's mark with another's position.
- **Main thread.** The app sends commands (`play`, `stop`, `seek`, `set_next`, `set_paused`) under a mutex that the decode thread holds only to copy them, and reads a `Status` snapshot each frame. Neither waits on the network or the device. The decode thread wakes the UI when the status changes, and four times a second while playing for the progress bar.

### Queue and gapless

Double-clicking a row copies the open list into the queue and plays from that row. The rows after it follow. Each new queue gets a generation, and a preloaded track is reused only if its generation, row and track id all match, so a row of a new list never plays bytes preloaded for the old one. The play button and the toggle media command start the selected row (or the first) when nothing is loaded, start the queue again from the top once it has played out, and otherwise pause or resume. Signing out, or TIDAL ending the session, stops the player and clears the queue and Now Playing. The volume stays. Next and previous move through the queue and skip rows without a track id. Previous restarts the track instead once it has played 3 seconds. The queue follows the list while its pages load.

About 30 seconds before the current track ends, or once all of it has downloaded, the player asks for the next track. The app resolves it and hands it over with `set_next`, and its fetch thread starts downloading. When the current track's decoder runs out, the decode thread writes the next track's first frames into the ring right after the last ones, with a mark between them, so the device sees one unbroken stream. When the mark plays, the queue moves on. If the next track has a different sample rate or channel count (or bit depth, in bit-perfect mode), the decode thread lets the ring play out and reopens the device, which leaves a short gap. While it waits it wakes as soon as the ring should be empty instead of every 250 ms, so the gap is the device's re-clock and little else (see Bit-perfect output).

### ReplayGain and volume

In bit-perfect mode neither applies (see below). Otherwise a track gets album gain when it plays as part of its album in order: the queue entry before or after it is from the same album, with the track number one away. Otherwise it gets track gain, so a playlist of singles plays at an even level. The factor is `10^(gain/20)`, lowered to `1/peak` if it would push the peak over full scale. The decode thread applies it. The volume slider applies after it, in the callback, as the cube of the slider's position, so half way is about -18 dB.

### Seeking

A seek shows its position in the player bar at once. It names the track it's for, and the decode thread drops it if that track no longer plays; `play` also drops a seek it hasn't applied yet, so a new track never starts at the old one's seek position. The decode thread then looks for the frame to start from. It brackets the target with the SEEKTABLE's points, or with the first frame and the end of the file when there is no SEEKTABLE. It guesses a byte offset in proportion and looks there for a frame header that the next header confirms: sync code, CRC-8, and the next frame starting where this one's samples end. It narrows the bracket until it has a frame no more than 0.3 s before the target, decodes from there and drops the samples before the target. A guess outside the downloaded window empties it and starts a new range request at that offset, and playback goes on from those bytes. A seek inside the window doesn't touch the network.

Measured from the seek command to the first sample at the new position leaving the callback, against the mock with `-audio-delay=50 -audio-rate=400` (50 ms before each audio response, 400 KB/s per connection, about three times the stream's bitrate) and `TIDALFAST_AUDIO_WINDOW_KB=512`, seven seeks each:

| file | latencies |
|---|---|
| with SEEKTABLE | 25, 62, 101, 109, 113, 142, 278 ms |
| without | 12, 101, 103, 105, 108, 142, 311 ms |

After the callback stopped waking the decode thread, the same setup with SEEKTABLE gave 9, 96, 102, 102, 122, 132 and 300 ms.

The slowest in both is a seek to 18.7 s in a 20 s track, which needed a second probe. With the default 8 MB window the whole mock track is already downloaded, and a seek took 9 ms. Allowing up to 1 s before the target instead of 0.3 s made seeks that landed far from a seekpoint take 380 to 400 ms, since that second had to download and decode before being thrown away. The player logs each seek's latency to stderr.

### Media keys and Now Playing

`MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are Obj-C classes, and Odin dev-2026-10 crashes compiling Obj-C method calls, so both live in `shell/shell.m`. The shell enables play, pause, toggle, next, previous and `changePlaybackPosition`, and turns each command into an `EVENT_MEDIA` event: `key_code` is the `Media_Command`, `dx` the position for a seek. The app handles them in `playback_update`, the same way as the player bar's buttons.

The app calls `Shell.set_now_playing` with the title, artist, album, duration, elapsed time, state and the cover as RGBA pixels, which an `Artwork` job fetches at 640x640. It calls it only when one of those changes, since macOS moves the elapsed time along by itself from the playback rate. The shell copies everything before it returns and rebuilds the artwork only when `artwork_key` changes. This is platform ABI version 2. `Shell` and `Now_Playing` have size checks on both sides.

### Hot reload

The callback, the decode thread and the fetch threads all run dylib code. `unload` destroys the player: it stops and closes the device, joins the threads and frees the decoders. In bit-perfect mode that also puts the device back to the rate and format it had and releases hog mode, so a reload never leaves it changed with nobody to restore it. `reload` makes a new player and plays the same tracks from where they were; their URLs, and a DASH track's segment URLs, live in heap memory, not in the dylib. So a reload leaves a short silence, and the next track's download starts over. Moving the callback into the shell would avoid the silence, but the shell would need its own ring and its own marks and positions, and decoding would still stop for the reload. A short silence while developing costs less. Two reloads during playback, one right after a gapless track change, resumed at the right position.

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

The decode thread also watches the device. A listener on its `kAudioDevicePropertyDeviceIsAlive` and one on the system's default output only note what changed and wake the decode thread. When the device has gone, as when a USB DAC is unplugged mid-track, the decode thread stops and destroys the dead output without trying to restore anything on it, and plays on from the audible position on whatever is now the default output. If nothing can open, the track fails and the player bar says so. When the default output moves to another device while this one isn't hogged, the device is put back and the track moves to the new default the same way. A hogged device stops being the default, so the default moving then is no reason to leave. miniaudio follows the default output by itself.

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

`tests/hires_test.odin` checks the parts without a device: the MPD's timeline with repeat counts and jumps, the `moov`/`dfLa`/`moof`/`trun` parsing (64-bit box sizes, default sizes, `trun`s without a data offset), 24-bit samples through fMP4 and dr_flac with no bit changed, segment lookup for seeks, a DASH track played by the player on the null device in bit-perfect mode with every sample exact and a seek into the second segment starting exactly at its target, turning bit-perfect on mid-track, the PKCE redirect parsing and exchange against the test mock, the Keychain's client id, and the settings file. Since the review it also checks `moof` bounds on hand-made and randomly damaged boxes, both base offset rules and a DASH track with an explicit `base_data_offset` played bit for bit, `hal_fill` against buffer lists of several shapes, the choice of a physical format deep enough, the Output menu's reason, a simulated device loss (`audio.simulate_device_loss`, test builds only), four threads saving settings at once while another reads the file, and the settings path outliving `playback_shutdown`. `tests/login_test.odin` checks that a superseded device login is dropped and that a hi-res login retries with its tokens, before and after a reload.

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
TIDALFAST_API=http://127.0.0.1:8787 TIDALFAST_AUDIO_NULL=1 TIDALFAST_AUDIO_CAPTURE=/tmp/cap.wav \
    TIDALFAST_REMOTE_TEST=8:play ./build/tidalfast     # quit after about 60 s
odin run tests/audio_check -o:speed -- /tmp/cap.wav /tmp/tidalfast-mock-audio/album-source.wav 883234 1633711
```

`audio_check` finds where the sweep starts in the capture, fits the gain, and compares every frame after the first buffer's volume ramp with the source times that gain. A gap, a repeated or dropped frame, or a gain change at a track boundary fails it. The numbers after the files are the boundaries' source frames, which it reports on. It passes: 2,163,136 frames (49.05 s) across both boundaries, 0 samples off, a largest error of 6.3e-9 (float rounding), at x0.1715, which is the album gain of x0.5 times the default volume of 0.7 cubed.

`tests/player_test.odin` sends media commands through `playback_update` with the fake data on the null device, and checks the queue, the player's position after a seek, and what goes to Now Playing. It also checks that a new list's row doesn't take the old list's preloaded track and that the toggle starts playback from idle and after the end. `tests/audio_test.odin` checks on the null device that `play` drops a pending seek, that `status` never pairs a mark with another mark's position, and that the callback never posts the decode thread's semaphore.

### CPU

Apple M1, the mock album playing to the null device: 1.5% with an optimized dylib and about 4% with a debug one, mostly the four UI frames a second for the progress bar. Paused, the device is stopped and the decode thread sleeps on its semaphore: 0.0%.

Measured again after the callback stopped waking the decode thread, with CPU time from `ps`: the fake tones with an optimized dylib use 0.20 s in 15 s of playing (1.3%), and nothing in 7 s idle before playing or 20 s paused. The mock album with a debug dylib uses 2.3 to 3.6%, and nothing in 20 s paused once the next track's download has filled its window.

## Hot reload

Run `./build/tidalfast`, edit something in `src/`, then run `./build.sh app`. The running window picks up the change.

The shell watches `build/` with FSEvents. `build.sh` writes the dylib to a temp name and renames it into place, so the shell never sees a half-written file. When `app.dylib` changes, the shell copies it to a unique temp path and `dlopen`s the copy, which leaves the linker free to overwrite the original. If the new dylib's ABI version matches, the shell calls `unload` on the old app and `reload` on the new one, then redraws. The old dylib stays open. A dylib that fails to load is skipped and the old one keeps running. If the shaders in the new dylib don't compile, the app logs the error and keeps drawing with the previous pipeline.

The app keeps its state in memory the shell allocates once: a persistent block and a frame block. `State` sits at the start of the persistent block, and the rest is an arena. The frame arena is `context.temp_allocator` and resets every frame. A reload doesn't touch either block, so state carries over.

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

If the app returns `animating = true`, the view's `CADisplayLink` adds a frame every vsync until the app returns false. The shell pauses the link while the window is minimized or fully covered, so a hidden animation costs no CPU. An idle window uses no CPU.

While the link runs, a pending redraw waits for the next tick instead of drawing straight away. Drawing between ticks would present more than once per refresh, and with sustained input that runs out of drawables and blocks the main thread in `nextDrawable`. The wait has a limit: if no tick arrives within two refresh intervals of the last one, as when the display sleeps, a timer wakes the run loop and the observer draws directly. The same happens at once when the link is paused. So explicit redraws still happen while the window is hidden or the display is off. Resizes are the exception and always draw synchronously, so the window never shows a stretched frame.

The shell merges mouse moves, and scroll events in the same phase, into one event with the summed delta. Phase changes such as a gesture beginning or ending keep their own event. The queue grows as needed and never drops an event, so the app never misses a button or key release.
