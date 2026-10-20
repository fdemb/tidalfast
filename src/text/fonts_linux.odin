package text

// fontconfig and FreeType behind the text code. The text font is the
// built-in Noto Sans. fontconfig finds fallback fonts on the loader thread; FreeType rasterizes glyphs for the atlas on
// the UI thread. Faces load into kb_text_shape on the loader as on macOS,
// and get their FreeType face on the UI thread the first time a glyph is
// drawn, so FreeType is only ever used from one thread.
//
// Glyphs are rasterized from their outlines unhinted, at the exact
// subpixel offset asked for, with plain grayscale antialiasing, which is
// what CoreText does with font smoothing off. Colour bitmap fonts (Noto
// Color Emoji) are scaled down from their nearest strike. There is no
// CoreText shaping: every font goes through kb_text_shape.

import "core:c"
import "core:hash"
import "core:math"
import "core:sys/posix"

import "../kbts"

foreign import freetype "system:freetype"
foreign import fontconfig "system:fontconfig"
foreign import libc_mincore "system:c"

// The loader never takes a font by reference on Linux, so this stays nil.
Font_Ref :: rawptr

FT_Library :: rawptr
FT_Error :: c.int

FT_Bitmap_Size :: struct {
	height, width:         i16,
	size, x_ppem, y_ppem: c.long, // 26.6
}

FT_Bitmap :: struct {
	rows, width:  u32,
	pitch:        i32,
	buffer:       [^]u8,
	num_grays:    u16,
	pixel_mode:   u8,
	palette_mode: u8,
	palette:      rawptr,
}
#assert(size_of(FT_Bitmap) == 40)

FT_Outline :: struct {
	n_contours, n_points: u16,
	points:               rawptr,
	tags:                 rawptr,
	contours:             rawptr,
	flags:                c.int,
}
#assert(size_of(FT_Outline) == 40)

FT_BBox :: struct {
	x_min, y_min, x_max, y_max: c.long,
}

// The start of FT_FaceRec and FT_GlyphSlotRec, up to the fields used here,
// at the offsets FreeType 2 has had since 2.1.
FT_FaceRec :: struct {
	num_faces, face_index, face_flags, style_flags, num_glyphs: c.long,
	family_name, style_name:                                     cstring,
	num_fixed_sizes:                                             c.int,
	available_sizes:                                             [^]FT_Bitmap_Size,
	_:                                                           [80]u8,
	glyph:                                                       ^FT_GlyphSlotRec,
}
#assert(offset_of(FT_FaceRec, available_sizes) == 64 && offset_of(FT_FaceRec, glyph) == 152)

FT_GlyphSlotRec :: struct {
	_:           [144]u8,
	format:      u32,
	_:           u32,
	bitmap:      FT_Bitmap,
	bitmap_left: c.int,
	bitmap_top:  c.int,
	outline:     FT_Outline,
}
#assert(offset_of(FT_GlyphSlotRec, bitmap) == 152 && offset_of(FT_GlyphSlotRec, outline) == 200)

FT_FACE_FLAG_FIXED_SIZES :: 1 << 1
FT_LOAD_NO_SCALE :: 1 << 0
FT_FACE_FLAG_COLOR :: 1 << 14
FT_LOAD_NO_HINTING :: 1 << 1
FT_LOAD_NO_BITMAP :: 1 << 3
FT_LOAD_COLOR :: 1 << 20
FT_GLYPH_FORMAT_OUTLINE :: 0x6f75_746c // 'outl'
FT_GLYPH_FORMAT_BITMAP :: 0x6269_7473 // 'bits'
FT_PIXEL_MODE_GRAY :: 2
FT_PIXEL_MODE_BGRA :: 7

@(default_calling_convention = "c")
foreign freetype {
	FT_Init_FreeType :: proc(library: ^FT_Library) -> FT_Error ---
	FT_Done_FreeType :: proc(library: FT_Library) -> FT_Error ---
	FT_New_Memory_Face :: proc(library: FT_Library, base: [^]u8, size: c.long, face_index: c.long, face: ^^FT_FaceRec) -> FT_Error ---
	FT_Done_Face :: proc(face: ^FT_FaceRec) -> FT_Error ---
	FT_Set_Char_Size :: proc(face: ^FT_FaceRec, width, height: c.long, h_res, v_res: c.uint) -> FT_Error ---
	FT_Select_Size :: proc(face: ^FT_FaceRec, strike: c.int) -> FT_Error ---
	FT_Load_Glyph :: proc(face: ^FT_FaceRec, glyph_index: c.uint, load_flags: i32) -> FT_Error ---
	FT_Get_Advance :: proc(face: ^FT_FaceRec, glyph_index: c.uint, load_flags: i32, advance: ^c.long) -> FT_Error ---
	FT_Outline_Get_CBox :: proc(outline: ^FT_Outline, box: ^FT_BBox) ---
	FT_Outline_Translate :: proc(outline: ^FT_Outline, dx, dy: c.long) ---
	FT_Outline_Get_Bitmap :: proc(library: FT_Library, outline: ^FT_Outline, bitmap: ^FT_Bitmap) -> FT_Error ---
}

FcPattern :: rawptr
FcCharSet :: rawptr

FcFontSet :: struct {
	nfont, sfont: c.int,
	fonts:        [^]FcPattern,
}

FC_MATCH_PATTERN :: 0
FC_RESULT_MATCH :: 0

@(default_calling_convention = "c")
foreign fontconfig {
	FcPatternCreate :: proc() -> FcPattern ---
	FcPatternDestroy :: proc(p: FcPattern) ---
	FcPatternAddCharSet :: proc(p: FcPattern, object: cstring, cs: FcCharSet) -> b32 ---
	FcPatternAddInteger :: proc(p: FcPattern, object: cstring, i: c.int) -> b32 ---
	FcPatternAddString :: proc(p: FcPattern, object: cstring, s: cstring) -> b32 ---
	FcPatternGetString :: proc(p: FcPattern, object: cstring, n: c.int, s: ^cstring) -> c.int ---
	FcPatternGetInteger :: proc(p: FcPattern, object: cstring, n: c.int, i: ^c.int) -> c.int ---
	FcPatternGetCharSet :: proc(p: FcPattern, object: cstring, n: c.int, cs: ^FcCharSet) -> c.int ---
	FcCharSetCreate :: proc() -> FcCharSet ---
	FcCharSetDestroy :: proc(cs: FcCharSet) ---
	FcCharSetAddChar :: proc(cs: FcCharSet, ucs4: u32) -> b32 ---
	FcCharSetHasChar :: proc(cs: FcCharSet, ucs4: u32) -> b32 ---
	FcConfigSubstitute :: proc(config: rawptr, p: FcPattern, kind: c.int) -> b32 ---
	FcDefaultSubstitute :: proc(p: FcPattern) ---
	FcFontSort :: proc(config: rawptr, p: FcPattern, trim: b32, csp: ^FcCharSet, result: ^c.int) -> ^FcFontSet ---
	FcFontSetDestroy :: proc(s: ^FcFontSet) ---
}

@(default_calling_convention = "c")
foreign libc_mincore {
	@(private)
	mincore :: proc(addr: rawptr, length: uint, vec: [^]u8) -> i32 ---
}

// Face_Native is a face's FreeType side, made on the UI thread by
// face_ft the first time the atlas needs it.
Face_Native :: struct {
	index:     int, // in a collection, with a variable font's named instance in the high bits
	ft:        ^FT_FaceRec,
	ft_failed: bool,
	ft_size:   f32, // the pixel size last set on ft
}

// Raster is the FreeType library, and the glyph last loaded into a face's
// slot, so rasterize after glyph_box doesn't load it again.
Raster :: struct {
	library:     FT_Library,
	loaded_face: ^FT_FaceRec,
	loaded_id:   u16,
	loaded_size: f32,
}

@(private)
raster_init :: proc(r: ^Raster) {
	if FT_Init_FreeType(&r.library) != 0 {
		r.library = nil
	}
}

@(private)
raster_destroy :: proc(r: ^Raster) {
	if r.library != nil {
		FT_Done_FreeType(r.library)
	}
	r^ = {}
}

@(private)
font_ref_release :: proc(ref: Font_Ref) {}

// FC_WEIGHTS are fontconfig's weights for each font, for its fallbacks.
@(private)
FC_WEIGHTS := [Font]c.int {
	.Regular   = 80,
	.Medium    = 100,
	.Semibold  = 180,
	.Bold      = 200,
	.Icon      = 200,
	.Icon_Fill = 200,
}

// NOTO_SANS is the text font: Noto Sans as one variable font, with
// Regular, Medium, SemiBold and Bold as named instances. Distributions
// differ in which Noto Sans weights they install, if any, so it's built in.
// tools/noto.sh takes it from Noto's release.
@(private)
NOTO_SANS := #load("../../assets/fonts/NotoSans-Variable.ttf")

// NOTO_WEIGHTS are the wght of each font's named instance.
@(private)
NOTO_WEIGHTS := #partial [Font]f32 {
	.Regular  = 400,
	.Medium   = 500,
	.Semibold = 600,
	.Bold     = 700,
}

// load_system loads the built-in Noto Sans at font's weight. The weights
// share its bytes and kb_text_shape tables, which hold the default
// instance, so the others get their advances from FreeType, which
// FT_New_Memory_Face gives the instance.
@(private)
load_system :: proc(t: ^State, font: Font) -> bool {
	instance := fvar_instance(NOTO_SANS, "wght", NOTO_WEIGHTS[font])
	if instance < 0 {
		return false
	}
	face := &t.faces[font]
	if font == .Regular {
		if !load_embedded(t, font, NOTO_SANS) {
			return false
		}
	} else {
		face^ = t.faces[Font.Regular]
		face.native = {}
		face.blob = nil
		face.name = hash.fnv64a(transmute([]byte)FONT_NAMES[font])
	}
	face.index = instance << 16
	face.native_advances = instance > 0 && face.hmetrics > 0
	return true
}

// file_face_name is the name of face index in the font file at path.
@(private)
file_face_name :: proc(path: cstring, index: int) -> u64 {
	return hash.fnv64a(transmute([]byte)string(path)) ~ (u64(index) + 1) * 0x9e37_79b9_7f4a_7c15
}

// load_embedded loads one of the built-in faces from its #load data. A
// debug build, which hot reload may replace, takes a copy; a release build
// reads the image's bytes in place, as on macOS.
@(private)
load_embedded :: proc(t: ^State, font: Font, data: []byte) -> bool {
	data := data
	when ODIN_DEBUG {
		copied := make([]byte, len(data))
		copy(copied, data)
		data = copied
	}
	face := &t.faces[font]
	if !load_face(face, nil, data, 0, false) {
		return false
	}
	face.name = hash.fnv64a(transmute([]byte)FONT_NAMES[font])
	return true
}

@(private)
FONT_NAMES := [Font]string {
	.Regular   = "Noto Sans Regular",
	.Medium    = "Noto Sans Medium",
	.Semibold  = "Noto Sans SemiBold",
	.Bold      = "Noto Sans Bold",
	.Icon      = "Phosphor Bold",
	.Icon_Fill = "Phosphor Fill",
}

// face_native_init notes which face of a collection this is and whether
// it's a colour bitmap font. The FreeType face comes later, on the UI
// thread.
@(private)
face_native_init :: proc(face: ^Face, ct: Font_Ref, index: int) -> bool {
	if face.units_per_em == 0 {
		return false
	}
	face.index = index
	face.color = font_table(face.file, index, "CBDT") != nil || font_table(face.file, index, "sbix") != nil
	return true
}

@(private)
face_native_free :: proc(face: ^Face) {
	if face.ft != nil {
		FT_Done_Face(face.ft)
	}
}

// load finds a fallback font with the request's character, the way
// fontconfig orders them for a sans-serif face of the font's weight, and
// loads the first whose cmap (as kb_text_shape reads it) has it.
@(private)
load :: proc(l: ^Loader, req: Load_Request) -> (res: Load_Result) {
	res.request = req
	r := req.codepoint
	pattern := FcPatternCreate()
	defer FcPatternDestroy(pattern)
	charset := FcCharSetCreate()
	defer FcCharSetDestroy(charset)
	FcCharSetAddChar(charset, u32(r))
	FcPatternAddCharSet(pattern, "charset", charset)
	// Fontconfig ranks fonts by family before coverage, so a symbol font
	// like DejaVu Sans would win 😀 with a black and white glyph. Ask for
	// the emoji family for characters drawn as emoji by default.
	FcPatternAddString(pattern, "family", "emoji" if emoji_presentation(r) else "sans-serif")
	FcPatternAddInteger(pattern, "weight", FC_WEIGHTS[req.font])
	FcConfigSubstitute(nil, pattern, FC_MATCH_PATTERN)
	FcDefaultSubstitute(pattern)
	result: c.int
	set := FcFontSort(nil, pattern, true, nil, &result)
	if set == nil {
		return
	}
	defer FcFontSetDestroy(set)
	for font in set.fonts[:set.nfont] {
		cs: FcCharSet
		if FcPatternGetCharSet(font, "charset", 0, &cs) != FC_RESULT_MATCH || !FcCharSetHasChar(cs, u32(r)) {
			continue
		}
		file: cstring
		index: c.int
		if FcPatternGetString(font, "file", 0, &file) != FC_RESULT_MATCH {
			continue
		}
		FcPatternGetInteger(font, "index", 0, &index)
		// The high bits name an instance of a variable font; kb_text_shape
		// reads the default one.
		if known_or_load(l, file, int(index) & 0xffff, r, &res) {
			return
		}
	}
	return
}

// known_or_load finds the face at index of the file at path among the
// known ones, or maps the file and loads it into kb_text_shape. A face
// whose cmap (as kb_text_shape reads it) lacks need counts as a failure.
@(private)
known_or_load :: proc(l: ^Loader, path: cstring, index: int, need: rune, res: ^Load_Result) -> bool {
	name := file_face_name(path, index)
	for &k in l.known[:l.known_count] {
		if k.name == name {
			if kbts.CodepointToGlyphId(&k.kb, need) == 0 {
				return false
			}
			res.found = name
			return true
		}
	}
	if l.known_count == MAX_FACES {
		return false
	}
	data, ok := map_file(path)
	if !ok {
		return false
	}
	face: Face
	if !load_face(&face, nil, data, index, true, need) {
		posix.munmap(raw_data(data), uint(len(data)))
		return false
	}
	face.name = name
	l.known[l.known_count] = {name, face.kb}
	l.known_count += 1
	res.found = name
	res.face = face
	res.loaded = true
	return true
}

// coretext_shape never runs on Linux: no face has coretext_shaping set.
@(private)
coretext_shape :: proc(t: ^State, face: int, sh: ^Shaping, start, end: int, size: f32, pending: ^bool) -> f32 {
	return 0
}

// native_advance is glyph id's advance in the face's instance at size, in
// points, from FreeType, which applies the instance's HVAR or gvar.
@(private)
native_advance :: proc(t: ^State, face: int, size: f32, id: u16) -> f32 {
	f := &t.faces[face]
	ft := face_ft(&t.atlas, f)
	units: c.long
	if ft == nil || FT_Get_Advance(ft, c.uint(id), FT_LOAD_NO_SCALE, &units) != 0 {
		return default_advance(f, id) * size / f.units_per_em
	}
	// Without HVAR it loads the glyph into the slot load_glyph remembers.
	t.atlas.raster.loaded_face = nil
	return f32(units) * size / f.units_per_em
}

// face_ft returns the face's FreeType face, making it the first time.
@(private)
face_ft :: proc(a: ^Atlas, face: ^Face) -> ^FT_FaceRec {
	if face.ft == nil && !face.ft_failed && a.raster.library != nil {
		if FT_New_Memory_Face(a.raster.library, raw_data(face.file), c.long(len(face.file)), c.long(face.index), &face.ft) != 0 {
			face.ft = nil
			face.ft_failed = true
		}
	}
	return face.ft
}

// load_glyph loads glyph at px_size into the face's slot: its outline, or
// for a colour bitmap font the BGRA bitmap of the strike nearest above
// px_size, with scale from strike pixels to px_size pixels.
@(private)
load_glyph :: proc(a: ^Atlas, face: ^Face, px_size: f32, glyph: u16) -> (slot: ^FT_GlyphSlotRec, scale: f64, ok: bool) {
	ft := face_ft(a, face)
	if ft == nil {
		return
	}
	scale = 1
	strike_ppem: f64
	if face.color && ft.face_flags & FT_FACE_FLAG_FIXED_SIZES != 0 && ft.num_fixed_sizes > 0 {
		// The smallest strike at least px_size, else the largest.
		want := c.long(px_size * 64)
		best := 0
		for i in 1 ..< int(ft.num_fixed_sizes) {
			ppem, current := ft.available_sizes[i].y_ppem, ft.available_sizes[best].y_ppem
			if current >= want ? (ppem >= want && ppem < current) : ppem > current {
				best = i
			}
		}
		strike_ppem = f64(ft.available_sizes[best].y_ppem) / 64
		scale = f64(px_size) / strike_ppem
	}
	r := &a.raster
	if r.loaded_face == ft && r.loaded_id == glyph && r.loaded_size == px_size {
		return ft.glyph, scale, true
	}
	r.loaded_face = nil
	if face.ft_size != px_size {
		err: FT_Error
		if strike_ppem > 0 {
			for i in 0 ..< int(ft.num_fixed_sizes) {
				if f64(ft.available_sizes[i].y_ppem) / 64 == strike_ppem {
					err = FT_Select_Size(ft, c.int(i))
					break
				}
			}
		} else {
			err = FT_Set_Char_Size(ft, 0, c.long(math.round(px_size * 64)), 72, 72)
		}
		if err != 0 {
			return
		}
		face.ft_size = px_size
	}
	flags: i32 = FT_LOAD_COLOR if strike_ppem > 0 else FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP
	if FT_Load_Glyph(ft, c.uint(glyph), flags) != 0 {
		return
	}
	r.loaded_face, r.loaded_id, r.loaded_size = ft, glyph, px_size
	return ft.glyph, scale, true
}

// glyph_box is the glyph's ink at px_size in pixels from the pen on the
// baseline, y up: left, bottom, right, top. Empty for a glyph with none.
// size matters only on macOS.
@(private)
glyph_box :: proc(a: ^Atlas, face: ^Face, px_size, size: f32, glyph: u16) -> [4]f64 {
	slot, scale, ok := load_glyph(a, face, px_size, glyph)
	if !ok {
		return {}
	}
	switch slot.format {
	case FT_GLYPH_FORMAT_OUTLINE:
		if slot.outline.n_points == 0 {
			return {}
		}
		box: FT_BBox
		FT_Outline_Get_CBox(&slot.outline, &box)
		return {f64(box.x_min) / 64, f64(box.y_min) / 64, f64(box.x_max) / 64, f64(box.y_max) / 64}
	case FT_GLYPH_FORMAT_BITMAP:
		b := slot.bitmap
		if b.pixel_mode != FT_PIXEL_MODE_BGRA || b.width == 0 || b.rows == 0 {
			return {}
		}
		left, top := f64(slot.bitmap_left), f64(slot.bitmap_top)
		return {left * scale, (top - f64(b.rows)) * scale, (left + f64(b.width)) * scale, top * scale}
	}
	return {}
}

// rasterize draws one glyph at px_size with its origin at origin (pixels
// from the bitmap's bottom left) and returns the w by h bitmap, top row
// first, in context.temp_allocator: coverage bytes, or premultiplied BGRA
// for colour. size, the text's size in points, matters only on macOS.
@(private)
rasterize :: proc(a: ^Atlas, face: ^Face, px_size, size: f32, glyph: u16, w, h: int, origin: [2]f64) -> []byte {
	bpp := 4 if face.color else 1
	out := make([]byte, w * h * bpp, context.temp_allocator)
	slot, scale, ok := load_glyph(a, face, px_size, glyph)
	if !ok {
		return out
	}
	if slot.format == FT_GLYPH_FORMAT_OUTLINE {
		if face.color {
			return out
		}
		dx, dy := c.long(math.round(origin.x * 64)), c.long(math.round(origin.y * 64))
		FT_Outline_Translate(&slot.outline, dx, dy)
		target := FT_Bitmap {
			rows       = u32(h),
			width      = u32(w),
			pitch      = i32(w),
			buffer     = raw_data(out),
			num_grays  = 256,
			pixel_mode = FT_PIXEL_MODE_GRAY,
		}
		FT_Outline_Get_Bitmap(a.raster.library, &slot.outline, &target)
		FT_Outline_Translate(&slot.outline, -dx, -dy)
		return out
	}
	if slot.format != FT_GLYPH_FORMAT_BITMAP || slot.bitmap.pixel_mode != FT_PIXEL_MODE_BGRA || !face.color {
		return out
	}
	// Box filter from the strike: each output pixel averages the strike
	// pixels whose centres fall inside it, in premultiplied BGRA.
	b := slot.bitmap
	src_w, src_h := int(b.width), int(b.rows)
	// The bitmap's top left, in output pixels from the output's bottom left.
	x0 := origin.x + f64(slot.bitmap_left) * scale
	y0 := origin.y + f64(slot.bitmap_top) * scale
	for row in 0 ..< h {
		// Output row 0 is the top; its y range in output pixels, y up.
		top := f64(h - row)
		for col in 0 ..< w {
			sx0 := int(math.ceil((f64(col) - x0) / scale - 0.5))
			sx1 := int(math.ceil((f64(col + 1) - x0) / scale - 0.5))
			sy0 := int(math.ceil((y0 - top) / scale - 0.5))
			sy1 := int(math.ceil((y0 - top + 1) / scale - 0.5))
			sum: [4]u32
			n: u32
			for sy in max(sy0, 0) ..< min(sy1, src_h) {
				line := b.buffer[sy * int(b.pitch):]
				for sx in max(sx0, 0) ..< min(sx1, src_w) {
					for k in 0 ..< 4 {
						sum[k] += u32(line[sx * 4 + k])
					}
				}
			}
			n = u32(max(sx1 - sx0, 1) * max(sy1 - sy0, 1))
			for k in 0 ..< 4 {
				out[(row * w + col) * 4 + k] = u8((sum[k] + n / 2) / n)
			}
		}
	}
	return out
}
