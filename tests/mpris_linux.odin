package tidal_tests

// The Linux shell's MPRIS server (shell/mpris.c) and the cover's PNG
// (shell/png.c). The server is asked through dbus-send, as a desktop's
// media widget would, on the session bus the tests run in. Without one it
// skips.

import "core:c/libc"
import "core:fmt"
import "core:image/png"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "../src/platform"

@(private = "file")
MPRIS_OBJ :: "../build/shell/mpris.o"
@(private = "file")
PNG_OBJ :: "../build/shell/png.o"

when !#exists(MPRIS_OBJ) || !#exists(PNG_OBJ) {
	#panic("build/shell/mpris.o or png.o is missing: run ./build.py test first")
}

foreign import mpris_c {MPRIS_OBJ, PNG_OBJ, "system:m"}

@(private = "file")
@(default_calling_convention = "c")
foreign mpris_c {
	mpris_init :: proc(command: proc "c" (command: u32, position: f64)) ---
	mpris_set :: proc(np: ^platform.Now_Playing) ---
	mpris_fd :: proc(events: ^i16) -> i32 ---
	mpris_dispatch :: proc(revents: i16) ---
	mpris_close :: proc() ---
	mpris_name :: proc() -> cstring ---
	png_encode :: proc(rgba: [^]u8, width, height: u32, size: ^uint) -> [^]u8 ---
}

@(private = "file")
Command :: struct {
	command:  platform.Media_Command,
	position: f64,
}

@(private = "file")
commands: [16]Command
@(private = "file")
command_count: int

@(private = "file")
record_command :: proc "c" (command: u32, position: f64) {
	if command_count < len(commands) {
		commands[command_count] = {platform.Media_Command(command), position}
		command_count += 1
	}
}

// pump answers the bus for up to seconds, or until done says so.
@(private = "file")
pump :: proc(seconds: f64, done: proc() -> bool = nil) {
	deadline := time.tick_now()
	for time.duration_seconds(time.tick_since(deadline)) < seconds {
		if done != nil && done() {
			return
		}
		events: i16
		fd := mpris_fd(&events)
		if fd < 0 {
			time.sleep(10 * time.Millisecond)
			continue
		}
		p := posix.pollfd {
			fd     = posix.FD(fd),
			events = transmute(posix.Poll_Event)events,
		}
		if posix.poll(&p, 1, 10) > 0 {
			mpris_dispatch(transmute(i16)p.revents)
		}
	}
}

// ask runs dbus-send against the server while answering it, and returns
// what it printed.
@(private = "file")
ask :: proc(t: ^testing.T, args: ..string) -> string {
	out_path := fmt.tprintf("/tmp/tidalfast-mpris-test-%d.out", posix.getpid())
	defer os.remove(out_path)
	out, err := os.create(out_path)
	if !testing.expect(t, err == nil, "can't make dbus-send's output file") {
		return ""
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "dbus-send", "--session", "--print-reply", fmt.tprintf("--dest=%s", string(mpris_name())))
	append(&command, ..args)
	p, perr := os.process_start({command = command[:], stdout = out, stderr = out})
	os.close(out)
	if !testing.expectf(t, perr == nil, "dbus-send didn't start: %v", perr) {
		return ""
	}
	for i := 0; ; i += 1 {
		pump(0.02)
		state, werr := os.process_wait(p, 0)
		if werr == nil && state.exited {
			break
		}
		if i > 500 {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
			testing.fail_now(t, "dbus-send didn't finish")
		}
	}
	data, _ := os.read_entire_file(out_path, context.temp_allocator)
	return string(data)
}

@(private = "file")
get :: proc(t: ^testing.T, property: string) -> string {
	return ask(t, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties.Get", "string:org.mpris.MediaPlayer2.Player", fmt.tprintf("string:%s", property))
}

@(private = "file")
named :: proc() -> bool {
	return mpris_name() != nil
}

@(test)
test_mpris_answers_a_media_widget :: proc(t: ^testing.T) {
	if os.get_env("DBUS_SESSION_BUS_ADDRESS", context.temp_allocator) == "" {
		fmt.println("mpris: no session bus, skipped")
		return
	}
	command_count = 0
	mpris_init(record_command)
	defer mpris_close()
	art := [4][4]u8{{200, 100, 0, 255}, {0, 0, 0, 255}, {0, 0, 0, 255}, {0, 0, 0, 255}}
	np := platform.Now_Playing {
		title          = "Jóga",
		artist         = "Björk",
		album          = "Homogenic",
		duration       = 300,
		elapsed        = 10,
		state          = .Playing,
		artwork        = &art[0][0],
		artwork_width  = 2,
		artwork_height = 2,
		artwork_key    = 7,
	}
	mpris_set(&np)
	pump(5, named)
	if !testing.expect(t, mpris_name() != nil, "no bus name") {
		return
	}

	testing.expect(t, strings.contains(get(t, "PlaybackStatus"), `"Playing"`))
	meta := get(t, "Metadata")
	testing.expectf(t, strings.contains(meta, `"Jóga"`) && strings.contains(meta, `"Björk"`) && strings.contains(meta, `"Homogenic"`), "metadata: %s", meta)
	testing.expectf(t, strings.contains(meta, "int64 300000000"), "length: %s", meta)
	testing.expectf(t, strings.contains(meta, `"/com/tidalfast/track/1"`), "track id: %s", meta)

	// The cover is a PNG file the metadata points to.
	url_at := strings.index(meta, "file://")
	if testing.expectf(t, url_at >= 0, "no artUrl: %s", meta) {
		path := meta[url_at + len("file://"):]
		path = path[:strings.index_byte(path, '"')]
		data, ok := os.read_entire_file(path, context.temp_allocator)
		if testing.expectf(t, ok == nil, "can't read %s", path) {
			img, err := png.load_from_bytes(data, allocator = context.temp_allocator)
			if testing.expectf(t, err == nil, "the cover isn't a PNG: %v", err) {
				testing.expect_value(t, img.width, 2)
				testing.expect_value(t, img.channels, 4)
				testing.expect_value(t, img.pixels[0], 200)
				testing.expect_value(t, img.pixels[1], 100)
			}
		}
	}

	ask(t, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player.PlayPause")
	ask(t, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player.Next")
	ask(t, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player.SetPosition", "objpath:/com/tidalfast/track/1", "int64:42000000")
	// Another track's position, and one past the end, are ignored.
	ask(t, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player.SetPosition", "objpath:/com/tidalfast/track/9", "int64:42000000")
	ask(t, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player.SetPosition", "objpath:/com/tidalfast/track/1", "int64:400000000")
	ask(t, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player.Seek", "int64:-5000000")
	if testing.expect_value(t, command_count, 4) {
		testing.expect_value(t, commands[0].command, platform.Media_Command.Toggle)
		testing.expect_value(t, commands[1].command, platform.Media_Command.Next)
		testing.expect_value(t, commands[2], Command{.Seek, 42})
		// 10 s in, playing for the time the asks took, then 5 s back.
		testing.expect_value(t, commands[3].command, platform.Media_Command.Seek)
		testing.expectf(t, commands[3].position >= 5 && commands[3].position < 8, "seek -5 s went to %v", commands[3].position)
	}

	np.state = .Paused
	mpris_set(&np)
	testing.expect(t, strings.contains(get(t, "PlaybackStatus"), `"Paused"`))
	pos := get(t, "Position")
	testing.expectf(t, strings.contains(pos, "int64 10000000"), "a paused position stays: %s", pos)

	none: platform.Now_Playing
	mpris_set(&none)
	testing.expect(t, strings.contains(get(t, "PlaybackStatus"), `"Stopped"`))
	testing.expect(t, strings.contains(get(t, "Metadata"), "/org/mpris/MediaPlayer2/TrackList/NoTrack"))
}

@(test)
test_png_unpremultiplies_the_cover :: proc(t: ^testing.T) {
	// Premultiplied half-transparent orange, and a fully transparent pixel.
	pixels := [8]u8{128, 64, 0, 128, 0, 0, 0, 0}
	size: uint
	data := png_encode(&pixels[0], 2, 1, &size)
	defer libc.free(data)
	img, err := png.load_from_bytes(data[:size], allocator = context.temp_allocator)
	if !testing.expectf(t, err == nil, "not a PNG: %v", err) {
		return
	}
	testing.expect_value(t, img.width, 2)
	testing.expect_value(t, img.height, 1)
	testing.expect_value(t, img.depth, 8)
	got: [8]u8
	copy(got[:], img.pixels[:])
	testing.expect_value(t, got, [8]u8{255, 128, 0, 128, 0, 0, 0, 0})
}
