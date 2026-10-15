// Mirror of src/platform/platform.odin. Change both together and bump
// PLATFORM_ABI_VERSION.
#pragma once

#include <stdint.h>
#include <stddef.h>

#define PLATFORM_ABI_VERSION 3

typedef enum {
  EVENT_NONE,
  EVENT_MOUSE_DOWN,
  EVENT_MOUSE_UP,
  EVENT_MOUSE_MOVE,
  EVENT_MOUSE_LEAVE,
  EVENT_SCROLL,
  EVENT_KEY_DOWN,
  EVENT_KEY_UP,
  EVENT_MODIFIERS_CHANGED,
  EVENT_RESIZE,
  EVENT_MEDIA, // key_code is a Media_Command, dx the position for MEDIA_SEEK
  EVENT_TEXT, // text for the focused text field; see platform.odin
  EVENT_MARKED_TEXT, // the input method's composition
  EVENT_UNMARK_TEXT,
  EVENT_ACCESS_PRESS, // target is the node's id
  EVENT_ACCESS_FOCUS,
} Event_Kind;

// Media keys, Control Center and headphones, from MPRemoteCommandCenter.
typedef enum {
  MEDIA_NONE,
  MEDIA_PLAY,
  MEDIA_PAUSE,
  MEDIA_TOGGLE,
  MEDIA_NEXT,
  MEDIA_PREVIOUS,
  MEDIA_SEEK,
} Media_Command;

typedef enum {
  MOUSE_BUTTON_LEFT,
  MOUSE_BUTTON_RIGHT,
  MOUSE_BUTTON_MIDDLE,
} Mouse_Button;

typedef enum {
  SCROLL_PHASE_NONE,
  SCROLL_PHASE_MAY_BEGIN,
  SCROLL_PHASE_BEGAN,
  SCROLL_PHASE_CHANGED,
  SCROLL_PHASE_STATIONARY,
  SCROLL_PHASE_ENDED,
  SCROLL_PHASE_CANCELLED,
} Scroll_Phase;

enum {
  MODIFIER_SHIFT = 1 << 0,
  MODIFIER_CONTROL = 1 << 1,
  MODIFIER_OPTION = 1 << 2,
  MODIFIER_COMMAND = 1 << 3,
  MODIFIER_CAPS_LOCK = 1 << 4,
};

typedef struct {
  uint32_t kind;
  uint32_t modifiers;
  double time;
  float x, y;
  float dx, dy;
  uint32_t button;
  uint32_t click_count;
  uint32_t key_code;
  uint32_t phase;
  uint32_t momentum_phase;
  uint8_t precise;
  uint8_t repeat;
  uint8_t replace; // replace_start and replace_end are set
  uint8_t _pad;
  uint32_t text_offset; // EVENT_TEXT, EVENT_MARKED_TEXT: bytes into Frame_Input.text
  uint32_t text_length;
  int32_t replace_start; // bytes of the field's text
  int32_t replace_end;
  int32_t select_start; // EVENT_MARKED_TEXT: the selection inside the marked text, bytes
  int32_t select_end;
  uint64_t target; // EVENT_ACCESS_*: the node's id
} Event;
_Static_assert(sizeof(Event) == 88, "Event size must match platform.odin");

typedef struct {
  uint8_t *persistent;
  size_t persistent_size;
  uint8_t *frame;
  size_t frame_size;
} Memory;

typedef enum {
  NOW_PLAYING_STOPPED,
  NOW_PLAYING_PLAYING,
  NOW_PLAYING_PAUSED,
} Now_Playing_State;

// What macOS shows in Control Center and on the lock screen. The shell
// copies everything before set_now_playing returns.
typedef struct {
  const char *title; // UTF-8; NULL clears Now Playing
  const char *artist;
  const char *album;
  double duration; // seconds
  double elapsed;
  uint32_t state; // Now_Playing_State
  uint32_t artwork_width;
  uint32_t artwork_height;
  uint32_t _pad;
  const uint8_t *artwork; // RGBA8 sRGB, premultiplied, or NULL
  uint64_t artwork_key; // the shell rebuilds the artwork only when this changes
} Now_Playing;
_Static_assert(sizeof(Now_Playing) == 72, "Now_Playing size must match platform.odin");

// The focused text field, for the input method. text is NULL when no text
// field has the focus.
typedef struct {
  const uint8_t *text; // UTF-8
  uint32_t length;
  uint32_t selection_start; // bytes, start <= end
  uint32_t selection_end;
  int32_t marked_start; // bytes; -1 without marked text
  int32_t marked_end;
  uint32_t limit; // most bytes the field takes, 0 for no limit
  float caret[4]; // x, y, w, h in view points: the marked text, or the caret
} Text_Input;
_Static_assert(sizeof(Text_Input) == 48, "Text_Input size must match platform.odin");

typedef enum {
  ACCESS_NONE,
  ACCESS_GROUP,
  ACCESS_BUTTON,
  ACCESS_TEXT_FIELD,
  ACCESS_STATIC_TEXT,
  ACCESS_LIST,
  ACCESS_TABLE,
  ACCESS_ROW,
  ACCESS_MENU,
  ACCESS_MENU_ITEM,
  ACCESS_SLIDER,
} Access_Role;

enum {
  ACCESS_FOCUSED = 1 << 0,
  ACCESS_SELECTED = 1 << 1,
  ACCESS_DISABLED = 1 << 2,
};

// One element of the accessibility tree, parents before children. parent
// is a node index, or -1 for the window's content.
typedef struct {
  uint64_t id; // stable across frames
  int32_t parent;
  uint32_t role; // Access_Role
  uint32_t flags;
  uint32_t _pad;
  float frame[4]; // x, y, w, h in view points
  const char *label; // UTF-8 or NULL
  const char *value;
} Access_Node;
_Static_assert(sizeof(Access_Node) == 56, "Access_Node size must match platform.odin");

typedef struct {
  void *metal_device;
  void *metal_layer;
  void (*request_redraw)(void);
  // The rest are main thread only.
  void (*set_now_playing)(const Now_Playing *info);
  void (*set_text_input)(const Text_Input *input); // copied
  void (*set_clipboard)(const uint8_t *text, size_t length);
  // Copies up to capacity bytes of the clipboard's text, returns its length.
  size_t (*get_clipboard)(uint8_t *buffer, size_t capacity);
  void (*set_accessibility)(const Access_Node *nodes, uint32_t count); // copied
} Shell;
_Static_assert(sizeof(Shell) == 64, "Shell size must match platform.odin");

typedef struct {
  Event *events;
  uint32_t event_count;
  float width, height;
  float scale;
  double time;
  const uint8_t *text; // what EVENT_TEXT and EVENT_MARKED_TEXT point into
  uint32_t text_length;
  uint32_t key_window;
} Frame_Input;
_Static_assert(sizeof(Frame_Input) == 48, "Frame_Input size must match platform.odin");

typedef struct {
  int32_t animating;
  float wake_after; // seconds until the app wants a frame without input, 0 for none
} Frame_Result;
_Static_assert(sizeof(Frame_Result) == 8, "Frame_Result size must match platform.odin");

typedef struct {
  uint32_t abi_version;
  uint32_t _pad;
  void (*init)(Memory *mem, Shell *shell);
  void (*reload)(Memory *mem, Shell *shell);
  void (*unload)(Memory *mem);
  void (*shutdown)(Memory *mem);
  Frame_Result (*frame)(Memory *mem, Shell *shell, Frame_Input *input);
} App_API;
_Static_assert(sizeof(App_API) == 48, "App_API size must match platform.odin");

typedef App_API *(*App_Get_API)(void);
#define APP_GET_API_SYMBOL "app_get_api"
