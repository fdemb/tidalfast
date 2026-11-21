package tidal_tests

import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:unicode/utf8"
import "core:time"

import "../third_party/kbts"
import "../src/platform"
import "../src/render"
import "../src/text"
import "../src/ui"

@(test)
test_subpixel_buckets :: proc(t: ^testing.T) {
	Case :: struct {
		x:      f32,
		whole:  f32,
		bucket: u8,
	}
	cases := []Case{{10, 10, 0}, {10.2, 10, 1}, {10.5, 10, 2}, {10.7, 10, 3}, {10.9, 11, 0}, {-0.3, -1, 3}, {0.12, 0, 0}, {0.13, 0, 1}}
	for c in cases {
		whole, bucket := text.subpixel(c.x)
		testing.expectf(t, whole == c.whole && bucket == c.bucket, "subpixel(%v) = %v, %v, want %v, %v", c.x, whole, bucket, c.whole, c.bucket)
	}
}

@(test)
test_cache_keys :: proc(t: ^testing.T) {
	a := text.run_key("Blue in Green", .Regular, 13)
	testing.expect_value(t, text.run_key("Blue in Green", .Regular, 13), a)
	testing.expect(t, text.run_key("Blue in Green", .Medium, 13) != a)
	testing.expect(t, text.run_key("Blue in Green", .Regular, 13.5) != a)
	testing.expect(t, text.run_key("Blue in Green ", .Regular, 13) != a)
	testing.expect(t, text.run_key("", .Regular, 13) != 0)

	g := text.glyph_key(0, 0, text.glyph_sizes(26, 13), 0)
	testing.expect(t, g != 0)
	testing.expect(t, text.glyph_key(0, 0, text.glyph_sizes(26, 13), 1) != g)
	testing.expect(t, text.glyph_key(1, 0, text.glyph_sizes(26, 13), 0) != g)
	testing.expect(t, text.glyph_key(0, 1, text.glyph_sizes(26, 13), 0) != g)
	testing.expect(t, text.glyph_key(0, 0, text.glyph_sizes(26.25, 13), 0) != g)
	testing.expect(t, text.glyph_key(0, 0, text.glyph_sizes(26, 26), 0) != g) // 26 px at 1x
	testing.expect_value(t, text.glyph_key(0, 0, text.glyph_sizes(26.01, 13), 0), g) // quarter pixel steps
}

// Coverage blended in linear light draws light text on dark heavier and
// dark text on light thinner than other Windows apps' text, so a glyph's
// coverage bends by its text's tone, and each tone has its own bitmap.
@(test)
glyph_tones_bend_coverage :: proc(t: ^testing.T) {
	sizes := text.glyph_sizes(13, 13)
	none := text.glyph_key(0, 0, sizes, 3)
	light := text.glyph_key(0, 0, sizes, 3, .Light)
	dark := text.glyph_key(0, 0, sizes, 3, .Dark)
	testing.expect(t, none != light && light != dark && none != dark)
	testing.expect(t, text.glyph_key(0, 0, sizes, 0, .Dark) != text.glyph_key(0, 0, sizes, 3, .None))

	ramp: [256]u8
	for &c, i in ramp {
		c = u8(i)
	}
	for tone in text.Tone {
		bent := ramp
		text.apply_tone(bent[:], tone)
		// Nothing and everything stay as they are, and the curve keeps
		// the order of what it bends.
		testing.expect_value(t, bent[0], 0)
		testing.expect_value(t, bent[255], 255)
		for i in 1 ..< 256 {
			testing.expect(t, bent[i] >= bent[i - 1])
		}
		half := int(bent[128])
		switch tone {
		case .None:
			testing.expect_value(t, half, 128)
		case .Light:
			testing.expectf(t, half < 100 && half > 60, "light text's half coverage is %d", half)
		case .Dark:
			testing.expectf(t, half > 155 && half < 195, "dark text's half coverage is %d", half)
		}
	}

	when text.TONES {
		testing.expect_value(t, text.tone_of({0xf3 / 255.0, 0xf3 / 255.0, 0xf3 / 255.0, 1}), text.Tone.Light)
		testing.expect_value(t, text.tone_of({0x74 / 255.0, 0x74 / 255.0, 0x74 / 255.0, 1}), text.Tone.Light)
		testing.expect_value(t, text.tone_of({0, 0, 0, 1}), text.Tone.Dark)
		testing.expect_value(t, text.tone_of({0.2, 0.2, 0.2, 0.5}), text.Tone.Dark)
	} else {
		testing.expect_value(t, text.tone_of({1, 1, 1, 1}), text.Tone.None)
	}
}

// glyphs makes a run of n glyphs, each 10 wide, with spaces at the given
// indices.
@(private = "file")
glyphs :: proc(n: int, spaces: ..int) -> []text.Glyph {
	out := make([]text.Glyph, n, context.temp_allocator)
	for &g, i in out {
		g.pen = f32(i * 10)
		g.advance = 10
		g.cluster = u32(i)
	}
	for i in spaces {
		out[i].space = true
	}
	return out
}

// The shaper, peel and CoreText agree on what a space is.
@(test)
test_is_space :: proc(t: ^testing.T) {
	for r in ([]rune{' ', 0xa0, 0x3000}) {
		testing.expectf(t, text.is_space(r), "%x is a space", r)
	}
	for r in ([]rune{'a', '\t', 0x200b, '('}) {
		testing.expectf(t, !text.is_space(r), "%x isn't a space", r)
	}
}

@(test)
test_truncate_ltr :: proc(t: ^testing.T) {
	gs := glyphs(10)
	first, last, shift, ellipsis_x, width := text.truncate(gs, 100, 120, 8, false)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, last, 10)
	testing.expect_value(t, width, 100)

	// 55 wide: 47 for glyphs, so four fit and the ellipsis follows them.
	first, last, shift, ellipsis_x, width = text.truncate(gs, 100, 55, 8, false)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, last, 4)
	testing.expect_value(t, shift, 0)
	testing.expect_value(t, ellipsis_x, 40)
	testing.expect_value(t, width, 48)

	// A space right before the cut goes too.
	gs = glyphs(10, 3)
	first, last, shift, ellipsis_x, width = text.truncate(gs, 100, 55, 8, false)
	testing.expect_value(t, last, 3)
	testing.expect_value(t, ellipsis_x, 30)

	// Nothing fits.
	first, last, shift, ellipsis_x, width = text.truncate(gs, 100, 6, 8, false)
	testing.expect_value(t, last, 0)
	testing.expect_value(t, width, 8)
}

// The Linux build's Noto Sans has its weights as named instances, Regular
// as the default.
@(test)
test_fvar_instance :: proc(t: ^testing.T) {
	noto := #load("../assets/fonts/NotoSans-Variable.ttf")
	testing.expect_value(t, text.fvar_instance(noto, "wght", 400), 0)
	testing.expect_value(t, text.fvar_instance(noto, "wght", 500), 2)
	testing.expect_value(t, text.fvar_instance(noto, "wght", 600), 3)
	testing.expect_value(t, text.fvar_instance(noto, "wght", 700), 4)
	testing.expect_value(t, text.fvar_instance(noto, "wght", 450), -1)
	testing.expect_value(t, text.fvar_instance(noto, "wdth", 100), -1)
	testing.expect_value(t, text.fvar_instance(noto[:100], "wght", 500), -1)
}

// A label sized to its text gets its width plus padding, and draws in that
// less the padding. In f32 that can come back a hair under the width, as
// it did for "Discovery" in Noto Sans, which then lost its last letters.
@(test)
test_truncate_padded_fit :: proc(t: ^testing.T) {
	gs := glyphs(6)
	run_width, pad: f32 = 59.2, 4
	avail := (run_width + 2 * pad) - 2 * pad
	testing.expect(t, avail < run_width, "the padding round trip loses a bit")
	_, last, _, _, width := text.truncate(gs, run_width, avail, 8, false)
	testing.expect_value(t, last, 6)
	testing.expect_value(t, width, run_width)
}

@(test)
test_truncate_rtl :: proc(t: ^testing.T) {
	// Right to left, the logical end is on the left: glyphs stay from the
	// right and the ellipsis goes in front.
	gs := glyphs(10, 6)
	first, last, shift, ellipsis_x, width := text.truncate(gs, 100, 55, 8, true)
	// Glyphs whose left edge is at or past 100 - 47 = 53 stay: 6 to 9,
	// minus the space at 6.
	testing.expect_value(t, first, 7)
	testing.expect_value(t, last, 10)
	testing.expect_value(t, ellipsis_x, 0)
	testing.expect_value(t, shift, 8 - 70)
	testing.expect_value(t, width, 38)
}

@(test)
test_visual_order :: proc(t: ^testing.T) {
	// abc [ابجد] [ ] [123] [ ] [هوز] def in a left-to-right paragraph.
	levels := []u8{0, 1, 1, 2, 1, 1, 0}
	order := make([]int, len(levels), context.temp_allocator)
	text.visual_order(levels, order)
	testing.expect(t, slice_equal(order, []int{0, 5, 4, 3, 2, 1, 6}), "ltr paragraph")

	// All right to left: plain reversal, with a left-to-right pair kept in
	// order.
	levels = []u8{1, 1, 2, 2, 1}
	order = make([]int, len(levels), context.temp_allocator)
	text.visual_order(levels, order)
	testing.expect(t, slice_equal(order, []int{4, 2, 3, 1, 0}), "rtl paragraph")
}

@(test)
test_resolve_levels :: proc(t: ^testing.T) {
	// "عيونك (Remix) 2024": kb_text_shape calls the closing bracket and
	// the space after it left to right. N0 makes the brackets right to
	// left, and the space between them and the number follows.
	{
		kinds := []text.Bidi_Kind{.Strong, .Neutral, .Neutral, .Strong, .Neutral, .Neutral, .Number}
		rtl := []bool{true, true, true, false, false, false, false}
		brackets := []rune{0, 0, '(', 0, ')', 0, 0}
		levels := make([]u8, len(kinds), context.temp_allocator)
		text.resolve_levels(kinds, rtl, brackets, true, levels)
		testing.expect(t, slice_equal(levels, []u8{1, 1, 1, 2, 1, 1, 2}), "remix levels")
		order := make([]int, len(kinds), context.temp_allocator)
		text.visual_order(levels, order)
		testing.expect(t, slice_equal(order, []int{6, 5, 4, 3, 2, 1, 0}), "remix order")
	}
	// "晴天 عيونك 🔥": kb_text_shape makes the neutrals after the Arabic
	// right to left; at the end of a left-to-right paragraph they're left
	// to right.
	{
		kinds := []text.Bidi_Kind{.Strong, .Neutral, .Strong, .Neutral, .Neutral}
		rtl := []bool{false, false, true, true, true}
		brackets := []rune{0, 0, 0, 0, 0}
		levels := make([]u8, len(kinds), context.temp_allocator)
		text.resolve_levels(kinds, rtl, brackets, false, levels)
		testing.expect(t, slice_equal(levels, []u8{0, 0, 1, 0, 0}), "trailing neutrals")
	}
	// "Song שיר 2024 end": a number after Hebrew sits at level 2.
	{
		kinds := []text.Bidi_Kind{.Strong, .Neutral, .Strong, .Neutral, .Number, .Neutral, .Strong}
		rtl := []bool{false, false, true, true, false, false, false}
		brackets := []rune{0, 0, 0, 0, 0, 0, 0}
		levels := make([]u8, len(kinds), context.temp_allocator)
		text.resolve_levels(kinds, rtl, brackets, false, levels)
		testing.expect(t, slice_equal(levels, []u8{0, 0, 1, 1, 2, 0, 0}), "number after rtl")
	}
	// Spans of neutrals take the direction on both sides when it agrees,
	// else the paragraph's, which also stands in past either end.
	{
		kinds := []text.Bidi_Kind{.Neutral, .Strong, .Neutral, .Neutral, .Neutral, .Strong, .Neutral, .Neutral, .Strong, .Neutral, .Neutral}
		rtl := []bool{true, true, false, false, false, true, true, true, false, true, true}
		brackets := make([]rune, len(kinds), context.temp_allocator)
		levels := make([]u8, len(kinds), context.temp_allocator)
		text.resolve_levels(kinds, rtl, brackets, false, levels)
		testing.expect(t, slice_equal(levels, []u8{0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0}), "neutral spans")
	}
}

@(test)
test_collection_index :: proc(t: ^testing.T) {
	// A two-face collection whose faces each have one "name" table.
	data := make([]byte, 128, context.temp_allocator)
	put32 :: proc(data: []byte, at: int, v: u32) {
		data[at], data[at + 1], data[at + 2], data[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
	}
	copy(data, "ttcf")
	put32(data, 8, 2)
	put32(data, 12, 20)
	put32(data, 16, 48)
	for face in 0 ..< 2 {
		offset := 20 + 28 * face
		data[offset + 5] = 1 // one table
		put32(data, offset + 12, text.table_tag("name"))
		put32(data, offset + 20, u32(100 + 8 * face))
		put32(data, offset + 24, 4)
	}
	copy(data[100:], "AAAA")
	copy(data[108:], "BBBB")
	testing.expect_value(t, text.collection_index_of_table(data, "name", transmute([]byte)string("BBBB")), 1)
	testing.expect_value(t, text.collection_index_of_table(data, "name", transmute([]byte)string("AAAA")), 0)
	testing.expect_value(t, text.collection_index_of_table(data, "name", transmute([]byte)string("CCCC")), 0)
}

@(test)
test_truncate_clusters :: proc(t: ^testing.T) {
	// A base and two marks drawn on it, all one cluster: the marks sit at
	// the base's right edge with no advance.
	gs := glyphs(6)
	gs[3].cluster, gs[4].cluster = 2, 2
	gs[3].pen, gs[4].pen = 30, 30
	gs[3].advance, gs[4].advance = 0, 0
	gs[5].pen = 30
	first, last, _, ellipsis_x, _ := text.truncate(gs, 40, 33, 8, false)
	testing.expect_value(t, last, 2)
	testing.expect_value(t, ellipsis_x, 20)
	// From the right, the cut at 40 - 15 = 25 falls inside the base, so
	// the marks at 30 go with it.
	first, last, _, _, _ = text.truncate(gs, 40, 23, 8, true)
	testing.expect_value(t, first, 5)
}

@(test)
test_paragraph_direction :: proc(t: ^testing.T) {
	Case :: struct {
		s:   string,
		rtl: bool,
	}
	cases := []Case{
		{"晴天 عيونك 🔥", false},
		{"밤편지 عيونك end", false},
		{"عيونك (Remix) 2024", true},
		{"2024 שלום abc", true}, // digits are weak
		{"🔥 (abc)", false},
		{"\u2067שלום\u2069 abc", false}, // an isolate is skipped
		{"\u2067abc\u2069", false}, // nothing strong outside it
		{"«ابجد»", true},
		{"2024", false},
		{"", false},
	}
	for c in cases {
		runes := make([dynamic]rune, context.temp_allocator)
		for r in c.s {
			append(&runes, r)
		}
		testing.expectf(t, text.paragraph_is_rtl(runes[:]) == c.rtl, "%q: want rtl %v", c.s, c.rtl)
	}
}

@(private)
Shaper :: struct {
	parent:  mem.Allocator,
	backing: []byte,
	arena:   mem.Arena,
	state:   ^text.State,
	r:       render.Renderer,
}

// shaper_init loads the real fonts and starts the loader. No GPU needed:
// nothing is drawn.
@(private)
shaper_init :: proc(s: ^Shaper) -> mem.Allocator {
	s.parent = context.allocator
	s.backing = make([]byte, 64 << 20)
	mem.arena_init(&s.arena, s.backing)
	allocator := mem.arena_allocator(&s.arena)
	s.state = new(text.State, allocator)
	context.allocator = allocator
	text.init(s.state)
	text.begin_frame(s.state, &s.r)
	return allocator
}

@(private)
shaper_destroy :: proc(s: ^Shaper) {
	text.destroy(s.state, &s.r)
	delete(s.backing, s.parent)
}

// shape_loaded shapes str, waiting for any fallback font it needs.
@(private)
shape_loaded :: proc(s: ^Shaper, font: text.Font, size: f32, str: string) -> ^text.Run {
	run := text.shape(s.state, font, size, str)
	for i := 0; run.pending && i < 5000; i += 1 {
		time.sleep(time.Millisecond)
		text.begin_frame(s.state, &s.r)
		run = text.shape(s.state, font, size, str)
	}
	return run
}

// cluster_glyphs returns the glyphs of run whose cluster starts at
// codepoint cp.
@(private = "file")
cluster_glyphs :: proc(run: ^text.Run, cp: u32) -> (n: int) {
	for g in run.glyphs {
		if g.cluster == cp {
			n += 1
		}
	}
	return
}

@(test)
test_shape_direction :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	// Left-to-right paragraphs: the first strong character is Han or
	// Hangul, so the emoji and "end" stay on the right.
	run := shape_loaded(&s, .Bold, 15, "晴天 عيونك 🔥")
	testing.expect(t, !run.rtl && !run.pending)
	testing.expect_value(t, run.glyphs[0].cluster, 0)
	testing.expect_value(t, run.glyphs[len(run.glyphs) - 1].cluster, 9)

	run = shape_loaded(&s, .Regular, 13, "밤편지 عيونك end")
	testing.expect(t, !run.rtl && !run.pending)
	testing.expect_value(t, run.glyphs[0].cluster, 0)
	testing.expect_value(t, run.glyphs[len(run.glyphs) - 1].cluster, 12)

	// Right to left: the number ends up on the left, the first Arabic
	// letter on the right.
	run = shape_loaded(&s, .Regular, 13, "عيونك (Remix) 2024")
	testing.expect(t, run.rtl)
	testing.expect_value(t, run.glyphs[0].cluster, 14)
	testing.expect_value(t, run.glyphs[len(run.glyphs) - 1].cluster, 0)
	// It reads "2024 (Remix) عيونك": the brackets pair around "Remix" and
	// go right to left, so the closing one (7 to 12 is "Remix)") is on the
	// left of "Remix", drawn as an opening one, and the other way round.
	// kb_text_shape puts the closing one in the left to right run of
	// "Remix) 2024".
	remix, close, open := -1, -1, -1
	for g, i in run.glyphs {
		switch g.cluster {
		case 7:
			remix = i
		case 12:
			close = i
		case 6:
			open = i
		}
	}
	if testing.expect(t, remix >= 0 && close >= 0 && open >= 0, "every bracket and Remix drawn") {
		testing.expectf(t, close < remix && remix < open, "closing bracket at %d, Remix at %d, opening at %d", close, remix, open)
		face := &s.state.faces[run.glyphs[close].face].kb
		testing.expect_value(t, run.glyphs[close].id, u16(kbts.CodepointToGlyphId(face, '(')))
		face = &s.state.faces[run.glyphs[open].face].kb
		testing.expect_value(t, run.glyphs[open].id, u16(kbts.CodepointToGlyphId(face, ')')))
	}

	run = shape_loaded(&s, .Regular, 13, "2024 שלום abc")
	testing.expect(t, run.rtl)
	testing.expect_value(t, run.glyphs[0].cluster, 10) // "abc" on the left

	run = shape_loaded(&s, .Regular, 13, "🔥 abc")
	testing.expect(t, !run.rtl)
	testing.expect_value(t, run.glyphs[0].cluster, 0)
}

// Brackets pair by rule N0 around text of either direction, nested or
// not, and a bracket without a pair, or one BidiBrackets.txt doesn't pair,
// is an ordinary neutral. Each case lists the codepoint each glyph draws,
// from left to right.
@(test)
test_shape_brackets :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	Case :: struct {
		s:     string,
		rtl:   bool,
		order: []u32,
	}
	cases := []Case{
		{"abc (שלום) def", false, {0, 1, 2, 3, 4, 8, 7, 6, 5, 9, 10, 11, 12, 13}},
		{"שלום (abc) עולם", true, {14, 13, 12, 11, 10, 9, 6, 7, 8, 5, 4, 3, 2, 1, 0}},
		{"a (ש [ב] ג) z", false, {0, 1, 2, 9, 8, 7, 6, 5, 4, 3, 10, 11, 12}},
		{"abc (שלום", false, {0, 1, 2, 3, 4, 8, 7, 6, 5}},
		{"שלום (abc", true, {6, 7, 8, 5, 4, 3, 2, 1, 0}},
		{"Song (Remix) [Live] {x}", false, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22}},
		{"שלום （Remix） 2024", true, {13, 14, 15, 16, 12, 11, 6, 7, 8, 9, 10, 5, 4, 3, 2, 1, 0}},
		{"שלום 「Remix」 2024", true, {13, 14, 15, 16, 12, 11, 6, 7, 8, 9, 10, 5, 4, 3, 2, 1, 0}},
		{"שלום 【Live】 2024", true, {12, 13, 14, 15, 11, 10, 6, 7, 8, 9, 5, 4, 3, 2, 1, 0}},
		{"abc שלום <עולם> def", false, {0, 1, 2, 3, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 14, 15, 16, 17, 18}},
	}
	for c in cases {
		run := shape_loaded(&s, .Regular, 13, c.s)
		got := make([]u32, len(run.glyphs), context.temp_allocator)
		for g, i in run.glyphs {
			got[i] = g.cluster
		}
		testing.expectf(t, run.rtl == c.rtl && slice_equal(got, c.order), "%q: rtl %v, order %v", c.s, run.rtl, got)
	}
	// The fullwidth pair goes right to left, so each bracket draws as the
	// other.
	run := shape_loaded(&s, .Regular, 13, "שלום （Remix） 2024")
	if testing.expect_value(t, len(run.glyphs), 17) {
		for c in ([]struct {
				at:   int,
				draw: rune,
			}{{5, 0xff08}, {11, 0xff09}}) {
			g := run.glyphs[c.at]
			testing.expect_value(t, g.id, u16(kbts.CodepointToGlyphId(&s.state.faces[g.face].kb, c.draw)))
		}
	}
}

// Truncating at every width keeps or drops whole clusters, in both
// directions and from both shapers (Hebrew, Latin marks and, under SF Pro,
// Arabic with harakat through kb_text_shape; emoji sequences through
// CoreText).
@(test)
test_shape_truncate_clusters :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	ellipsis := shape_loaded(&s, .Regular, 13, text.ELLIPSIS)
	for str in ([]string{"שלום abcq̣̇x", "abcq̣̇x שלום", "مُحَمَّد abc", "👨‍👩‍👧 🇵🇱 ok", "밤편지 é̃x"}) {
		run := shape_loaded(&s, .Regular, 13, str)
		testing.expectf(t, !run.pending, "%q still pending", str)
		for i := 1; i < len(run.glyphs); i += 1 {
			// A cluster's glyphs are next to each other.
			if run.glyphs[i].cluster != run.glyphs[i - 1].cluster {
				for g in run.glyphs[i:] {
					testing.expectf(t, g.cluster != run.glyphs[i - 1].cluster, "%q: cluster %d split", str, g.cluster)
				}
			}
		}
		for w := f32(1); w < run.width; w += 0.5 {
			first, last, _, _, _ := text.truncate(run.glyphs, run.width, w, ellipsis.width, run.rtl)
			for k in first ..< last {
				c := run.glyphs[k].cluster
				kept := 0
				for g in run.glyphs[first:last] {
					if g.cluster == c {
						kept += 1
					}
				}
				if kept != cluster_glyphs(run, c) {
					testing.expectf(t, false, "%q at %v: cluster %d cut", str, w, c)
					break
				}
			}
		}
	}

	// The case from the review: 13 pt, 28 pt wide. The marks on q stay or
	// go with it.
	run := shape_loaded(&s, .Regular, 13, "שלום abcq̣̇x")
	testing.expect(t, run.rtl)
	first, last, _, _, _ := text.truncate(run.glyphs, run.width, 28, ellipsis.width, run.rtl)
	q := 0
	for g in run.glyphs[first:last] {
		if g.cluster == 8 {
			q += 1
		}
	}
	testing.expect(t, q == 0 || q == 3, "q and its marks together")
}

// Shaping with the real fonts. No GPU needed: nothing is drawn.
@(test)
test_shape :: proc(t: ^testing.T) {
	sh: Shaper
	context.allocator = shaper_init(&sh)
	defer shaper_destroy(&sh)
	state := sh.state

	a := text.shape(state, .Regular, 13, "Blue in Green")
	testing.expect(t, a.width > 50 && a.width < 120)
	testing.expect_value(t, len(a.glyphs), 13)
	testing.expect(t, !a.rtl)
	testing.expect(t, text.shape(state, .Regular, 13, "Blue in Green") == a, "cache hit")
	testing.expect_value(t, state.stats.shaped, 1)
	bold := text.shape(state, .Bold, 13, "Blue in Green")
	testing.expect(t, bold.width > a.width, "bold is wider")
	// The weights are instances of one variable font, SF Pro or Noto Sans,
	// shaped at their own wght.
	width: f32
	for font in ([]text.Font{.Regular, .Medium, .Semibold, .Bold}) {
		w := text.shape(state, font, 13, "Blue in Green").width
		testing.expectf(t, w > width, "%v is wider than the weight below", font)
		width = w
	}

	arabic := shape_loaded(&sh, .Regular, 13, "عيونك")
	testing.expect(t, arabic.rtl)
	testing.expect(t, len(arabic.glyphs) > 0 && arabic.glyphs[0].face >= u8(len(text.Font)), "Arabic comes from a fallback face")

	cjk := shape_loaded(&sh, .Regular, 13, "夜に駆ける")
	testing.expect_value(t, len(cjk.glyphs), 5)
	for g in cjk.glyphs {
		testing.expect(t, g.id != 0 && g.face >= u8(len(text.Font)), "CJK glyph from a fallback face")
	}

	// Pens increase left to right.
	mixed := shape_loaded(&sh, .Regular, 13, "abc ابجد 123 هوز def")
	for i in 1 ..< len(mixed.glyphs) {
		testing.expect(t, mixed.glyphs[i].pen >= mixed.glyphs[i - 1].pen)
	}

	m := text.measure(state, .Regular, 13, "Blue in Green")
	testing.expect_value(t, m.width, a.width)
}

@(private = "file")
slice_equal :: proc(a, b: []$T) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if v != b[i] {
			return false
		}
	}
	return true
}

// Every glyph keeps the index of its own character through shaping, so
// repeated characters each get their own cluster, in kb_text_shape (Hangul,
// Latin with marks, Devanagari with a reordered vowel sign, Thai with sara
// am split in two) and CoreText (Arabic).
@(test)
test_repeated_clusters :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	Case :: struct {
		str:      string,
		clusters: []u32, // the distinct clusters in logical order
	}
	cases := []Case{
		{"밤밤편지", {0, 1, 2, 3}},
		{"가가가", {0, 1, 2}},
		{"ééx", {0, 1, 2}},
		{"ééx", {0, 2, 4}},
		{"q̣̇q̣̇", {0, 3}},
		{"किकि", {0, 2}},
		{"น้ำน้ำ", {0, 3}},
		{"ببب", {0, 1, 2}},
		{"عيونك عيونك", {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}},
	}
	for c in cases {
		run := shape_loaded(&s, .Regular, 13, c.str)
		testing.expectf(t, !run.pending, "%q still pending", c.str)
		// In visual order: rising left to right, falling right to left.
		seen := make([dynamic]u32, context.temp_allocator)
		for k in 0 ..< len(run.glyphs) {
			g := run.glyphs[len(run.glyphs) - 1 - k if run.rtl else k]
			if len(seen) == 0 || seen[len(seen) - 1] != g.cluster {
				append(&seen, g.cluster)
			}
		}
		testing.expectf(t, slice_equal(seen[:], c.clusters), "%q: clusters %v, want %v", c.str, seen[:], c.clusters)
	}

	// The case from the review: the two leading syllables are kept or
	// dropped one at a time.
	ellipsis := shape_loaded(&s, .Regular, 13, text.ELLIPSIS)
	run := shape_loaded(&s, .Regular, 13, "밤밤편지")
	two := run.glyphs[1].pen + run.glyphs[1].advance
	_, last, _, _, _ := text.truncate(run.glyphs, run.width, two + ellipsis.width + 0.1, ellipsis.width, false)
	testing.expect_value(t, last, 2)
}

// A character no font has is asked of the loader once, even after the
// fallback cache's first table fills up, and the run stops being pending.
@(test)
test_fallback_cache_limit :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)
	state := s.state

	testing.expect(t, !shape_loaded(&s, .Regular, 13, "가 夜 ب").pending)
	// Fill the table to the point where it used to drop new keys, with keys
	// no lookup makes.
	capacity := len(state.fallback_cache)
	for i := 0; state.fallback_used < capacity * 3 / 4; i += 1 {
		if state.fallback_cache[i].key == 0 {
			state.fallback_cache[i] = {key = 1 << 62 | u64(i), face = text.NO_FACE}
			state.fallback_used += 1
		}
	}

	run := shape_loaded(&s, .Regular, 13, "a͸b")
	testing.expect(t, !run.pending, "settles")
	testing.expect(t, len(state.fallback_cache) > capacity, "the table grew")
	generation := state.generation
	for _ in 0 ..< 10 {
		time.sleep(2 * time.Millisecond)
		text.begin_frame(state, &s.r)
		run = text.shape(state, .Regular, 13, "a͸b")
		testing.expect(t, !run.pending)
		testing.expect_value(t, state.stats.shaped, 0)
		testing.expect(t, !text.loading(state), "nothing asked again")
	}
	testing.expect_value(t, state.generation, generation)
}

// A loader result for a character the fallback faces turned out to have
// while it looked doesn't replace the face runs already use.
@(test)
test_loader_keeps_scanned_fallback :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)
	state := s.state

	cjk := shape_loaded(&s, .Regular, 13, "夜")
	arabic := shape_loaded(&s, .Regular, 13, "ب")
	if !testing.expect(t, !cjk.pending && !arabic.pending) {
		return
	}
	cjk_face, arabic_face := int(cjk.glyphs[0].face), int(arabic.glyphs[0].face)
	testing.expect(t, cjk_face != arabic_face)

	// The loader was asked for 龍 and hasn't answered yet.
	key := (u64(text.Font.Regular) + 1) << 32 | u64('龍')
	slot := int(text.mix64(key)) & (len(state.fallback_cache) - 1)
	for state.fallback_cache[slot].key != 0 && state.fallback_cache[slot].key != key {
		slot = (slot + 1) & (len(state.fallback_cache) - 1)
	}
	if state.fallback_cache[slot].key == 0 {
		state.fallback_used += 1
	}
	state.fallback_cache[slot] = {key, text.PENDING}

	run := text.shape(state, .Regular, 13, "龍 1")
	testing.expect(t, !run.pending)
	testing.expect_value(t, int(run.glyphs[0].face), cjk_face)

	for i := 0; text.loading(state) && i < 5000; i += 1 {
		time.sleep(time.Millisecond)
		text.begin_frame(state, &s.r)
	}
	l := &state.loader
	sync.mutex_lock(&l.mutex)
	l.results[l.result_count] = {font = .Regular, codepoint = '龍', found = state.faces[arabic_face].name}
	l.result_count += 1
	sync.mutex_unlock(&l.mutex)
	text.begin_frame(state, &s.r)

	run = text.shape(state, .Regular, 13, "龍 2")
	testing.expect_value(t, int(run.glyphs[0].face), cjk_face)
}

// A default ignorable a font doesn't map, like U+FE0F in Noto Color Emoji,
// doesn't stop the font covering the cluster: the shaper hides it anyway.
// The system font has no U+180B, a Mongolian variation selector.
@(test)
test_coverage_skips_default_ignorables :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	font := &s.state.faces[text.Font.Regular].kb
	testing.expect(t, kbts.CodepointToGlyphId(font, 0x180b) == 0, "the font has no U+180B")
	test: kbts.font_coverage_test
	kbts.FontCoverageTestBegin(&test, font)
	kbts.FontCoverageTestCodepoint(&test, 'a')
	kbts.FontCoverageTestCodepoint(&test, 0x180b)
	testing.expect(t, bool(kbts.FontCoverageTestEnd(&test)), "a + U+180B is covered")
}

// An emoji next to Hebrew comes from the colour face even when the face
// found for the Hebrew has a black and white one, as DejaVu Sans does.
@(test)
test_emoji_next_to_hebrew_is_colour :: proc(t: ^testing.T) {
	sh: Shaper
	context.allocator = shaper_init(&sh)
	defer shaper_destroy(&sh)

	hebrew := shape_loaded(&sh, .Regular, 13, "שלום")
	testing.expect(t, !hebrew.pending)
	for str in ([]string{"😀", "😀 שלום", "שלום ✌ 😀"}) {
		run := shape_loaded(&sh, .Regular, 13, str)
		testing.expectf(t, !run.pending, "%q still pending", str)
		runes := utf8.string_to_runes(str, context.temp_allocator)
		for g in run.glyphs {
			r := runes[g.cluster]
			if r == '😀' || r == '✌' {
				testing.expectf(t, sh.state.faces[g.face].color, "%q: %c drawn from a face without colour", str, r)
			}
		}
	}
}

// An empty string measures as nothing. kb_text_shape crashes on no
// codepoints, so a label with no text must never reach it.
@(test)
test_measure_empty :: proc(t: ^testing.T) {
	f: Fonts
	if !testing.expect(t, fonts_init(&f)) {
		return
	}
	defer fonts_destroy(&f)
	m := text.measure(f.state, .Semibold, 14, "")
	testing.expect_value(t, m.width, f32(0))
}

// A text field's caret sits on the leading edge of the cluster after it:
// the right edge of a Hebrew letter even when Latin follows it, and for a
// space or a digit, the edge its neighbours' direction gives.
@(test)
test_field_caret_mixed_direction :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	glyph_of :: proc(run: ^text.Run, cluster: u32) -> text.Glyph {
		for g in run.glyphs {
			if g.cluster == cluster {
				return g
			}
		}
		return {}
	}
	Case :: struct {
		str:     string,
		offset:  int, // a byte offset in str
		cluster: u32, // the codepoint index that starts there
		right:   bool, // the caret goes on the cluster's right edge
	}
	cases := []Case{
		{"aאבb", len("a"), 1, true},
		{"aאבb", len("aא"), 2, true},
		{"aאb", len("a"), 1, true},
		{"aאb", len("aא"), 2, false},
		{"אב גד", len("אב"), 2, true},
		{"a אב", len("a"), 1, false},
		{"א12ב", len("א"), 1, false},
		{"א12ב", len("א1"), 2, false},
	}
	for c in cases {
		run := shape_loaded(&s, .Regular, 13, c.str)
		testing.expectf(t, !run.pending, "%q still pending", c.str)
		g := glyph_of(run, c.cluster)
		want := g.pen + g.advance if c.right else g.pen
		lay := ui.field_layout(s.state, .Regular, 13, c.str)
		caret := ui.field_caret_x(lay, c.offset)
		testing.expectf(t, abs(caret - want) < 0.01, "%q at %d: caret %v, want %v", c.str, c.offset, caret, want)
	}
}

// A selection is drawn as its pieces on screen, left to right: one for a
// run in one direction, however long, and two for Latin split by Hebrew.
@(test)
test_field_selection_spans :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	long := strings.repeat("שלום ", 300, context.temp_allocator)
	run := shape_loaded(&s, .Regular, 13, long)
	testing.expect(t, !run.pending)
	lay := ui.field_layout(s.state, .Regular, 13, long)
	spans := ui.field_spans(lay, 0, len(long))
	testing.expectf(t, len(spans) == 1 && abs(spans[0].x) < 0.01 && abs(spans[0].y - run.width) < 0.01, "all of %d clusters: %v, want [0, %v]", len(lay.bounds) - 1, spans, run.width)

	mixed := "ab אב cd"
	run = shape_loaded(&s, .Regular, 13, mixed)
	lay = ui.field_layout(s.state, .Regular, 13, mixed)
	// "b א" is b on the left, then the space, then א at the right end of
	// the Hebrew word: two pieces with ב between them.
	spans = ui.field_spans(lay, len("a"), len("ab א"))
	testing.expectf(t, len(spans) == 2 && spans[0].x < spans[1].x, "%q: %v", mixed, spans)
}

// Dragging in a text field selects from the press to the mouse, by
// clusters, or by words after a double-click.
@(test)
test_text_field_drag_select :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)
	u: ui.State
	ui.init(&u)
	f := new(ui.Text_Field)
	ui.field_insert(f, "hello big world")
	shape_loaded(&s, .Regular, 13, "hello big world")
	now := 0.0
	frame :: proc(u: ^ui.State, s: ^Shaper, f: ^ui.Text_Field, now: ^f64, events: ..platform.Event) {
		now^ += 0.016
		ui.begin_frame(u, events, nil, s.state, 300, 200, now^)
		ui.text_field("search", f, "Search", ui.px(250), 30)
		ui.end_frame()
	}
	frame(&u, &s, f, &now)
	frame(&u, &s, f, &now)
	frame(&u, &s, f, &now, {kind = .Mouse_Down, x = 9, y = 15, button = .Left, click_count = 1})
	frame(&u, &s, f, &now, {kind = .Mouse_Move, x = 240, y = 15})
	frame(&u, &s, f, &now, {kind = .Mouse_Up, x = 240, y = 15, button = .Left})
	testing.expect_value(t, ui.field_selected(f), "hello big world")

	frame(&u, &s, f, &now, {kind = .Mouse_Down, x = 240, y = 15, button = .Left, click_count = 2})
	testing.expect_value(t, ui.field_selected(f), "world")
	frame(&u, &s, f, &now, {kind = .Mouse_Move, x = 9, y = 15})
	frame(&u, &s, f, &now, {kind = .Mouse_Up, x = 9, y = 15, button = .Left})
	testing.expect_value(t, ui.field_selected(f), "hello big world")
	testing.expect_value(t, f.cursor, 0)
}

// Text at size 0 measures as nothing, not NaN, even in a face shaped at
// an optical size of 0, with tracking for size 0.
@(test)
test_measure_size_zero :: proc(t: ^testing.T) {
	f: Fonts
	if !testing.expect(t, fonts_init(&f)) {
		return
	}
	defer fonts_destroy(&f)
	m := text.measure(f.state, .Regular, 0, "Size")
	testing.expect_value(t, m.width, f32(0))
}

// A working set bigger than three quarters of the run cache, all of it
// drawn every frame, fits, so begin_frame leaves it alone instead of
// sweeping every frame.
@(test)
test_large_working_set_is_not_swept_every_frame :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)
	state := s.state

	n := text.RUN_CAPACITY / 2 * 7 / 8
	draw_all :: proc(state: ^text.State, n: int) {
		buf: [16]byte
		for i in 0 ..< n {
			text.shape(state, .Regular, 13, strconv.write_int(buf[:], i64(i), 10))
		}
	}
	draw_all(state, n)
	testing.expect_value(t, state.run_count, n)
	last := state.last_sweep
	for _ in 0 ..< 5 {
		free_all(context.temp_allocator)
		text.begin_frame(state, &s.r)
		draw_all(state, n)
		testing.expect_value(t, state.stats.shaped, 0)
	}
	testing.expect_value(t, state.last_sweep, last)
}

// Shaped text and the editor split a string into the same grapheme
// clusters: shaping takes them from kb_text_shape's shaper, the editor
// from its break engine.
@(test)
test_shaped_clusters_match_grapheme_starts :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	for str in ([]string{"밤편지 é̃x", "q̣̇q̣̇", "किकि नमस्ते", "น้ำน้ำ", "👨‍👩‍👧 🇵🇱 ok", "👍🏽 ❤️", "é̂ b"}) {
		run := shape_loaded(&s, .Regular, 13, str)
		testing.expectf(t, !run.pending, "%q still pending", str)
		runes := utf8.string_to_runes(str, context.temp_allocator)
		starts := text.grapheme_starts(runes)
		want := make(map[u32]bool, context.temp_allocator)
		for start in starts {
			want[u32(start)] = true
		}
		got := make(map[u32]bool, context.temp_allocator)
		for g in run.glyphs {
			got[g.cluster] = true
		}
		testing.expectf(t, len(got) == len(want), "%q: %d clusters drawn, %d in the editor", str, len(got), len(want))
		for c in got {
			testing.expectf(t, want[c], "%q: cluster %d isn't a grapheme start", str, c)
		}
	}
}

// Noto Sans kerns "&T" by -60 units in every instance: its value record
// has a variation device whose index is NO_VARIATION_INDEX (0xFFFF, 0xFFFF),
// as fontTools writes for values that don't vary. kb_text_shape read past its
// variation store for it, which crashed on Windows. The tables sit at the
// end of committed memory, so a read past them faults on every system.
@(test)
test_kern_without_variation :: proc(t: ^testing.T) {
	data := #load("../assets/fonts/NotoSans-Variable.ttf")
	font: kbts.font
	state: kbts.load_font_state
	scratch_size, out_size, err := kbts.LoadFont(&font, &state, data, 0)
	if !testing.expect_value(t, err, kbts.load_font_error.NEED_TO_CREATE_BLOB) {
		return
	}
	scratch := make([]byte, max(scratch_size, 1))
	defer delete(scratch)
	GRANULE :: 64 << 10
	committed := uint(out_size + GRANULE - 1) / GRANULE * GRANULE
	reserved, reserve_err := virtual.reserve(committed + GRANULE)
	if !testing.expect_value(t, reserve_err, nil) {
		return
	}
	defer virtual.release(raw_data(reserved), len(reserved))
	if !testing.expect_value(t, virtual.commit(raw_data(reserved), committed), nil) {
		return
	}
	blob := reserved[committed - uint(out_size + 15) / 16 * 16:committed]
	if !testing.expect_value(t, kbts.PlaceBlob(&font, &state, raw_data(scratch), raw_data(blob)), kbts.load_font_error.NONE) {
		return
	}
	memory := make([]byte, 1 << 20)
	defer delete(memory)
	ctx := kbts.PlaceShapeContextFixedMemory(memory)

	first_advance :: proc(ctx: ^kbts.shape_context, font: ^kbts.font, weight: f32, s: string) -> i32 {
		v := kbts.variation{Tag = u32('w') | u32('g') << 8 | u32('h') << 16 | u32('t') << 24, Value = weight}
		_ = kbts.ShapePushFont2(ctx, font, &v, 1, nil)
		defer _ = kbts.ShapePopFont(ctx)
		kbts.ShapeBegin(ctx, .KBTS_DIRECTION_LTR, .DONT_KNOW)
		for r in s {
			kbts.ShapeCodepoint(ctx, r)
		}
		kbts.ShapeEnd(ctx)
		advance: i32
		first := true
		for {
			run, ok := kbts.ShapeRun(ctx)
			if !ok {
				break
			}
			for g in kbts.GlyphIteratorNext(&run.Glyphs) {
				if first {
					advance, first = g.AdvanceX, false
				}
			}
		}
		return advance
	}
	for weight in ([]f32{400, 700}) {
		kern := first_advance(ctx, &font, weight, "&T") - first_advance(ctx, &font, weight, "&")
		testing.expectf(t, kern == -60, "&T kerns %v units at wght %v", kern, weight)
	}
	testing.expect_value(t, kbts.ShapeError(ctx), kbts.shape_error.NONE)
}
