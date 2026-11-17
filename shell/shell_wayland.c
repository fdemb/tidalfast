// The platform side of the Linux executable. Owns the Wayland connection,
// the window and its surface, collects input into the event queue
// (common.c), and drives the app through the entry points in platform.h, as
// shell_cocoa.m and shell_win32.c do on macOS and Windows. src/app's main
// calls shell_main. The renderer makes its own Vulkan surface from the
// Wayland_Surface it gets.
//
// It redraws only when something asks for it: input, a resize or
// request_redraw from any thread. While the app reports it is animating, a
// frame callback adds a frame each time the compositor wants one, and other
// redraws wait for it; a hidden window gets no callbacks and stops drawing.
// A frame can also ask to be woken after a delay, which a timerfd does.
// Everything waits in one poll: the Wayland socket, an eventfd for
// request_redraw and timerfds.
//
// Text input goes through text-input-unstable-v3 when the compositor runs
// an input method, and otherwise from the keyboard through xkbcommon, with
// compose sequences for dead keys. Trackpad scrolls carry phases, and the
// shell adds momentum after the fingers lift, since Wayland leaves that to
// the client; scroll.c has the model, which follows GTK's. Now Playing and
// media commands from the desktop go through MPRIS on the session bus
// (mpris.c), whose socket is polled with the rest, and the media keys also
// reach the app while the window has the keyboard. Not here yet:
// accessibility (AT-SPI). The shell takes the app's tree only for the test
// driver's ax-dump and ax-press.

#define _GNU_SOURCE
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
#include <sys/mman.h>
#include <sys/random.h>
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
#include "pointer-gestures-unstable-v1-client-protocol.h"
#include "text-input-unstable-v3-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include "common.h"
#include "mpris.h"
#include "scroll.h"

#define PERSISTENT_SIZE (256ull << 20)
#define FRAME_SIZE (64ull << 20)
#define DEFAULT_WIDTH 1100
#define DEFAULT_HEIGHT 700
#define MIN_WIDTH 480
#define MIN_HEIGHT 360

static bool g_app_started; // app_init has run, so frames can be drawn
static Memory g_memory;
static Shell g_shell;
static Wayland_Surface g_surface_info;
static bool g_animating;
static bool g_in_frame; // inside app_frame

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
static struct wl_subcompositor *g_subcompositor;
static struct wp_viewporter *g_viewporter;
static struct wp_fractional_scale_manager_v1 *g_fractional_manager;
static struct zwp_text_input_manager_v3 *g_text_input_manager;
static struct zwp_pointer_gestures_v1 *g_gestures;
static struct zwp_pointer_gesture_hold_v1 *g_hold;
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
static uint32_t g_states; // 1 << xdg_toplevel_state for each the last configure had
static uint32_t g_wm_caps = ~0u; // 1 << xdg_toplevel_wm_capabilities for each the window manager has
static uint32_t g_serial; // of the last input event, for the clipboard
static struct wl_callback *g_frame_callback;
static double g_frame_requested;
// The display's refresh interval, from frame callbacks asked for in the
// callback before, which span one refresh. 0 until one has.
static double g_frame_interval;
static bool g_in_frame_done; // draw_frame is running from a frame callback
static bool g_frame_chained; // the pending callback was asked for in one

static int g_redraw_fd = -1; // eventfd
static int g_wake_fd = -1; // timerfd for wake_after
static int g_repeat_fd = -1; // timerfd for key repeat
static int g_test_fd = -1; // timerfd for the next test step
static int g_signal_fd = -1;

double now_seconds(void) {
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

void request_redraw(void) {
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

// Finger scrolls and the momentum after them, as GTK does them (scroll.c).
// The momentum is drawn from the frame's time, so each frame moves by as
// much as its own interval.
static Scroll_Kinetic g_kinetic;
static void glide_frame(double now);

static void frame_done(void *data, struct wl_callback *callback, uint32_t time);
static const struct wl_callback_listener g_frame_listener = {.done = frame_done};

static void update_border(void);
static uint32_t window_flags(void);
#define TITLEBAR_HEIGHT 46 // a GNOME header bar's, for the room the app keeps at the top when it draws the window's buttons

static void apply_scale(void) {
  if (g_fraction && g_viewport) {
    g_scale = g_fraction / 120.0f;
    wp_viewport_set_destination(g_viewport, (int32_t)g_width, (int32_t)g_height);
  } else {
    g_scale = (float)g_buffer_scale;
    wl_surface_set_buffer_scale(g_surface, g_buffer_scale);
  }
}

// A frame that asks for another from inside app_frame gets the next one;
// the app is never re-entered.
static void draw_frame(void) {
  if (!g_app_started || !g_configured || g_in_frame) return;
  atomic_store(&g_needs_redraw, false);
  g_configure_unanswered = false;
  // The callback goes with the commit the renderer's present makes.
  if (!g_frame_callback) {
    g_frame_callback = wl_surface_frame(g_surface);
    wl_callback_add_listener(g_frame_callback, &g_frame_listener, NULL);
    g_frame_requested = now_seconds();
    g_frame_chained = g_in_frame_done;
  }
  apply_scale();
  glide_frame(now_seconds());
  Frame_Input input = {
      .width = g_width,
      .height = g_height,
      .scale = g_scale,
      .time = now_seconds() - g_start_time,
      .key_window = g_key_window,
      .mouse_buttons = g_buttons,
      .frame_interval = (float)g_frame_interval,
      .window = window_flags(),
  };
  if (input.window & WINDOW_FLAG_BUTTONS) input.titlebar_height = TITLEBAR_HEIGHT;
  update_border();
  queue_take(&input.events, &input.event_count, &input.text, &input.text_length);
  g_in_frame = true;
  Frame_Result result = app_frame(&g_memory, &g_shell, &input);
  g_in_frame = false;
  g_animating = result.animating || g_kinetic.running;
  arm_timer(g_wake_fd, result.wake_after > 0 ? result.wake_after : 0, 0);
  wl_display_flush(g_display);
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
  wl_callback_destroy(callback);
  g_frame_callback = NULL;
  double now = now_seconds();
  double interval = now - g_frame_requested;
  if (g_frame_chained && interval > 0.002 && interval < 0.1)
    g_frame_interval = g_frame_interval > 0 ? g_frame_interval * 0.9 + interval * 0.1 : interval;
  if (g_animating || atomic_load(&g_needs_redraw)) {
    g_in_frame_done = true;
    draw_frame();
    g_in_frame_done = false;
  }
}

// When a frame callback is pending, the deadline by which it should have
// come; 0 when a redraw shouldn't wait for one. Input waits for it too:
// Wayland doesn't merge pointer motion, and with MAILBOX a fast mouse
// would otherwise draw a frame per event. A configure doesn't wait, so the
// compositor gets a frame at the new size soon after it.
static double frame_deadline(void) {
  if (!g_frame_callback || g_configure_unanswered) return 0;
  double deadline = g_frame_requested + 2 * (g_frame_interval > 0 ? g_frame_interval : 1.0 / 60);
  return now_seconds() < deadline ? deadline : 0;
}

// Text input
//
// Through text-input-v3. The compositor speaks for an input method; without
// one it never sends anything and keys arrive on the keyboard as usual.

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
  if (mirror_set(ti)) set_text_input_state();
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
static char g_own_mime[64]; // marks the offers that carry our own copy
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
  if (g_clip_len) memcpy(t->data, g_clip, g_clip_len);
  t->fd = fd;
  t->length = g_clip_len;
  t->done = 0;
  t->started = ++g_send_count;
  send_more(t);
}

static void source_cancelled(void *data, struct wl_data_source *s) {
  if (s == g_clip_source) {
    g_clip_source = NULL;
    g_selection_ours = false;
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
  char *copy = malloc(length + 1);
  if (!copy) return;
  if (length) memcpy(copy, text, length);
  free(g_clip);
  g_clip = copy;
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
} Offer_Flags;

static void offer_offer(void *data, struct wl_data_offer *offer, const char *mime) {
  Offer_Flags *m = data;
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

// The protocol sends each selection or enter right after its data_offer.
static Offer_Flags g_new_offer;

static void device_data_offer(void *data, struct wl_data_device *d, struct wl_data_offer *offer) {
  g_new_offer = (Offer_Flags){0};
  wl_data_offer_add_listener(offer, &g_offer_listener, &g_new_offer);
}

static void device_selection(void *data, struct wl_data_device *d, struct wl_data_offer *offer) {
  if (g_offer && g_offer != offer) wl_data_offer_destroy(g_offer);
  g_offer = offer;
  g_offer_text = offer && g_new_offer.text;
  g_selection_ours = offer && g_new_offer.ours && g_clip_source;
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
// We never accept a drag, so the drop is refused: finish would be a protocol
// error without an accepted action.
static void device_drop(void *data, struct wl_data_device *d) { end_drag(); }

static const struct wl_data_device_listener g_device_listener = {
    .data_offer = device_data_offer,
    .enter = device_enter,
    .leave = device_leave,
    .motion = device_motion,
    .drop = device_drop,
    .selection = device_selection,
};

// Input

static uint32_t g_modifiers;
static double g_mouse_x, g_mouse_y;

// Mouse buttons by evdev code.
#define EVDEV_BTN_LEFT 0x110
#define EVDEV_BTN_RIGHT 0x111
#define EVDEV_BTN_MIDDLE 0x112
#define EVDEV_BTN_SIDE 0x113
#define EVDEV_BTN_EXTRA 0x114
#define EVDEV_BTN_FORWARD 0x115
#define EVDEV_BTN_BACK 0x116

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

// The surface the pointer is on: the window's, or one of the border's
// around it. NULL off the window.
static struct wl_surface *g_pointer_surface;
static uint32_t g_enter_serial; // of the pointer's last enter, for set_cursor
static uint32_t g_swallowed; // 1 << Mouse_Button for presses the window took, whose releases go nowhere
static uint32_t g_resize_edge; // xdg_toplevel_resize_edge under the pointer on the border, 0 for none
static void border_pointer(struct wl_surface *s, double x, double y);
static void border_press(uint32_t serial);
static bool title_press(uint32_t button, uint32_t serial);

// The cursor by its name in the theme, or by the older X name.
static void set_cursor(const char *name, const char *x_name) {
  if (!g_cursor_theme || !g_pointer) return;
  struct wl_cursor *cursor = wl_cursor_theme_get_cursor(g_cursor_theme, name);
  if (!cursor) cursor = wl_cursor_theme_get_cursor(g_cursor_theme, x_name);
  if (!cursor || cursor->image_count == 0) return;
  struct wl_cursor_image *image = cursor->images[0];
  struct wl_buffer *buffer = wl_cursor_image_get_buffer(image);
  wl_pointer_set_cursor(g_pointer, g_enter_serial, g_cursor_surface, (int32_t)image->hotspot_x, (int32_t)image->hotspot_y);
  wl_surface_attach(g_cursor_surface, buffer, 0, 0);
  wl_surface_damage(g_cursor_surface, 0, 0, (int32_t)image->width, (int32_t)image->height);
  wl_surface_commit(g_cursor_surface);
}

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
  g_enter_serial = serial;
  g_pointer_surface = s;
  if (s != g_surface) {
    g_resize_edge = 0; // a new enter needs its own cursor
    border_pointer(s, wl_fixed_to_double(x), wl_fixed_to_double(y));
    return;
  }
  g_mouse_x = wl_fixed_to_double(x);
  g_mouse_y = wl_fixed_to_double(y);
  set_cursor("default", "left_ptr");
  push_event((Event){.kind = EVENT_MOUSE_MOVE, .modifiers = g_modifiers, .time = now_seconds(), .x = (float)g_mouse_x, .y = (float)g_mouse_y});
}

static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *s) {
  bool border = g_pointer_surface && g_pointer_surface != g_surface;
  g_pointer_surface = NULL;
  if (border) return;
  g_buttons = 0;
  g_swallowed = 0;
  push_event((Event){.kind = EVENT_MOUSE_LEAVE, .modifiers = g_modifiers, .time = now_seconds(), .x = (float)g_mouse_x, .y = (float)g_mouse_y});
}

static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
  if (g_pointer_surface && g_pointer_surface != g_surface) {
    border_pointer(g_pointer_surface, wl_fixed_to_double(x), wl_fixed_to_double(y));
    return;
  }
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
  bool down = state == WL_POINTER_BUTTON_STATE_PRESSED;
  if (g_pointer_surface && g_pointer_surface != g_surface) {
    if (down && code == EVDEV_BTN_LEFT) border_press(serial);
    return;
  }
  uint32_t button;
  if (code == EVDEV_BTN_LEFT) button = MOUSE_BUTTON_LEFT;
  else if (code == EVDEV_BTN_RIGHT) button = MOUSE_BUTTON_RIGHT;
  else if (code == EVDEV_BTN_MIDDLE) button = MOUSE_BUTTON_MIDDLE;
  else if (code == EVDEV_BTN_SIDE || code == EVDEV_BTN_BACK) button = MOUSE_BUTTON_BACK;
  else if (code == EVDEV_BTN_EXTRA || code == EVDEV_BTN_FORWARD) button = MOUSE_BUTTON_FORWARD;
  else return;
  double now = now_seconds();
  if (down) {
    bool again = g_click.button == button && now - g_click.time < 0.5 && fabs(g_mouse_x - g_click.x) < 4 && fabs(g_mouse_y - g_click.y) < 4;
    g_click.count = again ? g_click.count + 1 : 1;
    g_click.time = now;
    g_click.button = button;
    g_click.x = g_mouse_x;
    g_click.y = g_mouse_y;
    // A press on the title bar's empty room is the window's, and so is
    // its release.
    if (title_press(button, serial)) {
      g_swallowed |= 1u << button;
      return;
    }
    g_buttons |= 1u << button;
  } else {
    if (g_swallowed & (1u << button)) {
      g_swallowed &= ~(1u << button);
      return;
    }
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
  uint32_t time; // the compositor's ms, of the last axis or stop
  bool has_source, has_axis, stop;
  int32_t value120_x, value120_y;
  bool fingers; // a finger scroll is under way
} g_axis;

static bool g_gliding; // the app was sent a momentum began and no ended yet

// A wheel notch scrolls this many lines, as GTK and Firefox do.
#define WHEEL_LINES 3.0

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

static void glide_ended(void) {
  if (!g_gliding) return;
  g_gliding = false;
  scroll_event(0, 0, true, SCROLL_PHASE_NONE, SCROLL_PHASE_ENDED);
}

// The momentum's part of a frame drawn at now.
static void glide_frame(double now) {
  double d[2];
  Scroll_Step step = scroll_step(&g_kinetic, now, d);
  if (step == SCROLL_IDLE) return;
  if (d[0] != 0 || d[1] != 0) {
    scroll_event((float)d[0], (float)d[1], true, SCROLL_PHASE_NONE, g_gliding ? SCROLL_PHASE_CHANGED : SCROLL_PHASE_BEGAN);
    g_gliding = true;
  }
  if (step == SCROLL_FINISHED) glide_ended();
}

static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t value) {
  double v = -wl_fixed_to_double(value);
  if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) g_axis.dy += v;
  else g_axis.dx += v;
  g_axis.time = time;
  g_axis.has_axis = true;
}

static void pointer_axis_source(void *data, struct wl_pointer *p, uint32_t source) {
  g_axis.source = source;
  g_axis.has_source = true;
}

static void pointer_axis_stop(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis) {
  if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) g_axis.dy = 0;
  else g_axis.dx = 0;
  g_axis.time = time;
  g_axis.stop = true;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *p, uint32_t axis, int32_t discrete) {}

static void pointer_axis_value120(void *data, struct wl_pointer *p, uint32_t axis, int32_t value120) {
  if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) g_axis.value120_y -= value120;
  else g_axis.value120_x -= value120;
}

static void pointer_axis_relative_direction(void *data, struct wl_pointer *p, uint32_t axis, uint32_t direction) {}

static void pointer_frame(void *data, struct wl_pointer *p) {
  if (g_pointer_surface && g_pointer_surface != g_surface) {
    bool keep = g_axis.fingers;
    g_axis = (__typeof__(g_axis)){0};
    g_axis.fingers = keep;
    return;
  }
  bool fingers = g_axis.has_source ? g_axis.source == WL_POINTER_AXIS_SOURCE_FINGER || g_axis.source == WL_POINTER_AXIS_SOURCE_CONTINUOUS
                                   : g_axis.fingers;
  double now = now_seconds();
  bool moved = g_axis.dx != 0 || g_axis.dy != 0;
  // As in GDK, one axis stopping while the other still moves isn't the end.
  bool stop = g_axis.stop && !moved;
  if (fingers) {
    if (moved) {
      if (!g_axis.fingers) {
        scroll_begin(&g_kinetic, now);
        glide_ended();
      }
      double d[2] = {g_axis.dx, g_axis.dy};
      scroll_finger(&g_kinetic, d, g_axis.time);
      scroll_event((float)d[0], (float)d[1], true, g_axis.fingers ? SCROLL_PHASE_CHANGED : SCROLL_PHASE_BEGAN, SCROLL_PHASE_NONE);
      g_axis.fingers = true;
    }
    if (stop && g_axis.fingers) {
      g_axis.fingers = false;
      scroll_event(0, 0, true, SCROLL_PHASE_ENDED, SCROLL_PHASE_NONE);
      if (scroll_release(&g_kinetic, g_axis.time, now)) request_redraw();
    }
  } else if (g_axis.has_axis) {
    scroll_cancel(&g_kinetic);
    glide_ended();
    // A wheel: lines, from value120 where the compositor sends it.
    double lx = (g_axis.value120_x ? g_axis.value120_x / 120.0 : g_axis.dx / 10) * WHEEL_LINES;
    double ly = (g_axis.value120_y ? g_axis.value120_y / 120.0 : g_axis.dy / 10) * WHEEL_LINES;
    scroll_event((float)lx, (float)ly, false, SCROLL_PHASE_NONE, SCROLL_PHASE_NONE);
  }
  bool keep = g_axis.fingers;
  g_axis = (__typeof__(g_axis)){0};
  g_axis.fingers = keep;
}

// A finger resting on the touchpad stops the momentum, as in GTK, which
// takes holds of one or two fingers.
static void hold_begin(void *data, struct zwp_pointer_gesture_hold_v1 *h, uint32_t serial, uint32_t time, struct wl_surface *surface,
                       uint32_t fingers) {
  if (fingers != 1 && fingers != 2) return;
  scroll_hold(&g_kinetic, now_seconds());
  glide_ended();
  request_redraw();
}

static void hold_end(void *data, struct zwp_pointer_gesture_hold_v1 *h, uint32_t serial, uint32_t time, int32_t cancelled) {}

static const struct zwp_pointer_gesture_hold_v1_listener g_hold_listener = {.begin = hold_begin, .end = hold_end};

// Holds come from the pointer, so the gesture follows it.
static void update_hold(void) {
  if (g_hold && !g_pointer) {
    zwp_pointer_gesture_hold_v1_destroy(g_hold);
    g_hold = NULL;
  } else if (!g_hold && g_pointer && g_gestures) {
    g_hold = zwp_pointer_gestures_v1_get_hold_gesture(g_gestures, g_pointer);
    zwp_pointer_gesture_hold_v1_add_listener(g_hold, &g_hold_listener, NULL);
  }
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
    update_hold();
  } else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && g_pointer) {
    struct wl_pointer *pointer = g_pointer;
    g_pointer = NULL;
    update_hold();
    wl_pointer_release(pointer);
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
static uint32_t g_pending_states;

static void xdg_surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
  xdg_surface_ack_configure(s, serial);
  bool first = !g_configured;
  g_configured = true;
  if (g_pending_width > 0 && g_pending_height > 0 && (g_pending_width != g_width || g_pending_height != g_height || first)) {
    g_width = g_pending_width;
    g_height = g_pending_height;
  }
  g_states = g_pending_states;
  push_event((Event){.kind = EVENT_RESIZE, .x = g_width, .y = g_height});
  g_configure_unanswered = true;
}

static const struct xdg_surface_listener g_xdg_surface_listener = {.configure = xdg_surface_configure};

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t width, int32_t height, struct wl_array *states) {
  g_pending_width = width > 0 ? (float)width : g_width;
  g_pending_height = height > 0 ? (float)height : g_height;
  g_pending_states = 0;
  uint32_t *state;
  wl_array_for_each(state, states) if (*state < 32) g_pending_states |= 1u << *state;
}

static void toplevel_close(void *data, struct xdg_toplevel *t) { g_quit = true; }
static void toplevel_bounds(void *data, struct xdg_toplevel *t, int32_t width, int32_t height) {}

// What the window manager can do with the window, which comes before a
// configure. A compositor before xdg-shell 5 doesn't say, and can do all.
static void toplevel_capabilities(void *data, struct xdg_toplevel *t, struct wl_array *caps) {
  g_wm_caps = 0;
  uint32_t *cap;
  wl_array_for_each(cap, caps) if (*cap < 32) g_wm_caps |= 1u << *cap;
}

static const struct xdg_toplevel_listener g_toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_bounds,
    .wm_capabilities = toplevel_capabilities,
};

// The window's title bar
//
// The app asks for its own (set_decorations), unless it's on a tiling
// compositor or its settings ask for the compositor's, and the compositor
// answers through xdg-decoration. GNOME's mutter and Weston don't have it
// and leave every window's to the window. Hyprland answers server-side
// whatever the window asks and draws no title bar, so a window that asked
// for its own draws it whatever the answer. Where the title bar is the
// app's (own_buttons), the app draws the
// window's buttons in the room at the top of its view, which moves the
// window like a title bar (set_drag_regions): a press there moves it, a
// double-click maximises or restores it and a right click opens the window
// manager's menu for it. Around the window, unless it's maximised or
// tiled on that side, a border of subsurfaces resizes it and holds its
// shadow and outline, which GNOME leaves to the window too. The window's
// geometry is the window without the border, so snapping and maximising
// line up its edges, not the shadow's.

static struct zxdg_toplevel_decoration_v1 *g_decoration;
static bool g_own_titlebar; // the app's settings ask for its own title bar
static bool g_csd; // the compositor has no decorations, or left them to the app

static void decoration_configure(void *data, struct zxdg_toplevel_decoration_v1 *d, uint32_t mode) {
  g_csd = mode == ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
}

static const struct zxdg_toplevel_decoration_v1_listener g_decoration_listener = {.configure = decoration_configure};

// Asks for the mode the settings want. The compositor answers with a
// configure, which the next frame draws.
static void request_decorations(void) {
  if (!g_decoration_manager) {
    g_csd = true;
    return;
  }
  if (!g_decoration) {
    g_decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(g_decoration_manager, g_toplevel);
    zxdg_toplevel_decoration_v1_add_listener(g_decoration, &g_decoration_listener, NULL);
  }
  zxdg_toplevel_decoration_v1_set_mode(g_decoration, g_own_titlebar ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE
                                                                    : ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

static bool g_shown; // the window's first commit is done, so a change of mode goes out at once

static void set_decorations(uint32_t own) {
  if (!own == !g_own_titlebar) return;
  g_own_titlebar = own;
  if (g_shown) request_decorations();
  request_redraw();
}

static bool has_state(uint32_t state) { return g_states & (1u << state); }

// The app draws the window's buttons: the title bar is its own and the
// window isn't full screen, where GNOME's apps show none either.
static bool own_buttons(void) { return (g_csd || g_own_titlebar) && !has_state(XDG_TOPLEVEL_STATE_FULLSCREEN); }

static uint32_t window_flags(void) {
  uint32_t flags = g_decoration_manager ? WINDOW_FLAG_DECORATIONS : 0;
  if (!own_buttons()) return flags;
  flags |= WINDOW_FLAG_BUTTONS;
  if (has_state(XDG_TOPLEVEL_STATE_MAXIMIZED)) flags |= WINDOW_FLAG_MAXIMIZED;
  if (!(g_wm_caps & (1u << XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE))) flags |= WINDOW_FLAG_NO_MINIMIZE;
  if (!(g_wm_caps & (1u << XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE))) flags |= WINDOW_FLAG_NO_MAXIMIZE;
  return flags;
}

static void toggle_maximized(void) {
  if (has_state(XDG_TOPLEVEL_STATE_MAXIMIZED)) xdg_toplevel_unset_maximized(g_toplevel);
  else xdg_toplevel_set_maximized(g_toplevel);
}

static void window_command(uint32_t command) {
  switch (command) {
  case WINDOW_COMMAND_MINIMIZE: xdg_toplevel_set_minimized(g_toplevel); break;
  case WINDOW_COMMAND_TOGGLE_MAXIMIZE: toggle_maximized(); break;
  case WINDOW_COMMAND_CLOSE: g_quit = true; break;
  }
}

#define MAX_DRAG_REGIONS 64
static float g_drag_regions[MAX_DRAG_REGIONS][4];
static uint32_t g_drag_region_count;
static const char *g_title_action = "none"; // what the last press on the title bar did, for the window test step

static void set_drag_regions(const float (*rects)[4], uint32_t count) {
  if (count > MAX_DRAG_REGIONS) count = MAX_DRAG_REGIONS;
  memcpy(g_drag_regions, rects, count * sizeof rects[0]);
  g_drag_region_count = count;
}

static bool in_drag_region(double x, double y) {
  for (uint32_t i = 0; i < g_drag_region_count; i++) {
    const float *r = g_drag_regions[i];
    if (x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3]) return true;
  }
  return false;
}

// A press in the title bar's empty room, with the click count already
// counted: the left button moves the window, or every second click
// toggles maximised, as GNOME's default double-click does, and the right
// opens the window manager's menu. Other buttons go to the app.
static bool title_press(uint32_t button, uint32_t serial) {
  if (!own_buttons() || !g_toplevel || !in_drag_region(g_mouse_x, g_mouse_y)) return false;
  if (button == MOUSE_BUTTON_LEFT) {
    if (g_click.count % 2 == 0) {
      if (g_wm_caps & (1u << XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE)) toggle_maximized();
      g_title_action = "maximize";
    } else {
      if (g_seat) xdg_toplevel_move(g_toplevel, g_seat, serial);
      g_title_action = "move";
    }
    return true;
  }
  if (button == MOUSE_BUTTON_RIGHT) {
    if (g_seat && (g_wm_caps & (1u << XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU)))
      xdg_toplevel_show_window_menu(g_toplevel, g_seat, serial, (int32_t)g_mouse_x, (int32_t)g_mouse_y);
    g_title_action = "menu";
    return true;
  }
  return false;
}

// The border, in points outside the window on each side that isn't tiled
// or maximised. Along an edge, BORDER_CORNER points from a corner resize
// both ways, as GTK's do.
#define BORDER 16
#define BORDER_CORNER 24
enum { SIDE_TOP, SIDE_BOTTOM, SIDE_LEFT, SIDE_RIGHT, SIDES };

static struct {
  struct wl_surface *surface;
  struct wl_subsurface *subsurface;
  struct wp_viewport *viewport;
  int32_t x, y, w, h; // points from the window's top left; w or h 0 when hidden
} g_border[SIDES];
static int32_t g_margin[SIDES]; // the border's width on each side, 0 for none
static struct {
  float width, height, scale;
  int32_t margin[SIDES];
  bool active, viewport;
} g_border_drawn;

static void buffer_release(void *data, struct wl_buffer *buffer) { wl_buffer_destroy(buffer); }
static const struct wl_buffer_listener g_buffer_listener = {.release = buffer_release};

// How dark the border is at d points outside the window: an outline a
// pixel wide and a shadow that fades out by BORDER, darker on the active
// window. dy moves the shadow down a little, as a light from above would.
static float border_alpha(float d, float dy_d, float scale, bool active) {
  float line = d * scale < 1 ? 0.45f : 0;
  float t = 1 - dy_d / BORDER;
  float shadow = t > 0 ? (active ? 0.42f : 0.24f) * t * t : 0;
  return line + shadow * (1 - line);
}

// A buffer for the side's strip, pw by ph pixels over its w by h points,
// with the outline and shadow as premultiplied black. NULL when shared
// memory fails.
static struct wl_buffer *border_buffer(int side, int32_t pw, int32_t ph, bool active) {
  int32_t stride = pw * 4;
  size_t size = (size_t)stride * (size_t)ph;
  int fd = memfd_create("tidalfast-border", MFD_CLOEXEC);
  if (fd < 0) return NULL;
  if (ftruncate(fd, (off_t)size) < 0) {
    close(fd);
    return NULL;
  }
  uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (pixels == MAP_FAILED) {
    close(fd);
    return NULL;
  }
  float sx = (float)g_border[side].w / (float)pw, sy = (float)g_border[side].h / (float)ph;
  float scale = (float)pw / (float)g_border[side].w;
  for (int32_t py = 0; py < ph; py++) {
    float y = (float)g_border[side].y + ((float)py + 0.5f) * sy;
    for (int32_t px = 0; px < pw; px++) {
      float x = (float)g_border[side].x + ((float)px + 0.5f) * sx;
      float dx = fmaxf(fmaxf(-x, x - g_width), 0);
      float dy = fmaxf(fmaxf(-y, y - g_height), 0);
      // The shadow's distance, from the window moved down 2 points.
      float sdy = fmaxf(fmaxf(-(y - 2), (y - 2) - g_height), 0);
      float a = border_alpha(sqrtf(dx * dx + dy * dy), sqrtf(dx * dx + sdy * sdy), scale, active);
      pixels[py * pw + px] = (uint32_t)(a * 255 + 0.5f) << 24;
    }
  }
  munmap(pixels, size);
  struct wl_shm_pool *pool = wl_shm_create_pool(g_shm, fd, (int32_t)size);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, pw, ph, stride, WL_SHM_FORMAT_ARGB8888);
  wl_shm_pool_destroy(pool);
  close(fd);
  wl_buffer_add_listener(buffer, &g_buffer_listener, NULL);
  return buffer;
}

// Puts the border where this frame's size and states want it, before the
// frame's present commits the window's surface, which applies the
// subsurfaces' state with its own.
static void update_border(void) {
  if (!g_xdg_surface) return;
  bool on = own_buttons() && !has_state(XDG_TOPLEVEL_STATE_MAXIMIZED) && g_subcompositor && g_shm;
  static const uint32_t tiled[SIDES] = {XDG_TOPLEVEL_STATE_TILED_TOP, XDG_TOPLEVEL_STATE_TILED_BOTTOM, XDG_TOPLEVEL_STATE_TILED_LEFT,
                                        XDG_TOPLEVEL_STATE_TILED_RIGHT};
  for (int i = 0; i < SIDES; i++) g_margin[i] = on && !has_state(tiled[i]) ? BORDER : 0;
  bool viewport = g_fraction && g_viewport;
  bool active = has_state(XDG_TOPLEVEL_STATE_ACTIVATED);
  if (g_border_drawn.width == g_width && g_border_drawn.height == g_height && g_border_drawn.scale == g_scale &&
      !memcmp(g_border_drawn.margin, g_margin, sizeof g_margin) && g_border_drawn.active == active && g_border_drawn.viewport == viewport)
    return;
  g_border_drawn.width = g_width;
  g_border_drawn.height = g_height;
  g_border_drawn.scale = g_scale;
  memcpy(g_border_drawn.margin, g_margin, sizeof g_margin);
  g_border_drawn.active = active;
  g_border_drawn.viewport = viewport;

  int32_t w = (int32_t)g_width, h = (int32_t)g_height;
  xdg_surface_set_window_geometry(g_xdg_surface, 0, 0, w, h);
  int32_t mt = g_margin[SIDE_TOP], mb = g_margin[SIDE_BOTTOM], ml = g_margin[SIDE_LEFT], mr = g_margin[SIDE_RIGHT];
  int32_t rects[SIDES][4] = {
      {-ml, -mt, w + ml + mr, mt},
      {-ml, h, w + ml + mr, mb},
      {-ml, 0, ml, h},
      {w, 0, mr, h},
  };
  for (int i = 0; i < SIDES; i++) {
    __typeof__(g_border[0]) *b = &g_border[i];
    int32_t *r = rects[i];
    bool shown = r[2] > 0 && r[3] > 0;
    if (!shown && !b->surface) continue;
    if (!b->surface) {
      b->surface = wl_compositor_create_surface(g_compositor);
      b->subsurface = wl_subcompositor_get_subsurface(g_subcompositor, b->surface, g_surface);
      wl_subsurface_place_below(b->subsurface, g_surface);
      if (g_viewporter) b->viewport = wp_viewporter_get_viewport(g_viewporter, b->surface);
    }
    b->x = r[0];
    b->y = r[1];
    b->w = shown ? r[2] : 0;
    b->h = shown ? r[3] : 0;
    struct wl_buffer *buffer = NULL;
    if (shown) {
      int32_t pw, ph;
      if (viewport) {
        pw = (int32_t)ceilf((float)r[2] * g_scale);
        ph = (int32_t)ceilf((float)r[3] * g_scale);
        wp_viewport_set_destination(b->viewport, r[2], r[3]);
        wl_surface_set_buffer_scale(b->surface, 1);
      } else {
        pw = r[2] * g_buffer_scale;
        ph = r[3] * g_buffer_scale;
        if (b->viewport) wp_viewport_set_destination(b->viewport, -1, -1);
        wl_surface_set_buffer_scale(b->surface, g_buffer_scale);
      }
      buffer = border_buffer(i, pw, ph, active);
      if (!buffer) b->w = b->h = 0;
    }
    wl_subsurface_set_position(b->subsurface, r[0], r[1]);
    wl_surface_attach(b->surface, buffer, 0, 0);
    if (buffer) wl_surface_damage_buffer(b->surface, 0, 0, INT32_MAX, INT32_MAX);
    wl_surface_commit(b->surface);
  }
}

// The resize edge at x, y in points from the window's top left, on the
// border: the sides it's past, and the sides whose corners it's near.
static uint32_t resize_edge_at(double x, double y) {
  bool top = y < 0, bottom = y >= g_height, left = x < 0, right = x >= g_width;
  if (top || bottom) {
    if (x < BORDER_CORNER && g_margin[SIDE_LEFT]) left = true;
    else if (x >= g_width - BORDER_CORNER && g_margin[SIDE_RIGHT]) right = true;
  }
  if (left || right) {
    if (y < BORDER_CORNER && g_margin[SIDE_TOP]) top = true;
    else if (y >= g_height - BORDER_CORNER && g_margin[SIDE_BOTTOM]) bottom = true;
  }
  return (top ? XDG_TOPLEVEL_RESIZE_EDGE_TOP : 0) | (bottom ? XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM : 0) |
         (left ? XDG_TOPLEVEL_RESIZE_EDGE_LEFT : 0) | (right ? XDG_TOPLEVEL_RESIZE_EDGE_RIGHT : 0);
}

static void border_pointer(struct wl_surface *s, double x, double y) {
  for (int i = 0; i < SIDES; i++) {
    if (g_border[i].surface != s) continue;
    uint32_t edge = resize_edge_at(g_border[i].x + x, g_border[i].y + y);
    if (edge == g_resize_edge && g_resize_edge) return;
    g_resize_edge = edge;
    switch (edge) {
    case XDG_TOPLEVEL_RESIZE_EDGE_TOP: set_cursor("n-resize", "top_side"); break;
    case XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM: set_cursor("s-resize", "bottom_side"); break;
    case XDG_TOPLEVEL_RESIZE_EDGE_LEFT: set_cursor("w-resize", "left_side"); break;
    case XDG_TOPLEVEL_RESIZE_EDGE_RIGHT: set_cursor("e-resize", "right_side"); break;
    case XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT: set_cursor("nw-resize", "top_left_corner"); break;
    case XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT: set_cursor("ne-resize", "top_right_corner"); break;
    case XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT: set_cursor("sw-resize", "bottom_left_corner"); break;
    case XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT: set_cursor("se-resize", "bottom_right_corner"); break;
    default: set_cursor("default", "left_ptr"); break;
    }
    return;
  }
}

static void border_press(uint32_t serial) {
  if (g_resize_edge && g_seat && g_toplevel) xdg_toplevel_resize(g_toplevel, g_seat, serial, g_resize_edge);
}

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
  } else if (!strcmp(interface, wl_subcompositor_interface.name)) {
    g_subcompositor = wl_registry_bind(r, name, &wl_subcompositor_interface, 1);
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
  } else if (!strcmp(interface, zwp_pointer_gestures_v1_interface.name) && version >= 3) {
    // Version 3 added holds.
    g_gestures = wl_registry_bind(r, name, &zwp_pointer_gestures_v1_interface, 3);
    update_hold();
  }
#undef MIN
}

static void registry_remove(void *data, struct wl_registry *r, uint32_t name) {}

static const struct wl_registry_listener g_registry_listener = {.global = registry_global, .global_remove = registry_remove};

// The test steps of this shell, on top of common.c's:
//
//   size=w,h            make the window w by h points, as a floating window may
//   wheel=n             n wheel notches down, negative for up
//   finger=dy           one touchpad frame moving content up by dy, as libinput sends it
//   lift                the fingers leave the touchpad
//   hold                two fingers rest on the touchpad, which stops the momentum
//   scrolled            print the scroll the app was sent: points from touchpads, lines from wheels
//   move=x,y            the pointer to x, y in the window, in points
//   click=x,y           a left click there, through the same path as the compositor's
//   rclick=x,y          a right click there
//   edge=x,y            print the resize edge at x, y from the window's top left, on its border
//   window              print the window's title bar, states, border and what the last press on the title bar did

// Event times for the steps, in ms like the compositor's.
static uint32_t test_ms(void) { return (uint32_t)(now_seconds() * 1000); }

bool os_test_step(const char *command, char *arg) {
  if (!strcmp(command, "size")) {
    char *comma = strchr(arg, ',');
    float w = (float)atof(arg), h = comma ? (float)atof(comma + 1) : 0;
    if (w < 1 || h < 1) {
      fprintf(stderr, "shell: test: size wants w,h\n");
      return true;
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
    pointer_axis(NULL, NULL, test_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_double(atof(arg)));
    pointer_frame(NULL, NULL);
  } else if (!strcmp(command, "lift")) {
    pointer_axis_source(NULL, NULL, WL_POINTER_AXIS_SOURCE_FINGER);
    pointer_axis_stop(NULL, NULL, test_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL);
    pointer_frame(NULL, NULL);
  } else if (!strcmp(command, "hold")) {
    hold_begin(NULL, NULL, 0, test_ms(), NULL, 2);
  } else if (!strcmp(command, "move") || !strcmp(command, "click") || !strcmp(command, "rclick")) {
    char *comma = strchr(arg, ',');
    if (!comma) {
      fprintf(stderr, "shell: test: %s wants x,y\n", command);
      return true;
    }
    g_pointer_surface = g_surface;
    pointer_motion(NULL, NULL, test_ms(), wl_fixed_from_double(atof(arg)), wl_fixed_from_double(atof(comma + 1)));
    if (strcmp(command, "move")) {
      uint32_t code = !strcmp(command, "click") ? EVDEV_BTN_LEFT : EVDEV_BTN_RIGHT;
      pointer_button(NULL, NULL, 0, test_ms(), code, WL_POINTER_BUTTON_STATE_PRESSED);
      pointer_button(NULL, NULL, 0, test_ms(), code, WL_POINTER_BUTTON_STATE_RELEASED);
    }
  } else if (!strcmp(command, "edge")) {
    char *comma = strchr(arg, ',');
    fprintf(stderr, "shell: test: edge %u\n", comma ? resize_edge_at(atof(arg), atof(comma + 1)) : 0);
  } else if (!strcmp(command, "window")) {
    fprintf(stderr, "shell: test: window %s, flags %u, maximized %d, tiled %d%d%d%d, border %d %d %d %d, title %s\n",
            g_csd ? "client-side" : "server-side", window_flags(), has_state(XDG_TOPLEVEL_STATE_MAXIMIZED),
            has_state(XDG_TOPLEVEL_STATE_TILED_TOP), has_state(XDG_TOPLEVEL_STATE_TILED_BOTTOM), has_state(XDG_TOPLEVEL_STATE_TILED_LEFT),
            has_state(XDG_TOPLEVEL_STATE_TILED_RIGHT), g_margin[SIDE_TOP], g_margin[SIDE_BOTTOM], g_margin[SIDE_LEFT], g_margin[SIDE_RIGHT],
            g_title_action);
  } else if (!strcmp(command, "scrolled")) {
    fprintf(stderr, "shell: test: scrolled %.1f points, %.1f lines\n", g_test_scrolled_points, g_test_scrolled_lines);
  } else {
    return false;
  }
  return true;
}

void os_arm_test_timer(double after) { arm_timer(g_test_fd, after, 0); }

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
  xdg_toplevel_set_min_size(g_toplevel, MIN_WIDTH, MIN_HEIGHT);
  // The first commit waits for app_init, which says whose title bar the
  // settings want (set_decorations).
  g_surface_info = (Wayland_Surface){.display = g_display, .surface = g_surface};
  return true;
}

static void set_now_playing(const Now_Playing *np) {
  print_now_playing(np);
  mpris_set(np);
}

static void main_loop(void) {
  enum { FD_WAYLAND, FD_REDRAW, FD_WAKE, FD_REPEAT, FD_TEST, FD_SIGNAL, FD_RECEIVE, FD_MPRIS, FD_SEND, FD_COUNT = FD_SEND + CLIP_SENDS };
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
    int fd_list[FD_SEND] = {wl_fd, g_redraw_fd, g_wake_fd, g_repeat_fd, g_test_fd, g_signal_fd, g_receive_fd};
    for (int i = 0; i < FD_SEND; i++) fds[i] = (struct pollfd){.fd = fd_list[i], .events = POLLIN};
    fds[FD_MPRIS].fd = mpris_fd(&fds[FD_MPRIS].events);
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
    if (fds[FD_TEST].revents & POLLIN) {
      drain(g_test_fd);
      run_due_steps();
    }
    if (fds[FD_SIGNAL].revents & POLLIN) {
      struct signalfd_siginfo info;
      if (read(g_signal_fd, &info, sizeof info) > 0) g_quit = true;
    }
    if (fds[FD_RECEIVE].revents) receive_more();
    if (fds[FD_MPRIS].revents) mpris_dispatch(fds[FD_MPRIS].revents);
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

int shell_main(int argc, char **argv) {
  common_init();
  measure_init();
  measure_mark("main");

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
  // The random part tells apart two instances with the same pid in different pid namespaces.
  uint64_t nonce = 0;
  if (getrandom(&nonce, sizeof nonce, GRND_NONBLOCK) != (ssize_t)sizeof nonce) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    nonce = (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
  }
  snprintf(g_own_mime, sizeof g_own_mime, "application/x-tidalfast-%d-%016llx", getpid(), (unsigned long long)nonce);

  g_redraw_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  g_wake_fd = new_timer();
  g_repeat_fd = new_timer();
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
      .set_accessibility = getenv("TIDALFAST_SHELL_TEST") ? access_store : NULL,
      .set_drag_regions = set_drag_regions,
      .window_command = window_command,
      .set_decorations = set_decorations,
  };

  mpris_init(remote_command);

  measure_mark("app_start");
  app_init(&g_memory, &g_shell);
  g_app_started = true;
  request_decorations();
  wl_surface_commit(g_surface);
  g_shown = true;
  while (!g_configured && wl_display_dispatch(g_display) >= 0) {
  }
  draw_frame();
  measure_mark("window");
  // After the first frame, which it would otherwise hold up.
  mpris_start();
  setup_shell_test();
  request_redraw();
  main_loop();
  app_shutdown(&g_memory);
  mpris_close();
  wl_display_disconnect(g_display);
  return 0;
}
