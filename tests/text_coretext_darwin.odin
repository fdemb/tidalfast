// The tests that compare kb_text_shape with CoreText, on macOS only.
package tidal_tests

import "core:testing"

import "../src/text"

// coretext_glyphs shapes str with CoreText in face's font at size and
// returns each glyph's ID and advance by the UTF-16 index of its character.
@(private = "file")
coretext_glyphs :: proc(state: ^text.State, face: u8, size: f32, str: string) -> (ids: map[int]u16, advances: map[int]f32) {
	ids = make(map[int]u16, context.temp_allocator)
	advances = make(map[int]f32, context.temp_allocator)
	font := text.CTFontCreateCopyWithAttributes(state.faces[face].ct, text.CGFloat(size), nil, nil)
	defer text.cf_release(font)
	cf := text.CFStringCreateWithBytes(nil, raw_data(str), len(str), text.CF_STRING_ENCODING_UTF8, false)
	defer text.cf_release(cf)
	keys := [1]rawptr{text.kCTFontAttributeName}
	values := [1]rawptr{font}
	attrs := text.CFDictionaryCreate(nil, &keys[0], &values[0], 1, &text.kCFTypeDictionaryKeyCallBacks, &text.kCFTypeDictionaryValueCallBacks)
	defer text.cf_release(attrs)
	attributed := text.CFAttributedStringCreate(nil, cf, attrs)
	defer text.cf_release(attributed)
	line := text.CTLineCreateWithAttributedString(attributed)
	defer text.cf_release(line)
	runs := text.CTLineGetGlyphRuns(line)
	for i in 0 ..< text.CFArrayGetCount(runs) {
		run := text.CFArrayGetValueAtIndex(runs, i)
		n := text.CTRunGetGlyphCount(run)
		gs := make([]text.CGGlyph, n, context.temp_allocator)
		adv := make([]text.CGSize, n, context.temp_allocator)
		idx := make([]text.CFIndex, n, context.temp_allocator)
		text.CTRunGetGlyphs(run, {}, raw_data(gs))
		text.CTRunGetAdvances(run, {}, raw_data(adv))
		text.CTRunGetStringIndices(run, {}, raw_data(idx))
		for j in 0 ..< n {
			ids[idx[j]] = gs[j]
			advances[idx[j]] = f32(adv[j].width)
		}
	}
	return
}

// Hangul syllables come out of kb_text_shape as the font's precomposed
// glyphs, the same ones CoreText picks from the same face, each with its
// own codepoint index.
@(test)
test_hangul_matches_coretext :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	for str in ([]string{"가", "밤편지", "아이유 - 밤편지 (Remix)", "밤밤편지"}) {
		run := shape_loaded(&s, .Regular, 13, str)
		testing.expectf(t, !run.pending, "%q still pending", str)
		runes := make([dynamic]rune, context.temp_allocator)
		for r in str {
			append(&runes, r)
		}
		syllables := 0
		for r in runes {
			if r >= 0xac00 && r <= 0xd7a3 {
				syllables += 1
			}
		}
		hangul := 0
		for g in run.glyphs {
			r := runes[g.cluster]
			if r < 0xac00 || r > 0xd7a3 {
				continue
			}
			hangul += 1
			testing.expectf(t, g.face >= u8(len(text.Font)), "%q: %c from a fallback face", str, r)
			ids, advances := coretext_glyphs(s.state, g.face, 13, str)
			testing.expectf(t, ids[int(g.cluster)] == g.id, "%q: %c is glyph %d, CoreText %d", str, r, g.id, ids[int(g.cluster)])
			want := advances[int(g.cluster)]
			testing.expectf(t, abs(g.advance - want) < 0.01, "%q: %c advance %v, CoreText %v", str, r, g.advance, want)
		}
		testing.expectf(t, hangul == syllables, "%q: %d Hangul glyphs for %d syllables", str, hangul, syllables)
	}
}

// SF Pro's weights are instances of one variable font with an optical size
// axis, so its advances and kerning change with the weight and the size.
// Lines shaped by kb_text_shape come out as wide as CoreText's.
@(test)
test_variable_widths_match_coretext :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	line :: "Sphinx of black quartz, judge my vow. The quick brown fox jumps over"
	for font in ([]text.Font{.Regular, .Medium, .Semibold, .Bold}) {
		for size in ([]f32{11, 13, 17, 32}) {
			run := shape_loaded(&s, font, size, line)
			want := coretext_width(s.state, u8(font), size, line)
			testing.expectf(t, abs(run.width - want) < want * 0.0005, "%v at %v pt: %v wide, CoreText %v (%.2f%%)", font, size, run.width, want, (run.width - want) / want * 100)
		}
	}
}

@(private = "file")
coretext_width :: proc(state: ^text.State, face: u8, size: f32, str: string) -> f32 {
	font := text.CTFontCreateCopyWithAttributes(state.faces[face].ct, text.CGFloat(size), nil, nil)
	defer text.cf_release(font)
	cf := text.CFStringCreateWithBytes(nil, raw_data(str), len(str), text.CF_STRING_ENCODING_UTF8, false)
	defer text.cf_release(cf)
	keys := [1]rawptr{text.kCTFontAttributeName}
	values := [1]rawptr{font}
	attrs := text.CFDictionaryCreate(nil, &keys[0], &values[0], 1, &text.kCFTypeDictionaryKeyCallBacks, &text.kCFTypeDictionaryValueCallBacks)
	defer text.cf_release(attrs)
	attributed := text.CFAttributedStringCreate(nil, cf, attrs)
	defer text.cf_release(attributed)
	line := text.CTLineCreateWithAttributedString(attributed)
	defer text.cf_release(line)
	return f32(text.CTLineGetTypographicBounds(line, nil, nil, nil))
}
