package render

import "core:log"
import win "core:sys/windows"
import vk "vendor:vulkan"

import "../platform"

VULKAN_SURFACE_EXTENSION :: "VK_KHR_win32_surface"

// vulkan_loader opens vulkan-1.dll, which the GPU's driver installs, at run
// time. Without it the app starts anyway and draws nothing, as it does
// when Vulkan fails on Linux, and says why in the log.
@(private)
vulkan_loader :: proc() -> rawptr {
	// Overlay layers that games' launchers register (Steam, Epic, GOG,
	// Fossilize) load into every Vulkan process and cost 26 MB here for
	// nothing a music player uses. The user's own setting wins.
	if win.GetEnvironmentVariableW(win.L("VK_LOADER_LAYERS_DISABLE"), nil, 0) == 0 {
		win.SetEnvironmentVariableW(win.L("VK_LOADER_LAYERS_DISABLE"), win.L("~implicit~"))
	}
	lib := win.LoadLibraryW(win.L("vulkan-1.dll"))
	if lib == nil {
		log.error("render: no vulkan-1.dll; install the GPU's driver")
		return nil
	}
	return win.GetProcAddress(lib, "vkGetInstanceProcAddr")
}

// The shell's surface is a platform.Win32_Surface.
@(private)
vulkan_surface_valid :: proc(surface: rawptr) -> bool {
	ws := (^platform.Win32_Surface)(surface)
	if ws == nil || ws.instance == nil || ws.window == nil {
		log.error("render: no window")
		return false
	}
	return true
}

@(private)
vulkan_surface_create :: proc(instance: vk.Instance, surface: rawptr, out: ^vk.SurfaceKHR) -> vk.Result {
	ws := (^platform.Win32_Surface)(surface)
	info := vk.Win32SurfaceCreateInfoKHR {
		sType     = .WIN32_SURFACE_CREATE_INFO_KHR,
		hinstance = vk.HINSTANCE(ws.instance),
		hwnd      = vk.HWND(ws.window),
	}
	return vk.CreateWin32SurfaceKHR(instance, &info, nil, out)
}
