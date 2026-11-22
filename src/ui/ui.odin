// A Fleury-style immediate-mode UI. Every frame the app builds a tree of
// boxes; end_frame lays the tree out, draws it and records where each box
// ended up. Input in the next frame is tested against those rects, so a box
// answers for what the user saw.
//
// A box built with an ID string is keyed by a hash of that string, seeded
// with the key of its nearest keyed ancestor. Keyed boxes live in a pool in
// the persistent arena and keep their rect, animation values and scroll
// offset across frames. A box not built for one whole frame is freed. A box
// without an ID lives in the frame arena for one frame.
//
// "Play##row12" displays "Play" and hashes the whole string. "Play###row12"
// hashes only "###row12", so the label can change without changing the key.
//
// State holds no allocators. Its only procedure pointers are the shell's
// clipboard, which set_clipboard gives it every frame. The other per-frame
// pointers (renderer, text, the build tree) are set again by begin_frame.
package ui

import "core:hash"
import "core:log"
import "core:math"
import "core:slice"

import "../platform"
import "../render"
import "../text"

MAX_BOXES :: 8192
TEMP_BOXES :: 64 // boxes without a key are taken from the frame's memory this many at a time
BOX_TABLE :: 4096 // buckets, a power of two
MAX_KEY_PRESSES :: 32
NAV_BUTTONS :: platform.Mouse_Buttons{.Back, .Forward}
MAX_EDIT_EVENTS :: 64
MAX_SHORTCUTS :: 8
STACK_DEPTH :: 64
TOOLTIP_DELAY :: 1 // seconds of hovering before a tooltip shows
TOOLTIP_WARM :: 1 // seconds after a tooltip that the next one shows without the delay
DRAG_THRESHOLD :: 4 // points the mouse moves before a press becomes a drag
FADE_IN :: 0.08 // seconds hot_fade, active_t and focus_t take from 0 to 1
FADE_OUT :: 0.16 // seconds they take from 1 to 0
MAX_SETTLE_FRAMES :: 3 // extra frames in a row that a layout mismatch may ask for

Key :: distinct u64

Axis :: enum u8 {
	X,
	Y,
}

Size_Kind :: enum u8 {
	Null,
	Pixels, // value points
	Text, // the label's width or line height, plus value points
	Parent_Pct, // value times the nearest ancestor with a size of its own
	Children_Sum, // children added up along the child axis, the largest across it
}

// strictness is how much of the size a box keeps when its parent has too
// little room: 1 keeps all of it, 0 gives all of it up.
Size :: struct {
	kind:       Size_Kind,
	value:      f32,
	strictness: f32,
}

Align :: enum u8 {
	Left,
	Center,
	Right,
}

Box_Flag :: enum u32 {
	Clickable, // gets hot and active, takes mouse presses
	Focusable, // Tab stops here, Enter clicks it, and Space in a menu
	View_Scroll, // takes scroll input into view_off
	Allow_Overflow_X, // children may be wider than the box
	Allow_Overflow_Y,
	Floating_X, // placed at fixed_pos, outside the parent's layout
	Floating_Y,
	Clip, // children are clipped to the box
	Disabled, // no input
	Draw_Background,
	Draw_Border,
	Draw_Text,
	Draw_Shadow,
	Draw_Hot_Effects, // hover_color fades in while hot
	Draw_Active_Effects, // active_color fades in while pressed
	Draw_Hot_Underline, // the label is underlined while hot
	Text_Input, // a text field: with the focus it takes Return, Space, the arrows and Escape
	Click_On_Release, // clicked on a release over it rather than on the press, for drag sources
	Window_Drag, // empty titlebar space: a press there moves the window, see drag_regions
	Draw_Backdrop, // background over a blur of what's under the box, see render.push_backdrop
	Click_Shield, // clickable only so presses don't reach what's under it; under the titlebar it moves the window, see cut_drag_regions
	Focus_Is_Hot, // hot while it's the menu's highlight, see menu_highlight: hover and the keyboard move one highlight
	No_Focus_Ring, // shows the focus itself, as a table does with its selected row
	Shrink_From_End, // children that don't fit give up room from the end, not in proportion: the one crossing the edge is cut short and those after it get none
	Center_Children, // children sit in the middle of the room along the child axis, as between two fill() spacers, for a box that's only there to centre something
	Draw_Glass, // a lens of glass tinted by background, lit while hot and swelling while pressed, see render.push_glass
	Instant_Hover, // hot_t jumps with no fade, for list rows and tiles: a fast mouse is on one for a few frames, and a fade would light neighbours unevenly. end_frame lights the one under the mouse in this frame's layout
	Takes_Scroll, // a scroll over it goes to it along both axes, in Signal.scroll, and not to a view behind it: a control the wheel turns, as the volume
	Arrow_Keys, // with the focus it keeps the arrow keys for ui.take_key rather than moving the focus with them, as a slider does, see slider_keys
}
Box_Flags :: bit_set[Box_Flag; u32]

Box :: struct {
	// Kept across frames for keyed boxes.
	key:             Key,
	hash_next:       ^Box,
	first_frame:     u64,
	last_frame:      u64,
	rect:            render.Rect, // from the last layout
	clip:            render.Rect, // rect cut by every clipping ancestor
	view_bounds:     [2]f32, // size of the children from the last layout
	view_off:        [2]f32, // scroll offset drawn
	view_off_target: [2]f32, // where view_off is easing to
	stretch:         Stretch, // a trackpad pulling the content past its end, drawn on top of view_off
	built_size:      [2]f32, // the size a scroll view's children were built for, see build_size
	bar_t:           f32, // a scroll view's scrollbar fading in
	bar_seen:        f32, // view_off.y when the scrollbar was last built
	bar_time:        f64, // when view_off.y last moved, or the mouse or the focus came in
	bar_hovered:     bool, // the mouse was over the view when the scrollbar was last built
	bar_focused:     bool, // the focus was in the view then
	bar_grab:        f32, // where in the thumb the mouse took it
	hot_t:           f32, // how lit the hover is, along a smoothstep curve: what draws it
	hot_fade:        f32, // hot_t's linear progress, before its curve
	active_t:        f32,
	focus_t:         f32,
	open_t:          f32, // menus and tooltips fading in, a switch sliding (slide)

	using build:     Build,
}

// Build is what a box is given each frame. box_make clears it.
Build :: struct {
	parent, first, last, next: ^Box,
	child_count:               int,
	pref_size:                 [Axis]Size,
	child_axis:                Axis,
	fixed_pos:                 [2]f32, // relative to the parent
	fixed_size:                [2]f32,
	gutter:                    f32, // points at the right that children's widths leave out
	pad:                       [2]f32, // points before and after the children on each axis, inside the box
	inset_end:                 f32, // a scroll view's bottom under something drawn over it, see scroll_view
	bar_top:                   f32, // a scroll view's top right under something drawn over it, which its scrollbar stays below
	keep_in_window:            bool, // a floating box moved inside the window once its size is known, see fit_floating
	flip_y:                    f32, // with keep_in_window, where its bottom goes when it doesn't fit below
	above:                     bool, // with keep_in_window, its bottom goes at flip_y even when it fits below
	anchor:                    ^Box, // a floating box centred under this one, or above it when there's no room below, see fit_floating
	tab_first:                 ^Box, // Tab reaches this box and its children before the boxes inside this ancestor, see tab_first
	hit_from:                  int, // how many hits the frame had when finish reached the box
	id:                        string, // as given; must live until end_frame
	label:                     string, // the part of id before "##"
	using style:               Style,
	backdrop:                  Backdrop, // with Draw_Backdrop, background tints it
	gradient:                  render.Color, // bottom colour of the background, when its alpha isn't 0
	texture:                   render.Texture, // drawn over the background, rounded by radius
	texture_src:               render.Rect, // texels of texture to draw; zero for all of it
	rim:                       render.Rim, // a hairline inside the edge, see render.push_rim
	tilt:                      render.Tilt, // the background or texture leans under the pointer, see render.push_tilt; draw sets the pointer
	opacity:                   f32, // multiplies the box and everything inside it
	shown_by:                  ^Box, // drawn at least as opaque as this box's hot_t, see show_on_hover
	run:                       ^text.Run,
	text_size:                 [2]f32, // the label's size with padding, measured in end_frame
	// What assistive apps see: a role puts the box in the accessibility
	// tree. The strings must live until end_frame.
	access_role:               platform.Access_Role,
	access_label:              string,
	access_value:              string,
	access_selected:           bool,
}

// Backdrop is the blur a Draw_Backdrop box draws its background over.
Backdrop :: struct {
	blur:       f32, // points it reaches
	saturation: f32, // 1 keeps the colours
}

Signal :: struct {
	box:            ^Box,
	hovering:       bool, // hot, or the parent of the hot box
	held:           bool, // left button went down on the box and is still down
	pressed:        bool, // left button went down on the box this frame
	released:       bool, // left button came up after being pressed on the box
	clicked:        bool, // pressed on the box, or released over it with Click_On_Release, or Enter while focused, or Space on a menu item
	keyboard:       bool, // clicked came from a key
	double_clicked: bool,
	right_clicked:  bool, // right or control-click went down on the box
	dragging:       bool, // pressed on the box and moved past DRAG_THRESHOLD, until the release
	drag_delta:     [2]f32, // mouse movement since the press, up to the release if released
	mouse:          [2]f32, // while held the mouse, when released where the button came up
	scroll:         [2]f32, // points scrolled over the box this frame
	scroll_precise: [2]f32, // the part of scroll from trackpads; the rest is wheel lines of SCROLL_LINE
}

// One interactive box from the last layout, in drawing order.
Hit :: struct {
	key:          Key,
	rect:         render.Rect, // clipped
	flags:        Box_Flags,
	group:        Key, // nearest keyed ancestor, for arrow keys
	focus_parent: Key, // nearest focusable ancestor
	click_parent: Key, // nearest clickable ancestor
	floating:     bool,
	in_menu:      bool, // the open menu or inside it
	tab:          int, // where Tab reaches it: twice its place in the hits, plus one, or for a tab_first box twice its ancestor's hit_from
}

Key_Press :: struct {
	code:      platform.Key,
	modifiers: platform.Modifiers,
	repeat:    bool, // the key is held and the OS sent it again
}

// Edit_Event is a key press the UI didn't use, text from the shell, a
// text field getting or losing the focus, or a left press on one, in the
// order they came. target is the box that had the focus when it came, or
// the one that got or lost it or was pressed.
Edit_Event :: struct {
	op:                     Edit_Op,
	target:                 Key,
	select_all:             bool, // .Focus: select the field's text, as for Cmd-F
	key:                    Key_Press,
	text:                   string, // this frame's
	replace:                bool,
	replace_lo, replace_hi: int,
	select_lo, select_hi:   int,
	pos:                    [2]f32, // .Press: where
	click_count:            u32, // .Press: 2 for a double-click, 3 for a triple
	extend:                 bool, // .Press: with Shift
}

Edit_Op :: enum u8 {
	Key,
	Text,
	Marked_Text,
	Unmark_Text,
	Focus,
	Blur,
	Press,
}

// Shortcut is a key that gives a text field the focus, from focus_shortcut.
Shortcut :: struct {
	key:    Key_Press,
	target: Key,
}

State :: struct {
	boxes:          []Box, // the pool keyed boxes come from
	boxes_used:     int,
	free:           ^Box,
	table:          []^Box,
	box_count:      int,
	temp_boxes:     []Box, // the rest of this frame's last chunk of TEMP_BOXES
	hits:           []Hit,
	hit_count:      int,
	drag_rects:     [16]render.Rect, // the Window_Drag boxes, from end_frame; MAX_DRAG_REGIONS in the shells
	drag_count:     int,
	drag_from:      [16]int, // the hit list's length when each drag rect was found

	frame:          u64,
	time:           f64,
	dt:             f32,
	animated_before: bool, // the frame before last ended with animating set
	width, height:  f32,
	renderer:       ^render.Renderer, // this frame's
	texts:          ^text.State,
	root:           ^Box,
	floating_root:  ^Box,
	parents:        Stack(^Box),
	parent_misused: bool, // a pop_parent with none pushed
	parent_leaks:   int, // frames that ended with the parent stack unbalanced
	styles:         Styles,
	style_leaks:    int,
	drag_dropped:   bool, // this frame had more drag region pieces than drag_rects holds
	drag_drops:     int, // frames that did

	input:          Input,
	hot:            Key,
	hot_parent:     Key, // the hot box's clickable parent, which counts as hovered
	hot_since:      f64,
	hot_by_mouse:   bool, // the mouse moving made hot what it is, not boxes moving under it
	active:         [platform.Mouse_Button]Key,
	pressed:        [platform.Mouse_Button]Key, // this frame
	released:       [platform.Mouse_Button]Key,
	clicked:        [platform.Mouse_Button]Key,
	release_click:  [platform.Mouse_Button]bool, // the active box clicks on the release
	double_clicked: Key,
	drag_start:     [2]f32,
	drag_moved:     bool, // past DRAG_THRESHOLD since the press
	control_click:  bool, // the left button is down as a control-click
	buttons_stale:  platform.Mouse_Buttons, // held here but up in hardware last frame
	scroll_latch:   [2]Key, // the scroll views a trackpad gesture started over
	scroll_key:     [2]Key, // this frame's scroll goes to these boxes
	scroll:         [2]f32, // points, this frame
	scroll_precise: [2]f32, // the part of scroll from trackpads, applied without easing
	gesture:        Gesture, // the trackpad gesture, for stretch_view
	focus:          Key,
	focus_visible:  bool, // the focus came from the keyboard, so draw a ring
	focus_reveal:   bool, // the keyboard moved the focus: scroll it into view
	key_click:      Key, // Enter, or Space in a menu, this frame
	keys:           [MAX_KEY_PRESSES]Key_Press, // presses the UI didn't use
	nav_buttons:    platform.Mouse_Buttons, // Back and Forward pressed this frame, for take_button
	key_count:      int,
	edits:          [MAX_EDIT_EVENTS]Edit_Event,
	edit_count:     int,
	// Last frame's focus_shortcut calls, which this frame's keys go by.
	shortcuts:      [MAX_SHORTCUTS]Shortcut,
	shortcut_count: int,
	window_inactive: bool, // another window has the keyboard
	wake:           f64, // the earliest time something asked for a frame at, 0 for none
	// The focused text field, for the shell and the input method.
	text_input:     platform.Text_Input,
	text_claimed:   bool, // a focused field set text_input this frame
	text_sent:      u64, // hash of what the shell has
	// A field took text from the shell, whose mirror applied it its own
	// way, so the state goes to the shell even if it didn't change.
	text_resend:    bool,
	// The shell's clipboard, set with set_clipboard every frame.
	clipboard_get:  proc "c" (buffer: [^]u8, capacity: uint) -> uint,
	clipboard_set:  proc "c" (text: [^]u8, length: uint),
	access_nodes:   []platform.Access_Node, // this frame's tree, from end_frame
	access_hash:    u64,

	menu:           Key, // the open or closing context menu, 0 if none
	menu_open:      bool,
	menu_pos:       [2]f32,
	menu_up:        bool, // the menu's bottom goes at menu_pos, see open_menu
	menu_built:     bool,
	menu_focus_new: bool, // the first menu item built takes the focus
	menu_saved:     Key, // the focus before the menu opened, restored when it closes
	menu_saved_vis: bool,
	menu_lit:       Key, // the item highlighted when the menu closed, lit while it fades out
	tooltip_seen:   f64, // when a tooltip was last built
	tooltip_dismissed: Key, // the box clicked, which shows no tooltip until the mouse leaves it

	drag_active:    bool,
	drag_payload:   u64,
	drag_cancelled: bool, // Escape ended the drag; no new one until the next press
	drag_unclaimed: bool, // a press past DRAG_THRESHOLD came up this frame before drag_begin
	drop:           bool, // a drag ended this frame, at drop_pos
	drop_next:      bool, // drop in the next frame
	drop_payload:   u64,
	drop_pos:       [2]f32,

	settle_frames:  int, // frames in a row asked for by a layout mismatch
	pool_misses:    int, // keyed boxes this frame that got no state, the pool being full
	pool_miss_last: u64, // the last frame with pool misses
	pool_logged_at: f64,

	scrollbars:     Scrollbars, // how scroll views show their scrollbars, set by the app
	debug:          bool, // outline every box, show the key under the mouse
	animating:      bool, // something is still moving, draw another frame
}

@(thread_local, private)
ctx: ^State

// init allocates the box pool from context.allocator, which must outlive
// State (the persistent arena).
init :: proc(u: ^State) {
	u.boxes = make([]Box, MAX_BOXES)
	u.table = make([]^Box, BOX_TABLE)
	u.hits = make([]Hit, MAX_BOXES)
	// No tooltip yet, though the time may start at 0.
	u.tooltip_seen = -TOOLTIP_WARM
}

// Sizes

px :: proc(v: f32, strictness: f32 = 1) -> Size {
	return {.Pixels, v, strictness}
}

text_size :: proc(padding: f32 = 0, strictness: f32 = 1) -> Size {
	return {.Text, padding, strictness}
}

pct :: proc(v: f32, strictness: f32 = 0) -> Size {
	return {.Parent_Pct, v, strictness}
}

children_sum :: proc(strictness: f32 = 1) -> Size {
	return {.Children_Sum, 0, strictness}
}

// fill takes whatever room the parent has left.
fill :: proc() -> Size {
	return pct(1, 0)
}

// Keys

key_from_string :: proc(seed: Key, id: string) -> Key {
	_, hashed := split_id(id)
	return key_of(seed, hashed)
}

label_from_string :: proc(id: string) -> string {
	label, _ := split_id(id)
	return label
}

// split_id finds in one pass what box_make needs from an id: the label,
// up to the first "##", and the part the key hashes, from the first "###"
// on or else all of it. Every "###" is a "##", so the first comes no
// earlier.
@(private)
split_id :: proc(id: string) -> (label, hashed: string) {
	label, hashed = id, id
	for i in 0 ..< len(id) - 1 {
		if id[i] != '#' || id[i + 1] != '#' {
			continue
		}
		label = id[:i]
		for j in i ..< len(id) - 2 {
			if id[j] == '#' && id[j + 1] == '#' && id[j + 2] == '#' {
				hashed = id[j:]
				break
			}
		}
		break
	}
	return
}

@(private)
key_of :: proc(seed: Key, hashed: string) -> Key {
	if hashed == "" {
		return 0
	}
	h := hash.fnv64a(transmute([]byte)hashed) if seed == 0 else hash.fnv64a(transmute([]byte)hashed, u64(seed))
	return Key(h if h != 0 else 1)
}

// seed_key is the key of the nearest keyed box from b up.
seed_key :: proc(b: ^Box) -> Key {
	for p := b; p != nil; p = p.parent {
		if p.key != 0 {
			return p.key
		}
	}
	return 0
}

box_lookup :: proc(u: ^State, key: Key) -> ^Box {
	if key == 0 {
		return nil
	}
	for b := u.table[int(u64(key) & (BOX_TABLE - 1))]; b != nil; b = b.hash_next {
		if b.key == key {
			return b
		}
	}
	return nil
}

// Frame

// begin_frame prunes boxes that weren't built last frame, takes this frame's
// events and sets up the roots. Strings given to boxes must live until
// end_frame. hardware is the buttons down right now, from Frame_Input.mouse_buttons;
// without it the UI goes by the events alone.
// text is the bytes Text and Marked_Text events point into.
// frame_interval is the display's, from Frame_Input.frame_interval, or 0
// when the shell doesn't know it.
begin_frame :: proc(u: ^State, events: []platform.Event, r: ^render.Renderer, t: ^text.State, width, height: f32, time: f64, hardware: Maybe(platform.Mouse_Buttons) = nil, text_bytes: []u8 = nil, frame_interval: f32 = 0) {
	ctx = u
	u.frame += 1
	if width != u.width || height != u.height || len(events) > 0 {
		u.settle_frames = 0
	}
	// Nothing was easing across the gap after a frame that settled, so the
	// next step is one refresh of the display long. The interval after that
	// can be irregular, as the swap chain wakes up, so it steps no more.
	refresh := min(frame_interval, 1.0 / 30) if frame_interval > 0 else 1.0 / 60
	elapsed := f32(clamp(time - u.time, 0, 1.0 / 30))
	switch {
	case !u.animating:
		u.dt = refresh
	case !u.animated_before:
		u.dt = min(elapsed, refresh)
	case:
		u.dt = elapsed
	}
	u.animated_before = u.animating
	u.time = time
	u.width = width
	u.height = height
	u.renderer = r
	u.texts = t
	u.animating = false
	u.menu_built = false
	u.pool_misses = 0
	u.wake = 0
	u.text_claimed = false
	u.access_nodes = nil
	u.temp_boxes = nil
	prune(u)
	if held, ok := hardware.?; ok {
		release_stale(u, events, held)
	}
	process_events(u, events, text_bytes)
	u.shortcut_count = 0

	u.parents.count = 0
	u.parent_misused = false
	if !styles_clear(&u.styles) {
		u.style_leaks += 1
		if u.style_leaks == 1 {
			log.error("ui: a frame left a style scope open or a set_next unused, or opened or closed a scope between a set_next and its box")
		}
	}
	u.root = new(Box, context.temp_allocator)
	u.root.pref_size = {.X = px(width), .Y = px(height)}
	u.root.child_axis = .Y
	u.root.opacity = 1
	u.floating_root = new(Box, context.temp_allocator)
	u.floating_root.pref_size = {.X = px(width), .Y = px(height)}
	u.floating_root.opacity = 1
	push_parent(u.root)
}

// prune frees keyed boxes that weren't built in the last frame and drops
// interaction state that points at them. It goes through the part of the
// pool ever used rather than the table, which has many more buckets than a
// frame has boxes. A free box has no key.
@(private)
prune :: proc(u: ^State) {
	for &b in u.boxes[:u.boxes_used] {
		if b.key == 0 || b.last_frame + 1 >= u.frame {
			continue
		}
		link := &u.table[int(u64(b.key) & (BOX_TABLE - 1))]
		for link^ != &b {
			link = &link^.hash_next
		}
		link^ = b.hash_next
		b = {}
		b.hash_next = u.free
		u.free = &b
		u.box_count -= 1
	}
	for &k in u.active {
		if box_lookup(u, k) == nil {
			k = 0
		}
	}
	if box_lookup(u, u.focus) == nil {
		u.focus = 0
	}
	if box_lookup(u, u.menu_saved) == nil {
		u.menu_saved = 0
	}
	if box_lookup(u, u.menu_lit) == nil {
		u.menu_lit = 0
	}
}

// release_stale cancels buttons held since an earlier frame that the
// hardware says are up, as when the release went to another app. A button
// must look like that for two frames in a row, since its release may be on
// its way. Cancelled buttons don't release or click anything, and a drag
// they held ends without a drop.
@(private)
release_stale :: proc(u: ^State, events: []platform.Event, hardware: platform.Mouse_Buttons) {
	held := hardware
	// A control-click goes down as the left button and counts as the right.
	if u.control_click && .Left in held {
		held += {.Right}
	}
	stale := u.input.buttons - held
	for e in events {
		if e.kind == .Mouse_Down || e.kind == .Mouse_Up {
			stale -= {e.button, .Right} if e.button == .Left else {e.button}
		}
	}
	gone := stale & u.buttons_stale
	u.buttons_stale = stale - gone
	if u.buttons_stale != {} {
		u.animating = true
	}
	cancel_buttons(u, gone)
}

@(private)
cancel_buttons :: proc(u: ^State, buttons: platform.Mouse_Buttons) {
	u.input.buttons -= buttons
	for b in buttons {
		u.active[b] = 0
	}
	if .Right in buttons {
		u.control_click = false
	}
	if .Left in buttons {
		u.drag_active = false
		u.drag_moved = false
	}
}

@(private)
process_events :: proc(u: ^State, events: []platform.Event, text_bytes: []u8) {
	input_begin_frame(&u.input)
	u.pressed = {}
	u.released = {}
	u.clicked = {}
	u.double_clicked = 0
	u.key_click = 0
	u.key_count = 0
	u.nav_buttons = {}
	u.edit_count = 0
	u.scroll = {}
	u.scroll_precise = {}
	u.scroll_key = {}
	u.gesture = {in_momentum = u.gesture.in_momentum, vel = u.gesture.vel, vel_time = u.gesture.vel_time}
	u.drop = u.drop_next
	u.drop_next = false
	u.drag_unclaimed = false

	moved := false
	for event in events {
		e := event
		// A control-click is a right click on macOS. Its mouse up still says
		// left, so remember it for the release.
		if CONTROL_CLICK_IS_RIGHT && e.kind == .Mouse_Down && e.button == .Left && .Control in e.modifiers {
			u.control_click = true
		}
		if u.control_click && e.button == .Left && (e.kind == .Mouse_Down || e.kind == .Mouse_Up) {
			e.button = .Right
			if e.kind == .Mouse_Up {
				u.control_click = false
			}
		}
		input_apply(&u.input, e)
		#partial switch e.kind {
		case .Mouse_Down:
			if e.button in NAV_BUTTONS {
				// They don't press anything under the mouse. With a menu open
				// they only close it, as a click outside does.
				if u.menu_open {
					close_menu()
				} else {
					u.nav_buttons += {e.button}
				}
			} else {
				mouse_pressed(u, e)
			}
		case .Mouse_Up:
			hover := hit_at(u, u.input.mouse)
			if k := u.active[e.button]; k != 0 {
				u.released[e.button] = k
				if hover == k && u.release_click[e.button] {
					u.clicked[e.button] = k
				}
				if e.button == .Left && u.drag_moved && !u.drag_active && !u.drag_cancelled {
					u.drag_unclaimed = true
				}
			}
			u.active[e.button] = 0
			// A drag ends on any left release, wherever the source is.
			if e.button == .Left && u.drag_active {
				u.drag_active = false
				u.drop = true
				u.drop_payload = u.drag_payload
				u.drop_pos = u.input.mouse
			}
		case .Mouse_Move:
			moved = true
			if u.active[.Left] != 0 && !u.drag_moved {
				d := u.input.mouse - u.drag_start
				u.drag_moved = d.x * d.x + d.y * d.y >= DRAG_THRESHOLD * DRAG_THRESHOLD
			}
		case .Scroll:
			// A trackpad gesture and its momentum keep scrolling the view it
			// started over. A mouse wheel goes wherever the mouse is.
			if e.phase == .Began || e.phase == .May_Begin || (e.phase == .None && e.momentum_phase == .None) || u.scroll_latch == {} {
				u.scroll_latch = {scroll_hit_at(u, u.input.mouse, .X), scroll_hit_at(u, u.input.mouse, .Y)}
			}
			u.scroll_key = u.scroll_latch
			d := scroll_delta(e)
			gesture_event(&u.gesture, e, d)
			// A box that takes scrolls follows the fingers, not the glide
			// after them, so a flick doesn't fling it.
			if e.momentum_phase != .None && takes_scroll(u, u.scroll_key) {
				break
			}
			u.scroll += d
			if e.precise {
				u.scroll_precise += d
			}
		case .Key_Down:
			key_down(u, e)
		case .Text, .Marked_Text, .Unmark_Text:
			text_event(u, e, text_bytes)
		case .Access_Press:
			// As if the keyboard clicked it: Signal.clicked and keyboard.
			if !menu_blocks(u, Key(e.target)) {
				u.key_click = Key(e.target)
			}
		case .Access_Focus:
			if h, at := find_hit(u, Key(e.target)); at >= 0 && .Focusable in h.flags {
				move_focus(u, h.key, true)
				u.focus_reveal = true
			}
		}
	}

	hot := hit_at(u, u.input.mouse) if u.input.mouse_inside else 0
	if active := u.active[.Left]; active != 0 && hot != active {
		hot = 0
	}
	if hot != u.hot {
		u.hot = hot
		u.hot_since = u.time
		u.hot_by_mouse = moved
		u.tooltip_dismissed = 0
	}
	h, _ := find_hit(u, hot)
	u.hot_parent = h.click_parent
	if moved && u.menu_open {
		menu_hover(u, hot)
	}
}

// menu_hover moves an open menu's highlight, which is the focus, to the
// item under the mouse, or takes it off when there's none, as a macOS menu
// does. Only a moving mouse does this, so the arrow keys move the highlight
// away from a still one.
@(private)
menu_hover :: proc(u: ^State, hot: Key) {
	item := Key(0)
	if h, at := find_hit(u, hot); at >= 0 && h.in_menu {
		item = h.key if .Focusable in h.flags else h.focus_parent
	}
	if item != u.focus {
		move_focus(u, item, false)
	}
}

@(private)
mouse_pressed :: proc(u: ^State, e: platform.Event) {
	pos := u.input.mouse
	if u.menu_open {
		panel := box_lookup(u, u.menu)
		if panel == nil || !rect_contains(panel.clip, pos) {
			// A left click outside an open menu only closes it. A right click
			// goes on, so it can open another.
			close_menu()
			if e.button != .Right {
				return
			}
		}
	}
	hover := hit_at(u, pos)
	u.active[e.button] = hover
	u.pressed[e.button] = hover
	if e.button == .Left {
		u.drag_start = pos
		u.drag_moved = false
		u.drag_cancelled = false
		if e.click_count >= 2 {
			u.double_clicked = hover
		}
	}
	// The press clicks the box unless it waits for the release, and moves
	// the focus to it, or its nearest focusable ancestor, or nowhere.
	u.release_click[e.button] = false
	focus := Key(0)
	if h, at := find_hit(u, hover); at >= 0 {
		u.release_click[e.button] = .Click_On_Release in h.flags
		focus = h.key if .Focusable in h.flags else h.focus_parent
	}
	if hover != 0 && !u.release_click[e.button] {
		u.clicked[e.button] = hover
	}
	move_focus(u, focus, false)
	if e.button == .Left && focus == hover && takes_text(u, hover) {
		queue_edit(u, {op = .Press, target = hover, pos = pos, click_count = e.click_count, extend = .Shift in u.input.modifiers})
	}
}

// move_focus gives key the focus. A text field that gets or loses it hears
// so through the edit events, in order with the keys and text around it.
// A field selects its text when it comes from the keyboard, as tabbing
// into a Mac text field does, or when select_all says so.
@(private)
move_focus :: proc(u: ^State, key: Key, visible: bool, select_all: Maybe(bool) = nil) {
	if key != u.focus && takes_text(u, u.focus) {
		queue_edit(u, {op = .Blur, target = u.focus})
	}
	all := select_all.? or_else visible
	if takes_text(u, key) && (key != u.focus || all) {
		queue_edit(u, {op = .Focus, target = key, select_all = all})
	}
	u.focus = key
	u.focus_visible = visible
}

@(private)
queue_edit :: proc(u: ^State, e: Edit_Event) {
	if u.edit_count < MAX_EDIT_EVENTS {
		u.edits[u.edit_count] = e
		u.edit_count += 1
	}
}

@(private)
key_down :: proc(u: ^State, e: platform.Event) {
	mods := e.modifiers & {.Shift, .Control, .Alt, .Super}
	code := e.key
	switch {
	case !e.repeat && (code == .F1 || (code == .D && mods == {PRIMARY, .Shift})):
		u.debug = !u.debug
		return
	case shortcut_for(u, {code = code, modifiers = mods}) != 0:
		target := shortcut_for(u, {code = code, modifiers = mods})
		if u.menu_open {
			close_menu()
		}
		move_focus(u, target, false, select_all = true)
		u.animating = true
		return
	case code == .Tab && mods - {.Shift} == {}:
		focus_step(u, -1 if .Shift in mods else 1)
		return
	case focus_takes_text(u) && (code == .Escape || code == .Return || code == .Space || code == .Up || code == .Down):
		// The text field has these.
	case code == .Escape && mods == {}:
		if u.drag_active {
			u.drag_active = false
			u.drag_cancelled = true
			return
		}
		if u.menu_open {
			close_menu()
			return
		}
		if u.focus != 0 {
			move_focus(u, 0, false)
			return
		}
	case code == .Return && mods == {} && u.focus != 0:
		// With a menu open, only its items take keys.
		if !menu_blocks(u, u.focus) {
			u.key_click = u.focus
		}
		return
	case code == .Space && mods == {} && u.menu_open:
		// Space clicks only in a menu. Elsewhere it goes to the app, which
		// plays and pauses with it.
		if u.focus != 0 && !menu_blocks(u, u.focus) {
			u.key_click = u.focus
		}
		return
	case (code == .Up || code == .Down) && mods == {} && !focus_keeps_arrows(u):
		if focus_arrow(u, .Y, -1 if code == .Up else 1) {
			return
		}
	case (code == .Left || code == .Right) && mods == {} && !focus_takes_text(u) && !focus_keeps_arrows(u):
		if focus_arrow(u, .X, -1 if code == .Left else 1) {
			return
		}
	}
	// With a menu open, the keys it doesn't use go nowhere, so a shortcut
	// such as M doesn't act behind it.
	if u.menu_open {
		return
	}
	if u.key_count < MAX_KEY_PRESSES {
		u.keys[u.key_count] = {code, mods, bool(e.repeat)}
		u.key_count += 1
	}
	queue_edit(u, {op = .Key, target = u.focus, key = {code, mods, bool(e.repeat)}})
}

@(private)
shortcut_for :: proc(u: ^State, k: Key_Press) -> Key {
	for sc in u.shortcuts[:u.shortcut_count] {
		if sc.key.code == k.code && sc.key.modifiers == k.modifiers {
			return sc.target
		}
	}
	return 0
}

// focus_keeps_arrows says whether the focused box takes the arrow keys
// itself, as a slider does, outside an open menu.
@(private)
focus_keeps_arrows :: proc(u: ^State) -> bool {
	h, at := find_hit(u, u.focus)
	return at >= 0 && .Arrow_Keys in h.flags && !u.menu_open
}

// focus_takes_text says whether the focused box is a text field.
@(private)
focus_takes_text :: proc(u: ^State) -> bool {
	return takes_text(u, u.focus)
}

@(private)
takes_text :: proc(u: ^State, key: Key) -> bool {
	h, at := find_hit(u, key)
	return at >= 0 && .Text_Input in h.flags
}

// text_event queues text from the shell for the focused text field.
@(private)
text_event :: proc(u: ^State, e: platform.Event, text_bytes: []u8) {
	s := ""
	if int(e.text_offset) + int(e.text_length) <= len(text_bytes) {
		s = string(text_bytes[e.text_offset:][:e.text_length])
	}
	op := Edit_Op.Text
	#partial switch e.kind {
	case .Marked_Text:
		op = .Marked_Text
	case .Unmark_Text:
		op = .Unmark_Text
	}
	queue_edit(u, {
		op         = op,
		target     = u.focus,
		text       = s,
		replace    = bool(e.replace),
		replace_lo = int(e.replace_start),
		replace_hi = int(e.replace_end),
		select_lo  = int(e.select_start),
		select_hi  = int(e.select_end),
	})
}

// focus_step moves the focus to the next or previous focusable box in
// drawing order, wrapping around. A box given tab_first comes before the
// boxes inside its ancestor, wherever it's drawn.
@(private)
focus_step :: proc(u: ^State, dir: int) {
	// Each focusable hit as its place in Tab order and its index.
	order := make([dynamic][2]int, 0, u.hit_count, context.temp_allocator)
	for h, i in u.hits[:u.hit_count] {
		if .Focusable in h.flags && (!u.menu_open || h.in_menu) {
			append(&order, [2]int{h.tab, i})
		}
	}
	n := len(order)
	if n == 0 {
		return
	}
	slice.sort_by(order[:], proc(a, b: [2]int) -> bool {return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])})
	// Step from the focus's place, or from where it would go among them.
	start := -1 if dir > 0 else n
	if h, at := find_hit(u, u.focus); at >= 0 {
		here := [2]int{h.tab, at}
		before := 0
		for o in order {
			if o[0] < here[0] || (o[0] == here[0] && o[1] < here[1]) {
				before += 1
			}
		}
		start = before
		if dir > 0 && (before == n || order[before] != here) {
			start = before - 1
		}
	}
	i := ((start + dir) % n + n) % n
	move_focus(u, u.hits[order[i][1]].key, true)
	u.focus_reveal = true
}

// menu_blocks reports whether an open menu keeps the keyboard from key.
@(private)
menu_blocks :: proc(u: ^State, key: Key) -> bool {
	if !u.menu_open {
		return false
	}
	h, at := find_hit(u, key)
	return at < 0 || !h.in_menu
}

// focus_arrow moves the focus to the nearest focusable box with the same
// keyed parent in the arrow's direction: past the focused box along axis
// and overlapping it across, so a column moves up and down, a row left and
// right, and a grid both ways. With none overlapping it goes to the
// nearest box past it at all, so a box off to the side, such as Settings
// beside the history buttons, is still reached. In an open menu it moves among the menu's items, starting at the
// first or last when none has the focus.
@(private)
focus_arrow :: proc(u: ^State, axis: Axis, dir: int) -> bool {
	group := Key(0)
	if h, at := find_hit(u, u.focus); at >= 0 && .Focusable in h.flags {
		group = h.group
	}
	if u.menu_open && axis == .Y {
		return menu_arrow(u, dir)
	}
	if u.menu_open && group != u.menu {
		for i := 0 if dir > 0 else u.hit_count - 1; i >= 0 && i < u.hit_count; i += dir {
			h := u.hits[i]
			if .Focusable in h.flags && h.group == u.menu {
				move_focus(u, h.key, true)
				u.focus_reveal = true
				return true
			}
		}
		return false
	}
	from := box_lookup(u, u.focus)
	if group == 0 || from == nil {
		return false
	}
	span :: proc(r: render.Rect, axis: Axis) -> (lo, hi: f32) {
		if axis == .X {
			return r.x, r.x + r.w
		}
		return r.y, r.y + r.h
	}
	cross := Axis.Y if axis == .X else .X
	lo, hi := span(from.rect, axis)
	clo, chi := span(from.rect, cross)
	best := Key(0)
	best_overlaps: bool
	best_gap, best_off: f32
	for h in u.hits[:u.hit_count] {
		b := box_lookup(u, h.key)
		if h.key == u.focus || .Focusable not_in h.flags || h.group != group || b == nil {
			continue
		}
		blo, bhi := span(b.rect, axis)
		gap := blo - hi if dir > 0 else lo - bhi
		if gap < -0.5 {
			continue
		}
		bclo, bchi := span(b.rect, cross)
		overlaps := bclo < chi && bchi > clo
		off := max(bclo - chi, clo - bchi, 0) if !overlaps else abs((bclo + bchi) - (clo + chi))
		better := best == 0 || overlaps && !best_overlaps
		if !better && overlaps == best_overlaps {
			better = gap < best_gap - 0.5 || (gap <= best_gap + 0.5 && off < best_off)
		}
		if better {
			best, best_overlaps, best_gap, best_off = h.key, overlaps, gap, off
		}
	}
	if best == 0 {
		return false
	}
	move_focus(u, best, true)
	u.focus_reveal = true
	return true
}

// menu_arrow moves the open menu's highlight to its next or previous item
// in drawing order, which runs down the menu, into and out of a list that
// scrolls inside it. With no item lit it lights the first or the last.
@(private)
menu_arrow :: proc(u: ^State, dir: int) -> bool {
	_, at := find_hit(u, u.focus)
	if at < 0 || !u.hits[at].in_menu {
		at = -1 if dir > 0 else u.hit_count
	}
	for i := at + dir; i >= 0 && i < u.hit_count; i += dir {
		h := u.hits[i]
		if .Focusable in h.flags && h.in_menu {
			move_focus(u, h.key, true)
			u.focus_reveal = true
			return true
		}
	}
	return false
}

// find_hit is key's hit from the last frame and where it is in u.hits,
// -1 for none. Key 0 has none.
@(private)
find_hit :: proc(u: ^State, key: Key) -> (h: Hit, at: int) {
	for hit, i in u.hits[:u.hit_count] {
		if hit.key == key {
			return hit, i
		}
	}
	return {}, -1
}

// hit_at is the clickable box drawn last under pos in the last frame.
hit_at :: proc(u: ^State, pos: [2]f32) -> Key {
	for i := u.hit_count - 1; i >= 0; i -= 1 {
		h := u.hits[i]
		if .Clickable in h.flags && rect_contains(h.rect, pos) {
			return h.key
		}
	}
	return 0
}

// scroll_hit_at is the innermost scroll view under pos that scrolls along
// axis, or box that takes scrolls. An open menu over it takes the scroll
// instead.
@(private)
scroll_hit_at :: proc(u: ^State, pos: [2]f32, axis: Axis) -> Key {
	overflow := Box_Flag.Allow_Overflow_X if axis == .X else .Allow_Overflow_Y
	for i := u.hit_count - 1; i >= 0; i -= 1 {
		h := u.hits[i]
		if !rect_contains(h.rect, pos) {
			continue
		}
		if (.View_Scroll in h.flags && overflow in h.flags) || .Takes_Scroll in h.flags {
			return h.key
		}
		if h.floating && .Clickable in h.flags {
			return 0
		}
	}
	return 0
}

@(private)
takes_scroll :: proc(u: ^State, keys: [2]Key) -> bool {
	for k in keys {
		if h, at := find_hit(u, k); at >= 0 && .Takes_Scroll in h.flags {
			return true
		}
	}
	return false
}

// end_frame lays out and draws the tree. It returns whether anything is
// still animating, which the app passes to the shell.
end_frame :: proc() -> bool {
	u := ctx
	// begin_frame pushed the root, and only it should be left.
	if u.parents.count != 1 || u.parent_misused {
		u.parent_leaks += 1
		if u.parent_leaks == 1 {
			log.error("ui: a frame left a parent pushed, or popped one it didn't push")
		}
	}
	layout(u.root, u.texts, ui_scale(u))
	layout(u.floating_root, u.texts, ui_scale(u))
	fit_floating(u)
	u.hit_count = 0
	u.drag_count = 0
	mismatch := false
	finish(u, u.root, {0, 0, u.width, u.height}, 0, 0, false, false, &mismatch)
	finish(u, u.floating_root, {0, 0, u.width, u.height}, 0, 0, true, false, &mismatch)
	cut_drag_regions(u)
	// A focused box that's no longer focusable, such as a row's button
	// once the row isn't selected, gives the focus to the focusable box
	// it's in, so the keyboard goes on from there.
	if h, at := find_hit(u, u.focus); at >= 0 && .Focusable not_in h.flags && !u.menu_open {
		u.focus = h.focus_parent
		u.focus_visible &&= u.focus != 0
	}
	if u.focus_reveal {
		u.focus_reveal = false
		reveal_focus(u)
	}
	// Hot came from the last frame's rects, so a row that scrolled under a
	// still mouse would be lit a frame late, in the wrong place. An
	// Instant_Hover box has no fade to keep, so it's lit by this frame's.
	hot := hit_at(u, u.input.mouse) if u.input.mouse_inside else 0
	if active := u.active[.Left]; active != 0 && hot != active {
		hot = 0
	}
	if hot != u.hot {
		h, _ := find_hit(u, hot)
		relight(u, u.hot, false)
		relight(u, u.hot_parent, false)
		relight(u, hot, true)
		relight(u, h.click_parent, true)
	}
	// The build used sizes or offsets the layout didn't keep, so what's on
	// screen may be missing rows. One more frame builds it right. The limit
	// stops a layout that never settles from drawing forever once nothing
	// new comes in; begin_frame lifts it on events or a new window size.
	if mismatch && u.settle_frames < MAX_SETTLE_FRAMES {
		u.settle_frames += 1
		u.animating = true
	} else if !mismatch {
		u.settle_frames = 0
	}
	if u.pool_misses > 0 {
		// Log when a run of full frames starts, at most once a second.
		if u.pool_miss_last + 1 != u.frame && u.time - u.pool_logged_at >= 1 {
			log.warnf("ui: box pool full (%d boxes), %d keyed boxes built without state", MAX_BOXES, u.pool_misses)
			u.pool_logged_at = u.time
		}
		u.pool_miss_last = u.frame
	}
	access_build(u)
	draw_box(u, u.root, 1)
	draw_box(u, u.floating_root, 1)
	if u.debug {
		draw_debug(u)
	}
	if u.menu != 0 && !u.menu_built {
		close_menu()
		u.menu = 0
	}
	// Rows moved under a still mouse, or a box appeared that has no rect to
	// test against yet: one more frame settles hot.
	if hot != u.hot && u.active[.Left] == 0 {
		u.animating = true
	}
	return u.animating
}

// relight lights or darkens key's box at once, if it's an Instant_Hover
// box built this frame.
@(private)
relight :: proc(u: ^State, key: Key, on: bool) {
	b := box_lookup(u, key)
	if b == nil || b.last_frame != u.frame || .Instant_Hover not_in b.flags || .Focus_Is_Hot in b.flags {
		return
	}
	b.hot_fade = 1 if on else 0
	b.hot_t = b.hot_fade
}

// show_on_hover draws b at least as opaque as box's hover, as the buttons
// on a list row show while the row is hovered. It goes by box's hot_t when
// b is drawn, so it agrees with the row once end_frame has lit the
// Instant_Hover box under the mouse.
show_on_hover :: proc(b, box: ^Box) {
	b.shown_by = box
}

// drawn_opacity is the opacity b is drawn with: its own, or more with
// show_on_hover.
drawn_opacity :: proc(b: ^Box) -> f32 {
	if b.shown_by != nil {
		return max(b.opacity, b.shown_by.hot_t)
	}
	return b.opacity
}

// fit_floating places the floating boxes that have an anchor by it, and
// moves those and the ones that keep_in_window into the window, now that
// their sizes are known: left of the right edge, and up so their bottom is
// at flip_y when they don't fit below. Placing them while they're built
// would go by last frame's sizes, which a new box doesn't have.
@(private)
fit_floating :: proc(u: ^State) {
	MARGIN :: 8
	for b := u.floating_root.first; b != nil; b = b.next {
		pos := [2]f32{b.rect.x, b.rect.y}
		if a := b.anchor; a != nil {
			pos.x = a.rect.x + (a.rect.w - b.rect.w) / 2
			pos.y = a.rect.y + a.rect.h + TOOLTIP_GAP
			if pos.y + b.rect.h > u.height - MARGIN {
				pos.y = a.rect.y - TOOLTIP_GAP - b.rect.h
			}
		} else if !b.keep_in_window {
			continue
		} else if b.above || pos.y + b.rect.h > u.height - MARGIN {
			pos.y = b.flip_y - b.rect.h
		}
		pos.x = max(min(pos.x, u.width - b.rect.w - MARGIN), MARGIN)
		pos.y = max(pos.y, MARGIN)
		shift_box(b, pos - {b.rect.x, b.rect.y})
	}
}

@(private)
shift_box :: proc(b: ^Box, d: [2]f32) {
	b.rect.x += d.x
	b.rect.y += d.y
	for c := b.first; c != nil; c = c.next {
		shift_box(c, d)
	}
}

// finish records each box's clipped rect and the interactive boxes in
// drawing order for the next frame's input. It clamps scroll offsets to the
// content just laid out, and sets mismatch when a scroll view's children
// were built for an offset or size that the layout didn't keep.
@(private)
finish :: proc(u: ^State, b: ^Box, clip: render.Rect, focus_parent, click_parent: Key, floating, menu_ancestor: bool, mismatch: ^bool) {
	b.clip = rect_intersect(b.rect, clip)
	in_menu := menu_ancestor || (b.key != 0 && b.key == u.menu)
	if .View_Scroll in b.flags && b.key != 0 {
		limit := [2]f32{max(b.view_bounds.x - b.rect.w, 0), max(b.view_bounds.y - b.rect.h, 0)}
		for axis in 0 ..< 2 {
			if b.view_off[axis] > limit[axis] {
				b.view_off[axis] = limit[axis]
				mismatch^ = true
			}
			b.view_off_target[axis] = min(b.view_off_target[axis], limit[axis])
		}
		if b.built_size != {b.rect.w, b.rect.h} {
			mismatch^ = true
		}
		thumb_fit(u, b)
	}
	// A menu closed while it was built takes no input, though its boxes
	// were built to.
	closed := in_menu && !u.menu_open
	b.hit_from = u.hit_count
	tab := 2 * u.hit_count + 1
	if f := b.tab_first; f != nil && f.last_frame == u.frame {
		tab = 2 * f.hit_from
	}
	if b.key != 0 && b.flags & {.Clickable, .Focusable, .View_Scroll, .Takes_Scroll} != {} && .Disabled not_in b.flags && !closed && u.hit_count < len(u.hits) {
		u.hits[u.hit_count] = {
			key          = b.key,
			rect         = b.clip,
			flags        = b.flags,
			group        = seed_key(b.parent),
			focus_parent = focus_parent,
			click_parent = click_parent,
			floating     = floating,
			in_menu      = in_menu,
			tab          = tab,
		}
		u.hit_count += 1
	}
	if .Window_Drag in b.flags {
		if u.drag_count < len(u.drag_rects) {
			u.drag_rects[u.drag_count] = b.clip
			u.drag_from[u.drag_count] = u.hit_count
			u.drag_count += 1
		} else {
			u.drag_dropped = true
		}
	}
	inner := rect_intersect(clip, b.rect) if .Clip in b.flags else clip
	fp := b.key if .Focusable in b.flags && b.key != 0 else focus_parent
	cp := b.key if .Clickable in b.flags && b.key != 0 else click_parent
	for c := b.first; c != nil; c = c.next {
		if c.tab_first == nil {
			c.tab_first = b.tab_first
		}
		finish(u, c, inner, fp, cp, floating, in_menu, mismatch)
	}
}

// thumb_fit sizes and places view's scrollbar thumb for the content just
// laid out. It was built from the last layout's, which is a frame behind
// when rows come or go, as a new row in a list does.
@(private)
thumb_fit :: proc(u: ^State, view: ^Box) {
	bar := box_lookup(u, key_from_string(view.key, "###scrollbar"))
	if bar == nil || bar.last_frame != u.frame || bar.parent != view || bar.first == nil {
		return
	}
	if t, ok := thumb_of(view); ok {
		bar.first.rect.y = bar.rect.y + t.y
		bar.first.rect.h = t.h
	}
}

// reveal_focus scrolls the scroll views around the focused box the least
// it takes to show the box: along each axis, the nearest one that scrolls
// that way. The box must have been built this frame.
@(private)
reveal_focus :: proc(u: ^State) {
	b := box_lookup(u, u.focus)
	if b == nil || b.last_frame != u.frame {
		return
	}
	done: [2]bool
	for v := b.parent; v != nil && done != {true, true}; v = v.parent {
		if .View_Scroll not_in v.flags || v.key == 0 {
			continue
		}
		pos := [2]f32{b.rect.x - v.rect.x, b.rect.y - v.rect.y} + view_offset(v)
		size := [2]f32{b.rect.w, b.rect.h}
		view := [2]f32{v.rect.w, v.rect.h}
		for axis in 0 ..< 2 {
			overflow := Box_Flag.Allow_Overflow_X if axis == 0 else .Allow_Overflow_Y
			if overflow not_in v.flags || done[axis] {
				continue
			}
			done[axis] = true
			t := v.view_off_target[axis]
			if axis == 1 {
				view.y -= v.inset_end
			}
			// A box larger than the view, like a table of rows, keeps the
			// reader's place while any of it shows, and otherwise brings in
			// its nearer end.
			lo, hi := pos[axis], pos[axis] + size[axis]
			if size[axis] > view[axis] && lo < t + view[axis] && hi > t {
				continue
			} else if lo < t {
				t = max(lo, hi - view[axis])
			} else if hi > t + view[axis] {
				t = min(lo, hi - view[axis])
			}
			t = clamp(t, 0, max(v.view_bounds[axis] - view[axis], 0))
			if t != v.view_off_target[axis] {
				v.view_off_target[axis] = t
				u.animating = true
			}
		}
	}
}

// Building

// box_make adds a box under the current parent. A zero width or height
// means the label's size for a text box and the children's sum otherwise.
box_make :: proc(id: string, flags: Box_Flags = {}, width: Size = {}, height: Size = {}) -> ^Box {
	u := ctx
	parent := top_parent()
	label, hashed := split_id(id)
	key := key_of(seed_key(parent), hashed)
	b := box_lookup(u, key)
	if b != nil && b.last_frame == u.frame {
		// Built twice in a frame: the second one lives for this frame only.
		key = 0
		b = nil
	}
	if b != nil {
		b.build = {}
	} else if key != 0 {
		b = box_alloc(u, key)
		if b == nil {
			u.pool_misses += 1
		}
	}
	if b == nil {
		b = temp_box(u)
	}
	b.last_frame = u.frame
	b.flags = flags
	b.id = id
	b.label = label
	b.opacity = 1
	style_take(&u.styles, b)
	is_text := .Draw_Text in b.flags && b.label != ""
	b.pref_size[.X] = width if width.kind != .Null else (text_size() if is_text else children_sum())
	b.pref_size[.Y] = height if height.kind != .Null else (text_size() if is_text else children_sum())
	if parent != nil {
		add_child(parent, b)
	}

	if b.key != 0 {
		hot := u.hot == b.key || u.hot_parent == b.key
		if .Focus_Is_Hot in b.flags {
			hot = menu_highlight(u) == b.key
		}
		ring := u.focus == b.key && u.focus_visible && .No_Focus_Ring not_in b.flags
		b.hot_fade = (1 if hot else 0) if .Instant_Hover in b.flags else step_fade(u, b.hot_fade, hot)
		b.hot_t = math.smoothstep(f32(0), 1, b.hot_fade)
		b.active_t = step_fade(u, b.active_t, u.active[.Left] == b.key)
		b.focus_t = step_fade(u, b.focus_t, ring)
	}
	if .View_Scroll in b.flags && b.key != 0 {
		scroll_box(u, b)
		b.built_size = build_size(b)
	}
	return b
}

// temp_box is a zeroed box that lives until the end of the frame. One
// allocation per TEMP_BOXES boxes costs less than one per box.
@(private)
temp_box :: proc(u: ^State) -> ^Box {
	if len(u.temp_boxes) == 0 {
		u.temp_boxes = make([]Box, TEMP_BOXES, context.temp_allocator)
	}
	b := &u.temp_boxes[0]
	u.temp_boxes = u.temp_boxes[1:]
	return b
}

@(private)
box_alloc :: proc(u: ^State, key: Key) -> ^Box {
	b := u.free
	if b != nil {
		u.free = b.hash_next
	} else if u.boxes_used < len(u.boxes) {
		b = &u.boxes[u.boxes_used]
		u.boxes_used += 1
	} else {
		return nil
	}
	b^ = {}
	b.key = key
	b.first_frame = u.frame
	slot := &u.table[int(u64(key) & (BOX_TABLE - 1))]
	b.hash_next = slot^
	slot^ = b
	u.box_count += 1
	// It has no rect to test input against until it's laid out.
	u.animating = true
	return b
}

// ui_scale is the display's pixels per point, or 0 without a renderer.
ui_scale :: proc(u: ^State) -> f32 {
	return u.renderer.scale if u.renderer != nil else 0
}

// view_offset is how far layout moves view's content: its scroll offset
// on whole pixels. A box that stays put in a scroll view sits at it.
view_offset :: proc(view: ^Box) -> [2]f32 {
	s := ui_scale(ctx)
	return {drawn_off(view, 0, s), drawn_off(view, 1, s)}
}

// step_fade moves t toward 1 if on and toward 0 if not, at a constant speed,
// so a fade that reverses partway takes only as long as the distance back.
@(private)
step_fade :: proc(u: ^State, t: f32, on: bool) -> f32 {
	step := u.dt / FADE_IN if on else -u.dt / FADE_OUT
	next := clamp(t + step, 0, 1)
	if next != (1 if on else 0) {
		u.animating = true
	}
	return next
}

// approach eases v toward target by rate and snaps once it's within eps.
// Anything still moving keeps the frames coming.
approach :: proc(u: ^State, v, target, rate, eps: f32) -> f32 {
	if abs(target - v) <= eps {
		return target
	}
	u.animating = true
	return v + (target - v) * rate
}

// scroll_box applies this frame's scroll to a scroll view. Trackpad deltas
// move the view straight away, momentum included, since the shell supplies
// the inertia: macOS's own, or the Linux shell's. Wheel lines move the
// target and the view eases after it. Both stay within the content from the
// last layout, and a trackpad's scroll past it stretches the view.
@(private)
scroll_box :: proc(u: ^State, b: ^Box) {
	delta: [2]f32
	for axis in 0 ..< 2 {
		if u.scroll_key[axis] == b.key {
			b.view_off_target[axis] -= u.scroll[axis]
			b.view_off[axis] -= u.scroll_precise[axis]
			delta[axis] = -u.scroll_precise[axis]
		}
	}
	size := build_size(b)
	limit := [2]f32{max(b.view_bounds.x - size.x, 0), max(b.view_bounds.y - size.y, 0)}
	rate := 1 - math.exp(-u.dt * 20)
	unused: [2]f32
	for axis in 0 ..< 2 {
		overflow := Box_Flag.Allow_Overflow_X if axis == 0 else .Allow_Overflow_Y
		if overflow not_in b.flags {
			b.view_off_target[axis] = 0
		}
		b.view_off_target[axis] = clamp(b.view_off_target[axis], 0, limit[axis])
		if delta[axis] != 0 {
			unused[axis] = b.view_off[axis] - clamp(b.view_off[axis], 0, limit[axis])
		}
		b.view_off[axis] = clamp(b.view_off[axis], 0, limit[axis])
	}
	stretch_view(u, b, unused, limit)
	for axis in 0 ..< 2 {
		b.view_off[axis] = approach(u, b.view_off[axis], b.view_off_target[axis], rate, 0.25)
	}
}

// build_size is b's size as its build can know it: on each axis, its own
// size in points if it has one, or else its size in the last layout. A
// scroll view given its size in points builds the right rows from its
// first frame and right after a resize.
build_size :: proc(b: ^Box) -> [2]f32 {
	size := [2]f32{b.rect.w, b.rect.h}
	for axis in Axis {
		if b.pref_size[axis].kind == .Pixels {
			size[int(axis)] = b.pref_size[axis].value
		}
	}
	return size
}

signal :: proc(b: ^Box) -> (s: Signal) {
	u := ctx
	s.box = b
	k := b.key
	if k == 0 || .Disabled in b.flags {
		return
	}
	s.hovering = u.hot == k || u.hot_parent == k
	s.held = u.active[.Left] == k
	s.pressed = u.pressed[.Left] == k
	s.released = u.released[.Left] == k
	s.clicked = u.clicked[.Left] == k || u.key_click == k
	s.keyboard = u.key_click == k
	s.double_clicked = u.double_clicked == k
	s.right_clicked = u.pressed[.Right] == k
	if s.held {
		s.mouse = u.input.mouse
		s.drag_delta = s.mouse - u.drag_start
		s.dragging = u.drag_moved
	} else if s.released {
		s.mouse = u.input.release_pos[.Left]
		s.drag_delta = s.mouse - u.drag_start
		s.dragging = u.drag_moved
	}
	for axis in 0 ..< 2 {
		if u.scroll_key[axis] == k {
			s.scroll[axis] = u.scroll[axis]
			s.scroll_precise[axis] = u.scroll_precise[axis]
		}
	}
	return
}

// Parents and scopes

push_parent :: proc(b: ^Box) {push(&ctx.parents, b)}

pop_parent :: proc() {
	ctx.parent_misused ||= ctx.parents.count == 0
	pop(&ctx.parents)
}

top_parent :: proc() -> ^Box {
	u := ctx
	if u.parents.count == 0 {
		return nil
	}
	return u.parents.items[min(u.parents.count, STACK_DEPTH) - 1]
}

@(private)
pop_parent_box :: proc(_: ^Box) {
	pop_parent()
}

// parent makes b the parent of the boxes built until the end of the scope.
@(deferred_none = pop_parent)
parent :: proc(b: ^Box) {
	push_parent(b)
}

// row is a box laying its children out left to right, parent until the
// end of the scope.
@(deferred_out = pop_parent_box)
row :: proc(id: string = "", flags: Box_Flags = {}, width: Size = {}, height: Size = {}) -> ^Box {
	b := box_make(id, flags, width, height)
	b.child_axis = .X
	push_parent(b)
	return b
}

// column lays its children out top to bottom.
@(deferred_out = pop_parent_box)
column :: proc(id: string = "", flags: Box_Flags = {}, width: Size = {}, height: Size = {}) -> ^Box {
	b := box_make(id, flags, width, height)
	b.child_axis = .Y
	push_parent(b)
	return b
}

// Queries for the app

// take_key removes one press of code with exactly these modifiers from this
// frame's unused keys and reports whether there was one. The first caller
// gets it. With repeats false, a held key counts only when it goes down.
take_key :: proc(code: platform.Key, modifiers: platform.Modifiers = {}, repeats := true) -> bool {
	u := ctx
	for i in 0 ..< u.key_count {
		k := u.keys[i]
		if k.code == code && k.modifiers == modifiers && (repeats || !k.repeat) {
			u.keys[i] = u.keys[u.key_count - 1]
			u.key_count -= 1
			return true
		}
	}
	return false
}

// slider_keys takes the keys that move slider b while it has the focus:
// steps is how many steps Right and Up moved it up, less Left and Down,
// and home and end say Home or End sent it to its lowest or highest. Give
// b Arrow_Keys and Focusable, so the arrows reach it.
slider_keys :: proc(b: ^Box) -> (steps: int, home, end: bool) {
	if !has_focus(b) {
		return
	}
	for take_key(.Right) || take_key(.Up) {
		steps += 1
	}
	for take_key(.Left) || take_key(.Down) {
		steps -= 1
	}
	home = take_key(.Home)
	end = take_key(.End)
	return
}

// tab_first makes Tab reach b and the boxes inside it before the boxes
// inside within, one of b's ancestors, wherever b is drawn among them: a
// box drawn over a view so it stays on top, such as a toolbar, still comes
// first in Tab order.
tab_first :: proc(b, within: ^Box) {
	b.tab_first = within
}

// take_button reports whether Back or Forward on the mouse went down this
// frame, and keeps the press from any later caller.
take_button :: proc(button: platform.Mouse_Button) -> bool {
	u := ctx
	if button in u.nav_buttons {
		u.nav_buttons -= {button}
		return true
	}
	return false
}

// find is the keyed box id under the current parent, as the last frame left
// it, or nil before it's built for the first time.
find :: proc(id: string) -> ^Box {
	return box_lookup(ctx, key_from_string(seed_key(top_parent()), id))
}

// text_focused says whether a text field has the focus. It gets the keys
// it uses, and they still wait for ui.take_key, so app-wide shortcuts
// check this first.
text_focused :: proc() -> bool {
	return focus_takes_text(ctx)
}

// focus_key is the key with the focus, and whether the keyboard put it
// there, showing its ring, for something that takes the focus for a while,
// such as a text field opened in place, to give it back with
// restore_focus.
focus_key :: proc() -> (key: Key, ring: bool) {
	return ctx.focus, ctx.focus_visible
}

// restore_focus gives the focus to key, with its ring when ring is set,
// and scrolls it into view.
restore_focus :: proc(key: Key, ring: bool) {
	u := ctx
	move_focus(u, key, ring && key != 0)
	u.focus_reveal = ring
	u.animating = true
}

has_focus :: proc(b: ^Box) -> bool {
	return b.key != 0 && ctx.focus == b.key
}

focus_visible :: proc() -> bool {
	return ctx.focus_visible
}

set_focus :: proc(b: ^Box) {
	ctx.focus = b.key
}

mouse :: proc() -> [2]f32 {
	return ctx.input.mouse
}

// mouse_over tests the mouse against b's rect from the last layout,
// whatever is active.
mouse_over :: proc(b: ^Box) -> bool {
	u := ctx
	return u.input.mouse_inside && rect_contains(b.clip, u.input.mouse)
}

// mouse_on says whether the mouse is over b's rect from the last layout
// with nothing clickable under it and no button held on anything, for a
// box that shows the hover and takes no clicks.
mouse_on :: proc(b: ^Box) -> bool {
	u := ctx
	return u.hot == 0 && u.active[.Left] == 0 && mouse_over(b)
}

// Drag and drop. A source calls drag_begin with a payload once its signal
// says dragging. The drag then belongs to the UI: any left release ends it,
// over a target or not, and Escape cancels it, whether or not the source is
// still built. A target asks drop_hover while the drag goes on and dropped
// in the frame it ends.

drag_begin :: proc(payload: u64) {
	u := ctx
	if u.drag_cancelled {
		return
	}
	if u.drag_unclaimed {
		// The drag went past the threshold and ended within this frame, and
		// targets built before the source have already asked. Drop it in the
		// next frame, against the rects it was released over.
		u.drag_unclaimed = false
		u.drop_next = true
		u.drop_payload = payload
		u.drop_pos = u.input.release_pos[.Left]
		u.animating = true
		return
	}
	if .Left not_in u.input.buttons {
		return
	}
	u.drag_active = true
	u.drag_payload = payload
}

drag_payload :: proc() -> (payload: u64, ok: bool) {
	return ctx.drag_payload, ctx.drag_active
}

// drop_hover reports a drag going on with the mouse over b.
drop_hover :: proc(b: ^Box) -> bool {
	return ctx.drag_active && mouse_over(b)
}

// dropped returns the payload of a drag that ended over b this frame.
dropped :: proc(b: ^Box) -> (payload: u64, ok: bool) {
	u := ctx
	if !u.drop || !rect_contains(b.clip, u.drop_pos) {
		return
	}
	return u.drop_payload, true
}

// pool_stats is how many keyed boxes are alive and how many this frame got
// no state because the pool was full.
pool_stats :: proc(u: ^State) -> (used, capacity, misses: int) {
	return u.box_count, MAX_BOXES, u.pool_misses
}

// request_frame asks for another frame, for app animations.
request_frame :: proc() {
	ctx.animating = true
}

// wake_at asks for a frame at time t without keeping frames coming until
// then, as a caret's blink or a debounce does.
wake_at :: proc(t: f64) {
	u := ctx
	if u.wake == 0 || t < u.wake {
		u.wake = t
	}
}

// wake_after is how long from now the frame wake_at asked for is, for
// Frame_Result.wake_after, or 0 for none.
wake_after :: proc(u: ^State) -> f32 {
	if u.wake == 0 {
		return 0
	}
	return max(f32(u.wake - u.time), 0.001)
}

// set_window_key tells the UI whether the window has the keyboard. Carets
// only blink in the key window.
set_window_key :: proc(u: ^State, key: bool) {
	u.window_inactive = !key
}

// set_clipboard gives the UI the shell's clipboard for this frame.
set_clipboard :: proc(u: ^State, get: proc "c" (buffer: [^]u8, capacity: uint) -> uint, set: proc "c" (text: [^]u8, length: uint)) {
	u.clipboard_get = get
	u.clipboard_set = set
}

// copy_to_clipboard puts s on the shell's clipboard.
copy_to_clipboard :: proc(s: string) {
	u := ctx
	if u.clipboard_set != nil {
		u.clipboard_set(raw_data(s), uint(len(s)))
	}
}

// text_input returns the focused text field's state, and whether the shell
// needs it: it differs from what was last returned, or a field took text
// or marked text from the shell this frame. text is nil when no field has
// the focus.
text_input :: proc(u: ^State) -> (input: platform.Text_Input, changed: bool) {
	if u.text_claimed {
		input = u.text_input
	}
	h := hash.fnv64a(transmute([]byte)string(input.text[:input.length])) if input.text != nil else 0
	fields := [7]u64{u64(input.selection_start), u64(input.selection_end), u64(u32(input.marked_start)), u64(u32(input.marked_end)), u64(input.text != nil) | u64(input.limit) << 1, u64(transmute(u32)input.caret[0]) << 32 | u64(transmute(u32)input.caret[1]), u64(transmute(u32)input.caret[2]) << 32 | u64(transmute(u32)input.caret[3])}
	for f in fields {
		h = (h ~ f) * 1099511628211
	}
	changed = h != u.text_sent || u.text_resend
	u.text_sent = h
	u.text_resend = false
	return
}

// cut_drag_regions takes what's drawn over a Window_Drag box out of its
// rect where it takes clicks, so a button, a link or a scrollbar under the
// titlebar gets its press instead of the window moving. The topmost
// clickable box at each point decides, so a row hidden under a pinned bar
// doesn't count. A Click_Shield, clickable only to stop presses reaching
// what's under it, leaves its part of the rect moving the window. Past
// len(drag_rects) pieces the rest is dropped, which only makes less of the
// rect a drag region, and the first frame that drops any logs it.
@(private)
cut_drag_regions :: proc(u: ^State) {
	out: [len(u.drag_rects)]render.Rect
	n_out := 0
	for i in 0 ..< u.drag_count {
		// The pieces of the rect that no box above them has decided.
		open: [32]render.Rect
		open[0] = u.drag_rects[i]
		n := 1
		#reverse for h in u.hits[u.drag_from[i]:u.hit_count] {
			if .Clickable not_in h.flags {
				continue
			}
			for j := 0; j < n; {
				r := open[j]
				o := rect_intersect(r, h.rect)
				if o.w <= 0 || o.h <= 0 {
					j += 1
					continue
				}
				// r gives way to what's outside h: the bands above and
				// below it, and beside it within its height.
				rest := [4]render.Rect {
					{r.x, r.y, r.w, o.y - r.y},
					{r.x, o.y + o.h, r.w, r.y + r.h - (o.y + o.h)},
					{r.x, o.y, o.x - r.x, o.h},
					{o.x + o.w, o.y, r.x + r.w - (o.x + o.w), o.h},
				}
				open[j] = open[n - 1]
				n -= 1
				for p in rest {
					if p.w > 0 && p.h > 0 {
						if n < len(open) {
							open[n] = p
							n += 1
						} else {
							u.drag_dropped = true
						}
					}
				}
				if .Click_Shield in h.flags {
					if n_out < len(out) {
						out[n_out] = o
						n_out += 1
					} else {
						u.drag_dropped = true
					}
				}
			}
		}
		for p in open[:n] {
			if n_out < len(out) {
				out[n_out] = p
				n_out += 1
			} else {
				u.drag_dropped = true
			}
		}
	}
	u.drag_rects = out
	u.drag_count = n_out
	if u.drag_dropped {
		u.drag_drops += 1
		if u.drag_drops == 1 {
			log.warnf("ui: more than %d drag region pieces, the rest don't move the window", len(u.drag_rects))
		}
	}
	u.drag_dropped = false
}

// drag_regions is where a press moves the window, for the shell, valid
// after end_frame until the next begin_frame.
drag_regions :: proc(u: ^State) -> []render.Rect {
	return u.drag_rects[:u.drag_count]
}

// access_tree is this frame's accessibility tree and a hash of it, valid
// after end_frame until the next begin_frame.
access_tree :: proc(u: ^State) -> (nodes: []platform.Access_Node, h: u64) {
	return u.access_nodes, u.access_hash
}

// accessible puts b in the accessibility tree as role, read as label. The
// strings must live until end_frame.
accessible :: proc(b: ^Box, role: platform.Access_Role, label: string, value := "", selected := false) {
	b.access_role = role
	b.access_label = label
	b.access_value = value
	b.access_selected = selected
}

// data_changed asks for another frame after data the tree is built from
// changed outside the frame's events, such as a worker's result. A layout
// that hadn't settled gets its MAX_SETTLE_FRAMES again.
data_changed :: proc() {
	ctx.settle_frames = 0
	ctx.animating = true
}

// Rects

rect_contains :: proc(r: render.Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
}

rect_intersect :: proc(a, b: render.Rect) -> render.Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}
