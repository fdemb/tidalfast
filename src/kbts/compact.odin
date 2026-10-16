package kbts

import "core:c"

foreign import lib { LIB_PATH }

// Not part of Odin's bindings: tidalfast_compact_blob is added at the end
// of kb_text_shape.c. It copies a placed blob into output without the zeros
// of its glyph lookup matrices or its vertical metrics, returning the size
// output needs (nothing is written when output is nil), or 0 when there is
// nothing to compact.
@(default_calling_convention = "c")
foreign lib {
	tidalfast_compact_blob :: proc(blob: rawptr, output: rawptr) -> c.int ---
}
