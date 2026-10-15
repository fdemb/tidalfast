# TIDALfast

A native macOS TIDAL client in Odin. A small Obj-C shell owns the window and talks to macOS. Everything else is an Odin dylib that the shell reloads while it runs. `docs/plan.md` has the plan and the phases.

```
shell/          Obj-C executable: window, CAMetalLayer, event queue, dylib loader
src/platform/   the ABI between shell and app (shell/platform.h mirrors it)
src/app/        the hot-reloaded app dylib
src/render/     Metal renderer
src/text/       fonts, shaping (kb_text_shape), rasterizing (CoreText), glyph atlas
src/kbts/       kb_text_shape 2.21: C source and Odin bindings
assets/fonts/   Inter 4.1, static Regular/Medium/SemiBold/Bold, with its OFL licence
src/tidal/      TIDAL API library, see src/tidal/README.md
tests/          `odin test tests`
examples/cli/   CLI on top of src/tidal
```

## Building and running

```
./build.sh              # debug: build/tidalfast and build/app.dylib
./build.sh app          # rebuild only the dylib
./build.sh release      # optimized, hot reload off
./build/tidalfast
```

It needs macOS 14 or later, Odin and the Xcode command line tools. Shaders are compiled at runtime from source in `src/render`, so the Metal toolchain isn't needed.

`src/kbts` holds kb_text_shape's C source and a copy of Odin's `vendor:kb_text_shape` bindings that link `build/kbts/kb_text_shape.a`. `build.sh` compiles that archive when it's missing or older than the source, so nothing is written to the Odin install. Run `./build.sh` once before `odin test tests`. The project adds one function to `kb_text_shape.c`, `tidalfast_bidi_class`, which exports the library's Unicode bidi class table.

Environment variables:

- `TIDALFAST_SPALL=path` writes a [spall](https://gravitymoth.com/spall/) trace of every frame to `path`.
- `TIDALFAST_LOG_EVENTS=1` prints every input event.
- `TIDALFAST_CAPTURE=path` writes each presented frame to `path` as a TGA. It's for checking output when you can't take screenshots.
- `TIDALFAST_BENCH=1` scrolls the text list by itself and logs the CPU time per frame in four phases (see Text below). It keeps asking for frames even when the window is covered.

The backtick key toggles the frame-time overlay, which plots the CPU time of the last 120 frames against 120 Hz and 60 Hz lines. Under the plot are the last frame's total CPU time and the time spent building it (ui: everything before `end_frame`), its draw calls (blue dot) and instances (green dot), and the text cache's run count and atlas pages. The app also logs draw calls and instances to stderr whenever they change.

Tab switches between the text test screen (specimen lines and a 10,000-row list) and the phase 1 renderer test screen.

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

Each glyph's cluster is the index of the first codepoint of its grapheme cluster, from kb_text_shape's grapheme segmentation (skipped for text below U+0300). Glyphs get their codepoint from kb_text_shape's index, or from CoreText's string indices on the `CTLine` path. kb_text_shape's index is wrong in some fonts (Apple SD Gothic Neo's Hangul comes back all 0), so an index that goes backwards to a different character is replaced by the next codepoint matching the glyph's.

All of it is plain data in `State`, the persistent arena and malloc'd font tables, plus CF objects, so it survives a hot reload. The kb_text_shape context stores a pointer to the library's internal allocator function, which lives in the dylib, so `reload` places the context afresh in the same memory. The font loader thread runs dylib code, so `unload` stops and joins it and `reload` starts it again; queued requests and finished results wait in `State` meanwhile. On an incompatible reload, `app_shutdown` calls `text.destroy`, which stops the loader, releases the CTFonts and bitmap contexts, unmaps fallback font files and destroys the atlas pages.

### Fallback fonts and emoji

For each codepoint Inter lacks (Inter's coverage is cached per BMP codepoint, since kb_text_shape's cmap lookup costs about half a microsecond), `CTFontCreateForString` names a font. Its file comes from `kCTFontURLAttribute` and is mapped with `mmap`, which matters for the 180 MB Apple Color Emoji. In a `.ttc` the right face is the one whose `name` table is byte for byte what CoreText returns for the font; kb_text_shape can't read the PostScript names in PingFang, so names don't work. The result is cached per (font, codepoint), and the face joins that font's fallback list. Only the fallbacks a string needs go on kb_text_shape's font stack, under Inter.

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

`TIDALFAST_BENCH=1` on the 10,000-row list (about 25 rows in view, four labels each, plus the specimen panel and overlay, about 1,500 glyph instances), release build, Apple M1, 120 Hz display link. ui is the time spent building the frame, before `end_frame`:

| phase | what | ui avg | ui max |
|---|---|---|---|
| warm | scrolling back and forth over rows already shaped | 0.50 ms | 1.5 ms |
| cold | scrolling 6 rows per frame into rows never seen | 0.95 ms | 6.4 ms |
| jump | a whole new page of rows every frame | 1.32 ms | 3.9 ms |
| scripts | warm scrolling, plus a line in a new script every 30 frames | 0.57 ms | 3.2 to 4.2 ms |

The debug build is about five times slower (2.5 ms warm, 2.7 ms cold). The list itself takes about 0.1 to 0.25 ms warm. Cold frames are dominated by kb_text_shape, which costs about 0.4 µs per character (17 µs for "Bohemian Rhapsody (feat. Kendrick Lamar)"), and by CoreText shaping for Arabic and emoji runs (about 15 µs). The cold maximum is the phase's first frame, which jumps 1,000 rows and shapes about 80 runs at once. The warm maximum is a cache sweep, which runs every 256 frames and is counted in ui. An idle window still uses no CPU.

The scripts phase adds Thai, Devanagari, Georgian, Armenian, Ethiopic, Tamil, Khmer and Sinhala, none of which the prewarmed fonts cover, and logs each line's first frame and when it's first drawn with its font. With fonts loaded on the UI thread, those first frames took 5.8 to 21.9 ms. With the loader they take 0.4 to 2.1 ms, and the text appears one or two frames later, 8 to 18 ms after the line was added. The phase maximum is the frame after that, when CoreText rasterizes the new font's first glyphs within the raster budget.

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
- Running threads. The text loader thread runs dylib code, so `unload` joins it and `reload` starts a new one.
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
