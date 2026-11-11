// The platform side of the Windows executable. Owns the window, collects
// input into the event queue (common.c), and drives the app through the
// entry points in platform.h, as shell_wayland.c does on Linux. src/app's
// main calls shell_main. The renderer makes its own Direct3D 11 swap chain
// for the window in the Win32_Surface it gets.
//
// It redraws only when something asks for it: input, a resize or
// request_redraw from any thread. The main loop waits in
// MsgWaitForMultipleObjectsEx on the window's messages, an event that
// request_redraw sets and two waitable timers (wake_after and the test
// driver), then handles everything that came and draws one frame for it
// all. While the app is animating, the swap chain's blocking present
// paces the frames to the display, so the loop doesn't wait once a frame
// is due. A minimized window still draws the frames asked for, since the
// app does its work in frames (the queue moves on to the next track in
// one), but it doesn't animate. While the user drags the window's edge or
// title, or has the system menu open, Windows runs its own modal loop and
// the main loop doesn't run; a timer does its work from inside it, so the
// window keeps up with the drag.
//
// Text comes from WM_CHAR, and from an input method through IMM32: the
// composition string becomes marked text and the result string is
// inserted, as NSTextInputClient does on macOS. The input method is only
// on while a text field has the focus. Letters and digits are mapped by
// the virtual key the layout gives them, so shortcuts follow the layout,
// and the other keys by their scan code, their place on the keyboard. Not
// here yet: accessibility (UI Automation), Now Playing and the media
// overlay (System Media Transport Controls), drag and drop and touchpad
// momentum (Windows sends precision touchpad scrolls as fine wheel deltas,
// which arrive as precise scrolls without phases).

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define UNICODE
#define _UNICODE
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <imm.h>
#include <shellapi.h>

#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"

#define PERSISTENT_SIZE (256ull << 20)
#define FRAME_SIZE (64ull << 20)
#define DEFAULT_WIDTH 1100
#define DEFAULT_HEIGHT 700
#define MIN_WIDTH 480
#define MIN_HEIGHT 360
#define MODAL_TIMER 1

static bool g_app_started; // app_init has run, so frames can be drawn
static Memory g_memory;
static Shell g_shell;
static Win32_Surface g_surface_info;
static HWND g_window;
static float g_width = DEFAULT_WIDTH, g_height = DEFAULT_HEIGHT; // points
static float g_scale = 1;
static bool g_key_window;
static bool g_animating;
static bool g_in_size_move; // inside the modal loop of a drag or resize
static int g_modal_loops; // modal loops running: a drag, a resize or the system menu
static bool g_minimized; // frames only when asked, no animation, unless TIDALFAST_CAPTURE is set
static bool g_capture;
static bool g_in_frame; // inside app_frame, which a window message can re-enter
static bool g_shut_down; // app_shutdown has run

// Set by request_redraw. Auto-reset, so a wait it ends consumes it: a
// request that comes while a frame is starting leaves it set at most until
// the next wait, never with nothing to draw for it.
static HANDLE g_redraw_event;
static HANDLE g_shutdown_done; // set once app_shutdown has run, for the console handler
static HANDLE g_wake_timer; // wake_after
static HANDLE g_test_timer; // the next test step
static LARGE_INTEGER g_qpc_frequency;

double now_seconds(void) {
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  return (double)now.QuadPart / (double)g_qpc_frequency.QuadPart;
}

void request_redraw(void) {
  atomic_store(&g_needs_redraw, true);
  SetEvent(g_redraw_event);
}

static void arm_timer(HANDLE timer, double after) {
  if (after <= 0) {
    CancelWaitableTimer(timer);
    return;
  }
  LARGE_INTEGER due = {.QuadPart = -(LONGLONG)(after * 1e7)}; // 100 ns, relative
  if (due.QuadPart == 0) due.QuadPart = -1;
  SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE);
}

// TIDALFAST_MEASURE: the shell's startup marks, in the format the app's
// measure.odin prints, in milliseconds since Windows started the process.
static bool g_measure;
static double g_process_start; // unix seconds

static double unix_now(void) {
  FILETIME ft;
  GetSystemTimePreciseAsFileTime(&ft);
  uint64_t t = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
  return (double)(t - 116444736000000000ull) / 1e7;
}

static void measure_mark(const char *name) {
  if (!g_measure) return;
  fprintf(stderr, "measure: {\"mark\":\"%s\",\"ms\":%.1f}\n", name, (unix_now() - g_process_start) * 1000);
}

static void measure_init(void) {
  const char *measure = getenv("TIDALFAST_MEASURE");
  g_measure = measure && *measure;
  if (!g_measure) return;
  FILETIME created, exited, kernel, user;
  if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) {
    g_process_start = unix_now();
    return;
  }
  uint64_t t = ((uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
  g_process_start = (double)(t - 116444736000000000ull) / 1e7;
}

// UTF-16, which Windows speaks, to UTF-8.

static char *utf8_of(const wchar_t *w, int n) {
  int bytes = WideCharToMultiByte(CP_UTF8, 0, w, n, NULL, 0, NULL, NULL);
  char *out = malloc((size_t)bytes + 1);
  WideCharToMultiByte(CP_UTF8, 0, w, n, out, bytes, NULL, NULL);
  out[bytes] = 0;
  return out;
}

// The buttons held down now, in any app: the physical buttons, which
// GetAsyncKeyState reads, swapped back to the logical ones when the user
// swapped the left and right buttons. GetKeyState would be this thread's
// view, which misses a release that went to another app.
static uint32_t buttons_down(void) {
  bool swapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
  return (GetAsyncKeyState(swapped ? VK_RBUTTON : VK_LBUTTON) < 0 ? 1u << MOUSE_BUTTON_LEFT : 0) |
         (GetAsyncKeyState(swapped ? VK_LBUTTON : VK_RBUTTON) < 0 ? 1u << MOUSE_BUTTON_RIGHT : 0) |
         (GetAsyncKeyState(VK_MBUTTON) < 0 ? 1u << MOUSE_BUTTON_MIDDLE : 0) |
         (GetAsyncKeyState(VK_XBUTTON1) < 0 ? 1u << MOUSE_BUTTON_BACK : 0) |
         (GetAsyncKeyState(VK_XBUTTON2) < 0 ? 1u << MOUSE_BUTTON_FORWARD : 0);
}

// Frames

// The refresh interval of the monitor the window is on, in seconds, or 0
// when Windows doesn't say. It's looked up again when the window goes to
// another monitor, or after WM_DISPLAYCHANGE clears g_refresh_monitor.
static HMONITOR g_refresh_monitor;
static double g_refresh_interval;

static double refresh_interval(void) {
  HMONITOR monitor = MonitorFromWindow(g_window, MONITOR_DEFAULTTONEAREST);
  if (monitor == g_refresh_monitor) return g_refresh_interval;
  g_refresh_monitor = monitor;
  g_refresh_interval = 0;
  MONITORINFOEXW info;
  memset(&info, 0, sizeof info);
  ((MONITORINFO *)&info)->cbSize = sizeof info;
  DEVMODEW mode;
  memset(&mode, 0, sizeof mode);
  mode.dmSize = sizeof mode;
  // 0 and 1 mean the hardware's default rate, which it doesn't name.
  if (monitor && GetMonitorInfoW(monitor, (MONITORINFO *)&info) &&
      EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode) && mode.dmDisplayFrequency > 1)
    g_refresh_interval = 1.0 / mode.dmDisplayFrequency;
  return g_refresh_interval;
}

// A frame's work can send the window a message: the input method's
// answer to ImmNotifyIME, or a sent message from another thread while a
// call waits. If that message asks for a frame, it gets the next one; the
// app is never re-entered. Events it queues go to the next frame too,
// since queue_take handed this frame's to the app.
static void draw_frame(void) {
  if (!g_app_started || g_in_frame) return;
  atomic_store(&g_needs_redraw, false);
  Frame_Input input = {
      .width = g_width,
      .height = g_height,
      .scale = g_scale,
      .time = now_seconds() - g_start_time,
      .key_window = g_key_window,
      .mouse_buttons = buttons_down(),
      .frame_interval = (float)refresh_interval(),
  };
  queue_take(&input.events, &input.event_count, &input.text, &input.text_length);
  g_in_frame = true;
  Frame_Result result = app_frame(&g_memory, &g_shell, &input);
  g_in_frame = false;
  g_animating = result.animating;
  arm_timer(g_wake_timer, result.wake_after > 0 ? result.wake_after : 0);
}

// Whether the app's animation draws frames: not while the window is
// minimized, unless a test captures them.
static bool animating(void) { return g_animating && !(g_minimized && !g_capture); }

// The window's size in points, from its client rect in pixels.
static void update_size(void) {
  RECT r;
  GetClientRect(g_window, &r);
  g_scale = (float)GetDpiForWindow(g_window) / 96.0f;
  if (g_scale <= 0) g_scale = 1;
  float w = (float)(r.right - r.left) / g_scale, h = (float)(r.bottom - r.top) / g_scale;
  if (w < 1 || h < 1) return; // minimized
  g_width = w;
  g_height = h;
  push_event((Event){.kind = EVENT_RESIZE, .x = g_width, .y = g_height, .time = now_seconds()});
}

// Input

static uint32_t modifiers(void) {
  uint32_t m = 0;
  if (GetKeyState(VK_SHIFT) < 0) m |= MODIFIER_SHIFT;
  if (GetKeyState(VK_CONTROL) < 0) m |= MODIFIER_CONTROL;
  if (GetKeyState(VK_MENU) < 0) m |= MODIFIER_ALT;
  if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) m |= MODIFIER_SUPER;
  if (GetKeyState(VK_CAPITAL) & 1) m |= MODIFIER_CAPS_LOCK;
  return m;
}

static uint32_t g_modifiers;
static float g_mouse_x, g_mouse_y;
static bool g_tracking_leave;

static void modifiers_changed(void) {
  uint32_t m = modifiers();
  if (m != g_modifiers) {
    g_modifiers = m;
    push_event((Event){.kind = EVENT_MODIFIERS_CHANGED, .modifiers = m, .time = now_seconds()});
  }
}

// Keys for the app. Letters and digits come from the virtual key, which
// the layout sets: Control+Z is undo on the key labelled Z on a German or
// a French keyboard, and on Dvorak, and a Cyrillic or Greek layout gives
// its letter keys the US letters' virtual keys, so the shortcuts still
// work there. Editing and navigation keys come from the virtual key too,
// which the keypad's keys with NumLock off share with the dedicated ones.
// The rest go by scan code, the key's place on the keyboard, as the Linux
// shell maps evdev codes: the key under Escape is the overlay's backtick
// whatever it types. The keypad's Enter has the E0 prefix (bit 24 of
// lParam), which tells it from Return.
static uint32_t key_of(WPARAM vk, LPARAM lp) {
  if (vk >= 'A' && vk <= 'Z') return KEY_A + (uint32_t)(vk - 'A');
  if (vk >= '0' && vk <= '9') return KEY_DIGIT_0 + (uint32_t)(vk - '0');
  if (vk >= VK_F1 && vk <= VK_F12) return KEY_F1 + (uint32_t)(vk - VK_F1);
  switch (vk) {
  case VK_RETURN: return (lp & (1 << 24)) ? KEY_KEYPAD_ENTER : KEY_RETURN;
  case VK_TAB: return KEY_TAB;
  case VK_SPACE: return KEY_SPACE;
  case VK_BACK: return KEY_BACKSPACE;
  case VK_ESCAPE: return KEY_ESCAPE;
  case VK_DELETE: return KEY_DELETE;
  case VK_HOME: return KEY_HOME;
  case VK_END: return KEY_END;
  case VK_PRIOR: return KEY_PAGE_UP;
  case VK_NEXT: return KEY_PAGE_DOWN;
  case VK_LEFT: return KEY_LEFT;
  case VK_RIGHT: return KEY_RIGHT;
  case VK_UP: return KEY_UP;
  case VK_DOWN: return KEY_DOWN;
  }
  uint32_t scan = (uint32_t)(lp >> 16) & 0xff;
  bool extended = (lp & (1 << 24)) != 0;
  if (scan == 0x29 && !extended) return KEY_GRAVE;
  return KEY_NONE;
}

// While a text field has the focus, a key that types something with no
// Control or Alt held reaches the app as text only, from WM_CHAR, as on
// Linux. Other keys (arrows, Backspace, Return, shortcuts) reach it as key
// events. AltGr is Control and Alt together, and types text.
static bool types_text(WPARAM vk) {
  if (!g_ti.active) return false;
  bool ctrl = GetKeyState(VK_CONTROL) < 0, alt = GetKeyState(VK_MENU) < 0;
  bool altgr = GetKeyState(VK_RMENU) < 0 && ctrl;
  if ((ctrl || alt) && !altgr) return false;
  BYTE state[256];
  if (!GetKeyboardState(state)) return false;
  wchar_t out[4];
  // Flag 4: don't change the keyboard's dead key state.
  int n = ToUnicode((UINT)vk, MapVirtualKeyW((UINT)vk, MAPVK_VK_TO_VSC), state, out, 4, 4);
  return n != 0 && (n < 0 || out[0] >= 0x20) && out[0] != 0x7f;
}

static bool media_key(WPARAM vk) {
  switch (vk) {
  case VK_MEDIA_PLAY_PAUSE: remote_command(MEDIA_TOGGLE, 0); return true;
  case VK_MEDIA_STOP: remote_command(MEDIA_PAUSE, 0); return true;
  case VK_MEDIA_NEXT_TRACK: remote_command(MEDIA_NEXT, 0); return true;
  case VK_MEDIA_PREV_TRACK: remote_command(MEDIA_PREVIOUS, 0); return true;
  }
  return false;
}

static wchar_t g_high_surrogate;

static void on_char(wchar_t c) {
  if (c >= 0xd800 && c < 0xdc00) {
    g_high_surrogate = c;
    return;
  }
  wchar_t pair[2] = {c, 0};
  int n = 1;
  if (c >= 0xdc00 && c < 0xe000) {
    if (!g_high_surrogate) return;
    pair[0] = g_high_surrogate;
    pair[1] = c;
    n = 2;
  }
  g_high_surrogate = 0;
  if (!g_ti.active || pair[0] < 0x20 || pair[0] == 0x7f) return;
  char *utf8 = utf8_of(pair, n);
  text_insert(utf8, -1, -1);
  free(utf8);
}

// Click counts as macOS makes them: the same button again within the
// double-click time, close to the last press.
static struct {
  double time;
  uint32_t button, count;
  float x, y;
} g_click;

// The buttons that went down in the window and haven't come up, which
// hold the mouse capture so a drag keeps going outside the window.
static uint32_t g_held;

static void mouse_button(uint32_t button, bool down) {
  double now = now_seconds();
  if (down) {
    double limit = GetDoubleClickTime() / 1000.0;
    bool again = g_click.button == button && now - g_click.time < limit && fabsf(g_mouse_x - g_click.x) < 4 &&
                 fabsf(g_mouse_y - g_click.y) < 4;
    g_click.count = again ? g_click.count + 1 : 1;
    g_click.time = now;
    g_click.button = button;
    g_click.x = g_mouse_x;
    g_click.y = g_mouse_y;
    if (!g_held) SetCapture(g_window);
    g_held |= 1u << button;
  } else {
    bool held = g_held != 0;
    g_held &= ~(1u << button);
    if (held && !g_held && GetCapture() == g_window) ReleaseCapture();
  }
  push_event((Event){
      .kind = down ? EVENT_MOUSE_DOWN : EVENT_MOUSE_UP,
      .modifiers = g_modifiers,
      .time = now,
      .x = g_mouse_x,
      .y = g_mouse_y,
      .button = button,
      .click_count = g_click.count,
  });
}

static void mouse_at(LPARAM lp) {
  g_mouse_x = (float)GET_X_LPARAM(lp) / g_scale;
  g_mouse_y = (float)GET_Y_LPARAM(lp) / g_scale;
}

// A wheel notch is WHEEL_DELTA (120). A mouse wheel sends whole notches,
// which scroll the user's lines per notch, three by default. A precision
// touchpad, and a free-spinning wheel, send fractions of a notch, which go
// to the app as precise points, a notch being the same lines of 16 points.
// Up and left are positive, as the app takes them; Windows' horizontal
// wheel is positive to the right.
static double g_test_scrolled_points, g_test_scrolled_lines;

static void wheel(int delta, bool horizontal) {
  UINT lines = 3;
  SystemParametersInfoW(horizontal ? SPI_GETWHEELSCROLLCHARS : SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
  if (lines == WHEEL_PAGESCROLL || lines == 0) lines = 3;
  bool precise = delta % WHEEL_DELTA != 0;
  float amount = (float)delta / WHEEL_DELTA * (float)lines * (precise ? 16.0f : 1.0f);
  if (horizontal) amount = -amount;
  if (precise) g_test_scrolled_points += amount;
  else g_test_scrolled_lines += amount;
  push_event((Event){
      .kind = EVENT_SCROLL,
      .modifiers = g_modifiers,
      .time = now_seconds(),
      .x = g_mouse_x,
      .y = g_mouse_y,
      .dx = horizontal ? amount : 0,
      .dy = horizontal ? 0 : amount,
      .precise = precise,
  });
}

// Text input
//
// An input method composes in the window through IMM32. Its composition
// string goes to the app as marked text with the caret where the input
// method has it, and its result string is inserted. The candidate window
// goes under the caret the app reports. A composition the app ends itself,
// by unmarking, is completed for the input method too.
//
// The window has an input method context only while a text field has the
// focus. Without one, the input method is off: with a CJK input method
// selected, keys such as Space would otherwise go to it as VK_PROCESSKEY
// and never reach the app's shortcuts.

static bool g_composing;
// The app ended the composition and kept its text, so the result string
// that completing it brings, now or later, is already in the field.
static bool g_completed;

static void place_candidates(HIMC imc) {
  float *c = g_ti.caret;
  COMPOSITIONFORM cf = {.dwStyle = CFS_POINT, .ptCurrentPos = {(LONG)(c[0] * g_scale), (LONG)(c[1] * g_scale)}};
  ImmSetCompositionWindow(imc, &cf);
  CANDIDATEFORM cand = {
      .dwIndex = 0,
      .dwStyle = CFS_EXCLUDE,
      .ptCurrentPos = {(LONG)(c[0] * g_scale), (LONG)((c[1] + c[3]) * g_scale)},
      .rcArea = {(LONG)(c[0] * g_scale), (LONG)(c[1] * g_scale), (LONG)((c[0] + (c[2] > 1 ? c[2] : 1)) * g_scale),
                 (LONG)((c[1] + c[3]) * g_scale)},
  };
  ImmSetCandidateWindow(imc, &cand);
}

static char *ime_string(HIMC imc, DWORD which, LONG *units) {
  LONG bytes = ImmGetCompositionStringW(imc, which, NULL, 0);
  if (bytes < 0) bytes = 0;
  wchar_t *w = malloc((size_t)bytes + sizeof(wchar_t));
  ImmGetCompositionStringW(imc, which, w, (DWORD)bytes);
  *units = bytes / (LONG)sizeof(wchar_t);
  char *s = utf8_of(w, *units);
  free(w);
  return s;
}

static void ime_composition(LPARAM lp) {
  HIMC imc = ImmGetContext(g_window);
  if (!imc) return;
  if (lp & GCS_RESULTSTR) {
    if (g_completed) {
      g_completed = false;
    } else {
      LONG units;
      char *s = ime_string(imc, GCS_RESULTSTR, &units);
      text_insert(s, -1, -1);
      free(s);
    }
    g_composing = false;
  }
  if (lp & GCS_COMPSTR) {
    LONG units;
    char *s = ime_string(imc, GCS_COMPSTR, &units);
    // The caret, in UTF-16 units of the composition, as bytes.
    LONG cursor = (lp & GCS_CURSORPOS) ? ImmGetCompositionStringW(imc, GCS_CURSORPOS, NULL, 0) : units;
    if (cursor < 0 || cursor > units) cursor = units;
    uint32_t at = byte_of_utf16((const uint8_t *)s, (uint32_t)strlen(s), (uint32_t)cursor);
    if (*s || g_ti.marked_start >= 0) text_set_marked(s, at, at, -1, -1);
    g_composing = *s != 0;
    free(s);
  }
  place_candidates(imc);
  ImmReleaseContext(g_window, imc);
}

// The input method follows the focus: on with a text field, off without.
static void ime_enable(bool on) {
  if (on) {
    ImmAssociateContextEx(g_window, NULL, IACE_DEFAULT);
    return;
  }
  HIMC imc = ImmGetContext(g_window);
  if (imc) {
    ImmNotifyIME(imc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
    ImmReleaseContext(g_window, imc);
  }
  g_composing = false;
  g_completed = false;
  ImmAssociateContextEx(g_window, NULL, 0);
}

static void set_text_input(const Text_Input *ti) {
  bool was_active = g_ti.active, was_marked = g_ti.marked_start >= 0;
  if (!mirror_set(ti)) return;
  if (g_ti.active != was_active) ime_enable(g_ti.active);
  if (!g_ti.active) return;
  HIMC imc = ImmGetContext(g_window);
  if (!imc) return;
  place_candidates(imc);
  if (g_composing && was_marked && g_ti.marked_start < 0) {
    // The app ended the composition as it was.
    g_composing = false;
    g_completed = true;
    ImmNotifyIME(imc, NI_COMPOSITIONSTR, CPS_COMPLETE, 0);
  }
  ImmReleaseContext(g_window, imc);
}

// Clipboard: UTF-16 text on the system clipboard, CF_UNICODETEXT.
//
// Only one window can have the clipboard open, and clipboard managers and
// remote desktop clients open it for a moment after each change, so
// opening it tries again for a while before giving up.
static bool open_clipboard(void) {
  for (int i = 0; i < 10; i++) {
    if (OpenClipboard(g_window)) return true;
    Sleep(i < 5 ? 2 : 10);
  }
  fprintf(stderr, "shell: couldn't open the clipboard, error %lu\n", GetLastError());
  return false;
}

static void set_clipboard(const uint8_t *text, size_t length) {
  if (!open_clipboard()) return;
  EmptyClipboard();
  int units = MultiByteToWideChar(CP_UTF8, 0, (const char *)text, (int)length, NULL, 0);
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, ((size_t)units + 1) * sizeof(wchar_t));
  if (mem) {
    wchar_t *w = GlobalLock(mem);
    MultiByteToWideChar(CP_UTF8, 0, (const char *)text, (int)length, w, units);
    w[units] = 0;
    GlobalUnlock(mem);
    if (!SetClipboardData(CF_UNICODETEXT, mem)) GlobalFree(mem);
  }
  CloseClipboard();
}

static size_t get_clipboard(uint8_t *buffer, size_t capacity) {
  if (!open_clipboard()) return 0;
  size_t length = 0;
  HANDLE mem = GetClipboardData(CF_UNICODETEXT);
  const wchar_t *w = mem ? GlobalLock(mem) : NULL;
  if (w) {
    int bytes = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (bytes > 0) {
      char *utf8 = malloc((size_t)bytes);
      WideCharToMultiByte(CP_UTF8, 0, w, -1, utf8, bytes, NULL, NULL);
      length = (size_t)bytes - 1;
      if (buffer && capacity) memcpy(buffer, utf8, length < capacity ? length : capacity);
      SecureZeroMemory(utf8, (size_t)bytes);
      free(utf8);
    }
    GlobalUnlock(mem);
  }
  CloseClipboard();
  return length;
}

// The window

static void shut_down(void);

// A modal loop (a drag or resize of the window, or the system menu) keeps
// the main loop from running until it ends. A timer does the main loop's
// work from inside it: the test steps, the app's wake_after and the frames
// asked for.
static void modal_loop(bool entering) {
  g_modal_loops += entering ? 1 : -1;
  if (entering && g_modal_loops == 1) SetTimer(g_window, MODAL_TIMER, 8, NULL);
  if (!entering && g_modal_loops == 0) KillTimer(g_window, MODAL_TIMER);
}

static void modal_tick(void) {
  // Steps run whether their timer fired or not: a step can open the modal
  // loop, as vkey=alt+space does, and the timer for the steps after it is
  // only armed once that step returns.
  WaitForSingleObject(g_test_timer, 0);
  run_due_steps();
  if (WaitForSingleObject(g_wake_timer, 0) == WAIT_OBJECT_0) atomic_store(&g_needs_redraw, true);
  WaitForSingleObject(g_redraw_event, 0); // g_needs_redraw says the same
  if (atomic_load(&g_needs_redraw) || animating()) draw_frame();
}

static bool is_modifier(WPARAM vk) {
  return vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU || vk == VK_LWIN || vk == VK_RWIN || vk == VK_CAPITAL;
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_CLOSE:
    atomic_store(&g_quit, true);
    return 0;
  case WM_QUERYENDSESSION:
    return TRUE;
  case WM_ENDSESSION:
    // The user is logging off or Windows is shutting down. The process
    // can be ended any time after this returns, before the main loop
    // gets to quit, so the app shuts down here.
    if (wp) shut_down();
    return 0;
  case WM_SIZE:
    g_minimized = wp == SIZE_MINIMIZED;
    // A frame as the window goes, for the renderer to see it's minimized
    // and give back its buffers.
    if (g_minimized) draw_frame();
    if (wp != SIZE_MINIMIZED) {
      update_size();
      request_redraw();
      if (g_in_size_move) draw_frame();
    }
    return 0;
  case WM_DPICHANGED: {
    RECT *r = (RECT *)lp;
    SetWindowPos(hwnd, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
    update_size();
    return 0;
  }
  case WM_DISPLAYCHANGE:
    g_refresh_monitor = NULL;
    break;
  case WM_GETMINMAXINFO: {
    MINMAXINFO *mm = (MINMAXINFO *)lp;
    float s = hwnd ? (float)GetDpiForWindow(hwnd) / 96.0f : 1;
    RECT r = {0, 0, (LONG)(MIN_WIDTH * s), (LONG)(MIN_HEIGHT * s)};
    AdjustWindowRectExForDpi(&r, WS_OVERLAPPEDWINDOW, FALSE, 0, hwnd ? GetDpiForWindow(hwnd) : 96);
    mm->ptMinTrackSize.x = r.right - r.left;
    mm->ptMinTrackSize.y = r.bottom - r.top;
    return 0;
  }
  case WM_ENTERSIZEMOVE:
    g_in_size_move = true;
    modal_loop(true);
    return 0;
  case WM_EXITSIZEMOVE:
    g_in_size_move = false;
    modal_loop(false);
    return 0;
  case WM_ENTERMENULOOP:
    modal_loop(true);
    return 0;
  case WM_EXITMENULOOP:
    modal_loop(false);
    return 0;
  case WM_TIMER:
    if (wp == MODAL_TIMER) modal_tick();
    return 0;
  case WM_PAINT:
    ValidateRect(hwnd, NULL);
    request_redraw();
    return 0;
  case WM_ERASEBKGND:
    return 1;
  case WM_SETFOCUS:
    g_key_window = true;
    modifiers_changed();
    request_redraw();
    return 0;
  case WM_KILLFOCUS:
    g_key_window = false;
    request_redraw();
    return 0;
  case WM_CAPTURECHANGED:
    // Another window took the mouse, as Alt+Tab does in the middle of a
    // drag, and the buttons' releases may go to it. The app cancels a
    // button the hardware says is up (Frame_Input.mouse_buttons) over two
    // frames, so it needs a frame.
    if ((HWND)lp != hwnd && g_held) {
      g_held = 0;
      request_redraw();
    }
    return 0;
  case WM_MOUSEMOVE:
    mouse_at(lp);
    if (!g_tracking_leave) {
      TRACKMOUSEEVENT tme = {.cbSize = sizeof tme, .dwFlags = TME_LEAVE, .hwndTrack = hwnd};
      g_tracking_leave = TrackMouseEvent(&tme);
    }
    push_event((Event){.kind = EVENT_MOUSE_MOVE, .modifiers = g_modifiers, .time = now_seconds(), .x = g_mouse_x, .y = g_mouse_y});
    return 0;
  case WM_MOUSELEAVE:
    g_tracking_leave = false;
    push_event((Event){.kind = EVENT_MOUSE_LEAVE, .modifiers = g_modifiers, .time = now_seconds(), .x = g_mouse_x, .y = g_mouse_y});
    return 0;
  case WM_LBUTTONDOWN:
  case WM_LBUTTONUP:
  case WM_RBUTTONDOWN:
  case WM_RBUTTONUP:
  case WM_MBUTTONDOWN:
  case WM_MBUTTONUP:
  case WM_XBUTTONDOWN:
  case WM_XBUTTONUP: {
    mouse_at(lp);
    bool down = msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN || msg == WM_XBUTTONDOWN;
    uint32_t button = msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP   ? MOUSE_BUTTON_LEFT
                      : msg == WM_RBUTTONDOWN || msg == WM_RBUTTONUP ? MOUSE_BUTTON_RIGHT
                      : msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP ? MOUSE_BUTTON_MIDDLE
                      : GET_XBUTTON_WPARAM(wp) == XBUTTON1           ? MOUSE_BUTTON_BACK
                                                                     : MOUSE_BUTTON_FORWARD;
    mouse_button(button, down);
    return msg == WM_XBUTTONDOWN || msg == WM_XBUTTONUP ? TRUE : 0;
  }
  case WM_MOUSEWHEEL:
  case WM_MOUSEHWHEEL: {
    // The wheel's position is in screen pixels.
    POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
    ScreenToClient(hwnd, &p);
    g_mouse_x = (float)p.x / g_scale;
    g_mouse_y = (float)p.y / g_scale;
    wheel(GET_WHEEL_DELTA_WPARAM(wp), msg == WM_MOUSEHWHEEL);
    return 0;
  }
  case WM_KEYDOWN:
  case WM_SYSKEYDOWN: {
    modifiers_changed();
    if (!(lp & (1 << 30)) && media_key(wp)) return 0;
    // Alt+F4 closes the window and Alt+Space opens the system menu, as in
    // any window. The menu opens from the WM_SYSCHAR that follows.
    if (msg == WM_SYSKEYDOWN && (wp == VK_F4 || wp == VK_SPACE)) break;
    if (is_modifier(wp)) return 0;
    if (wp == VK_PROCESSKEY || types_text(wp)) {
      // WM_CHAR or the input method brings the text.
      if (msg == WM_SYSKEYDOWN) break;
      return 0;
    }
    push_event((Event){
        .kind = EVENT_KEY_DOWN,
        .modifiers = g_modifiers,
        .time = now_seconds(),
        .key = key_of(wp, lp),
        .repeat = (lp & (1 << 30)) != 0,
    });
    return 0;
  }
  case WM_KEYUP:
  case WM_SYSKEYUP:
    modifiers_changed();
    // Alt up returns here too, so there's no menu bar to activate.
    if (is_modifier(wp)) return 0;
    if (msg == WM_SYSKEYUP && (wp == VK_F4 || wp == VK_SPACE)) break;
    push_event((Event){.kind = EVENT_KEY_UP, .modifiers = g_modifiers, .time = now_seconds(), .key = key_of(wp, lp)});
    return 0;
  case WM_CHAR:
    on_char((wchar_t)wp);
    return 0;
  case WM_SYSCHAR:
    if (wp == ' ') break; // Alt+Space: the system menu
    return 0; // no beep for Alt shortcuts
  case WM_IME_STARTCOMPOSITION:
    g_composing = true;
    g_completed = false;
    return 0;
  case WM_IME_COMPOSITION:
    ime_composition(lp);
    return 0; // drawn by the app, not in the input method's own window
  case WM_IME_ENDCOMPOSITION:
    if (g_ti.marked_start >= 0) text_set_marked("", 0, 0, -1, -1);
    g_composing = false;
    g_completed = false;
    return 0;
  case WM_IME_SETCONTEXT:
    // The app draws the composition itself.
    lp &= ~(LPARAM)ISC_SHOWUICOMPOSITIONWINDOW;
    break;
  case WM_APPCOMMAND:
    switch (GET_APPCOMMAND_LPARAM(lp)) {
    case APPCOMMAND_BROWSER_BACKWARD: mouse_button(MOUSE_BUTTON_BACK, true), mouse_button(MOUSE_BUTTON_BACK, false); return TRUE;
    case APPCOMMAND_BROWSER_FORWARD: mouse_button(MOUSE_BUTTON_FORWARD, true), mouse_button(MOUSE_BUTTON_FORWARD, false); return TRUE;
    case APPCOMMAND_MEDIA_PLAY_PAUSE: remote_command(MEDIA_TOGGLE, 0); return TRUE;
    case APPCOMMAND_MEDIA_PLAY: remote_command(MEDIA_PLAY, 0); return TRUE;
    case APPCOMMAND_MEDIA_PAUSE: remote_command(MEDIA_PAUSE, 0); return TRUE;
    case APPCOMMAND_MEDIA_NEXTTRACK: remote_command(MEDIA_NEXT, 0); return TRUE;
    case APPCOMMAND_MEDIA_PREVIOUSTRACK: remote_command(MEDIA_PREVIOUS, 0); return TRUE;
    }
    break;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

// The test steps of this shell, on top of common.c's. The pointer and the
// wheel go through the window procedure, as Windows' own messages do:
//
//   size=w,h            make the window's client area w by h points
//   move=x,y            the pointer moves to x, y in points
//   click=x,y           a left click at x, y in points
//   type=text           each UTF-16 unit of text as a WM_CHAR, surrogate pairs as two
//   vkey=ctrl+name      WM_KEYDOWN and WM_KEYUP for a virtual key, with modifiers (ctrl, alt, shift) held:
//                       escape, return, enter (the keypad's), backspace, tab, space, delete, home, end,
//                       pageup, pagedown, left, right, up, down, a to z, 0 to 9, and the keypad's
//                       keys with NumLock off as kp-home, kp-left and so on. With alt, WM_SYSKEYDOWN,
//                       and WM_SYSCHAR for space, as TranslateMessage makes.
//   wheel=n             n wheel notches down, negative for up, where the pointer is
//   touchpad=dy         a precision touchpad scroll moving content up by dy points
//   scrolled            print the scroll the app was sent: points from touchpads, lines from wheels
//   snapshot            ask the app for a memory snapshot, as SIGUSR1 does elsewhere
//   minimize, restore   minimize the window, and show it again
//   endsession          WM_QUERYENDSESSION and WM_ENDSESSION, as when the user logs off
//   endmenu             print how many modal loops run, and close the open menu, such as alt+space's

// app_take_snapshot is in src/app/snapshot_windows.odin.
void app_take_snapshot(void);

static LPARAM test_point(const char *arg) {
  const char *comma = strchr(arg, ',');
  int x = (int)lroundf((float)atof(arg) * g_scale), y = comma ? (int)lroundf((float)atof(comma + 1) * g_scale) : 0;
  return MAKELPARAM(x, y);
}

static void test_wheel(int delta) {
  POINT p = {(LONG)(g_mouse_x * g_scale), (LONG)(g_mouse_y * g_scale)};
  ClientToScreen(g_window, &p);
  SendMessageW(g_window, WM_MOUSEWHEEL, MAKEWPARAM(0, delta), MAKELPARAM(p.x, p.y));
}

// The modifiers go into the thread's keyboard state, which GetKeyState
// reads, for as long as the key is down.
static void test_vkey(char *spec) {
  static const struct {
    const char *name;
    UINT vk;
    bool extended;
  } keys[] = {
      {"escape", VK_ESCAPE, false},     {"return", VK_RETURN, false},   {"enter", VK_RETURN, true},
      {"backspace", VK_BACK, false},    {"tab", VK_TAB, false},         {"space", VK_SPACE, false},
      {"delete", VK_DELETE, true},      {"home", VK_HOME, true},        {"end", VK_END, true},
      {"pageup", VK_PRIOR, true},       {"pagedown", VK_NEXT, true},    {"left", VK_LEFT, true},
      {"right", VK_RIGHT, true},        {"up", VK_UP, true},            {"down", VK_DOWN, true},
      {"kp-delete", VK_DELETE, false},  {"kp-home", VK_HOME, false},    {"kp-end", VK_END, false},
      {"kp-pageup", VK_PRIOR, false},   {"kp-pagedown", VK_NEXT, false}, {"kp-left", VK_LEFT, false},
      {"kp-right", VK_RIGHT, false},    {"kp-up", VK_UP, false},        {"kp-down", VK_DOWN, false},
  };
  BYTE state[256], held[256];
  GetKeyboardState(state);
  memcpy(held, state, sizeof held);
  bool alt = false;
  char *name = spec;
  for (char *plus = strchr(name, '+'); plus; plus = strchr(name, '+')) {
    *plus = 0;
    if (!strcmp(name, "ctrl")) held[VK_CONTROL] = held[VK_LCONTROL] = 0x80;
    else if (!strcmp(name, "shift")) held[VK_SHIFT] = held[VK_LSHIFT] = 0x80;
    else if (!strcmp(name, "alt")) held[VK_MENU] = held[VK_LMENU] = 0x80, alt = true;
    name = plus + 1;
  }
  UINT vk = 0;
  bool extended = false;
  for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
    if (!strcmp(keys[i].name, name)) vk = keys[i].vk, extended = keys[i].extended;
  if (!vk && strlen(name) == 1 && name[0] >= 'a' && name[0] <= 'z') vk = (UINT)(name[0] - 'a' + 'A');
  if (!vk && strlen(name) == 1 && name[0] >= '0' && name[0] <= '9') vk = (UINT)name[0];
  if (!vk) {
    fprintf(stderr, "shell: test: no key named %s\n", name);
    return;
  }
  UINT scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
  LPARAM lp = 1 | (LPARAM)scan << 16 | (extended ? 1 << 24 : 0) | (alt ? 1 << 29 : 0);
  SetKeyboardState(held);
  SendMessageW(g_window, alt ? WM_SYSKEYDOWN : WM_KEYDOWN, vk, lp);
  if (alt && vk == VK_SPACE) SendMessageW(g_window, WM_SYSCHAR, ' ', lp);
  SendMessageW(g_window, alt ? WM_SYSKEYUP : WM_KEYUP, vk, lp | (LPARAM)3 << 30);
  SetKeyboardState(state);
}

bool os_test_step(const char *command, char *arg) {
  if (!strcmp(command, "size")) {
    char *comma = strchr(arg, ',');
    float w = (float)atof(arg), h = comma ? (float)atof(comma + 1) : 0;
    if (w < 1 || h < 1) {
      fprintf(stderr, "shell: test: size wants w,h\n");
      return true;
    }
    UINT dpi = GetDpiForWindow(g_window);
    RECT r = {0, 0, (LONG)lroundf(w * dpi / 96.0f), (LONG)lroundf(h * dpi / 96.0f)};
    AdjustWindowRectExForDpi(&r, (DWORD)GetWindowLongW(g_window, GWL_STYLE), FALSE, (DWORD)GetWindowLongW(g_window, GWL_EXSTYLE), dpi);
    SetWindowPos(g_window, NULL, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    request_redraw();
  } else if (!strcmp(command, "move")) {
    SendMessageW(g_window, WM_MOUSEMOVE, 0, test_point(arg));
  } else if (!strcmp(command, "click")) {
    LPARAM at = test_point(arg);
    SendMessageW(g_window, WM_MOUSEMOVE, 0, at);
    SendMessageW(g_window, WM_LBUTTONDOWN, MK_LBUTTON, at);
    SendMessageW(g_window, WM_LBUTTONUP, 0, at);
  } else if (!strcmp(command, "type")) {
    int n = MultiByteToWideChar(CP_UTF8, 0, arg, -1, NULL, 0);
    wchar_t *w = malloc((size_t)n * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, arg, -1, w, n);
    for (int i = 0; i + 1 < n; i++) SendMessageW(g_window, WM_CHAR, w[i], 1);
    free(w);
  } else if (!strcmp(command, "vkey")) {
    test_vkey(arg);
  } else if (!strcmp(command, "wheel")) {
    test_wheel(-atoi(arg) * WHEEL_DELTA);
  } else if (!strcmp(command, "touchpad")) {
    // Thirds of a notch, which is three lines of 16 points.
    int thirds = (int)lround(atof(arg) / 16.0);
    for (int i = 0; i < abs(thirds); i++) test_wheel(thirds < 0 ? WHEEL_DELTA / 3 : -WHEEL_DELTA / 3);
  } else if (!strcmp(command, "scrolled")) {
    fprintf(stderr, "shell: test: scrolled %.1f points, %.1f lines\n", g_test_scrolled_points, g_test_scrolled_lines);
  } else if (!strcmp(command, "snapshot")) {
    app_take_snapshot();
  } else if (!strcmp(command, "minimize")) {
    ShowWindow(g_window, SW_MINIMIZE);
  } else if (!strcmp(command, "restore")) {
    ShowWindow(g_window, SW_RESTORE);
    request_redraw();
  } else if (!strcmp(command, "endmenu")) {
    fprintf(stderr, "shell: test: %d modal loops, ending the menu\n", g_modal_loops);
    EndMenu();
  } else if (!strcmp(command, "endsession")) {
    if (SendMessageW(g_window, WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF)) SendMessageW(g_window, WM_ENDSESSION, TRUE, ENDSESSION_LOGOFF);
  } else {
    return false;
  }
  return true;
}

void os_arm_test_timer(double after) { arm_timer(g_test_timer, after); }

// App

// A release build has the windows subsystem, so a launch from Explorer or
// the Start menu has no stderr. The app's log then goes to tidalfast.log
// in %LOCALAPPDATA%\tidalfast, which src/app/logging_windows.odin opens
// before shell_main runs, and the shell's own lines go to the end of the
// same file.
static bool g_no_stderr;

static void log_to_file(void) {
  HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
  g_no_stderr = !err || err == INVALID_HANDLE_VALUE;
  if (!g_no_stderr) return;
  // Windows sets LOCALAPPDATA for every session; the app looks there first
  // too (os_services.cache_dir).
  wchar_t dir[MAX_PATH];
  DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return;
  wchar_t path[MAX_PATH + 32];
  _snwprintf(path, sizeof path / sizeof path[0], L"%ls\\tidalfast\\tidalfast.log", dir);
  path[sizeof path / sizeof path[0] - 1] = 0;
  _wfreopen(path, L"a", stderr);
}

// fatal is for an error the app can't start after. Without a console to
// show it in, it shows in a message box too.
static void fatal(const char *message) {
  fprintf(stderr, "shell: %s\n", message);
  if (!g_no_stderr) return;
  int n = MultiByteToWideChar(CP_UTF8, 0, message, -1, NULL, 0);
  wchar_t *w = malloc((size_t)n * sizeof(wchar_t));
  MultiByteToWideChar(CP_UTF8, 0, message, -1, w, n);
  MessageBoxW(NULL, w, L"TIDALfast can't start", MB_OK | MB_ICONERROR);
  free(w);
}

static void *reserve(size_t size) {
  // Committed but untouched pages take no RAM until written, and start
  // zeroed, as mmap's do. They count toward the commit charge, the
  // process's private bytes, from the start.
  void *p = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
  if (!p) {
    char message[128];
    snprintf(message, sizeof message, "couldn't reserve %zu MB of memory, error %lu", size >> 20, GetLastError());
    fatal(message);
    exit(1);
  }
  return p;
}

// shut_down runs the app's shutdown once, which saves the settings. The
// main loop runs it when it quits, and WM_ENDSESSION when Windows ends the
// session first. A frame can't be re-entered, so inside one it only asks
// the main loop to quit, which runs it as soon as the frame is done.
static void shut_down(void) {
  atomic_store(&g_quit, true);
  SetEvent(g_redraw_event);
  if (g_shut_down || g_in_frame || !g_app_started) return;
  g_shut_down = true;
  g_app_started = false; // no frames after it
  app_shutdown(&g_memory);
  SetEvent(g_shutdown_done);
}

// Ctrl-C in the console, and SIGTERM, which the app raises to quit cleanly
// (sys.quit), quit through the main loop so the app's shutdown runs.
static void quit_signal(int sig) {
  atomic_store(&g_quit, true);
  SetEvent(g_redraw_event);
  signal(sig, quit_signal);
}

// The console calls this on a thread of its own. Closing the console ends
// the process as soon as it returns, so it waits for the shutdown first,
// for a little less than the five seconds Windows gives it.
static BOOL WINAPI console_handler(DWORD type) {
  if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT) {
    atomic_store(&g_quit, true);
    SetEvent(g_redraw_event);
    if (type == CTRL_CLOSE_EVENT) WaitForSingleObject(g_shutdown_done, 4500);
    return TRUE;
  }
  return FALSE;
}

static bool open_window(void) {
  HINSTANCE instance = GetModuleHandleW(NULL);
  WNDCLASSEXW wc = {
      .cbSize = sizeof wc,
      .style = CS_OWNDC,
      .lpfnWndProc = window_proc,
      .hInstance = instance,
      .hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1)),
      .hCursor = LoadCursorW(NULL, IDC_ARROW),
      .lpszClassName = L"TIDALfast",
  };
  char message[128];
  if (!RegisterClassExW(&wc)) {
    snprintf(message, sizeof message, "RegisterClassEx failed, error %lu", GetLastError());
    fatal(message);
    return false;
  }
  // The window opens at its default size in points, on the monitor the
  // system picks, at that monitor's DPI.
  POINT origin = {0, 0};
  UINT dpi = 96;
  HMONITOR monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  UINT dpi_x, dpi_y;
  HMODULE shcore = LoadLibraryW(L"shcore.dll");
  typedef HRESULT(WINAPI * Get_Dpi)(HMONITOR, int, UINT *, UINT *);
  Get_Dpi get_dpi = shcore ? (Get_Dpi)(void *)GetProcAddress(shcore, "GetDpiForMonitor") : NULL;
  if (get_dpi && get_dpi(monitor, 0, &dpi_x, &dpi_y) == S_OK) dpi = dpi_x;
  RECT r = {0, 0, (LONG)(DEFAULT_WIDTH * dpi / 96), (LONG)(DEFAULT_HEIGHT * dpi / 96)};
  AdjustWindowRectExForDpi(&r, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
  g_window = CreateWindowExW(0, L"TIDALfast", L"TIDALfast", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left,
                             r.bottom - r.top, NULL, NULL, instance, NULL);
  if (!g_window) {
    snprintf(message, sizeof message, "CreateWindowEx failed, error %lu", GetLastError());
    fatal(message);
    return false;
  }
  // A dark title bar, to go with the app. Windows 10 before 20H1 has no
  // such attribute and ignores it.
  BOOL dark = TRUE;
  DwmSetWindowAttribute(g_window, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark);
  g_surface_info = (Win32_Surface){.instance = instance, .window = g_window};
  // No text field has the focus yet, so no input method.
  ime_enable(false);
  update_size();
  return true;
}

static void pump_messages(void) {
  MSG msg;
  while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
    if (msg.message == WM_QUIT) {
      atomic_store(&g_quit, true);
      continue;
    }
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
}

static void main_loop(void) {
  while (!atomic_load(&g_quit)) {
    // A frame is due when something asked for one or the app animates;
    // otherwise wait for a message, a request or a timer. A due frame
    // draws at once, and present's vsync wait paces it. A minimized window
    // doesn't animate, since its present doesn't wait, but it still draws
    // the frames asked for, in which the app does its work.
    bool due = atomic_load(&g_needs_redraw) || animating();
    HANDLE handles[3];
    DWORD n = 0, timeout = INFINITE;
    if (!due) {
      handles[n++] = g_redraw_event;
      handles[n++] = g_wake_timer;
    }
    handles[n++] = g_test_timer;
    if (due) timeout = 0;
    DWORD r = MsgWaitForMultipleObjectsEx(n, handles, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    HANDLE signalled = r < WAIT_OBJECT_0 + n ? handles[r - WAIT_OBJECT_0] : NULL;
    if (signalled == g_wake_timer) atomic_store(&g_needs_redraw, true);
    if (signalled == g_test_timer) run_due_steps();
    pump_messages();
    if (atomic_load(&g_quit)) break;
    if (atomic_load(&g_needs_redraw) || animating()) draw_frame();
  }
}

int shell_main(int argc, char **argv) {
  log_to_file();
  // The CRT buffers stderr whole when it isn't a console, and the app
  // leaves through ExitProcess, which doesn't flush it: a log sent to a
  // file or a pipe would lose the shell's lines.
  setvbuf(stderr, NULL, _IONBF, 0);
  QueryPerformanceFrequency(&g_qpc_frequency);
  measure_init();
  measure_mark("main");
  const char *capture = getenv("TIDALFAST_CAPTURE");
  g_capture = capture && *capture;
  g_start_time = now_seconds();
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

  g_memory = (Memory){
      .persistent = reserve(PERSISTENT_SIZE),
      .persistent_size = PERSISTENT_SIZE,
      .frame = reserve(FRAME_SIZE),
      .frame_size = FRAME_SIZE,
  };

  g_redraw_event = CreateEventW(NULL, FALSE, FALSE, NULL);
  g_shutdown_done = CreateEventW(NULL, TRUE, FALSE, NULL);
  g_wake_timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  if (!g_wake_timer) g_wake_timer = CreateWaitableTimerW(NULL, FALSE, NULL);
  g_test_timer = CreateWaitableTimerW(NULL, FALSE, NULL);
  signal(SIGTERM, quit_signal);
  signal(SIGINT, quit_signal);
  SetConsoleCtrlHandler(console_handler, TRUE);

  if (!open_window()) return 1;
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

  measure_mark("app_start");
  app_init(&g_memory, &g_shell);
  g_app_started = true;
  // The first frame goes up before the window shows, so it never flashes
  // an empty client area.
  draw_frame();
  ShowWindow(g_window, SW_SHOWDEFAULT);
  UpdateWindow(g_window);
  measure_mark("window");
  setup_shell_test();
  request_redraw();
  main_loop();
  shut_down();
  DestroyWindow(g_window);
  return 0;
}
