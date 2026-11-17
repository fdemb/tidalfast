package text

// The parts of CoreFoundation, CoreGraphics and CoreText the text code uses.
// They are plain C APIs, declared by hand.

foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import CoreGraphics "system:CoreGraphics.framework"
foreign import CoreText "system:CoreText.framework"

CFTypeRef :: rawptr
CFStringRef :: rawptr
CFDataRef :: rawptr
CFArrayRef :: rawptr
CFDictionaryRef :: rawptr
CFURLRef :: rawptr
CFAttributedStringRef :: rawptr
CTFontRef :: rawptr
CTFontDescriptorRef :: rawptr
CTLineRef :: rawptr
CTRunRef :: rawptr
CGContextRef :: rawptr
CGColorSpaceRef :: rawptr

CFIndex :: int
CGFloat :: f64
CGGlyph :: u16

CFRange :: struct {
	location, length: CFIndex,
}

CGPoint :: struct {
	x, y: CGFloat,
}

CGSize :: struct {
	width, height: CGFloat,
}

CGRect :: struct {
	origin: CGPoint,
	size:   CGSize,
}

// Opaque; only their addresses are passed to CFDictionaryCreate.
CFDictionaryKeyCallBacks :: struct {
	_: [6]rawptr,
}
CFDictionaryValueCallBacks :: struct {
	_: [5]rawptr,
}
CFArrayCallBacks :: struct {
	_: [5]rawptr,
}

CF_STRING_ENCODING_UTF8 :: 0x08000100
CF_STRING_ENCODING_UTF32LE :: 0x1c000100

CG_IMAGE_ALPHA_ONLY :: 7
CG_BITMAP_BGRA_PREMULTIPLIED :: 2 | 2 << 12 // kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little

CT_FONT_ITALIC_TRAIT :: 1 << 0
CT_FONT_BOLD_TRAIT :: 1 << 1
CT_FONT_COLOR_GLYPHS_TRAIT :: 1 << 13
CT_FONT_UI_FONT_SYSTEM :: 2
CF_NUMBER_CGFLOAT_TYPE :: 16
CF_NUMBER_SINT64_TYPE :: 4

// vendor:darwin/Metal brings in core:sys/darwin/CoreFoundation, and Odin
// rejects a C function declared twice with different types. So these match
// its declarations: b8 for Boolean and int for CFStringEncoding, a UInt32
// that it declares as a long.
@(default_calling_convention = "c")
foreign CoreFoundation {
	kCFTypeDictionaryKeyCallBacks:   CFDictionaryKeyCallBacks
	kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks
	kCFTypeArrayCallBacks:           CFArrayCallBacks
	kCFAllocatorNull:                rawptr

	CFRelease :: proc(cf: CFTypeRef) ---
	CFRetain :: proc(cf: CFTypeRef) -> CFTypeRef ---
	CFNumberCreate :: proc(allocator: rawptr, type: CFIndex, value: rawptr) -> CFTypeRef ---
	CFEqual :: proc(a, b: CFTypeRef) -> b8 ---
	CFDataCreate :: proc(allocator: rawptr, bytes: [^]u8, length: CFIndex) -> CFDataRef ---
	CFDataCreateWithBytesNoCopy :: proc(allocator: rawptr, bytes: [^]u8, length: CFIndex, bytes_deallocator: rawptr) -> CFDataRef ---
	CFDataGetBytePtr :: proc(data: CFDataRef) -> [^]u8 ---
	CFDataGetLength :: proc(data: CFDataRef) -> CFIndex ---
	CFStringCreateWithBytes :: proc(allocator: rawptr, bytes: [^]u8, num_bytes: CFIndex, encoding: int, external_representation: b8) -> CFStringRef ---
	CFStringGetLength :: proc(s: CFStringRef) -> CFIndex ---
	CFStringGetCString :: proc(s: CFStringRef, buffer: [^]u8, size: CFIndex, encoding: int) -> b8 ---
	CFDictionaryCreate :: proc(allocator: rawptr, keys: [^]rawptr, values: [^]rawptr, count: CFIndex, key_callbacks: ^CFDictionaryKeyCallBacks, value_callbacks: ^CFDictionaryValueCallBacks) -> CFDictionaryRef ---
	CFDictionaryGetValue :: proc(dict: CFDictionaryRef, key: rawptr) -> rawptr ---
	CFDictionaryGetCount :: proc(dict: CFDictionaryRef) -> CFIndex ---
	CFDictionaryGetKeysAndValues :: proc(dict: CFDictionaryRef, keys: [^]rawptr, values: [^]rawptr) ---
	CFNumberGetValue :: proc(number: CFTypeRef, type: CFIndex, value: rawptr) -> b8 ---
	CFAttributedStringCreate :: proc(allocator: rawptr, s: CFStringRef, attributes: CFDictionaryRef) -> CFAttributedStringRef ---
	CFArrayCreate :: proc(allocator: rawptr, values: [^]rawptr, count: CFIndex, callbacks: ^CFArrayCallBacks) -> CFArrayRef ---
	CFCharacterSetCreateWithCharactersInString :: proc(allocator: rawptr, s: CFStringRef) -> CFTypeRef ---
	CFArrayGetCount :: proc(array: CFArrayRef) -> CFIndex ---
	CFArrayGetValueAtIndex :: proc(array: CFArrayRef, index: CFIndex) -> rawptr ---
	CFURLGetFileSystemRepresentation :: proc(url: CFURLRef, resolve_against_base: b8, buffer: [^]u8, max_length: CFIndex) -> b8 ---
}

@(default_calling_convention = "c")
foreign CoreGraphics {
	kCGColorSpaceSRGB: CFStringRef

	CGColorSpaceCreateWithName :: proc(name: CFStringRef) -> CGColorSpaceRef ---
	CGColorSpaceRelease :: proc(space: CGColorSpaceRef) ---
	CGBitmapContextCreate :: proc(data: rawptr, width, height, bits_per_component, bytes_per_row: uint, space: CGColorSpaceRef, bitmap_info: u32) -> CGContextRef ---
	CGBitmapContextGetData :: proc(ctx: CGContextRef) -> [^]u8 ---
	CGContextRelease :: proc(ctx: CGContextRef) ---
	CGContextClearRect :: proc(ctx: CGContextRef, rect: CGRect) ---
	CGContextSetGrayFillColor :: proc(ctx: CGContextRef, gray, alpha: CGFloat) ---
	CGContextSetAllowsAntialiasing :: proc(ctx: CGContextRef, allow: bool) ---
	CGContextSetShouldAntialias :: proc(ctx: CGContextRef, should: bool) ---
	CGContextSetAllowsFontSmoothing :: proc(ctx: CGContextRef, allow: bool) ---
	CGContextSetShouldSmoothFonts :: proc(ctx: CGContextRef, should: bool) ---
	CGContextSetAllowsFontSubpixelPositioning :: proc(ctx: CGContextRef, allow: bool) ---
	CGContextSetShouldSubpixelPositionFonts :: proc(ctx: CGContextRef, should: bool) ---
	CGContextSetAllowsFontSubpixelQuantization :: proc(ctx: CGContextRef, allow: bool) ---
	CGContextSetShouldSubpixelQuantizeFonts :: proc(ctx: CGContextRef, should: bool) ---
}

@(default_calling_convention = "c")
foreign CoreText {
	kCTFontURLAttribute:  CFStringRef
	kCTFontAttributeName: CFStringRef
	kCTFontCharacterSetAttribute: CFStringRef
	kCTFontTraitsAttribute: CFStringRef
	kCTFontWeightTrait: CFStringRef
	kCTFontOpticalSizeAttribute: CFStringRef

	CTFontManagerCreateFontDescriptorFromData :: proc(data: CFDataRef) -> CTFontDescriptorRef ---
	CTFontDescriptorCreateWithAttributes :: proc(attributes: CFDictionaryRef) -> CTFontDescriptorRef ---
	CTFontCollectionCreateWithFontDescriptors :: proc(descriptors: CFArrayRef, options: CFDictionaryRef) -> CFTypeRef ---
	CTFontCollectionCreateMatchingFontDescriptors :: proc(collection: CFTypeRef) -> CFArrayRef ---
	CTFontCreateWithFontDescriptor :: proc(descriptor: CTFontDescriptorRef, size: CGFloat, transform: rawptr) -> CTFontRef ---
	CTFontCreateCopyWithAttributes :: proc(font: CTFontRef, size: CGFloat, transform: rawptr, attributes: CTFontDescriptorRef) -> CTFontRef ---
	CTFontCreateUIFontForLanguage :: proc(type: u32, size: CGFloat, language: CFStringRef) -> CTFontRef ---
	CTFontCreateForString :: proc(current: CTFontRef, s: CFStringRef, range: CFRange) -> CTFontRef ---
	CTFontCopyAttribute :: proc(font: CTFontRef, attribute: CFStringRef) -> CFTypeRef ---
	CTFontCopyPostScriptName :: proc(font: CTFontRef) -> CFStringRef ---
	CTFontCopyTable :: proc(font: CTFontRef, tag: u32, options: u32) -> CFDataRef ---
	CTFontCopyVariation :: proc(font: CTFontRef) -> CFDictionaryRef ---
	CTFontGetSymbolicTraits :: proc(font: CTFontRef) -> u32 ---
	CTFontGetUnitsPerEm :: proc(font: CTFontRef) -> u32 ---
	CTFontGetAscent :: proc(font: CTFontRef) -> CGFloat ---
	CTFontGetDescent :: proc(font: CTFontRef) -> CGFloat ---
	CTFontGetBoundingRectsForGlyphs :: proc(font: CTFontRef, orientation: u32, glyphs: [^]CGGlyph, rects: [^]CGRect, count: CFIndex) -> CGRect ---
	CTFontDrawGlyphs :: proc(font: CTFontRef, glyphs: [^]CGGlyph, positions: [^]CGPoint, count: uint, ctx: CGContextRef) ---
	CTLineCreateWithAttributedString :: proc(s: CFAttributedStringRef) -> CTLineRef ---
	CTLineGetGlyphRuns :: proc(line: CTLineRef) -> CFArrayRef ---
	CTLineGetTypographicBounds :: proc(line: CTLineRef, ascent, descent, leading: ^CGFloat) -> f64 ---
	CTRunGetGlyphCount :: proc(run: CTRunRef) -> CFIndex ---
	CTRunGetGlyphs :: proc(run: CTRunRef, range: CFRange, buffer: [^]CGGlyph) ---
	CTRunGetPositions :: proc(run: CTRunRef, range: CFRange, buffer: [^]CGPoint) ---
	CTRunGetAdvances :: proc(run: CTRunRef, range: CFRange, buffer: [^]CGSize) ---
	CTRunGetStringIndices :: proc(run: CTRunRef, range: CFRange, buffer: [^]CFIndex) ---
	CTRunGetAttributes :: proc(run: CTRunRef) -> CFDictionaryRef ---
}

// cf_string copies s into buf as UTF-8 and returns it, or "" if it doesn't
// fit.
cf_string :: proc(s: CFStringRef, buf: []u8) -> string {
	if s == nil || !CFStringGetCString(s, raw_data(buf), len(buf), CF_STRING_ENCODING_UTF8) {
		return ""
	}
	return string(cstring(raw_data(buf)))
}

cf_release :: proc(ref: CFTypeRef) {
	if ref != nil {
		CFRelease(ref)
	}
}

font_has_table :: proc(font: CTFontRef, tag: string) -> bool {
	data := CTFontCopyTable(font, table_tag(tag), 0)
	defer cf_release(data)
	return data != nil
}
