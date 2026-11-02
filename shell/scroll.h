// Touchpad scrolling on Linux, as GTK 4's GtkScrolledWindow does it (GTK
// 4.24: gtkscrolledwindow.c, gtkeventcontrollerscroll.c and
// gtkkineticscrolling.c). The shell feeds it Wayland's finger scrolls and
// draws the momentum from it each frame. It has no Wayland in it, so the
// tests link it on its own. docs/linux.md has the model.

#pragma once

#include <stdbool.h>
#include <stdint.h>

#define SCROLL_FINGER_FACTOR 2.5 // GTK's MAGIC_SCROLL_FACTOR for surface units
#define SCROLL_HISTORY_MS 150 // the window the release velocity is measured over
#define SCROLL_HISTORY_CAP 256
#define SCROLL_FRICTION 4.0 // per second: the glide is v0 * exp(-4t)
#define SCROLL_ACCUM_FLOOR 0.33 // a fling adds to the one it interrupts...
#define SCROLL_ACCUM_CEIL 1.0
#define SCROLL_ACCUM_MAX 6.0 // ...up to six times that one's speed
#define SCROLL_REST 0.25 // points of glide left where the momentum ends

typedef struct {
  double dx, dy; // points, scaled
  uint32_t ms; // the compositor's event time
} Scroll_Sample;

typedef struct {
  Scroll_Sample history[SCROLL_HISTORY_CAP];
  int count;
  bool running; // momentum is gliding
  double start; // seconds, when it started
  double v0[2]; // points per second at the start
  double done[2]; // points of it sent so far
  double carry[2]; // speed of a glide that fingers or a hold interrupted
} Scroll_Kinetic;

typedef enum {
  SCROLL_IDLE, // no momentum
  SCROLL_MOVING, // momentum, and more to come
  SCROLL_FINISHED, // the last of the momentum
} Scroll_Step;

// Fingers touch down: the history starts again and any glide stops,
// keeping its speed for the next fling.
void scroll_begin(Scroll_Kinetic *k, double now);
// A finger frame: scales d in place to points and records it.
void scroll_finger(Scroll_Kinetic *k, double d[2], uint32_t ms);
// The fingers lift at ms: starts the momentum at now if they were moving.
bool scroll_release(Scroll_Kinetic *k, uint32_t ms, double now);
// A touchpad hold: stops the glide, keeping its speed, as scroll_begin does.
void scroll_hold(Scroll_Kinetic *k, double now);
// A wheel: stops the glide and forgets its speed.
void scroll_cancel(Scroll_Kinetic *k);
// The momentum's movement since the last step, for a frame drawn at now.
Scroll_Step scroll_step(Scroll_Kinetic *k, double now, double d[2]);
