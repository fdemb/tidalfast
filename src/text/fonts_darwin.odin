package text

// CoreText and CoreGraphics behind the text code: the system font and the
// icon faces from memory, fallback fonts that CTFontCreateForString and a search of the
// installed fonts find, CoreText shaping for morx-only fonts, and glyph
// bounds and bitmaps for the atlas.

import "core:hash"
import "core:slice"
import "core:strings"
import "core:sys/posix"

import "../../third_party/kbts"

SIZED_FONTS :: 16
SCRATCH_SIZE :: 256 // glyphs bigger than this get their own bitmap context

// Font_Ref is a CTFontRef. The loader takes one in a request for a font
// CoreText picked while shaping.
Font_Ref :: CTFontRef

// Face_Native is a face's CoreText side: the font at BASE_SIZE and the last
// few sizes the shaper and the atlas asked for.
Face_Native :: struct {
	ct:         CTFontRef, // at BASE_SIZE
	sized:      [SIZED_FONTS]Sized_Font,
	sized_next: int,
}

Sized_Font :: struct {
	size:    f32,
	optical: f32, // the optical size it's pinned to, or 0 for CoreText's pick
	font:    CTFontRef,
}

// Raster is the atlas's scratch bitmaps.
Raster :: struct {
	srgb:          CGColorSpaceRef,
	scratch:       CGContextRef, // SCRATCH_SIZE square, alpha only
	color_scratch: CGContextRef, // SCRATCH_SIZE square, BGRA
}

@(private)
raster_init :: proc(r: ^Raster) {
	r.srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
	r.scratch = bitmap_context(r, false, SCRATCH_SIZE, SCRATCH_SIZE)
	r.color_scratch = bitmap_context(r, true, SCRATCH_SIZE, SCRATCH_SIZE)
}

@(private)
raster_destroy :: proc(r: ^Raster) {
	CGContextRelease(r.scratch)
	CGContextRelease(r.color_scratch)
	CGColorSpaceRelease(r.srgb)
}

@(private)
font_ref_release :: proc(ref: Font_Ref) {
	cf_release(ref)
}

// SYSTEM_WEIGHTS are the kCTFontWeightTrait values of NSFontWeightRegular,
// Medium, Semibold and Bold.
@(private)
SYSTEM_WEIGHTS := #partial [Font]CGFloat {
	.Regular  = 0,
	.Medium   = 0.23,
	.Semibold = 0.3,
	.Bold     = 0.4,
}

// load_system loads the system UI font, SF Pro, at font's weight. The
// weights are instances of one variable font, so the faces share its
// mapped file and kb_text_shape tables.
@(private)
load_system :: proc(t: ^State, font: Font) -> bool {
	base := CTFontCreateUIFontForLanguage(CT_FONT_UI_FONT_SYSTEM, BASE_SIZE, nil)
	if base == nil {
		return false
	}
	defer cf_release(base)
	weight := SYSTEM_WEIGHTS[font]
	number := CFNumberCreate(nil, CF_NUMBER_CGFLOAT_TYPE, &weight)
	defer cf_release(number)
	trait_keys := [1]rawptr{kCTFontWeightTrait}
	trait_values := [1]rawptr{number}
	traits := CFDictionaryCreate(nil, &trait_keys[0], &trait_values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer cf_release(traits)
	keys := [1]rawptr{kCTFontTraitsAttribute}
	values := [1]rawptr{traits}
	attrs := CFDictionaryCreate(nil, &keys[0], &values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer cf_release(attrs)
	desc := CTFontDescriptorCreateWithAttributes(attrs)
	defer cf_release(desc)
	ct := CTFontCreateCopyWithAttributes(base, BASE_SIZE, nil, desc)
	if ct == nil {
		return false
	}
	defer cf_release(ct)

	path: [1024]u8
	if !font_path(ct, path[:]) {
		return false
	}
	face := &t.faces[font]
	shared := false
	for &other in t.faces[:int(font)] {
		other_path: [1024]u8
		if font_path(other.ct, other_path[:]) && string(cstring(&other_path[0])) == string(cstring(&path[0])) && kbts.FontCount(other.file) == 1 {
			face^ = other
			face.native = {}
			face.mapped = false
			face.blob = nil
			if !face_native_init(face, ct, 0) {
				return false
			}
			shared = true
			break
		}
	}
	if !shared {
		data, ok := map_file(cstring(&path[0]))
		if !ok {
			return false
		}
		index := collection_index(data, ct) if kbts.FontCount(data) > 1 else 0
		if !load_face(face, ct, data, index, true) {
			posix.munmap(raw_data(data), uint(len(data)))
			return false
		}
	}
	// The instance's metrics rather than the default one's.
	face.ascent = f32(CTFontGetAscent(face.ct)) / BASE_SIZE
	face.descent = f32(CTFontGetDescent(face.ct)) / BASE_SIZE
	t.loader.primary[font] = face.ct
	return true
}

// load_embedded loads one of the built-in faces from its #load data.
// CoreText and kb_text_shape read the executable's bytes in place.
@(private)
load_embedded :: proc(t: ^State, font: Font, data: []byte) -> bool {
	cf_data := CFDataCreateWithBytesNoCopy(nil, raw_data(data), len(data), kCFAllocatorNull)
	desc := CTFontManagerCreateFontDescriptorFromData(cf_data)
	ct := CTFontCreateWithFontDescriptor(desc, BASE_SIZE, nil)
	cf_release(desc)
	cf_release(cf_data)
	face := &t.faces[font]
	ok := ct != nil && load_face(face, ct, data, 0, false)
	cf_release(ct)
	if ok {
		t.loader.primary[font] = face.ct
	}
	return ok
}

// face_native_init keeps a copy of ct at BASE_SIZE for rasterizing and
// reads what kb_text_shape doesn't say about the face.
@(private)
face_native_init :: proc(face: ^Face, ct: Font_Ref, index: int) -> bool {
	if face.units_per_em == 0 {
		face.units_per_em = f32(CTFontGetUnitsPerEm(ct))
		face.ascent = f32(CTFontGetAscent(ct)) / BASE_SIZE
		face.descent = f32(CTFontGetDescent(ct)) / BASE_SIZE
	}
	face.ct = CTFontCreateCopyWithAttributes(ct, BASE_SIZE, nil, nil)
	face.name = font_name_hash(ct)
	face.color = CTFontGetSymbolicTraits(ct) & CT_FONT_COLOR_GLYPHS_TRAIT != 0
	face.coretext_shaping = !font_has_table(ct, "GSUB") && font_has_table(ct, "morx")
	face.native_advances = face.hmetrics > 0 && font_has_table(ct, "fvar")
	return true
}

@(private)
face_native_free :: proc(face: ^Face) {
	cf_release(face.ct)
	for s in face.sized {
		cf_release(s.font)
	}
}

@(private)
load :: proc(l: ^Loader, req: Load_Request) -> (res: Load_Result) {
	res.request = req
	if req.ct != nil {
		known_or_load(l, req.ct, -1, &res)
		return
	}
	r := req.codepoint
	str := CFStringCreateWithBytes(nil, ([^]u8)(&r), 4, CF_STRING_ENCODING_UTF32LE, false)
	defer cf_release(str)
	ct := CTFontCreateForString(l.primary[req.font], str, {0, CFStringGetLength(str)})
	found := ct != nil && known_or_load(l, ct, r, &res)
	cf_release(ct)
	// kb_text_shape reads a different cmap subtable than CoreText in some
	// fonts (Lucida Grande has Hebrew, but not to kb_text_shape), so if
	// CoreText's pick doesn't work, look through every font that has r.
	if !found {
		search_fallback(l, req.font, str, r, &res)
	}
	return
}

// known_or_load finds the face behind ct among the known ones, or loads it:
// maps the font's file, picks the face in a collection whose name table
// matches, and loads it into kb_text_shape. With need set, a face whose cmap
// (as kb_text_shape reads it) lacks need counts as a failure.
@(private)
known_or_load :: proc(l: ^Loader, ct: CTFontRef, need: rune, res: ^Load_Result) -> bool {
	name := font_name_hash(ct)
	for &k in l.known[:l.known_count] {
		if k.name == name {
			if need >= 0 && kbts.CodepointToGlyphId(&k.kb, need) == 0 {
				return false
			}
			res.found = name
			return true
		}
	}
	if l.known_count == MAX_FACES {
		return false
	}
	path: [1024]u8
	if !font_path(ct, path[:]) {
		return false
	}
	data, ok := map_file(cstring(&path[0]))
	if !ok {
		return false
	}
	index := 0
	if kbts.FontCount(data) > 1 {
		index = collection_index(data, ct)
	}
	face: Face
	if !load_face(&face, ct, data, index, true, need) {
		posix.munmap(raw_data(data), uint(len(data)))
		return false
	}
	if need >= 0 {
		warm_face(&face, need)
	}
	l.known[l.known_count] = {name, face.kb}
	l.known_count += 1
	res.found = name
	res.face = face
	res.loaded = true
	return true
}

// search_fallback tries the installed fonts that have r, best first:
// upright, bold if font is, and from /System/Library/Fonts before the
// Supplemental folder.
@(private)
search_fallback :: proc(l: ^Loader, font: Font, str: CFStringRef, r: rune, res: ^Load_Result) -> bool {
	charset := CFCharacterSetCreateWithCharactersInString(nil, str)
	defer cf_release(charset)
	keys := [1]rawptr{kCTFontCharacterSetAttribute}
	values := [1]rawptr{charset}
	attrs := CFDictionaryCreate(nil, &keys[0], &values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer cf_release(attrs)
	desc := CTFontDescriptorCreateWithAttributes(attrs)
	defer cf_release(desc)
	descs := [1]rawptr{desc}
	array := CFArrayCreate(nil, &descs[0], 1, &kCFTypeArrayCallBacks)
	defer cf_release(array)
	collection := CTFontCollectionCreateWithFontDescriptors(array, nil)
	defer cf_release(collection)
	matches := CTFontCollectionCreateMatchingFontDescriptors(collection)
	defer cf_release(matches)
	if matches == nil {
		return false
	}

	Candidate :: struct {
		font:  CTFontRef,
		score: int,
	}
	candidates := make([dynamic]Candidate, context.temp_allocator)
	defer for c in candidates {
		cf_release(c.font)
	}
	want_bold := CTFontGetSymbolicTraits(l.primary[font]) & CT_FONT_BOLD_TRAIT != 0
	for i in 0 ..< CFArrayGetCount(matches) {
		ct := CTFontCreateWithFontDescriptor(CFArrayGetValueAtIndex(matches, i), BASE_SIZE, nil)
		traits := CTFontGetSymbolicTraits(ct)
		score := 0
		if traits & CT_FONT_ITALIC_TRAIT == 0 {
			score += 4
		}
		if (traits & CT_FONT_BOLD_TRAIT != 0) == want_bold {
			score += 2
		}
		path: [1024]u8
		if font_path(ct, path[:]) && !strings.contains(string(cstring(&path[0])), "/Supplemental/") {
			score += 1
		}
		append(&candidates, Candidate{ct, score})
	}
	slice.stable_sort_by(candidates[:], proc(a, b: Candidate) -> bool {return a.score > b.score})
	for c in candidates {
		if known_or_load(l, c.font, r, res) {
			return true
		}
	}
	return false
}

// warm_face lays out and draws r once in a newly loaded face, on the
// loader thread, so the first use of the font costs the main thread less.
// Measured on an M1: the first line CoreText lays out in Geeza Pro takes
// 3.8 ms and later ones 30 to 200 us at any size. The first Apple Color
// Emoji glyph drawn takes 6 ms, and after this about 2.3 ms; the rest is
// decoding that glyph's bitmap, which every emoji glyph pays.
@(private)
warm_face :: proc(face: ^Face, r: rune) {
	if face.coretext_shaping {
		r := r
		str := CFStringCreateWithBytes(nil, ([^]u8)(&r), 4, CF_STRING_ENCODING_UTF32LE, false)
		defer cf_release(str)
		keys := [1]rawptr{kCTFontAttributeName}
		values := [1]rawptr{face.ct}
		attrs := CFDictionaryCreate(nil, &keys[0], &values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
		defer cf_release(attrs)
		attributed := CFAttributedStringCreate(nil, str, attrs)
		defer cf_release(attributed)
		cf_release(CTLineCreateWithAttributedString(attributed))
	}
	glyph := CGGlyph(kbts.CodepointToGlyphId(&face.kb, r))
	if glyph == 0 {
		return
	}
	SIZE :: 64
	ctx: CGContextRef
	if face.color {
		space := CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
		defer CGColorSpaceRelease(space)
		ctx = CGBitmapContextCreate(nil, SIZE, SIZE, 8, SIZE * 4, space, CG_BITMAP_BGRA_PREMULTIPLIED)
	} else {
		ctx = CGBitmapContextCreate(nil, SIZE, SIZE, 8, SIZE, nil, CG_IMAGE_ALPHA_ONLY)
	}
	if ctx == nil {
		return
	}
	defer CGContextRelease(ctx)
	pos := CGPoint{8, 16}
	CTFontDrawGlyphs(face.ct, &glyph, &pos, 1, ctx)
}

// font_path writes the path of ct's file into buf, NUL-terminated.
@(private)
font_path :: proc(ct: CTFontRef, buf: []u8) -> bool {
	url := CTFontCopyAttribute(ct, kCTFontURLAttribute)
	defer cf_release(url)
	return url != nil && CFURLGetFileSystemRepresentation(url, true, raw_data(buf), len(buf))
}

// collection_index returns the index of the face in a .ttc whose name
// table is byte for byte the one CoreText reports for ct, or 0.
collection_index :: proc(data: []byte, ct: CTFontRef) -> int {
	name := CTFontCopyTable(ct, table_tag("name"), 0)
	defer cf_release(name)
	if name == nil {
		return 0
	}
	want := CFDataGetBytePtr(name)[:CFDataGetLength(name)]
	return collection_index_of_table(data, table_tag("name"), want)
}

@(private)
font_name_hash :: proc(ct: CTFontRef) -> u64 {
	name := CTFontCopyPostScriptName(ct)
	defer cf_release(name)
	buf: [256]u8
	return hash.fnv64a(transmute([]byte)cf_string(name, buf[:]))
}

// run_font_face returns the face for a font CoreText picked for part of a
// run, by its name hash, asking the loader for it the first time.
@(private)
run_font_face :: proc(t: ^State, ct: CTFontRef, name: u64) -> int {
	if face := face_named(t, name); face >= 0 {
		return face
	}
	key := font_key(name)
	if face, ok := cached_face(t, key); ok {
		return face
	}
	if !fallback_room(t) {
		return NO_FACE
	}
	CFRetain(ct)
	if !load_request(&t.loader, {ct = ct, name = name}) {
		cf_release(ct)
		return PENDING
	}
	cache_face(t, key, PENDING)
	return PENDING
}

// sized_font returns face's CTFont at size, keeping the last few. With
// optical above 0 its optical size is pinned there, else CoreText sets it
// to size.
@(private)
sized_font :: proc(face: ^Face, size: f32, optical: f32 = 0) -> CTFontRef {
	for s in face.sized {
		if s.font != nil && s.size == size && s.optical == optical {
			return s.font
		}
	}
	slot := &face.sized[face.sized_next]
	face.sized_next = (face.sized_next + 1) % SIZED_FONTS
	cf_release(slot.font)
	desc: CTFontDescriptorRef
	if optical > 0 {
		value := CGFloat(optical)
		number := CFNumberCreate(nil, CF_NUMBER_CGFLOAT_TYPE, &value)
		keys := [1]rawptr{kCTFontOpticalSizeAttribute}
		values := [1]rawptr{number}
		attrs := CFDictionaryCreate(nil, &keys[0], &values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
		desc = CTFontDescriptorCreateWithAttributes(attrs)
		cf_release(attrs)
		cf_release(number)
	}
	slot^ = {size, optical, CTFontCreateCopyWithAttributes(face.ct, CGFloat(size), nil, desc)}
	cf_release(desc)
	return slot.font
}

// raster_font is face's CTFont for drawing at px_size pixels for text
// size points. A variable font's optical size would follow px_size, which
// on a 2x screen picks the design for text twice the size, so it's pinned
// to size.
@(private)
raster_font :: proc(face: ^Face, px_size, size: f32) -> CTFontRef {
	return sized_font(face, px_size, size if face.native_advances else 0)
}

// SF Pro's optical size axis changes its advances with the point size, so
// cached advances are kept per size.
ADVANCES_BY_SIZE :: true

// native_advance is glyph id's advance in the face's instance at size, in
// em.
@(private)
native_advance :: proc(t: ^State, face: int, size: f32, id: u16) -> f32 {
	glyph := CGGlyph(id)
	advance: CGSize
	CTFontGetAdvancesForGlyphs(sized_font(&t.faces[face], size), 0, &glyph, &advance, 1)
	return f32(advance.width) / size
}

// coretext_shape shapes sh.runes[start:end], all one direction and one
// script, with CoreText in face at size, and appends the glyphs to sh in
// visual order. Glyphs CoreText takes from a font
// still loading are left blank (ID 0) and set pending. Returns the width in
// points.
@(private)
coretext_shape :: proc(t: ^State, face: int, sh: ^Shaping, start, end: int, size: f32, pending: ^bool) -> f32 {
	font := sized_font(&t.faces[face], size)
	runes := sh.runes
	str := CFStringCreateWithBytes(nil, ([^]u8)(raw_data(runes[start:])), (end - start) * 4, CF_STRING_ENCODING_UTF32LE, false)
	defer cf_release(str)
	keys := [1]rawptr{kCTFontAttributeName}
	values := [1]rawptr{font}
	attrs := CFDictionaryCreate(nil, &keys[0], &values[0], 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	defer cf_release(attrs)
	attributed := CFAttributedStringCreate(nil, str, attrs)
	defer cf_release(attributed)
	line := CTLineCreateWithAttributedString(attributed)
	defer cf_release(line)

	// CoreText reports UTF-16 indices into str.
	rune_at := make([dynamic]int, 0, 2 * (end - start), context.temp_allocator)
	for r, i in runes[start:end] {
		append(&rune_at, start + i)
		if r >= 0x10000 {
			append(&rune_at, start + i)
		}
	}

	Placed :: struct {
		glyph: Glyph,
		cp:    int,
	}
	placed := make([dynamic]Placed, context.temp_allocator)
	width: f32
	runs := CTLineGetGlyphRuns(line)
	for i in 0 ..< CFArrayGetCount(runs) {
		run := CFArrayGetValueAtIndex(runs, i)
		n := CTRunGetGlyphCount(run)
		ids := make([]CGGlyph, n, context.temp_allocator)
		positions := make([]CGPoint, n, context.temp_allocator)
		advances := make([]CGSize, n, context.temp_allocator)
		indices := make([]CFIndex, n, context.temp_allocator)
		CTRunGetGlyphs(run, {}, raw_data(ids))
		CTRunGetPositions(run, {}, raw_data(positions))
		CTRunGetAdvances(run, {}, raw_data(advances))
		CTRunGetStringIndices(run, {}, raw_data(indices))
		run_face := face
		if run_font := CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName); run_font != nil && !CFEqual(run_font, font) {
			run_face = run_font_face(t, run_font, font_name_hash(run_font))
			if run_face == PENDING {
				pending^ = true
			}
		}
		for j in 0 ..< n {
			g := Glyph{pen = f32(positions[j].x), advance = f32(advances[j].width), offset = {0, -f32(positions[j].y)}, id = ids[j], face = u8(face)}
			if run_face >= 0 {
				g.face = u8(run_face)
			} else {
				g.id = 0
			}
			cp := rune_at[clamp(indices[j], 0, len(rune_at) - 1)]
			g.space = is_space(runes[cp])
			append(&placed, Placed{g, cp})
			width = max(width, f32(positions[j].x + advances[j].width))
		}
	}
	slice.stable_sort_by(placed[:], proc(a, b: Placed) -> bool {return a.glyph.pen < b.glyph.pen})
	for p in placed {
		shaping_append(sh, p.glyph, p.cp)
	}
	return width
}

// bitmap_context makes a CGBitmapContext for glyphs: grayscale
// antialiasing, font smoothing off (it only works on opaque contexts and
// thickens stems; the renderer blending coverage in linear light adds some
// weight back instead), and glyph origins kept at the exact subpixel offset
// asked for rather than quantized by CoreGraphics.
@(private)
bitmap_context :: proc(r: ^Raster, color: bool, w, h: int) -> CGContextRef {
	ctx: CGContextRef
	if color {
		ctx = CGBitmapContextCreate(nil, uint(w), uint(h), 8, uint(w * 4), r.srgb, CG_BITMAP_BGRA_PREMULTIPLIED)
	} else {
		ctx = CGBitmapContextCreate(nil, uint(w), uint(h), 8, uint(w), nil, CG_IMAGE_ALPHA_ONLY)
	}
	CGContextSetAllowsAntialiasing(ctx, true)
	CGContextSetShouldAntialias(ctx, true)
	CGContextSetAllowsFontSmoothing(ctx, false)
	CGContextSetShouldSmoothFonts(ctx, false)
	CGContextSetAllowsFontSubpixelPositioning(ctx, true)
	CGContextSetShouldSubpixelPositionFonts(ctx, true)
	CGContextSetAllowsFontSubpixelQuantization(ctx, false)
	CGContextSetShouldSubpixelQuantizeFonts(ctx, false)
	CGContextSetGrayFillColor(ctx, 1, 1)
	return ctx
}


// rasterize draws one glyph at px_size, for text size points, with its
// origin at origin (pixels from the bitmap's bottom left) and returns the w
// by h bitmap, top row first, in context.temp_allocator: coverage bytes, or
// premultiplied BGRA for colour.
@(private)
rasterize :: proc(a: ^Atlas, face: ^Face, px_size, size: f32, glyph: u16, w, h: int, origin: [2]f64) -> []byte {
	font := raster_font(face, px_size, size)
	color := face.color
	ctx := a.raster.color_scratch if color else a.raster.scratch
	ctx_h := SCRATCH_SIZE
	own := w > SCRATCH_SIZE || h > SCRATCH_SIZE
	if own {
		ctx = bitmap_context(&a.raster, color, w, h)
		ctx_h = h
	}
	defer if own {
		CGContextRelease(ctx)
	}
	bpp := 4 if color else 1
	stride := (w if own else SCRATCH_SIZE) * bpp

	CGContextClearRect(ctx, {{0, 0}, {CGFloat(w), CGFloat(h)}})
	glyph := glyph
	at := CGPoint{origin.x, origin.y}
	CTFontDrawGlyphs(font, &glyph, &at, 1, ctx)

	// The bitmap's first row is its top, so the w by h corner CoreGraphics
	// drew into (origin bottom left) is its last h rows.
	data := CGBitmapContextGetData(ctx)
	out := make([]byte, w * h * bpp, context.temp_allocator)
	for row in 0 ..< h {
		copy(out[row * w * bpp:][:w * bpp], data[(ctx_h - h + row) * stride:][:w * bpp])
	}
	return out
}

// glyph_box is the glyph's ink at px_size, for text size points, in pixels
// from the pen on the baseline, y up: left, bottom, right, top. Empty for a
// glyph with none.
@(private)
glyph_box :: proc(a: ^Atlas, face: ^Face, px_size, size: f32, glyph: u16) -> [4]f64 {
	font := raster_font(face, px_size, size)
	glyph := glyph
	bounds: CGRect
	CTFontGetBoundingRectsForGlyphs(font, 0, &glyph, &bounds, 1)
	if bounds.size.width <= 0 || bounds.size.height <= 0 {
		return {}
	}
	return {bounds.origin.x, bounds.origin.y, bounds.origin.x + bounds.size.width, bounds.origin.y + bounds.size.height}
}

foreign import system "system:System.framework"

@(default_calling_convention = "c")
foreign system {
	@(private)
	mincore :: proc(addr: rawptr, length: uint, vec: [^]u8) -> i32 ---
}
