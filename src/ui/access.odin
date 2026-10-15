package ui

import "core:hash"
import "core:strings"

import "../platform"

// access_build flattens the boxes that have an access role into this
// frame's accessibility tree, parents first. Only what is on screen goes
// in: a box clipped away, or a box under a clipping box clipped away, is
// left out with everything inside it, so a virtualized table gives only the
// rows in view. A box without a key gets an id from its parent's and its
// place among its siblings, which stays put while the tree does.
@(private)
access_build :: proc(u: ^State) {
	nodes := make([dynamic]platform.Access_Node, 0, 128, context.temp_allocator)
	h: u64 = 14695981039346656037
	top: u64
	access_walk(u, u.root, -1, 0, &top, &nodes, &h)
	access_walk(u, u.floating_root, -1, 0, &top, &nodes, &h)
	u.access_nodes = nodes[:]
	u.access_hash = h
}

// siblings counts the nodes made so far under parent.
@(private)
access_walk :: proc(u: ^State, b: ^Box, parent: i32, parent_id: u64, siblings: ^u64, nodes: ^[dynamic]platform.Access_Node, h: ^u64) {
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
			label  = strings.clone_to_cstring(label, context.temp_allocator) if label != "" else nil,
			value  = strings.clone_to_cstring(b.access_value, context.temp_allocator) if b.access_value != "" else nil,
		}
		append(nodes, node)
		fields := [6]u64{id, u64(u32(parent)), u64(node.role) << 32 | u64(transmute(u32)flags), u64(transmute(u32)node.frame[0]) << 32 | u64(transmute(u32)node.frame[1]), u64(transmute(u32)node.frame[2]) << 32 | u64(transmute(u32)node.frame[3]), u64(len(label)) << 32 | u64(len(b.access_value))}
		for f in fields {
			h^ = (h^ ~ f) * 1099511628211
		}
		h^ = hash.fnv64a(transmute([]byte)label, h^)
		h^ = hash.fnv64a(transmute([]byte)b.access_value, h^)
		parent = i32(len(nodes) - 1)
		parent_id = id
		siblings = &children
	}
	for c := b.first; c != nil; c = c.next {
		access_walk(u, c, parent, parent_id, siblings, nodes, h)
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
