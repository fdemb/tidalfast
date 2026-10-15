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
// All of State is plain data: no procedure pointers, no allocators. The
// per-frame pointers (renderer, text, the build tree) are set again by
// begin_frame, so State survives a hot reload.
package ui

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"

import "../platform"
import "../render"
import "../text"

MAX_BOXES :: 8192
BOX_TABLE :: 4096 // buckets, a power of two
MAX_KEY_PRESSES :: 32
MAX_EDIT_EVENTS :: 64
MAX_SHORTCUTS :: 8
STACK_DEPTH :: 64
TOOLTIP_DELAY :: 0.5 // seconds of hovering before a tooltip shows
DRAG_THRESHOLD :: 4 // points the mouse moves before a press becomes a drag
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
	Focusable, // Tab stops here, Enter and Space click it
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
	Text_Input, // a text field: with the focus it takes Return, Space, the arrows and Escape
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
	built_size:      [2]f32, // the rect size a scroll view's children were built for
	hot_t:           f32,
	active_t:        f32,
	focus_t:         f32,
	open_t:          f32, // menus and tooltips fading in

	using build:     Build,
}

// Build is what a box is given each frame. box_make clears it.
Build :: struct {
	parent, first, last, next: ^Box,
	child_count:               int,
	flags:                     Box_Flags,
	pref_size:                 [Axis]Size,
	child_axis:                Axis,
	fixed_pos:                 [2]f32, // relative to the parent
	fixed_size:                [2]f32,
	id:                        string, // as given; must live until end_frame
	label:                     string, // the part of id before "##"
	font:                      text.Font,
	font_size:                 f32,
	text_color:                render.Color,
	text_align:                Align,
	text_pad:                  f32, // left and right of the label
	background:                render.Color,
	gradient:                  render.Color, // bottom colour of the background, when its alpha isn't 0
	border_color:              render.Color,
	hover_color:               render.Color,
	active_color:              render.Color,
	radius:                    f32,
	texture:                   render.Texture, // drawn over the background, rounded by radius
	opacity:                   f32, // multiplies the box and everything inside it
	run:                       ^text.Run,
	text_size:                 [2]f32, // the label's size with padding, measured in end_frame
	// What assistive apps see: a role puts the box in the accessibility
	// tree. The strings must live until end_frame.
	access_role:               platform.Access_Role,
	access_label:              string,
	access_value:              string,
	access_selected:           bool,
}

Signal :: struct {
	box:            ^Box,
	hovering:       bool, // hot, or the parent of the hot box
	held:           bool, // left button went down on the box and is still down
	pressed:        bool, // left button went down on the box this frame
	released:       bool, // left button came up after being pressed on the box
	clicked:        bool, // released over the box, or Enter or Space while focused
	keyboard:       bool, // clicked came from a key
	double_clicked: bool,
	right_clicked:  bool, // right or control-click went down on the box
	dragging:       bool, // pressed on the box and moved past DRAG_THRESHOLD, until the release
	drag_delta:     [2]f32, // mouse movement since the press, up to the release if released
	mouse:          [2]f32, // while held the mouse, when released where the button came up
	scroll:         [2]f32, // points scrolled over the box this frame
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
}

Key_Press :: struct {
	code:      u32,
	modifiers: platform.Modifiers,
}

// Edit_Event is a key press the UI didn't use, text from the shell, or a
// text field getting or losing the focus, in the order they came. target is
// the box that had the focus when it came, or the one that got or lost it.
Edit_Event :: struct {
	op:                     Edit_Op,
	target:                 Key,
	select_all:             bool, // .Focus: select the field's text, as for Cmd-F
	key:                    Key_Press,
	text:                   string, // this frame's
	replace:                bool,
	replace_lo, replace_hi: int,
	select_lo, select_hi:   int,
}

Edit_Op :: enum u8 {
	Key,
	Text,
	Marked_Text,
	Unmark_Text,
	Focus,
	Blur,
}

// Shortcut is a key that gives a text field the focus, from focus_shortcut.
Shortcut :: struct {
	key:    Key_Press,
	target: Key,
}

Stack :: struct($T: typeid) {
	items: [STACK_DEPTH]T,
	count: int,
}

State :: struct {
	boxes:          []Box, // the pool keyed boxes come from
	boxes_used:     int,
	free:           ^Box,
	table:          []^Box,
	box_count:      int,
	hits:           []Hit,
	hit_count:      int,

	frame:          u64,
	time:           f64,
	dt:             f32,
	width, height:  f32,
	renderer:       ^render.Renderer, // this frame's
	texts:          ^text.State,
	root:           ^Box,
	floating_root:  ^Box,
	parents:        Stack(^Box),
	font:           text.Font,
	font_size:      f32,
	text_color:     render.Color,

	input:          Input,
	hot:            Key,
	hot_parent:     Key, // the hot box's clickable parent, which counts as hovered
	hot_since:      f64,
	active:         [platform.Mouse_Button]Key,
	pressed:        [platform.Mouse_Button]Key, // this frame
	released:       [platform.Mouse_Button]Key,
	clicked:        [platform.Mouse_Button]Key,
	double_clicked: Key,
	drag_start:     [2]f32,
	drag_moved:     bool, // past DRAG_THRESHOLD since the press
	control_click:  bool, // the left button is down as a control-click
	buttons_stale:  Mouse_Buttons, // held here but up in hardware last frame
	scroll_latch:   Key, // the scroll view a trackpad gesture started over
	scroll_key:     Key, // this frame's scroll goes to this box
	scroll:         [2]f32, // points, this frame
	scroll_precise: [2]f32, // the part of scroll from trackpads, applied without easing
	focus:          Key,
	focus_visible:  bool, // the focus came from the keyboard, so draw a ring
	focus_reveal:   bool, // the keyboard moved the focus: scroll it into view
	key_click:      Key, // Enter or Space this frame
	keys:           [MAX_KEY_PRESSES]Key_Press, // presses the UI didn't use
	key_count:      int,
	edits:          [MAX_EDIT_EVENTS]Edit_Event,
	edit_count:     int,
	// Last frame's focus_shortcut calls, which this frame's keys go by.
	shortcuts:      [MAX_SHORTCUTS]Shortcut,
	shortcut_count: int,
	click_count:    u32, // of the last left press: 2 for a double-click, 3 for a triple
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
	menu_built:     bool,
	menu_focus_new: bool, // the first menu item built takes the focus
	menu_saved:     Key, // the focus before the menu opened, restored when it closes
	menu_saved_vis: bool,
	tooltip_owner:  Key,

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
	u.font = .Regular
	u.font_size = 13
	u.text_color = {1, 1, 1, 1}
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
	if id == "" {
		return 0
	}
	part := id
	if i := strings.index(id, "###"); i >= 0 {
		part = id[i:]
	}
	h := hash.fnv64a(transmute([]byte)part) if seed == 0 else hash.fnv64a(transmute([]byte)part, u64(seed))
	return Key(h if h != 0 else 1)
}

label_from_string :: proc(id: string) -> string {
	if i := strings.index(id, "##"); i >= 0 {
		return id[:i]
	}
	return id
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
// end_frame. hardware is the buttons down right now, from hardware_buttons;
// without it the UI goes by the events alone.
// text is the bytes Text and Marked_Text events point into.
begin_frame :: proc(u: ^State, events: []platform.Event, r: ^render.Renderer, t: ^text.State, width, height: f32, time: f64, hardware: Maybe(Mouse_Buttons) = nil, text_bytes: []u8 = nil) {
	ctx = u
	u.frame += 1
	if width != u.width || height != u.height || len(events) > 0 {
		u.settle_frames = 0
	}
	u.dt = f32(clamp(time - u.time, 0, 1.0 / 30))
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
	prune(u)
	if held, ok := hardware.?; ok {
		release_stale(u, events, held)
	}
	process_events(u, events, text_bytes)
	u.shortcut_count = 0

	u.parents.count = 0
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
// interaction state that points at them.
@(private)
prune :: proc(u: ^State) {
	for &bucket in u.table {
		link := &bucket
		for link^ != nil {
			b := link^
			if b.last_frame + 1 >= u.frame {
				link = &b.hash_next
				continue
			}
			link^ = b.hash_next
			b^ = {}
			b.hash_next = u.free
			u.free = b
			u.box_count -= 1
		}
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
}

// release_stale cancels buttons held since an earlier frame that the
// hardware says are up, as when the release went to another app. A button
// must look like that for two frames in a row, since its release may be on
// its way. Cancelled buttons don't release or click anything, and a drag
// they held ends without a drop.
@(private)
release_stale :: proc(u: ^State, events: []platform.Event, hardware: Mouse_Buttons) {
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

// cancel_pointer lets go of every button without a release, for a hot
// reload, which may have missed one.
cancel_pointer :: proc(u: ^State) {
	cancel_buttons(u, u.input.buttons)
	u.buttons_stale = {}
}

@(private)
cancel_buttons :: proc(u: ^State, buttons: Mouse_Buttons) {
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
	u.edit_count = 0
	u.scroll = {}
	u.scroll_precise = {}
	u.scroll_key = 0
	u.drop = u.drop_next
	u.drop_next = false
	u.drag_unclaimed = false

	for event in events {
		e := event
		// A control-click is a right click on macOS. Its mouse up still says
		// left, so remember it for the release.
		if e.kind == .Mouse_Down && e.button == .Left && .Control in e.modifiers {
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
			mouse_pressed(u, e)
		case .Mouse_Up:
			hover := hit_at(u, u.input.mouse)
			if k := u.active[e.button]; k != 0 {
				u.released[e.button] = k
				if hover == k {
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
			if u.active[.Left] != 0 && !u.drag_moved {
				d := u.input.mouse - u.drag_start
				u.drag_moved = d.x * d.x + d.y * d.y >= DRAG_THRESHOLD * DRAG_THRESHOLD
			}
		case .Scroll:
			// A trackpad gesture and its momentum keep scrolling the view it
			// started over. A mouse wheel goes wherever the mouse is.
			if e.phase == .Began || e.phase == .May_Begin || (e.phase == .None && e.momentum_phase == .None) || u.scroll_latch == 0 {
				u.scroll_latch = scroll_hit_at(u, u.input.mouse)
			}
			u.scroll_key = u.scroll_latch
			d := scroll_delta(e)
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
			for h in u.hits[:u.hit_count] {
				if h.key == Key(e.target) && .Focusable in h.flags {
					move_focus(u, h.key, true)
					u.focus_reveal = true
				}
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
	}
	u.hot_parent = 0
	for h in u.hits[:u.hit_count] {
		if hot != 0 && h.key == hot {
			u.hot_parent = h.click_parent
			break
		}
	}
}

@(private)
mouse_pressed :: proc(u: ^State, e: platform.Event) {
	pos := u.input.mouse
	if u.menu != 0 && u.menu_open {
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
		u.click_count = e.click_count
	}
	// The press moves the focus to what was clicked, or its nearest
	// focusable ancestor, or nowhere.
	focus := Key(0)
	for h in u.hits[:u.hit_count] {
		if h.key == hover {
			focus = h.key if .Focusable in h.flags else h.focus_parent
			break
		}
	}
	move_focus(u, focus, false)
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
	mods := e.modifiers & {.Shift, .Control, .Option, .Command}
	code := e.key_code
	switch {
	case !e.repeat && (code == KEY_F1 || (code == KEY_D && mods == {.Command, .Shift})):
		u.debug = !u.debug
		return
	case shortcut_for(u, {code, mods}) != 0:
		target := shortcut_for(u, {code, mods})
		if u.menu != 0 && u.menu_open {
			close_menu()
		}
		move_focus(u, target, false, select_all = true)
		u.animating = true
		return
	case code == KEY_TAB && mods - {.Shift} == {}:
		focus_step(u, -1 if .Shift in mods else 1)
		return
	case focus_takes_text(u) && (code == KEY_ESCAPE || code == KEY_RETURN || code == KEY_SPACE || code == KEY_UP || code == KEY_DOWN):
		// The text field has these.
	case code == KEY_ESCAPE && mods == {}:
		if u.drag_active {
			u.drag_active = false
			u.drag_cancelled = true
			return
		}
		if u.menu != 0 && u.menu_open {
			close_menu()
			return
		}
		if u.focus != 0 {
			move_focus(u, 0, false)
			return
		}
	case (code == KEY_RETURN || code == KEY_SPACE) && mods == {} && u.focus != 0:
		// With a menu open, only its items take keys.
		if !menu_blocks(u, u.focus) {
			u.key_click = u.focus
		}
		return
	case (code == KEY_UP || code == KEY_DOWN) && mods == {}:
		if focus_arrow(u, -1 if code == KEY_UP else 1) {
			return
		}
	}
	if u.key_count < MAX_KEY_PRESSES {
		u.keys[u.key_count] = {code, mods}
		u.key_count += 1
	}
	queue_edit(u, {op = .Key, target = u.focus, key = {code, mods}})
}

@(private)
shortcut_for :: proc(u: ^State, k: Key_Press) -> Key {
	for sc in u.shortcuts[:u.shortcut_count] {
		if sc.key == k {
			return sc.target
		}
	}
	return 0
}

// focus_takes_text says whether the focused box is a text field.
@(private)
focus_takes_text :: proc(u: ^State) -> bool {
	return takes_text(u, u.focus)
}

@(private)
takes_text :: proc(u: ^State, key: Key) -> bool {
	if key == 0 {
		return false
	}
	for h in u.hits[:u.hit_count] {
		if h.key == key {
			return .Text_Input in h.flags
		}
	}
	return false
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
// drawing order, wrapping around.
@(private)
focus_step :: proc(u: ^State, dir: int) {
	n := u.hit_count
	if n == 0 {
		return
	}
	at := -1
	for h, i in u.hits[:n] {
		if h.key == u.focus {
			at = i
			break
		}
	}
	start := at if at >= 0 else (-1 if dir > 0 else n)
	for step in 1 ..= n {
		i := ((start + dir * step) % n + n) % n
		h := u.hits[i]
		if .Focusable in h.flags && (!u.menu_open || h.in_menu) {
			move_focus(u, h.key, true)
			u.focus_reveal = true
			return
		}
	}
}

// menu_blocks reports whether an open menu keeps the keyboard from key.
@(private)
menu_blocks :: proc(u: ^State, key: Key) -> bool {
	if u.menu == 0 || !u.menu_open {
		return false
	}
	for h in u.hits[:u.hit_count] {
		if h.key == key {
			return !h.in_menu
		}
	}
	return true
}

// focus_arrow moves the focus to the previous or next focusable box with
// the same keyed parent. In an open menu it moves among the menu's items.
@(private)
focus_arrow :: proc(u: ^State, dir: int) -> bool {
	group := Key(0)
	at := -1
	for h, i in u.hits[:u.hit_count] {
		if h.key == u.focus && .Focusable in h.flags {
			group = h.group
			at = i
			break
		}
	}
	if u.menu != 0 && u.menu_open {
		if at < 0 || group != u.menu {
			at = -1 if dir > 0 else u.hit_count
			group = u.menu
		}
	}
	if group == 0 {
		return false
	}
	for i := at + dir; i >= 0 && i < u.hit_count; i += dir {
		h := u.hits[i]
		if .Focusable in h.flags && h.group == group {
			move_focus(u, h.key, true)
			u.focus_reveal = true
			return true
		}
	}
	return false
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

// scroll_hit_at is the innermost scroll view under pos. An open menu over
// it takes the scroll instead.
@(private)
scroll_hit_at :: proc(u: ^State, pos: [2]f32) -> Key {
	for i := u.hit_count - 1; i >= 0; i -= 1 {
		h := u.hits[i]
		if !rect_contains(h.rect, pos) {
			continue
		}
		if .View_Scroll in h.flags {
			return h.key
		}
		if h.floating && .Clickable in h.flags {
			return 0
		}
	}
	return 0
}

// end_frame lays out and draws the tree. It returns whether anything is
// still animating, which the app passes to the shell.
end_frame :: proc() -> bool {
	u := ctx
	measure(u, u.root)
	measure(u, u.floating_root)
	layout(u.root)
	layout(u.floating_root)
	u.hit_count = 0
	mismatch := false
	finish(u, u.root, {0, 0, u.width, u.height}, 0, 0, false, false, &mismatch)
	finish(u, u.floating_root, {0, 0, u.width, u.height}, 0, 0, true, false, &mismatch)
	if u.focus_reveal {
		u.focus_reveal = false
		reveal_focus(u)
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
			fmt.eprintfln("ui: box pool full (%d boxes), %d keyed boxes built without state", MAX_BOXES, u.pool_misses)
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
	hot := hit_at(u, u.input.mouse) if u.input.mouse_inside else 0
	if hot != u.hot && u.active[.Left] == 0 {
		u.animating = true
	}
	return u.animating
}

// measure shapes the labels of boxes sized by their text, so layout knows
// their sizes. Other labels are shaped when drawn, if they're on screen.
@(private)
measure :: proc(u: ^State, b: ^Box) {
	if b.label != "" && (b.pref_size[.X].kind == .Text || b.pref_size[.Y].kind == .Text) && u.texts != nil {
		b.run = text.shape(u.texts, b.font, b.font_size, b.label)
		b.text_size = {b.run.width + 2 * b.text_pad, b.run.ascent + b.run.descent}
	}
	for c := b.first; c != nil; c = c.next {
		measure(u, c)
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
	}
	// A menu closed while it was built takes no input, though its boxes
	// were built to.
	closed := in_menu && !u.menu_open
	if b.key != 0 && b.flags & {.Clickable, .Focusable, .View_Scroll} != {} && .Disabled not_in b.flags && !closed && u.hit_count < len(u.hits) {
		u.hits[u.hit_count] = {
			key          = b.key,
			rect         = b.clip,
			flags        = b.flags,
			group        = seed_key(b.parent),
			focus_parent = focus_parent,
			click_parent = click_parent,
			floating     = floating,
			in_menu      = in_menu,
		}
		u.hit_count += 1
	}
	inner := rect_intersect(clip, b.rect) if .Clip in b.flags else clip
	fp := b.key if .Focusable in b.flags && b.key != 0 else focus_parent
	cp := b.key if .Clickable in b.flags && b.key != 0 else click_parent
	for c := b.first; c != nil; c = c.next {
		finish(u, c, inner, fp, cp, floating, in_menu, mismatch)
	}
}

// reveal_focus scrolls the nearest scroll view around the focused box the
// least it takes to show the box. The box must have been built this frame.
@(private)
reveal_focus :: proc(u: ^State) {
	b := box_lookup(u, u.focus)
	if b == nil || b.last_frame != u.frame {
		return
	}
	for v := b.parent; v != nil; v = v.parent {
		if .View_Scroll not_in v.flags || v.key == 0 {
			continue
		}
		pos := [2]f32{b.rect.x - v.rect.x, b.rect.y - v.rect.y} + v.view_off
		size := [2]f32{b.rect.w, b.rect.h}
		view := [2]f32{v.rect.w, v.rect.h}
		for axis in 0 ..< 2 {
			overflow := Box_Flag.Allow_Overflow_X if axis == 0 else .Allow_Overflow_Y
			if overflow not_in v.flags {
				continue
			}
			t := v.view_off_target[axis]
			if pos[axis] < t {
				t = pos[axis]
			} else if pos[axis] + size[axis] > t + view[axis] {
				t = pos[axis] + size[axis] - view[axis]
			}
			t = clamp(t, 0, max(v.view_bounds[axis] - view[axis], 0))
			if t != v.view_off_target[axis] {
				v.view_off_target[axis] = t
				u.animating = true
			}
		}
		return
	}
}

// Building

// box_make adds a box under the current parent. A zero width or height
// means the label's size for a text box and the children's sum otherwise.
box_make :: proc(id: string, flags: Box_Flags = {}, width: Size = {}, height: Size = {}) -> ^Box {
	u := ctx
	parent := top_parent()
	key := key_from_string(seed_key(parent), id)
	b := box_lookup(u, key)
	if b != nil && b.last_frame == u.frame {
		// Built twice in a frame: the second one lives for this frame only.
		key = 0
		b = nil
	}
	if key != 0 && b == nil {
		b = box_alloc(u, key)
		if b == nil {
			u.pool_misses += 1
		}
	}
	if b == nil {
		b = new(Box, context.temp_allocator)
	}
	b.build = {}
	b.last_frame = u.frame
	b.flags = flags
	b.id = id
	b.label = label_from_string(id)
	b.font = u.font
	b.font_size = u.font_size
	b.text_color = u.text_color
	b.hover_color = {1, 1, 1, 0.06}
	b.active_color = {1, 1, 1, 0.06}
	b.opacity = 1
	is_text := .Draw_Text in flags && b.label != ""
	b.pref_size[.X] = width if width.kind != .Null else (text_size() if is_text else children_sum())
	b.pref_size[.Y] = height if height.kind != .Null else (text_size() if is_text else children_sum())
	if parent != nil {
		add_child(parent, b)
	}

	if b.key != 0 {
		rate := 1 - math.exp(-u.dt * 18)
		b.hot_t = approach(u, b.hot_t, 1 if u.hot == b.key || u.hot_parent == b.key else 0, rate, 0.002)
		b.active_t = approach(u, b.active_t, 1 if u.active[.Left] == b.key else 0, rate, 0.002)
		b.focus_t = approach(u, b.focus_t, 1 if u.focus == b.key && u.focus_visible else 0, rate, 0.002)
	}
	if .View_Scroll in flags && b.key != 0 {
		scroll_box(u, b)
		b.built_size = {b.rect.w, b.rect.h}
	}
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
// move the view straight away, momentum included, since macOS already
// supplies the inertia. Wheel lines move the target and the view eases
// after it. Both stay within the content from the last layout.
@(private)
scroll_box :: proc(u: ^State, b: ^Box) {
	if u.scroll_key == b.key {
		b.view_off_target -= u.scroll
		b.view_off -= u.scroll_precise
	}
	limit := [2]f32{max(b.view_bounds.x - b.rect.w, 0), max(b.view_bounds.y - b.rect.h, 0)}
	rate := 1 - math.exp(-u.dt * 20)
	for axis in 0 ..< 2 {
		overflow := Box_Flag.Allow_Overflow_X if axis == 0 else .Allow_Overflow_Y
		if overflow not_in b.flags {
			b.view_off_target[axis] = 0
		}
		b.view_off_target[axis] = clamp(b.view_off_target[axis], 0, limit[axis])
		b.view_off[axis] = clamp(b.view_off[axis], 0, limit[axis])
		b.view_off[axis] = approach(u, b.view_off[axis], b.view_off_target[axis], rate, 0.25)
	}
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
	if u.scroll_key == k {
		s.scroll = u.scroll
	}
	return
}

// Parents and scopes

push_parent :: proc(b: ^Box) {
	u := ctx
	if u.parents.count < STACK_DEPTH {
		u.parents.items[u.parents.count] = b
	}
	u.parents.count += 1
}

pop_parent :: proc() {
	u := ctx
	if u.parents.count > 0 {
		u.parents.count -= 1
	}
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

Text_Style :: struct {
	font:  text.Font,
	size:  f32,
	color: render.Color,
}

@(private)
restore_text_style :: proc(old: Text_Style) {
	u := ctx
	u.font, u.font_size, u.text_color = old.font, old.size, old.color
}

// text_style sets the font, size and colour of boxes built until the end
// of the scope.
@(deferred_out = restore_text_style)
text_style :: proc(font: text.Font, size: f32, color: render.Color) -> Text_Style {
	u := ctx
	old := Text_Style{u.font, u.font_size, u.text_color}
	u.font, u.font_size, u.text_color = font, size, color
	return old
}

// Queries for the app

// key_pressed reports and uses up a key press the UI didn't take.
key_pressed :: proc(code: u32, modifiers: platform.Modifiers = {}) -> bool {
	u := ctx
	for i in 0 ..< u.key_count {
		k := u.keys[i]
		if k.code == code && k.modifiers == modifiers {
			u.keys[i] = u.keys[u.key_count - 1]
			u.key_count -= 1
			return true
		}
	}
	return false
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
