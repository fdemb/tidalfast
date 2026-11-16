package text

// The DirectWrite interfaces fonts_windows.odin calls, declared by hand:
// Odin's vendor library has none. Each vtable lists every method up to the
// last one called, in the order of the Windows SDK's dwrite*.h, with the
// ones never called as padding.

import "core:sys/windows"

foreign import dwrite "system:dwrite.lib"
foreign import kernel32 "system:kernel32.lib"

HRESULT :: windows.HRESULT
IID :: windows.IID
IUnknown :: windows.IUnknown
IUnknown_VTable :: windows.IUnknown_VTable

DWRITE_FACTORY_TYPE_SHARED :: 0
DWRITE_FONT_FACE_TYPE_TRUETYPE :: 1
DWRITE_FONT_SIMULATIONS_NONE :: 0
DWRITE_FONT_STRETCH_NORMAL :: 5
DWRITE_FONT_STYLE_NORMAL :: 0
DWRITE_READING_DIRECTION_LEFT_TO_RIGHT :: 0
DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC :: 5
DWRITE_MEASURING_MODE_NATURAL :: 0
DWRITE_GRID_FIT_MODE_DEFAULT :: 0
DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE :: 1
// With grayscale antialiasing, this texture holds 8-bit coverage.
DWRITE_TEXTURE_ALIASED_1x1 :: 0
E_NOINTERFACE :: HRESULT(-0x7fff_bffe) // 0x80004002
// The palette index of a colour layer drawn in the text's colour.
DWRITE_NO_PALETTE_INDEX :: 0xffff

IID_IDWriteFactory5 := IID{0x958db99a, 0xbe2a, 0x4f09, {0xaf, 0x7d, 0x65, 0x18, 0x98, 0x03, 0xd1, 0xd3}}
IID_IDWriteFactory6 := IID{0xf3744d80, 0x21f7, 0x42eb, {0xb3, 0x5d, 0x99, 0x5b, 0xc7, 0x2f, 0xc2, 0x23}}
IID_IDWriteLocalFontFileLoader := IID{0xb2d9f3ec, 0xc9fe, 0x4a11, {0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2}}
IID_IDWriteFontFace5 := IID{0x98eff3a5, 0xb667, 0x479a, {0xb1, 0x45, 0xe2, 0xfa, 0x5b, 0x9f, 0xdc, 0x29}}
IID_IDWriteTextAnalysisSource := IID{0x688e1a58, 0x5094, 0x47c8, {0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b}}

// axis_tag is DWRITE_MAKE_FONT_AXIS_TAG.
axis_tag :: proc "contextless" (s: string) -> u32 {
	return u32(s[0]) | u32(s[1]) << 8 | u32(s[2]) << 16 | u32(s[3]) << 24
}

DWRITE_FONT_METRICS :: struct {
	designUnitsPerEm:       u16,
	ascent:                 u16,
	descent:                u16,
	lineGap:                i16,
	capHeight:              u16,
	xHeight:                u16,
	underlinePosition:      i16,
	underlineThickness:     u16,
	strikethroughPosition:  i16,
	strikethroughThickness: u16,
}

DWRITE_GLYPH_RUN :: struct {
	fontFace:      ^IDWriteFontFace,
	fontEmSize:    f32,
	glyphCount:    u32,
	glyphIndices:  [^]u16,
	glyphAdvances: [^]f32,
	glyphOffsets:  rawptr,
	isSideways:    windows.BOOL,
	bidiLevel:     u32,
}

DWRITE_COLOR_F :: struct {
	r, g, b, a: f32,
}

DWRITE_COLOR_GLYPH_RUN :: struct {
	glyphRun:            DWRITE_GLYPH_RUN,
	glyphRunDescription: rawptr,
	baselineOriginX:     f32,
	baselineOriginY:     f32,
	runColor:            DWRITE_COLOR_F,
	paletteIndex:        u16,
}

DWRITE_FONT_AXIS_VALUE :: struct {
	axisTag: u32,
	value:   f32,
}

DWRITE_FONT_AXIS_RANGE :: struct {
	axisTag:  u32,
	minValue: f32,
	maxValue: f32,
}

// What a C compiler gives with dwrite.h.
#assert(size_of(DWRITE_GLYPH_RUN) == 48 && offset_of(DWRITE_GLYPH_RUN, glyphIndices) == 16)
#assert(size_of(DWRITE_COLOR_GLYPH_RUN) == 88 && offset_of(DWRITE_COLOR_GLYPH_RUN, runColor) == 64)
#assert(size_of(DWRITE_FONT_METRICS) == 20)

@(default_calling_convention = "system")
foreign dwrite {
	DWriteCreateFactory :: proc(factory_type: u32, iid: ^IID, factory: ^^IUnknown) -> HRESULT ---
}

@(default_calling_convention = "system")
foreign kernel32 {
	GetUserDefaultLocaleName :: proc(name: [^]u16, length: i32) -> i32 ---
}

// release drops a reference to any DirectWrite object, if there is one.
release :: proc "contextless" (object: rawptr) {
	if object != nil {
		unknown := (^IUnknown)(object)
		unknown->Release()
	}
}

// IDWriteFactory up to IDWriteFactory6, one vtable: each version adds its
// methods to the end of the one before.
IDWriteFactory :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFactory_VTable,
}
IDWriteFactory_VTable :: struct {
	using iunknown_vtable:            IUnknown_VTable,
	GetSystemFontCollection:          proc "system" (this: ^IDWriteFactory, collection: ^^IDWriteFontCollection, check_for_updates: windows.BOOL) -> HRESULT,
	_:                                [5]rawptr,
	CreateFontFace:                   proc "system" (this: ^IDWriteFactory, face_type: u32, files_number: u32, files: [^]^IDWriteFontFile, index: u32, simulations: u32, face: ^^IDWriteFontFace) -> HRESULT,
	_:                                [3]rawptr,
	RegisterFontFileLoader:           proc "system" (this: ^IDWriteFactory, loader: rawptr) -> HRESULT,
	UnregisterFontFileLoader:         proc "system" (this: ^IDWriteFactory, loader: rawptr) -> HRESULT,
	_:                                [9]rawptr, // the rest of IDWriteFactory
	_:                                [2]rawptr, // IDWriteFactory1
	// IDWriteFactory2
	GetSystemFontFallback:            proc "system" (this: ^IDWriteFactory, fallback: ^^IDWriteFontFallback) -> HRESULT,
	_:                                rawptr,
	TranslateColorGlyphRun:           proc "system" (this: ^IDWriteFactory, origin_x, origin_y: f32, run: ^DWRITE_GLYPH_RUN, description: rawptr, measuring_mode: u32, transform: rawptr, palette_index: u32, layers: ^^IDWriteColorGlyphRunEnumerator) -> HRESULT,
	_:                                rawptr,
	CreateGlyphRunAnalysis:           proc "system" (this: ^IDWriteFactory, run: ^DWRITE_GLYPH_RUN, transform: rawptr, rendering_mode: u32, measuring_mode: u32, grid_fit_mode: u32, antialias_mode: u32, origin_x, origin_y: f32, analysis: ^^IDWriteGlyphRunAnalysis) -> HRESULT,
	_:                                [9]rawptr, // IDWriteFactory3
	_:                                [3]rawptr, // IDWriteFactory4
	// IDWriteFactory5
	_:                                rawptr,
	CreateInMemoryFontFileLoader:     proc "system" (this: ^IDWriteFactory, loader: ^^IDWriteInMemoryFontFileLoader) -> HRESULT,
	_:                                [3]rawptr,
	// IDWriteFactory6
	_:                                rawptr,
	CreateFontResource:               proc "system" (this: ^IDWriteFactory, file: ^IDWriteFontFile, face_index: u32, resource: ^^IDWriteFontResource) -> HRESULT,
}
#assert(offset_of(IDWriteFactory_VTable, CreateFontFace) == 9 * size_of(rawptr))
#assert(offset_of(IDWriteFactory_VTable, RegisterFontFileLoader) == 13 * size_of(rawptr))
#assert(offset_of(IDWriteFactory_VTable, GetSystemFontFallback) == 26 * size_of(rawptr))
#assert(offset_of(IDWriteFactory_VTable, CreateGlyphRunAnalysis) == 30 * size_of(rawptr))
#assert(offset_of(IDWriteFactory_VTable, CreateInMemoryFontFileLoader) == 44 * size_of(rawptr))
#assert(offset_of(IDWriteFactory_VTable, CreateFontResource) == 49 * size_of(rawptr))

IDWriteFontCollection :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFontCollection_VTable,
}
IDWriteFontCollection_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFontFamilyCount:    proc "system" (this: ^IDWriteFontCollection) -> u32,
	GetFontFamily:         proc "system" (this: ^IDWriteFontCollection, index: u32, family: ^^IDWriteFontFamily) -> HRESULT,
	FindFamilyName:        proc "system" (this: ^IDWriteFontCollection, name: windows.wstring, index: ^u32, exists: ^windows.BOOL) -> HRESULT,
}

IDWriteFontFamily :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFontFamily_VTable,
}
IDWriteFontFamily_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	_:                     [4]rawptr, // IDWriteFontList, then GetFamilyNames
	GetFirstMatchingFont:  proc "system" (this: ^IDWriteFontFamily, weight: u32, stretch: u32, style: u32, font: ^^IDWriteFont) -> HRESULT,
}
#assert(offset_of(IDWriteFontFamily_VTable, GetFirstMatchingFont) == 7 * size_of(rawptr))

IDWriteFont :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFont_VTable,
}
IDWriteFont_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	_:                     [10]rawptr,
	CreateFontFace:        proc "system" (this: ^IDWriteFont, face: ^^IDWriteFontFace) -> HRESULT,
}
#assert(offset_of(IDWriteFont_VTable, CreateFontFace) == 13 * size_of(rawptr))

IDWriteFontFace :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFontFace_VTable,
}
IDWriteFontFace_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetType:               proc "system" (this: ^IDWriteFontFace) -> u32,
	GetFiles:              proc "system" (this: ^IDWriteFontFace, count: ^u32, files: [^]^IDWriteFontFile) -> HRESULT,
	GetIndex:              proc "system" (this: ^IDWriteFontFace) -> u32,
	GetSimulations:        proc "system" (this: ^IDWriteFontFace) -> u32,
	IsSymbolFont:          proc "system" (this: ^IDWriteFontFace) -> windows.BOOL,
	GetMetrics:            proc "system" (this: ^IDWriteFontFace, metrics: ^DWRITE_FONT_METRICS),
	GetGlyphCount:         proc "system" (this: ^IDWriteFontFace) -> u16,
}

IDWriteFontFace5 :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFontFace5_VTable,
}
IDWriteFontFace5_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	_:                     [50]rawptr, // IDWriteFontFace to IDWriteFontFace4
	GetFontAxisValueCount: proc "system" (this: ^IDWriteFontFace5) -> u32,
	GetFontAxisValues:     proc "system" (this: ^IDWriteFontFace5, values: [^]DWRITE_FONT_AXIS_VALUE, count: u32) -> HRESULT,
}
#assert(offset_of(IDWriteFontFace5_VTable, GetFontAxisValueCount) == 53 * size_of(rawptr))

IDWriteFontFile :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFontFile_VTable,
}
IDWriteFontFile_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetReferenceKey:       proc "system" (this: ^IDWriteFontFile, key: ^rawptr, key_size: ^u32) -> HRESULT,
	GetLoader:             proc "system" (this: ^IDWriteFontFile, loader: ^^IUnknown) -> HRESULT,
}

IDWriteLocalFontFileLoader :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteLocalFontFileLoader_VTable,
}
IDWriteLocalFontFileLoader_VTable :: struct {
	using iunknown_vtable:    IUnknown_VTable,
	CreateStreamFromKey:      rawptr,
	GetFilePathLengthFromKey: proc "system" (this: ^IDWriteLocalFontFileLoader, key: rawptr, key_size: u32, length: ^u32) -> HRESULT,
	GetFilePathFromKey:       proc "system" (this: ^IDWriteLocalFontFileLoader, key: rawptr, key_size: u32, path: [^]u16, length: u32) -> HRESULT,
}

IDWriteInMemoryFontFileLoader :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteInMemoryFontFileLoader_VTable,
}
IDWriteInMemoryFontFileLoader_VTable :: struct {
	using iunknown_vtable:           IUnknown_VTable,
	CreateStreamFromKey:             rawptr,
	CreateInMemoryFontFileReference: proc "system" (this: ^IDWriteInMemoryFontFileLoader, factory: ^IDWriteFactory, data: rawptr, size: u32, owner: ^IUnknown, file: ^^IDWriteFontFile) -> HRESULT,
}

IDWriteFontFallback :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFontFallback_VTable,
}
IDWriteFontFallback_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	MapCharacters:         proc "system" (this: ^IDWriteFontFallback, source: ^Analysis_Source, position, length: u32, base_collection: ^IDWriteFontCollection, base_family: windows.wstring, weight, style, stretch: u32, mapped_length: ^u32, mapped_font: ^^IDWriteFont, scale: ^f32) -> HRESULT,
}

IDWriteGlyphRunAnalysis :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteGlyphRunAnalysis_VTable,
}
IDWriteGlyphRunAnalysis_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetAlphaTextureBounds: proc "system" (this: ^IDWriteGlyphRunAnalysis, texture_type: u32, bounds: ^windows.RECT) -> HRESULT,
	CreateAlphaTexture:    proc "system" (this: ^IDWriteGlyphRunAnalysis, texture_type: u32, bounds: ^windows.RECT, alpha: [^]u8, size: u32) -> HRESULT,
}

IDWriteColorGlyphRunEnumerator :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteColorGlyphRunEnumerator_VTable,
}
IDWriteColorGlyphRunEnumerator_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	MoveNext:              proc "system" (this: ^IDWriteColorGlyphRunEnumerator, has_run: ^windows.BOOL) -> HRESULT,
	GetCurrentRun:         proc "system" (this: ^IDWriteColorGlyphRunEnumerator, run: ^^DWRITE_COLOR_GLYPH_RUN) -> HRESULT,
}

IDWriteFontResource :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable:      ^IDWriteFontResource_VTable,
}
IDWriteFontResource_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFontFile:           rawptr,
	GetFontFaceIndex:      rawptr,
	GetFontAxisCount:      proc "system" (this: ^IDWriteFontResource) -> u32,
	_:                     rawptr,
	GetFontAxisRanges:     proc "system" (this: ^IDWriteFontResource, ranges: [^]DWRITE_FONT_AXIS_RANGE, count: u32) -> HRESULT,
	_:                     [4]rawptr,
	HasVariations:         proc "system" (this: ^IDWriteFontResource) -> windows.BOOL,
	CreateFontFace:        proc "system" (this: ^IDWriteFontResource, simulations: u32, axes: [^]DWRITE_FONT_AXIS_VALUE, count: u32, face: ^^IDWriteFontFace) -> HRESULT,
}
#assert(offset_of(IDWriteFontResource_VTable, HasVariations) == 12 * size_of(rawptr))

// Analysis_Source is an IDWriteTextAnalysisSource over one character, the
// text MapCharacters asks about. It lives on the stack for the call, so it
// counts no references.
Analysis_Source :: struct {
	vtable: ^Analysis_Source_VTable,
	text:   [2]u16,
	length: u32,
	locale: [^]u16,
}
Analysis_Source_VTable :: struct {
	QueryInterface:               proc "system" (this: ^Analysis_Source, riid: ^IID, object: ^rawptr) -> HRESULT,
	AddRef:                       proc "system" (this: ^Analysis_Source) -> u32,
	Release:                      proc "system" (this: ^Analysis_Source) -> u32,
	GetTextAtPosition:            proc "system" (this: ^Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT,
	GetTextBeforePosition:        proc "system" (this: ^Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT,
	GetParagraphReadingDirection: proc "system" (this: ^Analysis_Source) -> u32,
	GetLocaleName:                proc "system" (this: ^Analysis_Source, position: u32, length: ^u32, locale: ^[^]u16) -> HRESULT,
	GetNumberSubstitution:        proc "system" (this: ^Analysis_Source, position: u32, length: ^u32, substitution: ^rawptr) -> HRESULT,
}

ANALYSIS_SOURCE_VTABLE := Analysis_Source_VTable {
	QueryInterface = proc "system" (this: ^Analysis_Source, riid: ^IID, object: ^rawptr) -> HRESULT {
		if riid^ == windows.IUnknown_UUID^ || riid^ == IID_IDWriteTextAnalysisSource {
			object^ = this
			return windows.S_OK
		}
		object^ = nil
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^Analysis_Source) -> u32 {return 1},
	Release = proc "system" (this: ^Analysis_Source) -> u32 {return 1},
	GetTextAtPosition = proc "system" (this: ^Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT {
		text^, length^ = nil, 0
		if position < this.length {
			text^, length^ = ([^]u16)(&this.text[position]), this.length - position
		}
		return windows.S_OK
	},
	GetTextBeforePosition = proc "system" (this: ^Analysis_Source, position: u32, text: ^[^]u16, length: ^u32) -> HRESULT {
		text^, length^ = nil, 0
		if position > 0 && position <= this.length {
			text^, length^ = ([^]u16)(&this.text[0]), position
		}
		return windows.S_OK
	},
	GetParagraphReadingDirection = proc "system" (this: ^Analysis_Source) -> u32 {
		return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT
	},
	GetLocaleName = proc "system" (this: ^Analysis_Source, position: u32, length: ^u32, locale: ^[^]u16) -> HRESULT {
		length^ = this.length - min(position, this.length)
		locale^ = this.locale
		return windows.S_OK
	},
	GetNumberSubstitution = proc "system" (this: ^Analysis_Source, position: u32, length: ^u32, substitution: ^rawptr) -> HRESULT {
		length^ = this.length - min(position, this.length)
		substitution^ = nil
		return windows.S_OK
	},
}

// STATIC_OWNER owns font data that lives as long as the process, the
// executable's own bytes, so DirectWrite reads them in place.
STATIC_OWNER_VTABLE := IUnknown_VTable {
	QueryInterface = proc "system" (this: ^IUnknown, riid: windows.REFIID, object: ^rawptr) -> HRESULT {
		object^ = nil
		if riid^ == windows.IUnknown_UUID^ {
			object^ = this
			return windows.S_OK
		}
		return E_NOINTERFACE
	},
	AddRef = proc "system" (this: ^IUnknown) -> windows.ULONG {return 1},
	Release = proc "system" (this: ^IUnknown) -> windows.ULONG {return 1},
}
STATIC_OWNER := IUnknown{&STATIC_OWNER_VTABLE}
