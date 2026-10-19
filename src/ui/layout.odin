// Layout runs five passes over the tree for each axis, after Fleury:
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
//    Across it, a child larger than its parent is cut to the parent's size.
//    Boxes that allow overflow (scroll views) skip this on that axis.
//    A box's gutter comes off its width before its children get any.
// 5. Positions: children are placed one after another along the child axis,
//    shifted by the parent's view_off, and the parent's view_bounds is set
//    to the size of its content.
package ui

import "core:math"

layout :: proc(root: ^Box) {
	for axis in Axis {
		layout_axis(root, axis)
	}
}

layout_axis :: proc(root: ^Box, axis: Axis) {
	sizes_standalone(root, axis)
	sizes_upwards(root, axis)
	sizes_downwards(root, axis)
	solve_violations(root, axis)
	if axis == .X {
		root.rect.x = root.fixed_pos.x
		root.rect.w = root.fixed_size.x
	} else {
		root.rect.y = root.fixed_pos.y
		root.rect.h = root.fixed_size.y
	}
	position(root, axis)
}

@(private)
floating_on :: proc(b: ^Box, axis: Axis) -> bool {
	return (.Floating_X if axis == .X else .Floating_Y) in b.flags
}

@(private)
overflow_on :: proc(b: ^Box, axis: Axis) -> bool {
	return (.Allow_Overflow_X if axis == .X else .Allow_Overflow_Y) in b.flags
}

// content_size is the room b has for its children, less its gutter.
@(private)
content_size :: proc(b: ^Box, axis: Axis) -> f32 {
	return max(b.fixed_size[axis] - b.gutter, 0) if axis == .X else b.fixed_size[axis]
}

sizes_standalone :: proc(b: ^Box, axis: Axis) {
	size := b.pref_size[axis]
	#partial switch size.kind {
	case .Pixels:
		b.fixed_size[axis] = size.value
	case .Text:
		b.fixed_size[axis] = size.value + b.text_size[axis]
	}
	for c := b.first; c != nil; c = c.next {
		sizes_standalone(c, axis)
	}
}

sizes_upwards :: proc(b: ^Box, axis: Axis) {
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
	for c := b.first; c != nil; c = c.next {
		sizes_upwards(c, axis)
	}
}

sizes_downwards :: proc(b: ^Box, axis: Axis) {
	for c := b.first; c != nil; c = c.next {
		sizes_downwards(c, axis)
	}
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
		b.fixed_size[axis] = sum
	}
}

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
	if !overflow_on(b, axis) {
		if axis != b.child_axis {
			for c := b.first; c != nil; c = c.next {
				if !floating_on(c, axis) {
					c.fixed_size[axis] = min(c.fixed_size[axis], allowed)
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
	for c := b.first; c != nil; c = c.next {
		solve_violations(c, axis)
	}
}

position :: proc(b: ^Box, axis: Axis) {
	at, bounds: f32
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
	if axis == .Y {
		bounds += b.inset_end
	}
	b.view_bounds[axis] = bounds
	for c := b.first; c != nil; c = c.next {
		position(c, axis)
	}
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
