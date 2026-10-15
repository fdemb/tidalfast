#include <stdint.h>
#ifndef _MSC_VER
  #include <string.h>
#endif

#define KB_TEXT_SHAPE_NO_CRT
#define KB_TEXT_SHAPE_IMPLEMENTATION
#include "kb_text_shape.h"

// Added for TIDALfast: kb_text_shape's Unicode bidi class table, which the
// library doesn't export. Returns a kbts_unicode_bidirectional_class.
int tidalfast_bidi_class(int Codepoint)
{
  return kbts__GetUnicodeBidirectionalClass((kbts_u32)Codepoint);
}
