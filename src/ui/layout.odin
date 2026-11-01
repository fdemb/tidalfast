// Layout solves five passes for each axis, after Fleury:
//
// 1. Standalone: Pixels and Text sizes, which need nothing else.
// 2. Upwards-dependent: Parent_Pct, from the nearest ancestor that has a
//    size of its own (Pixels, Text or Parent_Pct). Children_Sum ancestors
//    are skipped, since their size isn't known yet.
// 3. Downwards-dependent: Children_Sum, after the children.
// 4. Violations: a parent's size is final by the time its children are
//    solved, so percentages of it are taken again from that size. Then
//    children that don't fit their parent shrink. Along the child axis each child gives up its size times (1 - strictness), in
//    proportion, until the overflow is gone or nothing is left to give.
//    A box with Shrink_From_End takes the room from its last children
//    instead, so the child crossing its edge is cut and the rest get none.
//    Across it, a child larger than its parent is cut to the parent's size.
//    Boxes that allow overflow (scroll views) skip this on that axis.
//    A box's gutter and pad come off its size before its children get any.
// 5. Positions: children are placed one after another along the child axis,
//    shifted by the parent's view_off, and the parent's view_bounds is set
//    to the size of its content. With Center_Children they move in by half
//    the room they leave, where two fill() spacers around them would put
//    them, without the two boxes.
//
// The axes don't depend on each other, and each pass only reads what the
// ones before it wrote for the box, its ancestors or its children, so two
// walks over the tree do all ten: sizes does 1 and 2 on the way down and 3
// on the way up, and place does 4 and 5 for a box's children before going
// into them.
package ui

import "core:math"

import "../text"

// layout lays out the tree under root. With texts it first shapes the
// labels of boxes sized by their text, so it knows their sizes. Other
// labels are shaped when drawn, if they're on screen.
layout :: proc(root: ^Box, texts: ^text.State = nil) {
	sizes(root, texts)
	root.rect = {root.fixed_pos.x, root.fixed_pos.y, root.fixed_size.x, root.fixed_size.y}
	place(root)
}

@(private)
sizes :: proc(b: ^Box, texts: ^text.State) {
	if texts != nil && b.label != "" && (b.pref_size[.X].kind == .Text || b.pref_size[.Y].kind == .Text) {
		b.run = text.shape(texts, b.font, b.font_size, b.label)
		b.text_size = {b.run.width + 2 * b.text_pad, b.run.ascent + b.run.descent}
	}
	for axis in Axis {
		size_standalone(b, axis)
		size_upwards(b, axis)
	}
	for c := b.first; c != nil; c = c.next {
		sizes(c, texts)
	}
	for axis in Axis {
		size_downwards(b, axis)
	}
}

@(private)
place :: proc(b: ^Box) {
	if b.first == nil {
		// What position would work out for a box without children.
		b.view_bounds = {2 * b.pad.x, 2 * b.pad.y + b.inset_end}
		return
	}
	for axis in Axis {
		solve_violations(b, axis)
		position(b, axis)
	}
	for c := b.first; c != nil; c = c.next {
		place(c)
	}
}

@(private)
floating_on :: proc(b: ^Box, axis: Axis) -> bool {
	return (.Floating_X if axis == .X else .Floating_Y) in b.flags
}

@(private)
overflow_on :: proc(b: ^Box, axis: Axis) -> bool {
	return (.Allow_Overflow_X if axis == .X else .Allow_Overflow_Y) in b.flags
}

// content_size is the room b has for its children, less its gutter and pad.
@(private)
content_size :: proc(b: ^Box, axis: Axis) -> f32 {
	gutter := b.gutter if axis == .X else 0
	return max(b.fixed_size[axis] - gutter - 2 * b.pad[axis], 0)
}

@(private)
size_standalone :: proc(b: ^Box, axis: Axis) {
	size := b.pref_size[axis]
	#partial switch size.kind {
	case .Pixels:
		b.fixed_size[axis] = size.value
	case .Text:
		b.fixed_size[axis] = size.value + b.text_size[axis]
	}
}

@(private)
size_upwards :: proc(b: ^Box, axis: Axis) {
	size := b.pref_size[axis]
	if size.kind == .Parent_Pct {
		known: f32
		for p := b.parent; p != nil; p = p.parent {
			#partial switch p.pref_size[axis].kind {
			case .Pixels, .Text, .Parent_Pct:
				known = content_size(p, axis)
			case:
				continue
			}
			break
		}
		b.fixed_size[axis] = known * size.value
	}
}

@(private)
size_downwards :: proc(b: ^Box, axis: Axis) {
	if b.pref_size[axis].kind == .Children_Sum {
		sum: f32
		for c := b.first; c != nil; c = c.next {
			if floating_on(c, axis) {
				continue
			}
			if axis == b.child_axis {
				sum += c.fixed_size[axis]
			} else {
				sum = max(sum, c.fixed_size[axis])
			}
		}
		b.fixed_size[axis] = sum + 2 * b.pad[axis]
	}
}

// solve_violations fits b's children into it along axis.
@(private)
solve_violations :: proc(b: ^Box, axis: Axis) {
	allowed := content_size(b, axis)
	// Pass 2 took them from the size before b's parent shrank it. A fill
	// inside a shrunk fill would otherwise keep the outer one's first size,
	// and a strict percentage of it would overflow. A scroll view's
	// percentages are of the view, not of the content.
	if kind := b.pref_size[axis].kind; overflow_on(b, axis) || (kind != .Children_Sum && kind != .Null) {
		for c := b.first; c != nil; c = c.next {
			if c.pref_size[axis].kind == .Parent_Pct {
				c.fixed_size[axis] = allowed * c.pref_size[axis].value
			}
		}
	}
	if overflow_on(b, axis) {
		return
	}
	if axis != b.child_axis {
		for c := b.first; c != nil; c = c.next {
			if !floating_on(c, axis) {
				c.fixed_size[axis] = min(c.fixed_size[axis], allowed)
			}
		}
	} else if .Shrink_From_End in b.flags {
		left := allowed
		for c := b.first; c != nil; c = c.next {
			if !floating_on(c, axis) {
				c.fixed_size[axis] = min(c.fixed_size[axis], left)
				left -= c.fixed_size[axis]
			}
		}
	} else {
		total, giveable: f32
		for c := b.first; c != nil; c = c.next {
			if !floating_on(c, axis) {
				total += c.fixed_size[axis]
				giveable += c.fixed_size[axis] * (1 - c.pref_size[axis].strictness)
			}
		}
		violation := total - allowed
		if violation > 0 && giveable > 0 {
			take := clamp(violation / giveable, 0, 1)
			for c := b.first; c != nil; c = c.next {
				if !floating_on(c, axis) {
					c.fixed_size[axis] -= c.fixed_size[axis] * (1 - c.pref_size[axis].strictness) * take
				}
			}
		}
	}
}

// position places b's children along axis and sets b's view_bounds.
@(private)
position :: proc(b: ^Box, axis: Axis) {
	at := b.pad[axis]
	if .Center_Children in b.flags && axis == b.child_axis {
		used: f32
		for c := b.first; c != nil; c = c.next {
			if !floating_on(c, axis) {
				used += c.fixed_size[axis]
			}
		}
		at += max(content_size(b, axis) - used, 0) / 2
	}
	bounds: f32
	origin := b.rect.x if axis == .X else b.rect.y
	for c := b.first; c != nil; c = c.next {
		if !floating_on(c, axis) {
			c.fixed_pos[axis] = at
			if axis == b.child_axis {
				at += c.fixed_size[axis]
				bounds += c.fixed_size[axis]
			} else {
				bounds = max(bounds, c.fixed_size[axis])
			}
		}
		p := origin + c.fixed_pos[axis] - b.view_off[axis]
		if axis == .X {
			c.rect.x = p
			c.rect.w = c.fixed_size.x
		} else {
			c.rect.y = p
			c.rect.h = c.fixed_size.y
		}
	}
	bounds += 2 * b.pad[axis]
	if axis == .Y {
		bounds += b.inset_end
	}
	b.view_bounds[axis] = bounds
}

// add_child links c under parent, for building trees by hand.
add_child :: proc(parent, c: ^Box) {
	c.parent = parent
	if parent.last != nil {
		parent.last.next = c
	} else {
		parent.first = c
	}
	parent.last = c
	parent.child_count += 1
}

// virtual_range is the rows of height row_h that a view of height view_h
// scrolled down by offset shows, as [first, last).
virtual_range :: proc(offset, view_h, row_h: f32, count: int) -> (first, last: int) {
	if count <= 0 || row_h <= 0 || view_h <= 0 {
		return 0, 0
	}
	first = clamp(int(math.floor(offset / row_h)), 0, count)
	last = clamp(int(math.ceil((offset + view_h) / row_h)), first, count)
	return
}
