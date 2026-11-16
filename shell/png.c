// See png.h. The image data is deflate's stored blocks, which every
// decoder reads: a cover is written once a track, and compressing it would
// cost more than the bytes it saves on a local file or stream. It runs on
// the main thread, so the checksums go eight bytes at a time (CRC-32) and
// thousands of bytes per modulo (Adler-32): a 640x640 cover takes about a
// millisecond.

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "png.h"

// Slicing-by-8: table k gives the CRC of a byte followed by k zero bytes.
static uint32_t g_crc[8][256];

static void crc_init(void) {
  if (g_crc[0][1]) return;
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = c & 1 ? 0xedb88320u ^ (c >> 1) : c >> 1;
    g_crc[0][i] = c;
  }
  for (uint32_t i = 0; i < 256; i++)
    for (int k = 1; k < 8; k++) g_crc[k][i] = (g_crc[k - 1][i] >> 8) ^ g_crc[0][g_crc[k - 1][i] & 0xff];
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *p, size_t n) {
  for (; n >= 8; n -= 8, p += 8) {
    uint32_t lo = crc ^ ((uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24);
    crc = g_crc[7][lo & 0xff] ^ g_crc[6][(lo >> 8) & 0xff] ^ g_crc[5][(lo >> 16) & 0xff] ^ g_crc[4][lo >> 24] ^ g_crc[3][p[4]] ^
          g_crc[2][p[5]] ^ g_crc[1][p[6]] ^ g_crc[0][p[7]];
  }
  while (n--) crc = g_crc[0][(crc ^ *p++) & 0xff] ^ (crc >> 8);
  return crc;
}

// 5552 is the most bytes whose sums can't overflow 32 bits before the modulo.
static void adler32_update(uint32_t *a, uint32_t *b, const uint8_t *p, size_t n) {
  while (n) {
    size_t m = n < 5552 ? n : 5552;
    n -= m;
    while (m--) {
      *a += *p++;
      *b += *a;
    }
    *a %= 65521;
    *b %= 65521;
  }
}

static uint8_t *put_be32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24), p[1] = (uint8_t)(v >> 16), p[2] = (uint8_t)(v >> 8), p[3] = (uint8_t)v;
  return p + 4;
}

// chunk writes a chunk whose data is already at p + 8, len bytes of it.
static uint8_t *chunk(uint8_t *p, const char *type, uint32_t len) {
  put_be32(p, len);
  memcpy(p + 4, type, 4);
  uint32_t crc = crc32_update(0xffffffffu, p + 4, 4 + (size_t)len) ^ 0xffffffffu;
  return put_be32(p + 8 + len, crc);
}

static uint8_t unpremultiply(uint32_t c, uint32_t alpha) {
  if (alpha == 0) return 0;
  uint32_t v = (c * 255 + alpha / 2) / alpha;
  return (uint8_t)(v > 255 ? 255 : v);
}

uint8_t *png_encode(const uint8_t *rgba, uint32_t width, uint32_t height, size_t *size) {
  crc_init();
  size_t row = 1 + (size_t)width * 4;
  size_t raw_size = row * height;
  size_t blocks = raw_size / 65535 + 1;
  size_t idat = 2 + raw_size + blocks * 5 + 4;
  if (idat > 0x7fffffff) return NULL;
  uint8_t *raw = malloc(raw_size ? raw_size : 1);
  uint8_t *out = malloc(8 + (12 + 13) + (12 + idat) + 12);
  if (!raw || !out) {
    free(raw);
    free(out);
    return NULL;
  }

  // The scanlines, each a filter byte (none) and the row unpremultiplied.
  for (uint32_t y = 0; y < height; y++) {
    uint8_t *r = raw + y * row;
    const uint8_t *px = rgba + (size_t)y * width * 4;
    r[0] = 0;
    memcpy(r + 1, px, (size_t)width * 4);
    for (uint32_t x = 0; x < width; x++) {
      uint8_t *q = r + 1 + (size_t)x * 4;
      if (q[3] != 255)
        for (int c = 0; c < 3; c++) q[c] = unpremultiply(q[c], q[3]);
    }
  }

  static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  memcpy(out, signature, 8);
  uint8_t *p = out + 8;
  uint8_t *d = put_be32(put_be32(p + 8, width), height);
  d[0] = 8, d[1] = 6, d[2] = 0, d[3] = 0, d[4] = 0; // 8 bits, RGBA, deflate, adaptive filters, no interlace
  p = chunk(p, "IHDR", 13);

  d = p + 8;
  *d++ = 0x78, *d++ = 0x01; // zlib, a 32 KB window, no dictionary
  size_t at = 0;
  do {
    uint32_t n = raw_size - at > 65535 ? 65535 : (uint32_t)(raw_size - at);
    *d++ = at + n == raw_size; // the last block
    d[0] = (uint8_t)n, d[1] = (uint8_t)(n >> 8), d[2] = (uint8_t)~n, d[3] = (uint8_t)(~n >> 8);
    memcpy(d + 4, raw + at, n);
    d += 4 + n;
    at += n;
  } while (at < raw_size);
  uint32_t a = 1, b = 0;
  adler32_update(&a, &b, raw, raw_size);
  free(raw);
  d = put_be32(d, (b << 16) | a);
  p = chunk(p, "IDAT", (uint32_t)(d - (p + 8)));
  p = chunk(p, "IEND", 0);
  *size = (size_t)(p - out);
  return out;
}
