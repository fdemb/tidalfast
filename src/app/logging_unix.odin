#+build linux, darwin
package app

import "core:log"

// log_to_file leaves the log on stderr, which macOS and Linux always give.
log_to_file :: proc(data: ^log.File_Console_Logger_Data) -> bool {
	return false
}

// show_fatal shows nothing more than the log, which the app has already
// written the error to.
show_fatal :: proc(message: string) {}
