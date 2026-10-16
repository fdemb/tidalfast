// The few OS services the app needs that aren't windows, drawing or audio:
// a secret store and opening a URL in the default browser. Each OS has its
// own file. On macOS the secret store is the login Keychain, and all of it
// is C APIs (Security, CoreFoundation, LaunchServices), so it's called
// straight from Odin without going through the shell, and it's safe on any
// thread.
package os_services

import "core:strings"
import "core:sys/posix"

foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import Security "system:Security.framework"
foreign import CoreServices "system:CoreServices.framework"

@(private)
CFTypeRef :: rawptr
@(private)
CFStringRef :: rawptr
@(private)
CFDataRef :: rawptr
@(private)
CFDictionaryRef :: rawptr
@(private)
CFURLRef :: rawptr
@(private)
CFIndex :: int

Status :: i32 // OSStatus

SECRET_OK :: 0 // errSecSuccess
SECRET_NOT_FOUND :: -25300 // errSecItemNotFound

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

	SecItemAdd :: proc(attributes: CFDictionaryRef, result: ^CFTypeRef) -> Status ---
	SecItemCopyMatching :: proc(query: CFDictionaryRef, result: ^CFTypeRef) -> Status ---
	SecItemUpdate :: proc(query: CFDictionaryRef, attributes: CFDictionaryRef) -> Status ---
	SecItemDelete :: proc(query: CFDictionaryRef) -> Status ---
}

@(private, default_calling_convention = "c")
foreign CoreServices {
	LSOpenCFURLRef :: proc(url: CFURLRef, launched: ^CFURLRef) -> Status ---
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

// secret_set stores data as the generic password item (service, account),
// replacing the item's data if it exists. Returns the Security status,
// SECRET_OK on success.
secret_set :: proc(service, account: string, data: []u8) -> Status {
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
	if status != SECRET_NOT_FOUND {
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

// secret_get reads the data of the generic password item (service,
// account) into allocator. Status is SECRET_NOT_FOUND when there is
// no such item.
secret_get :: proc(service, account: string, allocator := context.allocator) -> (data: []u8, status: Status) {
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
	if status != SECRET_OK || result == nil {
		return nil, status
	}
	defer CFRelease(result)
	n := CFDataGetLength(result)
	data = make([]u8, n, allocator)
	copy(data, CFDataGetBytePtr(result)[:n])
	return data, status
}

// secret_delete removes the generic password item (service, account).
// Deleting an item that doesn't exist returns SECRET_NOT_FOUND.
secret_delete :: proc(service, account: string) -> Status {
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
