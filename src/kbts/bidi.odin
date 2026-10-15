package kbts

import "core:c"

foreign import lib { LIB_PATH }

// Not part of Odin's bindings: tidalfast_bidi_class is added at the end of
// kb_text_shape.c.

// kbts_unicode_bidirectional_class. NI covers every neutral, including the
// isolate and embedding controls.
Bidi_Class :: enum u8 {
	NI,
	BN,
	L,
	R,
	NSM,
	AL,
	AN,
	EN,
	ES,
	ET,
	CS,
}

@(default_calling_convention = "c")
foreign lib {
	tidalfast_bidi_class :: proc(codepoint: c.int) -> c.int ---
}

bidi_class :: proc "contextless" (r: rune) -> Bidi_Class {
	return Bidi_Class(tidalfast_bidi_class(c.int(r)))
}
