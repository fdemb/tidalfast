#+build darwin
// Shows what CoreAudio does with the output devices, like pw-top on
// PipeWire: each output device's nominal rate, buffer size, physical and
// virtual formats and hog owner, and the processes sending or recording
// audio and on which devices. It only reads properties, so it never
// changes a device.
//
//     odin build tools/audio_top -out:build/audio_top
//     ./build/audio_top                    refreshes every 500 ms
//     ./build/audio_top -once              prints one snapshot
//     ./build/audio_top -log -interval=2   a line per change, polled every 2 ms
//
// The process list needs macOS 14 (kAudioHardwarePropertyProcessObjectList).
// CoreAudio doesn't say whether it resamples or mixes a stream. The track
// reaches the device unchanged when the device's rate is the track's, the
// physical format holds its bits and no other process sends output to it.
package audio_top

import "core:flags"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

Options :: struct {
	interval: int `usage:"milliseconds between reads (default 500)"`,
	once:     bool `usage:"print one snapshot and quit"`,
	log:      bool `usage:"print a timestamped line for each change instead of the table"`,
	all:      bool `usage:"list every process CoreAudio knows, not only those doing audio"`,
}

foreign import CoreAudio "system:CoreAudio.framework"
foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import libc "system:System"

Audio_Object_ID :: u32
OS_Status :: i32

Property_Address :: struct {
	selector: u32,
	scope:    u32,
	element:  u32,
}

// AudioStreamBasicDescription
Stream_Description :: struct {
	sample_rate:       f64,
	format_id:         u32,
	format_flags:      u32,
	bytes_per_packet:  u32,
	frames_per_packet: u32,
	bytes_per_frame:   u32,
	channels:          u32,
	bits:              u32,
	reserved:          u32,
}

FLAG_FLOAT :: 1 << 0
FLAG_NON_INTERLEAVED :: 1 << 5
FLAG_NON_MIXABLE :: 1 << 6

fourcc :: proc "contextless" (s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

SYSTEM_OBJECT :: 1
ELEMENT_MAIN :: 0
SCOPE_GLOBAL := fourcc("glob")
SCOPE_OUTPUT := fourcc("outp")
SCOPE_INPUT := fourcc("inpt")

PROP_DEFAULT_OUTPUT := fourcc("dOut")
PROP_DEVICES := fourcc("dev#")
PROP_PROCESSES := fourcc("prs#")
PROP_NAME := fourcc("lnam")
PROP_UID := fourcc("uid ")
PROP_NOMINAL_RATE := fourcc("nsrt")
PROP_BUFFER_FRAMES := fourcc("fsiz")
PROP_RUNNING_SOMEWHERE := fourcc("gone")
PROP_HOG_MODE := fourcc("oink")
PROP_STREAMS := fourcc("stm#")
PROP_PHYSICAL_FORMAT := fourcc("pft ")
PROP_VIRTUAL_FORMAT := fourcc("sfmt")
PROP_PROCESS_PID := fourcc("ppid")
PROP_PROCESS_BUNDLE := fourcc("pbid")
PROP_PROCESS_DEVICES := fourcc("pdv#")
PROP_PROCESS_RUNNING_OUTPUT := fourcc("piro")
PROP_PROCESS_RUNNING_INPUT := fourcc("piri")

@(default_calling_convention = "c")
foreign CoreAudio {
	AudioObjectGetPropertyDataSize :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32) -> OS_Status ---
	AudioObjectGetPropertyData :: proc(id: Audio_Object_ID, addr: ^Property_Address, qualifier_size: u32, qualifier: rawptr, size: ^u32, data: rawptr) -> OS_Status ---
}

CF_STRING_ENCODING_UTF8 :: 0x08000100

@(default_calling_convention = "c")
foreign CoreFoundation {
	CFRelease :: proc(cf: rawptr) ---
	CFStringGetCString :: proc(s: rawptr, buffer: [^]u8, size: int, encoding: int) -> b8 ---
}

@(default_calling_convention = "c")
foreign libc {
	proc_name :: proc(pid: posix.pid_t, buffer: [^]u8, size: u32) -> i32 ---
}

get :: proc(id: Audio_Object_ID, selector, scope: u32, out: ^$T) -> bool {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	size := u32(size_of(T))
	return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, out) == 0
}

// get_array reads a property that is an array of T into the temp allocator.
get_array :: proc(id: Audio_Object_ID, selector, scope: u32, $T: typeid) -> []T {
	addr := Property_Address{selector, scope, ELEMENT_MAIN}
	size: u32
	if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) != 0 || size < size_of(T) {
		return nil
	}
	out := make([]T, int(size) / size_of(T), context.temp_allocator)
	if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw_data(out)) != 0 {
		return nil
	}
	return out[:int(size) / size_of(T)]
}

// string_property reads a CFString property into the temp allocator.
string_property :: proc(id: Audio_Object_ID, selector: u32) -> string {
	str: rawptr
	if !get(id, selector, SCOPE_GLOBAL, &str) || str == nil {
		return ""
	}
	defer CFRelease(str)
	buf := make([]u8, 256, context.temp_allocator)
	if !CFStringGetCString(str, raw_data(buf), len(buf), CF_STRING_ENCODING_UTF8) {
		return ""
	}
	return string(cstring(raw_data(buf)))
}

Device :: struct {
	id:          Audio_Object_ID,
	uid:         string,
	name:        string,
	default:     bool,
	rate:        f64,
	buffer:      u32,
	running:     bool, // some process does IO on it
	hog_pid:     posix.pid_t, // -1 for nobody
	physical:    Stream_Description,
	virtual:     Stream_Description,
	has_formats: bool,
}

Process :: struct {
	pid:     posix.pid_t,
	name:    string,
	bundle:  string,
	output:  bool,
	input:   bool,
	devices: []Audio_Object_ID, // the output devices it uses
}

Snapshot :: struct {
	devices:      []Device,
	processes:    []Process,
	has_processes: bool, // the OS has the process list (macOS 14 and up)
}

read_snapshot :: proc(all: bool) -> (s: Snapshot) {
	default_output: Audio_Object_ID
	get(SYSTEM_OBJECT, PROP_DEFAULT_OUTPUT, SCOPE_GLOBAL, &default_output)
	devices := make([dynamic]Device, context.temp_allocator)
	for id in get_array(SYSTEM_OBJECT, PROP_DEVICES, SCOPE_GLOBAL, Audio_Object_ID) {
		streams := get_array(id, PROP_STREAMS, SCOPE_OUTPUT, Audio_Object_ID)
		if len(streams) == 0 {
			continue
		}
		d := Device {
			id      = id,
			uid     = string_property(id, PROP_UID),
			name    = string_property(id, PROP_NAME),
			default = id == default_output,
			hog_pid = -1,
		}
		get(id, PROP_NOMINAL_RATE, SCOPE_GLOBAL, &d.rate)
		get(id, PROP_BUFFER_FRAMES, SCOPE_GLOBAL, &d.buffer)
		get(id, PROP_HOG_MODE, SCOPE_GLOBAL, &d.hog_pid)
		running: u32
		get(id, PROP_RUNNING_SOMEWHERE, SCOPE_GLOBAL, &running)
		d.running = running != 0
		d.has_formats = get(streams[0], PROP_PHYSICAL_FORMAT, SCOPE_GLOBAL, &d.physical)
		d.has_formats &= get(streams[0], PROP_VIRTUAL_FORMAT, SCOPE_GLOBAL, &d.virtual)
		append(&devices, d)
	}
	s.devices = devices[:]

	ids := get_array(SYSTEM_OBJECT, PROP_PROCESSES, SCOPE_GLOBAL, Audio_Object_ID)
	s.has_processes = ids != nil
	processes := make([dynamic]Process, context.temp_allocator)
	for id in ids {
		p: Process
		output, input: u32
		get(id, PROP_PROCESS_RUNNING_OUTPUT, SCOPE_GLOBAL, &output)
		get(id, PROP_PROCESS_RUNNING_INPUT, SCOPE_GLOBAL, &input)
		p.output, p.input = output != 0, input != 0
		if !all && !p.output && !p.input {
			continue
		}
		get(id, PROP_PROCESS_PID, SCOPE_GLOBAL, &p.pid)
		p.bundle = string_property(id, PROP_PROCESS_BUNDLE)
		buf := make([]u8, 256, context.temp_allocator)
		if n := proc_name(p.pid, raw_data(buf), u32(len(buf))); n > 0 {
			p.name = string(buf[:n])
		}
		p.devices = get_array(id, PROP_PROCESS_DEVICES, SCOPE_OUTPUT, Audio_Object_ID)
		append(&processes, p)
	}
	slice.sort_by(processes[:], proc(a, b: Process) -> bool {
		if a.output != b.output {
			return a.output
		}
		return a.pid < b.pid
	})
	s.processes = processes[:]
	return
}

format_text :: proc(f: Stream_Description, rate: f64) -> string {
	b := strings.builder_make(context.temp_allocator)
	if f.format_flags & FLAG_FLOAT != 0 {
		fmt.sbprintf(&b, "%d ch %d-bit float", f.channels, f.bits)
	} else {
		fmt.sbprintf(&b, "%d ch %d-bit int", f.channels, f.bits)
		if f.channels > 0 && f.format_flags & FLAG_NON_INTERLEAVED == 0 {
			if width := f.bytes_per_frame / f.channels * 8; width > f.bits {
				fmt.sbprintf(&b, " in %d", width)
			}
		}
	}
	if f.format_flags & FLAG_NON_MIXABLE != 0 {
		strings.write_string(&b, ", non-mixable")
	}
	if f.sample_rate != rate {
		fmt.sbprintf(&b, " at %.0f Hz", f.sample_rate)
	}
	return strings.to_string(b)
}

device_name :: proc(s: Snapshot, id: Audio_Object_ID) -> string {
	for d in s.devices {
		if d.id == id {
			return d.name
		}
	}
	return fmt.tprintf("#%d", id)
}

process_devices :: proc(s: Snapshot, p: Process) -> string {
	names := make([]string, len(p.devices), context.temp_allocator)
	for id, i in p.devices {
		names[i] = device_name(s, id)
	}
	return strings.join(names, ", ", context.temp_allocator)
}

// cell cuts s to width characters and pads it with spaces to width, on
// the left with right set. fmt's widths count bytes, which misaligns
// device names such as "Głośniki".
cell :: proc(s: string, width: int, right := false) -> string {
	n := strings.rune_count(s)
	if n > width {
		k := 0
		for _, i in s {
			if k == width - 1 {
				return fmt.tprintf("%s…", s[:i])
			}
			k += 1
		}
	}
	pad := strings.repeat(" ", width - n, context.temp_allocator)
	return fmt.tprintf("%s%s", pad, s) if right else fmt.tprintf("%s%s", s, pad)
}

write_table :: proc(b: ^strings.Builder, s: Snapshot, all: bool) {
	fmt.sbprintf(b, "  %s %s %s  %s %s STATE\x1b[K\n", cell("DEVICE", 30), cell("RATE", 7, true), cell("BUFFER", 6, true), cell("PHYSICAL", 28), cell("VIRTUAL", 24))
	for d in s.devices {
		physical, virtual := "?", "?"
		if d.has_formats {
			physical = format_text(d.physical, d.rate)
			virtual = format_text(d.virtual, d.rate)
		}
		state := "running" if d.running else "idle"
		if d.hog_pid != -1 {
			state = fmt.tprintf("%s, hogged by %d", state, d.hog_pid)
		}
		rate, buffer := fmt.tprintf("%.0f", d.rate), fmt.tprint(d.buffer)
		fmt.sbprintf(b, "%s %s %s %s  %s %s %s\x1b[K\n", "*" if d.default else " ", cell(d.name, 30), cell(rate, 7, true), cell(buffer, 6, true), cell(physical, 28), cell(virtual, 24), state)
	}
	strings.write_string(b, "\x1b[K\n")
	if !s.has_processes {
		strings.write_string(b, "The process list needs macOS 14.\x1b[K\n")
		return
	}
	fmt.sbprintf(b, "%s %s %s %s %s BUNDLE\x1b[K\n", cell("PID", 7), cell("PROCESS", 24), cell("OUT", 4), cell("IN", 4), cell("OUTPUT DEVICES", 36))
	for p in s.processes {
		name := p.name if p.name != "" else p.bundle if p.bundle != "" else "?"
		fmt.sbprintf(b, "%s %s %s %s %s %s\x1b[K\n", cell(fmt.tprint(p.pid), 7), cell(name, 24), cell("yes" if p.output else "", 4), cell("yes" if p.input else "", 4), cell(process_devices(s, p), 36), p.bundle)
	}
	if len(s.processes) == 0 {
		strings.write_string(b, "No process sends or records audio.\x1b[K\n" if !all else "No processes.\x1b[K\n")
	}
}

// Last is what -log printed last, kept across reads in the heap.
Last_Device :: struct {
	uid:  string,
	line: string,
}

Last_Process :: struct {
	pid:  posix.pid_t,
	line: string,
}

log_changes :: proc(s: Snapshot, last_devices: ^[dynamic]Last_Device, last_processes: ^[dynamic]Last_Process, first: bool) {
	now := time.now()
	h, m, sec := time.clock_from_time(now)
	stamp := fmt.tprintf("%02d:%02d:%02d.%03d", h, m, sec, now._nsec / 1e6 % 1000)
	for d in s.devices {
		physical := format_text(d.physical, d.rate) if d.has_formats else "?"
		line := fmt.tprintf("%.0f Hz, buffer %d, %s, %s%s%s", d.rate, d.buffer, physical, "running" if d.running else "idle", ", default" if d.default else "", fmt.tprintf(", hogged by %d", d.hog_pid) if d.hog_pid != -1 else "")
		found := false
		for &l in last_devices {
			if l.uid != d.uid {
				continue
			}
			found = true
			if l.line != line {
				fmt.printf("%s  %s: %s\n", stamp, d.name, line)
				delete(l.line)
				l.line = strings.clone(line)
			}
		}
		if !found {
			fmt.printf("%s  %s: %s%s\n", stamp, d.name, line, "" if first else " (new device)")
			append(last_devices, Last_Device{strings.clone(d.uid), strings.clone(line)})
		}
	}
	#reverse for l, i in last_devices {
		gone := true
		for d in s.devices {
			if d.uid == l.uid {
				gone = false
			}
		}
		if gone {
			fmt.printf("%s  device %s gone\n", stamp, l.uid)
			delete(l.uid)
			delete(l.line)
			unordered_remove(last_devices, i)
		}
	}
	for p in s.processes {
		name := p.name if p.name != "" else p.bundle if p.bundle != "" else "?"
		what := "output and input" if p.output && p.input else "output" if p.output else "input" if p.input else "no audio"
		line := fmt.tprintf("%s on %s", what, process_devices(s, p)) if p.output else what
		found := false
		for &l in last_processes {
			if l.pid != p.pid {
				continue
			}
			found = true
			if l.line != line {
				fmt.printf("%s  %s (%d): %s\n", stamp, name, p.pid, line)
				delete(l.line)
				l.line = strings.clone(line)
			}
		}
		if !found {
			fmt.printf("%s  %s (%d): %s\n", stamp, name, p.pid, line)
			append(last_processes, Last_Process{p.pid, strings.clone(line)})
		}
	}
	#reverse for l, i in last_processes {
		gone := true
		for p in s.processes {
			if p.pid == l.pid {
				gone = false
			}
		}
		if gone {
			fmt.printf("%s  pid %d stopped\n", stamp, l.pid)
			delete(l.line)
			unordered_remove(last_processes, i)
		}
	}
}

main :: proc() {
	opt := Options {
		interval = 500,
	}
	flags.parse_or_exit(&opt, os.args, .Unix)
	interval := time.Duration(max(opt.interval, 1)) * time.Millisecond
	tty := posix.isatty(posix.STDOUT_FILENO)

	if tty && !opt.once && !opt.log {
		fmt.print("\x1b[2J")
	}
	last_devices: [dynamic]Last_Device
	last_processes: [dynamic]Last_Process
	for first := true; ; first = false {
		s := read_snapshot(opt.all)
		if opt.log {
			log_changes(s, &last_devices, &last_processes, first)
		} else {
			b := strings.builder_make(context.temp_allocator)
			if tty && !opt.once {
				strings.write_string(&b, "\x1b[H")
			}
			h, m, sec := time.clock_from_time(time.now())
			fmt.sbprintf(&b, "audio_top  %02d:%02d:%02d  every %d ms, * is the default output\x1b[K\n\x1b[K\n", h, m, sec, opt.interval)
			write_table(&b, s, opt.all)
			if tty && !opt.once {
				strings.write_string(&b, "\x1b[J")
			} else {
				strings.write_string(&b, "\n")
			}
			out := strings.to_string(b)
			if !tty || opt.once {
				// No escape codes in a pipe or a one-off snapshot.
				out, _ = strings.remove_all(out, "\x1b[K", context.temp_allocator)
			}
			fmt.print(out)
		}
		free_all(context.temp_allocator)
		if opt.once {
			break
		}
		time.sleep(interval)
	}
}
