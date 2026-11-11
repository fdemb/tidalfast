#+build windows
package tidal_tests

import win "core:sys/windows"
import "core:testing"

import "../src/platform"
import "../src/render"

// The renderer drawing to a real window that's never shown: Direct3D 11 on
// the GPU or WARP, and Vulkan where the machine has it.

@(private = "file")
Test_Window :: struct {
	surface: platform.Win32_Surface,
	hwnd:    win.HWND,
}

@(private = "file")
open_test_window :: proc(t: ^testing.T) -> (w: ^Test_Window, ok: bool) {
	w = new(Test_Window, context.temp_allocator)
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	class := win.WNDCLASSEXW {
		cbSize        = size_of(win.WNDCLASSEXW),
		lpfnWndProc   = win.DefWindowProcW,
		hInstance     = instance,
		lpszClassName = win.L("tidalfast-render-test"),
	}
	win.RegisterClassExW(&class) // fails harmlessly when another test registered it
	w.hwnd = win.CreateWindowExW(0, win.L("tidalfast-render-test"), win.L("render test"), win.WS_OVERLAPPEDWINDOW, 0, 0, 400, 300, nil, nil, instance, nil)
	if !testing.expect(t, w.hwnd != nil, "no window") {
		return nil, false
	}
	w.surface = {instance = rawptr(instance), window = rawptr(w.hwnd)}
	return w, true
}

@(private = "file")
close_test_window :: proc(w: ^Test_Window) {
	win.DestroyWindow(w.hwnd)
}

@(private = "file")
draw_rects :: proc(r: ^render.Renderer, n: int) {
	render.begin_frame(r, 400, 300, 1, {0.063, 0.063, 0.063, 1})
	for i in 0 ..< n {
		render.push_rect(r, {f32(i % 40) * 10, f32(i / 40 % 30) * 10, 8, 8}, {1, 1, 1, 0.5})
	}
	render.end_frame(r)
}

// A driver update or a GPU reset takes the device away. The renderer
// releases everything, makes a new device at the next frame and moves
// resets on, and every texture made before is gone; the white texture
// behind handle 0 is there again.
@(test)
d3d11_renderer_recovers_from_a_lost_device :: proc(t: ^testing.T) {
	w, ok := open_test_window(t)
	if !ok {
		return
	}
	defer close_test_window(w)
	r := new(render.Renderer, context.temp_allocator)
	defer render.destroy(r)
	if !testing.expect(t, render.init(r, &w.surface), "no Direct3D 11 device") {
		return
	}
	cover_page := render.texture_create(r, 64, 64, .RGBA8)
	draw_rects(r, 10)

	// What the renderer does when present says the device is gone.
	render.release(r)
	r.device_lost = true
	draw_rects(r, 10)
	testing.expect(t, r.gpu.d3d.device != nil)
	testing.expect(t, !r.device_lost)
	testing.expect_value(t, r.device_resets, 1)
	testing.expect_value(t, render.texture_size(r, cover_page), [2]int{})
	testing.expect_value(t, render.texture_size(r, 0), [2]int{1, 1})
	testing.expect_value(t, r.stats.instances, 10)
}

// The frame's instances are built in ordinary memory, which push_glass and
// backdrop_hash read back, and copied to the GPU's buffer once. A frame
// past the array's size grows it and still draws every instance.
@(test)
d3d11_instances_are_built_in_ordinary_memory :: proc(t: ^testing.T) {
	w, ok := open_test_window(t)
	if !ok {
		return
	}
	defer close_test_window(w)
	r := new(render.Renderer, context.temp_allocator)
	defer render.destroy(r)
	if !testing.expect(t, render.init(r, &w.surface), "no Direct3D 11 device") {
		return
	}
	n := render.INITIAL_INSTANCES + 100
	draw_rects(r, n)
	testing.expect(t, rawptr(r.instances) == raw_data(r.gpu.d3d.cpu_instances))
	testing.expect(t, len(r.gpu.d3d.cpu_instances) >= n)
	testing.expect_value(t, r.stats.instances, n)
	testing.expect(t, r.gpu.d3d.instance_bytes >= n * size_of(render.Instance))
}

// A minimized window gives back its buffers, shrunk to a pixel, and gets
// them back at full size when it's restored.
@(test)
d3d11_minimized_window_parks_its_buffers :: proc(t: ^testing.T) {
	w, ok := open_test_window(t)
	if !ok {
		return
	}
	defer close_test_window(w)
	r := new(render.Renderer, context.temp_allocator)
	defer render.destroy(r)
	if !testing.expect(t, render.init(r, &w.surface), "no Direct3D 11 device") {
		return
	}
	draw_rects(r, 10)
	testing.expect_value(t, r.gpu.d3d.extent, [2]u32{400, 300})

	win.ShowWindow(w.hwnd, win.SW_SHOWMINNOACTIVE)
	draw_rects(r, 10)
	testing.expect(t, r.hidden)
	testing.expect(t, r.gpu.d3d.parked)
	testing.expect_value(t, r.gpu.d3d.extent, [2]u32{1, 1})

	win.ShowWindow(w.hwnd, win.SW_RESTORE)
	draw_rects(r, 10)
	testing.expect(t, !r.gpu.d3d.parked)
	testing.expect_value(t, r.gpu.d3d.extent, [2]u32{400, 300})
}

// TIDALFAST_RENDERER picks the backend. Direct3D 11 is the default, and
// what a name it doesn't know gets.
@(test)
renderer_flag_picks_the_backend :: proc(t: ^testing.T) {
	cases := []struct {
		name:    string,
		backend: render.Backend,
		known:   bool,
	} {
		{"", .D3D11, true},
		{"d3d11", .D3D11, true},
		{"vulkan", .Vulkan, true},
		{"metal", .D3D11, false},
	}
	for c in cases {
		backend, known := render.backend_from_name(c.name)
		testing.expect_value(t, backend, c.backend)
		testing.expect_value(t, known, c.known)
	}
}

// Vulkan draws through the same entry points, and a minimized window, which
// has no size for a swapchain, draws nothing and comes back when restored.
@(test)
vulkan_renderer_draws_and_survives_minimizing :: proc(t: ^testing.T) {
	if win.LoadLibraryW(win.L("vulkan-1.dll")) == nil {
		return
	}
	w, ok := open_test_window(t)
	if !ok {
		return
	}
	defer close_test_window(w)
	r := new(render.Renderer, context.temp_allocator)
	defer render.destroy(r)
	if !testing.expect(t, render.init_backend(r, &w.surface, .Vulkan), "no Vulkan device") {
		return
	}
	testing.expect_value(t, r.gpu.backend, render.Backend.Vulkan)
	cover := render.texture_create(r, 64, 64, .RGBA8)
	testing.expect_value(t, render.texture_size(r, cover), [2]int{64, 64})
	testing.expect(t, render.texture_bytes(r, cover) >= 64 * 64 * 4)
	draw_rects(r, 10)
	testing.expect_value(t, r.stats.instances, 10)

	n := render.INITIAL_INSTANCES + 100
	draw_rects(r, n)
	testing.expect_value(t, r.stats.instances, n)

	win.ShowWindow(w.hwnd, win.SW_SHOWMINNOACTIVE)
	for _ in 0 ..< 4 {
		draw_rects(r, 10)
	}

	win.ShowWindow(w.hwnd, win.SW_RESTORE)
	draw_rects(r, 20)
	testing.expect_value(t, r.gpu.vulkan.extent.width, 400 - frame_width(w))
	testing.expect_value(t, r.stats.instances, 20)
}

@(private = "file")
frame_width :: proc(w: ^Test_Window) -> u32 {
	client: win.RECT
	win.GetClientRect(w.hwnd, &client)
	return 400 - u32(client.right - client.left)
}