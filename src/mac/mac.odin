// The few macOS services the app needs that aren't windows or drawing: the
// Keychain, opening a URL in the default browser and reading text from the
// clipboard. All of them are C APIs (Security, CoreFoundation,
// LaunchServices, the Pasteboard Manager in HIServices), so they are called
// straight from Odin without going through the shell, and they're safe on
// any thread.
package mac

import "core:strings"
import "core:sys/posix"

foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import Security "system:Security.framework"
foreign import CoreServices "system:CoreServices.framework"
foreign import ApplicationServices "system:ApplicationServices.framework"

CFTypeRef :: rawptr
CFStringRef :: rawptr
CFDataRef :: rawptr
CFDictionaryRef :: rawptr
CFURLRef :: rawptr
CFIndex :: int
OSStatus :: i32

ERR_SEC_SUCCESS :: 0
ERR_SEC_ITEM_NOT_FOUND :: -25300

@(private)
CF_STRING_ENCODING_UTF8 :: 0x08000100

// Opaque; only their addresses are passed to CFDictionaryCreate.
@(private)
CFDictionaryKeyCallBacks :: struct {
	_: [6]rawptr,
}
@(private)
CFDictionaryValueCallBacks :: struct {
	_: [5]rawptr,
}

@(private, default_calling_convention = "c")
foreign CoreFoundation {
	kCFBooleanTrue: CFTypeRef

	CFRelease :: proc(cf: CFTypeRef) ---
	CFStringCreateWithBytes :: proc(alloc: rawptr, bytes: [^]u8, count: CFIndex, encoding: u32, external: bool) -> CFStringRef ---
	CFDataCreate :: proc(alloc: rawptr, bytes: [^]u8, length: CFIndex) -> CFDataRef ---
	CFDataGetBytePtr :: proc(data: CFDataRef) -> [^]u8 ---
	CFDataGetLength :: proc(data: CFDataRef) -> CFIndex ---
	CFDictionaryCreate :: proc(alloc: rawptr, keys: [^]CFTypeRef, values: [^]CFTypeRef, count: CFIndex, key_callbacks: ^CFDictionaryKeyCallBacks, value_callbacks: ^CFDictionaryValueCallBacks) -> CFDictionaryRef ---
	CFURLCreateWithBytes :: proc(alloc: rawptr, bytes: [^]u8, length: CFIndex, encoding: u32, base: CFURLRef) -> CFURLRef ---
}

@(private, default_calling_convention = "c")
foreign Security {
	kSecClass:                CFStringRef
	kSecClassGenericPassword: CFStringRef
	kSecAttrService:          CFStringRef
	kSecAttrAccount:          CFStringRef
	kSecAttrLabel:            CFStringRef
	kSecValueData:            CFStringRef
	kSecReturnData:           CFStringRef
	kSecMatchLimit:           CFStringRef
	kSecMatchLimitOne:        CFStringRef

	SecItemAdd :: proc(attributes: CFDictionaryRef, result: ^CFTypeRef) -> OSStatus ---
	SecItemCopyMatching :: proc(query: CFDictionaryRef, result: ^CFTypeRef) -> OSStatus ---
	SecItemUpdate :: proc(query: CFDictionaryRef, attributes: CFDictionaryRef) -> OSStatus ---
	SecItemDelete :: proc(query: CFDictionaryRef) -> OSStatus ---
}

@(private, default_calling_convention = "c")
foreign CoreServices {
	LSOpenCFURLRef :: proc(url: CFURLRef, launched: ^CFURLRef) -> OSStatus ---
}

@(private, default_calling_convention = "c")
foreign ApplicationServices {
	PasteboardCreate :: proc(name: CFStringRef, pasteboard: ^rawptr) -> OSStatus ---
	PasteboardSynchronize :: proc(pasteboard: rawptr) -> u32 ---
	PasteboardGetItemCount :: proc(pasteboard: rawptr, count: ^uint) -> OSStatus ---
	PasteboardGetItemIdentifier :: proc(pasteboard: rawptr, index: CFIndex, item: ^rawptr) -> OSStatus ---
	PasteboardCopyItemFlavorData :: proc(pasteboard: rawptr, item: rawptr, flavor: CFStringRef, data: ^CFDataRef) -> OSStatus ---
}

@(private)
cf_string :: proc(s: string) -> CFStringRef {
	return CFStringCreateWithBytes(nil, raw_data(s), len(s), CF_STRING_ENCODING_UTF8, false)
}

// src/text declares kCFTypeDictionaryKeyCallBacks and its value twin too,
// and with -o:speed Odin links a foreign variable declared in two packages
// under a mangled name that doesn't exist. So these two are looked up at
// run time instead.
@(private)
RTLD_DEFAULT :: posix.Symbol_Table(~uintptr(1)) // (void *)-2 on macOS

@(private)
cf_dictionary :: proc(keys, values: []CFTypeRef) -> CFDictionaryRef {
	key_callbacks := (^CFDictionaryKeyCallBacks)(posix.dlsym(RTLD_DEFAULT, "kCFTypeDictionaryKeyCallBacks"))
	value_callbacks := (^CFDictionaryValueCallBacks)(posix.dlsym(RTLD_DEFAULT, "kCFTypeDictionaryValueCallBacks"))
	return CFDictionaryCreate(nil, raw_data(keys), raw_data(values), len(keys), key_callbacks, value_callbacks)
}

// keychain_set stores data as the generic password item (service, account),
// replacing the item's data if it exists. Returns the Security status,
// ERR_SEC_SUCCESS on success.
keychain_set :: proc(service, account: string, data: []u8) -> OSStatus {
	svc := cf_string(service)
	defer CFRelease(svc)
	acct := cf_string(account)
	defer CFRelease(acct)
	value := CFDataCreate(nil, raw_data(data), len(data))
	defer CFRelease(value)

	query := cf_dictionary({kSecClass, kSecAttrService, kSecAttrAccount}, {kSecClassGenericPassword, svc, acct})
	defer CFRelease(query)
	update := cf_dictionary({kSecValueData}, {value})
	defer CFRelease(update)
	status := SecItemUpdate(query, update)
	if status != ERR_SEC_ITEM_NOT_FOUND {
		return status
	}
	label := cf_string("TIDALfast")
	defer CFRelease(label)
	item := cf_dictionary(
		{kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrLabel, kSecValueData},
		{kSecClassGenericPassword, svc, acct, label, value},
	)
	defer CFRelease(item)
	return SecItemAdd(item, nil)
}

// keychain_get reads the data of the generic password item (service,
// account) into allocator. Status is ERR_SEC_ITEM_NOT_FOUND when there is
// no such item.
keychain_get :: proc(service, account: string, allocator := context.allocator) -> (data: []u8, status: OSStatus) {
	svc := cf_string(service)
	defer CFRelease(svc)
	acct := cf_string(account)
	defer CFRelease(acct)
	query := cf_dictionary(
		{kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData, kSecMatchLimit},
		{kSecClassGenericPassword, svc, acct, kCFBooleanTrue, kSecMatchLimitOne},
	)
	defer CFRelease(query)
	result: CFTypeRef
	status = SecItemCopyMatching(query, &result)
	if status != ERR_SEC_SUCCESS || result == nil {
		return nil, status
	}
	defer CFRelease(result)
	n := CFDataGetLength(result)
	data = make([]u8, n, allocator)
	copy(data, CFDataGetBytePtr(result)[:n])
	return data, status
}

// keychain_delete removes the generic password item (service, account).
// Deleting an item that doesn't exist returns ERR_SEC_ITEM_NOT_FOUND.
keychain_delete :: proc(service, account: string) -> OSStatus {
	svc := cf_string(service)
	defer CFRelease(svc)
	acct := cf_string(account)
	defer CFRelease(acct)
	query := cf_dictionary({kSecClass, kSecAttrService, kSecAttrAccount}, {kSecClassGenericPassword, svc, acct})
	defer CFRelease(query)
	return SecItemDelete(query)
}

// open_url opens url in the default browser. A URL without a scheme gets
// https://.
open_url :: proc(url: string) -> bool {
	full := url if strings.contains(url, "://") else strings.concatenate({"https://", url}, context.temp_allocator)
	u := CFURLCreateWithBytes(nil, raw_data(full), len(full), CF_STRING_ENCODING_UTF8, nil)
	if u == nil {
		return false
	}
	defer CFRelease(u)
	return LSOpenCFURLRef(u, nil) == 0
}

// clipboard_text returns the plain text on the general clipboard, "" if
// there is none.
clipboard_text :: proc(allocator := context.allocator) -> string {
	name := cf_string("com.apple.pasteboard.clipboard")
	defer CFRelease(name)
	pb: rawptr
	if PasteboardCreate(name, &pb) != 0 || pb == nil {
		return ""
	}
	defer CFRelease(pb)
	PasteboardSynchronize(pb)
	count: uint
	if PasteboardGetItemCount(pb, &count) != 0 || count == 0 {
		return ""
	}
	item: rawptr
	if PasteboardGetItemIdentifier(pb, 1, &item) != 0 {
		return ""
	}
	flavor := cf_string("public.utf8-plain-text")
	defer CFRelease(flavor)
	data: CFDataRef
	if PasteboardCopyItemFlavorData(pb, item, flavor, &data) != 0 || data == nil {
		return ""
	}
	defer CFRelease(data)
	n := CFDataGetLength(data)
	return strings.clone(string(CFDataGetBytePtr(data)[:n]), allocator)
}
