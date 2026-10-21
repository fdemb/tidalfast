package ui

// Style stacks, after raddebugger's. box_make takes each box's style from
// the top of these stacks, so a style set for a scope reaches every box
// built in it:
//
//	{
//		ui.text_color(SECONDARY)     // until the end of the block
//		ui.label("Title")
//		ui.label("Artist")
//	}
//	ui.set_next_radius(6)           // the next box only
//	ui.box_make("", {.Draw_Background})
//
// A scope pops itself at the end of the enclosing block. A set_next value
// goes to the next box built and then is gone, whatever the stack holds.
// Opacity, positions and sizes aren't stacks: opacity already multiplies
// everything inside a box, and sizes are box_make's arguments.

import "../render"
import "../text"

Stack :: struct($T: typeid) {
	items:    [STACK_DEPTH]T,
	count:    int,
	next:     T, // set_next's value, for the next box only
	has_next: bool,
}

Style_Stacks :: struct {
	flags:        Stack(Box_Flags), // added to the flags box_make is given
	font:         Stack(text.Font),
	font_size:    Stack(f32),
	text_color:   Stack(render.Color),
	text_align:   Stack(Align),
	text_pad:     Stack(f32),
	background:   Stack(render.Color),
	border_color: Stack(render.Color),
	hover_color:  Stack(render.Color),
	active_color: Stack(render.Color),
	radius:       Stack(f32),
}

// What a box gets when nothing is pushed.
@(private)
STYLE_DEFAULT :: struct {
	font:         text.Font,
	font_size:    f32,
	text_color:   render.Color,
	hover_color:  render.Color,
	active_color: render.Color,
} {
	font         = .Regular,
	font_size    = 13,
	text_color   = {1, 1, 1, 1},
	hover_color  = {1, 1, 1, 0.06},
	active_color = {1, 1, 1, 0.06},
}

@(private)
push :: proc(s: ^Stack($T), v: T) {
	if s.count < STACK_DEPTH {
		s.items[s.count] = v
	}
	s.count += 1
}

@(private)
pop :: proc(s: ^Stack($T)) {
	if s.count > 0 {
		s.count -= 1
	}
}

@(private)
top :: proc(s: ^Stack($T), default: T) -> T {
	if s.has_next {
		return s.next
	}
	if s.count == 0 {
		return default
	}
	return s.items[min(s.count, STACK_DEPTH) - 1]
}

@(private)
set_next :: proc(s: ^Stack($T), v: T) {
	s.next = v
	s.has_next = true
}

// style_take gives b the style on top of the stacks and uses up the
// set_next values.
@(private)
style_take :: proc(st: ^Style_Stacks, b: ^Box) {
	b.flags += top(&st.flags, Box_Flags{})
	b.font = top(&st.font, STYLE_DEFAULT.font)
	b.font_size = top(&st.font_size, STYLE_DEFAULT.font_size)
	b.text_color = top(&st.text_color, STYLE_DEFAULT.text_color)
	b.text_align = top(&st.text_align, Align.Left)
	b.text_pad = top(&st.text_pad, f32(0))
	b.background = top(&st.background, render.Color{})
	b.border_color = top(&st.border_color, render.Color{})
	b.hover_color = top(&st.hover_color, STYLE_DEFAULT.hover_color)
	b.active_color = top(&st.active_color, STYLE_DEFAULT.active_color)
	b.radius = top(&st.radius, f32(0))
	st.flags.has_next = false
	st.font.has_next = false
	st.font_size.has_next = false
	st.text_color.has_next = false
	st.text_align.has_next = false
	st.text_pad.has_next = false
	st.background.has_next = false
	st.border_color.has_next = false
	st.hover_color.has_next = false
	st.active_color.has_next = false
	st.radius.has_next = false
}

// styles_clear empties the stacks for a new frame, and reports whether the
// last frame left a scope open or a set_next value unused.
@(private)
styles_clear :: proc(st: ^Style_Stacks) -> (balanced: bool) {
	balanced = true
	reset :: proc(s: ^Stack($T), balanced: ^bool) {
		if s.count != 0 || s.has_next {
			balanced^ = false
		}
		s.count = 0
		s.has_next = false
	}
	reset(&st.flags, &balanced)
	reset(&st.font, &balanced)
	reset(&st.font_size, &balanced)
	reset(&st.text_color, &balanced)
	reset(&st.text_align, &balanced)
	reset(&st.text_pad, &balanced)
	reset(&st.background, &balanced)
	reset(&st.border_color, &balanced)
	reset(&st.hover_color, &balanced)
	reset(&st.active_color, &balanced)
	reset(&st.radius, &balanced)
	return
}

// styles_push_defaults starts a scope with the default style, for the
// floating layer: a menu or a tooltip looks the same wherever it's built.
@(private)
styles_push_defaults :: proc(st: ^Style_Stacks) {
	push(&st.flags, Box_Flags{})
	push(&st.font, STYLE_DEFAULT.font)
	push(&st.font_size, STYLE_DEFAULT.font_size)
	push(&st.text_color, STYLE_DEFAULT.text_color)
	push(&st.text_align, Align.Left)
	push(&st.text_pad, f32(0))
	push(&st.background, render.Color{})
	push(&st.border_color, render.Color{})
	push(&st.hover_color, STYLE_DEFAULT.hover_color)
	push(&st.active_color, STYLE_DEFAULT.active_color)
	push(&st.radius, f32(0))
}

@(private)
styles_pop_defaults :: proc(st: ^Style_Stacks) {
	pop(&st.flags)
	pop(&st.font)
	pop(&st.font_size)
	pop(&st.text_color)
	pop(&st.text_align)
	pop(&st.text_pad)
	pop(&st.background)
	pop(&st.border_color)
	pop(&st.hover_color)
	pop(&st.active_color)
	pop(&st.radius)
}

// The current style, for widgets that measure text before they build.

current_font :: proc() -> text.Font {
	return top(&ctx.styles.font, STYLE_DEFAULT.font)
}

current_font_size :: proc() -> f32 {
	return top(&ctx.styles.font_size, STYLE_DEFAULT.font_size)
}

// Scopes: each sets its style for the boxes built until the end of the
// enclosing block.

@(deferred_none = pop_flags)
flags :: proc(v: Box_Flags) {push(&ctx.styles.flags, v)}
@(deferred_none = pop_font)
font :: proc(v: text.Font) {push(&ctx.styles.font, v)}
@(deferred_none = pop_font_size)
font_size :: proc(v: f32) {push(&ctx.styles.font_size, v)}
@(deferred_none = pop_text_color)
text_color :: proc(v: render.Color) {push(&ctx.styles.text_color, v)}
@(deferred_none = pop_text_align)
text_align :: proc(v: Align) {push(&ctx.styles.text_align, v)}
@(deferred_none = pop_text_pad)
text_pad :: proc(v: f32) {push(&ctx.styles.text_pad, v)}
@(deferred_none = pop_background)
background :: proc(v: render.Color) {push(&ctx.styles.background, v)}
@(deferred_none = pop_border_color)
border_color :: proc(v: render.Color) {push(&ctx.styles.border_color, v)}
@(deferred_none = pop_hover_color)
hover_color :: proc(v: render.Color) {push(&ctx.styles.hover_color, v)}
@(deferred_none = pop_active_color)
active_color :: proc(v: render.Color) {push(&ctx.styles.active_color, v)}
@(deferred_none = pop_radius)
radius :: proc(v: f32) {push(&ctx.styles.radius, v)}

// text_style sets the font, its size and the text colour together.
@(deferred_none = pop_text_style)
text_style :: proc(f: text.Font, size: f32, color: render.Color) {
	push(&ctx.styles.font, f)
	push(&ctx.styles.font_size, size)
	push(&ctx.styles.text_color, color)
}

@(private)
pop_flags :: proc() {pop(&ctx.styles.flags)}
@(private)
pop_font :: proc() {pop(&ctx.styles.font)}
@(private)
pop_font_size :: proc() {pop(&ctx.styles.font_size)}
@(private)
pop_text_color :: proc() {pop(&ctx.styles.text_color)}
@(private)
pop_text_align :: proc() {pop(&ctx.styles.text_align)}
@(private)
pop_text_pad :: proc() {pop(&ctx.styles.text_pad)}
@(private)
pop_background :: proc() {pop(&ctx.styles.background)}
@(private)
pop_border_color :: proc() {pop(&ctx.styles.border_color)}
@(private)
pop_hover_color :: proc() {pop(&ctx.styles.hover_color)}
@(private)
pop_active_color :: proc() {pop(&ctx.styles.active_color)}
@(private)
pop_radius :: proc() {pop(&ctx.styles.radius)}
@(private)
pop_text_style :: proc() {
	pop(&ctx.styles.font)
	pop(&ctx.styles.font_size)
	pop(&ctx.styles.text_color)
}

// set_next_*: the style of the next box built, whatever the stack holds.

set_next_flags :: proc(v: Box_Flags) {set_next(&ctx.styles.flags, v)}
set_next_font :: proc(v: text.Font) {set_next(&ctx.styles.font, v)}
set_next_font_size :: proc(v: f32) {set_next(&ctx.styles.font_size, v)}
set_next_text_color :: proc(v: render.Color) {set_next(&ctx.styles.text_color, v)}
set_next_text_align :: proc(v: Align) {set_next(&ctx.styles.text_align, v)}
set_next_text_pad :: proc(v: f32) {set_next(&ctx.styles.text_pad, v)}
set_next_background :: proc(v: render.Color) {set_next(&ctx.styles.background, v)}
set_next_border_color :: proc(v: render.Color) {set_next(&ctx.styles.border_color, v)}
set_next_hover_color :: proc(v: render.Color) {set_next(&ctx.styles.hover_color, v)}
set_next_active_color :: proc(v: render.Color) {set_next(&ctx.styles.active_color, v)}
set_next_radius :: proc(v: f32) {set_next(&ctx.styles.radius, v)}
