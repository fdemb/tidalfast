// A headless shell for Linux: runs build/linux/app/app.dylib the way
// shell/shell.m runs the app on macOS, without a window. It draws only when
// asked (request_redraw, wake_after) or while the app animates, at 120 Hz,
// and keeps two drawables while idle and three while animating, as the
// macOS shell does. There is no input: the app's own scenarios
// (TIDALFAST_MEASURE, TIDALFAST_BENCH) drive it. SIGTERM, SIGINT and SIGHUP
// run the app's shutdown and quit.
//
// TIDALFAST_LINUX_WINDOW=WxH@S sets the window in points and its scale,
// 1100x700@2 by default.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <malloc.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "../../shell/platform.h"

#define PERSISTENT_SIZE (256ull << 20)
#define FRAME_SIZE (64ull << 20)
#define TICK (1.0 / 120)

void *tf_metal_device(void);
void *tf_metal_layer(size_t pixel_format);
void tf_layer_set_size(void *layer, size_t width, size_t height);
void tf_layer_set_max_drawables(void *layer, int max);
void tf_pool_push(void);
void tf_pool_pop(void);

static int g_wake_pipe[2];
static atomic_bool g_needs_redraw;
static atomic_bool g_quit;
static bool g_measure;
static double g_process_start;

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void wake(void) {
  char c = 0;
  ssize_t n = write(g_wake_pipe[1], &c, 1);
  (void)n;
}

static void request_redraw(void) {
  atomic_store(&g_needs_redraw, true);
  wake();
}

static void on_signal(int sig) {
  atomic_store(&g_quit, true);
  wake();
}

// When the kernel started this process, as Unix seconds: its start in clock
// ticks after boot from /proc/self/stat, against the time since boot now.
// /proc/stat's boot time is whole seconds, which would put up to a second of
// error in every mark.
static void measure_init(void) {
  const char *measure = getenv("TIDALFAST_MEASURE");
  g_measure = measure && *measure;
  struct timeval tv;
  gettimeofday(&tv, NULL);
  g_process_start = tv.tv_sec + tv.tv_usec / 1e6;
  char buf[4096];
  FILE *f = fopen("/proc/self/stat", "r");
  if (!f) return;
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = 0;
  char *p = strrchr(buf, ')');
  unsigned long long start = 0;
  for (int field = 2; p && field < 22; field++) p = strchr(p + 1, ' ');
  if (p) start = strtoull(p + 1, NULL, 10);
  struct timespec boot;
  clock_gettime(CLOCK_BOOTTIME, &boot);
  double since_start = boot.tv_sec + boot.tv_nsec / 1e9 - (double)start / sysconf(_SC_CLK_TCK);
  if (start && since_start >= 0) g_process_start -= since_start;
}

static void measure_mark(const char *name) {
  if (!g_measure) return;
  struct timeval tv;
  gettimeofday(&tv, NULL);
  fprintf(stderr, "measure: {\"mark\":\"%s\",\"ms\":%.1f}\n", name, (tv.tv_sec + tv.tv_usec / 1e6 - g_process_start) * 1000);
}

static void set_now_playing(const Now_Playing *info) {}
static void set_text_input(const Text_Input *input) {}
static void set_accessibility(const Access_Node *nodes, uint32_t count) {}

static uint8_t *g_clipboard;
static size_t g_clipboard_len;

static void set_clipboard(const uint8_t *text, size_t length) {
  free(g_clipboard);
  g_clipboard = malloc(length ? length : 1);
  memcpy(g_clipboard, text, length);
  g_clipboard_len = length;
}

static size_t get_clipboard(uint8_t *buffer, size_t capacity) {
  size_t n = g_clipboard_len < capacity ? g_clipboard_len : capacity;
  if (n) memcpy(buffer, g_clipboard, n);
  return g_clipboard_len;
}

static void *reserve(size_t size) {
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) {
    fprintf(stderr, "shell: mmap of %zu bytes failed\n", size);
    exit(1);
  }
  return p;
}

int main(int argc, char **argv) {
  // macOS's malloc hands blocks over 128 KB straight to the VM system and
  // gives them back when freed. glibc's default raises that threshold as
  // big blocks are freed and keeps them in its heap, which made the same
  // app look 10 to 25 MB bigger here than its frees warrant.
  mallopt(M_MMAP_THRESHOLD, 128 << 10);
  measure_init();
  measure_mark("main");
  double start = now_seconds();

  float width = 1100, height = 700, scale = 2;
  const char *window = getenv("TIDALFAST_LINUX_WINDOW");
  if (window) sscanf(window, "%fx%f@%f", &width, &height, &scale);

  if (pipe2(g_wake_pipe, O_NONBLOCK | O_CLOEXEC) != 0) return 1;
  struct sigaction sa = {0};
  sa.sa_handler = on_signal;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);

  char exe[PATH_MAX], path[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0) return 1;
  exe[n] = 0;
  *strrchr(exe, '/') = 0;
  snprintf(path, sizeof(path), "%s/app.dylib", exe);
  measure_mark("launched");
  void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    fprintf(stderr, "shell: %s\n", dlerror());
    return 1;
  }
  App_Get_API get_api = (App_Get_API)dlsym(lib, APP_GET_API_SYMBOL);
  App_API *api = get_api ? get_api() : NULL;
  if (!api || api->abi_version != PLATFORM_ABI_VERSION) {
    fprintf(stderr, "shell: %s has no app or a different ABI\n", path);
    return 1;
  }
  measure_mark("dylib");

  Memory memory = {
      .persistent = reserve(PERSISTENT_SIZE),
      .persistent_size = PERSISTENT_SIZE,
      .frame = reserve(FRAME_SIZE),
      .frame_size = FRAME_SIZE,
  };
  void *layer = tf_metal_layer(81); // BGRA8Unorm_sRGB, as the macOS layer
  tf_layer_set_size(layer, (size_t)(width * scale), (size_t)(height * scale));
  Shell shell = {
      .metal_device = tf_metal_device(),
      .metal_layer = layer,
      .request_redraw = request_redraw,
      .set_now_playing = set_now_playing,
      .set_text_input = set_text_input,
      .set_clipboard = set_clipboard,
      .get_clipboard = get_clipboard,
      .set_accessibility = set_accessibility,
  };
  tf_pool_push();
  api->init(&memory, &shell);
  tf_pool_pop();
  measure_mark("window");

  bool animating = false;
  double wake_at = 0, last_frame = 0;
  int drawables = 2;
  request_redraw();
  while (!atomic_load(&g_quit)) {
    double now = now_seconds();
    double next = 1e9;
    if (atomic_load(&g_needs_redraw) || animating) next = animating ? last_frame + TICK : now;
    if (wake_at > 0 && wake_at < next) next = wake_at;
    if (next > now) {
      struct pollfd pfd = {g_wake_pipe[0], POLLIN, 0};
      double wait = next - now;
      int timeout = wait > 3600 ? 3600 * 1000 : (int)(wait * 1000) + 1;
      // A redraw asked for while animating waits for the next tick.
      if (animating && atomic_load(&g_needs_redraw)) timeout = (int)((last_frame + TICK - now) * 1000) + 1;
      poll(&pfd, 1, timeout < 0 ? 0 : timeout);
      char buf[64];
      while (read(g_wake_pipe[0], buf, sizeof(buf)) > 0) {
      }
      now = now_seconds();
      bool due = (atomic_load(&g_needs_redraw) && (!animating || now >= last_frame + TICK)) ||
                 (animating && now >= last_frame + TICK) || (wake_at > 0 && now >= wake_at);
      if (!due) continue;
    }
    if (atomic_load(&g_quit)) break;

    atomic_store(&g_needs_redraw, false);
    Frame_Input input = {
        .width = width,
        .height = height,
        .scale = scale,
        .time = now - start,
        .key_window = 1,
    };
    tf_pool_push();
    Frame_Result result = api->frame(&memory, &shell, &input);
    tf_pool_pop();
    last_frame = now;
    animating = result.animating != 0;
    wake_at = result.wake_after > 0 ? now_seconds() + result.wake_after : 0;
    int want = animating ? 3 : 2;
    if (want != drawables) {
      drawables = want;
      tf_layer_set_max_drawables(layer, drawables);
      // The layer lets go of the third drawable in the next nextDrawable.
      if (!animating) request_redraw();
    }
  }
  tf_pool_push();
  api->shutdown(&memory);
  tf_pool_pop();
  return 0;
}
