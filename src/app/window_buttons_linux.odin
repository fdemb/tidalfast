package app

import "base:runtime"
import "core:mem"
import "core:sync"

import "../os_services"
import "../platform"
import "../sys"

// window_layout_poll reads GNOME's button layout once a launch, on a
// thread of its own, the first frame the window has the app's buttons,
// and keeps it in the settings when it came back different.
window_layout_poll :: proc(s: ^State, shell: ^platform.Shell) {
	rd := &s.window.read
	if s.window.shown && !rd.started && !rd.taken {
		rd.wake = shell.request_redraw
		rd.started = sys.thread_start(&rd.thread, read_layout, rd)
		rd.taken = !rd.started
	}
	if !rd.started || rd.taken || !sync.atomic_load(&rd.done) {
		return
	}
	rd.taken = true
	sys.thread_join(rd.thread)
	if !rd.ok {
		return
	}
	l := button_layout_parse(string(rd.text[:rd.text_len]))
	if old, has := s.settings.button_layout.?; !has || old != l {
		s.settings.button_layout = l
		settings_queue(&s.data, settings_to_save(s))
	}
}

@(private = "file")
read_layout :: proc "c" (arg: rawptr) -> rawptr {
	context = runtime.default_context()
	buf: [16 << 10]u8
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	context.allocator = mem.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	rd := (^Layout_Read)(arg)
	if value, ok := os_services.portal_setting_string("org.gnome.desktop.wm.preferences", "button-layout"); ok && len(value) <= len(rd.text) {
		rd.text_len = copy(rd.text[:], value)
		rd.ok = true
	}
	sync.atomic_store(&rd.done, true)
	rd.wake()
	return nil
}
