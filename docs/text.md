# Text

`src/text` takes a string, a font (`.Regular`, `.Medium`, `.Semibold`, `.Bold`) and a size in points:

```odin
text.begin_frame(&s.text, r)                                  // once per frame
m := text.draw(&s.text, r, .Medium, 13, {x, y}, color, title, max_width = 280)
w := text.measure(&s.text, .Regular, 13, duration).width
run := text.shape(&s.text, .Regular, 13, label)               // keep and draw with draw_run
```

`pos` is the top left of the line box. `draw` returns the width actually drawn, the line height and ascent, and whether it truncated. `line_height` gives the box height without shaping anything.

The pipeline:

1. **Load.** The four Inter files and two Phosphor icon fonts are embedded with `#load`. The icon fonts hold only the icons the app draws, the `ICON_` strings in `text.odin`; `tools/icons.sh` cuts them from the `@phosphor-icons/web` package, about 2 KB each. An icon is text in the `.Icon` (bold) or `.Icon_Fill` face, so it is rasterized, cached and coloured like any glyph. Release builds use those bytes in place, handing CoreText a `CFData` that doesn't copy them: the shell never closes a dylib, and nothing reloads it. Debug builds, which hot reload replaces, copy them into the persistent arena first and give CoreText its own copy, as before. Each is parsed into kb_text_shape (`LoadFont` and `PlaceBlob` into our own memory, so the font holds no allocator) and handed to CoreText through `CTFontManagerCreateFontDescriptorFromData`. Both read the same bytes, so glyph IDs match.
2. **Shape.** `shape` hashes (string, font, size) and looks the run up in an open-addressing table. On a miss it decodes the string, finds fallback fonts for anything Inter lacks, picks the paragraph direction, shapes with the kb_text_shape context, fixes up bidi (below), and stores the glyphs in a pool: pen position, advance, offset, glyph ID, face and grapheme cluster, in visual order, in points. A run shaped while one of its fonts was still loading is marked pending, and `shape` shapes it again once fonts have arrived.
3. **Cache.** Runs remember the frame they were last used. Every 256 frames, runs not drawn for 600 frames go; if the table is three quarters full or the pool is, everything not drawn last frame goes. A sweep compacts the glyph pool. A `^Run` from `shape` is valid until the next `begin_frame`. If the cache is full mid-frame, the run lives in the frame arena for that frame and the next frame sweeps.
4. **Rasterize.** On first use at a pixel size and subpixel offset, a glyph is drawn with `CTFontDrawGlyphs` into a CGBitmapContext at physical pixel size: alpha-only (grayscale coverage) for normal glyphs, premultiplied BGRA for colour fonts. Antialiasing is on, font smoothing is off, subpixel positioning is on and CoreGraphics' own quantization is off, because we pick the offset. Rasterizing stops for the frame after 2 ms; the remaining glyphs show up over the next frames, and the app asks for another frame through `request_redraw`.
5. **Atlas.** `stb_rect_pack` packs bitmaps, with a one texel gap, into R8 pages (coverage) of up to 2048×2048 and BGRA pages (emoji) of up to 1024×1024. A page starts at a quarter of that side, 512×512 or 256×256, and doubles when a glyph doesn't fit: the GPU copies the old texture into the top left of the new one ahead of the next frame, and the packer starts over with that corner taken, so every glyph keeps its place. The old texture goes at the next `begin_frame`, since instances drawn earlier in the frame still sample it. The library's text at start fits in a 512×512 page, 256 KB instead of 4 MB. Scrolling the mock's 3,000-track list grows it to 1024×1024, and scrolling the fake data, with its scripts and emoji, ends with about 1.2 MB of glyph pages where it had two 4 MB pages. A full-size page that fills gets a new sibling, up to 8 pages. If they're all full, or the glyph table is three quarters full, the atlas starts over at the next `begin_frame`: old pages are destroyed rather than overwritten, since a frame in flight may still sample them.
6. **Draw.** The baseline is rounded to a whole pixel. Each glyph's pen x in pixels is split into a whole pixel and one of four quarter-pixel offsets (rounding to the nearest), and the bitmap for that offset is drawn one texel to one pixel, as a textured instance of the rect renderer. R8 coverage samples as premultiplied white, so it's tinted by the text colour and blended in linear light. Emoji are drawn untinted except for alpha.

Truncation uses the shaped advances and keeps or drops whole grapheme clusters, so a combining mark never stays without its base. A left-to-right paragraph keeps the clusters that fit before an ellipsis on the right. A right-to-left one keeps them from the right and puts the ellipsis on the left, which is its logical end. Spaces next to the ellipsis go.

Each glyph's cluster is the index of the first codepoint of its grapheme cluster, from kb_text_shape's grapheme segmentation (skipped for text below U+0300). Glyphs get their codepoint from kb_text_shape's index, or from CoreText's string indices on the `CTLine` path. Both are the true source index, so repeated characters get a cluster each.

All of it is plain data in `State`, the persistent arena and malloc'd font tables, plus CF objects, so it survives a hot reload. The kb_text_shape context stores a pointer to the library's internal allocator function, which lives in the dylib, so `reload` places the context afresh in the same memory. The font loader thread runs dylib code, so `unload` stops and joins it and `reload` starts it again; queued requests and finished results wait in `State` meanwhile. On an incompatible reload, `app_shutdown` calls `text.destroy`, which stops the loader, releases the CTFonts and bitmap contexts, unmaps fallback font files and destroys the atlas pages.

## Fallback fonts and emoji

For each codepoint Inter lacks (Inter's coverage is cached per BMP codepoint, since kb_text_shape's cmap lookup costs about half a microsecond), `CTFontCreateForString` names a font. Its file comes from `kCTFontURLAttribute` and is mapped with `mmap`, which matters for the 180 MB Apple Color Emoji. In a `.ttc` the right face is the one whose `name` table is byte for byte what CoreText returns for the font; kb_text_shape can't read the PostScript names in PingFang, so names don't work. The result is cached per (font, codepoint), and the face joins that font's fallback list. The cache never drops an entry, so a character no font has is asked for once per session; it starts at 4,096 slots and doubles when three quarters full. It used to drop new entries at that point instead, and then an unavailable character's answer had nowhere to go: it was asked for again on every reshape, and every answer woke the UI to reshape. Only the fallbacks a string needs go on kb_text_shape's font stack, under Inter.

All of that happens on a loader thread (`loader.odin`), because it took 4 to 22 ms on the UI thread the first time a script appeared (21 ms for Hebrew, which needs the font search below). The UI thread puts a request in a mutex-guarded queue and shapes without the font: those characters get Inter's missing glyph, which `draw_run` leaves blank, and the run is marked pending. The loader maps and parses the font into malloc'd memory, adds the face to a result list and calls the shell's `request_redraw`. The next `begin_frame` adds the face, and pending runs are shaped again when next asked for. The loader also handles fonts CoreText switches to inside a `CTLine` run. At start it loads the fallbacks for CJK, kana, Hangul, Arabic, Hebrew and emoji for each Inter weight, but not for the icon faces.

Two things get in the way:

- kb_text_shape doesn't always read the same cmap as CoreText. In Lucida Grande, CoreText's pick for Hebrew, kb_text_shape finds no Hebrew. When CoreText's pick doesn't have the character as kb_text_shape sees it, `search_fallback` goes through every installed font that has it, upright first, then matching boldness, then `/System/Library/Fonts` before `Supplemental`, and takes the first that works. Hebrew ends up in Arial Hebrew.
- Some of macOS's own fonts have only Apple's `morx` tables and no OpenType `GSUB`: Geeza Pro (CoreText's Arabic font), Lucida Grande and Apple Color Emoji. kb_text_shape can't shape them, so Arabic wouldn't join and emoji sequences (ZWJ families, flags, keycaps, the rainbow flag) wouldn't combine. Runs that kb_text_shape puts in such a font are reshaped by CoreText (`CTLine` over the run's codepoints in the same `CTFont`), and the glyphs it returns are rasterized from the same file. Arabic in Geeza Pro joins and reads right to left, and emoji sequences come out as one glyph.

Apple Color Emoji has colour bitmaps (`kCTFontColorGlyphsTrait`), so its glyphs go into the BGRA pages as premultiplied sRGB, the format `texture_update` expects, and draw at the nearest whole pixel.

## Right-to-left text

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

## Weight

At 2x with white text on the app's dark background, the rendered weight sits between CoreText's two modes. Summed brightness over "The quick brown fox jumps over" at 13 pt, against the same string drawn by CoreText into an opaque sRGB bitmap: ours 494k, CoreText without font smoothing 425k (it blends in gamma space, so it looks lighter), CoreText with font smoothing 569k. Glyph shapes and pixel placement match CoreText's; the difference is in edge brightness, from blending coverage in linear light. Dark text on a light background will look lighter than native for the same reason. Screen capture isn't permitted in the environment this was built in, so there's no comparison against a real AppKit window yet.

## Performance

`TIDALFAST_BENCH=text` on the 10,000-row list (about 25 rows in view, four labels each, plus the specimen panel and overlay, about 1,500 glyph instances), release build, Apple M1, 120 Hz display link. ui is the time spent building the frame, before `end_frame`:

| phase | what | ui avg | ui max |
|---|---|---|---|
| warm | scrolling back and forth over rows already shaped | 0.50 ms | 1.5 ms |
| cold | scrolling 6 rows per frame into rows never seen | 0.95 ms | 6.4 ms |
| jump | a whole new page of rows every frame | 1.32 ms | 3.9 ms |
| scripts | warm scrolling, plus a line in a new script every 30 frames | 0.57 ms | 3.2 to 4.2 ms |

The debug build is about five times slower (2.5 ms warm, 2.7 ms cold). The list itself takes about 0.1 to 0.25 ms warm. Cold frames are dominated by kb_text_shape, which costs about 0.4 µs per character (17 µs for "Bohemian Rhapsody (feat. Kendrick Lamar)"), and by CoreText shaping for Arabic and emoji runs (about 15 µs). The cold maximum is the phase's first frame, which jumps 1,000 rows and shapes about 80 runs at once. The warm maximum is a cache sweep, which runs every 256 frames and is counted in ui. An idle window still uses no CPU.

The scripts phase adds Thai, Devanagari, Georgian, Armenian, Ethiopic, Tamil, Khmer and Sinhala, none of which the prewarmed fonts cover, and logs each line's first frame and when it's first drawn with its font. With fonts loaded on the UI thread, those first frames took 5.8 to 21.9 ms. With the loader they take 0.4 to 2.1 ms, and the text appears one or two frames later, 8 to 18 ms after the line was added. The phase maximum is the frame after that, when CoreText rasterizes the new font's first glyphs within the raster budget.
