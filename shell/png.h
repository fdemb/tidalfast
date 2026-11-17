// A PNG of the Now Playing artwork, for the systems that take a cover as a
// file or a stream rather than as pixels: MPRIS on Linux and the System
// Media Transport Controls on Windows.
#pragma once

#include <stddef.h>
#include <stdint.h>

// png_encode makes a PNG of width by height premultiplied RGBA8 pixels,
// stored without compression. The caller frees it; NULL if out of memory.
uint8_t *png_encode(const uint8_t *rgba, uint32_t width, uint32_t height, size_t *size);
