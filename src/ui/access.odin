package ui

import "core:hash"

import "../platform"

ACCESS_TEXT :: 4096 // bytes of labels and values taken from the frame's memory at a time

@(private)
Access_Walk :: struct {
	nodes: [dynamic]platform.Access_Node,
	h:     u64,
	text:  []u8, // the rest of the chunk the strings are copied into
}

// access_build flattens the boxes that have an access role into this
// frame's accessibility tree, parents first. Only what is on screen goes
// in: a box clipped away, or a box under a clipping box clipped away, is
// left out with everything inside it, so a virtualized table gives only the
// rows in view. A box without a key gets an id from its parent's and its
// place among its siblings, which stays put while the tree does.
@(private)
access_build :: proc(u: ^State) {
	w := Access_Walk {
		nodes = make([dynamic]platform.Access_Node, 0, 128, context.temp_allocator),
		h     = 14695981039346656037,
	}
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

// siblings counts the nodes made so far under parent.
@(private)
access_walk :: proc(u: ^State, w: ^Access_Walk, b: ^Box, parent: i32, parent_id: u64, siblings: ^u64) {
	if b.opacity <= 0 {
		return
	}
	visible := b.clip.w > 0 && b.clip.h > 0
	if !visible && .Clip in b.flags {
		return
	}
	parent, parent_id, siblings := parent, parent_id, siblings
	children: u64
	if b.access_role != .None && visible {
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
			frame  = {b.clip.x, b.clip.y, b.clip.w, b.clip.h},
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
