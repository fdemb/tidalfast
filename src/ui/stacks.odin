package ui

// Style stacks, after raddebugger's. box_make takes each box's style from
// the top of the stack, so a style set for a scope reaches every box built
// in it:
//
//	{
//		ui.text_align(.Center)       // until the end of the block
//		ui.label("Title")
//		ui.label("Artist")
//	}
//	ui.set_next_radius(6)           // the next box only
//	ui.box_make("", {.Draw_Background})
//
// A scope pops itself at the end of the enclosing block. A set_next value
// goes to the next box built and then is gone, whatever the stack holds.

import "../render"
import "../text"

Stack :: struct($T: typeid) {
	items: [STACK_DEPTH]T,
	count: int,
}

// Style is the part of a box it takes from the stack.
Style :: struct {
	flags:        Box_Flags, // added to the flags box_make is given
	font:         text.Font,
	font_size:    f32,
	text_color:   render.Color,
	text_align:   Align,
	text_pad:     f32, // left and right of the label
	background:   render.Color,
	border_color: render.Color,
	hover_color:  render.Color,
	active_color: render.Color,
	radius:       f32,
}

@(private)
STYLE_DEFAULT :: Style {
	font         = .Regular,
	font_size    = 13,
	text_color   = {1, 1, 1, 1},
	hover_color  = {1, 1, 1, 0.06},
	active_color = {1, 1, 1, 0.06},
}

@(private)
Style_Field :: enum {
	Flags,
	Font,
	Font_Size,
	Text_Color,
	Text_Align,
	Text_Pad,
	Background,
	Border_Color,
	Hover_Color,
	Active_Color,
	Radius,
}

Styles :: struct {
	stack:    Stack(Style),
	spill:    Style, // written by scopes past STACK_DEPTH
	next:     Style,
	next_set: bit_set[Style_Field],
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
style_top :: proc(st: ^Styles) -> Style {
	if st.stack.count == 0 {
		return STYLE_DEFAULT
	}
	return st.stack.items[min(st.stack.count, STACK_DEPTH) - 1]
}

// style_push pushes a copy of the top for a scope to change.
@(private)
style_push :: proc() -> ^Style {
	st := &ctx.styles
	push(&st.stack, style_top(st))
	if st.stack.count > STACK_DEPTH {
		return &st.spill
	}
	return &st.stack.items[st.stack.count - 1]
}

@(private)
style_next :: proc(f: Style_Field) -> ^Style {
	ctx.styles.next_set += {f}
	return &ctx.styles.next
}

@(private)
style_take :: proc(st: ^Styles, b: ^Box) {
	s, n := style_top(st), st.next
	for f in st.next_set {
		switch f {
		case .Flags:
			s.flags = n.flags
		case .Font:
			s.font = n.font
		case .Font_Size:
			s.font_size = n.font_size
		case .Text_Color:
			s.text_color = n.text_color
		case .Text_Align:
			s.text_align = n.text_align
		case .Text_Pad:
			s.text_pad = n.text_pad
		case .Background:
			s.background = n.background
		case .Border_Color:
			s.border_color = n.border_color
		case .Hover_Color:
			s.hover_color = n.hover_color
		case .Active_Color:
			s.active_color = n.active_color
		case .Radius:
			s.radius = n.radius
		}
	}
	flags := b.flags
	b.style = s
	b.flags += flags
	st.next_set = {}
}

@(private)
styles_clear :: proc(st: ^Styles) -> (balanced: bool) {
	balanced = st.stack.count == 0 && st.next_set == {}
	st.stack.count = 0
	st.next_set = {}
	return
}

@(private)
pop_style :: proc() {pop(&ctx.styles.stack)}

// Scopes: each sets its style for the boxes built until the end of the
// enclosing block.

@(deferred_none = pop_style)
flags :: proc(v: Box_Flags) {style_push().flags = v}
@(deferred_none = pop_style)
text_align :: proc(v: Align) {style_push().text_align = v}
@(deferred_none = pop_style)
text_pad :: proc(v: f32) {style_push().text_pad = v}
@(deferred_none = pop_style)
background :: proc(v: render.Color) {style_push().background = v}
@(deferred_none = pop_style)
hover_color :: proc(v: render.Color) {style_push().hover_color = v}
@(deferred_none = pop_style)
radius :: proc(v: f32) {style_push().radius = v}

// text_style sets the font, its size and the text colour together.
@(deferred_none = pop_style)
text_style :: proc(f: text.Font, size: f32, color: render.Color) {
	s := style_push()
	s.font, s.font_size, s.text_color = f, size, color
}

// set_next_*: the style of the next box built, whatever the stack holds.

set_next_flags :: proc(v: Box_Flags) {style_next(.Flags).flags = v}
set_next_font :: proc(v: text.Font) {style_next(.Font).font = v}
set_next_font_size :: proc(v: f32) {style_next(.Font_Size).font_size = v}
set_next_text_color :: proc(v: render.Color) {style_next(.Text_Color).text_color = v}
set_next_text_align :: proc(v: Align) {style_next(.Text_Align).text_align = v}
set_next_text_pad :: proc(v: f32) {style_next(.Text_Pad).text_pad = v}
set_next_background :: proc(v: render.Color) {style_next(.Background).background = v}
set_next_border_color :: proc(v: render.Color) {style_next(.Border_Color).border_color = v}
set_next_hover_color :: proc(v: render.Color) {style_next(.Hover_Color).hover_color = v}
set_next_active_color :: proc(v: render.Color) {style_next(.Active_Color).active_color = v}
set_next_radius :: proc(v: f32) {style_next(.Radius).radius = v}
