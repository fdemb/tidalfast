// The parts of the shell shared by shell_cocoa.m, shell_wayland.c and
// shell_win32.c. See common.h.

#define _CRT_SECURE_NO_WARNINGS
#define _CRT_NONSTDC_NO_DEPRECATE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"

#ifdef _WIN32
#define strtok_r strtok_s
#define strdup _strdup
#endif

atomic_bool g_needs_redraw;
atomic_bool g_quit;
double g_start_time;
bool g_now_playing_log;

void common_init(void) {
  g_start_time = now_seconds();
  g_now_playing_log = getenv("TIDALFAST_NOW_PLAYING_LOG") != NULL;
}

static Event *g_events;
static uint32_t g_event_count, g_event_capacity;
static uint8_t *g_text;
static uint32_t g_text_len, g_text_cap;

// push_text copies text for an event into the frame's text buffer.
void push_text(Event *e, const char *text, size_t n) {
  if (g_text_len + n > g_text_cap) {
    while (g_text_len + n > g_text_cap) g_text_cap = g_text_cap ? g_text_cap * 2 : 1024;
    g_text = realloc(g_text, g_text_cap);
  }
  memcpy(g_text + g_text_len, text, n);
  e->text_offset = g_text_len;
  e->text_length = (uint32_t)n;
  g_text_len += (uint32_t)n;
}

static bool continuous_phase(uint32_t phase) {
  return phase == SCROLL_PHASE_NONE || phase == SCROLL_PHASE_CHANGED;
}

// Folds e into the last queued event when nothing between them matters: a
// move or resize replaces the one before it, and a scroll adds to a scroll in
// the same phase. Phase changes such as began and ended keep their own event.
static bool coalesce(Event *last, Event e) {
  if (last->kind != e.kind) return false;
  if (e.kind == EVENT_MOUSE_MOVE || e.kind == EVENT_RESIZE) {
    *last = e;
    return true;
  }
  if (e.kind == EVENT_SCROLL && last->phase == e.phase && last->momentum_phase == e.momentum_phase &&
      continuous_phase(e.phase) && continuous_phase(e.momentum_phase) && last->precise == e.precise &&
      last->modifiers == e.modifiers) {
    e.dx += last->dx;
    e.dy += last->dy;
    *last = e;
    return true;
  }
  return false;
}

// The queue grows rather than drop an event or draw early: a lost mouse up
// or key up leaves it stuck down. It only gets long if the main loop goes a
// long time without drawing.
void push_event(Event e) {
  if (g_event_count == 0 || !coalesce(&g_events[g_event_count - 1], e)) {
    if (g_event_count == g_event_capacity) {
      g_event_capacity = g_event_capacity ? g_event_capacity * 2 : 256;
      g_events = realloc(g_events, g_event_capacity * sizeof(Event));
    }
    g_events[g_event_count++] = e;
  }
  atomic_store(&g_needs_redraw, true);
}

static Event *g_spare_events;
static uint32_t g_spare_event_capacity;
static uint8_t *g_spare_text;
static uint32_t g_spare_text_cap;

void queue_take(Event **events, uint32_t *count, const uint8_t **text, uint32_t *text_length) {
  *events = g_events;
  *count = g_event_count;
  *text = g_text;
  *text_length = g_text_len;
  Event *e = g_events;
  g_events = g_spare_events;
  g_spare_events = e;
  uint32_t n = g_event_capacity;
  g_event_capacity = g_spare_event_capacity;
  g_spare_event_capacity = n;
  uint8_t *t = g_text;
  g_text = g_spare_text;
  g_spare_text = t;
  n = g_text_cap;
  g_text_cap = g_spare_text_cap;
  g_spare_text_cap = n;
  g_event_count = 0;
  g_text_len = 0;
}

// Now Playing
//
// macOS shows it in Control Center (shell_cocoa.m). Linux and Windows
// don't show it anywhere yet, MPRIS over D-Bus and the System Media
// Transport Controls to come, and print_now_playing only logs what the app
// sets.
// TIDALFAST_NOW_PLAYING_LOG=1 prints it, and
// TIDALFAST_REMOTE_TEST="3:pause,5:play,7:seek=42,9:next" sends media
// commands as the media keys do.

void remote_command(uint32_t command, double position) {
  push_event((Event){.kind = EVENT_MEDIA, .media = (uint8_t)command, .dx = (float)position, .time = now_seconds()});
  if (g_now_playing_log) fprintf(stderr, "shell: remote command %u (%.3f)\n", command, position);
  request_redraw();
}

void print_now_playing(const Now_Playing *np) {
  if (!g_now_playing_log) return;
  if (!np || !np->title) {
    fprintf(stderr, "shell: now playing: state 0, title \"\"\n");
    return;
  }
  fprintf(stderr, "shell: now playing: state %u, title \"%s\", artist \"%s\", album \"%s\", duration %.3f, elapsed %.3f, artwork %ux%u\n",
          np->state, np->title, np->artist ? np->artist : "", np->album ? np->album : "", np->duration, np->elapsed,
          np->artwork ? np->artwork_width : 0, np->artwork ? np->artwork_height : 0);
}

typedef struct {
  double at;
  uint32_t command;
  double value;
  char text[64];
} Remote_Step;

static Remote_Step *g_remote_steps;
static int g_remote_count, g_remote_next;

// Text input
//
// See Text_Mirror in common.h. text-input-v3 and the shell's IME code on
// Windows work in the mirror's UTF-8 bytes. AppKit counts in UTF-16 units,
// which shell_cocoa.m converts, rounding down to a whole codepoint.

Text_Mirror g_ti = {.marked_start = -1, .marked_end = -1};

static uint32_t utf8_width(uint8_t c) { return c < 0xc0 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4; }

uint32_t utf16_of_byte(const uint8_t *s, uint32_t len, uint32_t byte) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < byte && i < len;) {
    uint32_t w = utf8_width(s[i]);
    n += w == 4 ? 2 : 1;
    i += w;
  }
  return n;
}

// byte_of_utf16 never lands between a surrogate pair's halves.
uint32_t byte_of_utf16(const uint8_t *s, uint32_t len, uint32_t u16) {
  uint32_t n = 0, i = 0;
  while (i < len) {
    uint32_t w = utf8_width(s[i]);
    uint32_t units = w == 4 ? 2 : 1;
    if (n + units > u16) break;
    n += units;
    i += w;
  }
  return i < len ? i : len;
}

static void mirror_replace(uint32_t lo, uint32_t hi, const char *text, uint32_t n) {
  uint32_t length = g_ti.length - (hi - lo) + n;
  if (length > g_ti.capacity) {
    g_ti.capacity = length * 2 + 64;
    g_ti.bytes = realloc(g_ti.bytes, g_ti.capacity);
  }
  memmove(g_ti.bytes + lo + n, g_ti.bytes + hi, g_ti.length - hi);
  memcpy(g_ti.bytes + lo, text, n);
  g_ti.length = length;
}

// The range an edit replaces: the one given (bytes, lo >= 0), else the
// marked text, else the selection.
static void edit_range(int64_t given_lo, int64_t given_hi, Event *e, uint32_t *lo, uint32_t *hi) {
  if (given_lo >= 0) {
    *lo = (uint32_t)(given_lo < g_ti.length ? given_lo : g_ti.length);
    *hi = (uint32_t)(given_hi < g_ti.length ? given_hi : g_ti.length);
    while (*lo > 0 && *lo < g_ti.length && (g_ti.bytes[*lo] & 0xc0) == 0x80) (*lo)--;
    while (*hi > 0 && *hi < g_ti.length && (g_ti.bytes[*hi] & 0xc0) == 0x80) (*hi)--;
    if (*hi < *lo) *hi = *lo;
    e->replace = 1;
    e->replace_start = (int32_t)*lo;
    e->replace_end = (int32_t)*hi;
  } else if (g_ti.marked_start >= 0) {
    *lo = (uint32_t)g_ti.marked_start;
    *hi = (uint32_t)g_ti.marked_end;
  } else {
    *lo = g_ti.sel_start;
    *hi = g_ti.sel_end;
  }
}

// utf8_decode reads one codepoint as Odin's utf8.decode_rune does: an
// invalid or cut short sequence is U+FFFD one byte long.
static uint32_t utf8_decode(const uint8_t *s, uint32_t n, uint32_t *cp) {
  uint8_t c = s[0];
  uint32_t w = 0, min = 0x80, max = 0xbf;
  if (c < 0x80) {
    *cp = c;
    return 1;
  } else if (c >= 0xc2 && c <= 0xdf) {
    w = 2;
  } else if (c >= 0xe0 && c <= 0xef) {
    w = 3;
    if (c == 0xe0) min = 0xa0;
    if (c == 0xed) max = 0x9f;
  } else if (c >= 0xf0 && c <= 0xf4) {
    w = 4;
    if (c == 0xf0) min = 0x90;
    if (c == 0xf4) max = 0x8f;
  }
  *cp = 0xfffd;
  if (w == 0 || n < w || s[1] < min || s[1] > max) return 1;
  for (uint32_t i = 2; i < w; i++)
    if (s[i] < 0x80 || s[i] > 0xbf) return 1;
  uint32_t r = c & (0xff >> (w + 1));
  for (uint32_t i = 1; i < w; i++) r = r << 6 | (s[i] & 0x3f);
  *cp = r;
  return w;
}

// field_sanitize cleans n bytes of text as the app's field does (sanitize
// in src/ui/edit.odin): a run of line breaks and tabs (LF, CR, tab, NEL,
// U+2028, U+2029) becomes one space, or none at the start, and the other
// C0 and C1 controls, DEL, U+FFFD and invalid bytes go. It writes to out,
// which has room for n bytes, and returns the length.
static uint32_t field_sanitize(const char *text, uint32_t n, char *out) {
  const uint8_t *s = (const uint8_t *)text;
  uint32_t o = 0;
  for (uint32_t i = 0; i < n;) {
    uint32_t cp, w = utf8_decode(s + i, n - i, &cp);
    if (cp == '\n' || cp == '\r' || cp == '\t' || cp == 0x85 || cp == 0x2028 || cp == 0x2029) {
      if (o > 0 && out[o - 1] != ' ') out[o++] = ' ';
    } else if (!(cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) || cp == 0xfffd)) {
      memcpy(out + o, s + i, w);
      o += w;
    }
    i += w;
  }
  return o;
}

// field_fits says whether n bytes in place of [lo, hi) keep the field
// within its limit. An edit that doesn't fit is refused whole, by the app
// too, so the two never cut text in different places.
static bool field_fits(uint32_t n, uint32_t lo, uint32_t hi) {
  return !g_ti.limit || (uint64_t)g_ti.length - (hi - lo) + n <= g_ti.limit;
}

// utf8_start moves p back to the start of the UTF-8 sequence it's in.
static uint32_t utf8_start(const uint8_t *s, uint32_t n, uint32_t p) {
  while (p > 0 && p < n && (s[p] & 0xc0) == 0x80) p--;
  return p;
}

// text_insert is insertText: text in place of the given range (bytes, or
// lo < 0 for the marked text or the selection), ending any composition.
void text_insert(const char *utf8, int64_t lo_given, int64_t hi_given) {
  uint32_t n = (uint32_t)strlen(utf8);
  Event e = {.kind = EVENT_TEXT, .time = now_seconds()};
  push_text(&e, utf8, n);
  uint32_t lo, hi;
  edit_range(lo_given, hi_given, &e, &lo, &hi);
  char *clean = malloc(n + 1);
  uint32_t cn = field_sanitize(utf8, n, clean);
  if (!field_fits(cn, lo, hi)) {
    // Refused: a composition ends as it was, as unmark does.
    if (g_ti.marked_start >= 0) g_ti.sel_start = g_ti.sel_end = (uint32_t)g_ti.marked_end;
  } else if (cn > 0 || lo != hi) {
    // The field leaves itself alone when nothing goes in and nothing goes.
    mirror_replace(lo, hi, clean, cn);
    g_ti.sel_start = g_ti.sel_end = lo + cn;
  }
  free(clean);
  g_ti.marked_start = g_ti.marked_end = -1;
  push_event(e);
  request_redraw();
}

// text_set_marked is setMarkedText: the composition, with the input
// method's selection inside it in bytes.
void text_set_marked(const char *utf8, uint32_t sel_lo, uint32_t sel_hi, int64_t lo_given, int64_t hi_given) {
  uint32_t n = (uint32_t)strlen(utf8);
  Event e = {.kind = EVENT_MARKED_TEXT, .time = now_seconds()};
  push_text(&e, utf8, n);
  if (sel_lo > n) sel_lo = n;
  if (sel_hi > n) sel_hi = n;
  e.select_start = (int32_t)sel_lo;
  e.select_end = (int32_t)(sel_hi < sel_lo ? sel_lo : sel_hi);
  uint32_t lo, hi;
  edit_range(lo_given, hi_given, &e, &lo, &hi);
  char *clean = malloc(n + 1);
  uint32_t cn = field_sanitize(utf8, n, clean);
  if (!field_fits(cn, lo, hi)) {
    // Refused: the mirror stays as it was.
  } else if (cn > 0) {
    mirror_replace(lo, hi, clean, cn);
    uint32_t end = (uint32_t)e.select_end;
    g_ti.marked_start = (int32_t)lo;
    g_ti.marked_end = (int32_t)(lo + cn);
    g_ti.sel_start = lo + utf8_start((const uint8_t *)clean, cn, sel_lo < cn ? sel_lo : cn);
    g_ti.sel_end = lo + utf8_start((const uint8_t *)clean, cn, end < cn ? end : cn);
  } else {
    mirror_replace(lo, hi, clean, cn);
    g_ti.marked_start = g_ti.marked_end = -1;
    g_ti.sel_start = g_ti.sel_end = lo;
  }
  free(clean);
  push_event(e);
  request_redraw();
}

void text_unmark(void) {
  if (g_ti.marked_start >= 0) g_ti.sel_start = g_ti.sel_end = (uint32_t)g_ti.marked_end;
  g_ti.marked_start = g_ti.marked_end = -1;
  push_event((Event){.kind = EVENT_UNMARK_TEXT, .time = now_seconds()});
  request_redraw();
}

// surrounding_text is the field's text for the input method, which must
// leave out the composition: with marked text, the text around it, with
// the cursor and anchor where it was. Bytes; out holds g_ti.length + 1.
void surrounding_text(char *out, int32_t *cursor, int32_t *anchor) {
  if (g_ti.marked_start >= 0) {
    uint32_t lo = (uint32_t)g_ti.marked_start, hi = (uint32_t)g_ti.marked_end;
    memcpy(out, g_ti.bytes, lo);
    memcpy(out + lo, g_ti.bytes + hi, g_ti.length - hi);
    out[lo + g_ti.length - hi] = 0;
    *cursor = *anchor = (int32_t)lo;
    return;
  }
  memcpy(out, g_ti.bytes, g_ti.length);
  out[g_ti.length] = 0;
  *cursor = (int32_t)g_ti.sel_end;
  *anchor = (int32_t)g_ti.sel_start;
}

bool mirror_set(const Text_Input *ti) {
  if (!ti || !ti->text) {
    bool was = g_ti.active;
    g_ti.active = false;
    g_ti.length = g_ti.sel_start = g_ti.sel_end = 0;
    g_ti.marked_start = g_ti.marked_end = -1;
    return was;
  }
  bool changed = !g_ti.active || ti->length != g_ti.length || memcmp(ti->text, g_ti.bytes, ti->length) != 0 ||
                 ti->selection_start != g_ti.sel_start || ti->selection_end != g_ti.sel_end ||
                 memcmp(ti->caret, g_ti.caret, sizeof g_ti.caret) != 0;
  g_ti.length = 0;
  mirror_replace(0, 0, (const char *)ti->text, ti->length);
  g_ti.sel_start = ti->selection_start;
  g_ti.sel_end = ti->selection_end;
  g_ti.marked_start = ti->marked_start;
  g_ti.marked_end = ti->marked_end;
  g_ti.limit = ti->limit;
  memcpy(g_ti.caret, ti->caret, sizeof g_ti.caret);
  g_ti.active = true;
  return changed;
}

// Accessibility
//
// macOS hands the tree to assistive apps (shell_cocoa.m). Linux and
// Windows don't expose it yet, AT-SPI over D-Bus and UI Automation to come,
// and keep the copy for the test driver, offering set_accessibility only
// when it runs.

Shell_Node *g_nodes;
uint32_t g_node_count;
static uint32_t g_node_cap;

void access_store(const Access_Node *nodes, uint32_t count) {
  for (uint32_t i = 0; i < g_node_count; i++) {
    free(g_nodes[i].label);
    free(g_nodes[i].value);
  }
  if (count > g_node_cap) {
    g_node_cap = count * 2;
    g_nodes = realloc(g_nodes, g_node_cap * sizeof(Shell_Node));
  }
  for (uint32_t i = 0; i < count; i++) {
    const Access_Node *n = &nodes[i];
    g_nodes[i] = (Shell_Node){
        .id = n->id,
        .parent = n->parent,
        .role = n->role,
        .flags = n->flags,
        .frame = {n->frame[0], n->frame[1], n->frame[2], n->frame[3]},
        .label = n->label ? strdup(n->label) : NULL,
        .value = n->value ? strdup(n->value) : NULL,
    };
  }
  g_node_count = count;
}

static const char *access_role_name(uint32_t role) {
  static const char *names[] = {"none", "group", "button", "text field", "static text", "list", "table", "row", "menu", "menu item", "slider"};
  return role < sizeof names / sizeof names[0] ? names[role] : "?";
}

bool access_pressable(uint32_t role) {
  return role == ACCESS_BUTTON || role == ACCESS_ROW || role == ACCESS_MENU_ITEM;
}

// TIDALFAST_SHELL_TEST runs steps against the shell's own entry points, for
// checking text input and accessibility without a person at the keyboard:
// "2:key=ctrl+f;3:mark=にほんご;4:commit=日本語;6:ax-dump;7:ax-press=Next".
// Steps are seconds after the window is up and a command, separated by
// semicolons. Commands joined with | run together, with no frame between
// them. Ranges are in UTF-16 units on every OS. Here, ax-dump prints the
// tree as the app sent it, and ax-press sends the app the press an
// assistive app would; macOS takes those and the input method's steps
// itself, to go through AppKit (os_test_step in shell_cocoa.m).
//
//   key=ctrl+shift+z    a key down and up, with cmd or super, ctrl, opt or alt, and shift
//                       (letters, digits, escape, return, tab, left...)
//   mark=text           a composition, with the caret at the end of text
//   commit=text         text from an input method
//   mark-range=l,n,text a composition replacing UTF-16 units [l, l+n)
//   commit-range=l,n,text text replacing UTF-16 units [l, l+n)
//   commit-marked=text  text replacing the composition
//   unmark              end the composition as it is
//   clean=hex           print what field_sanitize makes of the bytes, in hex
//   ime                 print the shell's mirror of the text field and the surrounding text an input method gets
//   ax-dump             print the accessibility tree
//   ax-press=label      press the first pressable node whose label or value starts with label
//   capture=path        copy the last TIDALFAST_CAPTURE frame to path
//   quit
//
// Each OS's shell adds its own (os_test_step), such as size=w,h, which
// shell_cocoa.m, shell_wayland.c and shell_win32.c list.

typedef struct {
  double at;
  char *text; // the step after the colon, commands separated by |
} Test_Step;

static Test_Step *g_test_steps;
static int g_test_count, g_test_next;
static double g_test_start; // now_seconds at setup_shell_test, which step times count from

static uint32_t key_named(const char *name) {
  static const struct {
    const char *name;
    uint32_t key;
  } named[] = {
      {"return", KEY_RETURN}, {"tab", KEY_TAB},   {"space", KEY_SPACE}, {"backspace", KEY_BACKSPACE},
      {"escape", KEY_ESCAPE}, {"delete", KEY_DELETE}, {"home", KEY_HOME}, {"end", KEY_END},
      {"left", KEY_LEFT},     {"right", KEY_RIGHT}, {"down", KEY_DOWN},   {"up", KEY_UP},
  };
  for (size_t i = 0; i < sizeof named / sizeof named[0]; i++)
    if (!strcmp(named[i].name, name)) return named[i].key;
  if (strlen(name) == 1) {
    char c = name[0];
    if (c >= 'a' && c <= 'z') return KEY_A + (uint32_t)(c - 'a');
    if (c >= '0' && c <= '9') return KEY_DIGIT_0 + (uint32_t)(c - '0');
  }
  return KEY_NONE;
}

static void test_key(char *spec) {
  uint32_t mods = 0;
  char *last = spec;
  for (char *part = strtok(spec, "+"); part; part = strtok(NULL, "+")) {
    if (!strcmp(part, "cmd") || !strcmp(part, "super")) mods |= MODIFIER_SUPER;
    else if (!strcmp(part, "shift")) mods |= MODIFIER_SHIFT;
    else if (!strcmp(part, "opt") || !strcmp(part, "alt")) mods |= MODIFIER_ALT;
    else if (!strcmp(part, "ctrl")) mods |= MODIFIER_CONTROL;
    last = part;
  }
  uint32_t key = key_named(last);
  if (key == KEY_NONE) {
    fprintf(stderr, "shell: test: no key named %s\n", last);
    return;
  }
  double now = now_seconds();
  push_event((Event){.kind = EVENT_KEY_DOWN, .modifiers = mods, .key = key, .time = now});
  push_event((Event){.kind = EVENT_KEY_UP, .modifiers = mods, .key = key, .time = now});
  request_redraw();
}

static void test_ime_state(void) {
  char *text = malloc(g_ti.length + 1);
  memcpy(text, g_ti.bytes, g_ti.length);
  text[g_ti.length] = 0;
  char marked[64] = "none";
  if (g_ti.marked_start >= 0) {
    uint32_t lo = utf16_of_byte(g_ti.bytes, g_ti.length, (uint32_t)g_ti.marked_start);
    uint32_t hi = utf16_of_byte(g_ti.bytes, g_ti.length, (uint32_t)g_ti.marked_end);
    snprintf(marked, sizeof marked, "{%u, %u}", lo, hi - lo);
  }
  uint32_t lo = utf16_of_byte(g_ti.bytes, g_ti.length, g_ti.sel_start), hi = utf16_of_byte(g_ti.bytes, g_ti.length, g_ti.sel_end);
  char *around = malloc(g_ti.length + 1);
  int32_t cursor, anchor;
  surrounding_text(around, &cursor, &anchor);
  fprintf(stderr, "shell: ime: active %d, text \"%s\", marked %s, selected {%u, %u}, caret {%.0f, %.0f, %.0f, %.0f}, surrounding \"%s\" bytes %d to %d\n",
          g_ti.active, text, marked, lo, hi - lo, g_ti.caret[0], g_ti.caret[1], g_ti.caret[2], g_ti.caret[3], around, anchor, cursor);
  free(around);
  free(text);
}

static void test_ax(const char *press) {
  int depth[4096];
  bool pressed = false;
  for (uint32_t i = 0; i < g_node_count; i++) {
    Shell_Node *n = &g_nodes[i];
    int d = n->parent >= 0 && (uint32_t)n->parent < i && n->parent < 4096 ? depth[n->parent] + 1 : 1;
    if (i < 4096) depth[i] = d;
    const char *label = n->label ? n->label : "";
    if (!press) {
      fprintf(stderr, "shell: ax: %*s%s \"%s\"%s%s%s {%.0f, %.0f, %.0f, %.0f}%s%s\n", d * 2, "", access_role_name(n->role), label,
              n->value ? " = \"" : "", n->value ? n->value : "", n->value ? "\"" : "", n->frame[0], n->frame[1], n->frame[2],
              n->frame[3], n->flags & ACCESS_FOCUSED ? " focused" : "", access_pressable(n->role) ? " press" : "");
    } else if (!pressed && access_pressable(n->role) &&
               (!strncmp(label, press, strlen(press)) || (n->value && !strncmp(n->value, press, strlen(press))))) {
      fprintf(stderr, "shell: ax: pressing %s \"%s\"\n", access_role_name(n->role), label);
      push_event((Event){.kind = EVENT_ACCESS_PRESS, .target = n->id, .time = now_seconds()});
      request_redraw();
      pressed = true;
    }
  }
  if (press && !pressed) fprintf(stderr, "shell: ax: nothing to press called %s\n", press);
}

static void test_clean(const char *hex) {
  uint32_t n = (uint32_t)strlen(hex) / 2;
  char *in = malloc(n + 1), *out = malloc(n + 1);
  for (uint32_t i = 0; i < n; i++) {
    char byte[3] = {hex[i * 2], hex[i * 2 + 1], 0};
    in[i] = (char)strtoul(byte, NULL, 16);
  }
  uint32_t o = field_sanitize(in, n, out);
  fprintf(stderr, "shell: clean %s -> ", hex);
  for (uint32_t i = 0; i < o; i++) fprintf(stderr, "%02x", (uint8_t)out[i]);
  fprintf(stderr, "\n");
  free(in);
  free(out);
}

// test_range splits "location,length,text" into a byte range of the
// field's text.
static const char *test_range(char *arg, int64_t *lo, int64_t *hi) {
  char *a = strchr(arg, ',');
  char *b = a ? strchr(a + 1, ',') : NULL;
  if (!b) {
    *lo = *hi = -1;
    return "";
  }
  uint32_t location = (uint32_t)strtoul(arg, NULL, 10), length = (uint32_t)strtoul(a + 1, NULL, 10);
  *lo = byte_of_utf16(g_ti.bytes, g_ti.length, location);
  *hi = byte_of_utf16(g_ti.bytes, g_ti.length, location + length);
  return b + 1;
}

static bool copy_file(const char *from, const char *to) {
  FILE *in = fopen(from, "rb");
  if (!in) return false;
  FILE *out = fopen(to, "wb");
  if (!out) {
    fclose(in);
    return false;
  }
  char buf[1 << 16];
  size_t n;
  bool ok = true;
  while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
    if (fwrite(buf, 1, n, out) != n) {
      ok = false;
      break;
    }
  }
  ok = ok && !ferror(in);
  fclose(in);
  return fclose(out) == 0 && ok;
}

static void test_step(const char *command, char *arg) {
  int64_t lo, hi;
  if (os_test_step(command, arg)) {
    // The OS's own, or its own way of a shared one.
  } else if (!strcmp(command, "key")) {
    test_key(arg);
  } else if (!strcmp(command, "mark")) {
    text_set_marked(arg, (uint32_t)strlen(arg), (uint32_t)strlen(arg), -1, -1);
  } else if (!strcmp(command, "commit")) {
    text_insert(arg, -1, -1);
  } else if (!strcmp(command, "mark-range")) {
    const char *text = test_range(arg, &lo, &hi);
    text_set_marked(text, (uint32_t)strlen(text), (uint32_t)strlen(text), lo, hi);
  } else if (!strcmp(command, "commit-range")) {
    const char *text = test_range(arg, &lo, &hi);
    text_insert(text, lo, hi);
  } else if (!strcmp(command, "commit-marked")) {
    if (g_ti.marked_start >= 0) text_insert(arg, g_ti.marked_start, g_ti.marked_end);
    else text_insert(arg, -1, -1);
  } else if (!strcmp(command, "clean")) {
    test_clean(arg);
  } else if (!strcmp(command, "unmark")) {
    text_unmark();
  } else if (!strcmp(command, "ime")) {
    test_ime_state();
  } else if (!strcmp(command, "ax-dump")) {
    test_ax(NULL);
  } else if (!strcmp(command, "ax-press")) {
    test_ax(arg);
  } else if (!strcmp(command, "capture")) {
    const char *from = getenv("TIDALFAST_CAPTURE");
    if (!from || !copy_file(from, arg)) fprintf(stderr, "shell: test: couldn't copy the capture to %s\n", arg);
    else fprintf(stderr, "shell: test: captured %s\n", arg);
  } else if (!strcmp(command, "quit")) {
    atomic_store(&g_quit, true);
    request_redraw();
  } else {
    fprintf(stderr, "shell: test: unknown step %s\n", command);
  }
}

static int compare_steps(const void *a, const void *b) {
  double x = ((const Test_Step *)a)->at, y = ((const Test_Step *)b)->at;
  return x < y ? -1 : x > y;
}

static void arm_test_timer(void) {
  double next = 1e30;
  if (g_test_next < g_test_count) next = g_test_steps[g_test_next].at;
  if (g_remote_next < g_remote_count && g_remote_steps[g_remote_next].at < next) next = g_remote_steps[g_remote_next].at;
  if (next < 1e30) {
    double after = next - (now_seconds() - g_test_start);
    os_arm_test_timer(after > 0 ? after : 1e-6);
  }
}

void run_due_steps(void) {
  double now = now_seconds() - g_test_start;
  while (g_test_next < g_test_count && g_test_steps[g_test_next].at <= now) {
    Test_Step *s = &g_test_steps[g_test_next++];
    fprintf(stderr, "shell: test step %g:%s\n", s->at, s->text);
    char *save;
    for (char *rest = strtok_r(s->text, "|", &save); rest; rest = strtok_r(NULL, "|", &save)) {
      char *eq = strchr(rest, '=');
      char *arg = (char *)"";
      if (eq) {
        *eq = 0;
        arg = eq + 1;
      }
      test_step(rest, arg);
    }
  }
  while (g_remote_next < g_remote_count && g_remote_steps[g_remote_next].at <= now) {
    Remote_Step *s = &g_remote_steps[g_remote_next++];
    fprintf(stderr, "shell: remote test sends %s\n", s->text);
    remote_command(s->command, s->value);
  }
  arm_test_timer();
}

void setup_shell_test(void) {
  g_test_start = now_seconds();
  const char *script = getenv("TIDALFAST_SHELL_TEST");
  if (script) {
    char *copy = strdup(script), *save;
    for (char *step = strtok_r(copy, ";", &save); step; step = strtok_r(NULL, ";", &save)) {
      char *colon = strchr(step, ':');
      if (!colon) continue;
      *colon = 0;
      g_test_steps = realloc(g_test_steps, (size_t)(g_test_count + 1) * sizeof(Test_Step));
      g_test_steps[g_test_count++] = (Test_Step){.at = strtod(step, NULL), .text = strdup(colon + 1)};
    }
    free(copy);
    qsort(g_test_steps, (size_t)g_test_count, sizeof(Test_Step), compare_steps);
  }
  const char *remote = getenv("TIDALFAST_REMOTE_TEST");
  if (remote) {
    static const struct {
      const char *name;
      uint32_t command;
    } names[] = {{"play", MEDIA_PLAY}, {"pause", MEDIA_PAUSE}, {"toggle", MEDIA_TOGGLE}, {"next", MEDIA_NEXT}, {"previous", MEDIA_PREVIOUS}, {"seek", MEDIA_SEEK}};
    char *copy = strdup(remote), *save;
    for (char *step = strtok_r(copy, ",", &save); step; step = strtok_r(NULL, ",", &save)) {
      char *colon = strchr(step, ':');
      if (!colon) continue;
      Remote_Step s = {.at = strtod(step, NULL)};
      snprintf(s.text, sizeof s.text, "%s", step);
      char *name = colon + 1, *eq = strchr(name, '=');
      if (eq) {
        *eq = 0;
        s.value = strtod(eq + 1, NULL);
      }
      bool found = false;
      for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
        if (!strcmp(names[i].name, name)) s.command = names[i].command, found = true;
      if (!found) continue;
      g_remote_steps = realloc(g_remote_steps, (size_t)(g_remote_count + 1) * sizeof(Remote_Step));
      g_remote_steps[g_remote_count++] = s;
    }
    free(copy);
    for (int i = 1; i < g_remote_count; i++)
      for (int j = i; j > 0 && g_remote_steps[j].at < g_remote_steps[j - 1].at; j--) {
        Remote_Step t = g_remote_steps[j];
        g_remote_steps[j] = g_remote_steps[j - 1];
        g_remote_steps[j - 1] = t;
      }
  }
  arm_test_timer();
}
