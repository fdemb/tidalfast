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

import "core:hash"
import "core:math"
import "core:strings"

import "../platform"
import "../render"
import "../text"

MAX_BOXES :: 8192
BOX_TABLE :: 4096 // buckets, a power of two
MAX_KEY_PRESSES :: 32
STACK_DEPTH :: 64
TOOLTIP_DELAY :: 0.5 // seconds of hovering before a tooltip shows
DRAG_THRESHOLD :: 4 // points the mouse moves before a press becomes a drag

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
	dragging:       bool, // pressed on the box and moved past DRAG_THRESHOLD
	drag_delta:     [2]f32, // mouse movement since the press
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
}

Key_Press :: struct {
	code:      u32,
	modifiers: platform.Modifiers,
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
	scroll_latch:   Key, // the scroll view a trackpad gesture started over
	scroll_key:     Key, // this frame's scroll goes to this box
	scroll:         [2]f32, // points, this frame
	scroll_precise: [2]f32, // the part of scroll from trackpads, applied without easing
	focus:          Key,
	focus_visible:  bool, // the focus came from the keyboard, so draw a ring
	key_click:      Key, // Enter or Space this frame
	keys:           [MAX_KEY_PRESSES]Key_Press, // presses the UI didn't use
	key_count:      int,

	menu:           Key, // the open or closing context menu, 0 if none
	menu_open:      bool,
	menu_pos:       [2]f32,
	menu_built:     bool,
	tooltip_owner:  Key,

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
// end_frame.
begin_frame :: proc(u: ^State, events: []platform.Event, r: ^render.Renderer, t: ^text.State, width, height: f32, time: f64) {
	ctx = u
	u.frame += 1
	u.dt = f32(clamp(time - u.time, 0, 1.0 / 30))
	u.time = time
	u.width = width
	u.height = height
	u.renderer = r
	u.texts = t
	u.animating = false
	u.menu_built = false
	prune(u)
	process_events(u, events)

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
}

@(private)
process_events :: proc(u: ^State, events: []platform.Event) {
	input_begin_frame(&u.input)
	u.pressed = {}
	u.released = {}
	u.clicked = {}
	u.double_clicked = 0
	u.key_click = 0
	u.key_count = 0
	u.scroll = {}
	u.scroll_precise = {}
	u.scroll_key = 0

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
			}
			u.active[e.button] = 0
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
		if e.click_count >= 2 {
			u.double_clicked = hover
		}
	}
	// The press moves the focus to what was clicked, or its nearest
	// focusable ancestor, or nowhere.
	u.focus = 0
	u.focus_visible = false
	for h in u.hits[:u.hit_count] {
		if h.key == hover {
			u.focus = h.key if .Focusable in h.flags else h.focus_parent
			break
		}
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
	case code == KEY_TAB && mods - {.Shift} == {}:
		focus_step(u, -1 if .Shift in mods else 1)
		return
	case code == KEY_ESCAPE && mods == {}:
		if u.menu != 0 && u.menu_open {
			close_menu()
			return
		}
		if u.focus != 0 {
			u.focus = 0
			return
		}
	case (code == KEY_RETURN || code == KEY_SPACE) && mods == {} && u.focus != 0:
		u.key_click = u.focus
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
	start := at if at >= 0 else (n if dir > 0 else -1)
	for step in 1 ..= n {
		i := ((start + dir * step) % n + n) % n
		h := u.hits[i]
		if .Focusable in h.flags && (u.menu == 0 || !u.menu_open || h.floating) {
			u.focus = h.key
			u.focus_visible = true
			return
		}
	}
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
			u.focus = h.key
			u.focus_visible = true
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
	finish(u, u.root, {0, 0, u.width, u.height}, 0, 0, false)
	finish(u, u.floating_root, {0, 0, u.width, u.height}, 0, 0, true)
	draw_box(u, u.root, 1)
	draw_box(u, u.floating_root, 1)
	if u.debug {
		draw_debug(u)
	}
	if u.menu != 0 && !u.menu_built {
		u.menu = 0
		u.menu_open = false
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
// drawing order for the next frame's input.
@(private)
finish :: proc(u: ^State, b: ^Box, clip: render.Rect, focus_parent, click_parent: Key, floating: bool) {
	b.clip = rect_intersect(b.rect, clip)
	if b.key != 0 && b.flags & {.Clickable, .Focusable, .View_Scroll} != {} && .Disabled not_in b.flags && u.hit_count < len(u.hits) {
		u.hits[u.hit_count] = {
			key          = b.key,
			rect         = b.clip,
			flags        = b.flags,
			group        = seed_key(b.parent),
			focus_parent = focus_parent,
			click_parent = click_parent,
			floating     = floating,
		}
		u.hit_count += 1
	}
	inner := rect_intersect(clip, b.rect) if .Clip in b.flags else clip
	fp := b.key if .Focusable in b.flags && b.key != 0 else focus_parent
	cp := b.key if .Clickable in b.flags && b.key != 0 else click_parent
	for c := b.first; c != nil; c = c.next {
		finish(u, c, inner, fp, cp, floating)
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
	if u.active[.Left] == k {
		s.drag_delta = u.input.mouse - u.drag_start
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

// request_frame asks for another frame, for app animations.
request_frame :: proc() {
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
