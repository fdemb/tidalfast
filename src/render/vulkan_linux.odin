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
