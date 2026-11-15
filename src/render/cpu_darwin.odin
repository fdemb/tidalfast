// The CPU rasterizer on macOS. The shell gives a plain CALayer in place of
// a CAMetalLayer when TIDALFAST_RENDER=cpu. Frames draw into IOSurfaces
// that become the layer's contents, so the window server reads the pixels
// where they were drawn. Each surface keeps the hashes of the tiles it
// holds, so a frame redraws only what changed since that surface was last
// drawn.
package render

import "core:math"
import "core:mem"
import "core:time"

foreign import iosurface "system:IOSurface.framework"
foreign import corefoundation "system:CoreFoundation.framework"
foreign import coregraphics "system:CoreGraphics.framework"

@(default_calling_convention = "c")
foreign iosurface {
	IOSurfaceCreate :: proc(properties: id) -> rawptr ---
	IOSurfaceLock :: proc(surface: rawptr, options: u32, seed: ^u32) -> i32 ---
	IOSurfaceUnlock :: proc(surface: rawptr, options: u32, seed: ^u32) -> i32 ---
	IOSurfaceGetBaseAddress :: proc(surface: rawptr) -> rawptr ---
	IOSurfaceGetBytesPerRow :: proc(surface: rawptr) -> uint ---
	IOSurfaceIsInUse :: proc(surface: rawptr) -> b8 ---
	IOSurfaceSetValue :: proc(surface: rawptr, key: id, value: rawptr) ---
}

@(default_calling_convention = "c")
foreign corefoundation {
	CFRelease :: proc(object: rawptr) ---
}

@(default_calling_convention = "c")
foreign coregraphics {
	CGColorSpaceCreateWithName :: proc(name: rawptr) -> rawptr ---
	CGColorSpaceCopyPropertyList :: proc(space: rawptr) -> rawptr ---
	CGColorSpaceRelease :: proc(space: rawptr) ---
}

CPU_SURFACES :: 3

Cpu_Surface :: struct {
	ref:           rawptr, // IOSurfaceRef
	width, height: int,
	hashes:        []u64,
}

// cpu_mode says whether layer is the shell's plain CALayer.
cpu_mode :: proc(layer: id) -> bool {
	return !msg_proc(proc "c" (id, SEL, SEL) -> bool)(layer, sel_registerName("respondsToSelector:"), sel_registerName("nextDrawable"))
}

cpu_darwin_init :: proc(r: ^Renderer) {
	g := &r.gpu
	g.cpu = new(Cpu, cpu_allocator())
	cpu_init(g.cpu)
	g.shown = -1
	r.textures[0] = cpu_texture_slot(1, 1, .RGBA8, false)
	white := [4]u8{255, 255, 255, 255}
	texture_update(r, 0, white[:], 0, 0, 1, 1)
}

cpu_darwin_destroy :: proc(r: ^Renderer) {
	g := &r.gpu
	msg_id(g.layer, "setContents:", nil)
	for &s in g.surfaces {
		cpu_surface_free(&s)
	}
	cpu_destroy(g.cpu)
	free(g.cpu, cpu_allocator())
	for &slot in r.textures {
		delete(slot.cpu.pixels, cpu_allocator())
	}
	r^ = {}
}

cpu_surface_free :: proc(s: ^Cpu_Surface) {
	if s.ref != nil {
		CFRelease(s.ref)
	}
	delete(s.hashes, cpu_allocator())
	s^ = {}
}

cpu_surface_bytes :: proc(r: ^Renderer) -> int {
	n := 0
	for s in r.gpu.surfaces {
		if s.ref != nil {
			n += int(IOSurfaceGetBytesPerRow(s.ref)) * s.height
		}
	}
	return n
}

@(private = "file")
cpu_surface_make :: proc(s: ^Cpu_Surface, w, h, tiles: int) -> bool {
	cpu_surface_free(s)
	number :: proc(v: int) -> id {
		return msg_proc(proc "c" (id, SEL, i32) -> id)(objc_getClass("NSNumber"), sel_registerName("numberWithInt:"), i32(v))
	}
	props := msg(objc_getClass("NSMutableDictionary"), "dictionary")
	set :: proc(d: id, key: cstring, value: id) {
		msg_proc(proc "c" (id, SEL, id, id))(d, sel_registerName("setObject:forKey:"), value, ns_string(string(key)))
	}
	set(props, "IOSurfaceWidth", number(w))
	set(props, "IOSurfaceHeight", number(h))
	set(props, "IOSurfaceBytesPerElement", number(4))
	set(props, "IOSurfacePixelFormat", number(0x42475241)) // 'BGRA'
	s.ref = IOSurfaceCreate(props)
	if s.ref == nil {
		return false
	}
	// kCGColorSpaceSRGB is this string, and the text package already
	// declares the constant itself.
	space := CGColorSpaceCreateWithName(ns_string("kCGColorSpaceSRGB"))
	list := CGColorSpaceCopyPropertyList(space)
	IOSurfaceSetValue(s.ref, ns_string("IOSurfaceColorSpace"), list)
	CFRelease(list)
	CGColorSpaceRelease(space)
	s.width, s.height = w, h
	s.hashes = make([]u64, tiles, cpu_allocator())
	return true
}

// cpu_pick returns a surface of w by h the window server isn't reading,
// making one if it must, and frees any of another size.
@(private = "file")
cpu_pick :: proc(r: ^Renderer, w, h, tiles: int) -> int {
	g := &r.gpu
	pick := -1
	for &s, i in g.surfaces {
		if i == g.shown || s.ref == nil {
			continue
		}
		busy := bool(IOSurfaceIsInUse(s.ref))
		if s.width != w || s.height != h {
			if !busy {
				cpu_surface_free(&s)
			}
		} else if !busy && pick < 0 {
			pick = i
		}
	}
	if pick >= 0 {
		return pick
	}
	for &s, i in g.surfaces {
		if i != g.shown && s.ref == nil {
			return i if cpu_surface_make(&s, w, h, tiles) else -1
		}
	}
	// Every surface is busy: draw into one anyway rather than wait.
	for &s, i in g.surfaces {
		if i != g.shown {
			if s.width != w || s.height != h {
				return i if cpu_surface_make(&s, w, h, tiles) else -1
			}
			return i
		}
	}
	return -1
}

cpu_darwin_end_frame :: proc(r: ^Renderer) {
	g := &r.gpu
	c := g.cpu
	defer r.frame_index += 1
	r.stats = {0, r.instance_count}
	if r.width <= 0 || r.height <= 0 {
		return
	}
	parked := msg_proc(proc "c" (id, SEL) -> bool)(msg_id(g.layer, "valueForKey:", ns_string("tidalfastParked")), sel_registerName("boolValue"))
	if parked && r.capture_path == "" {
		for &s, i in g.surfaces {
			if i != g.shown || g.shown < 0 {
				cpu_surface_free(&s)
			}
		}
		if g.shown >= 0 {
			cpu_surface_free(&g.surfaces[g.shown])
			g.shown = -1
		}
		g.shown_hash = 0
		r.hidden = true
		r.poll_after = 0
		return
	}
	r.hidden = false

	start := time.tick_now()
	w := int(math.round(r.width * r.scale))
	h := int(math.round(r.height * r.scale))
	tiles := ((w + CPU_TILE - 1) / CPU_TILE) * ((h + CPU_TILE - 1) / CPU_TILE)
	i := cpu_pick(r, w, h, tiles)
	if i < 0 {
		return
	}
	s := &g.surfaces[i]
	IOSurfaceLock(s.ref, 0, nil)
	target := Cpu_Target {
		pixels = ([^]u8)(IOSurfaceGetBaseAddress(s.ref)),
		stride = int(IOSurfaceGetBytesPerRow(s.ref)),
		width  = w,
		height = h,
		hashes = s.hashes,
	}
	drawn, frame_hash := cpu_render(r, c, target)
	if r.capture_path != "" {
		pixels := make([]byte, w * h * 4, context.temp_allocator)
		for y in 0 ..< h {
			mem.copy(&pixels[y * w * 4], &target.pixels[y * target.stride], w * 4)
		}
		write_tga(r.capture_path, pixels, uint(w), uint(h))
	}
	IOSurfaceUnlock(s.ref, 0, nil)

	if frame_hash != g.shown_hash || g.shown < 0 {
		transaction := objc_getClass("CATransaction")
		msg(transaction, "begin")
		msg_bool(transaction, "setDisableActions:", true)
		msg_id(g.layer, "setContents:", s.ref)
		msg(transaction, "commit")
		g.shown = i
		g.shown_hash = frame_hash
	}
	r.stats.draw_calls = drawn
	r.gpu_ms = cpu_elapsed_ms(start)
}
