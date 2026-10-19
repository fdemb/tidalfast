package cacert

// path is nil: macOS's libcurl uses the system's trust store.
path :: proc() -> cstring {
	return nil
}
