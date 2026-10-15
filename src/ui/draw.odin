package ui

import "core:fmt"

import "../render"
import "../text"

ACCENT :: render.Color{0, 1, 1, 1}

@(private)
fade :: proc(c: render.Color, a: f32) -> render.Color {
	return {c.r, c.g, c.b, c.a * a}
}

// draw_box draws b and its children in order: shadow, background, texture,
// hot and active overlays, border, focus ring, label, then the children
// inside b's clip if it has one. A box clipped away entirely draws nothing
// itself, but its children may lie outside it.
@(private)
draw_box :: proc(u: ^State, b: ^Box, alpha: f32) {
	r := u.renderer
	a := alpha * b.opacity
	if r == nil || a <= 0 {
		return
	}
	if b.clip.w <= 0 || b.clip.h <= 0 {
		if .Clip not_in b.flags {
			for c := b.first; c != nil; c = c.next {
				draw_box(u, c, a)
			}
		}
		return
	}
	rect := b.rect
	if .Draw_Shadow in b.flags {
		render.push_shadow(r, rect, b.radius, 24, {0, 8}, 0, {0, 0, 0, 0.5 * a})
	}
	if .Draw_Background in b.flags {
		if b.gradient.a > 0 {
			render.push_gradient(r, rect, fade(b.background, a), fade(b.gradient, a), false, b.radius)
		} else if b.background.a > 0 {
			render.push_rect(r, rect, fade(b.background, a), b.radius)
		}
	}
	if b.texture != 0 {
		render.push_image(r, rect, b.texture, b.texture_src, tint = {1, 1, 1, a}, radius = b.radius)
	}
	if .Draw_Hot_Effects in b.flags && b.hot_t > 0 {
		render.push_rect(r, rect, fade(b.hover_color, a * b.hot_t), b.radius)
	}
	if .Draw_Active_Effects in b.flags && b.active_t > 0 {
		render.push_rect(r, rect, fade(b.active_color, a * b.active_t), b.radius)
	}
	if .Draw_Border in b.flags && b.border_color.a > 0 {
		render.push_rect(r, rect, fade(b.border_color, a), b.radius, 1)
	}
	if b.focus_t > 0 {
		render.push_rect(r, rect, fade(ACCENT, a * b.focus_t), b.radius, 2)
	}
	if .Draw_Text in b.flags && b.label != "" && u.texts != nil {
		draw_label(u, b, a)
	}
	if .Clip in b.flags {
		render.push_clip(r, rect)
	}
	for c := b.first; c != nil; c = c.next {
		draw_box(u, c, a)
	}
	if .Clip in b.flags {
		render.pop_clip(r)
	}
}

// draw_label centres the label vertically and truncates it with an
// ellipsis to the box's width less its padding.
@(private)
draw_label :: proc(u: ^State, b: ^Box, a: f32) {
	if b.run == nil {
		b.run = text.shape(u.texts, b.font, b.font_size, b.label)
	}
	run := b.run
	avail := b.rect.w - 2 * b.text_pad
	if avail <= 0 {
		return
	}
	w := min(run.width, avail)
	x := b.rect.x + b.text_pad
	switch b.text_align {
	case .Left:
	case .Center:
		x = b.rect.x + (b.rect.w - w) / 2
	case .Right:
		x = b.rect.x + b.rect.w - b.text_pad - w
	}
	y := b.rect.y + (b.rect.h - (run.ascent + run.descent)) / 2
	text.draw_run(u.texts, u.renderer, run, {x, y}, fade(b.text_color, a), avail)
}

// draw_debug outlines every box, and for the innermost box under the mouse
// fills it and shows its key, ID and size.
@(private)
draw_debug :: proc(u: ^State) {
	r := u.renderer
	if r == nil {
		return
	}
	hovered: ^Box
	outline :: proc(u: ^State, b: ^Box, depth: int, hovered: ^^Box) {
		colors := [4]render.Color{{1, 0.3, 0.3, 0.7}, {0.3, 0.8, 1, 0.7}, {1, 0.8, 0.2, 0.7}, {0.6, 1, 0.4, 0.7}}
		render.push_rect(u.renderer, b.rect, colors[depth % 4], 0, 1)
		if b.parent != nil && u.input.mouse_inside && rect_contains(b.clip, u.input.mouse) {
			hovered^ = b
		}
		for c := b.first; c != nil; c = c.next {
			outline(u, c, depth + 1, hovered)
		}
	}
	outline(u, u.root, 0, &hovered)
	outline(u, u.floating_root, 0, &hovered)
	if hovered == nil {
		return
	}
	render.push_rect(r, hovered.rect, {1, 0.3, 0.8, 0.18})
	render.push_rect(r, hovered.rect, {1, 0.3, 0.8, 1}, 0, 1)
	info := fmt.tprintf("%016x  %q  %.0fx%.0f", u64(hovered.key), hovered.id, hovered.rect.w, hovered.rect.h)
	if hovered.key == 0 {
		info = fmt.tprintf("no key  %q  %.0fx%.0f", hovered.id, hovered.rect.w, hovered.rect.h)
	}
	m := text.measure(u.texts, .Medium, 11, info)
	p := u.input.mouse + {14, 16}
	p.x = min(p.x, u.width - m.width - 16)
	p.y = min(p.y, u.height - m.height - 12)
	render.push_rect(r, {p.x - 6, p.y - 4, m.width + 12, m.height + 8}, {0.05, 0.05, 0.06, 0.95}, 4)
	text.draw(u.texts, r, .Medium, 11, p, {1, 1, 1, 1}, info)
}
