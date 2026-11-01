package render

// Odin dev-2026-10 hits a compiler assertion ("missing procedure
// 'sel_registerName'") on any intrinsics.objc_send, which every method in
// vendor:darwin/Metal uses. Until that is fixed, messages go through
// objc_msgSend directly, cast to the method's C signature as you would in C.
// arm64 only: there is no objc_msgSend_stret.

import "base:intrinsics"

foreign import objc "system:objc"

id :: rawptr
SEL :: rawptr

@(default_calling_convention = "c")
foreign objc {
	objc_getClass :: proc(name: cstring) -> id ---
	sel_registerName :: proc(name: cstring) -> SEL ---
	// Declared as in base:runtime; a foreign proc may only have one signature.
	objc_msgSend :: proc(self: ^intrinsics.objc_object, op: ^intrinsics.objc_selector, #c_vararg args: ..any) ---
}

// msg_proc returns objc_msgSend typed as P, which must start with (id, SEL).
msg_proc :: #force_inline proc "contextless" ($P: typeid) -> P {
	return P(rawptr(objc_msgSend))
}

msg :: proc "contextless" (obj: id, sel: cstring) -> id {
	return msg_proc(proc "c" (id, SEL) -> id)(obj, sel_registerName(sel))
}

msg_id :: proc "contextless" (obj: id, sel: cstring, arg: id) -> id {
	return msg_proc(proc "c" (id, SEL, id) -> id)(obj, sel_registerName(sel), arg)
}

msg_uint :: proc "contextless" (obj: id, sel: cstring, arg: uint) -> id {
	return msg_proc(proc "c" (id, SEL, uint) -> id)(obj, sel_registerName(sel), arg)
}

msg_bool :: proc "contextless" (obj: id, sel: cstring, arg: bool) {
	msg_proc(proc "c" (id, SEL, bool))(obj, sel_registerName(sel), arg)
}

// send is msg with a selector from sels.
send :: proc "contextless" (obj: id, sel: SEL) -> id {
	return msg_proc(proc "c" (id, SEL) -> id)(obj, sel)
}

send_id :: proc "contextless" (obj: id, sel: SEL, arg: id) -> id {
	return msg_proc(proc "c" (id, SEL, id) -> id)(obj, sel, arg)
}

send_uint :: proc "contextless" (obj: id, sel: SEL, arg: uint) -> id {
	return msg_proc(proc "c" (id, SEL, uint) -> id)(obj, sel, arg)
}

// The selectors a frame sends, registered once at start, and the one class
// it sends to. A sel_registerName is a lookup of about 400 instructions, and
// a frame sends about 45 messages. Metal is a load-time dependency of the
// executable, so its classes exist by then.
Selectors :: struct {
	render_pass_descriptor_class: id,
	command_buffer, commit, present_drawable, retain, release, wait_until_completed: SEL,
	status, gpu_start_time, gpu_end_time, contents: SEL,
	next_drawable, texture, width, height: SEL,
	render_pass_descriptor, color_attachments, object_at_indexed_subscript: SEL,
	set_texture, set_load_action, set_store_action, set_clear_color: SEL,
	render_command_encoder, end_encoding, set_render_pipeline_state: SEL,
	set_vertex_buffer, set_fragment_buffer, set_vertex_bytes, set_fragment_bytes, set_fragment_texture: SEL,
	draw_primitives, draw_primitives_instanced: SEL,
}

sels: Selectors

@(init, private)
register_selectors :: proc "contextless" () {
	sels = {
		render_pass_descriptor_class = objc_getClass("MTLRenderPassDescriptor"),
		command_buffer              = sel_registerName("commandBuffer"),
		commit                      = sel_registerName("commit"),
		present_drawable            = sel_registerName("presentDrawable:"),
		retain                      = sel_registerName("retain"),
		release                     = sel_registerName("release"),
		wait_until_completed        = sel_registerName("waitUntilCompleted"),
		status                      = sel_registerName("status"),
		gpu_start_time              = sel_registerName("GPUStartTime"),
		gpu_end_time                = sel_registerName("GPUEndTime"),
		contents                    = sel_registerName("contents"),
		next_drawable               = sel_registerName("nextDrawable"),
		texture                     = sel_registerName("texture"),
		width                       = sel_registerName("width"),
		height                      = sel_registerName("height"),
		render_pass_descriptor      = sel_registerName("renderPassDescriptor"),
		color_attachments           = sel_registerName("colorAttachments"),
		object_at_indexed_subscript = sel_registerName("objectAtIndexedSubscript:"),
		set_texture                 = sel_registerName("setTexture:"),
		set_load_action             = sel_registerName("setLoadAction:"),
		set_store_action            = sel_registerName("setStoreAction:"),
		set_clear_color             = sel_registerName("setClearColor:"),
		render_command_encoder      = sel_registerName("renderCommandEncoderWithDescriptor:"),
		end_encoding                = sel_registerName("endEncoding"),
		set_render_pipeline_state   = sel_registerName("setRenderPipelineState:"),
		set_vertex_buffer           = sel_registerName("setVertexBuffer:offset:atIndex:"),
		set_fragment_buffer         = sel_registerName("setFragmentBuffer:offset:atIndex:"),
		set_vertex_bytes            = sel_registerName("setVertexBytes:length:atIndex:"),
		set_fragment_bytes          = sel_registerName("setFragmentBytes:length:atIndex:"),
		set_fragment_texture        = sel_registerName("setFragmentTexture:atIndex:"),
		draw_primitives             = sel_registerName("drawPrimitives:vertexStart:vertexCount:"),
		draw_primitives_instanced   = sel_registerName("drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:"),
	}
}

new_object :: proc "contextless" (class: cstring) -> id {
	return msg(msg(objc_getClass(class), "alloc"), "init")
}

release :: proc "contextless" (obj: id) {
	if obj != nil {
		send(obj, sels.release)
	}
}

// ns_string returns an autoreleased NSString copy of s.
ns_string :: proc "contextless" (s: string) -> id {
	NS_UTF8_STRING_ENCODING :: 4
	str := msg(objc_getClass("NSString"), "alloc")
	str = msg_proc(proc "c" (id, SEL, rawptr, uint, uint) -> id)(str, sel_registerName("initWithBytes:length:encoding:"), raw_data(s), uint(len(s)), NS_UTF8_STRING_ENCODING)
	return msg(str, "autorelease")
}

// error_string returns the localized description of an NSError. The string
// lives as long as the current autorelease pool.
error_string :: proc "contextless" (err: id) -> string {
	if err == nil {
		return "unknown error"
	}
	desc := msg(err, "localizedDescription")
	return string(cstring(msg(desc, "UTF8String")))
}
