// The executable. Owns NSApplication, the window and the CAMetalLayer,
// collects input into an event array, and drives the app dylib through the
// App_API table in platform.h. It redraws only when something asks for it:
// input, resize, a reload or request_redraw from any thread. While the app
// reports it is animating and the window is visible, the display link adds a
// frame every vsync, and other redraws wait for the next tick. A frame can
// also ask to be woken after a delay, which a one-shot timer does.
//
// The view is an NSTextInputClient, so input methods work in the app's text
// fields, and it hands assistive apps an accessibility tree the app builds
// from its boxes.

#import <Carbon/Carbon.h> // kVK_* only
#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <MediaPlayer/MediaPlayer.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <copyfile.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>

#include "platform.h"

#ifndef HOT_RELOAD
#define HOT_RELOAD 1
#endif

#define PERSISTENT_SIZE (256ull << 20)
#define FRAME_SIZE (64ull << 20)

typedef struct {
  void *handle;
  App_API api;
  ino_t inode;
  struct timespec mtime;
} Loaded_App;

static Loaded_App g_app;
static NSString *g_app_path;
#if HOT_RELOAD
static int g_reload_count;
#endif

static Memory g_memory;
static Shell g_shell;
static Event *g_events;
static uint32_t g_event_count;
static uint32_t g_event_capacity;
static atomic_bool g_needs_redraw;
static bool g_animating;
static bool g_parked; // the window can't be seen and its drawables are a pixel, see update_parking
static bool g_never_park; // TIDALFAST_CAPTURE is set
static double g_last_tick; // CACurrentMediaTime of the last display link frame
static double g_tick_interval = 1.0 / 60;
static CFRunLoopTimerRef g_tick_fallback;
static CFRunLoopTimerRef g_wake_timer; // fires when a frame asked for wake_after
static bool g_wake_armed; // g_wake_timer is set to fire, see draw_frame
static uint8_t *g_text; // bytes text events point into, reset with the events
static uint32_t g_text_len;
static uint32_t g_text_cap;
static CFRunLoopRef g_main_run_loop;
static double g_start_time;

static NSWindow *g_window;
static NSView *g_view;
static CAMetalLayer *g_layer;
static CADisplayLink *g_display_link;

static void update_display_link(void);
static void access_frame_done(void);

// TIDALFAST_MEASURE: the shell's startup marks, in the format the app's
// measure.odin prints, in milliseconds since the kernel started the process.
static bool g_measure;
static int64_t g_process_start_us;

static void measure_mark(const char *name) {
  if (!g_measure) return;
  struct timeval now;
  gettimeofday(&now, NULL);
  int64_t us = (int64_t)now.tv_sec * 1000000 + now.tv_usec - g_process_start_us;
  fprintf(stderr, "measure: {\"mark\":\"%s\",\"ms\":%.1f}\n", name, us / 1000.0);
}

static void measure_init(void) {
  const char *measure = getenv("TIDALFAST_MEASURE");
  g_measure = measure && *measure;
  if (!g_measure) return;
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
  struct timeval start = {0};
  if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) start = info.kp_proc.p_starttime;
  else gettimeofday(&start, NULL);
  g_process_start_us = (int64_t)start.tv_sec * 1000000 + start.tv_usec;
}

static void request_redraw(void) {
  atomic_store(&g_needs_redraw, true);
  CFRunLoopWakeUp(g_main_run_loop);
}

// From the whole login session, so it sees releases that went to other apps.
static uint32_t held_mouse_buttons(void) {
  uint32_t held = 0;
  // Mouse_Button's values are CGMouseButton's: left, right, center, then
  // the side buttons as 3 and 4.
  for (uint32_t b = MOUSE_BUTTON_LEFT; b <= MOUSE_BUTTON_FORWARD; b++) {
    if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, b)) held |= 1u << b;
  }
  return held;
}

static void draw_frame(void) {
  if (!g_app.api.frame) return;
  atomic_store(&g_needs_redraw, false);

  NSSize size = g_view.bounds.size;
  // Full screen hides the titlebar, and the layout rect is then the view.
  // Elsewhere the titlebar is as tall as twice the buttons' centre: macOS 26
  // insets the layout rect further, past the toolbar.
  float titlebar = 0;
  NSButton *close = [g_window standardWindowButton:NSWindowCloseButton];
  if (close && size.height > g_window.contentLayoutRect.size.height) {
    titlebar = 2 * NSMidY([close convertRect:close.bounds toView:g_view]);
  }
  NSButton *zoom = [g_window standardWindowButton:NSWindowZoomButton];
  Frame_Input input = {
      .events = g_events,
      .event_count = g_event_count,
      .width = size.width,
      .height = size.height,
      .scale = g_window.backingScaleFactor,
      .time = CACurrentMediaTime() - g_start_time,
      .text = g_text,
      .text_length = g_text_len,
      .key_window = g_window.isKeyWindow,
      .mouse_buttons = held_mouse_buttons(),
      .titlebar_height = titlebar > 0 ? titlebar : 0,
      .titlebar_inset = titlebar > 0 && zoom ? NSMaxX(zoom.frame) : 0,
  };
  Frame_Result result;
  @autoreleasepool {
    result = g_app.api.frame(&g_memory, &g_shell, &input);
    access_frame_done();
  }
  g_event_count = 0;
  g_text_len = 0;
  g_animating = result.animating;
  update_display_link();
  // Moving a timer in the common modes costs about 13,000 instructions even
  // to the far future, so a frame that asks for no wake leaves an unarmed
  // timer alone.
  if (g_wake_timer && (result.wake_after > 0 || g_wake_armed)) {
    double after = result.wake_after > 0 ? result.wake_after : 1e9;
    CFRunLoopTimerSetNextFireDate(g_wake_timer, CFAbsoluteTimeGetCurrent() + after);
    g_wake_armed = result.wake_after > 0;
  }
}

// The timer repeats 1e9 s later, so once it fires it's unarmed.
static void wake_timer_fired(CFRunLoopTimerRef timer, void *info) {
  g_wake_armed = false;
  request_redraw();
}

// push_text copies text for an event into the frame's text buffer.
static void push_text(Event *e, const char *text, size_t n) {
  if (g_text_len + n > g_text_cap) {
    while (g_text_len + n > g_text_cap) g_text_cap = g_text_cap ? g_text_cap * 2 : 1024;
    g_text = realloc(g_text, g_text_cap);
  }
  memcpy(g_text + g_text_len, text, n);
  e->text_offset = g_text_len;
  e->text_length = (uint32_t)n;
  g_text_len += (uint32_t)n;
}

static bool continuous_phase(uint32_t phase) {
  return phase == SCROLL_PHASE_NONE || phase == SCROLL_PHASE_CHANGED;
}

// Folds e into the last queued event when nothing between them matters: a
// move or resize replaces the one before it, and a scroll adds to a scroll in
// the same phase. Phase changes such as began and ended keep their own event.
static bool coalesce(Event *last, Event e) {
  if (last->kind != e.kind) return false;
  if (e.kind == EVENT_MOUSE_MOVE || e.kind == EVENT_RESIZE) {
    *last = e;
    return true;
  }
  if (e.kind == EVENT_SCROLL && last->phase == e.phase && last->momentum_phase == e.momentum_phase &&
      continuous_phase(e.phase) && continuous_phase(e.momentum_phase) && last->precise == e.precise &&
      last->modifiers == e.modifiers) {
    e.dx += last->dx;
    e.dy += last->dy;
    *last = e;
    return true;
  }
  return false;
}

// The queue grows rather than drop an event or draw early: a lost mouse up
// or key up leaves it stuck down. It only gets long if the run loop goes a
// long time without sleeping.
static void push_event(Event e) {
  if (g_event_count == 0 || !coalesce(&g_events[g_event_count - 1], e)) {
    if (g_event_count == g_event_capacity) {
      g_event_capacity = g_event_capacity ? g_event_capacity * 2 : 256;
      g_events = realloc(g_events, g_event_capacity * sizeof(Event));
    }
    g_events[g_event_count++] = e;
  }
  atomic_store(&g_needs_redraw, true);
}

// When the next display link frame is due, the deadline by which it should
// have arrived. Two intervals of slack cover a late tick. Zero if the link
// is paused or hasn't ticked recently, as when the display sleeps.
static double tick_deadline(void) {
  if (g_display_link.paused) return 0;
  double deadline = g_last_tick + 2 * g_tick_interval;
  return CACurrentMediaTime() < deadline ? deadline : 0;
}

// Draws once per run loop pass, just before the loop sleeps, so a burst of
// events becomes one frame. While the display link is ticking, the redraw
// waits for the next tick instead, so input during an animation doesn't add
// frames between vsyncs and block in nextDrawable. A timer wakes the loop at
// the deadline in case the tick never comes.
static void before_waiting(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
  if (!atomic_load(&g_needs_redraw)) return;
  double deadline = tick_deadline();
  if (deadline == 0) {
    draw_frame();
    return;
  }
  CFRunLoopTimerSetNextFireDate(g_tick_fallback, CFAbsoluteTimeGetCurrent() + (deadline - CACurrentMediaTime()));
}

// Firing is all the fallback timer does: the run loop pass it causes ends in
// before_waiting, which draws if the tick still hasn't come.
static void tick_fallback_fired(CFRunLoopTimerRef timer, void *info) {}

// Hot reload

static bool file_identity(NSString *path, ino_t *inode, struct timespec *mtime) {
  struct stat st;
  if (stat(path.fileSystemRepresentation, &st) != 0) return false;
  *inode = st.st_ino;
  *mtime = st.st_mtimespec;
  return true;
}

// With hot reload, copies the dylib to a unique temp path and opens the
// copy, so the linker can replace the original while this copy is loaded.
// Without it the dylib is opened in place: macOS checks the signature of a
// file it hasn't seen before on every dlopen, about 100 ms for a fresh copy
// against under 10 for the same file again. dlopen runs the Odin runtime's
// startup in the new image.
static bool open_app(Loaded_App *out) {
  if (!file_identity(g_app_path, &out->inode, &out->mtime)) {
    fprintf(stderr, "shell: no app dylib at %s\n", g_app_path.UTF8String);
    return false;
  }
#if HOT_RELOAD
  NSString *name = [NSString stringWithFormat:@"tidalfast-app-%d-%d.dylib", getpid(), g_reload_count++];
  NSString *copy = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  if (copyfile(g_app_path.fileSystemRepresentation, copy.fileSystemRepresentation, NULL, COPYFILE_ALL) != 0) {
    fprintf(stderr, "shell: copy to %s failed\n", copy.UTF8String);
    return false;
  }
  void *handle = dlopen(copy.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  unlink(copy.fileSystemRepresentation);
#else
  void *handle = dlopen(g_app_path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
#endif
  if (!handle) {
    fprintf(stderr, "shell: dlopen failed: %s\n", dlerror());
    return false;
  }
  App_Get_API get_api = (App_Get_API)dlsym(handle, APP_GET_API_SYMBOL);
  App_API *api = get_api ? get_api() : NULL;
  if (!api || api->abi_version != PLATFORM_ABI_VERSION) {
    fprintf(stderr, "shell: app ABI %u, shell ABI %u, not loading\n", api ? api->abi_version : 0, PLATFORM_ABI_VERSION);
    dlclose(handle);
    return false;
  }
  out->handle = handle;
  out->api = *api;
  return true;
}

#if HOT_RELOAD
static void reload_if_changed(void) {
  ino_t inode;
  struct timespec mtime;
  if (!file_identity(g_app_path, &inode, &mtime)) return;
  if (inode == g_app.inode && mtime.tv_sec == g_app.mtime.tv_sec && mtime.tv_nsec == g_app.mtime.tv_nsec) return;

  Loaded_App next = {0};
  if (!open_app(&next)) {
    // Remember the file anyway so a broken build isn't retried until it changes.
    g_app.inode = inode;
    g_app.mtime = mtime;
    return;
  }
  g_app.api.unload(&g_memory);
  // The old image stays open for good. A State the new code can't read is
  // released through a procedure the old code left in it, so that code must
  // stay mapped. (macOS wouldn't unmap an Odin dylib anyway, since it uses
  // thread-local storage.)
  g_app = next;
  @autoreleasepool {
    g_app.api.reload(&g_memory, &g_shell);
  }
  fprintf(stderr, "shell: reloaded app (%d)\n", g_reload_count - 1);
  request_redraw();
}

static void build_dir_changed(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                              const FSEventStreamEventFlags *flags, const FSEventStreamEventId *ids) {
  reload_if_changed();
}

// FSEvents on the build directory: no polling, and it sees the rename that
// build.sh uses to put a finished dylib in place.
static void watch_app(void) {
  NSArray *paths = @[ g_app_path.stringByDeletingLastPathComponent ];
  FSEventStreamRef stream =
      FSEventStreamCreate(NULL, build_dir_changed, NULL, (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow, 0.05,
                          kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
  FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
  FSEventStreamStart(stream);
}
#endif

// Now Playing and media keys
//
// MPNowPlayingInfoCenter shows what plays in Control Center and on the lock
// screen. MPRemoteCommandCenter routes the media keys, Control Center's
// buttons and headphone controls to the app that is playing; each command
// becomes an EVENT_MEDIA in the app's next frame.
//
// TIDALFAST_NOW_PLAYING_LOG=1 prints nowPlayingInfo as macOS holds it after
// every update. TIDALFAST_REMOTE_TEST="3:pause,5:play,7:seek=42,9:next"
// sends commands through the same path as the real handlers, each that
// many seconds after launch, for testing without a keyboard.

static MPMediaItemArtwork *g_artwork;
static uint64_t g_artwork_key;
static bool g_now_playing_log;

static void remote_command(uint32_t command, double position) {
  push_event((Event){.kind = EVENT_MEDIA, .media = (uint8_t)command, .dx = (float)position, .time = CACurrentMediaTime()});
  if (g_now_playing_log) fprintf(stderr, "shell: remote command %u (%.3f)\n", command, position);
  request_redraw();
}

static MPMediaItemArtwork *make_artwork(const Now_Playing *np) {
  size_t w = np->artwork_width, h = np->artwork_height;
  NSData *pixels = [NSData dataWithBytes:np->artwork length:w * h * 4];
  CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGImageRef cg = CGImageCreate(w, h, 8, 32, w * 4, srgb, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault,
                                provider, NULL, true, kCGRenderingIntentDefault);
  CGColorSpaceRelease(srgb);
  CGDataProviderRelease(provider);
  if (!cg) return nil;
  NSImage *image = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(w, h)];
  CGImageRelease(cg);
  return [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                         requestHandler:^NSImage *(CGSize size) {
                                           return image;
                                         }];
}

static void log_now_playing(void) {
  MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
  NSDictionary *info = center.nowPlayingInfo;
  MPMediaItemArtwork *art = info[MPMediaItemPropertyArtwork];
  fprintf(stderr, "shell: now playing: state %ld, title \"%s\", artist \"%s\", album \"%s\", duration %.3f, elapsed %.3f, rate %.1f, artwork %s\n",
          (long)center.playbackState, [info[MPMediaItemPropertyTitle] UTF8String] ?: "",
          [info[MPMediaItemPropertyArtist] UTF8String] ?: "", [info[MPMediaItemPropertyAlbumTitle] UTF8String] ?: "",
          [info[MPMediaItemPropertyPlaybackDuration] doubleValue],
          [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue],
          [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue],
          art ? [NSString stringWithFormat:@"%.0fx%.0f", art.bounds.size.width, art.bounds.size.height].UTF8String : "none");
}

static void set_now_playing(const Now_Playing *np) {
  MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
  if (!np || !np->title) {
    center.nowPlayingInfo = nil;
    center.playbackState = MPNowPlayingPlaybackStateStopped;
    g_artwork = nil;
    g_artwork_key = 0;
    if (g_now_playing_log) log_now_playing();
    return;
  }
  if (np->artwork_key != g_artwork_key) {
    g_artwork_key = np->artwork_key;
    g_artwork = np->artwork && np->artwork_width && np->artwork_height ? make_artwork(np) : nil;
  }
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[MPMediaItemPropertyTitle] = [NSString stringWithUTF8String:np->title] ?: @"";
  if (np->artist) info[MPMediaItemPropertyArtist] = [NSString stringWithUTF8String:np->artist] ?: @"";
  if (np->album) info[MPMediaItemPropertyAlbumTitle] = [NSString stringWithUTF8String:np->album] ?: @"";
  info[MPMediaItemPropertyPlaybackDuration] = @(np->duration);
  info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(np->elapsed);
  info[MPNowPlayingInfoPropertyPlaybackRate] = @(np->state == NOW_PLAYING_PLAYING ? 1.0 : 0.0);
  info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);
  if (g_artwork) info[MPMediaItemPropertyArtwork] = g_artwork;
  center.nowPlayingInfo = info;
  center.playbackState = np->state == NOW_PLAYING_PLAYING  ? MPNowPlayingPlaybackStatePlaying
                         : np->state == NOW_PLAYING_PAUSED ? MPNowPlayingPlaybackStatePaused
                                                           : MPNowPlayingPlaybackStateStopped;
  if (g_now_playing_log) log_now_playing();
}

static void setup_remote_commands(void) {
  g_now_playing_log = getenv("TIDALFAST_NOW_PLAYING_LOG") != NULL;
  MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
  struct {
    MPRemoteCommand *command;
    uint32_t kind;
  } simple[] = {
      {center.playCommand, MEDIA_PLAY},
      {center.pauseCommand, MEDIA_PAUSE},
      {center.togglePlayPauseCommand, MEDIA_TOGGLE},
      {center.nextTrackCommand, MEDIA_NEXT},
      {center.previousTrackCommand, MEDIA_PREVIOUS},
  };
  for (size_t i = 0; i < sizeof simple / sizeof simple[0]; i++) {
    uint32_t kind = simple[i].kind;
    simple[i].command.enabled = YES;
    [simple[i].command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
      remote_command(kind, 0);
      return MPRemoteCommandHandlerStatusSuccess;
    }];
  }
  center.changePlaybackPositionCommand.enabled = YES;
  [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
    remote_command(MEDIA_SEEK, ((MPChangePlaybackPositionCommandEvent *)event).positionTime);
    return MPRemoteCommandHandlerStatusSuccess;
  }];

  const char *script = getenv("TIDALFAST_REMOTE_TEST");
  if (!script) return;
  NSDictionary *names = @{
    @"play" : @(MEDIA_PLAY),
    @"pause" : @(MEDIA_PAUSE),
    @"toggle" : @(MEDIA_TOGGLE),
    @"next" : @(MEDIA_NEXT),
    @"previous" : @(MEDIA_PREVIOUS),
    @"seek" : @(MEDIA_SEEK),
  };
  for (NSString *step in [@(script) componentsSeparatedByString:@","]) {
    NSArray *at = [step componentsSeparatedByString:@":"];
    if (at.count != 2) continue;
    NSArray *arg = [at[1] componentsSeparatedByString:@"="];
    NSNumber *kind = names[arg[0]];
    if (!kind) continue;
    uint32_t command = kind.unsignedIntValue;
    double value = arg.count > 1 ? [arg[1] doubleValue] : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([at[0] doubleValue] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     fprintf(stderr, "shell: remote test sends %s\n", [step UTF8String]);
                     remote_command(command, value);
                   });
  }
}

// Text input
//
// The app tells the shell about the focused text field after each frame
// (set_text_input): its text, selection, marked text and where the caret
// is. Input methods ask NSTextInputClient questions synchronously, often
// right after setMarkedText and before the app has had a frame, so the
// shell keeps a mirror of the field and applies each edit it sends on to
// the app to the mirror as well. The app's next state replaces the mirror.
// The app counts in UTF-8 bytes and AppKit in UTF-16 units; the mirror
// converts, rounding down to a whole codepoint. Both sides take the input
// method's edits by rules that need no segmentation, so they agree: the
// text is cleaned the same way byte for byte (field_sanitize and the app's
// sanitize), a replacement range is clamped to the text and rounded down to
// codepoints, and an edit that doesn't fit the limit is refused whole.

static struct {
  bool active;
  uint8_t *bytes;
  uint32_t length, capacity;
  uint32_t limit; // the field's, in bytes; 0 for none
  uint32_t sel_start, sel_end;
  int32_t marked_start, marked_end; // -1 without marked text
  NSRect caret; // view points
} g_ti = {.marked_start = -1, .marked_end = -1};
static bool g_ime_handled; // the input method took the key being handled

static uint32_t utf8_width(uint8_t c) { return c < 0xc0 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4; }

static NSUInteger utf16_of_byte(const uint8_t *s, uint32_t len, uint32_t byte) {
  NSUInteger n = 0;
  for (uint32_t i = 0; i < byte && i < len;) {
    uint32_t w = utf8_width(s[i]);
    n += w == 4 ? 2 : 1;
    i += w;
  }
  return n;
}

// byte_of_utf16 never lands between a surrogate pair's halves.
static uint32_t byte_of_utf16(const uint8_t *s, uint32_t len, NSUInteger u16) {
  NSUInteger n = 0;
  uint32_t i = 0;
  while (i < len) {
    uint32_t w = utf8_width(s[i]);
    NSUInteger units = w == 4 ? 2 : 1;
    if (n + units > u16) break;
    n += units;
    i += w;
  }
  return i < len ? i : len;
}

static void mirror_replace(uint32_t lo, uint32_t hi, const char *text, uint32_t n) {
  uint32_t length = g_ti.length - (hi - lo) + n;
  if (length > g_ti.capacity) {
    g_ti.capacity = length * 2 + 64;
    g_ti.bytes = realloc(g_ti.bytes, g_ti.capacity);
  }
  memmove(g_ti.bytes + lo + n, g_ti.bytes + hi, g_ti.length - hi);
  memcpy(g_ti.bytes + lo, text, n);
  g_ti.length = length;
}

// The range an edit replaces: the one the input method gave, else the
// marked text, else the selection.
static void edit_range(NSRange given, Event *e, uint32_t *lo, uint32_t *hi) {
  if (given.location != NSNotFound) {
    *lo = byte_of_utf16(g_ti.bytes, g_ti.length, given.location);
    *hi = byte_of_utf16(g_ti.bytes, g_ti.length, given.location + given.length);
    if (*hi < *lo) *hi = *lo;
    e->replace = 1;
    e->replace_start = (int32_t)*lo;
    e->replace_end = (int32_t)*hi;
  } else if (g_ti.marked_start >= 0) {
    *lo = (uint32_t)g_ti.marked_start;
    *hi = (uint32_t)g_ti.marked_end;
  } else {
    *lo = g_ti.sel_start;
    *hi = g_ti.sel_end;
  }
}

static NSString *plain_string(id string) {
  return [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : (NSString *)string;
}

// utf8_decode reads one codepoint as Odin's utf8.decode_rune does: an
// invalid or cut short sequence is U+FFFD one byte long.
static uint32_t utf8_decode(const uint8_t *s, uint32_t n, uint32_t *cp) {
  uint8_t c = s[0];
  uint32_t w = 0, min = 0x80, max = 0xbf;
  if (c < 0x80) {
    *cp = c;
    return 1;
  } else if (c >= 0xc2 && c <= 0xdf) {
    w = 2;
  } else if (c >= 0xe0 && c <= 0xef) {
    w = 3;
    if (c == 0xe0) min = 0xa0;
    if (c == 0xed) max = 0x9f;
  } else if (c >= 0xf0 && c <= 0xf4) {
    w = 4;
    if (c == 0xf0) min = 0x90;
    if (c == 0xf4) max = 0x8f;
  }
  *cp = 0xfffd;
  if (w == 0 || n < w || s[1] < min || s[1] > max) return 1;
  for (uint32_t i = 2; i < w; i++)
    if (s[i] < 0x80 || s[i] > 0xbf) return 1;
  uint32_t r = c & (0xff >> (w + 1));
  for (uint32_t i = 1; i < w; i++) r = r << 6 | (s[i] & 0x3f);
  *cp = r;
  return w;
}

// field_sanitize cleans n bytes of text as the app's field does (sanitize
// in src/ui/edit.odin): a run of line breaks and tabs (LF, CR, tab, NEL,
// U+2028, U+2029) becomes one space, or none at the start, and the other
// C0 and C1 controls, DEL, U+FFFD and invalid bytes go. It writes to out,
// which has room for n bytes, and returns the length.
static uint32_t field_sanitize(const char *text, uint32_t n, char *out) {
  const uint8_t *s = (const uint8_t *)text;
  uint32_t o = 0;
  for (uint32_t i = 0; i < n;) {
    uint32_t cp, w = utf8_decode(s + i, n - i, &cp);
    if (cp == '\n' || cp == '\r' || cp == '\t' || cp == 0x85 || cp == 0x2028 || cp == 0x2029) {
      if (o > 0 && out[o - 1] != ' ') out[o++] = ' ';
    } else if (!(cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) || cp == 0xfffd)) {
      memcpy(out + o, s + i, w);
      o += w;
    }
    i += w;
  }
  return o;
}

// field_fits says whether n bytes in place of [lo, hi) keep the field
// within its limit. An input method's edit that doesn't fit is refused
// whole, by the app too, so the two never cut text in different places.
static bool field_fits(uint32_t n, uint32_t lo, uint32_t hi) {
  return !g_ti.limit || (uint64_t)g_ti.length - (hi - lo) + n <= g_ti.limit;
}

// utf8_start moves p back to the start of the UTF-8 sequence it's in.
static uint32_t utf8_start(const uint8_t *s, uint32_t n, uint32_t p) {
  while (p > 0 && p < n && (s[p] & 0xc0) == 0x80) p--;
  return p;
}

static void text_insert(id string, NSRange replacement) {
  const char *utf8 = plain_string(string).UTF8String ?: "";
  uint32_t n = (uint32_t)strlen(utf8);
  Event e = {.kind = EVENT_TEXT, .time = CACurrentMediaTime()};
  push_text(&e, utf8, n);
  uint32_t lo, hi;
  edit_range(replacement, &e, &lo, &hi);
  char *clean = malloc(n + 1);
  uint32_t cn = field_sanitize(utf8, n, clean);
  if (!field_fits(cn, lo, hi)) {
    // Refused: a composition ends as it was, as unmarkText does.
    if (g_ti.marked_start >= 0) g_ti.sel_start = g_ti.sel_end = (uint32_t)g_ti.marked_end;
  } else if (cn > 0 || lo != hi) {
    // The field leaves itself alone when nothing goes in and nothing goes.
    mirror_replace(lo, hi, clean, cn);
    g_ti.sel_start = g_ti.sel_end = lo + cn;
  }
  free(clean);
  g_ti.marked_start = g_ti.marked_end = -1;
  g_ime_handled = true;
  push_event(e);
  request_redraw();
}

static void text_set_marked(id string, NSRange selected, NSRange replacement) {
  const char *utf8 = plain_string(string).UTF8String ?: "";
  uint32_t n = (uint32_t)strlen(utf8);
  Event e = {.kind = EVENT_MARKED_TEXT, .time = CACurrentMediaTime()};
  push_text(&e, utf8, n);
  uint32_t sel_lo = byte_of_utf16((const uint8_t *)utf8, n, selected.location);
  uint32_t sel_hi = byte_of_utf16((const uint8_t *)utf8, n, selected.location + selected.length);
  e.select_start = (int32_t)sel_lo;
  e.select_end = (int32_t)(sel_hi < sel_lo ? sel_lo : sel_hi);
  uint32_t lo, hi;
  edit_range(replacement, &e, &lo, &hi);
  char *clean = malloc(n + 1);
  uint32_t cn = field_sanitize(utf8, n, clean);
  if (!field_fits(cn, lo, hi)) {
    // Refused: the mirror stays as it was.
  } else if (cn > 0) {
    mirror_replace(lo, hi, clean, cn);
    // The selection was found in the text as given. The field clamps it to
    // what it kept and rounds it down to a codepoint.
    uint32_t end = (uint32_t)e.select_end;
    g_ti.marked_start = (int32_t)lo;
    g_ti.marked_end = (int32_t)(lo + cn);
    g_ti.sel_start = lo + utf8_start((const uint8_t *)clean, cn, sel_lo < cn ? sel_lo : cn);
    g_ti.sel_end = lo + utf8_start((const uint8_t *)clean, cn, end < cn ? end : cn);
  } else {
    mirror_replace(lo, hi, clean, cn);
    g_ti.marked_start = g_ti.marked_end = -1;
    g_ti.sel_start = g_ti.sel_end = lo;
  }
  free(clean);
  g_ime_handled = true;
  push_event(e);
  request_redraw();
}

static void text_unmark(void) {
  if (g_ti.marked_start >= 0) g_ti.sel_start = g_ti.sel_end = (uint32_t)g_ti.marked_end;
  g_ti.marked_start = g_ti.marked_end = -1;
  g_ime_handled = true;
  push_event((Event){.kind = EVENT_UNMARK_TEXT, .time = CACurrentMediaTime()});
  request_redraw();
}

static void set_text_input(const Text_Input *ti) {
  if (!ti || !ti->text) {
    if (g_ti.active && g_ti.marked_start >= 0) [g_view.inputContext discardMarkedText];
    g_ti.active = false;
    g_ti.length = g_ti.sel_start = g_ti.sel_end = 0;
    g_ti.marked_start = g_ti.marked_end = -1;
    return;
  }
  // The app ended a composition itself, as when the field lost the focus:
  // the input method has to forget it too.
  bool discard = g_ti.active && g_ti.marked_start >= 0 && ti->marked_start < 0;
  g_ti.length = 0;
  mirror_replace(0, 0, (const char *)ti->text, ti->length);
  g_ti.sel_start = ti->selection_start;
  g_ti.sel_end = ti->selection_end;
  g_ti.marked_start = ti->marked_start;
  g_ti.marked_end = ti->marked_end;
  g_ti.limit = ti->limit;
  NSRect caret = NSMakeRect(ti->caret[0], ti->caret[1], ti->caret[2], ti->caret[3]);
  bool moved = !NSEqualRects(caret, g_ti.caret);
  g_ti.caret = caret;
  g_ti.active = true;
  if (discard) [g_view.inputContext discardMarkedText];
  if (moved) [g_view.inputContext invalidateCharacterCoordinates];
}

// Window dragging

// The view draws under the titlebar, so the app says which parts of it are
// empty and move the window, as the titlebar itself would.
#define MAX_DRAG_REGIONS 16
static NSRect g_drag_regions[MAX_DRAG_REGIONS];
static uint32_t g_drag_region_count;

static void set_drag_regions(const float (*rects)[4], uint32_t count) {
  g_drag_region_count = count < MAX_DRAG_REGIONS ? count : MAX_DRAG_REGIONS;
  for (uint32_t i = 0; i < g_drag_region_count; i++) {
    g_drag_regions[i] = NSMakeRect(rects[i][0], rects[i][1], rects[i][2], rects[i][3]);
  }
}

static bool in_drag_region(NSPoint p) {
  for (uint32_t i = 0; i < g_drag_region_count; i++) {
    if (NSPointInRect(p, g_drag_regions[i])) return true;
  }
  return false;
}

// A double-click does what System Settings says a titlebar's does.
static void titlebar_double_click(void) {
  NSString *action = [NSUserDefaults.standardUserDefaults stringForKey:@"AppleActionOnDoubleClick"];
  if ([action isEqualToString:@"Minimize"]) {
    [g_window performMiniaturize:nil];
  } else if (![action isEqualToString:@"None"]) {
    [g_window performZoom:nil];
  }
}

// Clipboard

static void set_clipboard(const uint8_t *text, size_t length) {
  NSString *s = [[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
  if (!s) return;
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:s forType:NSPasteboardTypeString];
}

static size_t get_clipboard(uint8_t *buffer, size_t capacity) {
  NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  const char *utf8 = s.UTF8String;
  if (!utf8) return 0;
  size_t n = strlen(utf8);
  if (buffer && capacity) memcpy(buffer, utf8, n < capacity ? n : capacity);
  return n;
}

// Accessibility
//
// The app sends the tree after any frame that changed it (set_accessibility).
// The shell keeps a copy and makes NSAccessibilityElements from it only
// once an assistive app has asked the view for its children, and from then
// on after every change. Elements are kept by node id, so VoiceOver's
// cursor stays on an element while it moves or changes. Frames are kept in
// view points and turned into screen coordinates when asked for.

typedef struct {
  uint64_t id;
  int32_t parent;
  uint32_t role, flags;
  NSRect frame;
  char *label, *value; // malloc'd, or NULL
} Shell_Node;

static Shell_Node *g_nodes;
static uint32_t g_node_count, g_node_cap;
static bool g_access_dirty; // the nodes changed since the elements were made
static bool g_access_seen; // an assistive app asked for the tree
static bool g_access_changed; // set_accessibility ran this frame
static NSMutableDictionary<NSNumber *, NSAccessibilityElement *> *g_elements;
static NSArray *g_access_top; // the view's children
static NSArray *g_access_all; // every element in node order
static uint64_t g_access_focus;

static void access_event(uint32_t kind, uint64_t id) {
  push_event((Event){.kind = kind, .target = id, .time = CACurrentMediaTime()});
  request_redraw();
}

@interface Access_Element : NSAccessibilityElement
@property uint64_t node_id;
@property NSRect view_frame;
@property uint32_t node_flags;
@end

@implementation Access_Element
- (NSRect)accessibilityFrame { return NSAccessibilityFrameInView(g_view, self.view_frame); }
- (BOOL)isAccessibilityFocused { return (self.node_flags & ACCESS_FOCUSED) != 0; }
- (BOOL)isAccessibilityEnabled { return (self.node_flags & ACCESS_DISABLED) == 0; }
- (void)setAccessibilityFocused:(BOOL)focused {
  if (focused) access_event(EVENT_ACCESS_FOCUS, self.node_id);
}
// NSAccessibilityElement answers every selector, so AXPress is only offered
// where it does something.
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
  if (selector == @selector(accessibilityPerformPress)) return NO;
  return [super isAccessibilitySelectorAllowed:selector];
}
@end

// Buttons, rows and menu items: AXPress goes to the app as a click.
@interface Access_Pressable : Access_Element
@end

@implementation Access_Pressable
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
  if (selector == @selector(accessibilityPerformPress)) return YES;
  return [super isAccessibilitySelectorAllowed:selector];
}
- (BOOL)accessibilityPerformPress {
  access_event(EVENT_ACCESS_PRESS, self.node_id);
  return YES;
}
@end

static NSAccessibilityRole access_role(uint32_t role) {
  switch (role) {
  case ACCESS_BUTTON: return NSAccessibilityButtonRole;
  case ACCESS_TEXT_FIELD: return NSAccessibilityTextFieldRole;
  case ACCESS_STATIC_TEXT: return NSAccessibilityStaticTextRole;
  case ACCESS_LIST: return NSAccessibilityListRole;
  case ACCESS_TABLE: return NSAccessibilityTableRole;
  case ACCESS_ROW: return NSAccessibilityRowRole;
  case ACCESS_MENU: return NSAccessibilityMenuRole;
  case ACCESS_MENU_ITEM: return NSAccessibilityMenuItemRole;
  case ACCESS_SLIDER: return NSAccessibilitySliderRole;
  default: return NSAccessibilityGroupRole;
  }
}

static bool access_pressable(uint32_t role) {
  return role == ACCESS_BUTTON || role == ACCESS_ROW || role == ACCESS_MENU_ITEM;
}

static NSString *node_string(const char *s) { return s ? [NSString stringWithUTF8String:s] : nil; }

static void set_accessibility(const Access_Node *nodes, uint32_t count) {
  for (uint32_t i = 0; i < g_node_count; i++) {
    free(g_nodes[i].label);
    free(g_nodes[i].value);
  }
  if (count > g_node_cap) {
    g_node_cap = count * 2;
    g_nodes = realloc(g_nodes, g_node_cap * sizeof(Shell_Node));
  }
  for (uint32_t i = 0; i < count; i++) {
    const Access_Node *n = &nodes[i];
    g_nodes[i] = (Shell_Node){
        .id = n->id,
        .parent = n->parent,
        .role = n->role,
        .flags = n->flags,
        .frame = NSMakeRect(n->frame[0], n->frame[1], n->frame[2], n->frame[3]),
        .label = n->label ? strdup(n->label) : NULL,
        .value = n->value ? strdup(n->value) : NULL,
    };
  }
  g_node_count = count;
  g_access_dirty = true;
  g_access_changed = true;
}

static void access_materialize(void) {
  if (!g_access_dirty) return;
  g_access_dirty = false;
  NSMutableDictionary *next = [NSMutableDictionary dictionaryWithCapacity:g_node_count];
  NSMutableArray *all = [NSMutableArray arrayWithCapacity:g_node_count];
  NSMutableArray *top = [NSMutableArray array];
  NSMutableArray *kids = [NSMutableArray arrayWithCapacity:g_node_count];
  for (uint32_t i = 0; i < g_node_count; i++) {
    Shell_Node *n = &g_nodes[i];
    Class cls = access_pressable(n->role) ? Access_Pressable.class : Access_Element.class;
    Access_Element *el = (Access_Element *)g_elements[@(n->id)];
    if (!el || el.class != cls) el = [cls new];
    el.node_id = n->id;
    el.view_frame = n->frame;
    el.node_flags = n->flags;
    el.accessibilityElement = YES;
    el.accessibilityRole = access_role(n->role);
    NSString *label = node_string(n->label), *value = node_string(n->value);
    el.accessibilityLabel = label;
    el.accessibilityValue = n->role == ACCESS_STATIC_TEXT ? (value ?: label) : value;
    if (n->role == ACCESS_TEXT_FIELD) el.accessibilityPlaceholderValue = label;
    el.accessibilitySelected = (n->flags & ACCESS_SELECTED) != 0;
    next[@(n->id)] = el;
    [all addObject:el];
    [kids addObject:[NSMutableArray array]];
    if (n->parent >= 0 && (uint32_t)n->parent < i) {
      [kids[n->parent] addObject:el];
      el.accessibilityParent = all[n->parent];
    } else {
      [top addObject:el];
      el.accessibilityParent = g_view;
    }
  }
  for (uint32_t i = 0; i < g_node_count; i++) {
    Access_Element *el = all[i];
    el.accessibilityChildren = kids[i];
    if (g_nodes[i].role == ACCESS_TABLE || g_nodes[i].role == ACCESS_LIST) {
      NSMutableArray *rows = [NSMutableArray array];
      for (Access_Element *k in kids[i])
        if (k.accessibilityRole == NSAccessibilityRowRole) [rows addObject:k];
      el.accessibilityRows = rows;
      NSMutableArray *selected = [NSMutableArray array];
      for (Access_Element *k in rows)
        if (k.node_flags & ACCESS_SELECTED) [selected addObject:k];
      el.accessibilitySelectedRows = selected;
    }
  }
  g_elements = next;
  g_access_all = all;
  g_access_top = top;
}

static Access_Element *access_focused(void) {
  for (Access_Element *el in g_access_all)
    if (el.node_flags & ACCESS_FOCUSED) return el;
  return nil;
}

// After a frame that changed the tree, while an assistive app listens:
// make the elements and say what changed.
static void access_frame_done(void) {
  if (!g_access_changed) return;
  g_access_changed = false;
  if (!g_access_seen) return;
  access_materialize();
  NSAccessibilityPostNotification(g_view, NSAccessibilityLayoutChangedNotification);
  Access_Element *focus = access_focused();
  uint64_t id = focus ? focus.node_id : 0;
  if (id != g_access_focus) {
    g_access_focus = id;
    if (focus) NSAccessibilityPostNotification(focus, NSAccessibilityFocusedUIElementChangedNotification);
  } else if (focus && focus.accessibilityRole == NSAccessibilityTextFieldRole) {
    NSAccessibilityPostNotification(focus, NSAccessibilityValueChangedNotification);
  }
}

// Input

static uint32_t modifiers(NSEventModifierFlags flags) {
  uint32_t m = 0;
  if (flags & NSEventModifierFlagShift) m |= MODIFIER_SHIFT;
  if (flags & NSEventModifierFlagControl) m |= MODIFIER_CONTROL;
  if (flags & NSEventModifierFlagOption) m |= MODIFIER_ALT;
  if (flags & NSEventModifierFlagCommand) m |= MODIFIER_SUPER;
  if (flags & NSEventModifierFlagCapsLock) m |= MODIFIER_CAPS_LOCK;
  return m;
}

static uint32_t scroll_phase(NSEventPhase phase) {
  if (phase & NSEventPhaseBegan) return SCROLL_PHASE_BEGAN;
  if (phase & NSEventPhaseChanged) return SCROLL_PHASE_CHANGED;
  if (phase & NSEventPhaseStationary) return SCROLL_PHASE_STATIONARY;
  if (phase & NSEventPhaseEnded) return SCROLL_PHASE_ENDED;
  if (phase & NSEventPhaseCancelled) return SCROLL_PHASE_CANCELLED;
  if (phase & NSEventPhaseMayBegin) return SCROLL_PHASE_MAY_BEGIN;
  return SCROLL_PHASE_NONE;
}

@interface Metal_View : NSView <NSTextInputClient>
@end

@implementation Metal_View

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  self.wantsLayer = YES;
  self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
  self.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
  return self;
}

- (CALayer *)makeBackingLayer {
  g_layer = [CAMetalLayer layer];
  g_layer.device = MTLCreateSystemDefaultDevice();
  // An sRGB format, so blending happens in linear space. See src/render.
  g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
  g_layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  g_layer.framebufferOnly = YES;
  // Two drawables while idle, see update_display_link.
  g_layer.maximumDrawableCount = 2;
  return g_layer;
}

- (BOOL)isFlipped { return YES; }
// A view that isn't opaque moves the window from under the titlebar unless
// it says no. The app's buttons are there, and set_drag_regions does the rest.
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)update_drawable_size {
  CGFloat scale = self.window ? self.window.backingScaleFactor : 1;
  g_layer.contentsScale = scale;
  g_layer.drawableSize = g_parked ? CGSizeMake(1, 1) : CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
}

- (void)resized {
  [self update_drawable_size];
  push_event((Event){
      .kind = EVENT_RESIZE,
      .x = self.bounds.size.width,
      .y = self.bounds.size.height,
  });
  // Draw now, not on the next run loop pass, so the window never shows a
  // stretched frame while resizing.
  draw_frame();
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self resized];
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [self resized];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
  NSTrackingAreaOptions options = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                  NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect;
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
}

// NSEvent throws on properties that don't apply to the event's type:
// clickCount exists only on mouse down and up, phase and the scrolling deltas
// only on scroll wheel events, isARepeat only on key down and up.
static Event mouse_event(NSView *view, NSEvent *e, uint32_t kind, uint32_t button) {
  NSPoint p = [view convertPoint:e.locationInWindow fromView:nil];
  bool click = kind == EVENT_MOUSE_DOWN || kind == EVENT_MOUSE_UP;
  return (Event){
      .kind = kind,
      .modifiers = modifiers(e.modifierFlags),
      .time = e.timestamp,
      .x = p.x,
      .y = p.y,
      .button = button,
      .click_count = click ? (uint32_t)e.clickCount : 0,
  };
}

- (void)mouseDown:(NSEvent *)e {
  if (in_drag_region([self convertPoint:e.locationInWindow fromView:nil])) {
    if (e.clickCount == 2) {
      titlebar_double_click();
    } else {
      [g_window performWindowDragWithEvent:e];
    }
    return;
  }
  push_event(mouse_event(self, e, EVENT_MOUSE_DOWN, MOUSE_BUTTON_LEFT));
}
- (void)mouseUp:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_UP, MOUSE_BUTTON_LEFT)); }
- (void)rightMouseDown:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_DOWN, MOUSE_BUTTON_RIGHT)); }
- (void)rightMouseUp:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_UP, MOUSE_BUTTON_RIGHT)); }
- (void)otherMouseDown:(NSEvent *)e {
  if (e.buttonNumber <= MOUSE_BUTTON_FORWARD) push_event(mouse_event(self, e, EVENT_MOUSE_DOWN, (uint32_t)e.buttonNumber));
}
- (void)otherMouseUp:(NSEvent *)e {
  if (e.buttonNumber <= MOUSE_BUTTON_FORWARD) push_event(mouse_event(self, e, EVENT_MOUSE_UP, (uint32_t)e.buttonNumber));
}
- (void)mouseMoved:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_MOVE, 0)); }
- (void)mouseDragged:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_MOVE, 0)); }
- (void)rightMouseDragged:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_MOVE, 0)); }
- (void)otherMouseDragged:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_MOVE, 0)); }
- (void)mouseExited:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_LEAVE, 0)); }

- (void)scrollWheel:(NSEvent *)e {
  Event ev = mouse_event(self, e, EVENT_SCROLL, 0);
  ev.dx = e.scrollingDeltaX;
  ev.dy = e.scrollingDeltaY;
  ev.precise = e.hasPreciseScrollingDeltas;
  ev.phase = scroll_phase(e.phase);
  ev.momentum_phase = scroll_phase(e.momentumPhase);
  push_event(ev);
}

// Unlisted key codes are KEY_NONE.
static const uint8_t g_keys[128] = {
    [kVK_ANSI_A] = KEY_A, [kVK_ANSI_B] = KEY_B, [kVK_ANSI_C] = KEY_C, [kVK_ANSI_D] = KEY_D,
    [kVK_ANSI_E] = KEY_E, [kVK_ANSI_F] = KEY_F, [kVK_ANSI_G] = KEY_G, [kVK_ANSI_H] = KEY_H,
    [kVK_ANSI_I] = KEY_I, [kVK_ANSI_J] = KEY_J, [kVK_ANSI_K] = KEY_K, [kVK_ANSI_L] = KEY_L,
    [kVK_ANSI_M] = KEY_M, [kVK_ANSI_N] = KEY_N, [kVK_ANSI_O] = KEY_O, [kVK_ANSI_P] = KEY_P,
    [kVK_ANSI_Q] = KEY_Q, [kVK_ANSI_R] = KEY_R, [kVK_ANSI_S] = KEY_S, [kVK_ANSI_T] = KEY_T,
    [kVK_ANSI_U] = KEY_U, [kVK_ANSI_V] = KEY_V, [kVK_ANSI_W] = KEY_W, [kVK_ANSI_X] = KEY_X,
    [kVK_ANSI_Y] = KEY_Y, [kVK_ANSI_Z] = KEY_Z,
    [kVK_ANSI_0] = KEY_DIGIT_0, [kVK_ANSI_1] = KEY_DIGIT_1, [kVK_ANSI_2] = KEY_DIGIT_2, [kVK_ANSI_3] = KEY_DIGIT_3,
    [kVK_ANSI_4] = KEY_DIGIT_4, [kVK_ANSI_5] = KEY_DIGIT_5, [kVK_ANSI_6] = KEY_DIGIT_6, [kVK_ANSI_7] = KEY_DIGIT_7,
    [kVK_ANSI_8] = KEY_DIGIT_8, [kVK_ANSI_9] = KEY_DIGIT_9,
    [kVK_Return] = KEY_RETURN, [kVK_Tab] = KEY_TAB, [kVK_Space] = KEY_SPACE, [kVK_Delete] = KEY_BACKSPACE,
    [kVK_ForwardDelete] = KEY_DELETE, [kVK_Escape] = KEY_ESCAPE, [kVK_Home] = KEY_HOME, [kVK_End] = KEY_END,
    [kVK_PageUp] = KEY_PAGE_UP, [kVK_PageDown] = KEY_PAGE_DOWN, [kVK_LeftArrow] = KEY_LEFT,
    [kVK_RightArrow] = KEY_RIGHT, [kVK_UpArrow] = KEY_UP, [kVK_DownArrow] = KEY_DOWN, [kVK_ANSI_Grave] = KEY_GRAVE,
    [kVK_ANSI_KeypadEnter] = KEY_KEYPAD_ENTER,
    [kVK_F1] = KEY_F1, [kVK_F2] = KEY_F2, [kVK_F3] = KEY_F3, [kVK_F4] = KEY_F4,
    [kVK_F5] = KEY_F5, [kVK_F6] = KEY_F6, [kVK_F7] = KEY_F7, [kVK_F8] = KEY_F8,
    [kVK_F9] = KEY_F9, [kVK_F10] = KEY_F10, [kVK_F11] = KEY_F11, [kVK_F12] = KEY_F12,
};

static Event key_event(NSEvent *e, uint32_t kind) {
  return (Event){
      .kind = kind,
      .modifiers = modifiers(e.modifierFlags),
      .time = e.timestamp,
      .key = e.keyCode < 128 ? g_keys[e.keyCode] : KEY_NONE,
      .repeat = e.type == NSEventTypeKeyDown && e.isARepeat,
  };
}

// Not passed to super, so unhandled keys don't beep. While a text field has
// the focus, keys go through the input context first. What it turns into
// text or marked text reaches the app as text events only; keys it turns
// into commands (arrows, Delete, Return, Escape) reach the app as key
// events, and so do Command shortcuts. While there is marked text, every
// key belongs to the input method.
- (void)keyDown:(NSEvent *)e {
  bool command = (e.modifierFlags & NSEventModifierFlagCommand) != 0;
  if (g_ti.active && (!command || g_ti.marked_start >= 0)) {
    bool had_marked = g_ti.marked_start >= 0;
    g_ime_handled = false;
    [self.inputContext handleEvent:e];
    if (had_marked || g_ime_handled) return;
  }
  push_event(key_event(e, EVENT_KEY_DOWN));
}

// NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)range { text_insert(string, range); }

- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)range {
  text_set_marked(string, selected, range);
}

- (void)unmarkText { text_unmark(); }

// The key event that led here goes to the app as a key event.
- (void)doCommandBySelector:(SEL)selector {}

- (BOOL)hasMarkedText { return g_ti.active && g_ti.marked_start >= 0; }

- (NSRange)markedRange {
  if (!g_ti.active || g_ti.marked_start < 0) return NSMakeRange(NSNotFound, 0);
  NSUInteger lo = utf16_of_byte(g_ti.bytes, g_ti.length, (uint32_t)g_ti.marked_start);
  NSUInteger hi = utf16_of_byte(g_ti.bytes, g_ti.length, (uint32_t)g_ti.marked_end);
  return NSMakeRange(lo, hi - lo);
}

- (NSRange)selectedRange {
  if (!g_ti.active) return NSMakeRange(NSNotFound, 0);
  NSUInteger lo = utf16_of_byte(g_ti.bytes, g_ti.length, g_ti.sel_start);
  NSUInteger hi = utf16_of_byte(g_ti.bytes, g_ti.length, g_ti.sel_end);
  return NSMakeRange(lo, hi - lo);
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual {
  if (!g_ti.active) return nil;
  NSString *all = [[NSString alloc] initWithBytes:g_ti.bytes length:g_ti.length encoding:NSUTF8StringEncoding];
  NSRange r = NSIntersectionRange(range, NSMakeRange(0, all.length));
  if (r.length == 0 && range.location > all.length) return nil;
  r = [all rangeOfComposedCharacterSequencesForRange:r];
  if (actual) *actual = r;
  return [[NSAttributedString alloc] initWithString:[all substringWithRange:r]];
}

// The candidate window goes under the marked text, or the caret.
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual {
  if (actual) *actual = range;
  NSRect r = g_ti.caret;
  if (r.size.height <= 0) r.size.height = 16;
  return [self.window convertRectToScreen:[self convertRect:r toView:nil]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }

// Accessibility: the view is a group whose children come from the app.

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"TIDALfast"; }

- (NSArray *)accessibilityChildren {
  if (!g_access_seen) {
    g_access_seen = true;
    request_redraw();
  }
  access_materialize();
  return g_access_top ?: @[];
}

- (id)accessibilityHitTest:(NSPoint)point {
  g_access_seen = true;
  access_materialize();
  NSPoint p = [self convertPoint:[self.window convertPointFromScreen:point] fromView:nil];
  for (Access_Element *el in g_access_all.reverseObjectEnumerator)
    if (NSPointInRect(p, el.view_frame)) return el;
  return self;
}

- (id)accessibilityFocusedUIElement {
  g_access_seen = true;
  access_materialize();
  return access_focused() ?: self;
}
- (void)keyUp:(NSEvent *)e { push_event(key_event(e, EVENT_KEY_UP)); }
- (void)flagsChanged:(NSEvent *)e { push_event(key_event(e, EVENT_MODIFIERS_CHANGED)); }

- (void)display_link_tick:(CADisplayLink *)link {
  g_last_tick = CACurrentMediaTime();
  double interval = link.targetTimestamp - link.timestamp;
  if (interval > 0) g_tick_interval = interval;
  draw_frame();
}

@end

// While the window can't be seen (minimized, hidden or covered), its
// drawables shrink to a pixel and go back to the system: 44 MB at 1500x950
// points on a 2x display. Each frame at that size replaces one of them, the
// one on screen first, so parking draws three, the most the layer keeps: a
// third from the display link can outlive the drop back to two, see
// update_display_link. They take 1 to 12 ms each. Frames go on at that
// size as playback asks for them. When the window can be seen again it
// draws at full size straight away, as a resize does. Only a change parks,
// not the state at launch, and TIDALFAST_CAPTURE turns it off, since a
// capture of a covered window must still show the window. shown is an
// unhide or a deminiaturize, after which the occlusion state can lag: the
// window draws at full size, and a later change parks it again.
static void update_parking(bool shown) {
  bool visible = shown || (g_window.occlusionState & NSWindowOcclusionStateVisible) != 0;
  bool park = !visible && !g_never_park;
  if (park == g_parked) return;
  g_parked = park;
  [(Metal_View *)g_view update_drawable_size];
  int frames = g_parked ? 3 : 1;
  for (int i = 0; i < frames; i++) draw_frame();
}

// The link runs only while the app animates and the window is on screen. A
// hidden or minimized window gets no animation frames, but explicit redraws
// still draw.
static void update_display_link(void) {
  bool visible = (g_window.occlusionState & NSWindowOcclusionStateVisible) != 0;
  bool paused = !(g_animating && visible);
  // Count unpausing as a tick, so redraws start waiting for the link right
  // away and fall back to drawing directly if its first tick never comes.
  if (g_display_link.paused && !paused) g_last_tick = CACurrentMediaTime();
  g_display_link.paused = paused;
  // Each drawable is the window's size in pixels, about 12 MB at 1100x700
  // points on a 2x display. Frames drawn on demand need only two, one on
  // screen and one being drawn. Frames on every tick need three: with two,
  // a run could lock into waiting most of a refresh in nextDrawable on
  // every frame.
  NSUInteger drawables = paused ? 2 : 3;
  if (g_layer.maximumDrawableCount != drawables) {
    g_layer.maximumDrawableCount = drawables;
    // The layer lets go of the third drawable in the next nextDrawable, and
    // an idle window may not draw again for a long time.
    if (paused) request_redraw();
  }
}

// TIDALFAST_SHELL_TEST runs steps against the shell's own entry points,
// for checking text input and accessibility without a person at the
// keyboard: "2:key=cmd+f;3:mark=にほんご;4:commit=日本語;6:ax-dump;7:ax-press=Next".
// Steps are seconds after launch and a command, separated by semicolons.
// Commands joined with | run together, with no frame between them.
//
//   key=cmd+shift+z     a key down and up, as from the keyboard (letters, escape, return, tab, left...)
//   mark=text           setMarkedText, with the caret at the end of text
//   commit=text         insertText
//   mark-range=l,n,text setMarkedText replacing UTF-16 units [l, l+n)
//   commit-range=l,n,text insertText replacing UTF-16 units [l, l+n)
//   commit-marked=text  insertText replacing what markedRange says, as an input method does
//   unmark              unmarkText
//   clean=hex           print what field_sanitize makes of the bytes, in hex
//   ime                 print what NSTextInputClient answers
//   ax-dump             print the window's accessibility tree, as an assistive app reads it
//   ax-press=label      AXPress on the first element whose label or value starts with label
//   menu=title          the menu bar's item with that title, as clicking it does
//   hide, unhide        hide the app and show it again, as Cmd-H and clicking its Dock icon do
//   capture=path        copy the last TIDALFAST_CAPTURE frame to path
//   quit

static Key key_named(NSString *name) {
  NSDictionary *named = @{
    @"return" : @(KEY_RETURN), @"tab" : @(KEY_TAB), @"space" : @(KEY_SPACE), @"backspace" : @(KEY_BACKSPACE),
    @"escape" : @(KEY_ESCAPE), @"delete" : @(KEY_DELETE), @"home" : @(KEY_HOME), @"end" : @(KEY_END),
    @"left" : @(KEY_LEFT), @"right" : @(KEY_RIGHT), @"down" : @(KEY_DOWN), @"up" : @(KEY_UP),
  };
  if (named[name]) return [named[name] unsignedIntValue];
  if (name.length == 1) {
    unichar c = [name characterAtIndex:0];
    if (c >= 'a' && c <= 'z') return KEY_A + (c - 'a');
    if (c >= '0' && c <= '9') return KEY_DIGIT_0 + (c - '0');
  }
  return KEY_NONE;
}

static void test_key(NSString *spec) {
  uint32_t mods = 0;
  NSArray *parts = [spec componentsSeparatedByString:@"+"];
  for (NSString *p in parts) {
    if ([p isEqualToString:@"cmd"]) mods |= MODIFIER_SUPER;
    else if ([p isEqualToString:@"shift"]) mods |= MODIFIER_SHIFT;
    else if ([p isEqualToString:@"opt"]) mods |= MODIFIER_ALT;
    else if ([p isEqualToString:@"ctrl"]) mods |= MODIFIER_CONTROL;
  }
  Key key = key_named(parts.lastObject);
  if (key == KEY_NONE) {
    fprintf(stderr, "shell: test: no key named %s\n", [parts.lastObject UTF8String]);
    return;
  }
  double now = CACurrentMediaTime();
  push_event((Event){.kind = EVENT_KEY_DOWN, .modifiers = mods, .key = key, .time = now});
  push_event((Event){.kind = EVENT_KEY_UP, .modifiers = mods, .key = key, .time = now});
  request_redraw();
}

static void test_menu(NSString *title) {
  for (NSMenuItem *top in NSApp.mainMenu.itemArray) {
    NSMenu *menu = top.submenu;
    NSInteger i = [menu indexOfItemWithTitle:title];
    if (i >= 0) {
      [menu performActionForItemAtIndex:i];
      return;
    }
  }
  fprintf(stderr, "shell: test: no menu item %s\n", title.UTF8String);
}

static void test_ime_state(void) {
  Metal_View *v = (Metal_View *)g_view;
  NSRange marked = v.markedRange, sel = v.selectedRange;
  NSAttributedString *all = [v attributedSubstringForProposedRange:NSMakeRange(0, 1 << 20) actualRange:NULL];
  NSRect r = [v firstRectForCharacterRange:marked actualRange:NULL];
  fprintf(stderr, "shell: ime: active %d, text \"%s\", marked %s, selected {%lu, %lu}, first rect {%.0f, %.0f, %.0f, %.0f}\n",
          g_ti.active, all.string.UTF8String ?: "", v.hasMarkedText ? [NSString stringWithFormat:@"{%lu, %lu}", (unsigned long)marked.location, (unsigned long)marked.length].UTF8String : "none",
          (unsigned long)sel.location, (unsigned long)sel.length, r.origin.x, r.origin.y, r.size.width, r.size.height);
}

static NSString *ax_string(id value) {
  if (!value) return nil;
  if ([value isKindOfClass:NSString.class]) return value;
  if ([value isKindOfClass:NSAttributedString.class]) return [value string];
  return [value description];
}

static bool ax_can_press(id el) {
  return [el respondsToSelector:@selector(accessibilityPerformPress)] &&
         (![el respondsToSelector:@selector(isAccessibilitySelectorAllowed:)] ||
          [el isAccessibilitySelectorAllowed:@selector(accessibilityPerformPress)]);
}

// ax_walk reads the tree through the NSAccessibility protocol from the
// window down, the way AppKit answers an assistive app.
static void ax_walk(id el, int depth, NSString *press, bool *pressed) {
  // AppKit puts private proxies among a window's children.
  if (depth > 12 || ![el respondsToSelector:@selector(accessibilityRole)]) return;
  NSString *role = [el accessibilityRole];
  NSString *label = ax_string([el accessibilityLabel]) ?: ax_string([el accessibilityTitle]);
  NSString *value = ax_string([el accessibilityValue]);
  NSRect f = [el accessibilityFrame];
  if (!press) {
    fprintf(stderr, "shell: ax: %*s%s \"%s\"%s%s%s {%.0f, %.0f, %.0f, %.0f}%s%s\n", depth * 2, "", role.UTF8String ?: "?",
            label.UTF8String ?: "", value ? " = \"" : "", value.UTF8String ?: "", value ? "\"" : "", f.origin.x, f.origin.y,
            f.size.width, f.size.height, [el isAccessibilityFocused] ? " focused" : "",
            ax_can_press(el) ? " press" : "");
  } else if (!*pressed && ([label hasPrefix:press] || [value hasPrefix:press]) &&
             ax_can_press(el)) {
    fprintf(stderr, "shell: ax: pressing %s \"%s\"\n", role.UTF8String, label.UTF8String ?: value.UTF8String);
    [el accessibilityPerformPress];
    *pressed = true;
    return;
  }
  for (id child in [el accessibilityChildren]) ax_walk(child, depth + 1, press, pressed);
}

static void test_clean(NSString *hex) {
  uint32_t n = (uint32_t)hex.length / 2;
  char *in = malloc(n + 1), *out = malloc(n + 1);
  for (uint32_t i = 0; i < n; i++) in[i] = (char)strtoul([hex substringWithRange:NSMakeRange(i * 2, 2)].UTF8String, NULL, 16);
  uint32_t o = field_sanitize(in, n, out);
  fprintf(stderr, "shell: clean %s -> ", hex.UTF8String);
  for (uint32_t i = 0; i < o; i++) fprintf(stderr, "%02x", (uint8_t)out[i]);
  fprintf(stderr, "\n");
  free(in);
  free(out);
}

// test_range splits "location,length,text" for mark-range and commit-range.
static NSRange test_range(NSString *arg, NSString **text) {
  NSArray *parts = [arg componentsSeparatedByString:@","];
  if (parts.count < 3) {
    *text = @"";
    return NSMakeRange(NSNotFound, 0);
  }
  *text = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@","];
  return NSMakeRange((NSUInteger)[parts[0] integerValue], (NSUInteger)[parts[1] integerValue]);
}

static void test_step(NSString *command, NSString *arg) {
  NSString *text;
  if ([command isEqualToString:@"key"]) {
    test_key(arg);
  } else if ([command isEqualToString:@"mark"]) {
    [(Metal_View *)g_view setMarkedText:arg selectedRange:NSMakeRange(arg.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  } else if ([command isEqualToString:@"commit"]) {
    [(Metal_View *)g_view insertText:arg replacementRange:NSMakeRange(NSNotFound, 0)];
  } else if ([command isEqualToString:@"mark-range"]) {
    NSRange r = test_range(arg, &text);
    [(Metal_View *)g_view setMarkedText:text selectedRange:NSMakeRange(text.length, 0) replacementRange:r];
  } else if ([command isEqualToString:@"commit-range"]) {
    NSRange r = test_range(arg, &text);
    [(Metal_View *)g_view insertText:text replacementRange:r];
  } else if ([command isEqualToString:@"commit-marked"]) {
    [(Metal_View *)g_view insertText:arg replacementRange:((Metal_View *)g_view).markedRange];
  } else if ([command isEqualToString:@"clean"]) {
    test_clean(arg);
  } else if ([command isEqualToString:@"unmark"]) {
    [(Metal_View *)g_view unmarkText];
  } else if ([command isEqualToString:@"ime"]) {
    test_ime_state();
  } else if ([command isEqualToString:@"ax-dump"] || [command isEqualToString:@"ax-press"]) {
    bool pressed = false;
    ax_walk(g_window, 0, [command isEqualToString:@"ax-press"] ? arg : nil, &pressed);
    if ([command isEqualToString:@"ax-press"] && !pressed) fprintf(stderr, "shell: ax: nothing to press called %s\n", arg.UTF8String);
  } else if ([command isEqualToString:@"capture"]) {
    const char *from = getenv("TIDALFAST_CAPTURE");
    if (!from || copyfile(from, arg.fileSystemRepresentation, NULL, COPYFILE_DATA) != 0)
      fprintf(stderr, "shell: test: couldn't copy the capture to %s\n", arg.UTF8String);
    else
      fprintf(stderr, "shell: test: captured %s\n", arg.UTF8String);
  } else if ([command isEqualToString:@"size"]) {
    NSArray *wh = [arg componentsSeparatedByString:@","];
    double w = [wh.firstObject doubleValue], h = wh.count > 1 ? [wh[1] doubleValue] : 0;
    if (w < 1 || h < 1) {
      fprintf(stderr, "shell: test: size wants w,h\n");
      return;
    }
    [g_window setContentSize:NSMakeSize(w, h)];
  } else if ([command isEqualToString:@"hide"]) {
    [NSApp hide:nil];
  } else if ([command isEqualToString:@"unhide"]) {
    [NSApp unhide:nil];
    [NSApp activateIgnoringOtherApps:YES];
  } else if ([command isEqualToString:@"menu"]) {
    test_menu(arg);
  } else if ([command isEqualToString:@"quit"]) {
    [NSApp terminate:nil];
  } else {
    fprintf(stderr, "shell: test: unknown step %s\n", command.UTF8String);
  }
}

static void setup_shell_test(void) {
  const char *script = getenv("TIDALFAST_SHELL_TEST");
  if (!script) return;
  for (NSString *step in [@(script) componentsSeparatedByString:@";"]) {
    NSRange colon = [step rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    double at = [[step substringToIndex:colon.location] doubleValue];
    NSArray *commands = [[step substringFromIndex:colon.location + 1] componentsSeparatedByString:@"|"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      fprintf(stderr, "shell: test step %s\n", step.UTF8String);
      for (NSString *rest in commands) {
        NSRange eq = [rest rangeOfString:@"="];
        NSString *command = eq.location == NSNotFound ? rest : [rest substringToIndex:eq.location];
        NSString *arg = eq.location == NSNotFound ? @"" : [rest substringFromIndex:eq.location + 1];
        test_step(command, arg);
      }
    });
  }
}

// App

@interface App_Delegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

// TIDALFAST_BLUR_REFERENCE=<material>[,<height>] puts AppKit's blur of the
// window's own content over its bottom, where the player bar goes, to
// compare the renderer's blur with. The app leaves the bar out then.
static void setup_blur_reference(void) {
  const char *env = getenv("TIDALFAST_BLUR_REFERENCE");
  if (!env || !*env) return;
  NSArray<NSString *> *parts = [@(env) componentsSeparatedByString:@","];
  NSDictionary<NSString *, NSNumber *> *materials = @{
    @"titlebar" : @(NSVisualEffectMaterialTitlebar),
    @"selection" : @(NSVisualEffectMaterialSelection),
    @"menu" : @(NSVisualEffectMaterialMenu),
    @"popover" : @(NSVisualEffectMaterialPopover),
    @"sidebar" : @(NSVisualEffectMaterialSidebar),
    @"headerView" : @(NSVisualEffectMaterialHeaderView),
    @"sheet" : @(NSVisualEffectMaterialSheet),
    @"windowBackground" : @(NSVisualEffectMaterialWindowBackground),
    @"hudWindow" : @(NSVisualEffectMaterialHUDWindow),
    @"fullScreenUI" : @(NSVisualEffectMaterialFullScreenUI),
    @"toolTip" : @(NSVisualEffectMaterialToolTip),
    @"contentBackground" : @(NSVisualEffectMaterialContentBackground),
    @"underWindowBackground" : @(NSVisualEffectMaterialUnderWindowBackground),
    @"underPageBackground" : @(NSVisualEffectMaterialUnderPageBackground),
  };
  NSNumber *material = materials[parts[0]];
  if (!material) {
    fprintf(stderr, "shell: TIDALFAST_BLUR_REFERENCE: no material %s\n", parts[0].UTF8String);
    return;
  }
  CGFloat height = parts.count > 1 ? parts[1].doubleValue : 88;
  // Over the Metal view's layer: g_view is flipped, so the bottom is at
  // its height and the margin above the blur is what stretches.
  NSSize size = g_view.bounds.size;
  NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, size.height - height, size.width, height)];
  blur.material = material.integerValue;
  blur.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  blur.state = NSVisualEffectStateActive;
  blur.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [g_view addSubview:blur];
}

@implementation App_Delegate

// The menu bar's Take Memory Snapshot: SIGUSR1, which the app answers by
// writing a memory snapshot on its next frame (src/app/snapshot.odin).
- (void)takeMemorySnapshot:(id)sender {
  kill(getpid(), SIGUSR1);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  measure_mark("launched");
  NSRect frame = NSMakeRect(0, 0, 1100, 700);
  g_window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  g_window.title = @"TIDALfast";
  // The app draws the titlebar: the view goes under it and only the window's
  // buttons stay.
  g_window.titleVisibility = NSWindowTitleHidden;
  g_window.titlebarAppearsTransparent = YES;
  // An empty toolbar makes the titlebar a toolbar's height, as Finder's is,
  // which centres the window's buttons level with the app's Back and Forward.
  g_window.toolbar = [[NSToolbar alloc] initWithIdentifier:@"tidalfast"];
  g_window.toolbarStyle = NSWindowToolbarStyleUnified;
  g_window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
  g_window.delegate = self;
  g_window.acceptsMouseMovedEvents = YES;
  g_window.releasedWhenClosed = NO;

  g_view = [[Metal_View alloc] initWithFrame:frame];
  g_window.contentView = g_view;
  setup_blur_reference();
  [g_window center];

  g_display_link = [g_view displayLinkWithTarget:g_view selector:@selector(display_link_tick:)];
  g_display_link.paused = YES;
  [g_display_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeOcclusionStateNotification
                                                  object:g_window
                                                   queue:nil
                                              usingBlock:^(NSNotification *n) {
                                                update_parking(false);
                                                update_display_link();
                                              }];
  // A hidden app's or a minimized window's occlusion changes without the
  // notification above.
  g_never_park = getenv("TIDALFAST_CAPTURE") != NULL;
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  [center addObserverForName:NSApplicationDidHideNotification object:NSApp queue:nil usingBlock:^(NSNotification *n) {
    update_parking(false);
  }];
  [center addObserverForName:NSApplicationDidUnhideNotification object:NSApp queue:nil usingBlock:^(NSNotification *n) {
    update_parking(true);
  }];
  [center addObserverForName:NSWindowDidMiniaturizeNotification object:g_window queue:nil usingBlock:^(NSNotification *n) {
    update_parking(false);
  }];
  [center addObserverForName:NSWindowDidDeminiaturizeNotification object:g_window queue:nil usingBlock:^(NSNotification *n) {
    update_parking(true);
  }];
  // The app stops the caret blinking without the keyboard.
  for (NSNotificationName name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification ]) {
    [NSNotificationCenter.defaultCenter addObserverForName:name
                                                    object:g_window
                                                     queue:nil
                                                usingBlock:^(NSNotification *n) {
                                                  request_redraw();
                                                }];
  }

  g_shell = (Shell){
      .surface = (__bridge void *)g_layer,
      .request_redraw = request_redraw,
      .set_now_playing = set_now_playing,
      .set_text_input = set_text_input,
      .set_clipboard = set_clipboard,
      .get_clipboard = get_clipboard,
      .set_accessibility = set_accessibility,
      .set_drag_regions = set_drag_regions,
  };
  setup_remote_commands();

  if (!open_app(&g_app)) {
    [NSApp terminate:nil];
    return;
  }
  measure_mark("dylib");
  g_wake_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, wake_timer_fired, NULL);
  CFRunLoopAddTimer(g_main_run_loop, g_wake_timer, kCFRunLoopCommonModes);
  [(Metal_View *)g_view update_drawable_size];
  @autoreleasepool {
    g_app.api.init(&g_memory, &g_shell);
  }

  CFRunLoopObserverRef observer =
      CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting, true, 0, before_waiting, NULL);
  CFRunLoopAddObserver(g_main_run_loop, observer, kCFRunLoopCommonModes);
  // Repeating with a huge interval so it stays valid after it fires and can
  // be rearmed with CFRunLoopTimerSetNextFireDate.
  g_tick_fallback = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, tick_fallback_fired, NULL);
  CFRunLoopAddTimer(g_main_run_loop, g_tick_fallback, kCFRunLoopCommonModes);

#if HOT_RELOAD
  watch_app();
#endif

  [g_window makeKeyAndOrderFront:nil];
  [g_window makeFirstResponder:g_view];
  [NSApp activateIgnoringOtherApps:YES];
  measure_mark("window");
  setup_shell_test();
  request_redraw();
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  if (g_app.api.shutdown) g_app.api.shutdown(&g_memory);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return YES;
}

// In full screen the empty toolbar hides with the menu bar, so the view's
// top is free, as it was without one.
- (NSApplicationPresentationOptions)window:(NSWindow *)window
      willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)options {
  return options | NSApplicationPresentationAutoHideToolbar;
}

@end

static void *reserve(size_t size) {
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED) {
    fprintf(stderr, "shell: mmap of %zu bytes failed\n", size);
    exit(1);
  }
  return p;
}

static NSMenu *main_menu(void) {
  NSMenu *bar = [NSMenu new];
  NSMenuItem *app_item = [NSMenuItem new];
  [bar addItem:app_item];
  NSMenu *app_menu = [NSMenu new];
  [app_menu addItemWithTitle:@"Take Memory Snapshot" action:@selector(takeMemorySnapshot:) keyEquivalent:@""];
  [app_menu addItem:NSMenuItem.separatorItem];
  [app_menu addItemWithTitle:@"Quit TIDALfast" action:@selector(terminate:) keyEquivalent:@"q"];
  app_item.submenu = app_menu;
  return bar;
}

int main(int argc, const char *argv[]) {
  // SIGUSR1 asks the app for a memory snapshot (src/app/snapshot.odin),
  // and the app sets its handler once it's loaded. Until then it's
  // ignored, so the menu item can't quit the app.
  signal(SIGUSR1, SIG_IGN);
  @autoreleasepool {
    measure_init();
    measure_mark("main");
    g_start_time = CACurrentMediaTime();
    g_main_run_loop = CFRunLoopGetMain();

    NSString *exe_dir = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    g_app_path = [exe_dir stringByAppendingPathComponent:@"app.dylib"];

    // mmap memory starts zeroed and is only backed by pages as they are touched.
    g_memory = (Memory){
        .persistent = reserve(PERSISTENT_SIZE),
        .persistent_size = PERSISTENT_SIZE,
        .frame = reserve(FRAME_SIZE),
        .frame_size = FRAME_SIZE,
    };

    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    app.mainMenu = main_menu();
    App_Delegate *delegate = [App_Delegate new];
    app.delegate = delegate;

    // Quit cleanly on SIGTERM, SIGINT (Ctrl-C) and SIGHUP (the terminal
    // closing), so they still run the app's shutdown, which puts back an
    // audio device that bit-perfect output changed.
    static dispatch_source_t quit_signals[3];
    int signals[3] = {SIGTERM, SIGINT, SIGHUP};
    for (int i = 0; i < 3; i++) {
      signal(signals[i], SIG_IGN);
      quit_signals[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signals[i], 0, dispatch_get_main_queue());
      dispatch_source_set_event_handler(quit_signals[i], ^{
        [NSApp terminate:nil];
      });
      dispatch_resume(quit_signals[i]);
    }

    [app run];
  }
  return 0;
}
