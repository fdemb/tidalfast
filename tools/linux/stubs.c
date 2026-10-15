// Stand-ins for the macOS frameworks the app calls, so src/app runs on Linux
// without a window. See tools/linux/build.sh.
//
// - Obj-C and Metal: objc_msgSend is a trampoline that looks the selector up
//   in a table of C functions. Buffers and textures live in malloc'd memory,
//   written once when made, so they count toward the process's memory the
//   way Metal's allocations count toward the footprint on Apple silicon.
//   Nothing is drawn: command buffers finish as soon as they're committed.
// - CoreFoundation: refcounted objects for the few types the app uses.
// - CoreText and CoreGraphics: fonts come from fontconfig and FreeType.
//   CTFontCreateForString picks a fallback the way CoreText does, by asking
//   fontconfig for a font with the character. Glyphs are drawn with FreeType.
// - Security: an in-memory Keychain, gone when the process exits.
// - CoreAudio: no devices. The app runs with TIDALFAST_AUDIO_NULL=1, which
//   plays through miniaudio's null device instead.

#define _GNU_SOURCE
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include FT_OUTLINE_H
#include <fontconfig/fontconfig.h>

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define EXPORT __attribute__((visibility("default")))

// ---------------------------------------------------------------------------
// CoreFoundation objects

typedef enum {
  CF_DATA = 1,
  CF_STRING,
  CF_DICTIONARY,
  CF_ARRAY,
  CF_URL,
  CF_FONT,
  CF_DESCRIPTOR,
  CF_ATTRIBUTED,
  CF_LINE,
  CF_CHARSET,
  CF_COLORSPACE,
  CF_CONTEXT,
  CF_COLLECTION,
  CF_BOOLEAN,
} CF_Kind;

typedef struct CF {
  CF_Kind kind;
  atomic_int refs; // 0 for static objects, which are never freed
} CF;

typedef struct {
  CF base;
  uint8_t *bytes;
  long length;
  bool owned;
} CF_Data;

typedef struct {
  CF base;
  char *utf8;
  long length; // bytes
  uint32_t *codepoints;
  long count;
} CF_String;

typedef struct {
  CF base;
  long count;
  const void **keys;
  const void **values;
} CF_Dictionary;

typedef struct {
  CF base;
  long count;
  const void **values;
} CF_Array;

typedef struct {
  CF base;
  char *path;
} CF_URL_Object;

typedef struct Face_Entry Face_Entry;

typedef struct {
  CF base;
  Face_Entry *face;
  double size;
} CF_Font;

typedef struct {
  CF base;
  // One of: font data, a file and face index, or a character set to match.
  CF_Data *data;
  char *path;
  int index;
  const CF *charset;
} CF_Descriptor;

typedef struct {
  CF base;
  uint32_t *codepoints;
  long count;
} CF_Charset;

typedef struct {
  CF base;
  uint8_t *pixels;
  long width, height, stride;
  int bytes_per_pixel;
  bool owned;
} CF_Context;

typedef struct {
  CF base;
  const CF *descriptors; // a CF_Array
} CF_Collection;

static void *cf_new(CF_Kind kind, size_t size) {
  CF *cf = calloc(1, size);
  cf->kind = kind;
  atomic_store(&cf->refs, 1);
  return cf;
}

EXPORT const void *CFRetain(const void *ref) {
  CF *cf = (CF *)ref;
  if (cf && atomic_load(&cf->refs) > 0) atomic_fetch_add(&cf->refs, 1);
  return ref;
}

static void face_release(Face_Entry *face);

EXPORT void CFRelease(const void *ref) {
  CF *cf = (CF *)ref;
  if (!cf || atomic_load(&cf->refs) == 0) return;
  if (atomic_fetch_sub(&cf->refs, 1) != 1) return;
  switch (cf->kind) {
  case CF_DATA: {
    CF_Data *d = (CF_Data *)cf;
    if (d->owned) free(d->bytes);
  } break;
  case CF_STRING: {
    CF_String *s = (CF_String *)cf;
    free(s->utf8);
    free(s->codepoints);
  } break;
  case CF_DICTIONARY: {
    CF_Dictionary *d = (CF_Dictionary *)cf;
    for (long i = 0; i < d->count; i++) {
      CFRelease(d->keys[i]);
      CFRelease(d->values[i]);
    }
    free(d->keys);
    free(d->values);
  } break;
  case CF_ARRAY: {
    CF_Array *a = (CF_Array *)cf;
    for (long i = 0; i < a->count; i++) CFRelease(a->values[i]);
    free(a->values);
  } break;
  case CF_URL:
    free(((CF_URL_Object *)cf)->path);
    break;
  case CF_FONT:
    face_release(((CF_Font *)cf)->face);
    break;
  case CF_DESCRIPTOR: {
    CF_Descriptor *d = (CF_Descriptor *)cf;
    CFRelease(d->data);
    CFRelease(d->charset);
    free(d->path);
  } break;
  case CF_CHARSET:
    free(((CF_Charset *)cf)->codepoints);
    break;
  case CF_CONTEXT: {
    CF_Context *c = (CF_Context *)cf;
    if (c->owned) free(c->pixels);
  } break;
  case CF_COLLECTION:
    CFRelease(((CF_Collection *)cf)->descriptors);
    break;
  default:
    break;
  }
  free(cf);
}

static bool cf_string_equal(const CF_String *a, const CF_String *b) {
  return a->length == b->length && memcmp(a->utf8, b->utf8, a->length) == 0;
}

EXPORT bool CFEqual(const void *a, const void *b) {
  if (a == b) return true;
  if (!a || !b) return false;
  const CF *x = a, *y = b;
  if (x->kind != y->kind) return false;
  if (x->kind == CF_STRING) return cf_string_equal(a, b);
  if (x->kind == CF_FONT) {
    const CF_Font *f = a, *g = b;
    return f->face == g->face && f->size == g->size;
  }
  return false;
}

// Static objects: constants the frameworks export.
#define STATIC_STRING(name, text) \
  static CF_String name##_object = {{CF_STRING, 0}, text, sizeof(text) - 1, NULL, 0}; \
  EXPORT const void *name = &name##_object;

STATIC_STRING(kCTFontURLAttribute, "NSFontURLAttribute")
STATIC_STRING(kCTFontAttributeName, "NSFont")
STATIC_STRING(kCTFontCharacterSetAttribute, "NSCTFontCharacterSetAttribute")
STATIC_STRING(kCGColorSpaceSRGB, "kCGColorSpaceSRGB")
STATIC_STRING(kSecClass, "class")
STATIC_STRING(kSecClassGenericPassword, "genp")
STATIC_STRING(kSecAttrService, "svce")
STATIC_STRING(kSecAttrAccount, "acct")
STATIC_STRING(kSecAttrLabel, "labl")
STATIC_STRING(kSecValueData, "v_Data")
STATIC_STRING(kSecReturnData, "r_Data")
STATIC_STRING(kSecMatchLimit, "m_Limit")
STATIC_STRING(kSecMatchLimitOne, "m_LimitOne")

static CF kCFBooleanTrue_object = {CF_BOOLEAN, 0};
EXPORT const void *kCFBooleanTrue = &kCFBooleanTrue_object;
EXPORT const void *kCFAllocatorNull = NULL;
EXPORT void *kCFTypeDictionaryKeyCallBacks[6];
EXPORT void *kCFTypeDictionaryValueCallBacks[5];
EXPORT void *kCFTypeArrayCallBacks[5];

EXPORT const void *CFDataCreate(void *allocator, const uint8_t *bytes, long length) {
  CF_Data *d = cf_new(CF_DATA, sizeof(CF_Data));
  d->bytes = malloc(length > 0 ? length : 1);
  if (length > 0) memcpy(d->bytes, bytes, length);
  d->length = length;
  d->owned = true;
  return d;
}

EXPORT const void *CFDataCreateWithBytesNoCopy(void *allocator, const uint8_t *bytes, long length, const void *deallocator) {
  CF_Data *d = cf_new(CF_DATA, sizeof(CF_Data));
  d->bytes = (uint8_t *)bytes;
  d->length = length;
  return d;
}

EXPORT const uint8_t *CFDataGetBytePtr(const void *data) { return data ? ((CF_Data *)data)->bytes : NULL; }
EXPORT long CFDataGetLength(const void *data) { return data ? ((CF_Data *)data)->length : 0; }

#define ENCODING_UTF8 0x08000100u
#define ENCODING_UTF32LE 0x1c000100u

static long utf8_encode(uint32_t c, char *out) {
  if (c < 0x80) {
    out[0] = (char)c;
    return 1;
  }
  if (c < 0x800) {
    out[0] = (char)(0xc0 | c >> 6);
    out[1] = (char)(0x80 | (c & 0x3f));
    return 2;
  }
  if (c < 0x10000) {
    out[0] = (char)(0xe0 | c >> 12);
    out[1] = (char)(0x80 | (c >> 6 & 0x3f));
    out[2] = (char)(0x80 | (c & 0x3f));
    return 3;
  }
  out[0] = (char)(0xf0 | c >> 18);
  out[1] = (char)(0x80 | (c >> 12 & 0x3f));
  out[2] = (char)(0x80 | (c >> 6 & 0x3f));
  out[3] = (char)(0x80 | (c & 0x3f));
  return 4;
}

static long utf8_decode(const uint8_t *s, long n, uint32_t *out) {
  long count = 0;
  for (long i = 0; i < n;) {
    uint32_t c = s[i];
    int extra = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : 0;
    c &= extra == 3 ? 0x07 : extra == 2 ? 0x0f : extra == 1 ? 0x1f : 0x7f;
    i++;
    for (int k = 0; k < extra && i < n; k++, i++) c = c << 6 | (s[i] & 0x3f);
    out[count++] = c;
  }
  return count;
}

EXPORT const void *CFStringCreateWithBytes(void *allocator, const uint8_t *bytes, long n, uint32_t encoding, bool external) {
  CF_String *s = cf_new(CF_STRING, sizeof(CF_String));
  if (encoding == ENCODING_UTF32LE) {
    s->count = n / 4;
    s->codepoints = malloc((s->count + 1) * 4);
    memcpy(s->codepoints, bytes, s->count * 4);
    s->utf8 = malloc(s->count * 4 + 1);
    for (long i = 0; i < s->count; i++) s->length += utf8_encode(s->codepoints[i], s->utf8 + s->length);
  } else {
    s->utf8 = malloc(n + 1);
    memcpy(s->utf8, bytes, n);
    s->length = n;
    s->codepoints = malloc((n + 1) * 4);
    s->count = utf8_decode(bytes, n, s->codepoints);
  }
  s->utf8[s->length] = 0;
  return s;
}

static const void *cf_string_from(const char *text) {
  return CFStringCreateWithBytes(NULL, (const uint8_t *)text, (long)strlen(text), ENCODING_UTF8, false);
}

// UTF-16 units, as CoreFoundation counts.
EXPORT long CFStringGetLength(const void *str) {
  const CF_String *s = str;
  long n = 0;
  for (long i = 0; i < s->count; i++) n += s->codepoints[i] >= 0x10000 ? 2 : 1;
  return n;
}

EXPORT int8_t CFStringGetCString(const void *str, char *buffer, long size, long encoding) {
  const CF_String *s = str;
  if (!s || s->length + 1 > size) return 0;
  memcpy(buffer, s->utf8, s->length + 1);
  return 1;
}

EXPORT const void *CFDictionaryCreate(void *allocator, const void **keys, const void **values, long count, const void *kcb, const void *vcb) {
  CF_Dictionary *d = cf_new(CF_DICTIONARY, sizeof(CF_Dictionary));
  d->count = count;
  d->keys = calloc(count + 1, sizeof(void *));
  d->values = calloc(count + 1, sizeof(void *));
  for (long i = 0; i < count; i++) {
    d->keys[i] = CFRetain(keys[i]);
    d->values[i] = CFRetain(values[i]);
  }
  return d;
}

static bool cf_key_equal(const void *a, const void *b) {
  if (a == b) return true;
  const CF *x = a, *y = b;
  return x && y && x->kind == CF_STRING && y->kind == CF_STRING && cf_string_equal(a, b);
}

EXPORT const void *CFDictionaryGetValue(const void *dict, const void *key) {
  const CF_Dictionary *d = dict;
  if (!d) return NULL;
  for (long i = 0; i < d->count; i++)
    if (cf_key_equal(d->keys[i], key)) return d->values[i];
  return NULL;
}

EXPORT const void *CFArrayCreate(void *allocator, const void **values, long count, const void *callbacks) {
  CF_Array *a = cf_new(CF_ARRAY, sizeof(CF_Array));
  a->count = count;
  a->values = calloc(count + 1, sizeof(void *));
  for (long i = 0; i < count; i++) a->values[i] = CFRetain(values[i]);
  return a;
}

EXPORT long CFArrayGetCount(const void *array) { return array ? ((CF_Array *)array)->count : 0; }
EXPORT const void *CFArrayGetValueAtIndex(const void *array, long i) { return ((CF_Array *)array)->values[i]; }

EXPORT const void *CFAttributedStringCreate(void *allocator, const void *str, const void *attributes) {
  return cf_new(CF_ATTRIBUTED, sizeof(CF));
}

EXPORT const void *CFCharacterSetCreateWithCharactersInString(void *allocator, const void *str) {
  const CF_String *s = str;
  CF_Charset *c = cf_new(CF_CHARSET, sizeof(CF_Charset));
  c->count = s->count;
  c->codepoints = malloc((s->count + 1) * 4);
  memcpy(c->codepoints, s->codepoints, s->count * 4);
  return c;
}

static const void *url_from_path(const char *path) {
  CF_URL_Object *u = cf_new(CF_URL, sizeof(CF_URL_Object));
  u->path = strdup(path);
  return u;
}

EXPORT const void *CFURLCreateWithBytes(void *allocator, const uint8_t *bytes, long length, uint32_t encoding, const void *base) {
  CF_URL_Object *u = cf_new(CF_URL, sizeof(CF_URL_Object));
  u->path = strndup((const char *)bytes, length);
  return u;
}

EXPORT bool CFURLGetFileSystemRepresentation(const void *url, bool resolve, uint8_t *buffer, long size) {
  const CF_URL_Object *u = url;
  if (!u || (long)strlen(u->path) + 1 > size) return false;
  memcpy(buffer, u->path, strlen(u->path) + 1);
  return true;
}

// ---------------------------------------------------------------------------
// CoreGraphics

static CF g_srgb = {CF_COLORSPACE, 0};

EXPORT const void *CGColorSpaceCreateWithName(const void *name) { return &g_srgb; }
EXPORT void CGColorSpaceRelease(const void *space) {}

EXPORT const void *CGBitmapContextCreate(void *data, size_t width, size_t height, size_t bits, size_t stride, const void *space, uint32_t info) {
  CF_Context *c = cf_new(CF_CONTEXT, sizeof(CF_Context));
  c->width = (long)width;
  c->height = (long)height;
  c->stride = (long)stride;
  c->bytes_per_pixel = stride >= width * 4 ? 4 : 1;
  c->pixels = data;
  if (!data) {
    c->pixels = calloc(1, stride * height);
    c->owned = true;
  }
  return c;
}

EXPORT uint8_t *CGBitmapContextGetData(const void *ctx) { return ((CF_Context *)ctx)->pixels; }
EXPORT void CGContextRelease(const void *ctx) { CFRelease(ctx); }

typedef struct {
  double x, y, w, h;
} Rect64;

EXPORT void CGContextClearRect(const void *ctx, Rect64 rect) {
  const CF_Context *c = ctx;
  long x0 = (long)fmax(0, floor(rect.x)), x1 = (long)fmin(c->width, ceil(rect.x + rect.w));
  long y0 = (long)fmax(0, floor(rect.y)), y1 = (long)fmin(c->height, ceil(rect.y + rect.h));
  for (long y = y0; y < y1; y++) {
    long row = c->height - 1 - y;
    memset(c->pixels + row * c->stride + x0 * c->bytes_per_pixel, 0, (x1 - x0) * c->bytes_per_pixel);
  }
}

EXPORT void CGContextSetGrayFillColor(const void *ctx, double gray, double alpha) {}
EXPORT void CGContextSetAllowsAntialiasing(const void *ctx, bool v) {}
EXPORT void CGContextSetShouldAntialias(const void *ctx, bool v) {}
EXPORT void CGContextSetAllowsFontSmoothing(const void *ctx, bool v) {}
EXPORT void CGContextSetShouldSmoothFonts(const void *ctx, bool v) {}
EXPORT void CGContextSetAllowsFontSubpixelPositioning(const void *ctx, bool v) {}
EXPORT void CGContextSetShouldSubpixelPositionFonts(const void *ctx, bool v) {}
EXPORT void CGContextSetAllowsFontSubpixelQuantization(const void *ctx, bool v) {}
EXPORT void CGContextSetShouldSubpixelQuantizeFonts(const void *ctx, bool v) {}
EXPORT bool CGEventSourceButtonState(int32_t state, uint32_t button) { return false; }

// ---------------------------------------------------------------------------
// CoreText, on fontconfig and FreeType. One FT_Face per font file or data,
// shared by every CTFont made from it at any size; FreeType calls are
// serialized, since the font loader thread and the UI thread both use them.

struct Face_Entry {
  Face_Entry *next;
  int refs;
  FT_Face face;
  const void *data; // CF_Data kept alive for a face made from memory
  char *path;
  int index;
};

static pthread_mutex_t g_ft_mutex = PTHREAD_MUTEX_INITIALIZER;
static FT_Library g_ft;
static Face_Entry *g_faces;

static Face_Entry *face_get(const CF_Data *data, const char *path, int index) {
  pthread_mutex_lock(&g_ft_mutex);
  if (!g_ft) FT_Init_FreeType(&g_ft);
  Face_Entry *e = g_faces;
  for (; e; e = e->next) {
    if (data ? e->data == data : (e->path && strcmp(e->path, path) == 0 && e->index == index)) break;
  }
  if (e) {
    e->refs++;
  } else {
    FT_Face face = NULL;
    FT_Error err = data ? FT_New_Memory_Face(g_ft, data->bytes, data->length, index, &face) : FT_New_Face(g_ft, path, index, &face);
    if (!err) {
      e = calloc(1, sizeof(Face_Entry));
      e->refs = 1;
      e->face = face;
      e->data = data ? CFRetain(data) : NULL;
      e->path = path ? strdup(path) : NULL;
      e->index = index;
      e->next = g_faces;
      g_faces = e;
      if (getenv("TIDALFAST_STUBS_LOG")) fprintf(stderr, "stubs: face %s %d (%s %s)\n", path ? path : "(data)", index, face->family_name, face->style_name);
    }
  }
  pthread_mutex_unlock(&g_ft_mutex);
  return e;
}

static void face_release(Face_Entry *face) {
  if (!face) return;
  pthread_mutex_lock(&g_ft_mutex);
  if (--face->refs == 0) {
    for (Face_Entry **p = &g_faces; *p; p = &(*p)->next) {
      if (*p == face) {
        *p = face->next;
        break;
      }
    }
    FT_Done_Face(face->face);
    free(face->path);
  } else {
    face = NULL;
  }
  pthread_mutex_unlock(&g_ft_mutex);
  if (face) {
    CFRelease(face->data);
    free(face);
  }
}

static const void *font_new(Face_Entry *face, double size) {
  if (!face) return NULL;
  CF_Font *f = cf_new(CF_FONT, sizeof(CF_Font));
  f->face = face;
  f->size = size;
  return f;
}

static const void *descriptor_for_file(const char *path, int index) {
  CF_Descriptor *d = cf_new(CF_DESCRIPTOR, sizeof(CF_Descriptor));
  d->path = strdup(path);
  d->index = index;
  return d;
}

EXPORT const void *CTFontManagerCreateFontDescriptorFromData(const void *data) {
  CF_Descriptor *d = cf_new(CF_DESCRIPTOR, sizeof(CF_Descriptor));
  d->data = (CF_Data *)CFRetain(data);
  return d;
}

EXPORT const void *CTFontDescriptorCreateWithAttributes(const void *attributes) {
  CF_Descriptor *d = cf_new(CF_DESCRIPTOR, sizeof(CF_Descriptor));
  d->charset = CFRetain(CFDictionaryGetValue(attributes, kCTFontCharacterSetAttribute));
  return d;
}

EXPORT const void *CTFontCreateWithFontDescriptor(const void *descriptor, double size, const void *transform) {
  const CF_Descriptor *d = descriptor;
  if (!d || (!d->data && !d->path)) return NULL;
  return font_new(face_get(d->data, d->path, d->index), size);
}

EXPORT const void *CTFontCreateCopyWithAttributes(const void *font, double size, const void *transform, const void *attributes) {
  const CF_Font *f = font;
  if (!f) return NULL;
  pthread_mutex_lock(&g_ft_mutex);
  f->face->refs++;
  pthread_mutex_unlock(&g_ft_mutex);
  return font_new(f->face, size > 0 ? size : f->size);
}

static bool face_is_bold(const Face_Entry *e) { return (e->face->style_flags & FT_STYLE_FLAG_BOLD) != 0; }

// Fonts with the codepoints in cps: fontconfig's list, or with sort its
// fonts best first for family and weight (fontconfig's), which may lack them.
static FcFontSet *fc_fonts_with(const uint32_t *cps, long n, const char *family, int weight, bool sort) {
  static pthread_mutex_t fc_mutex = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&fc_mutex);
  FcInit();
  FcCharSet *cs = FcCharSetCreate();
  for (long i = 0; i < n; i++) FcCharSetAddChar(cs, cps[i]);
  FcPattern *pat = FcPatternCreate();
  FcPatternAddCharSet(pat, FC_CHARSET, cs);
  if (family) FcPatternAddString(pat, FC_FAMILY, (const FcChar8 *)family);
  if (weight > 0) FcPatternAddInteger(pat, FC_WEIGHT, weight);
  FcPatternAddBool(pat, FC_SCALABLE, FcTrue);
  FcFontSet *set = NULL;
  if (sort) {
    FcConfigSubstitute(NULL, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);
    FcResult result;
    set = FcFontSort(NULL, pat, FcTrue, NULL, &result);
  } else {
    FcObjectSet *os = FcObjectSetBuild(FC_FILE, FC_INDEX, FC_WEIGHT, FC_SLANT, NULL);
    set = FcFontList(NULL, pat, os);
    FcObjectSetDestroy(os);
  }
  FcPatternDestroy(pat);
  FcCharSetDestroy(cs);
  pthread_mutex_unlock(&fc_mutex);
  return set;
}

static bool fc_has_all(FcPattern *p, const uint32_t *cps, long n) {
  FcCharSet *cs;
  if (FcPatternGetCharSet(p, FC_CHARSET, 0, &cs) != FcResultMatch) return true;
  for (long i = 0; i < n; i++)
    if (!FcCharSetHasChar(cs, cps[i])) return false;
  return true;
}

// The family to ask fontconfig for first, by script, so that with the Noto
// fonts installed the fallbacks look like macOS's: a family per script, a
// face per weight.
static const char *fallback_family(uint32_t c) {
  if (c >= 0x3040 && c <= 0x30ff) return "Noto Sans CJK JP";
  if ((c >= 0xac00 && c <= 0xd7af) || (c >= 0x1100 && c <= 0x11ff) || (c >= 0x3130 && c <= 0x318f)) return "Noto Sans CJK KR";
  if ((c >= 0x2e80 && c <= 0x9fff) || (c >= 0xf900 && c <= 0xfaff) || c >= 0x20000) return "Noto Sans CJK SC";
  if (c >= 0x0590 && c <= 0x05ff) return "Noto Sans Hebrew";
  if ((c >= 0x0600 && c <= 0x06ff) || (c >= 0x0750 && c <= 0x077f) || (c >= 0xfb50 && c <= 0xfeff)) return "Noto Sans Arabic";
  if ((c >= 0x1f000 && c <= 0x1faff) || (c >= 0x2600 && c <= 0x27bf)) return "Noto Color Emoji";
  return "Noto Sans";
}

// fontconfig's weight for a face, from its OS/2 weight class.
static int face_weight(const Face_Entry *e) {
  int weight = face_is_bold(e) ? 700 : 400;
  pthread_mutex_lock(&g_ft_mutex);
  TT_OS2 *os2 = FT_Get_Sfnt_Table(e->face, FT_SFNT_OS2);
  if (os2 && os2->usWeightClass) weight = os2->usWeightClass;
  pthread_mutex_unlock(&g_ft_mutex);
  return (int)FcWeightFromOpenTypeDouble(weight);
}

EXPORT const void *CTFontCreateForString(const void *current, const void *str, long location, long length) {
  const CF_Font *cur = current;
  const CF_String *s = str;
  if (s->count == 0) return NULL;
  FcFontSet *set = fc_fonts_with(s->codepoints, s->count, fallback_family(s->codepoints[0]), cur ? face_weight(cur->face) : 0, true);
  const void *font = NULL;
  for (int i = 0; set && i < set->nfont && !font; i++) {
    FcPattern *p = set->fonts[i];
    if (!fc_has_all(p, s->codepoints, s->count)) continue;
    FcChar8 *file;
    int index = 0;
    if (FcPatternGetString(p, FC_FILE, 0, &file) != FcResultMatch) continue;
    FcPatternGetInteger(p, FC_INDEX, 0, &index);
    font = font_new(face_get(NULL, (const char *)file, index), cur ? cur->size : 12);
  }
  if (set) FcFontSetDestroy(set);
  return font;
}

EXPORT const void *CTFontCollectionCreateWithFontDescriptors(const void *descriptors, const void *options) {
  CF_Collection *c = cf_new(CF_COLLECTION, sizeof(CF_Collection));
  c->descriptors = CFRetain(descriptors);
  return c;
}

EXPORT const void *CTFontCollectionCreateMatchingFontDescriptors(const void *collection) {
  const CF_Collection *c = collection;
  const CF_Array *descs = (const CF_Array *)c->descriptors;
  if (!descs || descs->count == 0) return NULL;
  const CF_Descriptor *d = descs->values[0];
  const CF_Charset *cs = (const CF_Charset *)d->charset;
  if (!cs) return NULL;
  FcFontSet *set = fc_fonts_with(cs->codepoints, cs->count, NULL, 0, false);
  if (!set || set->nfont == 0) {
    if (set) FcFontSetDestroy(set);
    return NULL;
  }
  const void **values = calloc(set->nfont, sizeof(void *));
  long n = 0;
  for (int i = 0; i < set->nfont; i++) {
    FcChar8 *file;
    int index = 0;
    if (FcPatternGetString(set->fonts[i], FC_FILE, 0, &file) != FcResultMatch) continue;
    FcPatternGetInteger(set->fonts[i], FC_INDEX, 0, &index);
    values[n++] = descriptor_for_file((const char *)file, index);
  }
  FcFontSetDestroy(set);
  const void *array = CFArrayCreate(NULL, values, n, NULL);
  for (long i = 0; i < n; i++) CFRelease(values[i]);
  free(values);
  return array;
}

EXPORT const void *CTFontCopyAttribute(const void *font, const void *attribute) {
  const CF_Font *f = font;
  if (!f || !cf_key_equal(attribute, kCTFontURLAttribute) || !f->face->path) return NULL;
  return url_from_path(f->face->path);
}

EXPORT const void *CTFontCopyPostScriptName(const void *font) {
  const CF_Font *f = font;
  pthread_mutex_lock(&g_ft_mutex);
  const char *name = FT_Get_Postscript_Name(f->face->face);
  char buf[512];
  if (name) {
    snprintf(buf, sizeof(buf), "%s", name);
  } else {
    snprintf(buf, sizeof(buf), "%s-%s", f->face->face->family_name ? f->face->face->family_name : "",
             f->face->face->style_name ? f->face->face->style_name : "");
  }
  pthread_mutex_unlock(&g_ft_mutex);
  return cf_string_from(buf);
}

EXPORT const void *CTFontCopyTable(const void *font, uint32_t tag, uint32_t options) {
  const CF_Font *f = font;
  pthread_mutex_lock(&g_ft_mutex);
  FT_ULong length = 0;
  const void *data = NULL;
  if (FT_Load_Sfnt_Table(f->face->face, tag, 0, NULL, &length) == 0 && length > 0) {
    uint8_t *bytes = malloc(length);
    FT_Load_Sfnt_Table(f->face->face, tag, 0, bytes, &length);
    data = CFDataCreate(NULL, bytes, (long)length);
    free(bytes);
  }
  pthread_mutex_unlock(&g_ft_mutex);
  return data;
}

#define CT_ITALIC 1u
#define CT_BOLD 2u
#define CT_COLOR (1u << 13)

EXPORT uint32_t CTFontGetSymbolicTraits(const void *font) {
  const CF_Font *f = font;
  FT_Face face = f->face->face;
  uint32_t traits = 0;
  if (face->style_flags & FT_STYLE_FLAG_ITALIC) traits |= CT_ITALIC;
  if (face->style_flags & FT_STYLE_FLAG_BOLD) traits |= CT_BOLD;
  if (FT_HAS_COLOR(face)) traits |= CT_COLOR;
  return traits;
}

EXPORT uint32_t CTFontGetUnitsPerEm(const void *font) {
  FT_Face face = ((const CF_Font *)font)->face->face;
  return face->units_per_EM ? face->units_per_EM : 1000;
}

EXPORT double CTFontGetAscent(const void *font) {
  const CF_Font *f = font;
  FT_Face face = f->face->face;
  return face->units_per_EM ? f->size * face->ascender / face->units_per_EM : f->size * 0.8;
}

EXPORT double CTFontGetDescent(const void *font) {
  const CF_Font *f = font;
  FT_Face face = f->face->face;
  return face->units_per_EM ? -f->size * face->descender / face->units_per_EM : f->size * 0.2;
}

// Sizes a face for f, under the mutex. Bitmap-only faces (colour emoji)
// get their nearest strike, and *scale says how far to scale it.
static bool face_size(const CF_Font *f, double *scale) {
  FT_Face face = f->face->face;
  *scale = 1;
  if (FT_IS_SCALABLE(face)) return FT_Set_Char_Size(face, 0, (FT_F26Dot6)(f->size * 64), 72, 72) == 0;
  if (face->num_fixed_sizes == 0) return false;
  int best = 0;
  for (int i = 1; i < face->num_fixed_sizes; i++)
    if (abs(face->available_sizes[i].y_ppem / 64 - (int)f->size) < abs(face->available_sizes[best].y_ppem / 64 - (int)f->size)) best = i;
  if (FT_Select_Size(face, best)) return false;
  *scale = f->size / (face->available_sizes[best].y_ppem / 64.0);
  return true;
}

EXPORT Rect64 CTFontGetBoundingRectsForGlyphs(const void *font, uint32_t orientation, const uint16_t *glyphs, Rect64 *rects, long count) {
  const CF_Font *f = font;
  pthread_mutex_lock(&g_ft_mutex);
  double scale;
  bool sized = face_size(f, &scale);
  for (long i = 0; i < count; i++) {
    rects[i] = (Rect64){0};
    if (!sized) continue;
    FT_Face face = f->face->face;
    if (FT_IS_SCALABLE(face)) {
      if (FT_Load_Glyph(face, glyphs[i], FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP)) continue;
      if (face->glyph->format != FT_GLYPH_FORMAT_OUTLINE) continue;
      FT_BBox box;
      FT_Outline_Get_CBox(&face->glyph->outline, &box);
      rects[i] = (Rect64){box.xMin / 64.0, box.yMin / 64.0, (box.xMax - box.xMin) / 64.0, (box.yMax - box.yMin) / 64.0};
    } else {
      if (FT_Load_Glyph(face, glyphs[i], FT_LOAD_COLOR)) continue;
      FT_GlyphSlot g = face->glyph;
      rects[i] = (Rect64){g->bitmap_left * scale, (g->bitmap_top - (double)g->bitmap.rows) * scale, g->bitmap.width * scale, g->bitmap.rows * scale};
    }
  }
  pthread_mutex_unlock(&g_ft_mutex);
  return (Rect64){0};
}

// Draws coverage with FreeType, or a colour glyph scaled with the nearest
// texel. positions are in the context's bottom-left pixel space.
EXPORT void CTFontDrawGlyphs(const void *font, const uint16_t *glyphs, const double *positions, size_t count, const void *ctx) {
  const CF_Font *f = font;
  const CF_Context *c = ctx;
  pthread_mutex_lock(&g_ft_mutex);
  double scale;
  if (!face_size(f, &scale)) {
    pthread_mutex_unlock(&g_ft_mutex);
    return;
  }
  FT_Face face = f->face->face;
  for (size_t i = 0; i < count; i++) {
    double px = positions[2 * i], py = positions[2 * i + 1];
    FT_Vector delta = {(FT_Pos)((px - floor(px)) * 64), (FT_Pos)((py - floor(py)) * 64)};
    FT_Set_Transform(face, NULL, &delta);
    int flags = FT_IS_SCALABLE(face) ? FT_LOAD_RENDER | FT_LOAD_NO_HINTING : FT_LOAD_RENDER | FT_LOAD_COLOR;
    FT_Error err = FT_Load_Glyph(face, glyphs[i], flags);
    FT_Set_Transform(face, NULL, NULL);
    if (err) continue;
    FT_Bitmap *b = &face->glyph->bitmap;
    long left = (long)floor(px) + (long)(face->glyph->bitmap_left * scale);
    long top = (long)floor(py) + (long)(face->glyph->bitmap_top * scale);
    long w = (long)(b->width * scale), h = (long)(b->rows * scale);
    for (long y = 0; y < h; y++) {
      long cy = top - 1 - y; // y up in the context
      if (cy < 0 || cy >= c->height) continue;
      uint8_t *row = c->pixels + (c->height - 1 - cy) * c->stride;
      long sy = (long)(y / scale);
      for (long x = 0; x < w; x++) {
        long cx = left + x;
        if (cx < 0 || cx >= c->width) continue;
        long sx = (long)(x / scale);
        if (b->pixel_mode == FT_PIXEL_MODE_BGRA && c->bytes_per_pixel == 4) {
          memcpy(row + cx * 4, b->buffer + sy * b->pitch + sx * 4, 4);
        } else if (b->pixel_mode == FT_PIXEL_MODE_GRAY) {
          uint8_t v = b->buffer[sy * b->pitch + sx];
          if (c->bytes_per_pixel == 1) {
            if (v > row[cx]) row[cx] = v;
          } else {
            memset(row + cx * 4, v, 4);
          }
        }
      }
    }
  }
  pthread_mutex_unlock(&g_ft_mutex);
}

// The Linux fonts all have GSUB, so the app never asks CoreText to shape a
// line; these return a line with no runs.
EXPORT const void *CTLineCreateWithAttributedString(const void *s) { return cf_new(CF_LINE, sizeof(CF)); }
EXPORT const void *CTLineGetGlyphRuns(const void *line) {
  static CF_Array empty = {{CF_ARRAY, 0}, 0, NULL};
  return &empty;
}
EXPORT long CTRunGetGlyphCount(const void *run) { return 0; }
EXPORT void CTRunGetGlyphs(const void *run, long location, long length, uint16_t *out) {}
EXPORT void CTRunGetPositions(const void *run, long location, long length, void *out) {}
EXPORT void CTRunGetAdvances(const void *run, long location, long length, void *out) {}
EXPORT void CTRunGetStringIndices(const void *run, long location, long length, long *out) {}
EXPORT const void *CTRunGetAttributes(const void *run) { return NULL; }

// ---------------------------------------------------------------------------
// Security: an in-memory Keychain of generic passwords by service and account.

typedef struct Keychain_Item {
  struct Keychain_Item *next;
  char *service, *account;
  const void *data;
} Keychain_Item;

static pthread_mutex_t g_keychain_mutex = PTHREAD_MUTEX_INITIALIZER;
static Keychain_Item *g_keychain;

#define ERR_SEC_SUCCESS 0
#define ERR_SEC_DUPLICATE_ITEM (-25299)
#define ERR_SEC_ITEM_NOT_FOUND (-25300)

static const char *dict_string(const void *dict, const void *key) {
  const CF_String *s = CFDictionaryGetValue(dict, key);
  return s && s->base.kind == CF_STRING ? s->utf8 : "";
}

static Keychain_Item **keychain_find(const void *query) {
  const char *service = dict_string(query, kSecAttrService), *account = dict_string(query, kSecAttrAccount);
  Keychain_Item **p = &g_keychain;
  for (; *p; p = &(*p)->next)
    if (strcmp((*p)->service, service) == 0 && (!*account || strcmp((*p)->account, account) == 0)) break;
  return p;
}

EXPORT int32_t SecItemAdd(const void *attributes, const void **result) {
  pthread_mutex_lock(&g_keychain_mutex);
  int32_t status = ERR_SEC_DUPLICATE_ITEM;
  if (!*keychain_find(attributes)) {
    Keychain_Item *item = calloc(1, sizeof(Keychain_Item));
    item->service = strdup(dict_string(attributes, kSecAttrService));
    item->account = strdup(dict_string(attributes, kSecAttrAccount));
    const CF_Data *d = CFDictionaryGetValue(attributes, kSecValueData);
    item->data = d ? CFDataCreate(NULL, d->bytes, d->length) : CFDataCreate(NULL, NULL, 0);
    item->next = g_keychain;
    g_keychain = item;
    status = ERR_SEC_SUCCESS;
  }
  pthread_mutex_unlock(&g_keychain_mutex);
  return status;
}

EXPORT int32_t SecItemCopyMatching(const void *query, const void **result) {
  pthread_mutex_lock(&g_keychain_mutex);
  Keychain_Item *item = *keychain_find(query);
  int32_t status = ERR_SEC_ITEM_NOT_FOUND;
  if (item) {
    const CF_Data *d = item->data;
    if (result) *result = CFDataCreate(NULL, d->bytes, d->length);
    status = ERR_SEC_SUCCESS;
  }
  pthread_mutex_unlock(&g_keychain_mutex);
  return status;
}

EXPORT int32_t SecItemUpdate(const void *query, const void *attributes) {
  pthread_mutex_lock(&g_keychain_mutex);
  Keychain_Item *item = *keychain_find(query);
  int32_t status = ERR_SEC_ITEM_NOT_FOUND;
  if (item) {
    const CF_Data *d = CFDictionaryGetValue(attributes, kSecValueData);
    if (d) {
      CFRelease(item->data);
      item->data = CFDataCreate(NULL, d->bytes, d->length);
    }
    status = ERR_SEC_SUCCESS;
  }
  pthread_mutex_unlock(&g_keychain_mutex);
  return status;
}

EXPORT int32_t SecItemDelete(const void *query) {
  pthread_mutex_lock(&g_keychain_mutex);
  Keychain_Item **p = keychain_find(query);
  int32_t status = ERR_SEC_ITEM_NOT_FOUND;
  if (*p) {
    Keychain_Item *item = *p;
    *p = item->next;
    CFRelease(item->data);
    free(item->service);
    free(item->account);
    free(item);
    status = ERR_SEC_SUCCESS;
  }
  pthread_mutex_unlock(&g_keychain_mutex);
  return status;
}

EXPORT int32_t LSOpenCFURLRef(const void *url, const void **launched) { return 0; }

// ---------------------------------------------------------------------------
// CoreAudio: no objects at all.

#define AUDIO_BAD_OBJECT 0x216f626a // '!obj'

EXPORT int32_t AudioObjectGetPropertyDataSize(uint32_t id, const void *addr, uint32_t qsize, const void *q, uint32_t *size) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioObjectGetPropertyData(uint32_t id, const void *addr, uint32_t qsize, const void *q, uint32_t *size, void *out) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioObjectSetPropertyData(uint32_t id, const void *addr, uint32_t qsize, const void *q, uint32_t size, const void *data) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioDeviceCreateIOProcID(uint32_t dev, void *proc, void *client, void **id) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioDeviceDestroyIOProcID(uint32_t dev, void *id) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioDeviceStart(uint32_t dev, void *id) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioDeviceStop(uint32_t dev, void *id) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioObjectAddPropertyListener(uint32_t id, const void *addr, void *listener, void *client) { return AUDIO_BAD_OBJECT; }
EXPORT int32_t AudioObjectRemovePropertyListener(uint32_t id, const void *addr, void *listener, void *client) { return AUDIO_BAD_OBJECT; }

EXPORT uint64_t mach_absolute_time(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

EXPORT int mach_timebase_info(uint32_t *info) {
  info[0] = 1;
  info[1] = 1;
  return 0;
}

// ---------------------------------------------------------------------------
// Obj-C and Metal.
//
// An object starts with its class's methods. A selector is a pointer to a
// Selector, which holds the handler for that name. objc_msgSend asks
// objc_lookup for the handler and jumps to it with every argument register
// as it was, so each handler has the C signature its caller cast
// objc_msgSend to.

typedef struct Object Object;
typedef void (*Dealloc)(Object *);

typedef enum {
  O_CLASS = 1,
  O_DEVICE,
  O_LAYER,
  O_DRAWABLE,
  O_TEXTURE,
  O_TEXTURE_DESCRIPTOR,
  O_BUFFER,
  O_QUEUE,
  O_COMMAND_BUFFER,
  O_ENCODER,
  O_PASS,
  O_ATTACHMENTS,
  O_ATTACHMENT,
  O_PIPELINE_DESCRIPTOR,
  O_PIPELINE,
  O_LIBRARY,
  O_FUNCTION,
  O_STRING,
  O_GENERIC,
} Object_Kind;

struct Object {
  Object_Kind kind;
  atomic_int refs; // 0 for objects that live forever
  const char *class_name;
  // Kind-specific fields.
  size_t width, height, pixel_format, bytes_per_pixel, mip_bytes;
  bool mipmapped;
  uint8_t *bytes; // texture or buffer memory
  size_t length;
  char *text;
  Object *owner; // a drawable's layer
  int drawable_index;
};

static atomic_size_t g_gpu_allocated;
static pthread_mutex_t g_pool_mutex = PTHREAD_MUTEX_INITIALIZER;

static Object *obj_new(Object_Kind kind) {
  Object *o = calloc(1, sizeof(Object));
  o->kind = kind;
  atomic_store(&o->refs, 1);
  return o;
}

// GPU memory: allocated and written once, so its pages are resident, the way
// Metal's allocations count toward the footprint whether drawn into or not.
static uint8_t *gpu_alloc(size_t n) {
  uint8_t *p = malloc(n ? n : 1);
  memset(p, 0, n);
  atomic_fetch_add(&g_gpu_allocated, n);
  return p;
}

static void gpu_free(uint8_t *p, size_t n) {
  free(p);
  atomic_fetch_sub(&g_gpu_allocated, n);
}

static void obj_free(Object *o) {
  if (o->kind == O_TEXTURE || o->kind == O_BUFFER) gpu_free(o->bytes, o->length);
  free(o->text);
  free(o);
}

// Autorelease pools, pushed by the shell around each frame.
#define POOL_MAX 65536
static Object *g_pool[POOL_MAX];
static int g_pool_count;
static int g_pool_marks[64];
static int g_pool_depth;

static void obj_release(Object *o) {
  if (!o || atomic_load(&o->refs) == 0) return;
  if (atomic_fetch_sub(&o->refs, 1) == 1) obj_free(o);
}

static Object *obj_autorelease(Object *o) {
  if (!o) return o;
  pthread_mutex_lock(&g_pool_mutex);
  if (g_pool_count < POOL_MAX) {
    g_pool[g_pool_count++] = o;
  }
  pthread_mutex_unlock(&g_pool_mutex);
  return o;
}

EXPORT void tf_pool_push(void) {
  pthread_mutex_lock(&g_pool_mutex);
  g_pool_marks[g_pool_depth++] = g_pool_count;
  pthread_mutex_unlock(&g_pool_mutex);
}

EXPORT void tf_pool_pop(void) {
  pthread_mutex_lock(&g_pool_mutex);
  int mark = g_pool_marks[--g_pool_depth];
  int n = g_pool_count - mark;
  Object **items = malloc(sizeof(Object *) * (n ? n : 1));
  memcpy(items, g_pool + mark, sizeof(Object *) * n);
  g_pool_count = mark;
  pthread_mutex_unlock(&g_pool_mutex);
  for (int i = 0; i < n; i++) obj_release(items[i]);
  free(items);
}

static size_t pixel_bytes(size_t format) {
  switch (format) {
  case 10: // R8Unorm
  case 1: // A8Unorm
    return 1;
  case 115: // RGBA16Float
    return 8;
  default: // RGBA8, BGRA8 and their sRGB forms
    return 4;
  }
}

// Messages. Each takes (self, _cmd) and the method's own arguments.
typedef Object *Id;
typedef void *SEL_T;

static Id m_nil(Id self, SEL_T cmd) { return NULL; }
static Id m_self(Id self, SEL_T cmd) { return self; }

static Id m_alloc(Id cls, SEL_T cmd) {
  Object_Kind kind = O_GENERIC;
  if (strcmp(cls->class_name, "NSString") == 0) kind = O_STRING;
  if (strcmp(cls->class_name, "MTLRenderPipelineDescriptor") == 0) kind = O_PIPELINE_DESCRIPTOR;
  Object *o = obj_new(kind);
  o->class_name = cls->class_name;
  return o;
}

static Id m_retain(Id self, SEL_T cmd) {
  if (self && atomic_load(&self->refs) > 0) atomic_fetch_add(&self->refs, 1);
  return self;
}

static void m_release(Id self, SEL_T cmd) { obj_release(self); }
static Id m_autorelease(Id self, SEL_T cmd) { return obj_autorelease(self); }

static Id m_string_init(Id self, SEL_T cmd, const void *bytes, size_t length, size_t encoding) {
  self->text = strndup(bytes, length);
  return self;
}

static const char *m_utf8(Id self, SEL_T cmd) { return self && self->text ? self->text : ""; }
static Id m_description(Id self, SEL_T cmd) { return NULL; }

static Id m_new_queue(Id device, SEL_T cmd) { return obj_new(O_QUEUE); }
static size_t m_allocated(Id device, SEL_T cmd) { return atomic_load(&g_gpu_allocated); }

static Id m_new_buffer(Id device, SEL_T cmd, size_t length, size_t options) {
  Object *o = obj_new(O_BUFFER);
  o->length = length;
  o->bytes = gpu_alloc(length);
  return o;
}

static void *m_contents(Id buffer, SEL_T cmd) { return buffer->bytes; }
static size_t m_length(Id buffer, SEL_T cmd) { return buffer->length; }

static Id m_texture_descriptor(Id cls, SEL_T cmd, size_t format, size_t width, size_t height, bool mipmapped) {
  Object *o = obj_new(O_TEXTURE_DESCRIPTOR);
  o->pixel_format = format;
  o->width = width;
  o->height = height;
  o->mipmapped = mipmapped;
  return obj_autorelease(o);
}

static Id texture_new(size_t format, size_t width, size_t height, bool mipmapped) {
  Object *o = obj_new(O_TEXTURE);
  o->pixel_format = format;
  o->width = width;
  o->height = height;
  o->bytes_per_pixel = pixel_bytes(format);
  size_t n = width * height * o->bytes_per_pixel, total = n;
  if (mipmapped) {
    for (size_t w = width, h = height; w > 1 || h > 1;) {
      w = w > 1 ? w / 2 : 1;
      h = h > 1 ? h / 2 : 1;
      total += w * h * o->bytes_per_pixel;
    }
  }
  o->length = total;
  o->bytes = gpu_alloc(total);
  return o;
}

static Id m_new_texture(Id device, SEL_T cmd, Id desc) {
  return texture_new(desc->pixel_format, desc->width, desc->height, desc->mipmapped);
}

static size_t m_width(Id self, SEL_T cmd) { return self->width; }
static size_t m_height(Id self, SEL_T cmd) { return self->height; }
static size_t m_pixel_format(Id self, SEL_T cmd) { return self->pixel_format; }

typedef struct {
  size_t x, y, z;
} Origin;
typedef struct {
  size_t width, height, depth;
} Size3;
typedef struct {
  Origin origin;
  Size3 size;
} Region;

static void m_replace_region(Id tex, SEL_T cmd, Region region, size_t level, const void *bytes, size_t stride) {
  if (level != 0 || !bytes) return;
  size_t bpp = tex->bytes_per_pixel;
  for (size_t row = 0; row < region.size.height; row++) {
    size_t y = region.origin.y + row;
    if (y >= tex->height || region.origin.x + region.size.width > tex->width) break;
    memcpy(tex->bytes + (y * tex->width + region.origin.x) * bpp, (const uint8_t *)bytes + row * stride, region.size.width * bpp);
  }
}

static void m_copy_texture(Id enc, SEL_T cmd, Id src, size_t src_slice, size_t src_level, Origin src_origin, Size3 size, Id dst,
                           size_t dst_slice, size_t dst_level, Origin dst_origin) {
  if (!src || !dst || src_level || dst_level || src->bytes_per_pixel != dst->bytes_per_pixel) return;
  size_t bpp = src->bytes_per_pixel;
  for (size_t row = 0; row < size.height; row++) {
    size_t sy = src_origin.y + row, dy = dst_origin.y + row;
    if (sy >= src->height || dy >= dst->height) break;
    size_t w = size.width;
    if (src_origin.x + w > src->width || dst_origin.x + w > dst->width) break;
    memcpy(dst->bytes + (dy * dst->width + dst_origin.x) * bpp, src->bytes + (sy * src->width + src_origin.x) * bpp, w * bpp);
  }
}

static void m_copy_to_buffer(Id enc, SEL_T cmd, Id src, size_t slice, size_t level, Origin origin, Size3 size, Id buf, size_t offset,
                             size_t stride, size_t image_bytes) {
  if (!src || !buf || src->bytes_per_pixel != 4) return;
  for (size_t row = 0; row < size.height && origin.y + row < src->height; row++) {
    if (offset + row * stride + size.width * 4 > buf->length) break;
    memcpy(buf->bytes + offset + row * stride, src->bytes + ((origin.y + row) * src->width + origin.x) * 4, size.width * 4);
  }
}

static Id m_library(Id device, SEL_T cmd, Id source, Id options, Id *error) {
  if (error) *error = NULL;
  return obj_new(O_LIBRARY);
}

static Id m_function(Id library, SEL_T cmd, Id name) { return obj_new(O_FUNCTION); }

static Id m_pipeline(Id device, SEL_T cmd, Id desc, Id *error) {
  if (error) *error = NULL;
  return obj_new(O_PIPELINE);
}

// Attachments and pass descriptors: setters do nothing, so one attachment
// object answers for every index.
static Object g_attachment = {O_ATTACHMENT, 0, "MTLAttachment"};
static Object g_attachments = {O_ATTACHMENTS, 0, "MTLAttachmentArray"};
static Id m_attachments(Id self, SEL_T cmd) { return &g_attachments; }
static Id m_attachment_at(Id self, SEL_T cmd, size_t i) { return &g_attachment; }
static Id m_pass(Id cls, SEL_T cmd) { return obj_autorelease(obj_new(O_PASS)); }

static Id m_command_buffer(Id queue, SEL_T cmd) { return obj_autorelease(obj_new(O_COMMAND_BUFFER)); }
static Id m_encoder(Id cmdbuf, SEL_T cmd) { return obj_autorelease(obj_new(O_ENCODER)); }
static Id m_encoder_with(Id cmdbuf, SEL_T cmd, Id pass) { return obj_autorelease(obj_new(O_ENCODER)); }
static size_t m_status(Id cmdbuf, SEL_T cmd) { return 4; } // MTLCommandBufferStatusCompleted

// The layer: up to max_drawables textures of the drawable size, made when
// first needed and let go of when the shell lowers the count, as
// CAMetalLayer does.
#define MAX_DRAWABLES 3
typedef struct {
  Object base;
  size_t width, height, format;
  int max;
  int next;
  Object *textures[MAX_DRAWABLES];
} Layer;

static Id m_next_drawable(Id self, SEL_T cmd) {
  Layer *layer = (Layer *)self;
  if (layer->width == 0 || layer->height == 0) return NULL;
  for (int i = layer->max; i < MAX_DRAWABLES; i++) {
    if (layer->textures[i]) {
      obj_release(layer->textures[i]);
      layer->textures[i] = NULL;
    }
  }
  int i = layer->next % layer->max;
  layer->next = i + 1;
  Object *t = layer->textures[i];
  if (t && (t->width != layer->width || t->height != layer->height)) {
    obj_release(t);
    t = NULL;
  }
  if (!t) t = layer->textures[i] = texture_new(layer->format, layer->width, layer->height, false);
  Object *d = obj_new(O_DRAWABLE);
  d->owner = t;
  return obj_autorelease(d);
}

static Id m_drawable_texture(Id drawable, SEL_T cmd) { return drawable->owner; }

typedef struct {
  const char *name;
  void *imp;
} Selector;

#define SEL_ENTRY(name, fn) {name, (void *)fn}
static Selector g_selectors[] = {
    SEL_ENTRY("alloc", m_alloc),
    SEL_ENTRY("init", m_self),
    SEL_ENTRY("retain", m_retain),
    SEL_ENTRY("release", m_release),
    SEL_ENTRY("autorelease", m_autorelease),
    SEL_ENTRY("initWithBytes:length:encoding:", m_string_init),
    SEL_ENTRY("UTF8String", m_utf8),
    SEL_ENTRY("localizedDescription", m_description),
    SEL_ENTRY("newCommandQueue", m_new_queue),
    SEL_ENTRY("currentAllocatedSize", m_allocated),
    SEL_ENTRY("newBufferWithLength:options:", m_new_buffer),
    SEL_ENTRY("contents", m_contents),
    SEL_ENTRY("length", m_length),
    SEL_ENTRY("texture2DDescriptorWithPixelFormat:width:height:mipmapped:", m_texture_descriptor),
    SEL_ENTRY("newTextureWithDescriptor:", m_new_texture),
    SEL_ENTRY("width", m_width),
    SEL_ENTRY("height", m_height),
    SEL_ENTRY("pixelFormat", m_pixel_format),
    SEL_ENTRY("replaceRegion:mipmapLevel:withBytes:bytesPerRow:", m_replace_region),
    SEL_ENTRY("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", m_copy_texture),
    SEL_ENTRY("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", m_copy_to_buffer),
    SEL_ENTRY("newLibraryWithSource:options:error:", m_library),
    SEL_ENTRY("newFunctionWithName:", m_function),
    SEL_ENTRY("newRenderPipelineStateWithDescriptor:error:", m_pipeline),
    SEL_ENTRY("colorAttachments", m_attachments),
    SEL_ENTRY("objectAtIndexedSubscript:", m_attachment_at),
    SEL_ENTRY("renderPassDescriptor", m_pass),
    SEL_ENTRY("commandBuffer", m_command_buffer),
    SEL_ENTRY("blitCommandEncoder", m_encoder),
    SEL_ENTRY("renderCommandEncoderWithDescriptor:", m_encoder_with),
    SEL_ENTRY("status", m_status),
    SEL_ENTRY("nextDrawable", m_next_drawable),
    SEL_ENTRY("texture", m_drawable_texture),
    // Setters, encoding and synchronization: nothing to do.
    SEL_ENTRY("commit", m_nil),
    SEL_ENTRY("waitUntilCompleted", m_nil),
    SEL_ENTRY("presentDrawable:", m_nil),
    SEL_ENTRY("endEncoding", m_nil),
    SEL_ENTRY("generateMipmapsForTexture:", m_nil),
    SEL_ENTRY("drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", m_nil),
    SEL_ENTRY("setVertexBuffer:offset:atIndex:", m_nil),
    SEL_ENTRY("setFragmentBuffer:offset:atIndex:", m_nil),
    SEL_ENTRY("setVertexBytes:length:atIndex:", m_nil),
    SEL_ENTRY("setFragmentTexture:atIndex:", m_nil),
    SEL_ENTRY("setRenderPipelineState:", m_nil),
    SEL_ENTRY("setTexture:", m_nil),
    SEL_ENTRY("setLoadAction:", m_nil),
    SEL_ENTRY("setStoreAction:", m_nil),
    SEL_ENTRY("setClearColor:", m_nil),
    SEL_ENTRY("setPixelFormat:", m_nil),
    SEL_ENTRY("setBlendingEnabled:", m_nil),
    SEL_ENTRY("setSourceRGBBlendFactor:", m_nil),
    SEL_ENTRY("setDestinationRGBBlendFactor:", m_nil),
    SEL_ENTRY("setSourceAlphaBlendFactor:", m_nil),
    SEL_ENTRY("setDestinationAlphaBlendFactor:", m_nil),
    SEL_ENTRY("setVertexFunction:", m_nil),
    SEL_ENTRY("setFragmentFunction:", m_nil),
    SEL_ENTRY("setFramebufferOnly:", m_nil),
    SEL_ENTRY("setSwizzle:", m_nil),
    SEL_ENTRY("setUsage:", m_nil),
    SEL_ENTRY("setStorageMode:", m_nil),
};
#define SELECTOR_COUNT (sizeof(g_selectors) / sizeof(g_selectors[0]))

// Selectors not in the table, kept so each is reported once.
typedef struct Unknown_Selector {
  Selector sel;
  struct Unknown_Selector *next;
} Unknown_Selector;
static Unknown_Selector *g_unknown;
static pthread_mutex_t g_sel_mutex = PTHREAD_MUTEX_INITIALIZER;

static void *m_unknown(Id self, SEL_T cmd) { return NULL; }

EXPORT void *sel_registerName(const char *name) {
  for (size_t i = 0; i < SELECTOR_COUNT; i++)
    if (strcmp(g_selectors[i].name, name) == 0) return &g_selectors[i];
  pthread_mutex_lock(&g_sel_mutex);
  Unknown_Selector *u = g_unknown;
  for (; u; u = u->next)
    if (strcmp(u->sel.name, name) == 0) break;
  if (!u) {
    u = calloc(1, sizeof(Unknown_Selector));
    u->sel.name = strdup(name);
    u->sel.imp = (void *)m_unknown;
    u->next = g_unknown;
    g_unknown = u;
    fprintf(stderr, "stubs: no Obj-C method %s, answering nil\n", name);
  }
  pthread_mutex_unlock(&g_sel_mutex);
  return &u->sel;
}

static Object g_classes[] = {
    {O_CLASS, 0, "NSString"},
    {O_CLASS, 0, "MTLRenderPassDescriptor"},
    {O_CLASS, 0, "MTLTextureDescriptor"},
    {O_CLASS, 0, "MTLRenderPipelineDescriptor"},
};

EXPORT void *objc_getClass(const char *name) {
  for (size_t i = 0; i < sizeof(g_classes) / sizeof(g_classes[0]); i++)
    if (strcmp(g_classes[i].class_name, name) == 0) return &g_classes[i];
  fprintf(stderr, "stubs: no Obj-C class %s\n", name);
  return NULL;
}

EXPORT void *objc_lookup(void *self, void *sel) {
  if (!self || !sel) return (void *)m_unknown;
  return ((Selector *)sel)->imp;
}

#if defined(__x86_64__)
__asm__(".text\n"
        ".globl objc_msgSend\n"
        ".type objc_msgSend, @function\n"
        "objc_msgSend:\n"
        "  pushq %rbp\n"
        "  movq %rsp, %rbp\n"
        "  subq $192, %rsp\n"
        "  movq %rdi, 0(%rsp)\n"
        "  movq %rsi, 8(%rsp)\n"
        "  movq %rdx, 16(%rsp)\n"
        "  movq %rcx, 24(%rsp)\n"
        "  movq %r8, 32(%rsp)\n"
        "  movq %r9, 40(%rsp)\n"
        "  movq %rax, 48(%rsp)\n"
        "  movdqu %xmm0, 64(%rsp)\n"
        "  movdqu %xmm1, 80(%rsp)\n"
        "  movdqu %xmm2, 96(%rsp)\n"
        "  movdqu %xmm3, 112(%rsp)\n"
        "  movdqu %xmm4, 128(%rsp)\n"
        "  movdqu %xmm5, 144(%rsp)\n"
        "  movdqu %xmm6, 160(%rsp)\n"
        "  movdqu %xmm7, 176(%rsp)\n"
        "  call objc_lookup@PLT\n"
        "  movq %rax, %r11\n"
        "  movq 0(%rsp), %rdi\n"
        "  movq 8(%rsp), %rsi\n"
        "  movq 16(%rsp), %rdx\n"
        "  movq 24(%rsp), %rcx\n"
        "  movq 32(%rsp), %r8\n"
        "  movq 40(%rsp), %r9\n"
        "  movq 48(%rsp), %rax\n"
        "  movdqu 64(%rsp), %xmm0\n"
        "  movdqu 80(%rsp), %xmm1\n"
        "  movdqu 96(%rsp), %xmm2\n"
        "  movdqu 112(%rsp), %xmm3\n"
        "  movdqu 128(%rsp), %xmm4\n"
        "  movdqu 144(%rsp), %xmm5\n"
        "  movdqu 160(%rsp), %xmm6\n"
        "  movdqu 176(%rsp), %xmm7\n"
        "  leave\n"
        "  jmp *%r11\n");
#elif defined(__aarch64__)
__asm__(".text\n"
        ".globl objc_msgSend\n"
        ".type objc_msgSend, %function\n"
        "objc_msgSend:\n"
        "  stp x29, x30, [sp, #-224]!\n"
        "  mov x29, sp\n"
        "  stp x0, x1, [sp, #16]\n"
        "  stp x2, x3, [sp, #32]\n"
        "  stp x4, x5, [sp, #48]\n"
        "  stp x6, x7, [sp, #64]\n"
        "  str x8, [sp, #80]\n"
        "  stp q0, q1, [sp, #96]\n"
        "  stp q2, q3, [sp, #128]\n"
        "  stp q4, q5, [sp, #160]\n"
        "  stp q6, q7, [sp, #192]\n"
        "  bl objc_lookup\n"
        "  mov x16, x0\n"
        "  ldp x0, x1, [sp, #16]\n"
        "  ldp x2, x3, [sp, #32]\n"
        "  ldp x4, x5, [sp, #48]\n"
        "  ldp x6, x7, [sp, #64]\n"
        "  ldr x8, [sp, #80]\n"
        "  ldp q0, q1, [sp, #96]\n"
        "  ldp q2, q3, [sp, #128]\n"
        "  ldp q4, q5, [sp, #160]\n"
        "  ldp q6, q7, [sp, #192]\n"
        "  ldp x29, x30, [sp], #224\n"
        "  br x16\n");
#else
#error "objc_msgSend trampoline: x86_64 and arm64 only"
#endif

// For the shell: the device and layer it hands the app.
EXPORT void *tf_metal_device(void) {
  Object *o = obj_new(O_DEVICE);
  atomic_store(&o->refs, 0);
  return o;
}

EXPORT void *tf_metal_layer(size_t pixel_format) {
  Layer *l = calloc(1, sizeof(Layer));
  l->base.kind = O_LAYER;
  l->base.pixel_format = pixel_format;
  l->format = pixel_format;
  l->max = 2;
  return l;
}

EXPORT void tf_layer_set_size(void *layer, size_t width, size_t height) {
  Layer *l = layer;
  l->width = width;
  l->height = height;
}

EXPORT void tf_layer_set_max_drawables(void *layer, int max) { ((Layer *)layer)->max = max < 2 ? 2 : max > MAX_DRAWABLES ? MAX_DRAWABLES : max; }
