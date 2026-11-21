// The parts of the shell that are the same on every OS: the event queue,
// the mirror of the focused text field that input methods edit, the copy of
// the accessibility tree, the Now Playing log, and the test driver
// (TIDALFAST_SHELL_TEST and TIDALFAST_REMOTE_TEST). shell_cocoa.m,
// shell_wayland.c and shell_win32.c each provide the few procedures below
// that touch the OS.
#pragma once

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "platform.h"

// Provided by each OS's shell.
double now_seconds(void); // a monotonic clock, in seconds, the one input events are stamped with
void request_redraw(void); // Shell.request_redraw: safe from any thread
// An OS's own test step, such as size= or wheel=. It runs before the shared
// steps, so it can take the place of one of them, as macOS's input method
// and accessibility steps go through AppKit. False if it has none by that
// name.
bool os_test_step(const char *command, char *arg);
// Wake the shell after seconds to run the next test step (run_due_steps).
void os_arm_test_timer(double after);

extern atomic_bool g_needs_redraw;
extern atomic_bool g_quit; // the main loop ends; macOS's NSApplication quits by itself
extern double g_start_time; // now_seconds when the shell started

// common_init starts the clock and reads the environment the shared code
// needs. It's the first thing shell_main does.
void common_init(void);

// Events for the next frame, and the text they point into. queue_take
// hands the queued events and their text to a frame, and starts an empty
// queue in other buffers for what comes while it runs, so a callback
// re-entered from inside app_frame doesn't move or reset what the app is
// reading. The handed buffers stay valid until the next queue_take.
void push_event(Event e);
void push_text(Event *e, const char *text, size_t n);
void queue_take(Event **events, uint32_t *count, const uint8_t **text, uint32_t *text_length);

// The shell's mirror of the focused text field. The app sends it after each
// frame (set_text_input), and the shell applies each edit it sends on to
// the app to the mirror as well, so an input method asking about the text
// between frames gets the right answer. Bytes of UTF-8, as the app counts.
typedef struct {
  bool active;
  uint8_t *bytes;
  uint32_t length, capacity;
  uint32_t limit; // the field's, in bytes; 0 for none
  uint32_t sel_start, sel_end;
  int32_t marked_start, marked_end; // -1 without marked text
  float caret[4]; // view points
} Text_Mirror;

extern Text_Mirror g_ti;

// mirror_set takes the app's Text_Input into the mirror. True when the
// input method should hear about it: the field changed, gained or lost the
// focus.
bool mirror_set(const Text_Input *ti);
// The input method's edits, which go to the app and into the mirror.
// Ranges are bytes of the field's text, lo < 0 for the marked text or the
// selection.
void text_insert(const char *utf8, int64_t lo_given, int64_t hi_given);
void text_set_marked(const char *utf8, uint32_t sel_lo, uint32_t sel_hi, int64_t lo_given, int64_t hi_given);
void text_unmark(void);
// The field's text for the input method, without the composition; out
// holds g_ti.length + 1 bytes.
void surrounding_text(char *out, int32_t *cursor, int32_t *anchor);
uint32_t utf16_of_byte(const uint8_t *s, uint32_t len, uint32_t byte);
uint32_t byte_of_utf16(const uint8_t *s, uint32_t len, uint32_t u16);

// Media commands, as the media keys send them, and the Now Playing log
// (TIDALFAST_NOW_PLAYING_LOG).
extern bool g_now_playing_log;
void remote_command(uint32_t command, double position);
// print_now_playing logs what the app sets as Now Playing. The Linux and
// Windows shells call it before handing Now Playing to MPRIS and the
// System Media Transport Controls.
void print_now_playing(const Now_Playing *np);
// print_player_controls logs the volume, shuffle and repeat the app sets.
void print_player_controls(const Player_Controls *c);

// The accessibility tree as the app last sent it, which access_store
// copies. Linux and Windows keep it only for the test driver; macOS makes
// its NSAccessibilityElements from it.
typedef struct {
  uint64_t id;
  int32_t parent;
  uint32_t role, flags;
  float frame[4]; // view points
  char *label, *value; // malloc'd, or NULL
} Shell_Node;

extern Shell_Node *g_nodes;
extern uint32_t g_node_count;
void access_store(const Access_Node *nodes, uint32_t count);
// Buttons, rows and menu items take a press.
bool access_pressable(uint32_t role);

// The test driver. setup_shell_test reads the environment once the window
// is up, and step times count from then; run_due_steps runs the steps whose
// time has come and arms the timer for the next.
void setup_shell_test(void);
void run_due_steps(void);
