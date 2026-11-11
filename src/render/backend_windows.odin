// Windows has two backends, both compiled in. The renderer picks one when
// it starts: Direct3D 11 unless TIDALFAST_RENDERER=vulkan says otherwise.
// Vulkan is for comparing the two. Nothing of it loads unless it's picked,
// so the default keeps Direct3D 11's footprint (docs/windows.md).
package render

import "core:log"
import "core:os"

BACKDROPS :: true

Backend :: enum u8 {
	D3D11,
	Vulkan,
}

Gpu :: struct {
	backend: Backend,
	d3d:     D3d11_Gpu,
	vulkan:  Vulkan_Gpu,
}

Gpu_Texture :: struct #raw_union {
	d3d:    D3d11_Texture,
	vulkan: Vulkan_Texture,
}

// backend_from_name reads the value of TIDALFAST_RENDERER. known is false
// for anything but the empty string and the backends' names.
backend_from_name :: proc(name: string) -> (backend: Backend, known: bool) {
	switch name {
	case "", "d3d11":
		return .D3D11, true
	case "vulkan":
		return .Vulkan, true
	}
	return .D3D11, false
}

init :: proc(r: ^Renderer, surface: rawptr) -> bool {
	name := os.get_env("TIDALFAST_RENDERER", context.temp_allocator)
	backend, known := backend_from_name(name)
	if !known {
		log.warnf("render: TIDALFAST_RENDERER is %q, not d3d11 or vulkan; using Direct3D 11", name)
	}
	return init_backend(r, surface, backend)
}

// init_backend is init with the backend already picked. A backend that
// can't start draws nothing, like any failed init, rather than falling back
// to the other: a comparison that silently ran the other one would mislead.
init_backend :: proc(r: ^Renderer, surface: rawptr, backend: Backend) -> bool {
	r.gpu.backend = backend
	switch backend {
	case .D3D11:
		return d3d11_init(r, surface)
	case .Vulkan:
		return vulkan_init(r, surface)
	}
	return false
}

destroy :: proc(r: ^Renderer) {
	switch r.gpu.backend {
	case .D3D11:
		d3d11_destroy(r)
	case .Vulkan:
		vulkan_destroy(r)
	}
}

release :: proc(r: ^Renderer) {
	switch r.gpu.backend {
	case .D3D11:
		d3d11_release(r)
	case .Vulkan:
		vulkan_release(r)
	}
}

end_frame :: proc(r: ^Renderer) {
	switch r.gpu.backend {
	case .D3D11:
		d3d11_end_frame(r)
	case .Vulkan:
		vulkan_end_frame(r)
	}
}

gpu_allocated :: proc "contextless" (r: ^Renderer) -> int {
	if r.gpu.backend == .Vulkan {
		return vulkan_allocated(r)
	}
	return d3d11_allocated(r)
}

gpu_memory :: proc(r: ^Renderer) -> Gpu_Memory {
	if r.gpu.backend == .Vulkan {
		return vulkan_memory(r)
	}
	return d3d11_memory(r)
}

@(private)
gpu_texture_bytes :: proc(r: ^Renderer, slot: ^Texture_Slot) -> int {
	if r.gpu.backend == .Vulkan {
		return vulkan_texture_bytes(r, slot)
	}
	return d3d11_texture_bytes(r, slot)
}

@(private)
new_texture_slot :: proc(r: ^Renderer, width, height: int, format: Texture_Format, mipmapped: bool) -> Texture_Slot {
	if r.gpu.backend == .Vulkan {
		return vulkan_new_texture_slot(r, width, height, format, mipmapped)
	}
	return d3d11_new_texture_slot(r, width, height, format, mipmapped)
}

@(private)
gpu_texture_free :: proc(r: ^Renderer, t: Gpu_Texture) {
	if r.gpu.backend == .Vulkan {
		vulkan_texture_free(r, t)
	} else {
		d3d11_texture_free(r, t)
	}
}

@(private)
gpu_texture_write :: proc(r: ^Renderer, slot: ^Texture_Slot, pixels: []byte, x, y, w, h, bpp: int) {
	if r.gpu.backend == .Vulkan {
		vulkan_texture_write(r, slot, pixels, x, y, w, h, bpp)
	} else {
		d3d11_texture_write(r, slot, pixels, x, y, w, h, bpp)
	}
}

@(private)
gpu_texture_copy :: proc(r: ^Renderer, from, to: ^Texture_Slot, w, h: int) {
	if r.gpu.backend == .Vulkan {
		vulkan_texture_copy(r, from, to, w, h)
	} else {
		d3d11_texture_copy(r, from, to, w, h)
	}
}

@(private)
gpu_frame_begin :: proc(r: ^Renderer) -> [^]Instance {
	if r.gpu.backend == .Vulkan {
		return vulkan_frame_begin(r)
	}
	return d3d11_frame_begin(r)
}

@(private)
grow_instances :: proc(r: ^Renderer) {
	if r.gpu.backend == .Vulkan {
		vulkan_grow_instances(r)
	} else {
		d3d11_grow_instances(r)
	}
}
