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

new_object :: proc "contextless" (class: cstring) -> id {
	return msg(msg(objc_getClass(class), "alloc"), "init")
}

release :: proc "contextless" (obj: id) {
	if obj != nil {
		msg(obj, "release")
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
