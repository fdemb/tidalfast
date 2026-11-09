package app

import "core:log"
import "core:os"
import "core:strings"
import win "core:sys/windows"

import "../os_services"

// A release build has the windows subsystem, so a launch from Explorer or
// the Start menu has no stderr and the log would go nowhere. It goes to
// %LOCALAPPDATA%\tidalfast\tidalfast.log instead, and the last launch's
// is kept as tidalfast.old.log. The shell appends its own lines to the
// same file (log_to_file in shell_win32.c), after this has opened it.

@(private = "file")
has_stderr :: proc "contextless" () -> bool {
	h := win.GetStdHandle(win.STD_ERROR_HANDLE)
	return h != nil && h != win.INVALID_HANDLE_VALUE
}

// log_file is where the log goes without stderr, "" when Windows names no
// folder for it.
@(private = "file")
log_file :: proc(old := false) -> string {
	dir := os_services.cache_dir(context.temp_allocator)
	if dir == "" {
		return ""
	}
	name := "tidalfast.old.log" if old else "tidalfast.log"
	return strings.concatenate({dir, "/tidalfast/", name}, context.temp_allocator)
}

// log_to_file points data at the log file when there's no stderr, and
// says whether it did. Both the app and the shell append, so neither
// writes over the other's lines.
log_to_file :: proc(data: ^log.File_Console_Logger_Data) -> bool {
	if has_stderr() {
		return false
	}
	path := log_file()
	if path == "" {
		return false
	}
	dir, _ := os.split_path(path)
	_ = os.make_directory_all(dir)
	// Once: while another copy of the app has the log open, Windows refuses,
	// and this launch adds to its log.
	from := win.utf8_to_wstring(path, context.temp_allocator)
	to := win.utf8_to_wstring(log_file(old = true), context.temp_allocator)
	_ = win.MoveFileExW(from, to, win.MOVEFILE_REPLACE_EXISTING)
	f, err := os.open(path, {.Write, .Create, .Append})
	if err != nil {
		return false
	}
	data.file_handle = f
	return true
}

// show_fatal shows an error the app can't work after in a message box,
// when there's no console to see the log in.
show_fatal :: proc(message: string) {
	if has_stderr() {
		return
	}
	text := message
	if path := log_file(); path != "" {
		shown, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
		text = strings.concatenate({message, "\n\nThe log is in ", shown, "."}, context.temp_allocator)
	}
	MB_ICONERROR :: 0x10
	_ = win.MessageBoxW(nil, win.utf8_to_wstring(text, context.temp_allocator), win.L("TIDALfast"), MB_ICONERROR)
}
