package render

import "core:log"
import vk "vendor:vulkan"

import "../platform"

foreign import vulkan "system:vulkan"

@(default_calling_convention = "c")
foreign vulkan {
	vkGetInstanceProcAddr :: proc(instance: vk.Instance, name: cstring) -> rawptr ---
}

VULKAN_SURFACE_EXTENSION :: "VK_KHR_wayland_surface"

// The shell's frame callbacks pace animation here, not the present.
VULKAN_MAILBOX :: true

VERTEX_SPIRV :: #load("../../build/shaders/rect.vert.spv")
FRAGMENT_SPIRV :: #load("../../build/shaders/rect.frag.spv")
BLUR_VERTEX_SPIRV :: #load("../../build/shaders/blur.vert.spv")
BLUR_DOWN_SPIRV :: #load("../../build/shaders/blur_down.frag.spv")
BLUR_UP_SPIRV :: #load("../../build/shaders/blur_up.frag.spv")

BACKDROPS :: true

// Vulkan is the only backend on Linux, so what render.odin calls is its.
Gpu :: struct {
	vulkan: Vulkan_Gpu,
}

Gpu_Texture :: struct {
	vulkan: Vulkan_Texture,
}

init :: vulkan_init
destroy :: vulkan_destroy
release :: vulkan_release
end_frame :: vulkan_end_frame
gpu_allocated :: vulkan_allocated
gpu_memory :: vulkan_memory
gpu_texture_bytes :: vulkan_texture_bytes
new_texture_slot :: vulkan_new_texture_slot
gpu_texture_free :: vulkan_texture_free
gpu_texture_write :: vulkan_texture_write
gpu_texture_copy :: vulkan_texture_copy
gpu_frame_begin :: vulkan_frame_begin
grow_instances :: vulkan_grow_instances

// The app links the Vulkan loader on Linux; the AppImage leaves it to the
// system, with the GPU's drivers.
@(private)
vulkan_loader :: proc() -> rawptr {
	return rawptr(vkGetInstanceProcAddr)
}

// The shell's surface is a platform.Wayland_Surface.
@(private)
vulkan_surface_valid :: proc(surface: rawptr) -> bool {
	ws := (^platform.Wayland_Surface)(surface)
	if ws == nil || ws.display == nil || ws.surface == nil {
		log.error("render: no Wayland surface")
		return false
	}
	return true
}

@(private)
vulkan_surface_create :: proc(instance: vk.Instance, surface: rawptr, out: ^vk.SurfaceKHR) -> vk.Result {
	ws := (^platform.Wayland_Surface)(surface)
	info := vk.WaylandSurfaceCreateInfoKHR {
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(ws.display),
		surface = (^vk.wl_surface)(ws.surface),
	}
	return vk.CreateWaylandSurfaceKHR(instance, &info, nil, out)
}
