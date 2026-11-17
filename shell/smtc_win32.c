// See smtc_win32.h. The controls are WinRT objects, reached from C through
// their ABI: the few interfaces used are declared here with their methods
// in vtable order, the ones not called as plain pointers, from the
// Windows SDK's windows.media.h and windows.storage.streams.h. combase,
// shcore and shlwapi are loaded when the first track plays, so a launch
// doesn't pay for them.
//
// The window's thread joins COM's single-threaded apartment, as a UI thread
// should, when the first track sets the controls up; its message loop
// serves the apartment. The controls call the button handlers on a thread
// of their own,
// so the handlers post the command to the window and the window procedure
// hands it to the app. The cover goes to the controls as a PNG in a memory
// stream. TIDALFAST_NOW_PLAYING_LOG=1 prints what the controls hold after
// each change, read back from them.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define UNICODE
#define _UNICODE
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <objbase.h>

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include "png.h"
#include "smtc_win32.h"

typedef void *Hstring;
typedef struct {
  int64_t duration; // 100 ns
} Time_Span;
typedef struct {
  int64_t value;
} Event_Token;

#define UNKNOWN_METHODS(T)                                                \
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(T *, const GUID *, void **); \
  ULONG(STDMETHODCALLTYPE *AddRef)(T *);                                  \
  ULONG(STDMETHODCALLTYPE *Release)(T *)
#define INSPECTABLE_METHODS(T) \
  UNKNOWN_METHODS(T);          \
  void *GetIids, *GetRuntimeClassName, *GetTrustLevel

typedef struct Unknown Unknown;
typedef struct Handler Handler;
typedef struct Interop Interop;
typedef struct Controls Controls;
typedef struct Controls2 Controls2;
typedef struct Updater Updater;
typedef struct Music Music;
typedef struct Music2 Music2;
typedef struct Button_Args Button_Args;
typedef struct Position_Args Position_Args;
typedef struct Timeline Timeline;
typedef struct Stream_Refs Stream_Refs;

struct Unknown {
  const struct {
    UNKNOWN_METHODS(Unknown);
  } *v;
};

// ISystemMediaTransportControlsInterop
struct Interop {
  const struct {
    INSPECTABLE_METHODS(Interop);
    HRESULT(STDMETHODCALLTYPE *GetForWindow)(Interop *, HWND, const GUID *, void **);
  } *v;
};

// ISystemMediaTransportControls
struct Controls {
  const struct {
    INSPECTABLE_METHODS(Controls);
    HRESULT(STDMETHODCALLTYPE *get_PlaybackStatus)(Controls *, int32_t *);
    HRESULT(STDMETHODCALLTYPE *put_PlaybackStatus)(Controls *, int32_t);
    HRESULT(STDMETHODCALLTYPE *get_DisplayUpdater)(Controls *, Updater **);
    void *get_SoundLevel;
    HRESULT(STDMETHODCALLTYPE *get_IsEnabled)(Controls *, uint8_t *);
    HRESULT(STDMETHODCALLTYPE *put_IsEnabled)(Controls *, uint8_t);
    void *get_IsPlayEnabled;
    HRESULT(STDMETHODCALLTYPE *put_IsPlayEnabled)(Controls *, uint8_t);
    void *get_IsStopEnabled;
    HRESULT(STDMETHODCALLTYPE *put_IsStopEnabled)(Controls *, uint8_t);
    void *get_IsPauseEnabled;
    HRESULT(STDMETHODCALLTYPE *put_IsPauseEnabled)(Controls *, uint8_t);
    void *get_IsRecordEnabled, *put_IsRecordEnabled;
    void *get_IsFastForwardEnabled, *put_IsFastForwardEnabled;
    void *get_IsRewindEnabled, *put_IsRewindEnabled;
    void *get_IsPreviousEnabled;
    HRESULT(STDMETHODCALLTYPE *put_IsPreviousEnabled)(Controls *, uint8_t);
    void *get_IsNextEnabled;
    HRESULT(STDMETHODCALLTYPE *put_IsNextEnabled)(Controls *, uint8_t);
    void *get_IsChannelUpEnabled, *put_IsChannelUpEnabled;
    void *get_IsChannelDownEnabled, *put_IsChannelDownEnabled;
    HRESULT(STDMETHODCALLTYPE *add_ButtonPressed)(Controls *, Handler *, Event_Token *);
    HRESULT(STDMETHODCALLTYPE *remove_ButtonPressed)(Controls *, Event_Token);
    void *add_PropertyChanged, *remove_PropertyChanged;
  } *v;
};

// ISystemMediaTransportControls2
struct Controls2 {
  const struct {
    INSPECTABLE_METHODS(Controls2);
    void *get_AutoRepeatMode, *put_AutoRepeatMode;
    void *get_ShuffleEnabled, *put_ShuffleEnabled;
    void *get_PlaybackRate, *put_PlaybackRate;
    HRESULT(STDMETHODCALLTYPE *UpdateTimelineProperties)(Controls2 *, Timeline *);
    HRESULT(STDMETHODCALLTYPE *add_PlaybackPositionChangeRequested)(Controls2 *, Handler *, Event_Token *);
    HRESULT(STDMETHODCALLTYPE *remove_PlaybackPositionChangeRequested)(Controls2 *, Event_Token);
    void *add_PlaybackRateChangeRequested, *remove_PlaybackRateChangeRequested;
    void *add_ShuffleEnabledChangeRequested, *remove_ShuffleEnabledChangeRequested;
    void *add_AutoRepeatModeChangeRequested, *remove_AutoRepeatModeChangeRequested;
  } *v;
};

// ISystemMediaTransportControlsDisplayUpdater
struct Updater {
  const struct {
    INSPECTABLE_METHODS(Updater);
    void *get_Type;
    HRESULT(STDMETHODCALLTYPE *put_Type)(Updater *, int32_t);
    void *get_AppMediaId, *put_AppMediaId;
    HRESULT(STDMETHODCALLTYPE *get_Thumbnail)(Updater *, Unknown **);
    HRESULT(STDMETHODCALLTYPE *put_Thumbnail)(Updater *, Unknown *);
    HRESULT(STDMETHODCALLTYPE *get_MusicProperties)(Updater *, Music **);
    void *get_VideoProperties, *get_ImageProperties, *CopyFromFileAsync;
    HRESULT(STDMETHODCALLTYPE *ClearAll)(Updater *);
    HRESULT(STDMETHODCALLTYPE *Update)(Updater *);
  } *v;
};

// IMusicDisplayProperties
struct Music {
  const struct {
    INSPECTABLE_METHODS(Music);
    HRESULT(STDMETHODCALLTYPE *get_Title)(Music *, Hstring *);
    HRESULT(STDMETHODCALLTYPE *put_Title)(Music *, Hstring);
    void *get_AlbumArtist, *put_AlbumArtist;
    void *get_Artist;
    HRESULT(STDMETHODCALLTYPE *put_Artist)(Music *, Hstring);
  } *v;
};

// IMusicDisplayProperties2
struct Music2 {
  const struct {
    INSPECTABLE_METHODS(Music2);
    void *get_AlbumTitle;
    HRESULT(STDMETHODCALLTYPE *put_AlbumTitle)(Music2 *, Hstring);
  } *v;
};

// ISystemMediaTransportControlsButtonPressedEventArgs
struct Button_Args {
  const struct {
    INSPECTABLE_METHODS(Button_Args);
    HRESULT(STDMETHODCALLTYPE *get_Button)(Button_Args *, int32_t *);
  } *v;
};

// IPlaybackPositionChangeRequestedEventArgs
struct Position_Args {
  const struct {
    INSPECTABLE_METHODS(Position_Args);
    HRESULT(STDMETHODCALLTYPE *get_RequestedPlaybackPosition)(Position_Args *, Time_Span *);
  } *v;
};

// ISystemMediaTransportControlsTimelineProperties
struct Timeline {
  const struct {
    INSPECTABLE_METHODS(Timeline);
    void *get_StartTime;
    HRESULT(STDMETHODCALLTYPE *put_StartTime)(Timeline *, Time_Span);
    void *get_EndTime;
    HRESULT(STDMETHODCALLTYPE *put_EndTime)(Timeline *, Time_Span);
    void *get_MinSeekTime;
    HRESULT(STDMETHODCALLTYPE *put_MinSeekTime)(Timeline *, Time_Span);
    void *get_MaxSeekTime;
    HRESULT(STDMETHODCALLTYPE *put_MaxSeekTime)(Timeline *, Time_Span);
    void *get_Position;
    HRESULT(STDMETHODCALLTYPE *put_Position)(Timeline *, Time_Span);
  } *v;
};

// IRandomAccessStreamReferenceStatics
struct Stream_Refs {
  const struct {
    INSPECTABLE_METHODS(Stream_Refs);
    void *CreateFromFile, *CreateFromUri;
    HRESULT(STDMETHODCALLTYPE *CreateFromStream)(Stream_Refs *, Unknown *, Unknown **);
  } *v;
};

// A TypedEventHandler: a delegate, which is an IUnknown with Invoke.
// Both are static and agile, so the controls may call them from any
// thread.
typedef struct {
  UNKNOWN_METHODS(Handler);
  HRESULT(STDMETHODCALLTYPE *Invoke)(Handler *, void *sender, void *args);
} Handler_Vtbl;

struct Handler {
  const Handler_Vtbl *v;
  const GUID *iid;
};

static const GUID IID_Unknown_ = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID IID_Agile = {0x94ea2b94, 0xe9cc, 0x49e0, {0xc0, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90}};
static const GUID IID_Interop = {0xddb0472d, 0xc911, 0x4a1f, {0x86, 0xd9, 0xdc, 0x3d, 0x71, 0xa9, 0x5f, 0x5a}};
static const GUID IID_Controls = {0x99fa3ff4, 0x1742, 0x42a6, {0x90, 0x2e, 0x08, 0x7d, 0x41, 0xf9, 0x65, 0xec}};
static const GUID IID_Controls2 = {0xea98d2f6, 0x7f3c, 0x4af2, {0xa5, 0x86, 0x72, 0x88, 0x98, 0x08, 0xef, 0xb1}};
static const GUID IID_Music2 = {0x00368462, 0x97d3, 0x44b9, {0xb0, 0x0f, 0x00, 0x8a, 0xfc, 0xef, 0xaf, 0x18}};
static const GUID IID_Timeline = {0x5125316a, 0xc3a2, 0x475b, {0x85, 0x07, 0x93, 0x53, 0x4d, 0xc8, 0x8f, 0x15}};
static const GUID IID_Stream_Refs = {0x857309dc, 0x3fbf, 0x4e7d, {0x98, 0x6f, 0xef, 0x3b, 0x1a, 0x07, 0xa9, 0x64}};
static const GUID IID_Random_Access_Stream = {0x905a0fe1, 0xbc53, 0x11df, {0x8c, 0x49, 0x00, 0x1e, 0x4f, 0xc6, 0x86, 0xda}};
// TypedEventHandler<SystemMediaTransportControls, SystemMediaTransportControlsButtonPressedEventArgs>
static const GUID IID_Button_Handler = {0x0557e996, 0x7b23, 0x5bae, {0xaa, 0x81, 0xea, 0x0d, 0x67, 0x11, 0x43, 0xa4}};
// TypedEventHandler<SystemMediaTransportControls, PlaybackPositionChangeRequestedEventArgs>
static const GUID IID_Position_Handler = {0x44e34f15, 0xbdc0, 0x50a7, {0xac, 0xe4, 0x39, 0xe9, 0x1f, 0xb7, 0x53, 0xf1}};

enum { STATUS_CLOSED = 0, STATUS_STOPPED = 2, STATUS_PLAYING = 3, STATUS_PAUSED = 4 };
enum { TYPE_MUSIC = 1 };
enum { BUTTON_PLAY = 0, BUTTON_PAUSE = 1, BUTTON_STOP = 2, BUTTON_NEXT = 6, BUTTON_PREVIOUS = 7 };

static struct {
  HRESULT(WINAPI *RoGetActivationFactory)(Hstring, const GUID *, void **);
  HRESULT(WINAPI *RoActivateInstance)(Hstring, Unknown **);
  HRESULT(WINAPI *WindowsCreateString)(const WCHAR *, UINT32, Hstring *);
  HRESULT(WINAPI *WindowsDeleteString)(Hstring);
  const WCHAR *(WINAPI *WindowsGetStringRawBuffer)(Hstring, UINT32 *);
  HRESULT(WINAPI *CreateRandomAccessStreamOverStream)(Unknown *, int, const GUID *, void **);
  Unknown *(WINAPI *SHCreateMemStream)(const BYTE *, UINT);
} g_api;

static bool g_tried; // set up once, whether it worked or not
static HWND g_window;
static Controls *g_controls;
static Controls2 *g_controls2;
static Updater *g_updater;
static Timeline *g_timeline;
static Stream_Refs *g_stream_refs;
static Event_Token g_button_token, g_position_token;
static char *g_title, *g_artist, *g_album; // what the controls show
static uint64_t g_art_key;

// Handlers

static HRESULT STDMETHODCALLTYPE handler_query(Handler *self, const GUID *iid, void **out) {
  if (!memcmp(iid, &IID_Unknown_, sizeof(GUID)) || !memcmp(iid, &IID_Agile, sizeof(GUID)) || !memcmp(iid, self->iid, sizeof(GUID))) {
    *out = self;
    return S_OK;
  }
  *out = NULL;
  return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE handler_add_ref(Handler *self) { return 2; }
static ULONG STDMETHODCALLTYPE handler_release(Handler *self) { return 1; }

static HRESULT STDMETHODCALLTYPE button_pressed(Handler *self, void *sender, void *args) {
  int32_t button = -1;
  Button_Args *a = args;
  if (FAILED(a->v->get_Button(a, &button))) return S_OK;
  uint32_t command = button == BUTTON_PLAY       ? MEDIA_PLAY
                     : button == BUTTON_PAUSE    ? MEDIA_PAUSE
                     : button == BUTTON_STOP     ? MEDIA_PAUSE
                     : button == BUTTON_NEXT     ? MEDIA_NEXT
                     : button == BUTTON_PREVIOUS ? MEDIA_PREVIOUS
                                                 : MEDIA_NONE;
  if (command != MEDIA_NONE) PostMessageW(g_window, WM_SMTC, command, 0);
  return S_OK;
}

static HRESULT STDMETHODCALLTYPE position_requested(Handler *self, void *sender, void *args) {
  Time_Span at = {0};
  Position_Args *a = args;
  if (SUCCEEDED(a->v->get_RequestedPlaybackPosition(a, &at))) PostMessageW(g_window, WM_SMTC, MEDIA_SEEK, (LPARAM)(at.duration / 10000));
  return S_OK;
}

static const Handler_Vtbl g_button_vtbl = {handler_query, handler_add_ref, handler_release, button_pressed};
static const Handler_Vtbl g_position_vtbl = {handler_query, handler_add_ref, handler_release, position_requested};
static Handler g_button_handler = {&g_button_vtbl, &IID_Button_Handler};
static Handler g_position_handler = {&g_position_vtbl, &IID_Position_Handler};

// Strings

static Hstring hstring_wide(const WCHAR *s) {
  Hstring h = NULL;
  if (FAILED(g_api.WindowsCreateString(s, (UINT32)wcslen(s), &h))) return NULL;
  return h;
}

static Hstring hstring(const char *utf8) {
  WCHAR stack[256];
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  if (n <= 0) return NULL;
  WCHAR *w = n <= 256 ? stack : malloc((size_t)n * sizeof(WCHAR));
  if (!w) return NULL;
  MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n);
  Hstring h = NULL;
  if (FAILED(g_api.WindowsCreateString(w, (UINT32)(n - 1), &h))) h = NULL;
  if (w != stack) free(w);
  return h;
}

static void *activation_factory(const WCHAR *class_name, const GUID *iid) {
  Hstring name = hstring_wide(class_name);
  void *factory = NULL;
  if (!name || FAILED(g_api.RoGetActivationFactory(name, iid, &factory))) factory = NULL;
  if (name) g_api.WindowsDeleteString(name);
  return factory;
}

static void release(void *object) {
  if (object) ((Unknown *)object)->v->Release(object);
}

// Setting up

static bool load_api(void) {
  HMODULE combase = LoadLibraryW(L"combase.dll");
  HMODULE shcore = LoadLibraryW(L"shcore.dll");
  HMODULE shlwapi = LoadLibraryW(L"shlwapi.dll");
  if (!combase || !shcore || !shlwapi) return false;
  // Through void *: the pointers have the types above, which GetProcAddress doesn't know.
  *(void **)&g_api.RoGetActivationFactory = (void *)GetProcAddress(combase, "RoGetActivationFactory");
  *(void **)&g_api.RoActivateInstance = (void *)GetProcAddress(combase, "RoActivateInstance");
  *(void **)&g_api.WindowsCreateString = (void *)GetProcAddress(combase, "WindowsCreateString");
  *(void **)&g_api.WindowsDeleteString = (void *)GetProcAddress(combase, "WindowsDeleteString");
  *(void **)&g_api.WindowsGetStringRawBuffer = (void *)GetProcAddress(combase, "WindowsGetStringRawBuffer");
  *(void **)&g_api.CreateRandomAccessStreamOverStream = (void *)GetProcAddress(shcore, "CreateRandomAccessStreamOverStream");
  *(void **)&g_api.SHCreateMemStream = (void *)GetProcAddress(shlwapi, "SHCreateMemStream");
  return g_api.RoGetActivationFactory && g_api.RoActivateInstance && g_api.WindowsCreateString && g_api.WindowsDeleteString &&
         g_api.WindowsGetStringRawBuffer && g_api.CreateRandomAccessStreamOverStream && g_api.SHCreateMemStream;
}

static void setup(HWND window) {
  g_tried = true;
  g_window = window;
  if (!load_api()) {
    fprintf(stderr, "shell: smtc: Windows has no WinRT, so there are no media controls\n");
    return;
  }
  // S_FALSE when something on this thread got there first, and
  // RPC_E_CHANGED_MODE when that was the multithreaded apartment, in which
  // the controls work too.
  HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
    fprintf(stderr, "shell: smtc: COM failed (0x%08lx)\n", (unsigned long)hr);
    return;
  }
  Interop *interop = activation_factory(L"Windows.Media.SystemMediaTransportControls", &IID_Interop);
  if (!interop) {
    fprintf(stderr, "shell: smtc: no media controls on this system\n");
    return;
  }
  hr = interop->v->GetForWindow(interop, window, &IID_Controls, (void **)&g_controls);
  release(interop);
  if (FAILED(hr) || !g_controls) {
    fprintf(stderr, "shell: smtc: no media controls for the window (0x%08lx)\n", (unsigned long)hr);
    g_controls = NULL;
    return;
  }
  Controls *c = g_controls;
  if (FAILED(c->v->get_DisplayUpdater(c, &g_updater))) g_updater = NULL;
  c->v->put_IsPlayEnabled(c, 1);
  c->v->put_IsPauseEnabled(c, 1);
  c->v->put_IsStopEnabled(c, 1);
  c->v->put_IsNextEnabled(c, 1);
  c->v->put_IsPreviousEnabled(c, 1);
  c->v->add_ButtonPressed(c, &g_button_handler, &g_button_token);
  if (SUCCEEDED(c->v->QueryInterface(c, &IID_Controls2, (void **)&g_controls2))) {
    Hstring name = hstring_wide(L"Windows.Media.SystemMediaTransportControlsTimelineProperties");
    Unknown *timeline = NULL;
    if (name && SUCCEEDED(g_api.RoActivateInstance(name, &timeline))) {
      if (FAILED(timeline->v->QueryInterface(timeline, &IID_Timeline, (void **)&g_timeline))) g_timeline = NULL;
      release(timeline);
    }
    if (name) g_api.WindowsDeleteString(name);
    g_controls2->v->add_PlaybackPositionChangeRequested(g_controls2, &g_position_handler, &g_position_token);
  } else {
    g_controls2 = NULL;
  }
  g_stream_refs = activation_factory(L"Windows.Storage.Streams.RandomAccessStreamReference", &IID_Stream_Refs);
}

// Now Playing

static bool same(const char *a, const char *b) { return a && b && !strcmp(a, b); }

static void keep(char **slot, const char *s) {
  free(*slot);
  *slot = _strdup(s ? s : "");
}

// thumbnail is a stream reference to the cover as a PNG, or NULL.
static Unknown *thumbnail(const Now_Playing *np) {
  if (!np->artwork || !g_stream_refs) return NULL;
  size_t size;
  uint8_t *png = png_encode(np->artwork, np->artwork_width, np->artwork_height, &size);
  if (!png) return NULL;
  Unknown *memory = size <= UINT_MAX ? g_api.SHCreateMemStream(png, (UINT)size) : NULL; // a copy
  free(png);
  if (!memory) return NULL;
  Unknown *stream = NULL, *ref = NULL;
  if (FAILED(g_api.CreateRandomAccessStreamOverStream(memory, 0, &IID_Random_Access_Stream, (void **)&stream))) stream = NULL;
  release(memory);
  if (stream && FAILED(g_stream_refs->v->CreateFromStream(g_stream_refs, stream, &ref))) ref = NULL;
  release(stream);
  return ref;
}

static void set_string(Music *music, HRESULT(STDMETHODCALLTYPE *put)(Music *, Hstring), const char *s) {
  Hstring h = hstring(s ? s : "");
  put(music, h);
  if (h) g_api.WindowsDeleteString(h);
}

static void show_track(const Now_Playing *np) {
  Updater *u = g_updater;
  u->v->ClearAll(u);
  u->v->put_Type(u, TYPE_MUSIC);
  Music *music = NULL;
  if (SUCCEEDED(u->v->get_MusicProperties(u, &music)) && music) {
    set_string(music, music->v->put_Title, np->title);
    set_string(music, music->v->put_Artist, np->artist);
    Music2 *music2 = NULL;
    if (SUCCEEDED(music->v->QueryInterface(music, &IID_Music2, (void **)&music2)) && music2) {
      Hstring album = hstring(np->album ? np->album : "");
      music2->v->put_AlbumTitle(music2, album);
      if (album) g_api.WindowsDeleteString(album);
      release(music2);
    }
    release(music);
  }
}

static void set_timeline(const Now_Playing *np) {
  if (!g_controls2 || !g_timeline) return;
  Timeline *t = g_timeline;
  Time_Span zero = {0}, end = {(int64_t)(np->duration * 1e7)}, at = {(int64_t)(np->elapsed * 1e7)};
  t->v->put_StartTime(t, zero);
  t->v->put_EndTime(t, end);
  t->v->put_MinSeekTime(t, zero);
  t->v->put_MaxSeekTime(t, end);
  t->v->put_Position(t, at);
  g_controls2->v->UpdateTimelineProperties(g_controls2, t);
}

static void log_controls(void) {
  int32_t status = -1;
  uint8_t enabled = 0;
  g_controls->v->get_PlaybackStatus(g_controls, &status);
  g_controls->v->get_IsEnabled(g_controls, &enabled);
  char title[256] = "";
  Music *music = NULL;
  Hstring h = NULL;
  if (g_updater && SUCCEEDED(g_updater->v->get_MusicProperties(g_updater, &music)) && music) {
    if (SUCCEEDED(music->v->get_Title(music, &h)) && h) {
      UINT32 n = 0;
      const WCHAR *w = g_api.WindowsGetStringRawBuffer(h, &n);
      int m = WideCharToMultiByte(CP_UTF8, 0, w, (int)n, title, (int)sizeof title - 1, NULL, NULL);
      title[m > 0 ? m : 0] = 0;
      g_api.WindowsDeleteString(h);
    }
    release(music);
  }
  Unknown *thumb = NULL;
  if (g_updater && FAILED(g_updater->v->get_Thumbnail(g_updater, &thumb))) thumb = NULL;
  fprintf(stderr, "shell: smtc: status %d, enabled %d, title \"%s\", thumbnail %s\n", (int)status, enabled, title, thumb ? "yes" : "no");
  release(thumb);
}

void smtc_set(HWND window, const Now_Playing *np) {
  bool has = np && np->title;
  if (!has) {
    if (!g_controls) return;
    g_controls->v->put_PlaybackStatus(g_controls, STATUS_CLOSED);
    if (g_updater) {
      g_updater->v->ClearAll(g_updater);
      g_updater->v->Update(g_updater);
    }
    g_controls->v->put_IsEnabled(g_controls, 0);
    free(g_title), free(g_artist), free(g_album);
    g_title = g_artist = g_album = NULL;
    g_art_key = 0;
    if (g_now_playing_log) log_controls();
    return;
  }
  if (!g_tried) setup(window);
  if (!g_controls) return;
  Controls *c = g_controls;
  c->v->put_IsEnabled(c, 1);
  int32_t status = np->state == NOW_PLAYING_PLAYING ? STATUS_PLAYING : np->state == NOW_PLAYING_PAUSED ? STATUS_PAUSED : STATUS_STOPPED;
  c->v->put_PlaybackStatus(c, status);
  if (g_updater) {
    bool new_track = !same(g_title, np->title) || !same(g_artist, np->artist) || !same(g_album, np->album);
    uint64_t art_key = np->artwork ? np->artwork_key : 0;
    if (new_track) {
      show_track(np);
      keep(&g_title, np->title);
      keep(&g_artist, np->artist);
      keep(&g_album, np->album);
      g_art_key = 0;
    }
    if (new_track || art_key != g_art_key) {
      Unknown *ref = thumbnail(np);
      g_updater->v->put_Thumbnail(g_updater, ref);
      release(ref);
      g_art_key = art_key;
      g_updater->v->Update(g_updater);
    }
  }
  set_timeline(np);
  if (g_now_playing_log) log_controls();
}

void smtc_close(void) {
  if (!g_controls) return;
  g_controls->v->remove_ButtonPressed(g_controls, g_button_token);
  if (g_controls2) g_controls2->v->remove_PlaybackPositionChangeRequested(g_controls2, g_position_token);
  g_controls->v->put_IsEnabled(g_controls, 0);
  release(g_timeline);
  release(g_stream_refs);
  release(g_updater);
  release(g_controls2);
  release(g_controls);
  g_timeline = NULL, g_stream_refs = NULL, g_updater = NULL, g_controls2 = NULL, g_controls = NULL;
}
