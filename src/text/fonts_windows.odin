package text

// Fallback fonts on Windows: Segoe UI at the font's weight, then the first
// font in WINDOWS_FALLBACKS, in the Windows fonts folder, whose cmap has
// the character. They are the UI fonts Windows 10 and 11 use for each
// script, in about the order Windows' own fallback tries them; some come
// in optional font packages, so a font that isn't there is skipped. Segoe
// UI Emoji comes first for characters drawn as emoji, its colour layers
// (COLR) drawn in colour by fonts_freetype.odin.
//
// DirectWrite's IDWriteFontFallback would also find fonts the user
// installed. It is COM, and this list covers what a stock system draws.
// The rest of the text code is FreeType's, shared with Linux
// (fonts_freetype.odin).

import "core:os"
import "core:strings"

// SEGOE_WEIGHTS are Segoe UI's files for each font's weight, tried before
// the list.
@(private)
SEGOE_WEIGHTS := [Font]string {
	.Regular   = "segoeui.ttf",
	.Medium    = "seguisb.ttf",
	.Semibold  = "seguisb.ttf",
	.Bold      = "segoeuib.ttf",
	.Icon      = "segoeuib.ttf",
	.Icon_Fill = "segoeuib.ttf",
}

@(private)
WINDOWS_EMOJI :: "seguiemj.ttf"

@(private)
WINDOWS_FALLBACKS := [?]string {
	"seguisym.ttf", // symbols, arrows, dingbats
	"msyh.ttc", // Microsoft YaHei UI: Chinese, simplified
	"YuGothM.ttc", // Yu Gothic UI: Japanese
	"malgun.ttf", // Malgun Gothic: Korean
	"msjh.ttc", // Microsoft JhengHei UI: Chinese, traditional
	"Nirmala.ttc", // Nirmala UI: Indic scripts, Windows 11
	"Nirmala.ttf", // the same on Windows 10
	"LeelawUI.ttf", // Leelawadee UI: Thai, Lao, Khmer
	"ebrima.ttf", // African scripts
	"mmrtext.ttf", // Myanmar
	"himalaya.ttf", // Tibetan
	"seguihis.ttf", // historic scripts
	"meiryo.ttc", // Japanese, older systems
	"simsun.ttc", // Chinese, older systems
	"tahoma.ttf", // what Wine has
	"arial.ttf",
	WINDOWS_EMOJI,
}

@(private)
fonts_dir :: proc() -> string {
	windir := os.get_env("WINDIR", context.temp_allocator)
	if windir == "" {
		windir = "C:\\Windows"
	}
	return strings.concatenate({windir, "\\Fonts\\"}, context.temp_allocator)
}

// load finds a fallback font with the request's character and loads it.
@(private)
load :: proc(l: ^Loader, req: Load_Request) -> (res: Load_Result) {
	res.request = req
	r := req.codepoint
	dir := fonts_dir()
	try :: proc(l: ^Loader, dir, file: string, r: rune, res: ^Load_Result) -> bool {
		path := strings.clone_to_cstring(strings.concatenate({dir, file}, context.temp_allocator), context.temp_allocator)
		return known_or_load(l, path, 0, r, res)
	}
	if emoji_presentation(r) && try(l, dir, WINDOWS_EMOJI, r, &res) {
		return
	}
	if try(l, dir, SEGOE_WEIGHTS[req.font], r, &res) {
		return
	}
	for file in WINDOWS_FALLBACKS {
		if try(l, dir, file, r, &res) {
			return
		}
	}
	return
}
