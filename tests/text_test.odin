package tidal_tests

import "core:mem"
import "core:testing"
import "core:time"

import "../src/kbts"
import "../src/render"
import "../src/text"

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

	g := text.glyph_key(0, 0, 26, 0)
	testing.expect(t, g != 0)
	testing.expect(t, text.glyph_key(0, 0, 26, 1) != g)
	testing.expect(t, text.glyph_key(1, 0, 26, 0) != g)
	testing.expect(t, text.glyph_key(0, 1, 26, 0) != g)
	testing.expect(t, text.glyph_key(0, 0, 26.25, 0) != g)
	testing.expect_value(t, text.glyph_key(0, 0, 26.01, 0), g) // quarter pixel steps
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
	testing.expect_value(t, text.collection_index_of_table(data, text.table_tag("name"), transmute([]byte)string("BBBB")), 1)
	testing.expect_value(t, text.collection_index_of_table(data, text.table_tag("name"), transmute([]byte)string("AAAA")), 0)
	testing.expect_value(t, text.collection_index_of_table(data, text.table_tag("name"), transmute([]byte)string("CCCC")), 0)
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

	run = shape_loaded(&s, .Regular, 13, "2024 שלום abc")
	testing.expect(t, run.rtl)
	testing.expect_value(t, run.glyphs[0].cluster, 10) // "abc" on the left

	run = shape_loaded(&s, .Regular, 13, "🔥 abc")
	testing.expect(t, !run.rtl)
	testing.expect_value(t, run.glyphs[0].cluster, 0)
}

// Truncating at every width keeps or drops whole clusters, in both
// directions and from both shapers (Hebrew and Latin marks through
// kb_text_shape, Arabic with harakat and emoji sequences through CoreText).
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

// unload stops the loader thread as a hot reload does, and reload starts it
// again. Fonts asked for in between load after the restart.
@(test)
test_loader_restart :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	testing.expect(t, !shape_loaded(&s, .Regular, 13, "שלום").pending)
	text.unload(s.state)
	testing.expect(t, !s.state.loader.running)
	run := text.shape(s.state, .Regular, 13, "เพลงรัก")
	testing.expect(t, run.pending)
	time.sleep(20 * time.Millisecond)
	testing.expect(t, text.loading(s.state), "nothing loads while stopped")
	text.reload(s.state)
	testing.expect(t, s.state.loader.running)
	run = shape_loaded(&s, .Regular, 13, "เพลงรัก")
	testing.expect(t, !run.pending)
	for g in run.glyphs {
		testing.expect(t, g.id != 0 && g.face >= u8(len(text.Font)), "Thai from a fallback face")
	}
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

// A default ignorable a font doesn't map, like U+FE0F in Noto Color Emoji,
// doesn't stop the font covering the cluster: the shaper hides it anyway.
// Inter has no U+180B, a Mongolian variation selector.
@(test)
test_coverage_skips_default_ignorables :: proc(t: ^testing.T) {
	s: Shaper
	context.allocator = shaper_init(&s)
	defer shaper_destroy(&s)

	inter := &s.state.faces[text.Font.Regular].kb
	testing.expect(t, kbts.CodepointToGlyphId(inter, 0x180b) == 0, "Inter has no U+180B")
	test: kbts.font_coverage_test
	kbts.FontCoverageTestBegin(&test, inter)
	kbts.FontCoverageTestCodepoint(&test, 'a')
	kbts.FontCoverageTestCodepoint(&test, 0x180b)
	testing.expect(t, bool(kbts.FontCoverageTestEnd(&test)), "a + U+180B is covered")
}
