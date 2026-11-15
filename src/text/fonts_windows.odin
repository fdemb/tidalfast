package text

// DirectWrite behind the text code on Windows: the system UI font, the icon
// faces from memory, fallback fonts from DirectWrite's system font
// fallback, and glyph bounds and bitmaps for the atlas. kb_text_shape
// shapes every font; DirectWrite never does.
//
// The text font is Segoe UI Variable, Windows 11's UI font, made at each
// font's weight and, as on macOS, at the optical size of the text it draws.
// Windows 10 has the older Segoe UI as separate files, without a Medium.
//
// Glyphs are drawn with grayscale antialiasing in DirectWrite's natural
// symmetric mode, at the exact subpixel offset asked for, and hinted as the
// font's gasp table says. Segoe UI Emoji's colour layers (COLR) are
// composited from the layers DirectWrite hands back.

import "core:hash"
import "core:log"
import "core:mem"
import "core:strings"
import "core:sys/windows"
import "core:time"

import "../../third_party/kbts"
import "../sys"

SIZED_FONTS :: 16

// The loader never takes a font by reference here, so requests leave it
// nil. A face is loaded with the IDWriteFontFace it came from.
Font_Ref :: ^IDWriteFontFace

// Face_Native is a face's DirectWrite side. A face of the system's
// variable font keeps its resource, to make instances at other optical
// sizes.
Face_Native :: struct {
	dw:         ^IDWriteFontFace,
	file_name:  u64, // file_face_name of its file and index
	resource:   ^IDWriteFontResource,
	weight:     f32,
	opsz:       DWRITE_FONT_AXIS_RANGE, // its tag is 0 without an optical size axis
	sized:      [SIZED_FONTS]Sized_Face,
	sized_next: int,
}

Sized_Face :: struct {
	opsz: f32,
	face: ^IDWriteFontFace,
}

Raster :: struct {
	factory:     ^IDWriteFactory, // IDWriteFactory5, or 6 if factory6
	factory6:    bool,
	memory:      ^IDWriteInMemoryFontFileLoader, // registered with factory
	fallback:    ^IDWriteFontFallback,
	system:      ^IDWriteFontResource, // Segoe UI Variable
	system_opsz: DWRITE_FONT_AXIS_RANGE,
	t_analysis, t_bounds, t_texture, t_color, t_sized: time.Duration, // TEMP
	n_analysis: int, // TEMP
}

// Loader_Native is what the loader thread asks the fallback with.
Loader_Native :: struct {
	fallback: ^IDWriteFontFallback, // the atlas's, which outlives the loader
	locale:   [windows.LOCALE_NAME_MAX_LENGTH]u16,
}

// SYSTEM_WEIGHTS are each font's wght in Segoe UI Variable.
@(private)
SYSTEM_WEIGHTS := #partial [Font]f32 {
	.Regular  = 400,
	.Medium   = 500,
	.Semibold = 600,
	.Bold     = 700,
}

// STATIC_WEIGHTS are the weights asked of a font family with separate
// files. Segoe UI has no Medium, so it's Semibold.
@(private)
STATIC_WEIGHTS := [Font]u32 {
	.Regular   = 400,
	.Medium    = 600,
	.Semibold  = 600,
	.Bold      = 700,
	.Icon      = 700,
	.Icon_Fill = 700,
}

// FALLBACK_WEIGHTS are the weights the fallback matches for each font.
@(private)
FALLBACK_WEIGHTS := [Font]u32 {
	.Regular   = 400,
	.Medium    = 500,
	.Semibold  = 600,
	.Bold      = 700,
	.Icon      = 700,
	.Icon_Fill = 700,
}

// STATIC_FAMILIES are tried in order when there's no Segoe UI Variable.
// Wine has Tahoma.
@(private)
STATIC_FAMILIES := [?]string{"Segoe UI", "Tahoma", "Arial"}

@(private)
ICON_NAMES := #partial [Font]string {
	.Icon      = "Phosphor Bold",
	.Icon_Fill = "Phosphor Fill",
}

@(private)
raster_init :: proc(r: ^Raster) {
	unknown: ^IUnknown
	if DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory6, &unknown) >= 0 {
		r.factory6 = true
	} else if DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory5, &unknown) < 0 {
		return
	}
	r.factory = (^IDWriteFactory)(unknown)
	if r.factory->CreateInMemoryFontFileLoader(&r.memory) < 0 {
		r.memory = nil
	} else if r.factory->RegisterFontFileLoader(r.memory) < 0 {
		release(r.memory)
		r.memory = nil
	}
	if r.factory->GetSystemFontFallback(&r.fallback) < 0 {
		r.fallback = nil
	}
}

@(private)
raster_destroy :: proc(r: ^Raster) {
	release(r.system)
	release(r.fallback)
	if r.memory != nil {
		r.factory->UnregisterFontFileLoader(r.memory)
		release(r.memory)
	}
	release(r.factory)
	r^ = {}
}

@(private)
font_ref_release :: proc(ref: Font_Ref) {
	release(ref)
}

// load_system loads the system UI font at font's weight: an instance of
// Segoe UI Variable, or Segoe UI's file for the weight. Faces of one file
// share its mapping and kb_text_shape tables.
@(private)
load_system :: proc(t: ^State, font: Font) -> bool {
	r := &t.atlas.raster
	if r.factory == nil {
		return false
	}
	if font == .Regular {
		l := &t.loader.native
		l.fallback = r.fallback
		if GetUserDefaultLocaleName(&l.locale[0], len(l.locale)) == 0 {
			copy(l.locale[:], []u16{'e', 'n', '-', 'U', 'S', 0})
		}
		r.system, r.system_opsz = variable_system_font(r)
	}
	ff: ^IDWriteFontFace
	if r.system != nil {
		axes := [1]DWRITE_FONT_AXIS_VALUE{{axis_tag("wght"), SYSTEM_WEIGHTS[font]}}
		if r.system->CreateFontFace(DWRITE_FONT_SIMULATIONS_NONE, &axes[0], 1, &ff) < 0 {
			ff = nil
		}
	}
	variable := ff != nil
	family := "Segoe UI Variable"
	for name in STATIC_FAMILIES {
		if ff != nil {
			break
		}
		ff = family_font(r, name, STATIC_WEIGHTS[font])
		family = name
	}
	if ff == nil {
		log.errorf("text: no %v system font", font)
		return false
	}
	if font == .Regular {
		log.infof("text: %s", family)
	}
	defer release(ff)
	path, index, ok := face_path(ff)
	if !ok {
		return false
	}
	file := file_face_name(path, index)
	face := &t.faces[font]
	shared := false
	for &other in t.faces[:int(font)] {
		if other.file_name == file {
			face^ = other
			face.native = {}
			face.mapped = false
			face.blob = nil
			if !face_native_init(face, ff, index) {
				return false
			}
			shared = true
			break
		}
	}
	if !shared {
		data, mapped := sys.map_file(path)
		if !mapped {
			return false
		}
		if !load_face(face, ff, data, index, true) {
			sys.unmap_file(data)
			return false
		}
	}
	face.file_name = file
	face.name = file + u64(font)
	if variable {
		r.system->AddRef()
		face.resource = r.system
		face.weight = SYSTEM_WEIGHTS[font]
		face.opsz = r.system_opsz
	}
	// The instance's metrics rather than the default one's.
	metrics: DWRITE_FONT_METRICS
	ff->GetMetrics(&metrics)
	if metrics.designUnitsPerEm > 0 {
		face.ascent = f32(metrics.ascent) / f32(metrics.designUnitsPerEm)
		face.descent = f32(metrics.descent) / f32(metrics.designUnitsPerEm)
	}
	return true
}

// variable_system_font finds Segoe UI Variable, with its optical size axis
// if it has one. Nil without IDWriteFactory6, which makes instances.
@(private)
variable_system_font :: proc(r: ^Raster) -> (resource: ^IDWriteFontResource, opsz: DWRITE_FONT_AXIS_RANGE) {
	if !r.factory6 {
		return
	}
	ff := family_font(r, "Segoe UI Variable Text", 400)
	if ff == nil {
		return
	}
	defer release(ff)
	count: u32 = 1
	file: ^IDWriteFontFile
	if ff->GetFiles(&count, ([^]^IDWriteFontFile)(&file)) < 0 || file == nil {
		return
	}
	defer release(file)
	if r.factory->CreateFontResource(file, ff->GetIndex(), &resource) < 0 {
		return nil, {}
	}
	ranges: [8]DWRITE_FONT_AXIS_RANGE
	n := min(int(resource->GetFontAxisCount()), len(ranges))
	has_weight := false
	if resource->HasVariations() && resource->GetFontAxisRanges(&ranges[0], u32(n)) >= 0 {
		for axis in ranges[:n] {
			switch axis.axisTag {
			case axis_tag("wght"):
				has_weight = true
			case axis_tag("opsz"):
				opsz = axis
			}
		}
	}
	if !has_weight {
		release(resource)
		return nil, {}
	}
	return
}

// family_font is the face of the installed font family name that best
// matches weight, or nil.
@(private)
family_font :: proc(r: ^Raster, name: string, weight: u32) -> ^IDWriteFontFace {
	collection: ^IDWriteFontCollection
	if r.factory->GetSystemFontCollection(&collection, false) < 0 {
		return nil
	}
	defer release(collection)
	index: u32
	exists: windows.BOOL
	wide := windows.utf8_to_wstring(name, context.temp_allocator)
	if collection->FindFamilyName(wide, &index, &exists) < 0 || !exists {
		return nil
	}
	family: ^IDWriteFontFamily
	if collection->GetFontFamily(index, &family) < 0 {
		return nil
	}
	defer release(family)
	font: ^IDWriteFont
	if family->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, &font) < 0 {
		return nil
	}
	defer release(font)
	ff: ^IDWriteFontFace
	if font->CreateFontFace(&ff) < 0 {
		return nil
	}
	return ff
}

// face_path is the path of the file behind ff, in context.temp_allocator,
// and ff's index in it. False for a face that isn't one local file.
@(private)
face_path :: proc(ff: ^IDWriteFontFace) -> (path: cstring, index: int, ok: bool) {
	count: u32
	if ff->GetFiles(&count, nil) < 0 || count != 1 {
		return
	}
	file: ^IDWriteFontFile
	if ff->GetFiles(&count, ([^]^IDWriteFontFile)(&file)) < 0 || file == nil {
		return
	}
	defer release(file)
	key: rawptr
	key_size: u32
	if file->GetReferenceKey(&key, &key_size) < 0 {
		return
	}
	loader: ^IUnknown
	if file->GetLoader(&loader) < 0 {
		return
	}
	defer release(loader)
	local: ^IDWriteLocalFontFileLoader
	if loader->QueryInterface(&IID_IDWriteLocalFontFileLoader, (^rawptr)(&local)) < 0 {
		return
	}
	defer release(local)
	n: u32
	if local->GetFilePathLengthFromKey(key, key_size, &n) < 0 {
		return
	}
	wide := make([]u16, n + 1, context.temp_allocator)
	if local->GetFilePathFromKey(key, key_size, raw_data(wide), n + 1) < 0 {
		return
	}
	utf8, err := windows.utf16_to_utf8(wide[:n], context.temp_allocator)
	if err != nil {
		return
	}
	return strings.clone_to_cstring(utf8, context.temp_allocator), int(ff->GetIndex()), true
}

// load_embedded loads one of the built-in faces from its #load data, which
// DirectWrite and kb_text_shape read in place.
@(private)
load_embedded :: proc(t: ^State, font: Font, data: []byte) -> bool {
	r := &t.atlas.raster
	if r.memory == nil {
		return false
	}
	file: ^IDWriteFontFile
	if r.memory->CreateInMemoryFontFileReference(r.factory, raw_data(data), u32(len(data)), &STATIC_OWNER, &file) < 0 {
		return false
	}
	defer release(file)
	ff: ^IDWriteFontFace
	if r.factory->CreateFontFace(DWRITE_FONT_FACE_TYPE_TRUETYPE, 1, ([^]^IDWriteFontFile)(&file), 0, DWRITE_FONT_SIMULATIONS_NONE, &ff) < 0 {
		return false
	}
	defer release(ff)
	face := &t.faces[font]
	if !load_face(face, ff, data, 0, false) {
		return false
	}
	face.name = hash.fnv64a(transmute([]byte)ICON_NAMES[font])
	return true
}

// face_native_init keeps ct, the face DirectWrite draws with, and reads
// what kb_text_shape doesn't say about the face. A colour font with only
// bitmaps (CBDT, sbix) is refused, since only COLR layers are drawn in
// colour, and the fallback goes on.
@(private)
face_native_init :: proc(face: ^Face, ct: Font_Ref, index: int) -> bool {
	if ct == nil || face.units_per_em == 0 {
		return false
	}
	has :: proc(face: ^Face, index: int, tag: string) -> bool {
		return font_table(face.file, index, tag) != nil
	}
	if (has(face, index, "CBDT") || has(face, index, "sbix")) && !has(face, index, "glyf") && !has(face, index, "CFF ") && !has(face, index, "CFF2") {
		return false
	}
	face.color = has(face, index, "COLR") && has(face, index, "CPAL")
	face.native_advances = face.hmetrics > 0 && has(face, index, "fvar")
	ct->AddRef()
	face.dw = ct
	return true
}

@(private)
face_native_free :: proc(face: ^Face) {
	release(face.dw)
	release(face.resource)
	for s in face.sized {
		release(s.face)
	}
}

// load finds a fallback font with the request's character through
// DirectWrite's system font fallback, in the user's locale, and loads it.
@(private)
load :: proc(l: ^Loader, req: Load_Request) -> (res: Load_Result) {
	res.request = req
	fallback := l.native.fallback
	if fallback == nil {
		return
	}
	source := Analysis_Source {
		vtable = &ANALYSIS_SOURCE_VTABLE,
		locale = &l.native.locale[0],
	}
	r := req.codepoint
	if r >= 0x10000 {
		source.text = {u16(0xd800 + ((r - 0x10000) >> 10)), u16(0xdc00 + ((r - 0x10000) & 0x3ff))}
		source.length = 2
	} else {
		source.text[0] = u16(r)
		source.length = 1
	}
	mapped_length: u32
	font: ^IDWriteFont
	scale: f32
	hr := fallback->MapCharacters(&source, 0, source.length, nil, windows.L("Segoe UI"), FALLBACK_WEIGHTS[req.font], DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, &mapped_length, &font, &scale)
	if hr < 0 || font == nil {
		return
	}
	defer release(font)
	ff: ^IDWriteFontFace
	if font->CreateFontFace(&ff) < 0 {
		return
	}
	defer release(ff)
	known_or_load(l, ff, r, &res)
	return
}

// known_or_load finds the face behind ff among the known ones, or maps its
// file and loads it into kb_text_shape. A face whose cmap (as kb_text_shape
// reads it) lacks need counts as a failure.
@(private)
known_or_load :: proc(l: ^Loader, ff: ^IDWriteFontFace, need: rune, res: ^Load_Result) -> bool {
	path, index, ok := face_path(ff)
	if !ok {
		return false
	}
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
	data, mapped := sys.map_file(path)
	if !mapped {
		return false
	}
	face: Face
	if !load_face(&face, ff, data, index, true, need) {
		sys.unmap_file(data)
		return false
	}
	face.name = name
	face.file_name = name
	l.known[l.known_count] = {name, face.kb}
	l.known_count += 1
	res.found = name
	res.face = face
	res.loaded = true
	return true
}

// coretext_shape never runs here: no face has coretext_shaping set.
@(private)
coretext_shape :: proc(t: ^State, face: int, sh: ^Shaping, start, end: int, size: f32, pending: ^bool) -> f32 {
	return 0
}

// Segoe UI Variable's optical size axis changes its advances with the
// point size, so cached advances are kept per size.
ADVANCES_BY_SIZE :: true

// native_advance is glyph id's advance in the face's instance at size, in
// em.
@(private)
native_advance :: proc(t: ^State, face: int, size: f32, id: u16) -> f32 {
	f := &t.faces[face]
	id := id
	metrics: DWRITE_GLYPH_METRICS
	if sized_face(f, size)->GetDesignGlyphMetrics(&id, 1, &metrics, false) < 0 {
		return default_advance(f, id) / f.units_per_em
	}
	return f32(metrics.advanceWidth) / f.units_per_em
}

// sized_face is face's instance for text size points: at that optical
// size, within the axis's range, for a face of the system's variable font,
// else the face itself. The last few are kept.
@(private)
sized_face :: proc(face: ^Face, size: f32) -> ^IDWriteFontFace {
	if face.resource == nil || face.opsz.axisTag == 0 {
		return face.dw
	}
	opsz := clamp(size, face.opsz.minValue, face.opsz.maxValue)
	for s in face.sized {
		if s.face != nil && s.opsz == opsz {
			return s.face
		}
	}
	slot := &face.sized[face.sized_next]
	face.sized_next = (face.sized_next + 1) % SIZED_FONTS
	release(slot.face)
	slot^ = {}
	axes := [2]DWRITE_FONT_AXIS_VALUE{{axis_tag("wght"), face.weight}, {axis_tag("opsz"), opsz}}
	if face.resource->CreateFontFace(DWRITE_FONT_SIMULATIONS_NONE, &axes[0], len(axes), &slot.face) < 0 {
		slot.face = nil
		return face.dw
	}
	slot.opsz = opsz
	return slot.face
}

// glyph_run is a run of one glyph at px_size, in face's instance for text
// size points.
@(private)
glyph_run :: proc(face: ^Face, px_size, size: f32, glyph: ^u16) -> DWRITE_GLYPH_RUN {
	return {fontFace = sized_face(face, size), fontEmSize = px_size, glyphCount = 1, glyphIndices = glyph}
}

// glyph_analysis is DirectWrite's coverage of run with its pen at x, y in
// pixels from a bitmap's top left, and the coverage's bounds.
@(private)
glyph_analysis :: proc(r: ^Raster, run: ^DWRITE_GLYPH_RUN, x, y: f32) -> (analysis: ^IDWriteGlyphRunAnalysis, bounds: windows.RECT) {
	t0 := time.tick_now()
	if r.factory->CreateGlyphRunAnalysis(run, nil, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_DEFAULT, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, x, y, &analysis) < 0 {
		return nil, {}
	}
	r.t_analysis += time.tick_since(t0)
	r.n_analysis += 1
	t0 = time.tick_now()
	defer r.t_bounds += time.tick_since(t0)
	if analysis->GetAlphaTextureBounds(DWRITE_TEXTURE_ALIASED_1x1, &bounds) < 0 {
		release(analysis)
		return nil, {}
	}
	return
}

// color_layers are the colour layers of run with its pen at x, y, or nil
// for a glyph without any.
@(private)
color_layers :: proc(r: ^Raster, run: ^DWRITE_GLYPH_RUN, x, y: f32) -> ^IDWriteColorGlyphRunEnumerator {
	layers: ^IDWriteColorGlyphRunEnumerator
	t0 := time.tick_now()
	defer r.t_color += time.tick_since(t0)
	if r.factory->TranslateColorGlyphRun(x, y, run, nil, DWRITE_MEASURING_MODE_NATURAL, nil, 0, &layers) < 0 {
		return nil
	}
	return layers
}

@(private)
next_layer :: proc(layers: ^IDWriteColorGlyphRunEnumerator) -> ^DWRITE_COLOR_GLYPH_RUN {
	has_run: windows.BOOL
	if layers->MoveNext(&has_run) < 0 || !has_run {
		return nil
	}
	run: ^DWRITE_COLOR_GLYPH_RUN
	if layers->GetCurrentRun(&run) < 0 {
		return nil
	}
	return run
}

// glyph_box is the glyph's ink at px_size, for text size points, in pixels
// from the pen on the baseline, y up: left, bottom, right, top. Empty for a
// glyph with none.
@(private)
glyph_box :: proc(a: ^Atlas, face: ^Face, px_size, size: f32, glyph: u16) -> [4]f64 {
	glyph := glyph
	run := glyph_run(face, px_size, size, &glyph)
	box: windows.RECT
	add :: proc(box: ^windows.RECT, r: ^Raster, run: ^DWRITE_GLYPH_RUN, x, y: f32) {
		analysis, b := glyph_analysis(r, run, x, y)
		if analysis == nil {
			return
		}
		release(analysis)
		if b.right <= b.left || b.bottom <= b.top {
			return
		}
		if box.right <= box.left {
			box^ = b
			return
		}
		box^ = {min(box.left, b.left), min(box.top, b.top), max(box.right, b.right), max(box.bottom, b.bottom)}
	}
	layers := color_layers(&a.raster, &run, 0, 0) if face.color else nil
	if layers != nil {
		defer release(layers)
		for layer := next_layer(layers); layer != nil; layer = next_layer(layers) {
			add(&box, &a.raster, &layer.glyphRun, layer.baselineOriginX, layer.baselineOriginY)
		}
	} else {
		add(&box, &a.raster, &run, 0, 0)
	}
	if box.right <= box.left {
		return {}
	}
	return {f64(box.left), -f64(box.bottom), f64(box.right), -f64(box.top)}
}

// draw_coverage writes run's coverage, with its pen at x, y, into the w by
// h bitmap out, clipped to it.
@(private)
draw_coverage :: proc(r: ^Raster, run: ^DWRITE_GLYPH_RUN, x, y: f32, out: []byte, w, h: int) {
	analysis, b := glyph_analysis(r, run, x, y)
	if analysis == nil {
		return
	}
	defer release(analysis)
	b = {max(b.left, 0), max(b.top, 0), min(b.right, i32(w)), min(b.bottom, i32(h))}
	bw, bh := int(b.right - b.left), int(b.bottom - b.top)
	if bw <= 0 || bh <= 0 {
		return
	}
	alpha := make([]byte, bw * bh, context.temp_allocator)
	t0 := time.tick_now()
	defer r.t_texture += time.tick_since(t0)
	if analysis->CreateAlphaTexture(DWRITE_TEXTURE_ALIASED_1x1, &b, raw_data(alpha), u32(len(alpha))) < 0 {
		return
	}
	for row in 0 ..< bh {
		copy(out[(int(b.top) + row) * w + int(b.left):][:bw], alpha[row * bw:][:bw])
	}
}

// rasterize draws one glyph at px_size, for text size points, with its
// origin at origin (pixels from the bitmap's bottom left) and returns the w
// by h bitmap, top row first, in context.temp_allocator: coverage bytes, or
// premultiplied BGRA for colour.
@(private)
rasterize :: proc(a: ^Atlas, face: ^Face, px_size, size: f32, glyph: u16, w, h: int, origin: [2]f64) -> []byte {
	bpp := 4 if face.color else 1
	out := make([]byte, w * h * bpp, context.temp_allocator)
	glyph := glyph
	run := glyph_run(face, px_size, size, &glyph)
	// DirectWrite's bitmaps go down from their top left.
	x, y := f32(origin.x), f32(f64(h) - origin.y)
	if !face.color {
		draw_coverage(&a.raster, &run, x, y, out, w, h)
		return out
	}
	coverage := make([]byte, w * h, context.temp_allocator)
	layers := color_layers(&a.raster, &run, x, y)
	if layers == nil {
		// A glyph without colour layers, such as Segoe UI Emoji's check
		// mark: white, as the app's text is light on dark.
		draw_coverage(&a.raster, &run, x, y, coverage, w, h)
		for c, i in coverage {
			out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = c, c, c, c
		}
		return out
	}
	defer release(layers)
	for layer := next_layer(layers); layer != nil; layer = next_layer(layers) {
		mem.zero_slice(coverage)
		draw_coverage(&a.raster, &layer.glyphRun, layer.baselineOriginX, layer.baselineOriginY, coverage, w, h)
		color := layer.runColor
		if layer.paletteIndex == DWRITE_NO_PALETTE_INDEX {
			color = {1, 1, 1, 1}
		}
		// Each layer over the ones before, in premultiplied BGRA.
		for c, i in coverage {
			if c == 0 {
				continue
			}
			alpha := f32(c) / 255 * color.a
			p := out[i * 4:][:4]
			p[0] = u8(color.b * alpha * 255 + f32(p[0]) * (1 - alpha) + 0.5)
			p[1] = u8(color.g * alpha * 255 + f32(p[1]) * (1 - alpha) + 0.5)
			p[2] = u8(color.r * alpha * 255 + f32(p[2]) * (1 - alpha) + 0.5)
			p[3] = u8(alpha * 255 + f32(p[3]) * (1 - alpha) + 0.5)
		}
	}
	return out
}
