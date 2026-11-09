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
// all. Once a frame is due, it waits on the swap chain's frame latency
// object (Win32_Surface.frame_ready) with the messages still coming in,
// so the frame starts when the swap chain can take it, with the newest
// input, and present doesn't block. That paces animation to the display.
// While the user drags the window's edge or title,
// Windows runs its own modal loop and the main loop doesn't run; a timer
// draws from inside it, so the window keeps up with the drag.
//
// Text comes from WM_CHAR, and from an input method through IMM32: the
// composition string becomes marked text and the result string is
// inserted, as NSTextInputClient does on macOS. Keys are mapped by their
// scan code, the key's place on the keyboard. Not here yet: accessibility
// (UI Automation), Now Playing and the media overlay (System Media
// Transport Controls), drag and drop and touchpad momentum (Windows sends
// precision touchpad scrolls as fine wheel deltas, which arrive as precise
// scrolls without phases).

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
#define LIVE_RESIZE_TIMER 1

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
static bool g_minimized; // no frames until restored, unless TIDALFAST_CAPTURE is set
static bool g_capture;
// The swap chain's frame_ready was waited on and no frame has been
// presented since, so the next frame doesn't wait for it again.
static bool g_ready_taken;

static HANDLE g_redraw_event; // set by request_redraw
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

// Frames

static void draw_frame(void) {
  if (!g_app_started) return;
  atomic_store(&g_needs_redraw, false);
  ResetEvent(g_redraw_event);
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
      .mouse_buttons = (GetKeyState(VK_LBUTTON) < 0 ? 1u << MOUSE_BUTTON_LEFT : 0) |
                       (GetKeyState(VK_RBUTTON) < 0 ? 1u << MOUSE_BUTTON_RIGHT : 0) |
                       (GetKeyState(VK_MBUTTON) < 0 ? 1u << MOUSE_BUTTON_MIDDLE : 0) |
                       (GetKeyState(VK_XBUTTON1) < 0 ? 1u << MOUSE_BUTTON_BACK : 0) |
                       (GetKeyState(VK_XBUTTON2) < 0 ? 1u << MOUSE_BUTTON_FORWARD : 0),
  };
  uint64_t presents = g_surface_info.presents;
  Frame_Result result = app_frame(&g_memory, &g_shell, &input);
  if (g_surface_info.presents != presents) g_ready_taken = false;
  g_event_count = 0;
  g_text_len = 0;
  g_animating = result.animating;
  arm_timer(g_wake_timer, result.wake_after > 0 ? result.wake_after : 0);
}

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

// Keys by scan code, the key's place on the keyboard, as the Linux shell
// maps evdev codes (evdev codes are scan code set 1 for these). Extended
// keys (arrows, Home, the keypad's Enter) have the E0 prefix, here 0x100.
static uint32_t key_of_scan(uint32_t scan) {
  static const uint8_t keys[0x60] = {
      [0x1e] = KEY_A, [0x30] = KEY_B, [0x2e] = KEY_C, [0x20] = KEY_D, [0x12] = KEY_E, [0x21] = KEY_F, [0x22] = KEY_G,
      [0x23] = KEY_H, [0x17] = KEY_I, [0x24] = KEY_J, [0x25] = KEY_K, [0x26] = KEY_L, [0x32] = KEY_M, [0x31] = KEY_N,
      [0x18] = KEY_O, [0x19] = KEY_P, [0x10] = KEY_Q, [0x13] = KEY_R, [0x1f] = KEY_S, [0x14] = KEY_T, [0x16] = KEY_U,
      [0x2f] = KEY_V, [0x11] = KEY_W, [0x2d] = KEY_X, [0x15] = KEY_Y, [0x2c] = KEY_Z,
      [0x0b] = KEY_DIGIT_0, [0x02] = KEY_DIGIT_1, [0x03] = KEY_DIGIT_2, [0x04] = KEY_DIGIT_3, [0x05] = KEY_DIGIT_4,
      [0x06] = KEY_DIGIT_5, [0x07] = KEY_DIGIT_6, [0x08] = KEY_DIGIT_7, [0x09] = KEY_DIGIT_8, [0x0a] = KEY_DIGIT_9,
      [0x1c] = KEY_RETURN, [0x0f] = KEY_TAB, [0x39] = KEY_SPACE, [0x0e] = KEY_BACKSPACE, [0x01] = KEY_ESCAPE,
      [0x29] = KEY_GRAVE,
      [0x3b] = KEY_F1, [0x3c] = KEY_F2, [0x3d] = KEY_F3, [0x3e] = KEY_F4, [0x3f] = KEY_F5, [0x40] = KEY_F6,
      [0x41] = KEY_F7, [0x42] = KEY_F8, [0x43] = KEY_F9, [0x44] = KEY_F10, [0x57] = KEY_F11, [0x58] = KEY_F12,
  };
  switch (scan) {
  case 0x11c: return KEY_KEYPAD_ENTER;
  case 0x153: return KEY_DELETE;
  case 0x147: return KEY_HOME;
  case 0x14f: return KEY_END;
  case 0x149: return KEY_PAGE_UP;
  case 0x151: return KEY_PAGE_DOWN;
  case 0x14b: return KEY_LEFT;
  case 0x14d: return KEY_RIGHT;
  case 0x148: return KEY_UP;
  case 0x150: return KEY_DOWN;
  }
  return scan < sizeof keys ? keys[scan] : KEY_NONE;
}

static uint32_t scan_of(LPARAM lp) {
  uint32_t scan = (uint32_t)(lp >> 16) & 0xff;
  if (lp & (1 << 24)) scan |= 0x100;
  return scan;
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
    SetCapture(g_window);
  } else if (!(GetKeyState(VK_LBUTTON) < 0 || GetKeyState(VK_RBUTTON) < 0 || GetKeyState(VK_MBUTTON) < 0)) {
    ReleaseCapture();
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

static bool g_composing;

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
    LONG units;
    char *s = ime_string(imc, GCS_RESULTSTR, &units);
    text_insert(s, -1, -1);
    free(s);
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

static void set_text_input(const Text_Input *ti) {
  bool was_marked = g_ti.marked_start >= 0;
  if (!mirror_set(ti)) return;
  HIMC imc = ImmGetContext(g_window);
  if (!imc) return;
  if (g_ti.active) {
    place_candidates(imc);
  } else {
    ImmNotifyIME(imc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
    g_composing = false;
  }
  if (g_composing && was_marked && g_ti.marked_start < 0) {
    // The app ended the composition as it was.
    ImmNotifyIME(imc, NI_COMPOSITIONSTR, CPS_COMPLETE, 0);
    g_composing = false;
  }
  ImmReleaseContext(g_window, imc);
}

// Clipboard: UTF-16 text on the system clipboard, CF_UNICODETEXT.

static void set_clipboard(const uint8_t *text, size_t length) {
  if (!OpenClipboard(g_window)) return;
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
  if (!OpenClipboard(g_window)) return 0;
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

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_CLOSE:
    atomic_store(&g_quit, true);
    return 0;
  case WM_SIZE:
    g_minimized = wp == SIZE_MINIMIZED;
    // One frame as the window goes, for the renderer to see it's minimized
    // and give back its buffers. Then none until it's restored.
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
    SetTimer(hwnd, LIVE_RESIZE_TIMER, 8, NULL);
    return 0;
  case WM_EXITSIZEMOVE:
    g_in_size_move = false;
    KillTimer(hwnd, LIVE_RESIZE_TIMER);
    return 0;
  case WM_TIMER:
    if (wp == LIVE_RESIZE_TIMER && (atomic_load(&g_needs_redraw) || g_animating)) draw_frame();
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
    // Alt+F4 and the rest of the system's keys stay the system's.
    if (msg == WM_SYSKEYDOWN && wp == VK_F4) break;
    if (wp == VK_SHIFT || wp == VK_CONTROL || wp == VK_MENU || wp == VK_LWIN || wp == VK_RWIN || wp == VK_CAPITAL) return 0;
    if (wp == VK_PROCESSKEY || types_text(wp)) {
      // WM_CHAR or the input method brings the text.
      if (msg == WM_SYSKEYDOWN) break;
      return 0;
    }
    push_event((Event){
        .kind = EVENT_KEY_DOWN,
        .modifiers = g_modifiers,
        .time = now_seconds(),
        .key = key_of_scan(scan_of(lp)),
        .repeat = (lp & (1 << 30)) != 0,
    });
    return 0;
  }
  case WM_KEYUP:
  case WM_SYSKEYUP:
    modifiers_changed();
    // Alt up returns here too, so there's no menu bar to activate.
    if (wp == VK_SHIFT || wp == VK_CONTROL || wp == VK_MENU || wp == VK_LWIN || wp == VK_RWIN || wp == VK_CAPITAL) return 0;
    push_event((Event){.kind = EVENT_KEY_UP, .modifiers = g_modifiers, .time = now_seconds(), .key = key_of_scan(scan_of(lp))});
    return 0;
  case WM_CHAR:
    on_char((wchar_t)wp);
    return 0;
  case WM_SYSCHAR:
    return 0; // no beep for Alt shortcuts
  case WM_IME_STARTCOMPOSITION:
    g_composing = true;
    return 0;
  case WM_IME_COMPOSITION:
    ime_composition(lp);
    return 0; // drawn by the app, not in the input method's own window
  case WM_IME_ENDCOMPOSITION:
    if (g_ti.marked_start >= 0) text_set_marked("", 0, 0, -1, -1);
    g_composing = false;
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
//   vkey=name           WM_KEYDOWN and WM_KEYUP for a key: escape, return, backspace, left, right, a to z
//   wheel=n             n wheel notches down, negative for up, where the pointer is
//   touchpad=dy         a precision touchpad scroll moving content up by dy points
//   scrolled            print the scroll the app was sent: points from touchpads, lines from wheels
//   snapshot            ask the app for a memory snapshot, as SIGUSR1 does elsewhere
//   minimize, restore   minimize the window, and show it again

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
    static const struct {
      const char *name;
      UINT vk;
    } keys[] = {{"escape", VK_ESCAPE}, {"return", VK_RETURN}, {"backspace", VK_BACK}, {"left", VK_LEFT}, {"right", VK_RIGHT}};
    UINT vk = 0;
    for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
      if (!strcmp(keys[i].name, arg)) vk = keys[i].vk;
    if (!vk && strlen(arg) == 1 && arg[0] >= 'a' && arg[0] <= 'z') vk = (UINT)(arg[0] - 'a' + 'A');
    if (!vk) {
      fprintf(stderr, "shell: test: no key named %s\n", arg);
      return true;
    }
    UINT scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    LPARAM extended = (vk == VK_LEFT || vk == VK_RIGHT) ? (1 << 24) : 0;
    SendMessageW(g_window, WM_KEYDOWN, vk, 1 | (LPARAM)scan << 16 | extended);
    SendMessageW(g_window, WM_KEYUP, vk, 1 | (LPARAM)scan << 16 | extended | (LPARAM)3 << 30);
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
  } else {
    return false;
  }
  return true;
}

void os_arm_test_timer(double after) { arm_timer(g_test_timer, after); }

// App

static void *reserve(size_t size) {
  // Committed but untouched pages take no RAM until written, and start
  // zeroed, as mmap's do. They count toward the commit charge, the
  // process's private bytes, from the start.
  void *p = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
  if (!p) {
    fprintf(stderr, "shell: VirtualAlloc of %zu bytes failed\n", size);
    exit(1);
  }
  return p;
}

// Ctrl-C in the console, and SIGTERM, which the app raises to quit cleanly
// (sys.quit), quit through the main loop so the app's shutdown runs.
static void quit_signal(int sig) {
  atomic_store(&g_quit, true);
  SetEvent(g_redraw_event);
  signal(sig, quit_signal);
}

static BOOL WINAPI console_handler(DWORD type) {
  if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT) {
    atomic_store(&g_quit, true);
    SetEvent(g_redraw_event);
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
  if (!RegisterClassExW(&wc)) {
    fprintf(stderr, "shell: RegisterClassEx failed: %lu\n", GetLastError());
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
    fprintf(stderr, "shell: CreateWindowEx failed: %lu\n", GetLastError());
    return false;
  }
  // A dark title bar, to go with the app. Windows 10 before 20H1 has no
  // such attribute and ignores it.
  BOOL dark = TRUE;
  DwmSetWindowAttribute(g_window, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark);
  g_surface_info = (Win32_Surface){.instance = instance, .window = g_window};
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
    // A frame is due when something asked for one; otherwise wait for a
    // message, a request or a timer. A due frame waits until the swap
    // chain can take it (frame_ready), once per present, or draws at once
    // where there's nothing to wait on and present's vsync wait paces it.
    // A minimized window draws nothing and waits only for messages and
    // test steps; restoring it asks for a frame.
    bool hidden = g_minimized && !g_capture;
    bool due = !hidden && (atomic_load(&g_needs_redraw) || g_animating);
    HANDLE ready = (HANDLE)g_surface_info.frame_ready;
    bool wait_ready = due && ready && !g_ready_taken;
    HANDLE handles[3];
    DWORD n = 0, timeout = INFINITE;
    if (!hidden && !due) {
      handles[n++] = g_redraw_event;
      handles[n++] = g_wake_timer;
    }
    handles[n++] = g_test_timer;
    if (wait_ready) {
      // A swap chain whose frames go nowhere may never signal it.
      handles[n++] = ready;
      timeout = 100;
    } else if (due) {
      timeout = 0;
    }
    DWORD r = MsgWaitForMultipleObjectsEx(n, handles, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    HANDLE signalled = r < WAIT_OBJECT_0 + n ? handles[r - WAIT_OBJECT_0] : NULL;
    if (signalled == g_wake_timer) atomic_store(&g_needs_redraw, true);
    if (signalled == g_test_timer) run_due_steps();
    if (signalled == ready && ready) g_ready_taken = true;
    pump_messages();
    if (atomic_load(&g_quit)) break;
    // Input that came while the frame waited for the swap chain goes into
    // that frame, once the swap chain can take it.
    bool may_draw = !wait_ready || g_ready_taken || r == WAIT_TIMEOUT;
    if (!(g_minimized && !g_capture) && (atomic_load(&g_needs_redraw) || g_animating) && may_draw) draw_frame();
  }
}

int shell_main(int argc, char **argv) {
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

  g_redraw_event = CreateEventW(NULL, TRUE, FALSE, NULL);
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
  app_shutdown(&g_memory);
  DestroyWindow(g_window);
  return 0;
}
