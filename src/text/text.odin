// Text: the system's UI font (SF Pro on macOS, Noto Sans on Linux) and the
// built-in Phosphor icons loaded into kb_text_shape and the OS's font
// rasterizer (CoreText on macOS, FreeType on Linux), shaping with
// kb_text_shape, rasterizing into glyph atlases, and drawing through the
// rect renderer.
//
// A string goes through shape (cached by string, font and size), then
// draw_run turns each shaped glyph into a textured rect, rasterizing glyphs
// the atlas doesn't have yet. Positions are in points; glyph bitmaps are
// rasterized at physical pixel sizes and placed on whole pixels, with one of
// four bitmaps per glyph for the fractional x position.
//
// Characters the system font lacks go to a fallback font that CTFontCreateForString
// picks on macOS, fontconfig on Linux and a list of the system's fonts on
// Windows (fonts_darwin.odin, fonts_linux.odin, fonts_windows.odin). Its
// file is loaded into kb_text_shape too, so both
// sides see the same glyph IDs. Fallbacks load on a worker thread
// (loader.odin). Some macOS fonts (Geeza Pro for Arabic, Apple Color Emoji)
// carry only Apple's morx shaping tables, which kb_text_shape can't read.
// Runs in those fonts are shaped by CoreText instead, which still gets them
// the right glyphs from the same file.
//
// SF Pro is one variable font, and kb_text_shape reads only its default
// instance, so for variable fonts the advances come from the OS
// (native_advance) and kb_text_shape adds its kerning to them.
//
// kb_text_shape splits text into runs of one direction, script and font,
// but its bidi resolution is incomplete, so shape_uncached picks the
// paragraph direction, fixes up neutrals, numbers and brackets a run at a
// time and orders the runs itself.
//
package text

import "core:c/libc"
import "core:hash"
import "core:mem"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"

import "../../third_party/kbts"

import "../render"

Font :: enum u8 {
	Regular,
	Medium,
	Semibold,
	Bold,
	Icon, // Phosphor Bold, the ICON_ strings below
	Icon_Fill, // Phosphor Fill
}

// The icon fonts are built in. The others are the system's (load_system).
@(private)
ICON_FILES := #partial [Font][]byte {
	.Icon      = #load("../../assets/fonts/Phosphor-Bold.ttf"),
	.Icon_Fill = #load("../../assets/fonts/Phosphor-Fill.ttf"),
}

// The icons in the Phosphor fonts, cut down to these by tools/icons.sh.
// Each is drawn as text in .Icon or .Icon_Fill, as noted. A glyph fills a
// square em, centred on the line.
ICON_PLAY :: "\ue3d0" // Icon_Fill
ICON_PAUSE :: "\ue39e" // Icon_Fill
ICON_SKIP_BACK :: "\ue5a4" // Icon_Fill
ICON_SKIP_FORWARD :: "\ue5a6" // Icon_Fill
ICON_SHUFFLE :: "\ue422" // Icon
ICON_REPEAT :: "\ue3f6" // Icon
ICON_REPEAT_ONCE :: "\ue3f8" // Icon
ICON_CARET_LEFT :: "\ue138" // Icon
ICON_CARET_RIGHT :: "\ue13a" // Icon
ICON_HEART :: "\ue2a8" // Icon
ICON_HEART_FILL :: "\ue2a8" // Icon_Fill
ICON_DOTS_THREE :: "\ue1fe" // Icon
ICON_SHARE_NETWORK :: "\ue408" // Icon
ICON_PLUS :: "\ue3d4" // Icon
ICON_CHECK :: "\ue182" // Icon
ICON_HOUSE :: "\ue2c2" // Icon
ICON_HOUSE_FILL :: "\ue2c2" // Icon_Fill
ICON_SPEAKER_HIFI :: "\uea08" // Icon
ICON_MAGNIFYING_GLASS :: "\ue30c" // Icon
ICON_MAGNIFYING_GLASS_FILL :: "\ue30c" // Icon_Fill
ICON_GEAR :: "\ue270" // Icon
ICON_CARET_UP_DOWN :: "\ue140" // Icon
ICON_SIGN_OUT :: "\ue42a" // Icon
ICON_USER :: "\ue4c2" // Icon

MAX_FACES :: 32 // also kb_text_shape's font stack limit
FALLBACK_CAPACITY :: 4096 // to start with; it doubles when three quarters full
RUN_CAPACITY :: 8192 // slots; the cache holds at most half that
GLYPH_POOL :: 1 << 18
SHAPER_MEMORY :: 8 << 20
ADVANCE_CAPACITY :: 4096 // slots; cleared when three quarters full
// A cached run nobody drew for this many frames is dropped at the next sweep.
EVICT_AFTER :: 600
SWEEP_EVERY :: 256
BASE_SIZE :: 16

ELLIPSIS :: "…"
// Points a run may exceed max_width by and still fit: a box sized to the
// run, less its padding, can come out a rounding error narrower than it.
FIT_SLACK :: 0.001

// A shaped glyph. Runs store glyphs in visual order, left to right.
Glyph :: struct {
	pen:     f32, // points from the run's left edge
	advance: f32,
	offset:  [2]f32, // points, y down
	// Codepoint index of the first codepoint of the grapheme cluster the
	// glyph belongs to. A cluster's glyphs are next to each other.
	cluster: u32,
	id:      u16,
	face:    u8,
	space:   bool,
}

// A shaped string. Pointers returned by shape stay valid until the next
// begin_frame.
Run :: struct {
	key:       u64, // 0 marks an empty cache slot
	glyphs:    []Glyph,
	width:     f32, // points
	ascent:    f32,
	descent:   f32,
	size:      f32,
	font:      Font,
	rtl:       bool, // paragraph direction
	// Shaped while a font it needs was loading: those characters have no
	// glyph or draw blank. shape reshapes it once State.generation moves on.
	pending:   bool,
	generation: u64,
	last_used: u64,
}

Metrics :: struct {
	width:     f32, // points, after truncation
	height:    f32, // ascent + descent
	ascent:    f32,
	truncated: bool,
}

Face :: struct {
	kb:               kbts.font,
	using native:     Face_Native, // the OS's handle for rasterizing, see face_native_init
	name:             u64, // hash of the PostScript name, or of the file and index
	units_per_em:     f32,
	ascent, descent:  f32, // in em
	color:            bool, // colour bitmaps (emoji): drawn from the BGRA atlas
	coretext_shaping: bool, // morx without GSUB: kb_text_shape can't shape it
	// An instance of a variable font, whose advances kb_text_shape gets
	// wrong: it reads the default instance's. They come from the OS, plus
	// what kb_text_shape adds to the default ones (kerning).
	native_advances:  bool,
	hmtx:             []byte, // the default instance's advances, in file
	hmetrics:         int, // advances in hmtx
	file:             []byte,
	mapped:           bool,
	blob:             rawptr, // kb_text_shape's parsed tables, malloc'd
}

// What fallback_cache knows about a character for a font, or about a font
// CoreText picked by name: a face index, NO_FACE or PENDING.
Fallback :: struct {
	key:  u64, // fallback_key or font_key; 0 is empty
	face: i8,
}

NO_FACE :: -1
PENDING :: -2 // asked the loader

// A cached native_advance, by face, glyph and, if ADVANCES_BY_SIZE, size.
Advance :: struct {
	key: u64, // 0 is empty
	em:  f32,
}

Stats :: struct {
	shaped:     int, // runs shaped this frame (cache misses)
	rasterized: int, // glyphs rasterized this frame
	runs:       int, // runs in the cache
	pages:      int, // atlas pages
}

State :: struct {
	faces:           [MAX_FACES]Face,
	face_count:      int,
	// Fallback faces found so far for each font, in the order found.
	fallbacks:       [Font][MAX_FACES]u8,
	fallback_counts: [Font]int,
	// Malloc'd, since it grows. Entries are never dropped, so each
	// character or font is asked of the loader once per session.
	fallback_cache:  []Fallback,
	fallback_used:   int,
	loader:          Loader,
	// Goes up whenever loaded fonts arrive, so pending runs reshape.
	generation:      u64,
	// Whether each font has each BMP codepoint, two bits apiece: 0 not
	// asked yet, 1 yes, 2 no. kb_text_shape's cmap lookup is slow enough
	// (about half a microsecond) to matter once per character.
	coverage:        [Font][]u8,
	advances:        []Advance,
	advance_count:   int,

	shaper_memory:   []byte,
	shaper:          ^kbts.shape_context,

	runs:            []Run, // open addressing on Run.key
	run_count:       int,
	pool:            []Glyph, // glyphs of cached runs, compacted by sweep
	pool_used:       int,
	cache_full:      bool, // a run didn't fit; sweep hard next frame

	frame:           u64,
	last_sweep:      u64,
	atlas:           Atlas,
	stats:           Stats,
	// Some glyph wasn't drawn this frame: the atlas was full (begin_frame
	// resets it) or the raster budget ran out. Draw another frame.
	needs_redraw:    bool,
	// When the slow steps of init finished, for the startup marks.
	init_steps:      render.Init_Steps,
}

// init loads the system font and the icons, allocates the caches from context.allocator,
// which must outlive the State (the persistent arena), and starts the font
// loader. The fallback cache grows, so it's malloc'd instead. wake is
// called from the loader thread when fonts arrive.
init :: proc(t: ^State, wake: proc "c" () = nil) -> bool {
	cache := ([^]Fallback)(libc.calloc(FALLBACK_CAPACITY, size_of(Fallback)))
	if cache == nil {
		return false
	}
	t.fallback_cache = cache[:FALLBACK_CAPACITY]
	for &c in t.coverage {
		c = make([]u8, 0x10000 / 4)
	}
	t.runs = make([]Run, RUN_CAPACITY)
	t.advances = make([]Advance, ADVANCE_CAPACITY)
	t.pool = make([]Glyph, GLYPH_POOL)
	t.shaper_memory = make([]byte, SHAPER_MEMORY)
	t.shaper = kbts.PlaceShapeContextFixedMemory(t.shaper_memory)
	atlas_init(&t.atlas)

	for font in Font {
		ok := load_embedded(t, font, ICON_FILES[font]) if font >= .Icon else load_system(t, font)
		if !ok {
			return false
		}
		t.face_count += 1
		t.loader.known[font] = {t.faces[font].name, t.faces[font].kb}
	}
	render.init_step(&t.init_steps, "text_fonts")
	t.loader.known_count = len(Font)
	t.loader.wake = wake
	loader_start(&t.loader)
	for font in Font {
		if font == .Icon || font == .Icon_Fill {
			continue // drawn only with their own ICON_ strings
		}
		for r in PREWARM {
			fallback_face(t, font, r)
		}
	}
	return true
}

destroy :: proc(t: ^State, r: ^render.Renderer) {
	l := &t.loader
	loader_stop(l)
	for i in 0 ..< l.request_count {
		font_ref_release(l.requests[(l.request_head + i) % LOAD_QUEUE].ct)
	}
	for &res in l.results[:l.result_count] {
		font_ref_release(res.ct)
		free_face(&res.face)
	}
	for &face in t.faces[:t.face_count] {
		free_face(&face)
	}
	atlas_destroy(&t.atlas, r)
	libc.free(raw_data(t.fallback_cache))
	t^ = {}
}

// begin_frame drops runs that haven't been drawn for a while and resets
// the atlas if it filled up last frame. Call it once per frame, before any
// shape or draw.
begin_frame :: proc(t: ^State, r: ^render.Renderer) {
	t.frame += 1
	t.stats = {}
	t.needs_redraw = false
	take_loaded(t)
	// Sweeping hard only once a run didn't fit: a working set that fits but
	// stays above some threshold would otherwise be swept every frame.
	if t.cache_full {
		sweep(t, 1)
	} else if t.frame - t.last_sweep >= SWEEP_EVERY {
		sweep(t, EVICT_AFTER)
	}
	atlas_begin_frame(&t.atlas, r)
	t.stats.runs = t.run_count
	t.stats.pages = atlas_pages(t)
}

// atlas_pages counts the glyph pages in use now.
atlas_pages :: proc(t: ^State) -> int {
	n := 0
	for page in t.atlas.pages[:t.atlas.page_count] {
		n += int(page.size > 0)
	}
	return n
}

// shape returns the shaped run for s, from the cache when it can.
shape :: proc(t: ^State, font: Font, size: f32, s: string) -> ^Run {
	key := run_key(s, font, size)
	slot, found := run_slot(t.runs, key)
	if found {
		run := &t.runs[slot]
		run.last_used = t.frame
		if !run.pending || run.generation == t.generation {
			return run
		}
	}

	t.stats.shaped += 1
	shaped := shape_uncached(t, font, size, s)
	shaped.key = key
	shaped.last_used = t.frame
	// Shaping never touches the run table, so slot is still key's slot. A
	// pending run being replaced leaves its old glyphs for the next sweep.
	if (found || t.run_count < RUN_CAPACITY / 2) && t.pool_used + len(shaped.glyphs) <= len(t.pool) {
		glyphs := t.pool[t.pool_used:][:len(shaped.glyphs)]
		copy(glyphs, shaped.glyphs)
		t.pool_used += len(glyphs)
		shaped.glyphs = glyphs
		t.runs[slot] = shaped
		if !found {
			t.run_count += 1
		}
		return &t.runs[slot]
	}
	// No room: hand out a run that lives until the end of the frame.
	t.cache_full = true
	run := new(Run, context.temp_allocator)
	run^ = shaped
	return run
}

measure :: proc(t: ^State, font: Font, size: f32, s: string) -> Metrics {
	run := shape(t, font, size, s)
	return {width = run.width, height = run.ascent + run.descent, ascent = run.ascent}
}

// line_height is ascent plus descent of the font at size, in points.
line_height :: proc(t: ^State, font: Font, size: f32) -> f32 {
	face := &t.faces[font]
	return (face.ascent + face.descent) * size
}

// run_key hashes the string, font and size into a cache key. It is never 0.
run_key :: proc(s: string, font: Font, size: f32) -> u64 {
	h := hash.fnv64a(transmute([]byte)s)
	h ~= u64(font) << 32 | u64(transmute(u32)size)
	h = mix64(h)
	return h if h != 0 else 1
}

// mix64 is the splitmix64 finalizer. fnv64a's low bits are weak, and the
// tables index with them.
mix64 :: proc(x: u64) -> u64 {
	x := x
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	return x ~ (x >> 31)
}

@(private)
run_slot :: proc(runs: []Run, key: u64) -> (int, bool) {
	mask := len(runs) - 1
	for i := int(key) & mask;; i = (i + 1) & mask {
		if runs[i].key == key {
			return i, true
		}
		if runs[i].key == 0 {
			return i, false
		}
	}
}

// sweep drops runs not used in the last max_age frames, compacts the glyph
// pool and rebuilds the table.
@(private)
sweep :: proc(t: ^State, max_age: u64) {
	t.last_sweep = t.frame
	t.cache_full = false
	survivors := make([dynamic]Run, 0, t.run_count, context.temp_allocator)
	for run in t.runs {
		if run.key != 0 && t.frame - run.last_used <= max_age {
			append(&survivors, run)
		}
	}
	// Glyphs only ever move down the pool, so in pool order no run's glyphs
	// are overwritten before they've moved.
	slice.sort_by(survivors[:], proc(a, b: Run) -> bool {
		return uintptr(raw_data(a.glyphs)) < uintptr(raw_data(b.glyphs))
	})
	mem.zero_slice(t.runs)
	t.run_count = 0
	t.pool_used = 0
	for &run in survivors {
		glyphs := t.pool[t.pool_used:][:len(run.glyphs)]
		copy(glyphs, run.glyphs)
		t.pool_used += len(glyphs)
		run.glyphs = glyphs
		slot, _ := run_slot(t.runs, run.key)
		t.runs[slot] = run
		t.run_count += 1
	}
}

// One kb_text_shape run before reordering: a stretch of one direction,
// script and font, in logical order.
@(private)
Piece :: struct {
	face:       int,
	rtl:        bool,
	start, end: int, // codepoints
	first:      int, // into the glyph buffer
	count:      int,
	width:      f32,
}

// Shaping is shape_uncached's scratch, in the temp allocator: the string's
// codepoints, the glyphs shaped so far with each one's codepoint index, and
// the pieces that index into both, and the grapheme boundaries
// kb_text_shape found. glyphs and cps only change together
// (shaping_append, flip), so cps[i] is always glyphs[i]'s codepoint.
@(private)
Shaping :: struct {
	runes:  []rune,
	glyphs: [dynamic]Glyph,
	cps:    [dynamic]int,
	pieces: [dynamic]Piece,
	// boundary[i] is true if a grapheme cluster starts at codepoint i. nil
	// if shaping failed or every codepoint is a cluster of its own.
	boundary: []bool,
}

@(private)
shaping_append :: proc(sh: ^Shaping, g: Glyph, cp: int) {
	append(&sh.glyphs, g)
	append(&sh.cps, cp)
}

// Font_Stack is the fallback faces a string needs on top of its font, and
// whether colour faces go above the rest for an emoji in it.
@(private)
Font_Stack :: struct {
	needed:      bit_set[0 ..< MAX_FACES],
	color_emoji: bool,
}

@(private)
shape_uncached :: proc(t: ^State, font: Font, size: f32, s: string) -> Run {
	primary := &t.faces[font]
	run := Run {
		size       = size,
		font       = font,
		ascent     = primary.ascent * size,
		descent    = primary.descent * size,
		generation = t.generation,
	}
	// kb_text_shape crashes on no codepoints, and text at size 0 is nothing.
	if len(s) == 0 || !(size > 0) {
		return run
	}
	sh := Shaping{runes = utf8.string_to_runes(s, context.temp_allocator)}
	sh.glyphs.allocator = context.temp_allocator
	sh.cps.allocator = context.temp_allocator
	sh.pieces.allocator = context.temp_allocator
	stack: Font_Stack
	stack, run.pending = font_stack(t, font, sh.runes)
	run.rtl = paragraph_is_rtl(sh.runes)
	kb_shape(t, font, size, &sh, stack, run.rtl)
	coretext_reshape(t, size, &sh, &run.pending)
	order := bidi_reorder(t, &sh, run.rtl)
	run.glyphs, run.width = place_pieces(&sh, order)
	return run
}

// font_stack finds fallback faces for whatever the font doesn't have. Only
// the ones this string needs go on the font stack: kb_text_shape is slower
// with more fonts to choose from. Characters whose font is still loading
// get the font's missing glyph, which draw_run leaves blank, and set
// pending.
@(private)
font_stack :: proc(t: ^State, font: Font, runes: []rune) -> (stack: Font_Stack, pending: bool) {
	for r in runes {
		if has_codepoint(t, font, r) || ignorable(r) {
			continue
		}
		// A cached face is used as is, unless it's a black and white one
		// for an emoji, which a colour face found since should draw. With
		// no face cached, or NO_FACE or PENDING, the fallback faces found
		// so far may have r now.
		key := fallback_key(font, r)
		face, cached := cached_face(t, key)
		if !cached || face < 0 || emoji_presentation(r) && !t.faces[face].color {
			if found := in_fallbacks(t, font, r); found >= 0 {
				face = found
				cache_face(t, key, face)
			} else if !cached {
				face = fallback_face(t, font, r)
			}
		}
		if face >= 0 {
			stack.needed += {face}
			stack.color_emoji ||= t.faces[face].color && emoji_presentation(r)
		} else if face == PENDING {
			pending = true
		}
	}
	return
}

// kb_shape shapes sh.runes with kb_text_shape into pieces, each running up
// to the next one's first codepoint. If the context runs out of memory or
// meets a bad font it starts over and tries once more; a second failure
// leaves whatever was shaped.
@(private)
kb_shape :: proc(t: ^State, font: Font, size: f32, sh: ^Shaping, stack: Font_Stack, paragraph_rtl: bool) {
	for _ in 0 ..< 2 {
		if kb_shape_once(t, font, size, sh, stack, paragraph_rtl) {
			break
		}
		t.shaper = kbts.PlaceShapeContextFixedMemory(t.shaper_memory)
	}
	pieces := sh.pieces[:]
	for &piece, i in pieces {
		piece.end = max(pieces[i + 1].start if i + 1 < len(pieces) else len(sh.runes), piece.start)
	}
}

// kb_shape_once is one try of kb_shape, from empty. It returns false if
// kb_text_shape reported an error.
@(private)
kb_shape_once :: proc(t: ^State, font: Font, size: f32, sh: ^Shaping, stack: Font_Stack, paragraph_rtl: bool) -> bool {
	clear(&sh.pieces)
	clear(&sh.glyphs)
	clear(&sh.cps)
	ctx := t.shaper
	// The top of the stack wins: the primary font, then the fallbacks,
	// earliest found highest. kb_text_shape takes the first font that has a
	// character, so with an emoji in colour the colour faces go above the
	// rest, or a symbol font found for Hebrew or Arabic would draw it in
	// black and white.
	pushed := 1
	for pass in 0 ..< 2 {
		for i := t.fallback_counts[font] - 1; i >= 0; i -= 1 {
			face := int(t.fallbacks[font][i])
			on_top := stack.color_emoji && t.faces[face].color
			if face in stack.needed && on_top == (pass == 1) {
				_ = kbts.ShapePushFont(ctx, &t.faces[face].kb)
				pushed += 1
			}
		}
	}
	_ = kbts.ShapePushFont(ctx, &t.faces[font].kb)
	kbts.ShapeBegin(ctx, .KBTS_DIRECTION_RTL if paragraph_rtl else .KBTS_DIRECTION_LTR, .DONT_KNOW)
	kbts.ShapeUtf32(ctx, sh.runes)
	kbts.ShapeEnd(ctx)
	for {
		run, ok := kbts.ShapeRun(ctx)
		if !ok {
			break
		}
		face := face_of(t, run.Font)
		native := t.faces[face].native_advances
		piece := Piece{face = face, rtl = run.Direction == .KBTS_DIRECTION_RTL, first = len(sh.glyphs)}
		scale := size / t.faces[face].units_per_em
		x: f32
		for g in kbts.GlyphIteratorNext(&run.Glyphs) {
			advance := f32(g.AdvanceX) * scale
			// A mark's zero advance stays zero.
			if native && g.AdvanceX != 0 {
				advance += cached_advance(t, face, size, g.Id) - default_advance(&t.faces[face], g.Id) * scale
			}
			glyph := Glyph {
				pen     = x,
				advance = advance,
				offset  = {f32(g.OffsetX) * scale, -f32(g.OffsetY) * scale},
				id      = g.Id,
				face    = u8(face),
				space   = is_space(g.Codepoint),
			}
			// With the context API this is always the codepoint index.
			shaping_append(sh, glyph, clamp(int(g.UserIdOrCodepointIndex), 0, len(sh.runes) - 1))
			x += advance
		}
		piece.count = len(sh.glyphs) - piece.first
		piece.width = x
		if piece.count > 0 {
			piece.start = slice.min(sh.cps[piece.first:])
			append(&sh.pieces, piece)
		}
	}
	sh.boundary = nil
	if kbts.ShapeError(ctx) == .NONE && !single_codepoint_graphemes(sh.runes) {
		sh.boundary = make([]bool, len(sh.runes) + 1, context.temp_allocator)
		for i in 1 ..< len(sh.runes) {
			cp: kbts.shape_codepoint
			if kbts.ShapeGetShapeCodepoint(ctx, i32(i), &cp) {
				sh.boundary[i] = .GRAPHEME in cp.BreakFlags
			}
		}
	}
	for _ in 0 ..< pushed {
		_ = kbts.ShapePopFont(ctx)
	}
	return kbts.ShapeError(ctx) == .NONE
}

// coretext_reshape has CoreText shape the pieces in morx-only fonts again.
// Their new glyphs go at the end, and the pieces point there.
@(private)
coretext_reshape :: proc(t: ^State, size: f32, sh: ^Shaping, pending: ^bool) {
	for &piece in sh.pieces {
		if !t.faces[piece.face].coretext_shaping || piece.end <= piece.start {
			continue
		}
		piece.first = len(sh.glyphs)
		piece.width = coretext_shape(t, piece.face, sh, piece.start, piece.end, size, pending)
		piece.count = len(sh.glyphs) - piece.first
	}
}

// bidi_reorder settles each piece's direction and returns the pieces in
// visual order. kb_text_shape gives each run a direction but resolves
// neutrals at the end of the text and brackets around text of the other
// direction wrongly, and has no embedding levels. So spaces and brackets at
// the ends of runs become runs of their own, and resolve_levels redoes the
// neutral and number rules over whole runs.
@(private)
bidi_reorder :: proc(t: ^State, sh: ^Shaping, paragraph_rtl: bool) -> []int {
	peel(t, sh)
	n := len(sh.pieces)
	kinds := make([]Bidi_Kind, n, context.temp_allocator)
	rtl := make([]bool, n, context.temp_allocator)
	brackets := make([]rune, n, context.temp_allocator)
	for piece, i in sh.pieces {
		runes := sh.runes[piece.start:piece.end]
		strong_rtl: bool
		kinds[i], strong_rtl = bidi_kind(runes)
		rtl[i] = strong_rtl if kinds[i] == .Strong else piece.rtl
		if len(runes) == 1 && mirror(runes[0]) != runes[0] {
			brackets[i] = runes[0]
		}
	}
	levels := make([]u8, n, context.temp_allocator)
	resolve_levels(kinds, rtl, brackets, paragraph_rtl, levels)
	for &piece, i in sh.pieces {
		if rtl[i] != piece.rtl {
			piece.rtl = rtl[i]
			flip(t, &piece, sh)
		}
	}
	order := make([]int, n, context.temp_allocator)
	visual_order(levels, order)
	return order
}

// place_pieces lays the pieces out left to right in order, and gives each
// glyph its grapheme cluster.
@(private)
place_pieces :: proc(sh: ^Shaping, order: []int) -> (glyphs: []Glyph, width: f32) {
	clusters := grapheme_starts(sh.runes, sh.boundary)
	out := make([]Glyph, len(sh.glyphs), context.temp_allocator)
	n := 0
	for i in order {
		piece := sh.pieces[i]
		for g, j in sh.glyphs[piece.first:][:piece.count] {
			out[n] = g
			out[n].pen += width
			out[n].cluster = u32(clusters[sh.cps[piece.first + j]])
			n += 1
		}
		width += piece.width
	}
	return out[:n], width
}

// paragraph_is_rtl applies rules P2 and P3 of the Unicode bidi algorithm:
// the paragraph is right to left if its first strong character (L, R or
// AL), skipping text between an isolate initiator and its PDI, is R or AL.
// Without one it is left to right.
paragraph_is_rtl :: proc(runes: []rune) -> bool {
	isolates := 0
	for r in runes {
		switch r {
		case 0x2066 ..= 0x2068: // LRI, RLI, FSI
			isolates += 1
			continue
		case 0x2069: // PDI
			isolates = max(isolates - 1, 0)
			continue
		}
		if isolates > 0 {
			continue
		}
		#partial switch bidi_class(r) {
		case .L:
			return false
		case .R, .AL:
			return true
		}
	}
	return false
}

// bidi_class is r's Unicode bidi class as kb_text_shape's table has it,
// except that the table leaves out the ranges UnicodeData.txt lists as
// First/Last pairs (Han, Hangul syllables, Tangut) and calls them NI. The
// letters there are L.
bidi_class :: proc(r: rune) -> kbts.Bidi_Class {
	class := kbts.bidi_class(r)
	if class == .NI && r >= 0x3400 && unicode.is_letter(r) {
		return .L
	}
	return class
}

// single_codepoint_graphemes is true if every codepoint in runes is sure to
// be a grapheme cluster of its own.
@(private)
single_codepoint_graphemes :: proc(runes: []rune) -> bool {
	for r in runes {
		// Below U+0300 every codepoint but CR LF is a cluster of its own.
		if r >= 0x300 || r == '\r' {
			return false
		}
	}
	return true
}

// grapheme_starts returns, for each codepoint, the index of the first
// codepoint of its grapheme cluster, from kb_text_shape's segmentation:
// boundary, if shaping found it already, or else its break engine.
// It clears the boundaries rule GB11 joins.
grapheme_starts :: proc(runes: []rune, boundary: []bool = nil) -> []int {
	starts := make([]int, len(runes), context.temp_allocator)
	for &start, i in starts {
		start = i
	}
	if len(runes) == 0 || single_codepoint_graphemes(runes) {
		return starts
	}
	boundary := boundary if boundary != nil else grapheme_boundaries(runes)
	// kb_text_shape breaks before the last pictograph of a ZWJ sequence, so
	// 👨‍👩‍👧 came out as 👨‍👩‍ and 👧. Rule GB11 joins them.
	for i in 1 ..< len(runes) {
		if runes[i - 1] == 0x200d && pictographic(runes[i]) {
			boundary[i] = false
		}
	}
	for i in 1 ..< len(runes) {
		if !boundary[i] {
			starts[i] = starts[i - 1]
		}
	}
	return starts
}

// grapheme_boundaries runs kb_text_shape's break engine over runes and
// returns where grapheme clusters start.
@(private)
grapheme_boundaries :: proc(runes: []rune) -> []bool {
	boundary := make([]bool, len(runes) + 1, context.temp_allocator)
	state: kbts.break_state
	kbts.BreakBegin(&state, .DONT_KNOW, .STRICT, {})
	for r, i in runes {
		kbts.BreakAddCodepoint(&state, r, 1, b32(i == len(runes) - 1))
		for b in kbts.Break(&state) {
			if .GRAPHEME in b.Flags && b.Position >= 0 && int(b.Position) <= len(runes) {
				boundary[b.Position] = true
			}
		}
	}
	kbts.BreakEnd(&state)
	for b in kbts.Break(&state) {
		if .GRAPHEME in b.Flags && b.Position >= 0 && int(b.Position) <= len(runes) {
			boundary[b.Position] = true
		}
	}
	return boundary
}

// pictographic approximates Extended_Pictographic: the emoji blocks and the
// older symbol blocks emoji sequences use.
@(private)
pictographic :: proc(r: rune) -> bool {
	switch r {
	case 0x1f000 ..= 0x1faff, 0x2600 ..= 0x27bf, 0x2b00 ..= 0x2bff, 0x2190 ..= 0x21ff, 0x2300 ..= 0x23ff, 0x00a9, 0x00ae, 0x203c, 0x2049, 0x2122, 0x2139, 0x3030, 0x303d, 0x3297, 0x3299:
		return true
	}
	return false
}

// is_space says whether a glyph for r is a space that truncation trims
// and peel splits off: the space, the no-break space and the ideographic
// space.
is_space :: proc(r: rune) -> bool {
	return r == ' ' || r == 0xa0 || r == 0x3000
}

// peel splits spaces and brackets at either logical end of a run into
// one-glyph runs of their own, as long as each is a glyph to itself. The
// split glyphs stay where they are in sh.glyphs.
@(private)
peel :: proc(t: ^State, sh: ^Shaping) {
	peelable :: proc(r: rune) -> bool {
		return is_space(r) || mirror(r) != r
	}
	// edge says whether the glyph at the left or right end of [lo, hi) is
	// codepoint cp's and no other glyph there is.
	edge :: proc(cps: []int, lo, hi, cp: int, at_left: bool) -> bool {
		g, inner := lo, lo + 1
		if !at_left {
			g, inner = hi - 1, hi - 2
		}
		return cps[g] == cp && cps[inner] != cp
	}
	single :: proc(sh: ^Shaping, p: Piece, g, cp: int) -> Piece {
		sh.glyphs[g].pen = 0
		return {face = p.face, rtl = p.rtl, start = cp, end = cp + 1, first = g, count = 1, width = sh.glyphs[g].advance}
	}

	pieces := make([dynamic]Piece, 0, len(sh.pieces), context.temp_allocator)
	runes, cps := sh.runes, sh.cps[:]
	for p in sh.pieces {
		if t.faces[p.face].coretext_shaping {
			append(&pieces, p)
			continue
		}
		// The logical end is on the right in a left-to-right run.
		lo, hi := p.first, p.first + p.count
		start, end := p.start, p.end
		for hi - lo > 1 && end - start > 1 && peelable(runes[end - 1]) && edge(cps, lo, hi, end - 1, p.rtl) {
			if p.rtl {
				lo += 1
			} else {
				hi -= 1
			}
			end -= 1
		}
		for hi - lo > 1 && end - start > 1 && peelable(runes[start]) && edge(cps, lo, hi, start, !p.rtl) {
			if p.rtl {
				hi -= 1
			} else {
				lo += 1
			}
			start += 1
		}
		left, right: f32
		for g in sh.glyphs[p.first:lo] {
			left += g.advance
		}
		for g in sh.glyphs[hi:p.first + p.count] {
			right += g.advance
		}
		for &g in sh.glyphs[lo:hi] {
			g.pen -= left
		}
		// The j-th codepoint peeled from either end is the j-th glyph in
		// from its side.
		for j in 0 ..< start - p.start {
			append(&pieces, single(sh, p, p.first + p.count - 1 - j if p.rtl else p.first + j, p.start + j))
		}
		append(&pieces, Piece{face = p.face, rtl = p.rtl, start = start, end = end, first = lo, count = hi - lo, width = p.width - left - right})
		for j := p.end - end - 1; j >= 0; j -= 1 {
			append(&pieces, single(sh, p, p.first + j if p.rtl else p.first + p.count - 1 - j, p.end - 1 - j))
		}
	}
	sh.pieces = pieces
}

// flip reverses a run of neutrals whose direction resolve_levels changed,
// and swaps brackets for their mirror images or back. Other glyphs keep
// their IDs: CoreText may have merged an emoji sequence into one.
@(private)
flip :: proc(t: ^State, piece: ^Piece, sh: ^Shaping) {
	gs := sh.glyphs[piece.first:][:piece.count]
	cs := sh.cps[piece.first:][:piece.count]
	slice.reverse(gs)
	slice.reverse(cs)
	x: f32
	for &g, i in gs {
		g.pen = x
		x += g.advance
		r := sh.runes[cs[i]]
		if mirror(r) == r {
			continue
		}
		if piece.rtl {
			r = mirror(r)
		}
		if id := kbts.CodepointToGlyphId(&t.faces[g.face].kb, r); id != 0 {
			g.id = u16(id)
		}
	}
}

// mirror returns the bracket that faces the other way, or r.
mirror :: proc(r: rune) -> rune {
	switch r {
	case '(': return ')'
	case ')': return '('
	case '[': return ']'
	case ']': return '['
	case '{': return '}'
	case '}': return '{'
	case '<': return '>'
	case '>': return '<'
	case '«': return '»'
	case '»': return '«'
	}
	return r
}

Bidi_Kind :: enum u8 {
	Strong, // has a strong character (L, R, AL), which sets its direction
	Number, // digits (EN, AN) but nothing strong
	Neutral, // spaces, punctuation, symbols, emoji
	Bracket, // a bracket whose direction N0 settled
}

// bidi_kind classes a run, and for a strong run says whether its first
// strong character is right to left. kb_text_shape's run direction isn't
// used for that: it calls Han and Hangul neutral, so a CJK run next to
// Arabic could come back right to left.
bidi_kind :: proc(runes: []rune) -> (kind: Bidi_Kind, rtl: bool) {
	kind = .Neutral
	for r in runes {
		#partial switch bidi_class(r) {
		case .L:
			return .Strong, false
		case .R, .AL:
			return .Strong, true
		case .EN, .AN:
			kind = .Number
		}
	}
	return kind, false
}

// resolve_levels sets each run's embedding level, and the direction of
// neutral runs, from the runs' kinds and directions (strong runs' own,
// kb_text_shape's for the rest).
// brackets[i] is the bracket a run consists of, or 0. It applies the Unicode
// bidi rules a run at a time:
//   - W7: a number after left-to-right text (or at the start of a
//     left-to-right paragraph) is left-to-right; otherwise it counts as
//     right-to-left to the neutrals around it.
//   - N0: a bracket pair takes the paragraph's direction if the text inside
//     has it, else the other direction if the text inside and the text
//     before the pair both have that.
//   - N1, N2: other neutrals take the direction of the text on both sides
//     if that agrees, else the paragraph's. The paragraph's direction
//     stands in at either end.
//   - I1, I2: right-to-left is level 1; left-to-right is level 0, or 2 in
//     a right-to-left paragraph; numbers after right-to-left text are 2.
// kinds and rtl are changed in place.
resolve_levels :: proc(kinds: []Bidi_Kind, rtl: []bool, brackets: []rune, paragraph_rtl: bool, levels: []u8) {
	// The direction each run shows its neighbours.
	acts_rtl := make([]bool, len(kinds), context.temp_allocator)
	strong_rtl := paragraph_rtl
	for kind, i in kinds {
		#partial switch kind {
		case .Strong:
			strong_rtl = rtl[i]
			acts_rtl[i] = rtl[i]
		case .Number:
			acts_rtl[i] = strong_rtl
			rtl[i] = false
		}
	}

	// N0, pairs in order of their opening bracket.
	Pair :: struct {
		open, close: int,
	}
	pairs := make([dynamic]Pair, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	for b, i in brackets {
		switch b {
		case '(', '[', '{', '<', '«':
			append(&stack, i)
		case ')', ']', '}', '>', '»':
			#reverse for open, depth in stack {
				if mirror(brackets[open]) == b {
					append(&pairs, Pair{open, i})
					resize(&stack, depth)
					break
				}
			}
		}
	}
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.open < b.open})
	for p in pairs {
		same, other := false, false
		for j in p.open + 1 ..< p.close {
			if kinds[j] != .Neutral {
				same |= acts_rtl[j] == paragraph_rtl
				other |= acts_rtl[j] != paragraph_rtl
			}
		}
		if !same && !other {
			continue
		}
		dir := paragraph_rtl
		if !same {
			before := paragraph_rtl
			for j := p.open - 1; j >= 0; j -= 1 {
				if kinds[j] != .Neutral {
					before = acts_rtl[j]
					break
				}
			}
			dir = before
		}
		for i in ([2]int{p.open, p.close}) {
			kinds[i] = .Bracket
			rtl[i] = dir
			acts_rtl[i] = dir
		}
	}

	// N1, N2: after[i] is the direction of the first run past i that isn't
	// neutral.
	after := make([]bool, len(kinds), context.temp_allocator)
	next := paragraph_rtl
	#reverse for kind, i in kinds {
		after[i] = next
		if kind != .Neutral {
			next = acts_rtl[i]
		}
	}
	before := paragraph_rtl
	for kind, i in kinds {
		if kind != .Neutral {
			before = acts_rtl[i]
			continue
		}
		rtl[i] = before if before == after[i] else paragraph_rtl
	}
	for kind, i in kinds {
		switch {
		case kind == .Number:
			levels[i] = 2 if acts_rtl[i] || paragraph_rtl else 0
		case rtl[i]:
			levels[i] = 1
		case:
			levels[i] = 2 if paragraph_rtl else 0
		}
	}
}

// visual_order fills order with run indices left to right, by rule L2 of
// the Unicode bidi algorithm: from the highest level down to 1, reverse
// every stretch of runs at that level or above. Glyphs within a run are
// already in visual order.
visual_order :: proc(levels: []u8, order: []int) {
	top: u8
	for level, i in levels {
		order[i] = i
		top = max(top, level)
	}
	for level := top; level >= 1; level -= 1 {
		for i := 0; i < len(order); {
			if levels[order[i]] < level {
				i += 1
				continue
			}
			j := i
			for j < len(order) && levels[order[j]] >= level {
				j += 1
			}
			slice.reverse(order[i:j])
			i = j
		}
	}
}

// truncate picks the glyphs that fit in max_width with an ellipsis
// ellipsis_width wide at the logical end: the right for a left-to-right
// paragraph, the left for a right-to-left one. It keeps or drops whole
// grapheme clusters, so a mark never outlives its base. Glyphs [first,
// last) stay; draw them shifted right by shift and the ellipsis at
// ellipsis_x. Spaces next to the ellipsis go too. width is the result's
// width.
truncate :: proc(glyphs: []Glyph, run_width, max_width, ellipsis_width: f32, rtl: bool) -> (first, last: int, shift, ellipsis_x, width: f32) {
	if run_width <= max_width + FIT_SLACK {
		return 0, len(glyphs), 0, 0, run_width
	}
	avail := max_width - ellipsis_width
	if !rtl {
		for last < len(glyphs) {
			end := cluster_end(glyphs, last)
			if right_edge(glyphs[last:end]) > avail {
				break
			}
			last = end
		}
		for last > 0 && glyphs[last - 1].space {
			last = cluster_start(glyphs, last - 1)
		}
		ellipsis_x = right_edge(glyphs[:last])
		return 0, last, 0, ellipsis_x, ellipsis_x + ellipsis_width
	}
	cut := run_width - avail
	first = len(glyphs)
	for first > 0 {
		start := cluster_start(glyphs, first - 1)
		if left_edge(glyphs[start:first], run_width) < cut {
			break
		}
		first = start
	}
	for first < len(glyphs) && glyphs[first].space {
		first = cluster_end(glyphs, first)
	}
	start := left_edge(glyphs[first:], run_width)
	shift = ellipsis_width - start
	return first, len(glyphs), shift, 0, ellipsis_width + run_width - start
}

// cluster_end returns the index after the last glyph of glyphs[i]'s cluster.
@(private)
cluster_end :: proc(glyphs: []Glyph, i: int) -> int {
	j := i + 1
	for j < len(glyphs) && glyphs[j].cluster == glyphs[i].cluster {
		j += 1
	}
	return j
}

// cluster_start returns the index of the first glyph of glyphs[i]'s cluster.
@(private)
cluster_start :: proc(glyphs: []Glyph, i: int) -> int {
	j := i
	for j > 0 && glyphs[j - 1].cluster == glyphs[i].cluster {
		j -= 1
	}
	return j
}

@(private)
right_edge :: proc(glyphs: []Glyph) -> (x: f32) {
	for g in glyphs {
		x = max(x, g.pen + g.advance)
	}
	return
}

// left_edge returns the smallest pen in glyphs, or empty if there are none.
@(private)
left_edge :: proc(glyphs: []Glyph, empty: f32) -> f32 {
	x := empty
	for g in glyphs {
		x = min(x, g.pen)
	}
	return x
}

// Fonts

@(private)
face_of :: proc(t: ^State, f: ^kbts.font) -> int {
	for &face, i in t.faces[:t.face_count] {
		if &face.kb == f {
			return i
		}
	}
	return 0
}

@(private)
face_named :: proc(t: ^State, name: u64) -> int {
	for face, i in t.faces[:t.face_count] {
		if face.name == name {
			return i
		}
	}
	return NO_FACE
}

// default_advance is glyph id's advance in the default instance, in font
// units, from the hmtx table. Glyphs past the last entry take its advance.
@(private)
default_advance :: proc(face: ^Face, id: u16) -> f32 {
	i := 4 * min(int(id), face.hmetrics - 1)
	if i < 0 || i + 2 > len(face.hmtx) {
		return 0
	}
	return f32(int(face.hmtx[i]) << 8 | int(face.hmtx[i + 1]))
}

// cached_advance is native_advance in points, from the advances cache when
// it can.
@(private)
cached_advance :: proc(t: ^State, face: int, size: f32, id: u16) -> f32 {
	key := 1 << 63 | u64(face) << 48 | u64(id) << 32
	when ADVANCES_BY_SIZE {
		key |= u64(transmute(u32)size)
	}
	mask := len(t.advances) - 1
	slot := int(mix64(key)) & mask
	for t.advances[slot].key != 0 {
		if t.advances[slot].key == key {
			return t.advances[slot].em * size
		}
		slot = (slot + 1) & mask
	}
	if t.advance_count >= len(t.advances) * 3 / 4 {
		mem.zero_slice(t.advances)
		t.advance_count = 0
		slot = int(mix64(key)) & mask
	}
	em := native_advance(t, face, size, id)
	t.advances[slot] = {key, em}
	t.advance_count += 1
	return em * size
}

// fvar_instance returns the 1-based number of the first named instance in
// font file data whose axis tag is at value, 0 if value is the axis's
// default, or -1 if there's neither. Other axes aren't looked at.
fvar_instance :: proc(data: []byte, tag: string, value: f32) -> int {
	be16 :: proc(data: []byte, at: int) -> int {
		return int(data[at]) << 8 | int(data[at + 1])
	}
	fixed :: proc(data: []byte, at: int) -> f32 {
		return f32(i32(u32(be32(data, at)))) / 65536
	}
	fvar := font_table(data, 0, "fvar")
	if len(fvar) < 16 {
		return -1
	}
	axes, axis_count, axis_size := be16(fvar, 4), be16(fvar, 8), be16(fvar, 10)
	instance_count, instance_size := be16(fvar, 12), be16(fvar, 14)
	instances := axes + axis_count * axis_size
	if instances + instance_count * instance_size > len(fvar) || 4 + 4 * axis_count > instance_size {
		return -1
	}
	for axis in 0 ..< axis_count {
		record := axes + axis * axis_size
		if u32(be32(fvar, record)) != table_tag(tag) {
			continue
		}
		if fixed(fvar, record + 8) == value {
			return 0
		}
		for i in 0 ..< instance_count {
			if fixed(fvar, instances + i * instance_size + 4 + 4 * axis) == value {
				return i + 1
			}
		}
	}
	return -1
}

// file_face_name is the name of face index in the font file at path, for
// the systems that find fallback fonts by file.
@(private)
file_face_name :: proc(path: cstring, index: int) -> u64 {
	return hash.fnv64a(transmute([]byte)string(path)) ~ (u64(index) + 1) * 0x9e37_79b9_7f4a_7c15
}

// font_table returns table tag of face index in the font file data, or nil.
font_table :: proc(data: []byte, index: int, tag: string) -> []byte {
	offset := 0
	if be32(data, 0) == int(table_tag("ttcf")) {
		offset = be32(data, 12 + 4 * index)
	}
	if offset < 0 || offset + 12 > len(data) {
		return nil
	}
	tables := int(data[offset + 4]) << 8 | int(data[offset + 5])
	for j in 0 ..< tables {
		record := offset + 12 + 16 * j
		if be32(data, record) != int(table_tag(tag)) {
			continue
		}
		at, size := be32(data, record + 8), be32(data, record + 12)
		if at < 0 || size < 0 || at + size > len(data) {
			return nil
		}
		return data[at:][:size]
	}
	return nil
}

// table_tag packs a four letter OpenType table tag big-endian, the way
// CTFontCopyTable wants it.
table_tag :: proc(s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

// be32 reads a big-endian u32 at at, or -1 past the end.
@(private)
be32 :: proc(data: []byte, at: int) -> int {
	if at < 0 || at + 4 > len(data) {
		return -1
	}
	return int(data[at]) << 24 | int(data[at + 1]) << 16 | int(data[at + 2]) << 8 | int(data[at + 3])
}

// collection_index_of_table returns the index of the first face in a font
// collection whose table tag equals want, or 0.
collection_index_of_table :: proc(data: []byte, tag: string, want: []byte) -> int {
	for i in 0 ..< be32(data, 8) {
		if table := font_table(data, i, tag); table != nil && mem.compare(table, want) == 0 {
			return i
		}
	}
	return 0
}

@(private)
has_codepoint :: proc(t: ^State, font: Font, r: rune) -> bool {
	if r >= 0x10000 {
		return kbts.CodepointToGlyphId(&t.faces[font].kb, r) != 0
	}
	cell := &t.coverage[font][r >> 2]
	shift := u8(r & 3) * 2
	known := (cell^ >> shift) & 3
	if known == 0 {
		known = 1 if kbts.CodepointToGlyphId(&t.faces[font].kb, r) != 0 else 2
		cell^ |= known << shift
	}
	return known == 1
}

// in_fallbacks returns the first of font's fallback faces that has r, or
// -1. A character usually drawn as an emoji only takes a colour face:
// symbol fonts such as DejaVu Sans have black and white 😀 and ❤ too, so
// without a colour face that has it, it goes to fallback_face, which asks
// the loader once and remembers the answer.
@(private)
in_fallbacks :: proc(t: ^State, font: Font, r: rune) -> int {
	if emoji_presentation(r) {
		for face in t.fallbacks[font][:t.fallback_counts[font]] {
			if t.faces[face].color && kbts.CodepointToGlyphId(&t.faces[face].kb, r) != 0 {
				return int(face)
			}
		}
		return -1
	}
	for face in t.fallbacks[font][:t.fallback_counts[font]] {
		if kbts.CodepointToGlyphId(&t.faces[face].kb, r) != 0 {
			return int(face)
		}
	}
	return -1
}

// emoji_presentation approximates Emoji_Presentation=Yes: the
// pictographic planes, regional indicators, and the older symbol and
// dingbat blocks, where most characters have an emoji in Noto Color Emoji.
@(private)
emoji_presentation :: proc(r: rune) -> bool {
	switch r {
	case 0x1f000 ..= 0x1faff, 0x2600 ..= 0x27bf:
		return true
	}
	return false
}

// fallback_face returns the fallback face for r under font: a face index,
// NO_FACE if no font has it, or PENDING while the loader looks. The first
// time it asks the loader.
@(private)
fallback_face :: proc(t: ^State, font: Font, r: rune) -> int {
	key := fallback_key(font, r)
	if face, ok := cached_face(t, key); ok {
		return face
	}
	// Without an entry to record the answer in, the loader's result would
	// be lost and the character asked for again on every reshape.
	if !fallback_room(t) {
		return NO_FACE
	}
	if load_request(&t.loader, {font = font, codepoint = r}) {
		cache_face(t, key, PENDING)
	}
	return PENDING
}

// take_loaded adds the faces the loader found to the font table and the
// fallback cache, and moves the generation on so pending runs reshape.
@(private)
take_loaded :: proc(t: ^State) {
	results: [LOAD_RESULTS]Load_Result
	n := take_results(&t.loader, &results)
	for &res in results[:n] {
		face := NO_FACE
		if res.found != 0 {
			face = face_named(t, res.found)
			if face < 0 && res.loaded && t.face_count < MAX_FACES {
				face = t.face_count
				t.faces[face] = res.face
				t.face_count += 1
				res.loaded = false
			}
		}
		if res.loaded {
			free_face(&res.face)
		}
		if res.ct != nil {
			cache_face(t, font_key(res.name), face)
			font_ref_release(res.ct)
			continue
		}
		// CoreText hands back the font itself (or another weight of it) when
		// nothing has the character.
		if face < len(Font) {
			face = NO_FACE
		}
		// font_stack may have found the character in a fallback face while
		// the loader looked. Runs already use that face, so it stays.
		key := fallback_key(res.font, res.codepoint)
		if cached, ok := cached_face(t, key); !ok || cached < 0 {
			cache_face(t, key, face)
		}
		list := &t.fallbacks[res.font]
		if face >= 0 && !slice.contains(list[:t.fallback_counts[res.font]], u8(face)) {
			list[t.fallback_counts[res.font]] = u8(face)
			t.fallback_counts[res.font] += 1
		}
	}
	if n > 0 {
		t.generation += 1
	}
}

@(private)
fallback_key :: proc(font: Font, r: rune) -> u64 {
	return (u64(font) + 1) << 32 | u64(r)
}

@(private)
font_key :: proc(name: u64) -> u64 {
	return name | 1 << 63
}

@(private)
cached_face :: proc(t: ^State, key: u64) -> (int, bool) {
	slot, found := fallback_slot(t, key)
	return int(t.fallback_cache[slot].face), found
}

// cache_face records face for key. A new key goes in only if fallback_room
// finds room, which fails only when malloc does.
@(private)
cache_face :: proc(t: ^State, key: u64, face: int) {
	slot, found := fallback_slot(t, key)
	if !found {
		if !fallback_room(t) {
			return
		}
		slot, _ = fallback_slot(t, key)
		t.fallback_used += 1
	}
	t.fallback_cache[slot] = {key, i8(face)}
}

// fallback_room makes sure the fallback cache can take one more key,
// doubling it once it's three quarters full. False if it can't grow.
@(private)
fallback_room :: proc(t: ^State) -> bool {
	if t.fallback_used < len(t.fallback_cache) * 3 / 4 {
		return true
	}
	n := 2 * len(t.fallback_cache)
	table := ([^]Fallback)(libc.calloc(uint(n), size_of(Fallback)))
	if table == nil {
		return false
	}
	old := t.fallback_cache
	t.fallback_cache = table[:n]
	for entry in old {
		if entry.key != 0 {
			slot, _ := fallback_slot(t, entry.key)
			t.fallback_cache[slot] = entry
		}
	}
	libc.free(raw_data(old))
	return true
}

@(private)
fallback_slot :: proc(t: ^State, key: u64) -> (int, bool) {
	mask := len(t.fallback_cache) - 1
	slot := int(mix64(key)) & mask
	for t.fallback_cache[slot].key != 0 {
		if t.fallback_cache[slot].key == key {
			return slot, true
		}
		slot = (slot + 1) & mask
	}
	return slot, false
}

// ignorable is true for characters that draw nothing on their own, so a
// missing glyph for them needs no fallback font.
@(private)
ignorable :: proc(r: rune) -> bool {
	switch r {
	case 0 ..< 0x20, 0x7f ..= 0x9f, 0x200b ..= 0x200f, 0x202a ..= 0x202e, 0x2060 ..= 0x2069, 0xfe00 ..= 0xfe0f, 0xfeff, 0xe0000 ..= 0xe0fff:
		return true
	}
	return false
}
