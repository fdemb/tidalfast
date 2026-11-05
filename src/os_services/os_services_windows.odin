// The few OS services the app needs that aren't windows, drawing or audio:
// a secret store, opening a URL in the default browser and where settings
// and caches go. On Windows the secret store is the Credential Manager, the
// user's vault that Windows encrypts with their login. A generic credential
// holds at most CRED_MAX_BLOB bytes, so a longer secret is split across
// numbered credentials: "tidalfast/auth", "tidalfast/auth#1" and so on.
package os_services

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import win "core:sys/windows"

Status :: i32

SECRET_OK :: 0
SECRET_NOT_FOUND :: -25300 // the same number as on macOS
SECRET_UNAVAILABLE :: -1
SECRET_FAILED :: -2

@(private)
CRED_TYPE_GENERIC :: 1
@(private)
CRED_PERSIST_LOCAL_MACHINE :: 2
// CRED_MAX_CREDENTIAL_BLOB_SIZE: 5 * 512 bytes.
@(private)
CRED_MAX_BLOB :: 2560
@(private)
CRED_MAX_PARTS :: 8

@(private)
CREDENTIALW :: struct {
	flags:                u32,
	type:                 u32,
	target_name:          win.wstring,
	comment:              win.wstring,
	last_written:         win.FILETIME,
	credential_blob_size: u32,
	credential_blob:      [^]u8,
	persist:              u32,
	attribute_count:      u32,
	attributes:           rawptr,
	target_alias:         win.wstring,
	user_name:            win.wstring,
}

foreign import advapi32 "system:Advapi32.lib"

@(private)
@(default_calling_convention = "system")
foreign advapi32 {
	CredWriteW :: proc(credential: ^CREDENTIALW, flags: u32) -> win.BOOL ---
	CredReadW :: proc(target_name: win.LPCWSTR, type: u32, flags: u32, credential: ^^CREDENTIALW) -> win.BOOL ---
	CredDeleteW :: proc(target_name: win.LPCWSTR, type: u32, flags: u32) -> win.BOOL ---
	CredFree :: proc(buffer: rawptr) ---
}

@(private)
target :: proc(service, account: string, part: int) -> win.wstring {
	name := fmt.tprintf("%s/%s", service, account) if part == 0 else fmt.tprintf("%s/%s#%d", service, account, part)
	return win.utf8_to_wstring(name, context.temp_allocator)
}

@(private)
error_status :: proc(what: string) -> Status {
	err := win.GetLastError()
	if err == win.ERROR_NOT_FOUND {
		return SECRET_NOT_FOUND
	}
	log.warnf("os_services: %s failed, error %d", what, err)
	return SECRET_FAILED
}

// secret_set stores data as the item (service, account), replacing the
// item's data if it exists. Returns SECRET_OK on success.
secret_set :: proc(service, account: string, data: []u8) -> Status {
	parts := max((len(data) + CRED_MAX_BLOB - 1) / CRED_MAX_BLOB, 1)
	if parts > CRED_MAX_PARTS {
		log.warn("os_services: the secret is too long for the Credential Manager")
		return SECRET_FAILED
	}
	user := win.utf8_to_wstring(account, context.temp_allocator)
	for part in 0 ..< parts {
		chunk := data[min(part * CRED_MAX_BLOB, len(data)):min((part + 1) * CRED_MAX_BLOB, len(data))]
		cred := CREDENTIALW {
			type                 = CRED_TYPE_GENERIC,
			target_name          = target(service, account, part),
			credential_blob_size = u32(len(chunk)),
			credential_blob      = raw_data(chunk),
			persist              = CRED_PERSIST_LOCAL_MACHINE,
			user_name            = user,
		}
		if !CredWriteW(&cred, 0) {
			return error_status("CredWriteW")
		}
	}
	// A shorter secret leaves no parts of a longer one behind.
	for part in parts ..< CRED_MAX_PARTS {
		if !CredDeleteW(target(service, account, part), CRED_TYPE_GENERIC, 0) {
			break
		}
	}
	return SECRET_OK
}

// secret_get reads the data of the item (service, account) into
// allocator. Status is SECRET_NOT_FOUND when there is no such item.
secret_get :: proc(service, account: string, allocator := context.allocator) -> (data: []u8, status: Status) {
	out := make([dynamic]u8, 0, CRED_MAX_BLOB, context.temp_allocator)
	for part in 0 ..< CRED_MAX_PARTS {
		cred: ^CREDENTIALW
		if !CredReadW(target(service, account, part), CRED_TYPE_GENERIC, 0, &cred) {
			if part > 0 && win.GetLastError() == win.ERROR_NOT_FOUND {
				break
			}
			return nil, error_status("CredReadW")
		}
		append(&out, ..cred.credential_blob[:cred.credential_blob_size])
		full := cred.credential_blob_size == CRED_MAX_BLOB
		CredFree(cred)
		if !full {
			break
		}
	}
	data = make([]u8, len(out), allocator)
	copy(data, out[:])
	return data, SECRET_OK
}

// secret_delete removes the item (service, account). Deleting an item that
// doesn't exist returns SECRET_NOT_FOUND.
secret_delete :: proc(service, account: string) -> Status {
	if !CredDeleteW(target(service, account, 0), CRED_TYPE_GENERIC, 0) {
		return error_status("CredDeleteW")
	}
	for part in 1 ..< CRED_MAX_PARTS {
		if !CredDeleteW(target(service, account, part), CRED_TYPE_GENERIC, 0) {
			break
		}
	}
	return SECRET_OK
}

// open_url opens url in the default browser. A URL without a scheme gets
// https://, and any scheme but http and https is refused.
open_url :: proc(url: string) -> bool {
	full := url if strings.contains(url, "://") else strings.concatenate({"https://", url}, context.temp_allocator)
	if !strings.has_prefix(full, "https://") && !strings.has_prefix(full, "http://") {
		log.warn("os_services: not opening a URL that isn't http or https")
		return false
	}
	wide := win.utf8_to_wstring(full, context.temp_allocator)
	// ShellExecute returns a value above 32 when it worked.
	result := uintptr(win.ShellExecuteW(nil, win.L("open"), wide, nil, nil, win.SW_SHOWNORMAL))
	if result <= 32 {
		log.warnf("os_services: couldn't open the browser, error %d", result)
		return false
	}
	return true
}

// config_dir is where settings go: the roaming %APPDATA%. Empty if Windows
// doesn't say.
config_dir :: proc(allocator: runtime.Allocator) -> string {
	return known_folder(win.FOLDERID_RoamingAppData, "APPDATA", allocator)
}

// cache_dir is where caches go: %LOCALAPPDATA%, which doesn't roam.
cache_dir :: proc(allocator: runtime.Allocator) -> string {
	return known_folder(win.FOLDERID_LocalAppData, "LOCALAPPDATA", allocator)
}

// known_folder is the folder's path with forward slashes, which Windows
// takes as well as backslashes, so the app can join paths with "/". The
// environment variable Windows sets for it comes first, as XDG_CONFIG_HOME
// does on Linux, so tests can keep the app away from the user's folders.
@(private)
known_folder :: proc(id: win.GUID, variable: string, allocator: runtime.Allocator) -> string {
	if dir := os.get_env(variable, context.temp_allocator); dir != "" {
		return slashes(dir, allocator)
	}
	id := id
	path: win.LPWSTR
	if win.SHGetKnownFolderPath(&id, 0, nil, &path) != 0 {
		return ""
	}
	defer win.CoTaskMemFree(rawptr(path))
	dir, err := win.wstring_to_utf8(win.wstring(path), -1, context.temp_allocator)
	if err != nil {
		return ""
	}
	return slashes(dir, allocator)
}

@(private)
slashes :: proc(s: string, allocator: runtime.Allocator) -> string {
	out, _ := strings.replace_all(s, "\\", "/", allocator)
	return out
}
