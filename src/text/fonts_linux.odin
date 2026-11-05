package text

// Fallback fonts on Linux come from fontconfig, on the loader thread. The
// rest of the text code is FreeType's, shared with Windows
// (fonts_freetype.odin).

import "core:c"

foreign import fontconfig "system:fontconfig"

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
