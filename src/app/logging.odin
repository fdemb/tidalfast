package app

// The app logs through core:log, to stderr:
//
//	[WARN ] --- [12:34:56] [settings.odin:79] app: ... isn't valid settings, using the defaults
//
// Info and up by default. TIDALFAST_LOG_HTTP=1 adds debug, which is mostly
// the TIDAL library: a line per request and its token refreshes.
//
// app_logger builds the logger from globals that log_init fills when the
// dylib loads. Threads the app starts set it in their context; the audio
// player keeps the one it was created with.

import "base:runtime"
import "core:log"
import "core:os"
import "core:terminal"

@(private = "file")
log_data: log.File_Console_Logger_Data

@(private = "file")
log_level: log.Level

@(private = "file")
log_options: log.Options

@(init, private = "file")
log_init :: proc "contextless" () {
	context = runtime.default_context()
	log_data.file_handle = os.stderr
	log_level = .Debug if os.get_env("TIDALFAST_LOG_HTTP", context.temp_allocator) != "" else .Info
	log_options = {.Level, .Time, .Short_File_Path, .Line}
	if terminal.is_terminal(os.stderr) {
		log_options += {.Terminal_Color}
	}
}

app_logger :: proc() -> log.Logger {
	return {log.file_logger_proc, &log_data, log_level, log_options}
}
