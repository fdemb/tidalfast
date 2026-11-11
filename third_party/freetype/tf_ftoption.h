/* FreeType's own options, less the two that need code the Windows build
   doesn't link: zlib, for WOFF and compressed SVG glyphs, and OT-SVG
   itself. build.py points FT_CONFIG_OPTIONS_H here. */
#include <freetype/config/ftoption.h>
#undef FT_CONFIG_OPTION_USE_ZLIB
#undef FT_CONFIG_OPTION_SVG
