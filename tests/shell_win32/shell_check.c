// A check of the Windows shell without the app: shell/shell_win32.c and
// shell/common.c linked with a stub app, run on Windows or under Wine (see
// run.sh). A driver thread does what a person, Windows or the app's own
// threads would: keys, a minimized window, a redraw asked for from another
// thread, the system menu, a clipboard another app holds, the window's top
// and its buttons, which the app draws, the end of the session. The stub app records what each frame got, and the driver checks
// it. Each check prints PASS or FAIL; the exit code is the failures.
//
// It goes through the shell's real entry points (window messages and the
// Shell callbacks), so it builds against an older shell_win32.c too and
// shows what that one got wrong.

#include "../../shell/shell_win32.c"

#include <process.h>

#define MAX_SEEN 256

static CRITICAL_SECTION g_lock;
static Event g_seen[MAX_SEEN]; // key, text and mouse events, in order
static int g_seen_count;
static volatile LONG g_frames;
static volatile LONG g_shutdowns;
static int g_failures;
static bool g_endsession_run;
static WNDPROC g_shell_proc;
static volatile LONG g_keymenus; // WM_SYSCOMMAND SC_KEYMENU, which opens the system menu

// What the driver asks the next frame to do, on the UI thread.
static volatile LONG g_ask;
enum {
  ASK_NONE,
  ASK_TEXT_FIELD, // focus a text field
  ASK_NO_TEXT_FIELD,
  ASK_REENTER, // send the window a key from inside the frame
  ASK_STRAY_EVENT, // set the redraw event with no redraw pending
  ASK_WAKE, // wake_after 0.05
  ASK_ANIMATE, // say it's animating
  ASK_COPY, // set the clipboard
  ASK_END_MENU,
};
static volatile LONG g_ime_context; // whether the window had an input method context, -1 before asked
static volatile LONG g_menu_allowed; // let SC_KEYMENU open the system menu
static volatile LONG g_menu_open; // between WM_ENTERMENULOOP and WM_EXITMENULOOP
static volatile LONG g_window_flags = -1; // the last frame's Frame_Input.window
static volatile LONG g_titlebar_height; // and its titlebar_height, in points
static Shell *g_stub_shell;

// The stub app's top: a 50 point room whose empty part moves the window,
// and the window's three buttons, 46 points wide, at its right.
#define STUB_TOP 50.0f
#define STUB_BUTTON 46.0f

static void check(bool ok, const char *name, const char *detail) {
  fprintf(stdout, "%s %s%s%s\n", ok ? "PASS" : "FAIL", name, ok || !detail ? "" : ": ", ok || !detail ? "" : detail);
  fflush(stdout);
  if (!ok) g_failures++;
}

static LONG frames(void) { return InterlockedCompareExchange(&g_frames, 0, 0); }

// Waits up to ms for a frame after `after`, true if one came.
static bool frame_after(LONG after, int ms) {
  for (int i = 0; i < ms / 5; i++) {
    if (frames() > after) return true;
    Sleep(5);
  }
  return frames() > after;
}

static void clear_seen(void) {
  EnterCriticalSection(&g_lock);
  g_seen_count = 0;
  LeaveCriticalSection(&g_lock);
}

static int seen_key(uint32_t kind, uint32_t key) {
  int n = 0;
  EnterCriticalSection(&g_lock);
  for (int i = 0; i < g_seen_count; i++)
    if (g_seen[i].kind == kind && g_seen[i].key == key) n++;
  LeaveCriticalSection(&g_lock);
  return n;
}

static uint32_t first_key_down(void) {
  uint32_t key = KEY_COUNT;
  EnterCriticalSection(&g_lock);
  for (int i = 0; i < g_seen_count; i++)
    if (g_seen[i].kind == EVENT_KEY_DOWN) {
      key = g_seen[i].key;
      break;
    }
  LeaveCriticalSection(&g_lock);
  return key;
}

// Asks the next frame to do something and waits until it has.
static void ask(LONG what) {
  InterlockedExchange(&g_ask, what);
  request_redraw();
  for (int i = 0; i < 400 && InterlockedCompareExchange(&g_ask, 0, 0) != ASK_NONE; i++) Sleep(5);
}

// The stub app

static Text_Input g_field = {.text = (const uint8_t *)"", .marked_start = -1, .marked_end = -1, .caret = {10, 10, 1, 16}};
static bool g_field_on;

void app_init(Memory *mem, Shell *shell) {}

Frame_Result app_frame(Memory *mem, Shell *shell, Frame_Input *input) {
  EnterCriticalSection(&g_lock);
  for (uint32_t i = 0; i < input->event_count; i++) {
    Event e = input->events[i];
    bool kept = e.kind == EVENT_KEY_DOWN || e.kind == EVENT_KEY_UP || e.kind == EVENT_TEXT || e.kind == EVENT_MOUSE_MOVE ||
                e.kind == EVENT_MOUSE_DOWN || e.kind == EVENT_MOUSE_UP || e.kind == EVENT_MOUSE_LEAVE;
    if (kept && g_seen_count < MAX_SEEN) g_seen[g_seen_count++] = e;
  }
  LeaveCriticalSection(&g_lock);
  InterlockedExchange(&g_window_flags, (LONG)input->window);
  InterlockedExchange(&g_titlebar_height, (LONG)input->titlebar_height);
  g_stub_shell = shell;
  float w = input->width;
  float buttons[3][4] = {{w - 3 * STUB_BUTTON, 0, STUB_BUTTON, STUB_TOP}, {w - 2 * STUB_BUTTON, 0, STUB_BUTTON, STUB_TOP}, {w - STUB_BUTTON, 0, STUB_BUTTON, STUB_TOP}};
  float drag[1][4] = {{0, 0, w - 3 * STUB_BUTTON, STUB_TOP}};
  // An older shell has neither.
  if (shell->set_window_buttons) shell->set_window_buttons((const float(*)[4])buttons, 3);
  if (shell->set_drag_regions) shell->set_drag_regions((const float(*)[4])drag, 1);
  Frame_Result result = {0};
  LONG what = InterlockedExchange(&g_ask, ASK_NONE);
  switch (what) {
  case ASK_TEXT_FIELD: g_field_on = true; break;
  case ASK_NO_TEXT_FIELD: g_field_on = false; break;
  case ASK_REENTER:
    // As a sent message from another thread or an input method's answer
    // can, while the app is inside the frame.
    SendMessageW(g_window, WM_KEYDOWN, VK_F5, 1 | 0x3f << 16);
    SendMessageW(g_window, WM_KEYUP, VK_F5, 1 | 0x3f << 16 | 3u << 30);
    break;
  case ASK_STRAY_EVENT:
    // As when request_redraw on another thread sets the event just after
    // the frame took its request.
    SetEvent(g_redraw_event);
    break;
  case ASK_WAKE: result.wake_after = 0.05f; break;
  case ASK_ANIMATE: result.animating = 1; break;
  case ASK_COPY: shell->set_clipboard((const uint8_t *)"copied", 6); break;
  case ASK_END_MENU: EndMenu(); break;
  }
  shell->set_text_input(g_field_on ? &g_field : NULL);
  HIMC imc = ImmGetContext(g_window);
  InterlockedExchange(&g_ime_context, imc != NULL);
  if (imc) ImmReleaseContext(g_window, imc);
  InterlockedIncrement(&g_frames);
  return result;
}

void app_shutdown(Memory *mem) { InterlockedIncrement(&g_shutdowns); }

void app_take_snapshot(void) {}

static LRESULT CALLBACK spy_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_ENTERMENULOOP) InterlockedExchange(&g_menu_open, 1);
  if (msg == WM_EXITMENULOOP) InterlockedExchange(&g_menu_open, 0);
  if (msg == WM_SYSCOMMAND && (wp & 0xfff0) == SC_KEYMENU && lp == ' ' && !InterlockedCompareExchange(&g_menu_allowed, 0, 0)) {
    // Seen, and kept from opening the menu, which would wait for a person.
    InterlockedIncrement(&g_keymenus);
    return 0;
  }
  return CallWindowProcW(g_shell_proc, hwnd, msg, wp, lp);
}

// The driver

static void key(UINT msg, WPARAM vk, UINT scan, bool extended) {
  LPARAM lp = 1 | (LPARAM)scan << 16 | (extended ? 1 << 24 : 0) | (msg == WM_SYSKEYDOWN || msg == WM_SYSCHAR ? 1 << 29 : 0);
  SendMessageW(g_window, msg, vk, lp);
}

static void press(WPARAM vk, UINT scan, bool extended) {
  clear_seen();
  LONG before = frames();
  key(WM_KEYDOWN, vk, scan, extended);
  SendMessageW(g_window, WM_KEYUP, vk, 1 | (LPARAM)scan << 16 | (extended ? 1 << 24 : 0) | 3u << 30);
  frame_after(before, 500);
}

static void check_keys(void) {
  char detail[96];
  // The key in the US Z place types Y on a German keyboard, and Windows
  // gives it VK_Y. Control+Y must be redo there, not undo.
  press('Y', 0x2c, false);
  snprintf(detail, sizeof detail, "got key %u, want %u (Y)", first_key_down(), KEY_Y);
  check(first_key_down() == KEY_Y, "keys: QWERTZ's Y is Y", detail);
  // French AZERTY: Q is where US A is.
  press('Q', 0x1e, false);
  snprintf(detail, sizeof detail, "got key %u, want %u (Q)", first_key_down(), KEY_Q);
  check(first_key_down() == KEY_Q, "keys: AZERTY's Q is Q", detail);
  // AZERTY's comma is in the US M place; it isn't M.
  press(VK_OEM_COMMA, 0x32, false);
  snprintf(detail, sizeof detail, "got key %u, want %u (none)", first_key_down(), KEY_NONE);
  check(first_key_down() == KEY_NONE || first_key_down() == KEY_COUNT, "keys: AZERTY's comma isn't M", detail);
  // Dvorak's J is where US C is.
  press('J', 0x2e, false);
  snprintf(detail, sizeof detail, "got key %u, want %u (J)", first_key_down(), KEY_J);
  check(first_key_down() == KEY_J, "keys: Dvorak's J is J", detail);
  // A Cyrillic layout gives the US C place VK_C: Control+C still copies.
  press('C', 0x2e, false);
  check(first_key_down() == KEY_C, "keys: Cyrillic's VK_C is C", NULL);
  // The keypad's 7 with NumLock off is Home, without the E0 prefix.
  press(VK_HOME, 0x47, false);
  snprintf(detail, sizeof detail, "got key %u, want %u (home)", first_key_down(), KEY_HOME);
  check(first_key_down() == KEY_HOME, "keys: keypad Home with NumLock off", detail);
  press(VK_RETURN, 0x1c, true);
  check(first_key_down() == KEY_KEYPAD_ENTER, "keys: keypad Enter", NULL);
  press(VK_OEM_3, 0x29, false);
  check(first_key_down() == KEY_GRAVE, "keys: the key under Escape is grave", NULL);
}

static void check_alt_space(void) {
  clear_seen();
  LONG before = frames();
  key(WM_SYSKEYDOWN, VK_SPACE, 0x39, false);
  key(WM_SYSCHAR, ' ', 0x39, false);
  SendMessageW(g_window, WM_SYSKEYUP, VK_SPACE, 1 | 0x39 << 16 | 1 << 29 | 3u << 30);
  frame_after(before, 300);
  check(InterlockedCompareExchange(&g_keymenus, 0, 0) == 1, "alt+space opens the system menu", "no SC_KEYMENU");
  check(seen_key(EVENT_KEY_DOWN, KEY_SPACE) == 0, "alt+space doesn't reach the app", NULL);
}

static void check_ime(void) {
  ask(ASK_NONE);
  request_redraw();
  Sleep(50);
  check(InterlockedCompareExchange(&g_ime_context, 0, 0) == 0, "input method off without a text field", NULL);
  ask(ASK_TEXT_FIELD);
  request_redraw();
  Sleep(50);
  check(InterlockedCompareExchange(&g_ime_context, 0, 0) == 1, "input method on in a text field", NULL);
  ask(ASK_NO_TEXT_FIELD);
  request_redraw();
  Sleep(50);
  check(InterlockedCompareExchange(&g_ime_context, 0, 0) == 0, "input method off again after it", NULL);
}

static void check_reentry(void) {
  clear_seen();
  ask(ASK_REENTER);
  Sleep(100);
  check(seen_key(EVENT_KEY_DOWN, KEY_F5) == 1, "a key sent from inside a frame reaches the next one", NULL);
}

static double cpu_seconds(void) {
  FILETIME created, exited, kernel, user;
  GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user);
  uint64_t k = ((uint64_t)kernel.dwHighDateTime << 32) | kernel.dwLowDateTime;
  uint64_t u = ((uint64_t)user.dwHighDateTime << 32) | user.dwLowDateTime;
  return (double)(k + u) / 1e7;
}

static void check_stray_event(void) {
  ask(ASK_STRAY_EVENT);
  Sleep(50);
  double cpu = cpu_seconds();
  LONG before = frames();
  Sleep(500);
  char detail[96];
  snprintf(detail, sizeof detail, "%.0f ms of CPU in 500 ms idle", (cpu_seconds() - cpu) * 1000);
  check(cpu_seconds() - cpu < 0.1, "a stray redraw event doesn't spin", detail);
  check(frames() == before, "and draws nothing", NULL);
}

static void check_capture(void) {
  LONG before = frames();
  SendMessageW(g_window, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(50, 50));
  frame_after(before, 300);
  Sleep(30);
  before = frames();
  // As when Alt+Tab takes the mouse in the middle of a drag.
  SendMessageW(g_window, WM_CAPTURECHANGED, 0, (LPARAM)GetDesktopWindow());
  check(frame_after(before, 300), "losing the capture asks for a frame", NULL);
  SendMessageW(g_window, WM_LBUTTONUP, 0, MAKELPARAM(50, 50));
  Sleep(30);
}

static void check_minimized(void) {
  ShowWindow(g_window, SW_MINIMIZE);
  Sleep(300);
  check(IsIconic(g_window), "the window minimizes", NULL);
  LONG before = frames();
  // As the audio thread does when the track ends.
  request_redraw();
  check(frame_after(before, 500), "minimized: a redraw asked for from another thread draws", NULL);
  ask(ASK_WAKE);
  before = frames();
  check(frame_after(before, 500), "minimized: wake_after draws", NULL);
  ask(ASK_ANIMATE);
  Sleep(20);
  before = frames();
  Sleep(300);
  char detail[64];
  snprintf(detail, sizeof detail, "%ld frames in 300 ms", frames() - before);
  check(frames() - before <= 1, "minimized: animation draws nothing", detail);
}

static bool menu_open(void) { return InterlockedCompareExchange(&g_menu_open, 0, 0) != 0; }

static void check_menu(void) {
  InterlockedExchange(&g_menu_allowed, 1);
  PostMessageW(g_window, WM_SYSCOMMAND, SC_KEYMENU, ' ');
  for (int i = 0; i < 100 && !menu_open(); i++) Sleep(10);
  check(menu_open(), "the system menu opens", NULL);
  Sleep(100);
  LONG before = frames();
  request_redraw();
  check(frame_after(before, 500), "system menu: a redraw asked for draws", NULL);
  ask(ASK_END_MENU);
  // The old shell draws nothing in the menu; WM_CANCELMODE closes it.
  if (menu_open()) SendMessageW(g_window, WM_CANCELMODE, 0, 0);
  for (int i = 0; i < 100 && menu_open(); i++) Sleep(10);
  InterlockedExchange(&g_menu_allowed, 0);
}

static void check_clipboard(void) {
  // Another app holds the clipboard for a moment, as clipboard managers do
  // after each change.
  if (!OpenClipboard(NULL)) {
    check(false, "clipboard: the driver can open it", NULL);
    return;
  }
  EmptyClipboard();
  InterlockedExchange(&g_ask, ASK_COPY);
  request_redraw();
  Sleep(30);
  CloseClipboard();
  for (int i = 0; i < 100 && InterlockedCompareExchange(&g_ask, 0, 0) != ASK_NONE; i++) Sleep(5);
  Sleep(50);
  bool copied = false;
  if (OpenClipboard(NULL)) {
    HANDLE mem = GetClipboardData(CF_UNICODETEXT);
    const wchar_t *w = mem ? GlobalLock(mem) : NULL;
    copied = w && !wcscmp(w, L"copied");
    if (w) GlobalUnlock(mem);
    CloseClipboard();
  }
  check(copied, "clipboard: a copy waits for another app to let go", NULL);
}

static int seen_mouse(uint32_t kind, float *x, float *y) {
  int n = 0;
  EnterCriticalSection(&g_lock);
  for (int i = 0; i < g_seen_count; i++)
    if (g_seen[i].kind == kind) {
      n++;
      if (x) *x = g_seen[i].x, *y = g_seen[i].y;
    }
  LeaveCriticalSection(&g_lock);
  return n;
}

// A point of the client area in points, on the screen, as WM_NCHITTEST
// and the non-client mouse messages take it.
static LPARAM screen_point(float x, float y) {
  POINT p = {(LONG)lroundf(x * g_scale), (LONG)lroundf(y * g_scale)};
  ClientToScreen(g_window, &p);
  return MAKELPARAM(p.x, p.y);
}

static LRESULT hit_at(float x, float y) { return SendMessageW(g_window, WM_NCHITTEST, 0, screen_point(x, y)); }

static float client_width(void) {
  RECT c;
  GetClientRect(g_window, &c);
  return (float)c.right / g_scale;
}

static void check_window_top(void) {
  char detail[160];
  request_redraw();
  Sleep(100);
  LONG flags = InterlockedCompareExchange(&g_window_flags, 0, 0);
  check(flags >= 0 && (flags & WINDOW_FLAG_BUTTONS), "the app draws the window's buttons", NULL);
  check(InterlockedCompareExchange(&g_titlebar_height, 0, 0) > 0, "and keeps room at the top", NULL);
  RECT w;
  GetWindowRect(g_window, &w);
  POINT origin = {0, 0};
  ClientToScreen(g_window, &origin);
  snprintf(detail, sizeof detail, "client top %ld, window top %ld", origin.y, w.top);
  check(origin.y == w.top, "no titlebar: the client area starts at the window's top", detail);

  float width = client_width();
  snprintf(detail, sizeof detail, "got %ld", (long)hit_at(width / 2, 1));
  check(hit_at(width / 2, 1) == HTTOP, "the top edge resizes", detail);
  snprintf(detail, sizeof detail, "got %ld", (long)hit_at(100, 30));
  check(hit_at(100, 30) == HTCAPTION, "a drag region moves the window", detail);
  snprintf(detail, sizeof detail, "got %ld", (long)hit_at(width - 1.5f * STUB_BUTTON, 30));
  check(hit_at(width - 1.5f * STUB_BUTTON, 30) == HTMAXBUTTON, "the app's maximise button is HTMAXBUTTON, for snap layouts", detail);
  check(hit_at(width - 0.5f * STUB_BUTTON, 30) == HTCLIENT, "close is the app's", NULL);
  check(hit_at(100, 200) == HTCLIENT, "below the top is the app's", NULL);

  // The pointer over the maximise button comes as non-client messages,
  // which reach the app as ordinary ones. The shell's point step sends
  // them, and keeps the pointer there whatever the real one does.
  float mx = width - 1.5f * STUB_BUTTON, my = 30;
  clear_seen();
  LONG before = frames();
  char at[32];
  snprintf(at, sizeof at, "%.1f,%.1f", mx, my);
  os_test_step("point", at);
  frame_after(before, 300);
  float x = -1, y = -1;
  int moves = seen_mouse(EVENT_MOUSE_MOVE, &x, &y);
  snprintf(detail, sizeof detail, "%d moves, the last at %.1f, %.1f", moves, x, y);
  check(moves == 1 && fabsf(x - mx) < 1 && fabsf(y - my) < 1, "maximise button: the pointer reaches the app", detail);
  clear_seen();
  before = frames();
  SendMessageW(g_window, WM_NCLBUTTONDOWN, HTMAXBUTTON, screen_point(mx, my));
  // GetCapture only sees the calling thread's.
  GUITHREADINFO gui = {.cbSize = sizeof gui};
  GetGUIThreadInfo(GetWindowThreadProcessId(g_window, NULL), &gui);
  check(gui.hwndCapture == g_window, "maximise button: a press takes the capture", NULL);
  SendMessageW(g_window, WM_LBUTTONUP, 0, MAKELPARAM((int)(mx * g_scale), (int)(my * g_scale)));
  frame_after(before, 300);
  Sleep(30);
  check(seen_mouse(EVENT_MOUSE_DOWN, NULL, NULL) == 1 && seen_mouse(EVENT_MOUSE_UP, NULL, NULL) == 1,
        "maximise button: the press and release reach the app", NULL);
  check(!IsZoomed(g_window), "and the system doesn't act on them itself", NULL);
  clear_seen();
  before = frames();
  SendMessageW(g_window, WM_NCMOUSEMOVE, HTCAPTION, screen_point(100, 30));
  frame_after(before, 300);
  check(seen_mouse(EVENT_MOUSE_LEAVE, NULL, NULL) == 1, "off the maximise button onto a drag region, the pointer leaves the app", NULL);

  // The app's buttons ask the shell, which changes the window after the
  // frame.
  if (!g_stub_shell->window_command) {
    check(false, "the shell takes window commands", NULL);
    return;
  }
  g_stub_shell->window_command(WINDOW_COMMAND_TOGGLE_MAXIMIZE);
  for (int i = 0; i < 100 && !IsZoomed(g_window); i++) Sleep(10);
  check(IsZoomed(g_window), "maximise maximises", NULL);
  request_redraw();
  Sleep(100);
  check((InterlockedCompareExchange(&g_window_flags, 0, 0) & WINDOW_FLAG_MAXIMIZED) != 0, "and the app is told", NULL);
  MONITORINFO info = {.cbSize = sizeof info};
  GetMonitorInfoW(MonitorFromWindow(g_window, MONITOR_DEFAULTTONEAREST), &info);
  origin = (POINT){0, 0};
  ClientToScreen(g_window, &origin);
  RECT c;
  GetClientRect(g_window, &c);
  snprintf(detail, sizeof detail, "client %ld,%ld %ldx%ld, work area %ld,%ld to %ld,%ld", origin.x, origin.y, c.right, c.bottom,
           info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom);
  check(origin.y >= info.rcWork.top && origin.x >= info.rcWork.left && origin.y + c.bottom <= info.rcWork.bottom &&
            origin.x + c.right <= info.rcWork.right && origin.y - info.rcWork.top <= 2,
        "maximised, the client area fills the work area and no more", detail);
  check(hit_at(client_width() / 2, 1) != HTTOP, "maximised, the top edge doesn't resize", NULL);
  g_stub_shell->window_command(WINDOW_COMMAND_TOGGLE_MAXIMIZE);
  for (int i = 0; i < 100 && IsZoomed(g_window); i++) Sleep(10);
  check(!IsZoomed(g_window), "maximise again restores", NULL);
}

static unsigned __stdcall watchdog(void *arg) {
  Sleep(30000);
  fprintf(stdout, "FAIL timed out\n");
  fflush(stdout);
  ExitProcess(100);
}

static unsigned __stdcall driver(void *arg) {
  while (!IsWindowVisible(g_window) || frames() < 1) Sleep(10);
  Sleep(200);
  g_shell_proc = (WNDPROC)SetWindowLongPtrW(g_window, GWLP_WNDPROC, (LONG_PTR)spy_proc);
  check_keys();
  check_alt_space();
  check_ime();
  check_reentry();
  check_stray_event();
  check_capture();
  check_clipboard();
  check_menu();
  check_window_top();
  check_minimized();
  if (g_endsession_run) {
    // Logging off: the app shuts down before WM_ENDSESSION returns.
    if (SendMessageW(g_window, WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF))
      SendMessageW(g_window, WM_ENDSESSION, TRUE, ENDSESSION_LOGOFF);
    check(InterlockedCompareExchange(&g_shutdowns, 0, 0) == 1, "logging off shuts the app down", NULL);
    Sleep(200);
    if (InterlockedCompareExchange(&g_shutdowns, 0, 0) == 0) raise(SIGTERM);
  } else {
    // sys.quit raises SIGTERM; the window is still minimized.
    raise(SIGTERM);
  }
  return 0;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  g_endsession_run = argc > 1 && !strcmp(argv[1], "endsession");
  InitializeCriticalSection(&g_lock);
  InterlockedExchange(&g_ime_context, -1);
  _beginthreadex(NULL, 0, watchdog, NULL, 0, NULL);
  _beginthreadex(NULL, 0, driver, NULL, 0, NULL);
  shell_main(argc, argv);
  check(InterlockedCompareExchange(&g_shutdowns, 0, 0) == 1, g_endsession_run ? "the app shut down once" : "quitting while minimized shuts down", NULL);
  fprintf(stdout, "%d failed\n", g_failures);
  return g_failures;
}
