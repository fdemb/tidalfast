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
static int g_reload_count;

static Memory g_memory;
static Shell g_shell;
static Event *g_events;
static uint32_t g_event_count;
static uint32_t g_event_capacity;
static atomic_bool g_needs_redraw;
static bool g_animating;
static double g_last_tick; // CACurrentMediaTime of the last display link frame
static double g_tick_interval = 1.0 / 60;
static CFRunLoopTimerRef g_tick_fallback;
static CFRunLoopTimerRef g_wake_timer; // fires when a frame asked for wake_after
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

static void request_redraw(void) {
  atomic_store(&g_needs_redraw, true);
  CFRunLoopWakeUp(g_main_run_loop);
}

static void draw_frame(void) {
  if (!g_app.api.frame) return;
  atomic_store(&g_needs_redraw, false);

  NSSize size = g_view.bounds.size;
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
  if (g_wake_timer) {
    double after = result.wake_after > 0 ? result.wake_after : 1e9;
    CFRunLoopTimerSetNextFireDate(g_wake_timer, CFAbsoluteTimeGetCurrent() + after);
  }
}

static void wake_timer_fired(CFRunLoopTimerRef timer, void *info) { request_redraw(); }

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

// Copies the dylib to a unique temp path and opens the copy, so the linker
// can replace the original while this copy is loaded. dlopen runs the Odin
// runtime's startup in the new image.
static bool open_app(Loaded_App *out) {
  if (!file_identity(g_app_path, &out->inode, &out->mtime)) {
    fprintf(stderr, "shell: no app dylib at %s\n", g_app_path.UTF8String);
    return false;
  }
  NSString *name = [NSString stringWithFormat:@"tidalfast-app-%d-%d.dylib", getpid(), g_reload_count++];
  NSString *copy = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  if (copyfile(g_app_path.fileSystemRepresentation, copy.fileSystemRepresentation, NULL, COPYFILE_ALL) != 0) {
    fprintf(stderr, "shell: copy to %s failed\n", copy.UTF8String);
    return false;
  }
  void *handle = dlopen(copy.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  unlink(copy.fileSystemRepresentation);
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
  push_event((Event){.kind = EVENT_MEDIA, .key_code = command, .dx = (float)position, .time = CACurrentMediaTime()});
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
// converts, rounding down to a whole codepoint.

static struct {
  bool active;
  uint8_t *bytes;
  uint32_t length, capacity;
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

static void text_insert(id string, NSRange replacement) {
  const char *utf8 = plain_string(string).UTF8String ?: "";
  uint32_t n = (uint32_t)strlen(utf8);
  Event e = {.kind = EVENT_TEXT, .time = CACurrentMediaTime()};
  push_text(&e, utf8, n);
  uint32_t lo, hi;
  edit_range(replacement, &e, &lo, &hi);
  mirror_replace(lo, hi, utf8, n);
  g_ti.sel_start = g_ti.sel_end = lo + n;
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
  mirror_replace(lo, hi, utf8, n);
  if (n > 0) {
    g_ti.marked_start = (int32_t)lo;
    g_ti.marked_end = (int32_t)(lo + n);
    g_ti.sel_start = lo + sel_lo;
    g_ti.sel_end = lo + (uint32_t)e.select_end;
  } else {
    g_ti.marked_start = g_ti.marked_end = -1;
    g_ti.sel_start = g_ti.sel_end = lo;
  }
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
  NSRect caret = NSMakeRect(ti->caret[0], ti->caret[1], ti->caret[2], ti->caret[3]);
  bool moved = !NSEqualRects(caret, g_ti.caret);
  g_ti.caret = caret;
  g_ti.active = true;
  if (discard) [g_view.inputContext discardMarkedText];
  if (moved) [g_view.inputContext invalidateCharacterCoordinates];
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
  if (flags & NSEventModifierFlagOption) m |= MODIFIER_OPTION;
  if (flags & NSEventModifierFlagCommand) m |= MODIFIER_COMMAND;
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
  return g_layer;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)update_drawable_size {
  CGFloat scale = self.window ? self.window.backingScaleFactor : 1;
  g_layer.contentsScale = scale;
  g_layer.drawableSize = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
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

- (void)mouseDown:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_DOWN, MOUSE_BUTTON_LEFT)); }
- (void)mouseUp:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_UP, MOUSE_BUTTON_LEFT)); }
- (void)rightMouseDown:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_DOWN, MOUSE_BUTTON_RIGHT)); }
- (void)rightMouseUp:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_UP, MOUSE_BUTTON_RIGHT)); }
- (void)otherMouseDown:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_DOWN, MOUSE_BUTTON_MIDDLE)); }
- (void)otherMouseUp:(NSEvent *)e { push_event(mouse_event(self, e, EVENT_MOUSE_UP, MOUSE_BUTTON_MIDDLE)); }
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

static Event key_event(NSEvent *e, uint32_t kind) {
  return (Event){
      .kind = kind,
      .modifiers = modifiers(e.modifierFlags),
      .time = e.timestamp,
      .key_code = e.keyCode,
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
}

// TIDALFAST_SHELL_TEST runs steps against the shell's own entry points,
// for checking text input and accessibility without a person at the
// keyboard: "2:key=cmd+f;3:mark=にほんご;4:commit=日本語;6:ax-dump;7:ax-press=Next".
// Steps are seconds after launch and a command, separated by semicolons.
//
//   key=cmd+shift+z     a key down and up, as from the keyboard (letters, escape, return, tab, left...)
//   mark=text           setMarkedText, with the caret at the end of text
//   commit=text         insertText
//   unmark              unmarkText
//   ime                 print what NSTextInputClient answers
//   ax-dump             print the window's accessibility tree, as an assistive app reads it
//   ax-press=label      AXPress on the first element whose label or value starts with label
//   capture=path        copy the last TIDALFAST_CAPTURE frame to path
//   quit

static uint32_t key_code_named(NSString *name) {
  NSDictionary *named = @{
    @"return" : @36, @"tab" : @48, @"space" : @49, @"backspace" : @51, @"escape" : @53, @"delete" : @117,
    @"home" : @115, @"end" : @119, @"left" : @123, @"right" : @124, @"down" : @125, @"up" : @126,
  };
  if (named[name]) return [named[name] unsignedIntValue];
  // kVK_ANSI_A and on, in the order of the US layout's key codes.
  const char *letters = "asdfhgzxcv?bqweryt";
  if (name.length == 1) {
    const char *at = strchr(letters, [name characterAtIndex:0]);
    if (at) return (uint32_t)(at - letters);
    if ([name isEqualToString:@"o"]) return 31;
    if ([name isEqualToString:@"u"]) return 32;
    if ([name isEqualToString:@"i"]) return 34;
    if ([name isEqualToString:@"p"]) return 35;
    if ([name isEqualToString:@"l"]) return 37;
    if ([name isEqualToString:@"j"]) return 38;
    if ([name isEqualToString:@"k"]) return 40;
    if ([name isEqualToString:@"n"]) return 45;
    if ([name isEqualToString:@"m"]) return 46;
  }
  return UINT32_MAX;
}

static void test_key(NSString *spec) {
  uint32_t mods = 0;
  NSArray *parts = [spec componentsSeparatedByString:@"+"];
  for (NSString *p in parts) {
    if ([p isEqualToString:@"cmd"]) mods |= MODIFIER_COMMAND;
    else if ([p isEqualToString:@"shift"]) mods |= MODIFIER_SHIFT;
    else if ([p isEqualToString:@"opt"]) mods |= MODIFIER_OPTION;
    else if ([p isEqualToString:@"ctrl"]) mods |= MODIFIER_CONTROL;
  }
  uint32_t code = key_code_named(parts.lastObject);
  if (code == UINT32_MAX) {
    fprintf(stderr, "shell: test: no key named %s\n", [parts.lastObject UTF8String]);
    return;
  }
  double now = CACurrentMediaTime();
  push_event((Event){.kind = EVENT_KEY_DOWN, .modifiers = mods, .key_code = code, .time = now});
  push_event((Event){.kind = EVENT_KEY_UP, .modifiers = mods, .key_code = code, .time = now});
  request_redraw();
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

static void test_step(NSString *command, NSString *arg) {
  if ([command isEqualToString:@"key"]) {
    test_key(arg);
  } else if ([command isEqualToString:@"mark"]) {
    [(Metal_View *)g_view setMarkedText:arg selectedRange:NSMakeRange(arg.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  } else if ([command isEqualToString:@"commit"]) {
    [(Metal_View *)g_view insertText:arg replacementRange:NSMakeRange(NSNotFound, 0)];
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
    NSString *rest = [step substringFromIndex:colon.location + 1];
    NSRange eq = [rest rangeOfString:@"="];
    NSString *command = eq.location == NSNotFound ? rest : [rest substringToIndex:eq.location];
    NSString *arg = eq.location == NSNotFound ? @"" : [rest substringFromIndex:eq.location + 1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      fprintf(stderr, "shell: test step %s\n", step.UTF8String);
      test_step(command, arg);
    });
  }
}

// App

@interface App_Delegate : NSObject <NSApplicationDelegate>
@end

@implementation App_Delegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  NSRect frame = NSMakeRect(0, 0, 1100, 700);
  g_window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  g_window.title = @"TIDALfast";
  g_window.acceptsMouseMovedEvents = YES;
  g_window.releasedWhenClosed = NO;

  g_view = [[Metal_View alloc] initWithFrame:frame];
  g_window.contentView = g_view;
  [g_window center];

  g_display_link = [g_view displayLinkWithTarget:g_view selector:@selector(display_link_tick:)];
  g_display_link.paused = YES;
  [g_display_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeOcclusionStateNotification
                                                  object:g_window
                                                   queue:nil
                                              usingBlock:^(NSNotification *n) {
                                                update_display_link();
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
      .metal_device = (__bridge void *)g_layer.device,
      .metal_layer = (__bridge void *)g_layer,
      .request_redraw = request_redraw,
      .set_now_playing = set_now_playing,
      .set_text_input = set_text_input,
      .set_clipboard = set_clipboard,
      .get_clipboard = get_clipboard,
      .set_accessibility = set_accessibility,
  };
  setup_remote_commands();

  if (!open_app(&g_app)) {
    [NSApp terminate:nil];
    return;
  }
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
  setup_shell_test();
  request_redraw();
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  if (g_app.api.shutdown) g_app.api.shutdown(&g_memory);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  return YES;
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
  [app_menu addItemWithTitle:@"Quit TIDALfast" action:@selector(terminate:) keyEquivalent:@"q"];
  app_item.submenu = app_menu;
  return bar;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
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

    // Quit cleanly on SIGTERM, so `kill` still runs the app's shutdown.
    signal(SIGTERM, SIG_IGN);
    dispatch_source_t sigterm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigterm, ^{
      [NSApp terminate:nil];
    });
    dispatch_resume(sigterm);

    [app run];
  }
  return 0;
}
