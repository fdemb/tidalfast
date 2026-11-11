package ui

import "core:hash"

import "../platform"
import "../render"

ACCESS_TEXT :: 4096 // bytes of labels and values taken from the frame's memory at a time

@(private)
Access_Walk :: struct {
	nodes:   [dynamic]platform.Access_Node,
	h:       u64,
	text:    []u8, // the rest of the chunk the strings are copied into
	shields: [dynamic]^Box, // the Click_Shield boxes on screen, in drawing order
	passed:  int, // how many of shields the walk has reached
}

// access_build flattens the boxes that have an access role into this
// frame's accessibility tree, parents first. Only what is on screen goes
// in: a box clipped away, or a box under a clipping box clipped away, is
// left out with everything inside it, so a virtualized table gives only the
// rows in view. A Click_Shield drawn over a box, such as the player bar
// over the list's last rows, takes its part of the box's frame, and a box
// it hides entirely is left out. A box without a key gets an id from its
// parent's and its place among its siblings, which stays put while the
// tree does.
@(private)
access_build :: proc(u: ^State) {
	w := Access_Walk {
		nodes   = make([dynamic]platform.Access_Node, 0, 128, context.temp_allocator),
		h       = 14695981039346656037,
		shields = make([dynamic]^Box, 0, 8, context.temp_allocator),
	}
	access_shields(&w, u.root)
	access_shields(&w, u.floating_root)
	top: u64
	access_walk(u, &w, u.root, -1, 0, &top)
	access_walk(u, &w, u.floating_root, -1, 0, &top)
	u.access_nodes = w.nodes[:]
	u.access_hash = w.h
}

// access_cstring copies s with a NUL after it into the walk's chunk, which
// costs less than an allocation for each.
@(private)
access_cstring :: proc(w: ^Access_Walk, s: string) -> cstring {
	if s == "" {
		return nil
	}
	if len(w.text) <= len(s) {
		w.text = make([]u8, max(ACCESS_TEXT, len(s) + 1), context.temp_allocator)
	}
	copy(w.text, s)
	w.text[len(s)] = 0
	c := cstring(raw_data(w.text))
	w.text = w.text[len(s) + 1:]
	return c
}

// access_skips says whether the walk leaves out b and everything inside it.
@(private)
access_skips :: proc(b: ^Box) -> bool {
	return drawn_opacity(b) <= 0 || (.Clip in b.flags && (b.clip.w <= 0 || b.clip.h <= 0))
}

// access_shields collects the shields in the order access_walk reaches them.
@(private)
access_shields :: proc(w: ^Access_Walk, b: ^Box) {
	if access_skips(b) {
		return
	}
	if .Click_Shield in b.flags && b.clip.w > 0 && b.clip.h > 0 {
		append(&w.shields, b)
	}
	for c := b.first; c != nil; c = c.next {
		access_shields(w, c)
	}
}

// access_uncovered is the part of r that the shields drawn after b leave
// in view. A shield across r's whole width or height cuts r to the side
// that sticks out; one over r's middle leaves r whole, since what's left
// isn't a rect.
@(private)
access_uncovered :: proc(w: ^Access_Walk, b: ^Box, r: render.Rect) -> render.Rect {
	r := r
	shields: for shield in w.shields[w.passed:] {
		for p := shield.parent; p != nil; p = p.parent {
			if p == b {
				continue shields
			}
		}
		o := rect_intersect(r, shield.clip)
		if o.w <= 0 || o.h <= 0 {
			continue
		}
		above, below := o.y - r.y, r.y + r.h - (o.y + o.h)
		left, right := o.x - r.x, r.x + r.w - (o.x + o.w)
		if left < 0.5 && right < 0.5 {
			if below < 0.5 {
				r.h = max(above, 0)
			} else if above < 0.5 {
				r = {r.x, o.y + o.h, r.w, below}
			}
		} else if above < 0.5 && below < 0.5 {
			if right < 0.5 {
				r.w = max(left, 0)
			} else if left < 0.5 {
				r = {o.x + o.w, r.y, right, r.h}
			}
		}
	}
	return r
}

// siblings counts the nodes made so far under parent.
@(private)
access_walk :: proc(u: ^State, w: ^Access_Walk, b: ^Box, parent: i32, parent_id: u64, siblings: ^u64) {
	if access_skips(b) {
		return
	}
	if w.passed < len(w.shields) && w.shields[w.passed] == b {
		w.passed += 1
	}
	frame := b.clip
	if b.access_role != .None && frame.w > 0 && frame.h > 0 {
		frame = access_uncovered(w, b, frame)
	}
	parent, parent_id, siblings := parent, parent_id, siblings
	children: u64
	if b.access_role != .None && frame.w > 0 && frame.h > 0 {
		siblings^ += 1
		id := u64(b.key)
		if id == 0 {
			id = mix_id(parent_id ~ siblings^ * 0x9e3779b97f4a7c15 ~ u64(b.access_role) << 56)
		}
		flags: platform.Access_Flags
		if b.key != 0 && b.key == u.focus {
			flags += {.Focused}
		}
		if b.access_selected {
			flags += {.Selected}
		}
		if .Disabled in b.flags {
			flags += {.Disabled}
		}
		label := b.access_label
		node := platform.Access_Node {
			id     = id,
			parent = parent,
			role   = b.access_role,
			flags  = flags,
			frame  = {frame.x, frame.y, frame.w, frame.h},
			label  = access_cstring(w, label),
			value  = access_cstring(w, b.access_value),
		}
		append(&w.nodes, node)
		fields := [6]u64{id, u64(u32(parent)), u64(node.role) << 32 | u64(transmute(u32)flags), u64(transmute(u32)node.frame[0]) << 32 | u64(transmute(u32)node.frame[1]), u64(transmute(u32)node.frame[2]) << 32 | u64(transmute(u32)node.frame[3]), u64(len(label)) << 32 | u64(len(b.access_value))}
		for f in fields {
			w.h = (w.h ~ f) * 1099511628211
		}
		w.h = hash.fnv64a(transmute([]byte)label, w.h)
		w.h = hash.fnv64a(transmute([]byte)b.access_value, w.h)
		parent = i32(len(w.nodes) - 1)
		parent_id = id
		siblings = &children
	}
	for c := b.first; c != nil; c = c.next {
		access_walk(u, w, c, parent, parent_id, siblings)
	}
}

@(private)
mix_id :: proc(x: u64) -> u64 {
	z := x + 0x9e3779b97f4a7c15
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	z ~= z >> 31
	return z if z != 0 else 1
}
