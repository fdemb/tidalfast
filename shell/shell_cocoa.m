// The platform side of the macOS executable. Owns NSApplication, the window
// and its CAMetalLayer, collects input into the event queue (common.c), and
// drives the app through the entry points in platform.h, as
// shell_wayland.c and shell_win32.c do on Linux and Windows. src/app's main
// calls shell_main. The renderer draws to the CAMetalLayer it gets.
//
// It redraws only when something asks for it: input, a resize or
// request_redraw from any thread. The run loop draws once per pass, just
// before it sleeps, for everything that came. While the app reports it is
// animating and the window is visible, the display link adds a frame every
// vsync, and other redraws wait for the next tick. A frame can also ask to
// be woken after a delay, which a one-shot timer does.
//
// The view is an NSTextInputClient, so input methods work in the app's text
// fields, and it hands assistive apps an accessibility tree the app builds
// from its boxes. MPRemoteCommandCenter brings the media keys and
// MPNowPlayingInfoCenter shows what plays.
//
// The window keeps the system's titlebar buttons, and the view goes up
// under them: the app keeps room for them (Frame_Input.titlebar_height and
// titlebar_inset), and the empty parts of the top move the window
// (set_drag_regions).

#import <Carbon/Carbon.h> // kVK_* only
#import <Cocoa/Cocoa.h>
#import <MediaPlayer/MediaPlayer.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/time.h>

#include "common.h"

#define PERSISTENT_SIZE (256ull << 20)
#define FRAME_SIZE (64ull << 20)
#define DEFAULT_WIDTH 1100
#define DEFAULT_HEIGHT 700
#define MIN_WIDTH 480
#define MIN_HEIGHT 360

static bool g_app_started; // app_init has run, so frames can be drawn
static Memory g_memory;
static Shell g_shell;
static bool g_animating;
static bool g_in_frame; // inside app_frame
static bool g_parked; // the window can't be seen and its drawables are a pixel, see update_parking
static bool g_never_park; // TIDALFAST_CAPTURE is set
static double g_last_tick; // CACurrentMediaTime of the last display link frame
static double g_tick_interval = 1.0 / 60;
static CFRunLoopTimerRef g_tick_fallback;
static CFRunLoopTimerRef g_wake_timer; // fires when a frame asked for wake_after
static bool g_wake_armed; // g_wake_timer is set to fire, see draw_frame
static CFRunLoopTimerRef g_test_timer; // the next test step
static CFRunLoopRef g_main_run_loop;

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

// NSEvent timestamps count from the same start.
double now_seconds(void) { return CACurrentMediaTime(); }

void request_redraw(void) {
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

// A frame that asks for another from inside app_frame, as a resize can,
// gets the next one; the app is never re-entered.
static void draw_frame(void) {
  if (!g_app_started || g_in_frame) return;
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
      .width = size.width,
      .height = size.height,
      .scale = g_window.backingScaleFactor,
      .time = now_seconds() - g_start_time,
      .key_window = g_window.isKeyWindow,
      .mouse_buttons = held_mouse_buttons(),
      .titlebar_height = titlebar > 0 ? titlebar : 0,
      .titlebar_inset = titlebar > 0 && zoom ? NSMaxX(zoom.frame) : 0,
      .frame_interval = g_tick_interval,
  };
  queue_take(&input.events, &input.event_count, &input.text, &input.text_length);
  Frame_Result result;
  g_in_frame = true;
  @autoreleasepool {
    result = app_frame(&g_memory, &g_shell, &input);
  }
  g_in_frame = false;
  access_frame_done();
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

// Now Playing and media keys
//
// MPNowPlayingInfoCenter shows what plays in Control Center and on the lock
// screen. MPRemoteCommandCenter routes the media keys, Control Center's
// buttons and headphone controls to the app that is playing; each command
// becomes an EVENT_MEDIA in the app's next frame.
//
// TIDALFAST_NOW_PLAYING_LOG=1 prints nowPlayingInfo as macOS holds it after
// every update. TIDALFAST_REMOTE_TEST (common.c) sends commands through
// remote_command, as the handlers here do.

static MPMediaItemArtwork *g_artwork;
static uint64_t g_artwork_key;

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
}

// Text input
//
// The app tells the shell about the focused text field after each frame
// (set_text_input), and the shell keeps a mirror of it (Text_Mirror in
// common.h), since input methods ask NSTextInputClient questions
// synchronously, often right after setMarkedText and before the app has had
// a frame. The view's NSTextInputClient methods hand the input method's
// edits to common.c's text_insert, text_set_marked and text_unmark, which
// send them to the app and apply them to the mirror. AppKit counts in
// UTF-16 units and the mirror in UTF-8 bytes; the view converts, rounding
// down to a whole codepoint.

static bool g_ime_handled; // the input method took the key being handled

static NSString *plain_string(id string) {
  return [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : (NSString *)string;
}

static uint32_t utf16_index(NSUInteger i) { return i > UINT32_MAX ? UINT32_MAX : (uint32_t)i; }

// A range of the field's text in UTF-16 units as bytes, -1 for none.
static void byte_range(NSRange r, int64_t *lo, int64_t *hi) {
  if (r.location == NSNotFound) {
    *lo = *hi = -1;
    return;
  }
  *lo = byte_of_utf16(g_ti.bytes, g_ti.length, utf16_index(r.location));
  *hi = byte_of_utf16(g_ti.bytes, g_ti.length, utf16_index(r.location + r.length));
}

static void set_text_input(const Text_Input *ti) {
  // The app ended a composition itself, as when the field lost the focus:
  // the input method has to forget it too.
  bool was_marked = g_ti.active && g_ti.marked_start >= 0;
  float caret[4];
  memcpy(caret, g_ti.caret, sizeof caret);
  mirror_set(ti);
  if (was_marked && g_ti.marked_start < 0) [g_view.inputContext discardMarkedText];
  if (g_ti.active && memcmp(caret, g_ti.caret, sizeof caret) != 0) [g_view.inputContext invalidateCharacterCoordinates];
}

// Window dragging

// The view draws under the titlebar, so the app says which parts of it are
// empty and move the window, as the titlebar itself would.
#define MAX_DRAG_REGIONS 64
static float g_drag_regions[MAX_DRAG_REGIONS][4];
static uint32_t g_drag_region_count;

static void set_drag_regions(const float (*rects)[4], uint32_t count) {
  if (count > MAX_DRAG_REGIONS) count = MAX_DRAG_REGIONS;
  memcpy(g_drag_regions, rects, count * sizeof rects[0]);
  g_drag_region_count = count;
}

static bool in_drag_region(NSPoint p) {
  for (uint32_t i = 0; i < g_drag_region_count; i++) {
    const float *r = g_drag_regions[i];
    if (p.x >= r[0] && p.x < r[0] + r[2] && p.y >= r[1] && p.y < r[1] + r[3]) return true;
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
// The shell keeps a copy (access_store) and makes NSAccessibilityElements from it only
// once an assistive app has asked the view for its children, and from then
// on after every change. Elements are kept by node id, so VoiceOver's
// cursor stays on an element while it moves or changes. Frames are kept in
// view points and turned into screen coordinates when asked for.

static bool g_access_dirty; // the nodes changed since the elements were made
static bool g_access_seen; // an assistive app asked for the tree
static bool g_access_changed; // set_accessibility ran this frame
static NSMutableDictionary<NSNumber *, NSAccessibilityElement *> *g_elements;
static NSArray *g_access_top; // the view's children
static NSArray *g_access_all; // every element in node order
static uint64_t g_access_focus;

static void access_event(uint32_t kind, uint64_t id) {
  push_event((Event){.kind = kind, .target = id, .time = now_seconds()});
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

static NSString *node_string(const char *s) { return s ? [NSString stringWithUTF8String:s] : nil; }

static void set_accessibility(const Access_Node *nodes, uint32_t count) {
  access_store(nodes, count);
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
    el.view_frame = NSMakeRect(n->frame[0], n->frame[1], n->frame[2], n->frame[3]);
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
  measure_mark("metal_device");
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

- (void)insertText:(id)string replacementRange:(NSRange)range {
  int64_t lo, hi;
  byte_range(range, &lo, &hi);
  text_insert(plain_string(string).UTF8String ?: "", lo, hi);
  g_ime_handled = true;
}

// The selection is in UTF-16 units of the marked text.
- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)range {
  const char *utf8 = plain_string(string).UTF8String ?: "";
  uint32_t n = (uint32_t)strlen(utf8);
  uint32_t sel_lo = byte_of_utf16((const uint8_t *)utf8, n, utf16_index(selected.location));
  uint32_t sel_hi = byte_of_utf16((const uint8_t *)utf8, n, utf16_index(selected.location + selected.length));
  int64_t lo, hi;
  byte_range(range, &lo, &hi);
  text_set_marked(utf8, sel_lo, sel_hi, lo, hi);
  g_ime_handled = true;
}

- (void)unmarkText {
  text_unmark();
  g_ime_handled = true;
}

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
  NSRect r = NSMakeRect(g_ti.caret[0], g_ti.caret[1], g_ti.caret[2], g_ti.caret[3]);
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

// The test steps of this shell, on top of common.c's. The input method's
// and accessibility's shared steps go through AppKit here, as an input
// method's and an assistive app's calls do, in place of common.c's:
//
//   mark=text           setMarkedText, with the caret at the end of text
//   commit=text         insertText
//   mark-range=l,n,text setMarkedText replacing UTF-16 units [l, l+n)
//   commit-range=l,n,text insertText replacing UTF-16 units [l, l+n)
//   commit-marked=text  insertText replacing what markedRange says, as an input method does
//   unmark              unmarkText
//   ime                 print what NSTextInputClient answers
//   ax-dump             print the window's accessibility tree, as an assistive app reads it
//   ax-press=label      AXPress on the first element whose label or value starts with label
//   quit                quit through NSApplication, as Cmd-Q does
//
// And its own:
//
//   size=w,h            make the window's content w by h points
//   menu=title          the menu bar's item with that title, as clicking it does
//   hide, unhide        hide the app and show it again, as Cmd-H and clicking its Dock icon do

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

bool os_test_step(const char *command_utf8, char *arg_utf8) {
  NSString *command = @(command_utf8), *arg = @(arg_utf8) ?: @"";
  Metal_View *view = (Metal_View *)g_view;
  NSString *text;
  if ([command isEqualToString:@"mark"]) {
    [view setMarkedText:arg selectedRange:NSMakeRange(arg.length, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  } else if ([command isEqualToString:@"commit"]) {
    [view insertText:arg replacementRange:NSMakeRange(NSNotFound, 0)];
  } else if ([command isEqualToString:@"mark-range"]) {
    NSRange r = test_range(arg, &text);
    [view setMarkedText:text selectedRange:NSMakeRange(text.length, 0) replacementRange:r];
  } else if ([command isEqualToString:@"commit-range"]) {
    NSRange r = test_range(arg, &text);
    [view insertText:text replacementRange:r];
  } else if ([command isEqualToString:@"commit-marked"]) {
    [view insertText:arg replacementRange:view.markedRange];
  } else if ([command isEqualToString:@"unmark"]) {
    [view unmarkText];
  } else if ([command isEqualToString:@"ime"]) {
    test_ime_state();
  } else if ([command isEqualToString:@"ax-dump"] || [command isEqualToString:@"ax-press"]) {
    bool press = [command isEqualToString:@"ax-press"], pressed = false;
    ax_walk(g_window, 0, press ? arg : nil, &pressed);
    if (press && !pressed) fprintf(stderr, "shell: ax: nothing to press called %s\n", arg.UTF8String);
  } else if ([command isEqualToString:@"quit"]) {
    [NSApp terminate:nil];
  } else if ([command isEqualToString:@"size"]) {
    NSArray *wh = [arg componentsSeparatedByString:@","];
    double w = [wh.firstObject doubleValue], h = wh.count > 1 ? [wh[1] doubleValue] : 0;
    if (w < 1 || h < 1) {
      fprintf(stderr, "shell: test: size wants w,h\n");
      return true;
    }
    [g_window setContentSize:NSMakeSize(w, h)];
  } else if ([command isEqualToString:@"menu"]) {
    test_menu(arg);
  } else if ([command isEqualToString:@"hide"]) {
    [NSApp hide:nil];
  } else if ([command isEqualToString:@"unhide"]) {
    [NSApp unhide:nil];
    [NSApp activateIgnoringOtherApps:YES];
  } else {
    return false;
  }
  return true;
}

// The timer repeats 1e9 s later, so it only fires when armed.
static void test_timer_fired(CFRunLoopTimerRef timer, void *info) { run_due_steps(); }

void os_arm_test_timer(double after) { CFRunLoopTimerSetNextFireDate(g_test_timer, CFAbsoluteTimeGetCurrent() + after); }

// App
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
  NSRect frame = NSMakeRect(0, 0, DEFAULT_WIDTH, DEFAULT_HEIGHT);
  g_window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  measure_mark("ns_window");
  g_window.title = @"TIDALfast";
  g_window.contentMinSize = NSMakeSize(MIN_WIDTH, MIN_HEIGHT);
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

  g_wake_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, wake_timer_fired, NULL);
  CFRunLoopAddTimer(g_main_run_loop, g_wake_timer, kCFRunLoopCommonModes);
  g_test_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, test_timer_fired, NULL);
  CFRunLoopAddTimer(g_main_run_loop, g_test_timer, kCFRunLoopCommonModes);
  [(Metal_View *)g_view update_drawable_size];
  measure_mark("app_start");
  @autoreleasepool {
    app_init(&g_memory, &g_shell);
  }
  g_app_started = true;

  CFRunLoopObserverRef observer =
      CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting, true, 0, before_waiting, NULL);
  CFRunLoopAddObserver(g_main_run_loop, observer, kCFRunLoopCommonModes);
  // Repeating with a huge interval so it stays valid after it fires and can
  // be rearmed with CFRunLoopTimerSetNextFireDate.
  g_tick_fallback = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0, tick_fallback_fired, NULL);
  CFRunLoopAddTimer(g_main_run_loop, g_tick_fallback, kCFRunLoopCommonModes);

  [g_window makeKeyAndOrderFront:nil];
  [g_window makeFirstResponder:g_view];
  [NSApp activateIgnoringOtherApps:YES];
  measure_mark("window");
  setup_shell_test();
  request_redraw();
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  if (g_app_started) app_shutdown(&g_memory);
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

int shell_main(int argc, char **argv) {
  // SIGUSR1 asks the app for a memory snapshot (src/app/snapshot.odin),
  // and the app sets its handler once it's loaded. Until then it's
  // ignored, so the menu item can't quit the app.
  signal(SIGUSR1, SIG_IGN);
  @autoreleasepool {
    common_init();
    measure_init();
    measure_mark("main");
    g_main_run_loop = CFRunLoopGetMain();

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
