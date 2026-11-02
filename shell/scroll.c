#include "scroll.h"

#include <math.h>
#include <string.h>

// The glide's distance and speed t seconds after it started, from
// y'' = -f y': it travels v0 / f in all.
static double glide_offset(double v0, double t) { return v0 / SCROLL_FRICTION * (1 - exp(-SCROLL_FRICTION * t)); }
static double glide_speed(double v0, double t) { return v0 * exp(-SCROLL_FRICTION * t); }

// Keeps the samples within SCROLL_HISTORY_MS of ms, then adds this one.
// Times are compared as a signed difference, so the clock may wrap.
static void history_push(Scroll_Kinetic *k, double dx, double dy, uint32_t ms) {
  int keep = 0;
  while (keep < k->count && (int32_t)(ms - k->history[keep].ms) > SCROLL_HISTORY_MS) keep++;
  if (k->count - keep == SCROLL_HISTORY_CAP) keep++;
  memmove(k->history, k->history + keep, (size_t)(k->count - keep) * sizeof k->history[0]);
  k->count -= keep;
  k->history[k->count++] = (Scroll_Sample){.dx = dx, .dy = dy, .ms = ms};
}

// A glide that would have come to rest by now, though no frame stepped it
// there, passes nothing on.
static void interrupt(Scroll_Kinetic *k, double now) {
  if (!k->running) return;
  k->running = false;
  for (int i = 0; i < 2; i++) {
    double v = glide_speed(k->v0[i], now - k->start);
    k->carry[i] = fabs(v) / SCROLL_FRICTION >= SCROLL_REST ? v : 0;
  }
}

void scroll_begin(Scroll_Kinetic *k, double now) {
  interrupt(k, now);
  k->count = 0;
}

void scroll_finger(Scroll_Kinetic *k, double d[2], uint32_t ms) {
  d[0] *= SCROLL_FINGER_FACTOR;
  d[1] *= SCROLL_FINGER_FACTOR;
  history_push(k, d[0], d[1], ms);
}

// A fling in the same direction as the glide it interrupted, and at least a
// third as fast, adds that glide's speed, scaled by how much faster it is.
static double accumulate(double v, double last) {
  if (last == 0 || (v >= 0) != (last >= 0) || fabs(v) < fabs(last) * SCROLL_ACCUM_FLOOR) return v;
  double lo = last * SCROLL_ACCUM_FLOOR, hi = last * SCROLL_ACCUM_CEIL;
  double m = (v - lo) / (hi - lo);
  return v + last * (m < SCROLL_ACCUM_MAX ? m : SCROLL_ACCUM_MAX);
}

bool scroll_release(Scroll_Kinetic *k, uint32_t ms, double now) {
  history_push(k, 0, 0, ms);
  double sum[2] = {0, 0};
  for (int i = 0; i < k->count; i++) {
    sum[0] += k->history[i].dx;
    sum[1] += k->history[i].dy;
  }
  int32_t span = (int32_t)(k->history[k->count - 1].ms - k->history[0].ms);
  double v[2] = {0, 0};
  if (span > 0)
    for (int i = 0; i < 2; i++) v[i] = sum[i] * 1000 / span;
  k->count = 0;
  bool moving = v[0] != 0 || v[1] != 0;
  for (int i = 0; i < 2; i++) {
    if (moving) v[i] = accumulate(v[i], k->carry[i]);
    k->carry[i] = 0;
    k->v0[i] = v[i];
    k->done[i] = 0;
  }
  k->running = moving && (fabs(v[0]) / SCROLL_FRICTION >= SCROLL_REST || fabs(v[1]) / SCROLL_FRICTION >= SCROLL_REST);
  k->start = now;
  return k->running;
}

void scroll_hold(Scroll_Kinetic *k, double now) { interrupt(k, now); }

void scroll_cancel(Scroll_Kinetic *k) {
  k->running = false;
  k->carry[0] = k->carry[1] = 0;
}

Scroll_Step scroll_step(Scroll_Kinetic *k, double now, double d[2]) {
  d[0] = d[1] = 0;
  if (!k->running) return SCROLL_IDLE;
  double t = now - k->start;
  if (t < 0) t = 0;
  // Once less than SCROLL_REST is left on both axes, the rest goes at once,
  // so the glide always covers v0 / f and the frames stop.
  bool rest = true;
  for (int i = 0; i < 2; i++)
    if (fabs(glide_speed(k->v0[i], t)) / SCROLL_FRICTION >= SCROLL_REST) rest = false;
  for (int i = 0; i < 2; i++) {
    double to = rest ? k->v0[i] / SCROLL_FRICTION : glide_offset(k->v0[i], t);
    d[i] = to - k->done[i];
    k->done[i] = to;
  }
  if (!rest) return SCROLL_MOVING;
  k->running = false;
  return SCROLL_FINISHED;
}
