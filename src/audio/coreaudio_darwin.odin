#+private
package audio

// The CoreAudio HAL calls bitperfect_darwin.odin makes. They are plain C
// functions in CoreAudio.framework, declared by hand, so Odin calls them
// without the Obj-C runtime. Private to the package: the player goes
// through the procedures bitperfect_linux.odin also has.

import CF "core:sys/darwin/CoreFoundation"
import "core:sys/posix"

foreign import CoreAudio "system:CoreAudio.framework"

Audio_Object_ID :: u32
OS_Status :: i32

Property_Address :: struct {
	selector: u32,
	scope:    u32,
	element:  u32,
}

IO_Proc :: #type proc "c" (device: Audio_Object_ID, now: rawptr, input: ^Audio_Buffer_List, input_time: rawptr, output: ^Audio_Buffer_List, output_time: rawptr, client: rawptr) -> OS_Status
Listener_Proc :: #type proc "c" (id: Audio_Object_ID, count: u32, addresses: [^]Property_Address, client: rawptr) -> OS_Status

@(private = "file")
fourcc :: proc "contextless" (s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

SYSTEM_OBJECT :: 1
SCOPE_GLOBAL := fourcc("glob")
SCOPE_OUTPUT := fourcc("outp")
ELEMENT_MAIN :: 0

PROP_DEFAULT_OUTPUT := fourcc("dOut")
PROP_DEVICES := fourcc("dev#")
PROP_NAME := fourcc("lnam")
PROP_UID := fourcc("uid ")
PROP_ALIVE := fourcc("livn")
PROP_STEREO_CHANNELS := fourcc("dch2")
PROP_NOMINAL_RATE := fourcc("nsrt")
PROP_AVAILABLE_RATES := fourcc("nsr#")
PROP_HOG_MODE := fourcc("oink")
PROP_STREAMS := fourcc("stm#")
PROP_PHYSICAL_FORMAT := fourcc("pft ")
PROP_AVAILABLE_PHYSICAL := fourcc("pfta")
PROP_VIRTUAL_FORMAT := fourcc("sfmt")

@(default_calling_convention = "c")
foreign CoreAudio {
	AudioObjectGetPropertyDataSize :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32) -> OS_Status ---
	AudioObjectGetPropertyData :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32, data: rawptr) -> OS_Status ---
	AudioObjectSetPropertyData :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: u32, data: rawptr) -> OS_Status ---
	AudioDeviceCreateIOProcID :: proc(device: Audio_Object_ID, io_proc: IO_Proc, client: rawptr, id: ^rawptr) -> OS_Status ---
	AudioDeviceDestroyIOProcID :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioDeviceStart :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioDeviceStop :: proc(device: Audio_Object_ID, id: rawptr) -> OS_Status ---
	AudioObjectAddPropertyListener :: proc(id: Audio_Object_ID, addr: ^Property_Address, listener: Listener_Proc, client: rawptr) -> OS_Status ---
	AudioObjectRemovePropertyListener :: proc(id: Audio_Object_ID, addr: ^Property_Address, listener: Listener_Proc, client: rawptr) -> OS_Status ---
}

get :: proc(id: Audio_Object_ID, selector, scope: u32, out: ^$T) -> bool {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	size := u32(size_of(T))
	return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, out) == 0
}

set :: proc(id: Audio_Object_ID, selector, scope: u32, value: ^$T) -> OS_Status {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	return AudioObjectSetPropertyData(id, &addr, 0, nil, u32(size_of(T)), value)
}

// get_array reads a property that is an array of T into the temp allocator.
get_array :: proc(id: Audio_Object_ID, selector, scope: u32, $T: typeid) -> []T {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	size: u32
	if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) != 0 || size < size_of(T) {
		return nil
	}
	out := make([]T, int(size) / size_of(T), context.temp_allocator)
	if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw_data(out)) != 0 {
		return nil
	}
	return out[:int(size) / size_of(T)]
}

device_available_rates :: proc(dev: Audio_Object_ID) -> []Value_Range {
	return get_array(dev, PROP_AVAILABLE_RATES, SCOPE_GLOBAL, Value_Range)
}

// device_stereo_channels is the pair of output channels the device wants
// stereo on, from 0. {0, 1} if it doesn't say.
device_stereo_channels :: proc(dev: Audio_Object_ID) -> [2]int {
	ch: [2]u32
	if !get(dev, PROP_STEREO_CHANNELS, SCOPE_OUTPUT, &ch) || ch[0] == 0 || ch[1] == 0 {
		return {0, 1}
	}
	return {int(ch[0]) - 1, int(ch[1]) - 1}
}

// listen calls listener with client whenever the property changes. The
// listener runs on a HAL thread.
listen :: proc(id: Audio_Object_ID, selector: u32, listener: Listener_Proc, client: rawptr) -> bool {
	addr := Property_Address{selector, SCOPE_GLOBAL, ELEMENT_MAIN}
	return AudioObjectAddPropertyListener(id, &addr, listener, client) == 0
}

unlisten :: proc(id: Audio_Object_ID, selector: u32, listener: Listener_Proc, client: rawptr) {
	addr := Property_Address{selector, SCOPE_GLOBAL, ELEMENT_MAIN}
	AudioObjectRemovePropertyListener(id, &addr, listener, client)
}

// device_hog_owner is the pid that has the device in hog mode, -1 for none.
device_hog_owner :: proc(dev: Audio_Object_ID) -> posix.pid_t {
	pid := posix.pid_t(-1)
	get(dev, PROP_HOG_MODE, SCOPE_GLOBAL, &pid)
	return pid
}

// device_output_stream is the device's first output stream, 0 if none.
device_output_stream :: proc(dev: Audio_Object_ID) -> Audio_Object_ID {
	streams := get_array(dev, PROP_STREAMS, SCOPE_OUTPUT, Audio_Object_ID)
	return streams[0] if len(streams) > 0 else 0
}

stream_physical_formats :: proc(stream: Audio_Object_ID) -> []Ranged_Description {
	return get_array(stream, PROP_AVAILABLE_PHYSICAL, SCOPE_GLOBAL, Ranged_Description)
}

stream_physical_format :: proc(stream: Audio_Object_ID) -> (f: Stream_Description, ok: bool) {
	ok = get(stream, PROP_PHYSICAL_FORMAT, SCOPE_GLOBAL, &f)
	return
}

stream_virtual_format :: proc(stream: Audio_Object_ID) -> (f: Stream_Description, ok: bool) {
	ok = get(stream, PROP_VIRTUAL_FORMAT, SCOPE_GLOBAL, &f)
	return
}

// device_uid is the device's persistent id, the same after a reboot.
device_uid :: proc(dev: Audio_Object_ID) -> string {
	return string_property(dev, PROP_UID) or_else ""
}

// string_property reads a CFString property into the temp allocator.
string_property :: proc(dev: Audio_Object_ID, selector: u32) -> (string, bool) {
	str: CF.String
	if !get(dev, selector, SCOPE_GLOBAL, &str) || str == nil {
		return "", false
	}
	defer CF.CFRelease(CF.TypeRef(str))
	buf := make([]u8, 256, context.temp_allocator)
	if !CF.StringGetCString(str, raw_data(buf), CF.Index(len(buf)), CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)) {
		return "", false
	}
	return string(cstring(raw_data(buf))), true
}

// device_by_uid finds a device by device_uid, 0 if it isn't there.
device_by_uid :: proc(uid: string) -> Audio_Object_ID {
	for dev in get_array(SYSTEM_OBJECT, PROP_DEVICES, SCOPE_GLOBAL, Audio_Object_ID) {
		if device_uid(dev) == uid {
			return dev
		}
	}
	return 0
}
