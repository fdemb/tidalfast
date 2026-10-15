// Types shared by the Obj-C shell and the app dylib. shell/platform.h mirrors
// this file field for field. Change both together and bump ABI_VERSION.
package platform

ABI_VERSION :: 2

Event_Kind :: enum u32 {
	None,
	Mouse_Down,
	Mouse_Up,
	Mouse_Move,
	Mouse_Leave,
	Scroll,
	Key_Down,
	Key_Up,
	Modifiers_Changed,
	Resize,
	Media, // key_code is a Media_Command, dx the position for .Seek
}

// Media keys, Control Center and headphones, from MPRemoteCommandCenter.
Media_Command :: enum u32 {
	None,
	Play,
	Pause,
	Toggle,
	Next,
	Previous,
	Seek,
}

Mouse_Button :: enum u32 {
	Left,
	Right,
	Middle,
}

// Mirrors NSEventPhase. Trackpad scrolls carry a phase while the fingers are
// down and a momentum phase for the inertia that follows. Mouse wheels have
// neither.
Scroll_Phase :: enum u32 {
	None,
	May_Begin,
	Began,
	Changed,
	Stationary,
	Ended,
	Cancelled,
}

Modifier :: enum u32 {
	Shift,
	Control,
	Option,
	Command,
	Caps_Lock,
}
Modifiers :: bit_set[Modifier; u32]

// Positions are in points with the origin at the top left of the view.
Event :: struct {
	kind:           Event_Kind,
	modifiers:      Modifiers,
	time:           f64, // seconds, NSEvent.timestamp
	x, y:           f32,
	// Scroll delta in points for precise (trackpad) scrolls, in lines otherwise.
	dx, dy:         f32,
	button:         Mouse_Button,
	click_count:    u32,
	key_code:       u32, // macOS virtual key code
	phase:          Scroll_Phase,
	momentum_phase: Scroll_Phase,
	precise:        b8,
	repeat:         b8,
	_:              [2]u8,
}
#assert(size_of(Event) == 56)

// Memory the shell allocates once and passes to every app call. It outlives
// any one dylib, so it is where all app state goes. Both blocks start zeroed.
Memory :: struct {
	persistent:      [^]u8,
	persistent_size: uint,
	frame:           [^]u8,
	frame_size:      uint,
}

Now_Playing_State :: enum u32 {
	Stopped,
	Playing,
	Paused,
}

// What macOS shows in Control Center and on the lock screen. The shell
// copies everything before set_now_playing returns.
Now_Playing :: struct {
	title:          cstring, // nil clears Now Playing
	artist:         cstring,
	album:          cstring,
	duration:       f64, // seconds
	elapsed:        f64,
	state:          Now_Playing_State,
	artwork_width:  u32,
	artwork_height: u32,
	_:              u32,
	artwork:        [^]u8, // RGBA8 sRGB, premultiplied, or nil
	artwork_key:    u64, // the shell rebuilds the artwork only when this changes
}
#assert(size_of(Now_Playing) == 72)

// What the shell gives the app. The Metal objects and the procedures belong
// to the shell, so they stay valid across reloads and the app may keep them.
Shell :: struct {
	metal_device:    rawptr, // id<MTLDevice>
	metal_layer:     rawptr, // CAMetalLayer*
	// Safe from any thread. Wakes the main run loop and draws one frame.
	request_redraw:  proc "c" (),
	// Main thread only.
	set_now_playing: proc "c" (info: ^Now_Playing),
}
#assert(size_of(Shell) == 32)

Frame_Input :: struct {
	events:        [^]Event,
	event_count:   u32,
	width, height: f32, // view size in points
	scale:         f32, // backing scale factor
	time:          f64, // seconds since the shell started
}

Frame_Result :: struct {
	// Keep the display link running and call frame again next vsync.
	animating: b32,
}

// Returned by app_get_api. The shell calls init on the first load, unload on
// the old dylib and reload on the new one around a hot reload, and shutdown on
// quit.
App_API :: struct {
	abi_version: u32,
	_:           u32,
	init:        proc "c" (mem: ^Memory, shell: ^Shell),
	reload:      proc "c" (mem: ^Memory, shell: ^Shell),
	unload:      proc "c" (mem: ^Memory),
	shutdown:    proc "c" (mem: ^Memory),
	frame:       proc "c" (mem: ^Memory, shell: ^Shell, input: ^Frame_Input) -> Frame_Result,
}
#assert(size_of(Frame_Input) == 32)
#assert(size_of(App_API) == 48)

GET_API_SYMBOL :: "app_get_api"
