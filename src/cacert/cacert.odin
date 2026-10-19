// Package cacert finds the CA certificates for libcurl on Linux.
//
// libcurl looks for them where the distribution that built it keeps them.
// The AppImage carries Debian's libcurl, which looks for
// /etc/ssl/certs/ca-certificates.crt. openSUSE has no file there, and every
// HTTPS request would fail with CURLE_SSL_CACERT_BADFILE. Set CURLOPT_CAINFO
// to path() on each handle.
package cacert

import "core:os"

BUNDLES :: []string {
	"/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Arch
	"/etc/pki/tls/certs/ca-bundle.crt", // Fedora, RHEL without the Debian link
	"/etc/ssl/ca-bundle.pem", // openSUSE
	"/etc/ssl/cert.pem", // Alpine, Void
}

// pick returns "" when builtin, libcurl's own bundle, exists or libcurl has
// none, else the first of bundles that exists.
pick :: proc(builtin: string, bundles: []string) -> string {
	if builtin == "" || os.exists(builtin) {
		return ""
	}
	for b in bundles {
		if os.exists(b) {
			return b
		}
	}
	return ""
}
