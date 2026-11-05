// The parts of the shell that are the same on Linux and Windows: the event
// queue, the mirror of the focused text field that input methods edit, the
// accessibility tree kept for the test driver, the Now Playing log, and the
// test driver itself (TIDALFAST_SHELL_TEST and TIDALFAST_REMOTE_TEST).
// shell_wayland.c and shell_win32.c each provide the few procedures below
// that touch the OS. shell.m keeps its own copies, in Objective-C.
#pragma once

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "platform.h"

// Provided by each OS's shell.
double now_seconds(void); // a monotonic clock, in seconds
void request_redraw(void); // Shell.request_redraw: safe from any thread
// An OS's own test step, such as size= or wheel=. False if it has none by
// that name.
bool os_test_step(const char *command, char *arg);
// Wake the shell after seconds to run the next test step (run_due_steps).
void os_arm_test_timer(double after);

extern atomic_bool g_needs_redraw;
extern atomic_bool g_quit;
extern double g_start_time; // now_seconds when the shell started

// Events for the next frame, and the text they point into. The shell
// resets both after each app_frame.
extern Event *g_events;
extern uint32_t g_event_count;
extern uint8_t *g_text;
extern uint32_t g_text_len;

void push_event(Event e);
void push_text(Event *e, const char *text, size_t n);

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
void text_insert(const char *utf8, int64_t lo_given, int64_t hi_given);
void text_set_marked(const char *utf8, uint32_t sel_lo, uint32_t sel_hi, int64_t lo_given, int64_t hi_given);
void text_unmark(void);
// The field's text for the input method, without the composition; out
// holds g_ti.length + 1 bytes.
void surrounding_text(char *out, int32_t *cursor, int32_t *anchor);
uint32_t utf16_of_byte(const uint8_t *s, uint32_t len, uint32_t byte);
uint32_t byte_of_utf16(const uint8_t *s, uint32_t len, uint32_t u16);

// Media commands, as the media keys send them, and the Now Playing log.
extern bool g_now_playing_log;
void remote_command(uint32_t command, double position);
void set_now_playing(const Now_Playing *np);

// The accessibility tree as the app last sent it.
void set_accessibility(const Access_Node *nodes, uint32_t count);

// The test driver. setup_shell_test reads the environment once the window
// is up; run_due_steps runs the steps whose time has come and arms the
// timer for the next.
void setup_shell_test(void);
void run_due_steps(void);
