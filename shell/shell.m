// The executable. Owns NSApplication, the window and the CAMetalLayer,
// collects input into an event array, and drives the app dylib through the
// App_API table in platform.h. It redraws only when something asks for it:
// input, resize, a reload or request_redraw from any thread. While the app
// reports it is animating and the window is visible, the display link adds a
// frame every vsync, and other redraws wait for the next tick.

#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
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
static CFRunLoopRef g_main_run_loop;
static double g_start_time;

static NSWindow *g_window;
static NSView *g_view;
static CAMetalLayer *g_layer;
static CADisplayLink *g_display_link;

static void update_display_link(void);

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
  };
  Frame_Result result;
  @autoreleasepool {
    result = g_app.api.frame(&g_memory, &g_shell, &input);
  }
  g_event_count = 0;
  g_animating = result.animating;
  update_display_link();
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

@interface Metal_View : NSView
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

// Not passed to super, so unhandled keys don't beep. Text input and IME come
// with NSTextInputClient in a later phase.
- (void)keyDown:(NSEvent *)e { push_event(key_event(e, EVENT_KEY_DOWN)); }
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

  g_shell = (Shell){
      .metal_device = (__bridge void *)g_layer.device,
      .metal_layer = (__bridge void *)g_layer,
      .request_redraw = request_redraw,
  };

  if (!open_app(&g_app)) {
    [NSApp terminate:nil];
    return;
  }
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
