// The Linux executable. Owns the Wayland connection, the window and its
// surface, collects input into an event array, and drives the app library
// through the App_API table in platform.h, as shell.m does on macOS. The
// renderer makes its own Vulkan surface from the Wayland_Surface it gets.
//
// It redraws only when something asks for it: input, a resize, a reload or
// request_redraw from any thread. While the app reports it is animating, a
// frame callback adds a frame each time the compositor wants one, and other
// redraws wait for it; a hidden window gets no callbacks and stops drawing.
// A frame can also ask to be woken after a delay, which a timerfd does.
// Everything waits in one poll: the Wayland socket, an eventfd for
// request_redraw, timerfds and inotify for hot reload.
//
// Text input goes through text-input-unstable-v3 when the compositor runs
// an input method, and otherwise from the keyboard through xkbcommon, with
// compose sequences for dead keys. Trackpad scrolls carry phases, and the
// shell adds momentum after the fingers lift, since Wayland leaves that to
// the client. Not here yet: accessibility (AT-SPI) and Now Playing (MPRIS);
// the shell takes the app's tree only for the test driver's ax-dump and
// ax-press, and media keys reach the app while the window has the keyboard.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/inotify.h>
#include <sys/mman.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland-cursor.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon.h>

#include "fractional-scale-v1-client-protocol.h"
#include "text-input-unstable-v3-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include "platform.h"

#ifndef HOT_RELOAD
#define HOT_RELOAD 1
#endif

#define PERSISTENT_SIZE (256ull << 20)
#define FRAME_SIZE (64ull << 20)
#define DEFAULT_WIDTH 1100
#define DEFAULT_HEIGHT 700

typedef struct {
  void *handle;
  App_API api;
  ino_t inode;
  struct timespec mtime;
} Loaded_App;

static Loaded_App g_app;
static char g_app_path[PATH_MAX];
static int g_reload_count;

static Memory g_memory;
static Shell g_shell;
static Wayland_Surface g_surface_info;
static Event *g_events;
static uint32_t g_event_count, g_event_capacity;
static uint8_t *g_text; // bytes text events point into, reset with the events
static uint32_t g_text_len, g_text_cap;
static atomic_bool g_needs_redraw;
static bool g_animating;
static bool g_quit;
static double g_start_time;

// Wayland
static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static uint32_t g_compositor_version;
static struct wl_shm *g_shm;
static struct wl_seat *g_seat;
static struct wl_pointer *g_pointer;
static struct wl_keyboard *g_keyboard;
static struct wl_data_device_manager *g_data_manager;
static struct wl_data_device *g_data_device;
static struct xdg_wm_base *g_wm_base;
static struct zxdg_decoration_manager_v1 *g_decoration_manager;
static struct wp_viewporter *g_viewporter;
static struct wp_fractional_scale_manager_v1 *g_fractional_manager;
static struct zwp_text_input_manager_v3 *g_text_input_manager;
static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;
static struct wp_viewport *g_viewport;
static struct wp_fractional_scale_v1 *g_fractional;
static struct zwp_text_input_v3 *g_text_input;
static struct wl_cursor_theme *g_cursor_theme;
static struct wl_surface *g_cursor_surface;

static bool g_configured;
static bool g_configure_unanswered; // acked, and no frame drawn since
static float g_width = DEFAULT_WIDTH, g_height = DEFAULT_HEIGHT; // points
static float g_scale = 1;
static int32_t g_buffer_scale = 1; // without fractional scaling
static uint32_t g_fraction = 0; // the fractional scale, in 120ths; 0 without it
static bool g_key_window;
static uint32_t g_serial; // of the last input event, for the clipboard
static struct wl_callback *g_frame_callback;
static double g_frame_requested;
static double g_frame_interval = 1.0 / 60;

static int g_redraw_fd = -1; // eventfd
static int g_wake_fd = -1; // timerfd for wake_after
static int g_repeat_fd = -1; // timerfd for key repeat
static int g_momentum_fd = -1; // timerfd for scroll momentum
static int g_test_fd = -1; // timerfd for the next test step
static int g_inotify_fd = -1;
static int g_signal_fd = -1;

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void arm_timer(int fd, double after, double interval) {
  struct itimerspec spec = {0};
  if (after > 0) {
    spec.it_value.tv_sec = (time_t)after;
    spec.it_value.tv_nsec = (long)((after - (double)(time_t)after) * 1e9);
    if (spec.it_value.tv_sec == 0 && spec.it_value.tv_nsec == 0) spec.it_value.tv_nsec = 1;
  }
  if (interval > 0) {
    spec.it_interval.tv_sec = (time_t)interval;
    spec.it_interval.tv_nsec = (long)((interval - (double)(time_t)interval) * 1e9);
  }
  timerfd_settime(fd, 0, &spec, NULL);
}

static void drain(int fd) {
  uint64_t n;
  while (read(fd, &n, sizeof n) > 0) {
  }
}

// TIDALFAST_MEASURE: the shell's startup marks, in the format the app's
// measure.odin prints, in milliseconds since the kernel started the process.
static bool g_measure;
static double g_process_start; // CLOCK_REALTIME seconds

static void measure_mark(const char *name) {
  if (!g_measure) return;
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  fprintf(stderr, "measure: {\"mark\":\"%s\",\"ms\":%.1f}\n", name, (ts.tv_sec + ts.tv_nsec / 1e9 - g_process_start) * 1000);
}

// Field 22 of /proc/self/stat is the start time in clock ticks after boot.
static void measure_init(void) {
  const char *measure = getenv("TIDALFAST_MEASURE");
  g_measure = measure && *measure;
  if (!g_measure) return;
  struct timespec real, boot;
  clock_gettime(CLOCK_REALTIME, &real);
  clock_gettime(CLOCK_BOOTTIME, &boot);
  g_process_start = real.tv_sec + real.tv_nsec / 1e9;
  FILE *f = fopen("/proc/self/stat", "r");
  if (!f) return;
  char buf[1024];
  size_t n = fread(buf, 1, sizeof buf - 1, f);
  fclose(f);
  buf[n] = 0;
  char *p = strrchr(buf, ')');
  if (!p) return;
  unsigned long long start = 0;
  int field = 2;
  for (p++; *p && field < 22; p++)
    if (*p == ' ') field++;
  if (field == 22) start = strtoull(p, NULL, 10);
  long hz = sysconf(_SC_CLK_TCK);
  if (hz > 0 && start > 0) g_process_start -= (boot.tv_sec + boot.tv_nsec / 1e9) - (double)start / hz;
}

static void request_redraw(void) {
  atomic_store(&g_needs_redraw, true);
  uint64_t one = 1;
  if (write(g_redraw_fd, &one, sizeof one) < 0) {
  }
}

// Buttons held down, as the pointer events said. Wayland grabs the pointer
// while a button is down, so releases outside the window still arrive; a
// grab the compositor breaks ends in a leave, which clears them.
static uint32_t g_buttons;

static void set_text_input_state(void);
static void access_frame_done(void);

static void frame_done(void *data, struct wl_callback *callback, uint32_t time);
static const struct wl_callback_listener g_frame_listener = {.done = frame_done};

static void apply_scale(void) {
  if (g_fraction && g_viewport) {
    g_scale = g_fraction / 120.0f;
    wp_viewport_set_destination(g_viewport, (int32_t)g_width, (int32_t)g_height);
  } else {
    g_scale = (float)g_buffer_scale;
    wl_surface_set_buffer_scale(g_surface, g_buffer_scale);
  }
}

static void draw_frame(void) {
  if (!g_app.api.frame || !g_configured) return;
  atomic_store(&g_needs_redraw, false);
  g_configure_unanswered = false;
  // The callback goes with the commit the renderer's present makes.
  if (!g_frame_callback) {
    g_frame_callback = wl_surface_frame(g_surface);
    wl_callback_add_listener(g_frame_callback, &g_frame_listener, NULL);
    g_frame_requested = now_seconds();
  }
  apply_scale();
  Frame_Input input = {
      .events = g_events,
      .event_count = g_event_count,
      .width = g_width,
      .height = g_height,
      .scale = g_scale,
      .time = now_seconds() - g_start_time,
      .text = g_text,
      .text_length = g_text_len,
      .key_window = g_key_window,
      .mouse_buttons = g_buttons,
  };
  Frame_Result result = g_app.api.frame(&g_memory, &g_shell, &input);
  access_frame_done();
  g_event_count = 0;
  g_text_len = 0;
  g_animating = result.animating;
  arm_timer(g_wake_fd, result.wake_after > 0 ? result.wake_after : 0, 0);
  wl_display_flush(g_display);
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
  wl_callback_destroy(callback);
  g_frame_callback = NULL;
  double now = now_seconds();
  double interval = now - g_frame_requested;
  if (interval > 0.002 && interval < 0.1) g_frame_interval = g_frame_interval * 0.9 + interval * 0.1;
  if (g_animating || atomic_load(&g_needs_redraw)) draw_frame();
}

// When a frame callback is pending, the deadline by which it should have
// come; 0 when a redraw shouldn't wait for one. Input waits for it too:
// Wayland doesn't merge pointer motion, and with MAILBOX a fast mouse
// would otherwise draw a frame per event. A configure doesn't wait, so the
// compositor gets a frame at the new size soon after it.
static double frame_deadline(void) {
  if (!g_frame_callback || g_configure_unanswered) return 0;
  double deadline = g_frame_requested + 2 * g_frame_interval;
  return now_seconds() < deadline ? deadline : 0;
}

// push_text copies text for an event into the frame's text buffer.
static void push_text(Event *e, const char *text, size_t n) {
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
// or key up leaves it stuck down.
static void push_event(Event e) {
  if (g_event_count == 0 || !coalesce(&g_events[g_event_count - 1], e)) {
    if (g_event_count == g_event_capacity) {
      g_event_capacity = g_event_capacity ? g_event_capacity * 2 : 256;
      g_events = realloc(g_events, g_event_capacity * sizeof(Event));
    }
    g_events[g_event_count++] = e;
  }
  atomic_store(&g_needs_redraw, true);
}

// Hot reload

static bool file_identity(const char *path, ino_t *inode, struct timespec *mtime) {
  struct stat st;
  if (stat(path, &st) != 0) return false;
  *inode = st.st_ino;
  *mtime = st.st_mtim;
  return true;
}

static bool copy_file(const char *from, const char *to) {
  int in = open(from, O_RDONLY | O_CLOEXEC);
  if (in < 0) return false;
  int out = open(to, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0700);
  if (out < 0) {
    close(in);
    return false;
  }
  char buf[1 << 16];
  ssize_t n;
  bool ok = true;
  while ((n = read(in, buf, sizeof buf)) > 0) {
    if (write(out, buf, (size_t)n) != n) {
      ok = false;
      break;
    }
  }
  close(in);
  close(out);
  return ok && n == 0;
}

// With hot reload, copies the library to a unique temp path and opens the
// copy, so the linker can replace the original while this copy is loaded,
// and so dlopen sees a new file rather than handing back the old image.
static bool open_app(Loaded_App *out) {
  if (!file_identity(g_app_path, &out->inode, &out->mtime)) {
    fprintf(stderr, "shell: no app library at %s\n", g_app_path);
    return false;
  }
#if HOT_RELOAD
  char copy[PATH_MAX];
  const char *tmp = getenv("TMPDIR");
  snprintf(copy, sizeof copy, "%s/tidalfast-app-%d-%d.so", tmp && *tmp ? tmp : "/tmp", getpid(), g_reload_count++);
  if (!copy_file(g_app_path, copy)) {
    fprintf(stderr, "shell: copy to %s failed\n", copy);
    return false;
  }
  void *handle = dlopen(copy, RTLD_NOW | RTLD_LOCAL);
  unlink(copy);
#else
  void *handle = dlopen(g_app_path, RTLD_NOW | RTLD_LOCAL);
#endif
  if (!handle) {
    fprintf(stderr, "shell: dlopen failed: %s\n", dlerror());
    return false;
  }
  App_Get_API get_api = (App_Get_API)dlsym(handle, APP_GET_API_SYMBOL);
  App_API *api = get_api ? get_api() : NULL;
  if (!api || api->abi_version != PLATFORM_ABI_VERSION) {
    fprintf(stderr, "shell: app ABI %u, shell ABI %u, not loading\n", api ? api->abi_version : 0, PLATFORM_ABI_VERSION);
    dlclose(handle);
    return false;
  }
  out->handle = handle;
  out->api = *api;
  return true;
}

static void reload_if_changed(void) {
  ino_t inode;
  struct timespec mtime;
  if (!file_identity(g_app_path, &inode, &mtime)) return;
  if (inode == g_app.inode && mtime.tv_sec == g_app.mtime.tv_sec && mtime.tv_nsec == g_app.mtime.tv_nsec) return;
  Loaded_App next = {0};
  if (!open_app(&next)) {
    // Remember the file anyway so a broken build isn't retried until it changes.
    g_app.inode = inode;
    g_app.mtime = mtime;
    return;
  }
  g_app.api.unload(&g_memory);
  // The old image stays open for good: a State the new code can't read is
  // released through a procedure the old code left in it.
  g_app = next;
  g_app.api.reload(&g_memory, &g_shell);
  fprintf(stderr, "shell: reloaded app (%d)\n", g_reload_count - 1);
  request_redraw();
}

#if HOT_RELOAD
// inotify on the build directory sees the rename build.sh uses to put a
// finished library in place.
static void watch_app(void) {
  char dir[PATH_MAX];
  snprintf(dir, sizeof dir, "%s", g_app_path);
  char *slash = strrchr(dir, '/');
  if (slash) *slash = 0;
  g_inotify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (g_inotify_fd >= 0) inotify_add_watch(g_inotify_fd, dir, IN_MOVED_TO | IN_CLOSE_WRITE);
}
#endif

// Now Playing
//
// Not shown anywhere yet; MPRIS over D-Bus is the Linux equivalent.
// TIDALFAST_NOW_PLAYING_LOG=1 prints what the app sets, and
// TIDALFAST_REMOTE_TEST="3:pause,5:play,7:seek=42,9:next" sends media
// commands as the media keys do.

static bool g_now_playing_log;

static void remote_command(uint32_t command, double position) {
  push_event((Event){.kind = EVENT_MEDIA, .media = (uint8_t)command, .dx = (float)position, .time = now_seconds()});
  if (g_now_playing_log) fprintf(stderr, "shell: remote command %u (%.3f)\n", command, position);
  request_redraw();
}

static void set_now_playing(const Now_Playing *np) {
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
// The app tells the shell about the focused text field after each frame
// (set_text_input). The shell keeps a mirror of the field and applies each
// edit it sends on to the app to the mirror as well, as shell.m does, so an
// input method asking about the text between frames gets the right answer.
// text-input-v3 counts in UTF-8 bytes, as the app does.

static struct {
  bool active;
  uint8_t *bytes;
  uint32_t length, capacity;
  uint32_t limit; // the field's, in bytes; 0 for none
  uint32_t sel_start, sel_end;
  int32_t marked_start, marked_end; // -1 without marked text
  float caret[4]; // view points
} g_ti = {.marked_start = -1, .marked_end = -1};

static uint32_t utf8_width(uint8_t c) { return c < 0xc0 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4; }

static uint32_t utf16_of_byte(const uint8_t *s, uint32_t len, uint32_t byte) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < byte && i < len;) {
    uint32_t w = utf8_width(s[i]);
    n += w == 4 ? 2 : 1;
    i += w;
  }
  return n;
}

// byte_of_utf16 never lands between a surrogate pair's halves.
static uint32_t byte_of_utf16(const uint8_t *s, uint32_t len, uint32_t u16) {
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
static void text_insert(const char *utf8, int64_t lo_given, int64_t hi_given) {
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
static void text_set_marked(const char *utf8, uint32_t sel_lo, uint32_t sel_hi, int64_t lo_given, int64_t hi_given) {
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

static void text_unmark(void) {
  if (g_ti.marked_start >= 0) g_ti.sel_start = g_ti.sel_end = (uint32_t)g_ti.marked_end;
  g_ti.marked_start = g_ti.marked_end = -1;
  push_event((Event){.kind = EVENT_UNMARK_TEXT, .time = now_seconds()});
  request_redraw();
}

// text-input-v3. The compositor speaks for an input method; without one it
// never sends anything and keys arrive on the keyboard as usual.

static bool g_ti_entered; // the text input has the window's surface
static bool g_ti_enabled; // enabled with the compositor
static struct {
  char *preedit;
  int32_t preedit_begin, preedit_end;
  char *commit;
  uint32_t delete_before, delete_after;
  bool has_preedit;
} g_ime;

static void ti_enter(void *data, struct zwp_text_input_v3 *ti, struct wl_surface *surface) {
  g_ti_entered = true;
  g_ti_enabled = false;
  set_text_input_state();
}

static void ti_leave(void *data, struct zwp_text_input_v3 *ti, struct wl_surface *surface) {
  g_ti_entered = false;
  if (g_ti_enabled) {
    zwp_text_input_v3_disable(ti);
    zwp_text_input_v3_commit(ti);
  }
  g_ti_enabled = false;
}

static void ti_preedit(void *data, struct zwp_text_input_v3 *ti, const char *text, int32_t begin, int32_t end) {
  free(g_ime.preedit);
  g_ime.preedit = text ? strdup(text) : NULL;
  g_ime.preedit_begin = begin;
  g_ime.preedit_end = end;
  g_ime.has_preedit = true;
}

static void ti_commit(void *data, struct zwp_text_input_v3 *ti, const char *text) {
  free(g_ime.commit);
  g_ime.commit = text ? strdup(text) : NULL;
}

static void ti_delete(void *data, struct zwp_text_input_v3 *ti, uint32_t before, uint32_t after) {
  g_ime.delete_before = before;
  g_ime.delete_after = after;
}

// done applies what came since the last done, in the protocol's order: the
// old composition goes, surrounding text is deleted, the commit string goes
// in, then the new composition.
static void ti_done(void *data, struct zwp_text_input_v3 *ti, uint32_t serial) {
  if (!g_ti.active) goto reset;
  bool had_marked = g_ti.marked_start >= 0;
  if (g_ime.delete_before || g_ime.delete_after) {
    if (had_marked) text_set_marked("", 0, 0, -1, -1);
    had_marked = false;
    int64_t lo = (int64_t)g_ti.sel_start - g_ime.delete_before, hi = (int64_t)g_ti.sel_end + g_ime.delete_after;
    text_insert("", lo < 0 ? 0 : lo, hi);
  }
  if (g_ime.commit) {
    text_insert(g_ime.commit, -1, -1);
    had_marked = false;
  }
  if (g_ime.has_preedit) {
    const char *p = g_ime.preedit ? g_ime.preedit : "";
    if (*p || had_marked) {
      uint32_t lo = g_ime.preedit_begin >= 0 ? (uint32_t)g_ime.preedit_begin : (uint32_t)strlen(p);
      uint32_t hi = g_ime.preedit_end >= 0 ? (uint32_t)g_ime.preedit_end : lo;
      text_set_marked(p, lo, hi, -1, -1);
    }
  } else if (had_marked) {
    text_set_marked("", 0, 0, -1, -1);
  }
reset:
  free(g_ime.preedit);
  free(g_ime.commit);
  g_ime = (__typeof__(g_ime)){0};
}

static const struct zwp_text_input_v3_listener g_ti_listener = {
    .enter = ti_enter,
    .leave = ti_leave,
    .preedit_string = ti_preedit,
    .commit_string = ti_commit,
    .delete_surrounding_text = ti_delete,
    .done = ti_done,
};

// surrounding_text is the field's text for the input method, which must
// leave out the composition: with marked text, the text around it, with
// the cursor and anchor where it was. Bytes; out holds g_ti.length + 1.
static void surrounding_text(char *out, int32_t *cursor, int32_t *anchor) {
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

// set_text_input_state tells the compositor about the field: enabled while
// one has the focus, with its text around the caret and where the caret is.
static void set_text_input_state(void) {
  struct zwp_text_input_v3 *ti = g_text_input;
  if (!ti || !g_ti_entered) return;
  if (!g_ti.active) {
    if (g_ti_enabled) {
      zwp_text_input_v3_disable(ti);
      zwp_text_input_v3_commit(ti);
      g_ti_enabled = false;
    }
    return;
  }
  if (!g_ti_enabled) {
    zwp_text_input_v3_enable(ti);
    zwp_text_input_v3_set_content_type(ti, ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE, ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL);
    g_ti_enabled = true;
  }
  // Surrounding text is limited to 4000 bytes by the protocol's message
  // size; a search field never gets near it.
  if (g_ti.length < 4000) {
    char *s = malloc(g_ti.length + 1);
    int32_t cursor, anchor;
    surrounding_text(s, &cursor, &anchor);
    zwp_text_input_v3_set_surrounding_text(ti, s, cursor, anchor);
    free(s);
  }
  float *c = g_ti.caret;
  zwp_text_input_v3_set_cursor_rectangle(ti, (int32_t)c[0], (int32_t)c[1], (int32_t)(c[2] > 1 ? c[2] : 1), (int32_t)(c[3] > 0 ? c[3] : 16));
  zwp_text_input_v3_commit(ti);
}

static void set_text_input(const Text_Input *ti) {
  if (!ti || !ti->text) {
    bool was = g_ti.active;
    g_ti.active = false;
    g_ti.length = g_ti.sel_start = g_ti.sel_end = 0;
    g_ti.marked_start = g_ti.marked_end = -1;
    if (was) set_text_input_state();
    return;
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
  if (changed) set_text_input_state();
}

// Clipboard
//
// The selection is offered as UTF-8 text. Another client's is read on each
// selection event, through a pipe the main loop polls, and wiped when the
// window loses the keyboard; pastes copy from what arrived. Ours is answered
// from our copy. Transfers both ways run in the main loop and never block it.

#define CLIP_MAX (64 << 10) // the app's CLIPBOARD_MAX
#define CLIP_SENDS 4

typedef struct {
  int fd; // -1 for a free slot
  char *data;
  size_t length, done;
  uint64_t started;
} Clip_Send;

static char *g_clip; // what we offer, or NULL
static size_t g_clip_len;
static struct wl_data_source *g_clip_source;
static char g_own_mime[48]; // marks the offers that carry our own copy
static Clip_Send g_sends[CLIP_SENDS] = {{.fd = -1}, {.fd = -1}, {.fd = -1}, {.fd = -1}};
static uint64_t g_send_count;
static struct wl_data_offer *g_offer; // the current selection
static struct wl_data_offer *g_drag_offer; // a drag over the window, never accepted
static bool g_offer_text;
static bool g_selection_ours;
static int g_receive_fd = -1;
static uint8_t g_paste[CLIP_MAX]; // the selection's text, as far as it has arrived
static size_t g_paste_len;

static bool set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void source_target(void *data, struct wl_data_source *s, const char *mime) {}

static void end_send(Clip_Send *t) {
  if (t->fd < 0) return;
  close(t->fd);
  free(t->data);
  *t = (Clip_Send){.fd = -1};
}

static void end_receive(void) {
  if (g_receive_fd < 0) return;
  close(g_receive_fd);
  g_receive_fd = -1;
}

static void send_more(Clip_Send *t) {
  if (t->fd < 0) return;
  ssize_t n = 0;
  while (t->done < t->length && (n = write(t->fd, t->data + t->done, t->length - t->done)) > 0) t->done += (size_t)n;
  if (t->done < t->length && n < 0 && errno == EAGAIN) return;
  end_send(t);
}

// Each send keeps its own copy, since a new selection frees ours. A free
// slot has started 0, so the oldest send gives way only when all are busy.
static void source_send(void *data, struct wl_data_source *s, const char *mime, int32_t fd) {
  Clip_Send *t = &g_sends[0];
  for (int i = 1; i < CLIP_SENDS; i++)
    if (g_sends[i].started < t->started) t = &g_sends[i];
  end_send(t);
  if (!set_nonblocking(fd) || !(t->data = malloc(g_clip_len + 1))) {
    close(fd);
    return;
  }
  memcpy(t->data, g_clip, g_clip_len);
  t->fd = fd;
  t->length = g_clip_len;
  t->done = 0;
  t->started = ++g_send_count;
  send_more(t);
}

static void source_cancelled(void *data, struct wl_data_source *s) {
  if (s == g_clip_source) {
    g_clip_source = NULL;
    free(g_clip);
    g_clip = NULL;
    g_clip_len = 0;
  }
  wl_data_source_destroy(s);
}

static void source_dnd_drop_performed(void *data, struct wl_data_source *s) {}
static void source_dnd_finished(void *data, struct wl_data_source *s) {}
static void source_action(void *data, struct wl_data_source *s, uint32_t action) {}

static const struct wl_data_source_listener g_source_listener = {
    .target = source_target,
    .send = source_send,
    .cancelled = source_cancelled,
    .dnd_drop_performed = source_dnd_drop_performed,
    .dnd_finished = source_dnd_finished,
    .action = source_action,
};

static void set_clipboard(const uint8_t *text, size_t length) {
  if (!g_data_manager || !g_data_device) return;
  free(g_clip);
  g_clip = malloc(length);
  memcpy(g_clip, text, length);
  g_clip_len = length;
  struct wl_data_source *s = wl_data_device_manager_create_data_source(g_data_manager);
  wl_data_source_add_listener(s, &g_source_listener, NULL);
  wl_data_source_offer(s, "text/plain;charset=utf-8");
  wl_data_source_offer(s, "text/plain");
  wl_data_source_offer(s, "UTF8_STRING");
  wl_data_source_offer(s, g_own_mime);
  wl_data_device_set_selection(g_data_device, s, g_serial);
  g_clip_source = s;
  g_selection_ours = true;
}

static void receive_more(void) {
  if (g_receive_fd < 0) return;
  ssize_t n = 0;
  while (g_paste_len < CLIP_MAX && (n = read(g_receive_fd, g_paste + g_paste_len, CLIP_MAX - g_paste_len)) > 0)
    g_paste_len += (size_t)n;
  if (g_paste_len < CLIP_MAX && n < 0 && errno == EAGAIN) return;
  end_receive();
}

// The shell's copy of the selection may be a password, so it doesn't
// outlive the focus.
static void clear_paste(void) {
  end_receive();
  explicit_bzero(g_paste, g_paste_len);
  g_paste_len = 0;
}

// While our own copy is the selection, get_clipboard reads it directly.
static void receive_selection(void) {
  clear_paste();
  int fds[2];
  if (g_selection_ours || !g_offer || !g_offer_text || pipe2(fds, O_CLOEXEC) != 0) return;
  // The write end goes to the source client, which may expect it to block.
  wl_data_offer_receive(g_offer, "text/plain;charset=utf-8", fds[1]);
  wl_display_flush(g_display);
  close(fds[1]);
  if (!set_nonblocking(fds[0])) {
    close(fds[0]);
    return;
  }
  g_receive_fd = fds[0];
}

// A paste waits up to 100 ms for a selection that is still arriving, then
// pastes nothing rather than part of it. Some compositors don't send the
// selection again when the window gets the keyboard back, so a paste with
// nothing received asks for it itself.
static size_t get_clipboard(uint8_t *buffer, size_t capacity) {
  if (g_receive_fd < 0 && g_paste_len == 0) receive_selection();
  double deadline = now_seconds() + 0.1;
  while (!g_selection_ours && g_receive_fd >= 0) {
    int timeout = (int)ceil((deadline - now_seconds()) * 1000);
    struct pollfd p = {.fd = g_receive_fd, .events = POLLIN};
    if (timeout > 0 && poll(&p, 1, timeout) > 0) {
      receive_more();
    } else {
      clear_paste();
    }
  }
  const uint8_t *text = g_selection_ours ? (const uint8_t *)g_clip : g_paste;
  size_t length = g_selection_ours ? g_clip_len : g_paste_len;
  if (buffer && capacity && length) memcpy(buffer, text, length < capacity ? length : capacity);
  return length;
}

typedef struct {
  bool text, ours;
} Offer_Mimes;

static void offer_offer(void *data, struct wl_data_offer *offer, const char *mime) {
  Offer_Mimes *m = data;
  if (!strcmp(mime, "text/plain;charset=utf-8")) m->text = true;
  if (!strcmp(mime, g_own_mime)) m->ours = true;
}

static void offer_source_actions(void *data, struct wl_data_offer *offer, uint32_t actions) {}
static void offer_action(void *data, struct wl_data_offer *offer, uint32_t action) {}

static const struct wl_data_offer_listener g_offer_listener = {
    .offer = offer_offer,
    .source_actions = offer_source_actions,
    .action = offer_action,
};

static Offer_Mimes g_new_offer;

static void device_data_offer(void *data, struct wl_data_device *d, struct wl_data_offer *offer) {
  g_new_offer = (Offer_Mimes){0};
  wl_data_offer_add_listener(offer, &g_offer_listener, &g_new_offer);
}

static void device_selection(void *data, struct wl_data_device *d, struct wl_data_offer *offer) {
  if (g_offer && g_offer != offer) wl_data_offer_destroy(g_offer);
  g_offer = offer;
  g_offer_text = offer && g_new_offer.text;
  g_selection_ours = offer && g_new_offer.ours;
  receive_selection();
}

static void end_drag(void) {
  if (g_drag_offer) wl_data_offer_destroy(g_drag_offer);
  g_drag_offer = NULL;
}

static void device_enter(void *data, struct wl_data_device *d, uint32_t serial, struct wl_surface *s, wl_fixed_t x,
                         wl_fixed_t y, struct wl_data_offer *offer) {
  end_drag();
  g_drag_offer = offer;
}

static void device_leave(void *data, struct wl_data_device *d) { end_drag(); }
static void device_motion(void *data, struct wl_data_device *d, uint32_t time, wl_fixed_t x, wl_fixed_t y) {}
static void device_drop(void *data, struct wl_data_device *d) { end_drag(); }

static const struct wl_data_device_listener g_device_listener = {
    .data_offer = device_data_offer,
    .enter = device_enter,
    .leave = device_leave,
    .motion = device_motion,
    .drop = device_drop,
    .selection = device_selection,
};

// Accessibility
//
// Not exposed to assistive apps yet (AT-SPI over D-Bus). The shell keeps a
// copy of the tree for the test driver, and offers set_accessibility only
// when it runs.

typedef struct {
  uint64_t id;
  int32_t parent;
  uint32_t role, flags;
  float frame[4];
  char *label, *value; // malloc'd, or NULL
} Shell_Node;

static Shell_Node *g_nodes;
static uint32_t g_node_count, g_node_cap;

static void set_accessibility(const Access_Node *nodes, uint32_t count) {
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

static void access_frame_done(void) {}

static const char *access_role_name(uint32_t role) {
  static const char *names[] = {"none", "group", "button", "text field", "static text", "list", "table", "row", "menu", "menu item", "slider"};
  return role < sizeof names / sizeof names[0] ? names[role] : "?";
}

static bool access_pressable(uint32_t role) {
  return role == ACCESS_BUTTON || role == ACCESS_ROW || role == ACCESS_MENU_ITEM;
}

// Input

static uint32_t g_modifiers;
static double g_mouse_x, g_mouse_y;

// Mouse buttons by evdev code.
#define EVDEV_BTN_LEFT 0x110
#define EVDEV_BTN_RIGHT 0x111
#define EVDEV_BTN_MIDDLE 0x112

// Keys by evdev code, the place on the keyboard. Unlisted codes are KEY_NONE.
static const uint8_t g_keys[128] = {
    [30] = KEY_A, [48] = KEY_B, [46] = KEY_C, [32] = KEY_D, [18] = KEY_E, [33] = KEY_F, [34] = KEY_G,
    [35] = KEY_H, [23] = KEY_I, [36] = KEY_J, [37] = KEY_K, [38] = KEY_L, [50] = KEY_M, [49] = KEY_N,
    [24] = KEY_O, [25] = KEY_P, [16] = KEY_Q, [19] = KEY_R, [31] = KEY_S, [20] = KEY_T, [22] = KEY_U,
    [47] = KEY_V, [17] = KEY_W, [45] = KEY_X, [21] = KEY_Y, [44] = KEY_Z,
    [11] = KEY_DIGIT_0, [2] = KEY_DIGIT_1, [3] = KEY_DIGIT_2, [4] = KEY_DIGIT_3, [5] = KEY_DIGIT_4,
    [6] = KEY_DIGIT_5, [7] = KEY_DIGIT_6, [8] = KEY_DIGIT_7, [9] = KEY_DIGIT_8, [10] = KEY_DIGIT_9,
    [28] = KEY_RETURN, [15] = KEY_TAB, [57] = KEY_SPACE, [14] = KEY_BACKSPACE, [111] = KEY_DELETE,
    [1] = KEY_ESCAPE, [102] = KEY_HOME, [107] = KEY_END, [104] = KEY_PAGE_UP, [109] = KEY_PAGE_DOWN,
    [105] = KEY_LEFT, [106] = KEY_RIGHT, [103] = KEY_UP, [108] = KEY_DOWN, [41] = KEY_GRAVE,
    [96] = KEY_KEYPAD_ENTER,
    [59] = KEY_F1, [60] = KEY_F2, [61] = KEY_F3, [62] = KEY_F4, [63] = KEY_F5, [64] = KEY_F6,
    [65] = KEY_F7, [66] = KEY_F8, [67] = KEY_F9, [68] = KEY_F10, [87] = KEY_F11, [88] = KEY_F12,
};

static struct xkb_context *g_xkb;
static struct xkb_keymap *g_keymap;
static struct xkb_state *g_xkb_state;
static struct xkb_compose_table *g_compose_table;
static struct xkb_compose_state *g_compose;
static int32_t g_repeat_rate = 25, g_repeat_delay = 600;
static uint32_t g_repeat_key; // evdev code + 8, 0 for none

// Pointer

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
  g_mouse_x = wl_fixed_to_double(x);
  g_mouse_y = wl_fixed_to_double(y);
  if (g_cursor_theme) {
    struct wl_cursor *cursor = wl_cursor_theme_get_cursor(g_cursor_theme, "default");
    if (!cursor) cursor = wl_cursor_theme_get_cursor(g_cursor_theme, "left_ptr");
    if (cursor && cursor->image_count > 0) {
      struct wl_cursor_image *image = cursor->images[0];
      struct wl_buffer *buffer = wl_cursor_image_get_buffer(image);
      wl_pointer_set_cursor(p, serial, g_cursor_surface, (int32_t)image->hotspot_x, (int32_t)image->hotspot_y);
      wl_surface_attach(g_cursor_surface, buffer, 0, 0);
      wl_surface_damage(g_cursor_surface, 0, 0, (int32_t)image->width, (int32_t)image->height);
      wl_surface_commit(g_cursor_surface);
    }
  }
  push_event((Event){.kind = EVENT_MOUSE_MOVE, .modifiers = g_modifiers, .time = now_seconds(), .x = (float)g_mouse_x, .y = (float)g_mouse_y});
}

static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) {
  g_buttons = 0;
  push_event((Event){.kind = EVENT_MOUSE_LEAVE, .modifiers = g_modifiers, .time = now_seconds(), .x = (float)g_mouse_x, .y = (float)g_mouse_y});
}

static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
  g_mouse_x = wl_fixed_to_double(x);
  g_mouse_y = wl_fixed_to_double(y);
  push_event((Event){.kind = EVENT_MOUSE_MOVE, .modifiers = g_modifiers, .time = now_seconds(), .x = (float)g_mouse_x, .y = (float)g_mouse_y});
}

// Click counts as macOS makes them: the same button again within the
// double-click time, close to the last press.
static struct {
  double time;
  uint32_t button, count;
  double x, y;
} g_click;

static void pointer_button(void *data, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t code, uint32_t state) {
  g_serial = serial;
  uint32_t button;
  if (code == EVDEV_BTN_LEFT) button = MOUSE_BUTTON_LEFT;
  else if (code == EVDEV_BTN_RIGHT) button = MOUSE_BUTTON_RIGHT;
  else if (code == EVDEV_BTN_MIDDLE) button = MOUSE_BUTTON_MIDDLE;
  else return;
  double now = now_seconds();
  bool down = state == WL_POINTER_BUTTON_STATE_PRESSED;
  if (down) {
    bool again = g_click.button == button && now - g_click.time < 0.5 && fabs(g_mouse_x - g_click.x) < 4 && fabs(g_mouse_y - g_click.y) < 4;
    g_click.count = again ? g_click.count + 1 : 1;
    g_click.time = now;
    g_click.button = button;
    g_click.x = g_mouse_x;
    g_click.y = g_mouse_y;
    g_buttons |= 1u << button;
  } else {
    g_buttons &= ~(1u << button);
  }
  push_event((Event){
      .kind = down ? EVENT_MOUSE_DOWN : EVENT_MOUSE_UP,
      .modifiers = g_modifiers,
      .time = now,
      .x = (float)g_mouse_x,
      .y = (float)g_mouse_y,
      .button = button,
      .click_count = g_click.count,
  });
}

// Scrolls come in pointer frames: axis values, a source and maybe a stop,
// then frame. A finger scroll is precise and carries phases; a wheel counts
// in lines. Wayland's axes point the other way to macOS's deltas.
static struct {
  double dx, dy;
  uint32_t source;
  bool has_source, has_axis, stop;
  int32_t value120_x, value120_y;
  bool fingers; // a finger scroll is under way
} g_axis;

// Momentum after a finger scroll ends, in points per second, decaying.
static struct {
  double vx, vy; // velocity while the fingers move, smoothed
  double last; // time of the last finger frame
  bool running, started;
  double tick;
} g_momentum;

#define MOMENTUM_TAU 0.35 // seconds for the speed to fall to 1/e
#define MOMENTUM_MIN 30.0 // points per second where it stops
#define MOMENTUM_TICK (1.0 / 120)

// libinput sends finger scrolls at about the finger's own speed, where macOS
// accelerates them. Slow drags stay 1:1 for control and fast swipes go up to
// SCROLL_GAIN_MAX times, so one swipe can cross a screen as in Chromium.
#define SCROLL_GAIN_SLOW 100.0 // points per second below which the gain is 1
#define SCROLL_GAIN_RAMP 300.0 // points per second for each extra 1x
#define SCROLL_GAIN_MAX 4.0
// A wheel notch scrolls this many lines, as GTK and Firefox do.
#define WHEEL_LINES 3.0

static double scroll_gain(double distance, double dt) {
  if (dt < 0.004) dt = 0.004; // frames arrive at up to a few hundred Hz
  double gain = 1 + (distance / dt - SCROLL_GAIN_SLOW) / SCROLL_GAIN_RAMP;
  return gain < 1 ? 1 : gain > SCROLL_GAIN_MAX ? SCROLL_GAIN_MAX : gain;
}

static double g_test_scrolled_points, g_test_scrolled_lines; // for the scrolled test step

static void scroll_event(float dx, float dy, bool precise, uint32_t phase, uint32_t momentum) {
  if (precise) g_test_scrolled_points += dy;
  else g_test_scrolled_lines += dy;
  push_event((Event){
      .kind = EVENT_SCROLL,
      .modifiers = g_modifiers,
      .time = now_seconds(),
      .x = (float)g_mouse_x,
      .y = (float)g_mouse_y,
      .dx = dx,
      .dy = dy,
      .precise = precise,
      .phase = phase,
      .momentum_phase = momentum,
  });
}

static void momentum_stop(void) {
  if (!g_momentum.running) return;
  g_momentum.running = false;
  arm_timer(g_momentum_fd, 0, 0);
  if (g_momentum.started) scroll_event(0, 0, true, SCROLL_PHASE_NONE, SCROLL_PHASE_ENDED);
}

static void momentum_tick(void) {
  double now = now_seconds();
  double dt = now - g_momentum.tick;
  g_momentum.tick = now;
  double decay = exp(-dt / MOMENTUM_TAU);
  g_momentum.vx *= decay;
  g_momentum.vy *= decay;
  if (hypot(g_momentum.vx, g_momentum.vy) < MOMENTUM_MIN) {
    momentum_stop();
    return;
  }
  uint32_t phase = g_momentum.started ? SCROLL_PHASE_CHANGED : SCROLL_PHASE_BEGAN;
  g_momentum.started = true;
  scroll_event((float)(g_momentum.vx * dt), (float)(g_momentum.vy * dt), true, SCROLL_PHASE_NONE, phase);
}

static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t value) {
  double v = -wl_fixed_to_double(value);
  if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) g_axis.dy += v;
  else g_axis.dx += v;
  g_axis.has_axis = true;
}

static void pointer_axis_source(void *data, struct wl_pointer *p, uint32_t source) {
  g_axis.source = source;
  g_axis.has_source = true;
}

static void pointer_axis_stop(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis) { g_axis.stop = true; }

static void pointer_axis_discrete(void *data, struct wl_pointer *p, uint32_t axis, int32_t discrete) {}

static void pointer_axis_value120(void *data, struct wl_pointer *p, uint32_t axis, int32_t value120) {
  if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) g_axis.value120_y -= value120;
  else g_axis.value120_x -= value120;
}

static void pointer_axis_relative_direction(void *data, struct wl_pointer *p, uint32_t axis, uint32_t direction) {}

static void pointer_frame(void *data, struct wl_pointer *p) {
  bool fingers = g_axis.has_source ? g_axis.source == WL_POINTER_AXIS_SOURCE_FINGER || g_axis.source == WL_POINTER_AXIS_SOURCE_CONTINUOUS
                                   : g_axis.fingers;
  if (g_axis.has_axis || g_axis.stop) {
    double now = now_seconds();
    if (fingers && (g_axis.has_axis || g_axis.fingers)) {
      momentum_stop();
      if (g_axis.has_axis) {
        uint32_t phase = g_axis.fingers ? SCROLL_PHASE_CHANGED : SCROLL_PHASE_BEGAN;
        double dt = now - g_momentum.last;
        if (!g_axis.fingers || dt > 0.1) g_momentum.vx = g_momentum.vy = 0;
        double gain = scroll_gain(hypot(g_axis.dx, g_axis.dy), g_axis.fingers ? dt : 0.016);
        g_axis.dx *= gain;
        g_axis.dy *= gain;
        if (dt > 0.001) {
          double k = dt / (dt + 0.03);
          g_momentum.vx += (g_axis.dx / dt - g_momentum.vx) * k;
          g_momentum.vy += (g_axis.dy / dt - g_momentum.vy) * k;
        }
        g_momentum.last = now;
        g_axis.fingers = true;
        scroll_event((float)g_axis.dx, (float)g_axis.dy, true, phase, SCROLL_PHASE_NONE);
      }
      if (g_axis.stop && g_axis.fingers) {
        g_axis.fingers = false;
        scroll_event(0, 0, true, SCROLL_PHASE_ENDED, SCROLL_PHASE_NONE);
        // Fingers that stopped moving before they lifted leave no momentum.
        if (now - g_momentum.last < 0.05 && hypot(g_momentum.vx, g_momentum.vy) > MOMENTUM_MIN * 4) {
          g_momentum.running = true;
          g_momentum.started = false;
          g_momentum.tick = now;
          arm_timer(g_momentum_fd, MOMENTUM_TICK, MOMENTUM_TICK);
        }
      }
    } else if (g_axis.has_axis) {
      momentum_stop();
      // A wheel: lines, from value120 where the compositor sends it.
      double lx = (g_axis.value120_x ? g_axis.value120_x / 120.0 : g_axis.dx / 10) * WHEEL_LINES;
      double ly = (g_axis.value120_y ? g_axis.value120_y / 120.0 : g_axis.dy / 10) * WHEEL_LINES;
      scroll_event((float)lx, (float)ly, false, SCROLL_PHASE_NONE, SCROLL_PHASE_NONE);
    }
  }
  bool keep = g_axis.fingers;
  g_axis = (__typeof__(g_axis)){0};
  g_axis.fingers = keep;
}

static const struct wl_pointer_listener g_pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
    .axis_value120 = pointer_axis_value120,
    .axis_relative_direction = pointer_axis_relative_direction,
};

// Keyboard

static uint32_t xkb_modifiers(void) {
  uint32_t m = 0;
  if (!g_xkb_state) return 0;
  if (xkb_state_mod_name_is_active(g_xkb_state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MODIFIER_SHIFT;
  if (xkb_state_mod_name_is_active(g_xkb_state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MODIFIER_CONTROL;
  if (xkb_state_mod_name_is_active(g_xkb_state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MODIFIER_ALT;
  if (xkb_state_mod_name_is_active(g_xkb_state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MODIFIER_SUPER;
  if (xkb_state_mod_name_is_active(g_xkb_state, XKB_MOD_NAME_CAPS, XKB_STATE_MODS_LOCKED) > 0) m |= MODIFIER_CAPS_LOCK;
  return m;
}

static void keyboard_keymap(void *data, struct wl_keyboard *k, uint32_t format, int32_t fd, uint32_t size) {
  if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
    close(fd);
    return;
  }
  char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) return;
  struct xkb_keymap *keymap = xkb_keymap_new_from_string(g_xkb, map, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
  munmap(map, size);
  if (!keymap) return;
  xkb_state_unref(g_xkb_state);
  xkb_keymap_unref(g_keymap);
  g_keymap = keymap;
  g_xkb_state = xkb_state_new(keymap);
}

static void keyboard_enter(void *data, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s, struct wl_array *keys) {
  g_serial = serial;
  g_key_window = true;
  request_redraw();
}

static void stop_repeat(void) {
  g_repeat_key = 0;
  arm_timer(g_repeat_fd, 0, 0);
}

static void keyboard_leave(void *data, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s) {
  g_key_window = false;
  stop_repeat();
  clear_paste();
  request_redraw();
}

// key_text is what a key types, through any compose sequence; empty while a
// sequence is under way or for a key that types nothing.
static void key_text(uint32_t keycode, char *out, size_t cap) {
  out[0] = 0;
  xkb_keysym_t sym = xkb_state_key_get_one_sym(g_xkb_state, keycode);
  if (g_compose && xkb_compose_state_feed(g_compose, sym) == XKB_COMPOSE_FEED_ACCEPTED) {
    switch (xkb_compose_state_get_status(g_compose)) {
    case XKB_COMPOSE_COMPOSING: return;
    case XKB_COMPOSE_COMPOSED:
      xkb_compose_state_get_utf8(g_compose, out, cap);
      xkb_compose_state_reset(g_compose);
      return;
    case XKB_COMPOSE_CANCELLED: xkb_compose_state_reset(g_compose); return;
    case XKB_COMPOSE_NOTHING: break;
    }
  }
  xkb_state_key_get_utf8(g_xkb_state, keycode, out, cap);
}

static bool media_key(xkb_keysym_t sym) {
  switch (sym) {
  case XKB_KEY_XF86AudioPlay: remote_command(MEDIA_TOGGLE, 0); return true;
  case XKB_KEY_XF86AudioPause: remote_command(MEDIA_PAUSE, 0); return true;
  case XKB_KEY_XF86AudioNext: remote_command(MEDIA_NEXT, 0); return true;
  case XKB_KEY_XF86AudioPrev: remote_command(MEDIA_PREVIOUS, 0); return true;
  }
  return false;
}

// While a text field has the focus, a key that types something with no
// Control, Alt or Super held reaches the app as text only; other keys
// (arrows, Backspace, Return, shortcuts) reach it as key events.
static void key_press(uint32_t keycode, bool repeat) {
  uint32_t code = keycode - 8;
  if (!repeat && media_key(xkb_state_key_get_one_sym(g_xkb_state, keycode))) return;
  if (g_ti.active && !(g_modifiers & (MODIFIER_CONTROL | MODIFIER_ALT | MODIFIER_SUPER))) {
    char text[64];
    key_text(keycode, text, sizeof text);
    if (g_compose && xkb_compose_state_get_status(g_compose) == XKB_COMPOSE_COMPOSING) return;
    if ((uint8_t)text[0] >= 0x20 && text[0] != 0x7f) {
      text_insert(text, -1, -1);
      return;
    }
  }
  push_event((Event){
      .kind = EVENT_KEY_DOWN,
      .modifiers = g_modifiers,
      .time = now_seconds(),
      .key = code < 128 ? g_keys[code] : KEY_NONE,
      .repeat = repeat,
  });
}

static void keyboard_key(void *data, struct wl_keyboard *k, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
  g_serial = serial;
  if (!g_xkb_state) return;
  uint32_t keycode = key + 8;
  if (state == WL_KEYBOARD_KEY_STATE_PRESSED) {
    key_press(keycode, false);
    if (xkb_keymap_key_repeats(g_keymap, keycode) && g_repeat_rate > 0) {
      g_repeat_key = keycode;
      arm_timer(g_repeat_fd, g_repeat_delay / 1000.0, 1.0 / g_repeat_rate);
    }
  } else {
    if (g_repeat_key == keycode) stop_repeat();
    push_event((Event){
        .kind = EVENT_KEY_UP,
        .modifiers = g_modifiers,
        .time = now_seconds(),
        .key = key < 128 ? g_keys[key] : KEY_NONE,
    });
  }
}

static void keyboard_modifiers(void *data, struct wl_keyboard *k, uint32_t serial, uint32_t depressed, uint32_t latched,
                               uint32_t locked, uint32_t group) {
  if (!g_xkb_state) return;
  xkb_state_update_mask(g_xkb_state, depressed, latched, locked, 0, 0, group);
  uint32_t m = xkb_modifiers();
  if (m != g_modifiers) {
    g_modifiers = m;
    push_event((Event){.kind = EVENT_MODIFIERS_CHANGED, .modifiers = m, .time = now_seconds()});
  }
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *k, int32_t rate, int32_t delay) {
  g_repeat_rate = rate;
  g_repeat_delay = delay;
  stop_repeat();
}

static const struct wl_keyboard_listener g_keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
  if ((caps & WL_SEAT_CAPABILITY_POINTER) && !g_pointer) {
    g_pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(g_pointer, &g_pointer_listener, NULL);
  } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && g_pointer) {
    wl_pointer_release(g_pointer);
    g_pointer = NULL;
  }
  if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !g_keyboard) {
    g_keyboard = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(g_keyboard, &g_keyboard_listener, NULL);
  } else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && g_keyboard) {
    wl_keyboard_release(g_keyboard);
    g_keyboard = NULL;
    keyboard_leave(NULL, NULL, 0, NULL);
  }
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {}

static const struct wl_seat_listener g_seat_listener = {.capabilities = seat_capabilities, .name = seat_name};

// Window

static void wm_ping(void *data, struct xdg_wm_base *base, uint32_t serial) { xdg_wm_base_pong(base, serial); }
static const struct xdg_wm_base_listener g_wm_listener = {.ping = wm_ping};

static float g_pending_width, g_pending_height;

static void xdg_surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
  xdg_surface_ack_configure(s, serial);
  bool first = !g_configured;
  g_configured = true;
  if (g_pending_width > 0 && g_pending_height > 0 && (g_pending_width != g_width || g_pending_height != g_height || first)) {
    g_width = g_pending_width;
    g_height = g_pending_height;
  }
  push_event((Event){.kind = EVENT_RESIZE, .x = g_width, .y = g_height});
  g_configure_unanswered = true;
}

static const struct xdg_surface_listener g_xdg_surface_listener = {.configure = xdg_surface_configure};

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t width, int32_t height, struct wl_array *states) {
  g_pending_width = width > 0 ? (float)width : g_width;
  g_pending_height = height > 0 ? (float)height : g_height;
}

static void toplevel_close(void *data, struct xdg_toplevel *t) { g_quit = true; }
static void toplevel_bounds(void *data, struct xdg_toplevel *t, int32_t width, int32_t height) {}
static void toplevel_capabilities(void *data, struct xdg_toplevel *t, struct wl_array *caps) {}

static const struct xdg_toplevel_listener g_toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_bounds,
    .wm_capabilities = toplevel_capabilities,
};

static void surface_enter(void *data, struct wl_surface *s, struct wl_output *o) {}
static void surface_leave(void *data, struct wl_surface *s, struct wl_output *o) {}

static void surface_preferred_scale(void *data, struct wl_surface *s, int32_t factor) {
  if (factor > 0 && factor != g_buffer_scale) {
    g_buffer_scale = factor;
    push_event((Event){.kind = EVENT_RESIZE, .x = g_width, .y = g_height});
    request_redraw();
  }
}

static void surface_preferred_transform(void *data, struct wl_surface *s, uint32_t transform) {}

static const struct wl_surface_listener g_surface_listener = {
    .enter = surface_enter,
    .leave = surface_leave,
    .preferred_buffer_scale = surface_preferred_scale,
    .preferred_buffer_transform = surface_preferred_transform,
};

static void fractional_preferred(void *data, struct wp_fractional_scale_v1 *f, uint32_t scale) {
  if (scale != g_fraction) {
    g_fraction = scale;
    push_event((Event){.kind = EVENT_RESIZE, .x = g_width, .y = g_height});
    request_redraw();
  }
}

static const struct wp_fractional_scale_v1_listener g_fractional_listener = {.preferred_scale = fractional_preferred};

static void registry_global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
#define MIN(a, b) ((a) < (b) ? (a) : (b))
  if (!strcmp(interface, wl_compositor_interface.name)) {
    g_compositor_version = MIN(version, 6);
    g_compositor = wl_registry_bind(r, name, &wl_compositor_interface, g_compositor_version);
  } else if (!strcmp(interface, wl_shm_interface.name)) {
    g_shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
  } else if (!strcmp(interface, wl_seat_interface.name) && !g_seat) {
    g_seat = wl_registry_bind(r, name, &wl_seat_interface, MIN(version, 9));
    wl_seat_add_listener(g_seat, &g_seat_listener, NULL);
  } else if (!strcmp(interface, wl_data_device_manager_interface.name)) {
    g_data_manager = wl_registry_bind(r, name, &wl_data_device_manager_interface, MIN(version, 3));
  } else if (!strcmp(interface, xdg_wm_base_interface.name)) {
    g_wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, MIN(version, 6));
    xdg_wm_base_add_listener(g_wm_base, &g_wm_listener, NULL);
  } else if (!strcmp(interface, zxdg_decoration_manager_v1_interface.name)) {
    g_decoration_manager = wl_registry_bind(r, name, &zxdg_decoration_manager_v1_interface, 1);
  } else if (!strcmp(interface, wp_viewporter_interface.name)) {
    g_viewporter = wl_registry_bind(r, name, &wp_viewporter_interface, 1);
  } else if (!strcmp(interface, wp_fractional_scale_manager_v1_interface.name)) {
    g_fractional_manager = wl_registry_bind(r, name, &wp_fractional_scale_manager_v1_interface, 1);
  } else if (!strcmp(interface, zwp_text_input_manager_v3_interface.name)) {
    g_text_input_manager = wl_registry_bind(r, name, &zwp_text_input_manager_v3_interface, 1);
  }
#undef MIN
}

static void registry_remove(void *data, struct wl_registry *r, uint32_t name) {}

static const struct wl_registry_listener g_registry_listener = {.global = registry_global, .global_remove = registry_remove};

// TIDALFAST_SHELL_TEST runs steps against the shell's own entry points, for
// checking text input and accessibility without a person at the keyboard:
// "2:key=ctrl+f;3:mark=にほんご;4:commit=日本語;6:ax-dump;7:ax-press=Next".
// Steps are seconds after launch and a command, separated by semicolons.
// Commands joined with | run together, with no frame between them. The
// same steps as on macOS (see shell.m), with ranges in UTF-16 units there
// too; ax-dump prints the tree as the app sent it, and ax-press sends the
// app the press an assistive app would.
//
//   key=ctrl+shift+z    a key down and up (letters, digits, escape, return, tab, left...)
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
//   size=w,h            make the window w by h points, as a floating window may
//   wheel=n             n wheel notches down, negative for up
//   finger=dy           one touchpad frame moving content up by dy, as libinput sends it
//   lift                the fingers leave the touchpad
//   scrolled            print the scroll the app was sent: points from touchpads, lines from wheels
//   quit

typedef struct {
  double at;
  char *text; // the step after the colon, commands separated by |
} Test_Step;

static Test_Step *g_test_steps;
static int g_test_count, g_test_next;

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

static void test_step(const char *command, char *arg) {
  int64_t lo, hi;
  if (!strcmp(command, "key")) {
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
  } else if (!strcmp(command, "size")) {
    char *comma = strchr(arg, ',');
    float w = (float)atof(arg), h = comma ? (float)atof(comma + 1) : 0;
    if (w < 1 || h < 1) {
      fprintf(stderr, "shell: test: size wants w,h\n");
      return;
    }
    g_width = w;
    g_height = h;
    push_event((Event){.kind = EVENT_RESIZE, .x = g_width, .y = g_height});
    request_redraw();
  } else if (!strcmp(command, "wheel")) {
    int n = atoi(arg);
    pointer_axis_source(NULL, NULL, WL_POINTER_AXIS_SOURCE_WHEEL);
    pointer_axis_value120(NULL, NULL, WL_POINTER_AXIS_VERTICAL_SCROLL, 120 * n);
    pointer_axis(NULL, NULL, 0, WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(15.0 * n));
    pointer_frame(NULL, NULL);
  } else if (!strcmp(command, "finger")) {
    pointer_axis_source(NULL, NULL, WL_POINTER_AXIS_SOURCE_FINGER);
    pointer_axis(NULL, NULL, 0, WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(atof(arg)));
    pointer_frame(NULL, NULL);
  } else if (!strcmp(command, "lift")) {
    pointer_axis_source(NULL, NULL, WL_POINTER_AXIS_SOURCE_FINGER);
    pointer_axis_stop(NULL, NULL, 0, WL_POINTER_AXIS_VERTICAL_SCROLL);
    pointer_frame(NULL, NULL);
  } else if (!strcmp(command, "scrolled")) {
    fprintf(stderr, "shell: test: scrolled %.1f points, %.1f lines\n", g_test_scrolled_points, g_test_scrolled_lines);
  } else if (!strcmp(command, "quit")) {
    g_quit = true;
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
    double after = next - (now_seconds() - g_start_time);
    arm_timer(g_test_fd, after > 0 ? after : 1e-6, 0);
  }
}

static void run_due_steps(void) {
  double now = now_seconds() - g_start_time;
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

static void setup_shell_test(void) {
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
  g_now_playing_log = getenv("TIDALFAST_NOW_PLAYING_LOG") != NULL;
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

// App

static void *reserve(size_t size) {
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) {
    fprintf(stderr, "shell: mmap of %zu bytes failed\n", size);
    exit(1);
  }
  return p;
}

static int new_timer(void) { return timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC); }

static bool connect_wayland(void) {
  g_display = wl_display_connect(NULL);
  if (!g_display) {
    fprintf(stderr, "shell: can't connect to a Wayland compositor (is WAYLAND_DISPLAY set?)\n");
    return false;
  }
  g_registry = wl_display_get_registry(g_display);
  wl_registry_add_listener(g_registry, &g_registry_listener, NULL);
  wl_display_roundtrip(g_display);
  if (!g_compositor || !g_wm_base) {
    fprintf(stderr, "shell: the compositor has no xdg-shell\n");
    return false;
  }
  g_xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  const char *locale = getenv("LC_ALL");
  if (!locale || !*locale) locale = getenv("LC_CTYPE");
  if (!locale || !*locale) locale = getenv("LANG");
  if (!locale || !*locale) locale = "C";
  g_compose_table = xkb_compose_table_new_from_locale(g_xkb, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
  if (g_compose_table) g_compose = xkb_compose_state_new(g_compose_table, XKB_COMPOSE_STATE_NO_FLAGS);
  if (g_seat && g_data_manager) {
    g_data_device = wl_data_device_manager_get_data_device(g_data_manager, g_seat);
    wl_data_device_add_listener(g_data_device, &g_device_listener, NULL);
  }
  if (g_seat && g_text_input_manager) {
    g_text_input = zwp_text_input_manager_v3_get_text_input(g_text_input_manager, g_seat);
    zwp_text_input_v3_add_listener(g_text_input, &g_ti_listener, NULL);
  }
  if (g_shm) {
    const char *size = getenv("XCURSOR_SIZE");
    g_cursor_theme = wl_cursor_theme_load(getenv("XCURSOR_THEME"), size && atoi(size) > 0 ? atoi(size) : 24, g_shm);
    g_cursor_surface = wl_compositor_create_surface(g_compositor);
  }

  g_surface = wl_compositor_create_surface(g_compositor);
  if (g_compositor_version >= 6) wl_surface_add_listener(g_surface, &g_surface_listener, NULL);
  if (g_viewporter && g_fractional_manager) {
    g_viewport = wp_viewporter_get_viewport(g_viewporter, g_surface);
    g_fractional = wp_fractional_scale_manager_v1_get_fractional_scale(g_fractional_manager, g_surface);
    wp_fractional_scale_v1_add_listener(g_fractional, &g_fractional_listener, NULL);
  }
  g_xdg_surface = xdg_wm_base_get_xdg_surface(g_wm_base, g_surface);
  xdg_surface_add_listener(g_xdg_surface, &g_xdg_surface_listener, NULL);
  g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
  xdg_toplevel_add_listener(g_toplevel, &g_toplevel_listener, NULL);
  xdg_toplevel_set_title(g_toplevel, "TIDALfast");
  xdg_toplevel_set_app_id(g_toplevel, "tidalfast");
  xdg_toplevel_set_min_size(g_toplevel, 480, 360);
  // The compositor's title bar where it has one (KDE, wlroots); GNOME's
  // mutter draws none, and the window is moved with Super-drag there.
  if (g_decoration_manager) {
    struct zxdg_toplevel_decoration_v1 *d = zxdg_decoration_manager_v1_get_toplevel_decoration(g_decoration_manager, g_toplevel);
    zxdg_toplevel_decoration_v1_set_mode(d, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
  }
  wl_surface_commit(g_surface);
  g_surface_info = (Wayland_Surface){.display = g_display, .surface = g_surface};
  return true;
}

static void main_loop(void) {
  enum { FD_WAYLAND, FD_REDRAW, FD_WAKE, FD_REPEAT, FD_MOMENTUM, FD_TEST, FD_SIGNAL, FD_INOTIFY, FD_RECEIVE, FD_SEND, FD_COUNT = FD_SEND + CLIP_SENDS };
  struct pollfd fds[FD_COUNT];
  int wl_fd = wl_display_get_fd(g_display);
  while (!g_quit) {
    while (wl_display_prepare_read(g_display) != 0)
      if (wl_display_dispatch_pending(g_display) < 0) goto lost;
    bool unflushed = false;
    if (wl_display_flush(g_display) < 0) {
      if (errno != EAGAIN) {
        wl_display_cancel_read(g_display);
        goto lost;
      }
      unflushed = true;
    }
    int timeout = -1;
    if (atomic_load(&g_needs_redraw) && g_configured) {
      double deadline = frame_deadline();
      timeout = deadline == 0 ? 0 : (int)ceil((deadline - now_seconds()) * 1000);
      if (timeout < 0) timeout = 0;
    }
    int fd_list[FD_SEND] = {wl_fd, g_redraw_fd, g_wake_fd, g_repeat_fd, g_momentum_fd, g_test_fd, g_signal_fd, g_inotify_fd, g_receive_fd};
    for (int i = 0; i < FD_SEND; i++) fds[i] = (struct pollfd){.fd = fd_list[i], .events = POLLIN};
    for (int i = 0; i < CLIP_SENDS; i++) fds[FD_SEND + i] = (struct pollfd){.fd = g_sends[i].fd, .events = POLLOUT};
    if (unflushed) fds[FD_WAYLAND].events |= POLLOUT;
    int n = poll(fds, FD_COUNT, timeout);
    if (n > 0 && (fds[FD_WAYLAND].revents & POLLIN)) {
      if (wl_display_read_events(g_display) < 0) goto lost;
    } else {
      wl_display_cancel_read(g_display);
    }
    if (fds[FD_WAYLAND].revents & (POLLERR | POLLHUP)) goto lost;
    if (wl_display_dispatch_pending(g_display) < 0) goto lost;
    if (fds[FD_REDRAW].revents & POLLIN) drain(g_redraw_fd);
    if (fds[FD_WAKE].revents & POLLIN) {
      drain(g_wake_fd);
      atomic_store(&g_needs_redraw, true);
    }
    if (fds[FD_REPEAT].revents & POLLIN) {
      drain(g_repeat_fd);
      if (g_repeat_key && g_xkb_state) key_press(g_repeat_key, true);
    }
    if (fds[FD_MOMENTUM].revents & POLLIN) {
      drain(g_momentum_fd);
      if (g_momentum.running) momentum_tick();
    }
    if (fds[FD_TEST].revents & POLLIN) {
      drain(g_test_fd);
      run_due_steps();
    }
    if (fds[FD_SIGNAL].revents & POLLIN) {
      struct signalfd_siginfo info;
      if (read(g_signal_fd, &info, sizeof info) > 0) g_quit = true;
    }
    if (g_inotify_fd >= 0 && (fds[FD_INOTIFY].revents & POLLIN)) {
      char buf[4096];
      while (read(g_inotify_fd, buf, sizeof buf) > 0) {
      }
      reload_if_changed();
    }
    if (fds[FD_RECEIVE].revents) receive_more();
    for (int i = 0; i < CLIP_SENDS; i++)
      if (fds[FD_SEND + i].revents) send_more(&g_sends[i]);
    // A burst of events becomes one frame. A redraw waits for the pending
    // frame callback, or its deadline.
    if (atomic_load(&g_needs_redraw) && g_configured && frame_deadline() == 0) draw_frame();
  }
  return;
lost:
  fprintf(stderr, "shell: lost the Wayland connection\n");
}

int main(int argc, char **argv) {
  measure_init();
  measure_mark("main");
  g_start_time = now_seconds();

  char exe[PATH_MAX - 16];
  ssize_t len = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (len <= 0) {
    fprintf(stderr, "shell: can't find the executable's folder\n");
    return 1;
  }
  exe[len] = 0;
  char *slash = strrchr(exe, '/');
  if (slash) *slash = 0;
  snprintf(g_app_path, sizeof g_app_path, "%s/app.so", exe);

  // mmap memory starts zeroed and is only backed by pages as they are touched.
  g_memory = (Memory){
      .persistent = reserve(PERSISTENT_SIZE),
      .persistent_size = PERSISTENT_SIZE,
      .frame = reserve(FRAME_SIZE),
      .frame_size = FRAME_SIZE,
  };

  // Quit cleanly on SIGTERM, SIGINT (Ctrl-C) and SIGHUP (the terminal
  // closing), so they still run the app's shutdown.
  sigset_t quit_signals;
  sigemptyset(&quit_signals);
  sigaddset(&quit_signals, SIGTERM);
  sigaddset(&quit_signals, SIGINT);
  sigaddset(&quit_signals, SIGHUP);
  sigprocmask(SIG_BLOCK, &quit_signals, NULL);
  g_signal_fd = signalfd(-1, &quit_signals, SFD_NONBLOCK | SFD_CLOEXEC);
  // A clipboard reader that closes its end early mustn't kill the app.
  signal(SIGPIPE, SIG_IGN);
  snprintf(g_own_mime, sizeof g_own_mime, "application/x-tidalfast-%d", getpid());

  g_redraw_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  g_wake_fd = new_timer();
  g_repeat_fd = new_timer();
  g_momentum_fd = new_timer();
  g_test_fd = new_timer();

  if (!connect_wayland()) return 1;
  measure_mark("launched");

  g_shell = (Shell){
      .surface = &g_surface_info,
      .request_redraw = request_redraw,
      .set_now_playing = set_now_playing,
      .set_text_input = set_text_input,
      .set_clipboard = set_clipboard,
      .get_clipboard = get_clipboard,
      .set_accessibility = getenv("TIDALFAST_SHELL_TEST") ? set_accessibility : NULL,
  };

  if (!open_app(&g_app)) return 1;
  measure_mark("dylib");
  g_app.api.init(&g_memory, &g_shell);
#if HOT_RELOAD
  watch_app();
#endif
  while (!g_configured && wl_display_dispatch(g_display) >= 0) {
  }
  draw_frame();
  measure_mark("window");
  setup_shell_test();
  request_redraw();
  main_loop();
  if (g_app.api.shutdown) g_app.api.shutdown(&g_memory);
  wl_display_disconnect(g_display);
  return 0;
}
