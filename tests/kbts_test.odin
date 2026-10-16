package tidal_tests

import "core:c"
import "core:hash"
import "core:os"
import "core:testing"

import "../src/kbts"

// The text loader keeps fonts as blobs compacted by tidalfast_compact_blob.
// Shaping with one must give exactly the glyphs, advances, offsets and
// clusters of the blob kb_text_shape placed. The bundled Inter always runs;
// the system's CJK, Arabic and Indic fonts run where they are installed.
@(test)
test_compact_blob_shapes_the_same :: proc(t: ^testing.T) {
	Font_File :: struct {
		path:  string,
		index: int,
	}
	files := []Font_File {
		{"assets/fonts/Inter-Regular.ttf", 0},
		{"assets/fonts/Inter-Bold.ttf", 0},
		{"/System/Library/Fonts/Hiragino Sans GB.ttc", 0},
		{"/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", 0},
		{"/System/Library/Fonts/AppleSDGothicNeo.ttc", 0},
		{"/System/Library/Fonts/SFArabic.ttf", 0},
		{"/System/Library/Fonts/SFHebrew.ttf", 0},
		{"/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 0},
		{"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 0},
		{"/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", 2},
		{"/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf", 0},
		{"/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf", 0},
		{"/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf", 0},
	}
	texts := []string {
		"Hello, World! office ffi fl AV To Wa 1/2 Jóga Sigur Rós Ærøskøbing",
		"東京都の天気は晴れ。音楽を聴きながら、コーヒーを飲む。「ジョーカー」（２０１９）",
		"我们的歌：周杰伦《七里香》，一路向北。",
		"안녕하세요, 아이유의 좋은 날 ㄱㅏㄴㅏ",
		"مرحبا بالعالم، أغنية فيروز «نسم علينا الهوى» لا إله إلا الله",
		"שָׁלוֹם עוֹלָם, עִבְרִית",
		"नमस्ते दुनिया, क्षत्रिय र्क",
		"สวัสดีครับ ภาษาไทย",
	}
	shaper_memory := make([]byte, 4 << 20)
	defer delete(shaper_memory)
	shape :: proc(memory: []byte, f: ^kbts.font, s: string) -> (h: u64, glyphs: int) {
		ctx := kbts.PlaceShapeContextFixedMemory(memory)
		_ = kbts.ShapePushFont(ctx, f)
		kbts.ShapeBegin(ctx, .DONT_KNOW, .DONT_KNOW)
		kbts.ShapeUtf8(ctx, s, .CODEPOINT_INDEX)
		kbts.ShapeEnd(ctx)
		h = 14695981039346656037
		for {
			run, ok := kbts.ShapeRun(ctx)
			if !ok {
				break
			}
			for g in kbts.GlyphIteratorNext(&run.Glyphs) {
				v := [6]i32{i32(g.Id), g.AdvanceX, g.AdvanceY, g.OffsetX, g.OffsetY, i32(g.UserIdOrCodepointIndex)}
				h = hash.fnv64a(([^]byte)(&v)[:size_of(v)], h)
				glyphs += 1
			}
		}
		return
	}

	compacted := 0
	for file in files {
		data, err := os.read_entire_file(file.path, context.allocator)
		if err != nil {
			continue
		}
		defer delete(data)

		dense: kbts.font
		state: kbts.load_font_state
		scratch_size, out_size, load_err := kbts.LoadFont(&dense, &state, data, c.int(file.index))
		if load_err != .NEED_TO_CREATE_BLOB {
			continue
		}
		scratch := make([]byte, max(scratch_size, 1))
		defer delete(scratch)
		blob := make([]byte, max(out_size, 1))
		defer delete(blob)
		testing.expect_value(t, kbts.PlaceBlob(&dense, &state, raw_data(scratch), raw_data(blob)), kbts.load_font_error.NONE)

		size := kbts.tidalfast_compact_blob(raw_data(blob), nil)
		if size <= 0 {
			continue
		}
		small_blob := make([]byte, size)
		defer delete(small_blob)
		testing.expect_value(t, kbts.tidalfast_compact_blob(raw_data(blob), raw_data(small_blob)), size)
		small: kbts.font
		_, _, load_err = kbts.LoadFont(&small, &state, small_blob, 0)
		testing.expect_value(t, load_err, kbts.load_font_error.NONE)
		compacted += 1

		for s in texts {
			want, glyphs := shape(shaper_memory, &dense, s)
			got, _ := shape(shaper_memory, &small, s)
			testing.expectf(t, got == want, "%s: %q shapes differently from a compacted blob", file.path, s)
			testing.expectf(t, glyphs > 0, "%s: %q has no glyphs", file.path, s)
		}
	}
	testing.expect(t, compacted >= 2, "no font compacted; run from the repository root")
}
