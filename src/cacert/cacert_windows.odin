package cacert

// path is nil: the libcurl Odin ships for Windows uses Schannel, which
// trusts the system's certificate store.
path :: proc() -> cstring {
	return nil
}
