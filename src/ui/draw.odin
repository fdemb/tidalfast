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
// rim, hot and active overlays, border, focus ring, label, then the children
// inside b's clip if it has one. A box clipped away entirely draws nothing
// itself, but its children may lie outside it. A tilted box draws its
// background or texture and its rim as one, see render.push_tilt. Without
// a renderer it draws nothing but still finds the cut label under the
// mouse, see note_cut.
@(private)
draw_box :: proc(u: ^State, b: ^Box, alpha: f32) {
	r := u.renderer
	a := alpha * drawn_opacity(b)
	if a <= 0 {
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
	if r != nil {
		draw_fill(u, b, a)
	}
	if u.cut_found && b != u.tooltip_box && covers(b) && rect_contains(b.clip, u.input.mouse) {
		u.cut_found = false
	}
	if .Draw_Text in b.flags && b.label != "" && u.texts != nil {
		draw_label(u, b, a)
	}
	owner, row := u.cut_owner, u.cut_row
	if b.full_text != "" {
		u.cut_owner = b
	}
	if .Instant_Hover in b.flags || b.tip_around {
		u.cut_row = b
	}
	if .Clip in b.flags && r != nil {
		render.push_clip(r, b.rect)
	}
	for c := b.first; c != nil; c = c.next {
		draw_box(u, c, a)
	}
	if .Clip in b.flags && r != nil {
		render.pop_clip(r)
	}
	u.cut_owner, u.cut_row = owner, row
}

// draw_fill draws what's under b's label: shadow, background, texture, rim,
// hot and active overlays, border and focus ring.
@(private)
draw_fill :: proc(u: ^State, b: ^Box, a: f32) {
	r := u.renderer
	rect := b.rect
	tilt := b.tilt
	tilt.pointer = u.input.mouse
	tilted := render.TILT && tilt.amount > 0
	if .Draw_Shadow in b.flags {
		sh := b.shadow if b.shadow != {} else SHADOW_DEFAULT
		render.push_shadow(r, rect, b.radius, sh.blur, {0, sh.y}, 0, {0, 0, 0, sh.alpha * a})
	}
	if .Draw_Backdrop in b.flags {
		render.push_backdrop(r, rect, b.backdrop.blur, b.backdrop.saturation, fade(b.background, a), b.radius)
	} else if .Draw_Glass in b.flags {
		draw_glass(u, b, a)
	} else if .Draw_Background in b.flags {
		if tilted && b.texture == 0 {
			top := fade(b.background, a)
			render.push_tilt(r, rect, top, fade(b.gradient, a) if b.gradient.a > 0 else top, b.radius, tilt, b.rim)
		} else if b.gradient.a > 0 {
			render.push_gradient(r, rect, fade(b.background, a), fade(b.gradient, a), false, b.radius)
		} else if b.background.a > 0 {
			render.push_rect(r, rect, fade(b.background, a), b.radius)
		}
	}
	if b.texture != 0 && tilted {
		render.push_tilt(r, rect, {1, 1, 1, a}, {1, 1, 1, a}, b.radius, tilt, b.rim, b.texture, b.texture_src)
	} else if b.texture != 0 {
		render.push_image(r, rect, b.texture, b.texture_src, tint = {1, 1, 1, a}, radius = b.radius)
	}
	if b.rim != {} && !tilted {
		render.push_rim(r, rect, {b.rim.lift * a, b.rim.darken * a}, b.radius)
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
}

// covers says whether b paints over what was drawn before it, so a label
// under it can't be read.
@(private)
covers :: proc(b: ^Box) -> bool {
	if b.flags & {.Draw_Backdrop, .Draw_Glass} != {} || b.texture != 0 {
		return true
	}
	return .Draw_Background in b.flags && (b.background.a > 0 || b.gradient.a > 0)
}

// draw_glass draws b as glass. Pressed, it swells a little and a light
// follows the pointer inside it, as a finger lights glass on iOS.
@(private)
draw_glass :: proc(u: ^State, b: ^Box, a: f32) {
	grow := min(b.rect.w, b.rect.h) * 0.06 * b.active_t
	rect := render.Rect{b.rect.x - grow, b.rect.y - grow, b.rect.w + 2 * grow, b.rect.h + 2 * grow}
	tint := b.background
	tint.a = (tint.a + 0.05 * b.hot_t + 0.04 * b.active_t) * a
	render.push_glass(u.renderer, rect, b.radius + grow, {
		tint = tint,
		refraction = min(rect.w, rect.h) * 0.12,
		bevel = min(rect.w, rect.h) * 0.22,
		highlight = (0.6 + 0.4 * b.hot_t) * a,
		glow = b.active_t * a,
		glow_at = u.input.mouse,
	})
}

// draw_label centres the label vertically and truncates it with an
// ellipsis to the box's width less its padding. Without a renderer it only
// looks for a cut label under the mouse.
@(private)
draw_label :: proc(u: ^State, b: ^Box, a: f32) {
	owner := b
	if b.full_text == "" && u.cut_owner != nil {
		owner = u.cut_owner
	}
	under := u.cut_scan && rect_contains(owner.clip, u.input.mouse)
	if u.renderer == nil && !under {
		return
	}
	if b.run == nil {
		b.run = text.shape(u.texts, b.font, b.font_size, b.label)
	}
	run := b.run
	avail := b.rect.w - 2 * b.text_pad
	if avail <= 0 {
		return
	}
	if under && text.cut_off(run, avail) {
		note_cut(u, owner)
	}
	if u.renderer == nil {
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
	if .Draw_Hot_Underline in b.flags && b.hot_t > 0 {
		render.push_rect(u.renderer, {x, y + run.ascent + 1.5, w, 1}, fade(b.text_color, a * b.hot_t))
	}
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
