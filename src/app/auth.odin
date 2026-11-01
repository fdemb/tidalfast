package app

// The login kept between runs: the Keychain item and the JSON in it, and
// saving the tokens whenever the session gets new ones.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:sync"
import "core:time"

import "../os_services"
import "../tidal"

KEYCHAIN_SERVICE :: "tidalfast"
KEYCHAIN_MOCK_SERVICE :: "tidalfast-mock" // with TIDALFAST_API
KEYCHAIN_ACCOUNT :: "auth"

// Keychain is where the login is kept between runs: the OS Keychain item
// for a service, or, in tests, an item in memory.
Keychain :: union {
	Os_Keychain,
	^Memory_Keychain,
}

// Os_Keychain is the item (service, KEYCHAIN_ACCOUNT). Against a mock
// server, TIDALFAST_KEYCHAIN can name another service, so test runs of
// differently signed builds don't share one and the Keychain doesn't ask
// for access.
Os_Keychain :: struct {
	service: Small,
}

// Memory_Keychain holds the item on the heap, nil for none. Workers read
// and write it, so it has a lock of its own.
Memory_Keychain :: struct {
	mutex: sync.Mutex,
	item:  []u8,
}

keychain_get :: proc(k: ^Keychain, allocator := context.allocator) -> ([]u8, os_services.Status) {
	switch &k in k {
	case Os_Keychain:
		return os_services.secret_get(small_str(&k.service), KEYCHAIN_ACCOUNT, allocator)
	case ^Memory_Keychain:
		sync.guard(&k.mutex)
		if k.item == nil {
			return nil, os_services.SECRET_NOT_FOUND
		}
		return slice.clone(k.item, allocator), os_services.SECRET_OK
	}
	return nil, os_services.SECRET_NOT_FOUND
}

keychain_set :: proc(k: ^Keychain, data: []u8) -> os_services.Status {
	switch &k in k {
	case Os_Keychain:
		return os_services.secret_set(small_str(&k.service), KEYCHAIN_ACCOUNT, data)
	case ^Memory_Keychain:
		sync.guard(&k.mutex)
		delete(k.item, runtime.heap_allocator())
		k.item = slice.clone(data, runtime.heap_allocator())
	}
	return os_services.SECRET_OK
}

keychain_delete :: proc(k: ^Keychain) -> os_services.Status {
	switch &k in k {
	case Os_Keychain:
		return os_services.secret_delete(small_str(&k.service), KEYCHAIN_ACCOUNT)
	case ^Memory_Keychain:
		sync.guard(&k.mutex)
		delete(k.item, runtime.heap_allocator())
		k.item = nil
	}
	return os_services.SECRET_OK
}

// Stored_Auth is what goes in the Keychain item, as JSON.
Stored_Auth :: struct {
	token_type:    string,
	access_token:  string,
	refresh_token: string,
	expiry:        i64, // unix seconds, 0 for none
	session_id:    string,
	country_code:  string,
	locale:        string,
	user_id:       i64,
	is_pkce:       bool,
	client_id:     string, // the client the tokens belong to; refreshes must use it
}

auth_marshal :: proc(a: tidal.Auth, allocator: runtime.Allocator) -> []u8 {
	st := Stored_Auth {
		token_type    = a.token_type,
		access_token  = a.access_token,
		refresh_token = a.refresh_token,
		session_id    = a.session_id,
		country_code  = a.country_code,
		locale        = a.locale,
		user_id       = a.user_id,
		is_pkce       = a.is_pkce,
		client_id     = a.client_id,
	}
	if t, ok := a.expiry_time.?; ok {
		st.expiry = time.to_unix_seconds(t)
	}
	data, _ := json.marshal(st, allocator = allocator)
	return data
}

// auth_restore puts stored login state into the session. False if it holds
// no usable login.
auth_restore :: proc(s: ^tidal.Session, data: []u8) -> bool {
	st: Stored_Auth
	if json.unmarshal(data, &st, allocator = context.temp_allocator) != nil {
		return false
	}
	if st.access_token == "" && st.refresh_token == "" {
		return false
	}
	if st.user_id == 0 {
		return false
	}
	// Items from before the client id was stored go by is_pkce alone. A
	// client this build doesn't know can't refresh; the first request finds
	// out and the login starts over.
	if st.client_id != "" {
		pkce := st.client_id == s.config.client_id_pkce
		if !pkce && st.client_id != s.config.client_id && st.client_id != s.device_client_id {
			log.warn("app: the saved login is for a client this build doesn't know")
		}
		st.is_pkce = pkce
	}
	a := tidal.Auth {
		token_type    = st.token_type,
		access_token  = st.access_token,
		refresh_token = st.refresh_token,
		session_id    = st.session_id,
		country_code  = st.country_code,
		locale        = st.locale,
		is_pkce       = st.is_pkce,
		user_id       = st.user_id,
		user_kind     = .Logged_In_User,
	}
	if st.expiry != 0 {
		a.expiry_time = time.unix(st.expiry, 0)
	}
	tidal.session_restore(s, a)
	return true
}

// auth_load reads the Keychain item into the session. It runs on a worker:
// macOS may ask the user whether this build may read the item, and that
// blocks the caller until they answer.
auth_load :: proc(d: ^Data, res: ^Result) -> bool {
	data, status := keychain_get(&d.keychain, context.temp_allocator)
	if status == os_services.SECRET_NOT_FOUND {
		return false
	}
	if status != os_services.SECRET_OK {
		res.message = small(fmt.tprintf("Couldn't read the Keychain (error %d)", status))
		return false
	}
	return auth_restore(d.session, data)
}

// auth_changed is the session's on_auth_change: after a login or a token
// refresh, on whichever worker did it, the new tokens go to the Keychain.
// TIDAL may rotate the refresh token on refresh, and the old one stops
// working, so this happens every time. Tokens from a login that sign_out
// has cleared since are never saved: with keychain_mutex held, the epoch
// they were read in must still be the session's.
auth_changed :: proc(s: ^tidal.Session, data: rawptr) {
	d := (^Data)(data)
	refresh_gate_open(d)
	a := tidal.session_auth(s, context.temp_allocator)
	if a.user_id == 0 || (a.access_token == "" && a.refresh_token == "") {
		return
	}
	sync.guard(&d.keychain_mutex)
	if a.epoch != tidal.session_epoch(s) {
		return
	}
	bytes := auth_marshal(a, context.temp_allocator)
	if status := keychain_set(&d.keychain, bytes); status != os_services.SECRET_OK {
		log.errorf("app: couldn't save the login to the Keychain (error %d)", status)
	} else {
		d.keychain_saved = a.epoch
	}
}
