package cacert

import "core:strings"
import "core:sync"
import curl "vendor:curl"

@(private = "file")
once: sync.Once
@(private = "file")
found: cstring

// path is the bundle to set as CURLOPT_CAINFO, or nil to keep libcurl's own.
path :: proc() -> cstring {
	sync.once_do(&once, proc() {
		if p := pick(string(curl.version_info(curl.VERSION_NOW).cainfo), BUNDLES); p != "" {
			found = strings.clone_to_cstring(p)
		}
	})
	return found
}
