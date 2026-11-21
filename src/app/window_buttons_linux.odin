package app

import "base:runtime"
import "core:mem"

import "../os_services"
import "../platform"
import "../sys"

// window_layout_poll starts the thread that reads GNOME's button layout,
// the first frame the window has the app's buttons, and takes each layout
// it gives: the one read at the start and any the portal later says the
// user chose. A new one goes in the settings, which this frame's buttons
// follow. Only GNOME's desktops use it (gnome_desktop).
window_layout_poll :: proc(s: ^State, shell: ^platform.Shell) {
	rd := &s.window.read
	if !gnome_desktop(s.window.desktop) {
		return
	}
	if s.window.shown && !rd.started {
		rd.wake = shell.request_redraw
		rd.started = true
		if !sys.thread_start(&rd.thread, watch_layout, rd) {
			return
		}
	}
	buf: [len(rd.text)]u8
	if text, ok := layout_read_take(rd, buf[:]); ok {
		l := button_layout_parse(text)
		if old, has := s.settings.button_layout.?; !has || old != l {
			s.settings.button_layout = l
			settings_queue(&s.data, settings_to_save(s))
		}
	}
}

// watch_layout runs for as long as the session bus is there, blocked on
// its socket between changes, and is never joined.
@(private = "file")
watch_layout :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	buf: [16 << 10]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	context.allocator = mem.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	given :: proc(value: string, user: rawptr) {
		layout_read_give((^Layout_Read)(user), value)
	}
	os_services.portal_setting_watch("org.gnome.desktop.wm.preferences", "button-layout", given, arg)
	return nil
}
