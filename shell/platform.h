// Mirror of src/platform/platform.odin. Change both together and bump
// PLATFORM_ABI_VERSION.
#pragma once

#include <stdint.h>
#include <stddef.h>

#define PLATFORM_ABI_VERSION 1

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
} Event_Kind;

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
  uint8_t _pad[2];
} Event;
_Static_assert(sizeof(Event) == 56, "Event size must match platform.odin");

typedef struct {
  uint8_t *persistent;
  size_t persistent_size;
  uint8_t *frame;
  size_t frame_size;
} Memory;

typedef struct {
  void *metal_device;
  void *metal_layer;
  void (*request_redraw)(void);
} Shell;

typedef struct {
  Event *events;
  uint32_t event_count;
  float width, height;
  float scale;
  double time;
} Frame_Input;
_Static_assert(sizeof(Frame_Input) == 32, "Frame_Input size must match platform.odin");

typedef struct {
  int32_t animating;
} Frame_Result;

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
