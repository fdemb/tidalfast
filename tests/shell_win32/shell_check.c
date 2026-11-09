// A check of the Windows shell without the app: shell/shell_win32.c and
// shell/common.c linked with a stub app, run on Windows or under Wine (see
// run.sh). A driver thread does what a person, Windows or the app's own
// threads would: keys, a minimized window, a redraw asked for from another
// thread, the system menu, a clipboard another app holds, the end of the
// session. The stub app records what each frame got, and the driver checks
// it. Each check prints PASS or FAIL; the exit code is the failures.
//
// It goes through the shell's real entry points (window messages and the
// Shell callbacks), so it builds against an older shell_win32.c too and
// shows what that one got wrong.

#include "../../shell/shell_win32.c"

#include <process.h>

#define MAX_SEEN 256

static CRITICAL_SECTION g_lock;
static Event g_seen[MAX_SEEN]; // key and text events, in order
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
static volatile LONG g_presenting; // each frame counts as a present, for check_resize_paced
static volatile LONG g_display_on; // the display thread signals frame_ready
static volatile LONG g_refreshes; // how many times it has

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
    if ((e.kind == EVENT_KEY_DOWN || e.kind == EVENT_KEY_UP || e.kind == EVENT_TEXT) && g_seen_count < MAX_SEEN) g_seen[g_seen_count++] = e;
  }
  LeaveCriticalSection(&g_lock);
  if (InterlockedCompareExchange(&g_presenting, 0, 0)) g_surface_info.presents++;
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

// A swap chain's frame latency object, as a display that refreshes every
// 16 ms signals it.
static unsigned __stdcall display(void *ready) {
  while (InterlockedCompareExchange(&g_display_on, 0, 0)) {
    Sleep(16);
    ReleaseSemaphore((HANDLE)ready, 1, NULL);
    InterlockedIncrement(&g_refreshes);
  }
  return 0;
}

// Present doesn't block on such a swap chain, so frames drawn during a drag
// must wait for the display, or the content falls behind the window. A
// resize leaves extra signals on the object, which mustn't count as the
// display being ready. Sizes change as fast as the driver can send them.
static void check_resize_paced(void) {
  HANDLE ready = CreateSemaphoreW(NULL, 8, 1024, NULL);
  InterlockedExchange(&g_presenting, 1);
  g_surface_info.frame_ready = ready;
  InterlockedExchange(&g_display_on, 1);
  HANDLE thread = (HANDLE)_beginthreadex(NULL, 0, display, ready, 0, NULL);
  SendMessageW(g_window, WM_ENTERSIZEMOVE, 0, 0);
  LONG before = frames(), refreshes = InterlockedCompareExchange(&g_refreshes, 0, 0);
  for (int i = 0; i < 30; i++)
    SetWindowPos(g_window, NULL, 0, 0, 800 + i * 4, 600, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  LONG drawn = frames() - before, shown = InterlockedCompareExchange(&g_refreshes, 0, 0) - refreshes;
  SendMessageW(g_window, WM_EXITSIZEMOVE, 0, 0);
  g_surface_info.frame_ready = NULL;
  InterlockedExchange(&g_presenting, 0);
  InterlockedExchange(&g_display_on, 0);
  WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
  char detail[96];
  snprintf(detail, sizeof detail, "%ld frames in %ld refreshes", drawn, shown);
  check(drawn >= 5 && drawn <= shown + 4, "a drag's frames wait for the display", detail);
  Sleep(150); // the main loop can be in a wait on the handle for this long
  CloseHandle(ready);
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
  check_resize_paced();
  check_menu();
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
