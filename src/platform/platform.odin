// Types shared by the Obj-C shell and the app dylib. shell/platform.h mirrors
// this file field for field. Change both together and bump ABI_VERSION;
// tests/abi_test.odin compares their field offsets.
package platform

ABI_VERSION :: 7

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
	Media, // media is the command, dx the position for .Seek
	// Text from the keyboard or an input method, for the focused text field.
	// It replaces the marked text if there is any, else the selection, or
	// the replace range when replace is set.
	Text,
	// The input method's composition: replaces the marked text if there is
	// any, else the selection, or the replace range, and becomes the new
	// marked text. Empty text ends the composition and removes it.
	Marked_Text,
	Unmark_Text, // the marked text stays as it is and is no longer marked
	Access_Press, // an assistive app pressed the node target
	Access_Focus, // an assistive app moved the focus to the node target
}

// Media keys, Control Center and headphones, from MPRemoteCommandCenter.
Media_Command :: enum u8 {
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
Mouse_Buttons :: bit_set[Mouse_Button; u32]

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

// Keys by their place on a US keyboard, whatever the layout says they type.
// Text comes in Text events; these are for shortcuts and editing. The shell
// maps its own key codes to these, and keys not listed here to None.
Key :: enum u32 {
	None,
	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Digit_0, Digit_1, Digit_2, Digit_3, Digit_4,
	Digit_5, Digit_6, Digit_7, Digit_8, Digit_9,
	Return,
	Tab,
	Space,
	Backspace,
	Delete, // forward delete
	Escape,
	Home,
	End,
	Page_Up,
	Page_Down,
	Left,
	Right,
	Up,
	Down,
	Grave,
	Keypad_Enter,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}
#assert(len(Key) == 65)

Modifier :: enum u32 {
	Shift,
	Control,
	Alt, // Option on macOS
	Super, // Command on macOS, the Windows key on Windows
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
	key:            Key,
	phase:          Scroll_Phase,
	momentum_phase: Scroll_Phase,
	precise:        b8,
	repeat:         b8,
	replace:        b8, // Text, Marked_Text: replace_start and replace_end are set
	media:          Media_Command,
	text_offset:    u32, // Text, Marked_Text: the text is Frame_Input.text[text_offset:][:text_length], UTF-8
	text_length:    u32,
	replace_start:  i32, // bytes of the field's text
	replace_end:    i32,
	select_start:   i32, // Marked_Text: the input method's selection inside the marked text, bytes
	select_end:     i32,
	target:         u64, // Access_Press, Access_Focus: the node's id
}
#assert(size_of(Event) == 88)

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

// The focused text field, for the input method. The shell answers
// NSTextInputClient's questions from it, and puts the candidate window
// under caret.
Text_Input :: struct {
	text:            [^]u8, // UTF-8; nil when no text field has the focus
	length:          u32,
	selection_start: u32, // bytes, start <= end
	selection_end:   u32,
	marked_start:    i32, // bytes; -1 without marked text
	marked_end:      i32,
	limit:           u32, // most bytes the field takes, 0 for no limit
	caret:           [4]f32, // x, y, w, h in view points: the marked text, or the caret
}
#assert(size_of(Text_Input) == 48)

Access_Role :: enum u32 {
	None,
	Group,
	Button,
	Text_Field,
	Static_Text,
	List,
	Table,
	Row,
	Menu,
	Menu_Item,
	Slider,
}

Access_Flag :: enum u32 {
	Focused,
	Selected,
	Disabled,
}
Access_Flags :: bit_set[Access_Flag; u32]

// One element of the accessibility tree. Nodes come parents first; parent
// is the index of the parent node, or -1 for the window's content.
Access_Node :: struct {
	id:     u64, // stable across frames
	parent: i32,
	role:   Access_Role,
	flags:  Access_Flags,
	_:      u32,
	frame:  [4]f32, // x, y, w, h in view points
	label:  cstring, // UTF-8 or nil
	value:  cstring,
}
#assert(size_of(Access_Node) == 56)

// What Shell.surface points to on Linux: the Wayland connection and the
// window's surface, for the renderer to make a Vulkan surface from. The
// shell owns both.
Wayland_Surface :: struct {
	display: rawptr, // wl_display
	surface: rawptr, // wl_surface
}
#assert(size_of(Wayland_Surface) == 16)

// What the shell gives the app. The surface and the procedures belong to
// the shell, so they stay valid across reloads and the app may keep them.
Shell :: struct {
	// What the renderer draws to, set up by the shell: a CAMetalLayer with its
	// device on macOS, a Wayland_Surface on Linux.
	surface:           rawptr,
	// Safe from any thread. Wakes the main run loop and draws one frame.
	request_redraw:  proc "c" (),
	// The rest are main thread only.
	set_now_playing:   proc "c" (info: ^Now_Playing),
	// nil or a Text_Input with a nil text when no text field has the focus.
	// The shell copies it.
	set_text_input:    proc "c" (input: ^Text_Input),
	set_clipboard:     proc "c" (text: [^]u8, length: uint),
	// Copies up to capacity bytes of the clipboard's text and returns its
	// whole length. buffer may be nil to ask for the length.
	get_clipboard:     proc "c" (buffer: [^]u8, capacity: uint) -> uint,
	// The shell copies the nodes and their strings.
	set_accessibility: proc "c" (nodes: [^]Access_Node, count: u32),
	// Where a press moves the window, as x, y, w, h in view points: the
	// empty parts of the titlebar the view draws under. The shell copies
	// them. nil on Linux.
	set_drag_regions:  proc "c" (rects: [^][4]f32, count: u32),
}
#assert(size_of(Shell) == 64)

Frame_Input :: struct {
	events:        [^]Event,
	event_count:   u32,
	width, height: f32, // view size in points
	scale:         f32, // backing scale factor
	time:          f64, // seconds since the shell started
	text:          [^]u8, // what Text and Marked_Text events point into
	text_length:   u32,
	key_window:    b32, // the window gets key events
	// Held down now, whichever app got the events, so the UI can drop a press
	// whose release went elsewhere.
	mouse_buttons: Mouse_Buttons,
	// The window's buttons sit over the view's top titlebar_height points,
	// and end titlebar_inset points from its left edge. Both 0 when the
	// window has its own titlebar, or none, as in full screen.
	titlebar_height: f32,
	titlebar_inset:  f32,
	_:               u32,
}

Frame_Result :: struct {
	// Keep the display link running and call frame again next vsync.
	animating:  b32,
	// Seconds until the app wants a frame without input, as for a caret's
	// next blink; 0 for none. A timer wakes the shell, not the display link.
	wake_after: f32,
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
#assert(size_of(Frame_Input) == 64)
#assert(size_of(Frame_Result) == 8)
#assert(size_of(App_API) == 48)

GET_API_SYMBOL :: "app_get_api"
