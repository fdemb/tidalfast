// The Vulkan backend, for Linux on Wayland.
//
// The same pipeline as Metal: one instanced quad per rect, the instances in
// a storage buffer per frame slot that both shaders index, a colour and a
// coverage texture bound per batch. The shaders are GLSL in shaders/,
// compiled to SPIR-V by build.sh and #loaded, so they hot reload with the
// dylib.
//
// Metal writes textures straight from the CPU and keeps released objects
// alive until the GPU is done with them; Vulkan does neither. So texture
// writes go through a staging buffer per frame slot and are recorded into
// an upload command buffer that the frame's submit runs first, and
// destroyed textures wait in their slot until its fence says the GPU is
// past them. A slot is touched only after its fence has been waited for
// (slot_ready), which begin_frame does anyway and texture calls between
// frames do too.
//
// Vulkan handles belong to the driver, not the dylib, so they survive a
// reload. The procedure pointers vendor:vulkan keeps are dylib globals, so
// reload loads them again, and rebuilds the pipeline from the new shaders.
package render

import "core:log"
import "core:math"
import "core:mem"
import "core:sync"
import "core:time"
import vk "vendor:vulkan"

import "../platform"

foreign import vulkan "system:vulkan"

@(default_calling_convention = "c")
foreign vulkan {
	vkGetInstanceProcAddr :: proc(instance: vk.Instance, name: cstring) -> rawptr ---
}

MAX_SWAPCHAIN_IMAGES :: 8
MAX_DEAD :: 512 // textures freed in one frame before they wait for the GPU instead
STAGING_START :: 4 << 20
MAX_WRITES :: 64 // images one upload holds as transfer destinations

VERTEX_SPIRV :: #load("../../build/shaders/rect.vert.spv")
FRAGMENT_SPIRV :: #load("../../build/shaders/rect.frag.spv")

Gpu_Frame :: struct {
	cmd:            vk.CommandBuffer,
	upload:         vk.CommandBuffer,
	uploading:      bool, // upload has commands recorded since begin
	fence:          vk.Fence,
	ready:          bool, // the fence was waited for since the last submit
	wait_ms:        f32, // how long that wait took, until begin_frame reports it
	acquired:       vk.Semaphore,
	instances:      Gpu_Buffer,
	set:            vk.DescriptorSet, // the instance buffer and samplers
	staging:        Gpu_Buffer,
	staging_used:   int,
	writes:         [MAX_WRITES]Image_Write,
	write_count:    int,
	dead:           [MAX_DEAD]Gpu_Texture,
	dead_count:     int,
	dead_buffers:   [8]Gpu_Buffer, // staging buffers outgrown this frame
	dead_buffer_count: int,
	capture:        Gpu_Buffer, // the frame's pixels for TIDALFAST_CAPTURE, until end_frame writes them out
}

// An image the slot's upload commands hold as a transfer destination until
// end_writes hands it back to the shaders, so the writes to it between
// share one pair of barriers.
Image_Write :: struct {
	image:         vk.Image,
	levels:        u32,
	width, height: i32,
	written:       [4]i32, // x0 y0 x1 y1 written since the last barrier
}

Gpu_Buffer :: struct {
	buffer:    vk.Buffer,
	memory:    vk.DeviceMemory,
	mapped:    [^]u8,
	size:      int, // what the buffer was made with, all a copy may use
	allocated: int, // bytes of memory behind it, which can be more
}

// Not yet: push_backdrop draws its tint, and the app keeps the player bar
// off the content.
BACKDROPS :: false

Gpu :: struct {
	instance:         vk.Instance,
	physical:         vk.PhysicalDevice,
	device:           vk.Device,
	queue:            vk.Queue,
	queue_family:     u32,
	memory:           vk.PhysicalDeviceMemoryProperties,
	surface:          vk.SurfaceKHR,
	format:           vk.Format,
	swapchain:        vk.SwapchainKHR,
	extent:           vk.Extent2D,
	requested:        vk.Extent2D, // the size asked of make_swapchain, before it clamps; zero makes it again
	image_count:      u32,
	images:           [MAX_SWAPCHAIN_IMAGES]vk.Image,
	views:            [MAX_SWAPCHAIN_IMAGES]vk.ImageView,
	framebuffers:     [MAX_SWAPCHAIN_IMAGES]vk.Framebuffer,
	rendered:         [MAX_SWAPCHAIN_IMAGES]vk.Semaphore, // per image, waited by its present
	render_pass:      vk.RenderPass,
	frame_layout:     vk.DescriptorSetLayout,
	texture_layout:   vk.DescriptorSetLayout,
	pipeline_layout:  vk.PipelineLayout,
	pipeline:         vk.Pipeline,
	samplers:         [2]vk.Sampler, // linear with mips, nearest
	pool:             vk.CommandPool,
	descriptors:      vk.DescriptorPool,
	frames:           [FRAMES_IN_FLIGHT]Gpu_Frame,
	can_capture:      bool, // the swapchain images can be copied from
	allocated:        int, // bytes of device memory; atomic
}

Gpu_Texture :: struct {
	image:  vk.Image,
	view:   vk.ImageView,
	memory: vk.DeviceMemory,
	set:    vk.DescriptorSet,
	size:   int,
	levels: u32,
}

// init draws to surface, a platform.Wayland_Surface. If it fails, it
// tears down what it made, so g.device is nil and the renderer draws
// nothing.
init :: proc(r: ^Renderer, surface: rawptr) -> (ok: bool) {
	g := &r.gpu
	defer if !ok {
		stop(r)
	}
	ws := (^platform.Wayland_Surface)(surface)
	if ws == nil || ws.display == nil || ws.surface == nil {
		log.error("render: no Wayland surface")
		return false
	}
	vk.load_proc_addresses_global(rawptr(vkGetInstanceProcAddr))

	app_info := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "TIDALfast",
		apiVersion       = vk.API_VERSION_1_1,
	}
	extensions := [2]cstring{"VK_KHR_surface", "VK_KHR_wayland_surface"}
	instance_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = len(extensions),
		ppEnabledExtensionNames = &extensions[0],
	}
	if res := vk.CreateInstance(&instance_info, nil, &g.instance); res != .SUCCESS {
		log.errorf("render: vkCreateInstance failed: %v", res)
		return false
	}
	vk.load_proc_addresses_instance(g.instance)

	surface_info := vk.WaylandSurfaceCreateInfoKHR {
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = (^vk.wl_display)(ws.display),
		surface = (^vk.wl_surface)(ws.surface),
	}
	if res := vk.CreateWaylandSurfaceKHR(g.instance, &surface_info, nil, &g.surface); res != .SUCCESS {
		log.errorf("render: vkCreateWaylandSurfaceKHR failed: %v", res)
		return false
	}
	if !pick_device(g) {
		log.error("render: no Vulkan device can draw to the window")
		return false
	}
	priority: f32 = 1
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = g.queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	device_extensions := [1]cstring{"VK_KHR_swapchain"}
	device_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = len(device_extensions),
		ppEnabledExtensionNames = &device_extensions[0],
	}
	if res := vk.CreateDevice(g.physical, &device_info, nil, &g.device); res != .SUCCESS {
		log.errorf("render: vkCreateDevice failed: %v", res)
		return false
	}
	vk.load_proc_addresses_device(g.device)
	vk.GetDeviceQueue(g.device, g.queue_family, 0, &g.queue)
	vk.GetPhysicalDeviceMemoryProperties(g.physical, &g.memory)
	if !pick_format(g) || !make_render_pass(g) || !make_layouts(g) {
		return false
	}

	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = g.queue_family,
	}
	// The frame layout's two immutable samplers count against the pool.
	sizes := [3]vk.DescriptorPoolSize{{.STORAGE_BUFFER, FRAMES_IN_FLIGHT}, {.SAMPLER, 2 * FRAMES_IN_FLIGHT}, {.SAMPLED_IMAGE, MAX_TEXTURES + 1}}
	descriptor_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = MAX_TEXTURES + 1 + FRAMES_IN_FLIGHT,
		poolSizeCount = len(sizes),
		pPoolSizes    = &sizes[0],
	}
	if vk.CreateCommandPool(g.device, &pool_info, nil, &g.pool) != .SUCCESS || vk.CreateDescriptorPool(g.device, &descriptor_info, nil, &g.descriptors) != .SUCCESS {
		log.error("render: can't make the command or descriptor pool")
		return false
	}
	for &f in g.frames {
		buffers: [2]vk.CommandBuffer
		alloc := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = g.pool,
			level              = .PRIMARY,
			commandBufferCount = 2,
		}
		vk.AllocateCommandBuffers(g.device, &alloc, &buffers[0])
		f.cmd, f.upload = buffers[0], buffers[1]
		fence_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		vk.CreateFence(g.device, &fence_info, nil, &f.fence)
		semaphore_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk.CreateSemaphore(g.device, &semaphore_info, nil, &f.acquired)
		set_info := vk.DescriptorSetAllocateInfo {
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = g.descriptors,
			descriptorSetCount = 1,
			pSetLayouts        = &g.frame_layout,
		}
		if vk.AllocateDescriptorSets(g.device, &set_info, &f.set) != .SUCCESS {
			log.error("render: can't allocate the frame descriptor sets")
			return false
		}
	}

	// Slot 0 is the white texture behind the zero handle.
	r.textures[0] = new_texture_slot(r, 1, 1, .RGBA8, false)
	if r.textures[0].width == 0 {
		log.error("render: can't make the white texture")
		return false
	}
	white := [4]u8{255, 255, 255, 255}
	texture_update(r, 0, white[:], 0, 0, 1, 1)
	g.pipeline = build_pipeline(r)
	return g.pipeline != 0
}

// reload loads this dylib's Vulkan procedures and rebuilds the pipeline
// from its shaders. If that fails, the old pipeline stays in place and
// reload returns false.
reload :: proc(r: ^Renderer) -> bool {
	g := &r.gpu
	if g.device == nil {
		return false
	}
	vk.load_proc_addresses_global(rawptr(vkGetInstanceProcAddr))
	vk.load_proc_addresses_instance(g.instance)
	vk.load_proc_addresses_device(g.device)
	pipeline := build_pipeline(r)
	if pipeline == 0 {
		return false
	}
	vk.DeviceWaitIdle(g.device)
	vk.DestroyPipeline(g.device, g.pipeline, nil)
	g.pipeline = pipeline
	return true
}

destroy :: proc(r: ^Renderer) {
	g := &r.gpu
	if g.device != nil {
		vk.DeviceWaitIdle(g.device)
		for &f in g.frames {
			free_dead(r, &f)
			free_buffer(g, &f.instances)
			free_buffer(g, &f.staging)
			free_buffer(g, &f.capture)
			vk.DestroyFence(g.device, f.fence, nil)
			vk.DestroySemaphore(g.device, f.acquired, nil)
		}
		for slot in r.textures {
			if slot.width != 0 {
				free_texture_now(g, slot.gpu)
			}
		}
		destroy_swapchain(g)
		vk.DestroySwapchainKHR(g.device, g.swapchain, nil)
		vk.DestroyPipeline(g.device, g.pipeline, nil)
		vk.DestroyPipelineLayout(g.device, g.pipeline_layout, nil)
		vk.DestroyDescriptorSetLayout(g.device, g.frame_layout, nil)
		vk.DestroyDescriptorSetLayout(g.device, g.texture_layout, nil)
		for s in g.samplers {
			vk.DestroySampler(g.device, s, nil)
		}
		vk.DestroyRenderPass(g.device, g.render_pass, nil)
		vk.DestroyDescriptorPool(g.device, g.descriptors, nil)
		vk.DestroyCommandPool(g.device, g.pool, nil)
		vk.DestroyDevice(g.device, nil)
	}
	if g.instance != nil {
		if g.surface != 0 {
			vk.DestroySurfaceKHR(g.instance, g.surface, nil)
		}
		vk.DestroyInstance(g.instance, nil)
	}
	r^ = {}
}

// stop destroys the renderer after a failure, so g.device is nil and it
// draws nothing, but keeps the capture path the shell set.
@(private)
stop :: proc(r: ^Renderer) {
	path := r.capture_path
	destroy(r)
	r.capture_path = path
}

// gpu_allocated is the device memory the renderer holds, in bytes. Safe
// from any thread.
gpu_allocated :: proc "contextless" (r: ^Renderer) -> int {
	return sync.atomic_load(&r.gpu.allocated)
}

// pick_device takes the first device with a queue that draws and presents
// to the surface, a GPU before a CPU implementation such as lavapipe.
@(private)
pick_device :: proc(g: ^Gpu) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(g.instance, &count, nil)
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g.instance, &count, raw_data(devices))
	best_score := -1
	for d in devices {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(d, &props)
		families: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(d, &families, nil)
		family_props := make([]vk.QueueFamilyProperties, families, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(d, &families, raw_data(family_props))
		for fp, i in family_props {
			present: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(d, u32(i), g.surface, &present)
			if .GRAPHICS not_in fp.queueFlags || !present {
				continue
			}
			score := 0
			#partial switch props.deviceType {
			case .DISCRETE_GPU:
				score = 3
			case .INTEGRATED_GPU:
				score = 2
			case .VIRTUAL_GPU:
				score = 1
			}
			if score > best_score {
				best_score = score
				g.physical = d
				g.queue_family = u32(i)
			}
			break
		}
	}
	if best_score >= 0 {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(g.physical, &props)
		name := props.deviceName
		log.infof("render: Vulkan on %s", cstring(&name[0]))
	}
	return best_score >= 0
}

// pick_format takes an sRGB swapchain format, so blending happens in
// linear space. See render.odin.
@(private)
pick_format :: proc(g: ^Gpu) -> bool {
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical, g.surface, &count, nil)
	formats := make([]vk.SurfaceFormatKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical, g.surface, &count, raw_data(formats))
	for want in ([2]vk.Format{.B8G8R8A8_SRGB, .R8G8B8A8_SRGB}) {
		for f in formats {
			if f.format == want && f.colorSpace == .SRGB_NONLINEAR {
				g.format = want
				return true
			}
		}
	}
	log.error("render: the surface has no 8-bit sRGB format")
	return false
}

@(private)
make_render_pass :: proc(g: ^Gpu) -> bool {
	attachment := vk.AttachmentDescription {
		format         = g.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}
	ref := vk.AttachmentReference{0, .COLOR_ATTACHMENT_OPTIMAL}
	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &ref,
	}
	// The image is acquired at the colour output stage, so the layout change
	// waits for the acquire semaphore there.
	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}
	return vk.CreateRenderPass(g.device, &info, nil, &g.render_pass) == .SUCCESS
}

@(private)
make_layouts :: proc(g: ^Gpu) -> bool {
	linear := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = vk.LOD_CLAMP_NONE,
	}
	nearest := linear
	nearest.magFilter, nearest.minFilter, nearest.mipmapMode, nearest.maxLod = .NEAREST, .NEAREST, .NEAREST, 0
	vk.CreateSampler(g.device, &linear, nil, &g.samplers[0])
	vk.CreateSampler(g.device, &nearest, nil, &g.samplers[1])

	frame_bindings := [3]vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX, .FRAGMENT}},
		{binding = 1, descriptorType = .SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}, pImmutableSamplers = &g.samplers[0]},
		{binding = 2, descriptorType = .SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}, pImmutableSamplers = &g.samplers[1]},
	}
	frame_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(frame_bindings),
		pBindings    = &frame_bindings[0],
	}
	texture_binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .SAMPLED_IMAGE,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	texture_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &texture_binding,
	}
	if vk.CreateDescriptorSetLayout(g.device, &frame_info, nil, &g.frame_layout) != .SUCCESS || vk.CreateDescriptorSetLayout(g.device, &texture_info, nil, &g.texture_layout) != .SUCCESS {
		return false
	}
	// Set 1 is the colour texture, set 2 the coverage texture.
	sets := [3]vk.DescriptorSetLayout{g.frame_layout, g.texture_layout, g.texture_layout}
	push := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		size       = size_of([2]f32),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = len(sets),
		pSetLayouts            = &sets[0],
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	return vk.CreatePipelineLayout(g.device, &layout_info, nil, &g.pipeline_layout) == .SUCCESS
}

// build_pipeline returns a new pipeline, or 0 after logging why it failed.
@(private)
build_pipeline :: proc(r: ^Renderer) -> vk.Pipeline {
	g := &r.gpu
	module :: proc(g: ^Gpu, spirv: []byte) -> vk.ShaderModule {
		// #load data has no alignment; SPIR-V is read as u32s.
		words := make([]u32, (len(spirv) + 3) / 4, context.temp_allocator)
		mem.copy(raw_data(words), raw_data(spirv), len(spirv))
		info := vk.ShaderModuleCreateInfo {
			sType    = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(spirv),
			pCode    = raw_data(words),
		}
		m: vk.ShaderModule
		if res := vk.CreateShaderModule(g.device, &info, nil, &m); res != .SUCCESS {
			log.errorf("render: shader module failed: %v", res)
			return 0
		}
		return m
	}
	vs := module(g, VERTEX_SPIRV)
	fs := module(g, FRAGMENT_SPIRV)
	defer vk.DestroyShaderModule(g.device, vs, nil)
	defer vk.DestroyShaderModule(g.device, fs, nil)
	if vs == 0 || fs == 0 {
		return 0
	}
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vs, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fs, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_STRIP,
	}
	viewport := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	raster := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	// The fragment shader outputs premultiplied colour.
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable         = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}
	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = len(stages),
		pStages             = &stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState      = &viewport,
		pRasterizationState = &raster,
		pMultisampleState   = &multisample,
		pColorBlendState    = &blend,
		pDynamicState       = &dynamic_info,
		layout              = g.pipeline_layout,
		renderPass          = g.render_pass,
	}
	pipeline: vk.Pipeline
	if res := vk.CreateGraphicsPipelines(g.device, 0, 1, &info, nil, &pipeline); res != .SUCCESS {
		log.errorf("render: pipeline failed: %v", res)
		return 0
	}
	return pipeline
}

// Memory

@(private)
memory_type :: proc(g: ^Gpu, bits: u32, want: vk.MemoryPropertyFlags) -> (u32, bool) {
	for i in 0 ..< g.memory.memoryTypeCount {
		if bits & (1 << i) != 0 && want <= g.memory.memoryTypes[i].propertyFlags {
			return i, true
		}
	}
	return 0, false
}

@(private)
allocate :: proc(g: ^Gpu, req: vk.MemoryRequirements, want: vk.MemoryPropertyFlags) -> vk.DeviceMemory {
	index, ok := memory_type(g, req.memoryTypeBits, want)
	if !ok && .DEVICE_LOCAL in want {
		index, ok = memory_type(g, req.memoryTypeBits, want - {.DEVICE_LOCAL})
	}
	if !ok {
		return 0
	}
	info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = index,
	}
	m: vk.DeviceMemory
	if vk.AllocateMemory(g.device, &info, nil, &m) != .SUCCESS {
		return 0
	}
	sync.atomic_add(&g.allocated, int(req.size))
	return m
}

@(private)
free_memory :: proc(g: ^Gpu, m: vk.DeviceMemory, size: int) {
	if m != 0 {
		vk.FreeMemory(g.device, m, nil)
		sync.atomic_sub(&g.allocated, size)
	}
}

// new_buffer makes a host-visible, coherent buffer, mapped for good.
@(private)
new_buffer :: proc(g: ^Gpu, size: int, usage: vk.BufferUsageFlags) -> (b: Gpu_Buffer, ok: bool) {
	info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	if vk.CreateBuffer(g.device, &info, nil, &b.buffer) != .SUCCESS {
		return {}, false
	}
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g.device, b.buffer, &req)
	b.memory = allocate(g, req, {.HOST_VISIBLE, .HOST_COHERENT})
	if b.memory == 0 {
		vk.DestroyBuffer(g.device, b.buffer, nil)
		return {}, false
	}
	b.size = size
	b.allocated = int(req.size)
	vk.BindBufferMemory(g.device, b.buffer, b.memory, 0)
	p: rawptr
	vk.MapMemory(g.device, b.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, &p)
	b.mapped = ([^]u8)(p)
	return b, true
}

@(private)
free_buffer :: proc(g: ^Gpu, b: ^Gpu_Buffer) {
	if b.buffer != 0 {
		vk.DestroyBuffer(g.device, b.buffer, nil)
		free_memory(g, b.memory, b.allocated)
	}
	b^ = {}
}

// Frame slots

// slot_ready waits until the GPU is done with the slot the next submit
// uses, then frees what was waiting on it and starts its upload commands
// over. Once per submit; later calls return at once.
@(private)
slot_ready :: proc(r: ^Renderer) -> ^Gpu_Frame {
	g := &r.gpu
	f := &g.frames[r.frame_index % FRAMES_IN_FLIGHT]
	if f.ready {
		return f
	}
	wait := time.tick_now()
	vk.WaitForFences(g.device, 1, &f.fence, true, max(u64))
	f.wait_ms = f32(time.duration_milliseconds(time.tick_since(wait)))
	f.ready = true
	free_dead(r, f)
	return f
}

// flush_slot runs the uploads recorded so far and waits for the GPU to
// finish everything, so what waits in the slot can go now instead of
// after the next frame. For when the slot runs out of room to keep it.
// nil if the submit failed and the renderer stopped.
@(private)
flush_slot :: proc(r: ^Renderer) -> ^Gpu_Frame {
	f := slot_ready(r)
	if !submit_uploads(r, f) {
		return nil
	}
	vk.DeviceWaitIdle(r.gpu.device)
	f.ready = true
	free_dead(r, f)
	return f
}

// free_dead frees what waited for the GPU to finish with the slot and
// empties its staging buffer.
@(private)
free_dead :: proc(r: ^Renderer, f: ^Gpu_Frame) {
	g := &r.gpu
	for t in f.dead[:f.dead_count] {
		free_texture_now(g, t)
	}
	f.dead_count = 0
	for &b in f.dead_buffers[:f.dead_buffer_count] {
		free_buffer(g, &b)
	}
	f.dead_buffer_count = 0
	f.staging_used = 0
}

// end_uploads finishes the slot's upload commands, or returns false if
// there are none.
@(private)
end_uploads :: proc(f: ^Gpu_Frame) -> bool {
	if !f.uploading {
		return false
	}
	end_writes(f)
	vk.EndCommandBuffer(f.upload)
	f.uploading = false
	return true
}

// upload_cmd returns the slot's upload command buffer, begun.
@(private)
upload_cmd :: proc(r: ^Renderer) -> vk.CommandBuffer {
	f := slot_ready(r)
	if !f.uploading {
		begin := vk.CommandBufferBeginInfo {
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		vk.BeginCommandBuffer(f.upload, &begin)
		f.uploading = true
	}
	return f.upload
}

// stage copies bytes into the slot's staging buffer and returns their
// offset, growing the buffer if it's full. A buffer that copies recorded
// this frame still read waits with the slot's dead, or if there's no room
// for it there, flush_slot runs those copies first.
@(private)
stage :: proc(r: ^Renderer, bytes: []byte) -> (buffer: vk.Buffer, offset: int, ok: bool) {
	g := &r.gpu
	f := slot_ready(r)
	at := mem.align_forward_int(f.staging_used, 16)
	if at + len(bytes) > f.staging.size && f.staging_used > 0 && f.dead_buffer_count == len(f.dead_buffers) {
		f = flush_slot(r)
		if f == nil {
			return 0, 0, false
		}
		at = 0
	}
	if at + len(bytes) > f.staging.size {
		size := max(STAGING_START, 2 * f.staging.size, len(bytes))
		next, made := new_buffer(g, size, {.TRANSFER_SRC})
		if !made {
			return 0, 0, false
		}
		if f.staging.buffer != 0 {
			if f.staging_used == 0 {
				free_buffer(g, &f.staging)
			} else {
				f.dead_buffers[f.dead_buffer_count] = f.staging
				f.dead_buffer_count += 1
			}
		}
		f.staging = next
		at = 0
	}
	mem.copy(f.staging.mapped[at:], raw_data(bytes), len(bytes))
	f.staging_used = at + len(bytes)
	return f.staging.buffer, at, true
}

// Textures

@(private)
image_barrier :: proc(cmd: vk.CommandBuffer, image: vk.Image, from, to: vk.ImageLayout, first_level, levels: u32, src_stage, dst_stage: vk.PipelineStageFlags, src_access, dst_access: vk.AccessFlags) {
	barrier := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = src_access,
		dstAccessMask       = dst_access,
		oldLayout           = from,
		newLayout           = to,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {{.COLOR}, first_level, levels, 0, 1},
	}
	vk.CmdPipelineBarrier(cmd, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)
}

// new_texture_slot returns a zero slot if Vulkan can't make the texture.
// The image starts out ready to sample, with undefined contents.
@(private)
new_texture_slot :: proc(r: ^Renderer, width, height: int, format: Texture_Format, mipmapped: bool) -> Texture_Slot {
	g := &r.gpu
	if g.device == nil {
		return {}
	}
	vk_format: vk.Format
	switch format {
	case .R8:
		vk_format = .R8_UNORM
	case .RGBA8:
		vk_format = .R8G8B8A8_SRGB
	case .BGRA8:
		vk_format = .B8G8R8A8_SRGB
	}
	levels := u32(1)
	if mipmapped {
		levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1
	}
	t: Gpu_Texture
	t.levels = levels
	info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = vk_format,
		extent        = {u32(width), u32(height), 1},
		mipLevels     = levels,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.SAMPLED, .TRANSFER_DST, .TRANSFER_SRC},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	if vk.CreateImage(g.device, &info, nil, &t.image) != .SUCCESS {
		return {}
	}
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g.device, t.image, &req)
	t.memory = allocate(g, req, {.DEVICE_LOCAL})
	if t.memory == 0 {
		vk.DestroyImage(g.device, t.image, nil)
		return {}
	}
	t.size = int(req.size)
	vk.BindImageMemory(g.device, t.image, t.memory, 0)
	view_info := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		image            = t.image,
		viewType         = .D2,
		format           = vk_format,
		subresourceRange = {{.COLOR}, 0, levels, 0, 1},
	}
	if format == .R8 {
		// Coverage samples as premultiplied white.
		view_info.components = {.R, .R, .R, .R}
	}
	vk.CreateImageView(g.device, &view_info, nil, &t.view)
	set_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = g.descriptors,
		descriptorSetCount = 1,
		pSetLayouts        = &g.texture_layout,
	}
	if vk.AllocateDescriptorSets(g.device, &set_info, &t.set) != .SUCCESS {
		free_texture_now(g, t)
		return {}
	}
	image_info := vk.DescriptorImageInfo {
		imageView   = t.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = t.set,
		descriptorCount = 1,
		descriptorType  = .SAMPLED_IMAGE,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(g.device, 1, &write, 0, nil)
	image_barrier(upload_cmd(r), t.image, .UNDEFINED, .SHADER_READ_ONLY_OPTIMAL, 0, levels, {.TOP_OF_PIPE}, {.FRAGMENT_SHADER}, {}, {.SHADER_READ})
	return {gpu = t, width = i32(width), height = i32(height), format = format, mipmapped = mipmapped}
}

// gpu_texture_free frees the texture once the frames that may sample it
// are done.
@(private)
gpu_texture_free :: proc(r: ^Renderer, t: Gpu_Texture) {
	if r.gpu.device == nil {
		return
	}
	f := slot_ready(r)
	if f.dead_count == MAX_DEAD {
		f = flush_slot(r)
		if f == nil {
			return
		}
	}
	f.dead[f.dead_count] = t
	f.dead_count += 1
}

@(private)
free_texture_now :: proc(g: ^Gpu, t: Gpu_Texture) {
	if t.set != 0 {
		set := t.set
		vk.FreeDescriptorSets(g.device, g.descriptors, 1, &set)
	}
	if t.view != 0 {
		vk.DestroyImageView(g.device, t.view, nil)
	}
	if t.image != 0 {
		vk.DestroyImage(g.device, t.image, nil)
	}
	free_memory(g, t.memory, t.size)
}

// gpu_texture_write queues a copy of the pixels into the texture ahead of
// the next frame. The mips, if it has them, are made again once the
// upload's writes to it end.
@(private)
gpu_texture_write :: proc(r: ^Renderer, slot: ^Texture_Slot, pixels: []byte, x, y, w, h, bpp: int) {
	if r.gpu.device == nil {
		return
	}
	buffer, offset, ok := stage(r, pixels[:w * h * bpp])
	if !ok {
		log.error("render: out of staging memory")
		return
	}
	cmd := upload_cmd(r)
	target := write_target(r, slot)
	if write_region(&target.written, {i32(x), i32(y), i32(x + w), i32(y + h)}) {
		image_barrier(cmd, target.image, .TRANSFER_DST_OPTIMAL, .TRANSFER_DST_OPTIMAL, 0, 1, {.TRANSFER}, {.TRANSFER}, {.TRANSFER_WRITE}, {.TRANSFER_WRITE})
	}
	region := vk.BufferImageCopy {
		bufferOffset     = vk.DeviceSize(offset),
		imageSubresource = {{.COLOR}, 0, 0, 1},
		imageOffset      = {i32(x), i32(y), 0},
		imageExtent      = {u32(w), u32(h), 1},
	}
	vk.CmdCopyBufferToImage(cmd, buffer, target.image, .TRANSFER_DST_OPTIMAL, 1, &region)
}

// write_region adds region to the texels written since the last barrier
// and returns whether it overlaps them, when the copy has to wait for the
// earlier ones. Copies to disjoint regions need no barrier between them.
write_region :: proc(written: ^[4]i32, region: [4]i32) -> (overlaps: bool) {
	w := written^
	overlaps = region.x < w.z && w.x < region.z && region.y < w.w && w.y < region.w
	if overlaps || w.x >= w.z || w.y >= w.w {
		written^ = region
	} else {
		written^ = {min(w.x, region.x), min(w.y, region.y), max(w.z, region.z), max(w.w, region.w)}
	}
	return
}

// write_target returns the upload's write to the texture, first moving its
// image to a transfer destination if the upload hasn't yet.
@(private)
write_target :: proc(r: ^Renderer, slot: ^Texture_Slot) -> ^Image_Write {
	f := slot_ready(r)
	t := slot.gpu
	for &w in f.writes[:f.write_count] {
		if w.image == t.image {
			return &w
		}
	}
	if f.write_count == MAX_WRITES {
		end_writes(f)
	}
	image_barrier(f.upload, t.image, .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_DST_OPTIMAL, 0, t.levels, {.FRAGMENT_SHADER}, {.TRANSFER}, {.SHADER_READ}, {.TRANSFER_WRITE})
	f.writes[f.write_count] = {image = t.image, levels = t.levels, width = slot.width, height = slot.height}
	f.write_count += 1
	return &f.writes[f.write_count - 1]
}

// end_writes hands every image the upload writes back to the shaders,
// making its mips first if it has them.
@(private)
end_writes :: proc(f: ^Gpu_Frame) {
	for w in f.writes[:f.write_count] {
		if w.levels > 1 {
			generate_mips(f.upload, w)
		} else {
			image_barrier(f.upload, w.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, 0, 1, {.TRANSFER}, {.FRAGMENT_SHADER}, {.TRANSFER_WRITE}, {.SHADER_READ})
		}
	}
	f.write_count = 0
}

// generate_mips blits each level from the one above. Every level comes in
// as a transfer destination and leaves ready to sample.
@(private)
generate_mips :: proc(cmd: vk.CommandBuffer, t: Image_Write) {
	w, h := t.width, t.height
	for level in 1 ..< t.levels {
		image_barrier(cmd, t.image, .TRANSFER_DST_OPTIMAL, .TRANSFER_SRC_OPTIMAL, level - 1, 1, {.TRANSFER}, {.TRANSFER}, {.TRANSFER_WRITE}, {.TRANSFER_READ})
		nw, nh := max(w / 2, 1), max(h / 2, 1)
		blit := vk.ImageBlit {
			srcSubresource = {{.COLOR}, level - 1, 0, 1},
			srcOffsets     = {{0, 0, 0}, {w, h, 1}},
			dstSubresource = {{.COLOR}, level, 0, 1},
			dstOffsets     = {{0, 0, 0}, {nw, nh, 1}},
		}
		vk.CmdBlitImage(cmd, t.image, .TRANSFER_SRC_OPTIMAL, t.image, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)
		image_barrier(cmd, t.image, .TRANSFER_SRC_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, level - 1, 1, {.TRANSFER}, {.FRAGMENT_SHADER}, {.TRANSFER_READ}, {.SHADER_READ})
		w, h = nw, nh
	}
	image_barrier(cmd, t.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, t.levels - 1, 1, {.TRANSFER}, {.FRAGMENT_SHADER}, {.TRANSFER_WRITE}, {.SHADER_READ})
}

@(private)
gpu_texture_copy :: proc(r: ^Renderer, from, to: ^Texture_Slot, w, h: int) {
	if r.gpu.device == nil {
		return
	}
	cmd := upload_cmd(r)
	// Both images must be ready to sample, as the barriers below expect.
	end_writes(slot_ready(r))
	src, dst := from.gpu.image, to.gpu.image
	image_barrier(cmd, src, .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_SRC_OPTIMAL, 0, 1, {.FRAGMENT_SHADER}, {.TRANSFER}, {.SHADER_READ}, {.TRANSFER_READ})
	image_barrier(cmd, dst, .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_DST_OPTIMAL, 0, 1, {.FRAGMENT_SHADER}, {.TRANSFER}, {.SHADER_READ}, {.TRANSFER_WRITE})
	region := vk.ImageCopy {
		srcSubresource = {{.COLOR}, 0, 0, 1},
		dstSubresource = {{.COLOR}, 0, 0, 1},
		extent         = {u32(w), u32(h), 1},
	}
	vk.CmdCopyImage(cmd, src, .TRANSFER_SRC_OPTIMAL, dst, .TRANSFER_DST_OPTIMAL, 1, &region)
	image_barrier(cmd, src, .TRANSFER_SRC_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, 0, 1, {.TRANSFER}, {.FRAGMENT_SHADER}, {.TRANSFER_READ}, {.SHADER_READ})
	image_barrier(cmd, dst, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, 0, 1, {.TRANSFER}, {.FRAGMENT_SHADER}, {.TRANSFER_WRITE}, {.SHADER_READ})
}

// Frame

// gpu_frame_begin waits until the GPU is done with this frame's slot and
// returns its instance buffer, or nil if there is none.
@(private)
gpu_frame_begin :: proc(r: ^Renderer) -> [^]Instance {
	if r.gpu.device == nil {
		return nil
	}
	f := slot_ready(r)
	// The wait may have come earlier, from a texture call between frames.
	r.slot_wait_ms, f.wait_ms = f.wait_ms, 0
	r.drawable_wait_ms = 0
	if f.instances.buffer == 0 {
		set_instance_buffer(r, f, INITIAL_INSTANCES)
	}
	return ([^]Instance)(f.instances.mapped)
}

// grow_instances replaces the current slot's buffer with one twice the
// size and copies over what this frame has pushed so far. Nothing has read
// this frame's buffer yet, so the old one can go at once. If there's no
// memory for it, the old buffer and capacity stay.
@(private)
grow_instances :: proc(r: ^Renderer) {
	f := &r.gpu.frames[r.slot]
	old := f.instances
	set_instance_buffer(r, f, r.capacity[r.slot] * 2)
	if f.instances.buffer == old.buffer {
		return
	}
	mem.copy(f.instances.mapped, old.mapped, r.instance_count * size_of(Instance))
	free_buffer(&r.gpu, &old)
	r.instances = ([^]Instance)(f.instances.mapped)
}

@(private)
set_instance_buffer :: proc(r: ^Renderer, f: ^Gpu_Frame, capacity: int) {
	g := &r.gpu
	b, ok := new_buffer(g, capacity * size_of(Instance), {.STORAGE_BUFFER})
	if !ok {
		log.error("render: out of memory for instances")
		return
	}
	f.instances = b
	r.capacity[r.slot] = capacity
	buffer_info := vk.DescriptorBufferInfo {
		buffer = b.buffer,
		range  = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = f.set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .STORAGE_BUFFER,
		pBufferInfo     = &buffer_info,
	}
	vk.UpdateDescriptorSets(g.device, 1, &write, 0, nil)
}

@(private)
destroy_swapchain :: proc(g: ^Gpu) {
	for i in 0 ..< g.image_count {
		vk.DestroyFramebuffer(g.device, g.framebuffers[i], nil)
		vk.DestroyImageView(g.device, g.views[i], nil)
		vk.DestroySemaphore(g.device, g.rendered[i], nil)
	}
	g.image_count = 0
}

// make_swapchain makes the swapchain at width by height pixels, in place
// of the old one. Wayland lets the client pick the size. Mailbox when the
// driver has it, so a present never blocks and the shell's frame callbacks
// pace animation; FIFO otherwise.
@(private)
make_swapchain :: proc(r: ^Renderer, width, height: u32) -> bool {
	g := &r.gpu
	vk.DeviceWaitIdle(g.device)
	destroy_swapchain(g)
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g.physical, g.surface, &caps)
	extent := vk.Extent2D{width, height}
	if caps.currentExtent.width != max(u32) {
		extent = caps.currentExtent
	}
	extent.width = clamp(extent.width, max(caps.minImageExtent.width, 1), max(caps.maxImageExtent.width, 1))
	extent.height = clamp(extent.height, max(caps.minImageExtent.height, 1), max(caps.maxImageExtent.height, 1))

	count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g.physical, g.surface, &count, nil)
	modes := make([]vk.PresentModeKHR, count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g.physical, g.surface, &count, raw_data(modes))
	mode := vk.PresentModeKHR.FIFO
	for m in modes {
		if m == .MAILBOX {
			mode = .MAILBOX
		}
	}
	images := max(caps.minImageCount, 2)
	if mode == .MAILBOX {
		images = max(images, 3)
	}
	if caps.maxImageCount > 0 {
		images = min(images, caps.maxImageCount)
	}
	images = min(images, MAX_SWAPCHAIN_IMAGES)
	usage := vk.ImageUsageFlags{.COLOR_ATTACHMENT}
	g.can_capture = .TRANSFER_SRC in caps.supportedUsageFlags
	if r.capture_path != "" && g.can_capture {
		usage += {.TRANSFER_SRC}
	}
	alpha := vk.CompositeAlphaFlagsKHR{.OPAQUE}
	if .OPAQUE not_in caps.supportedCompositeAlpha {
		alpha = {.INHERIT}
	}
	old := g.swapchain
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = g.surface,
		minImageCount    = images,
		imageFormat      = g.format,
		imageColorSpace  = .SRGB_NONLINEAR,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = usage,
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = alpha,
		presentMode      = mode,
		clipped          = true,
		oldSwapchain     = old,
	}
	res := vk.CreateSwapchainKHR(g.device, &info, nil, &g.swapchain)
	if old != 0 {
		vk.DestroySwapchainKHR(g.device, old, nil)
	}
	if res != .SUCCESS {
		log.errorf("render: vkCreateSwapchainKHR failed: %v", res)
		g.swapchain = 0
		return false
	}
	g.extent = extent
	g.requested = {width, height}
	n: u32
	vk.GetSwapchainImagesKHR(g.device, g.swapchain, &n, nil)
	n = min(n, MAX_SWAPCHAIN_IMAGES)
	vk.GetSwapchainImagesKHR(g.device, g.swapchain, &n, &g.images[0])
	for i in 0 ..< n {
		view_info := vk.ImageViewCreateInfo {
			sType            = .IMAGE_VIEW_CREATE_INFO,
			image            = g.images[i],
			viewType         = .D2,
			format           = g.format,
			subresourceRange = {{.COLOR}, 0, 1, 0, 1},
		}
		vk.CreateImageView(g.device, &view_info, nil, &g.views[i])
		fb_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = g.render_pass,
			attachmentCount = 1,
			pAttachments    = &g.views[i],
			width           = extent.width,
			height          = extent.height,
			layers          = 1,
		}
		vk.CreateFramebuffer(g.device, &fb_info, nil, &g.framebuffers[i])
		semaphore_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk.CreateSemaphore(g.device, &semaphore_info, nil, &g.rendered[i])
	}
	g.image_count = n
	return true
}

// end_frame records the frame and presents it, after the uploads queued
// since the last one.
end_frame :: proc(r: ^Renderer) {
	g := &r.gpu
	// Counts frames that drew nothing too, so frame_index - FRAMES_IN_FLIGHT
	// is always a frame the GPU has finished once begin_frame returns.
	defer r.frame_index += 1
	if g.device == nil {
		return
	}
	f := slot_ready(r)
	want := vk.Extent2D{u32(math.round(r.width * r.scale)), u32(math.round(r.height * r.scale))}
	image := max(u32)
	if g.pipeline != 0 && want.width > 0 && want.height > 0 {
		if g.swapchain == 0 || g.requested != want {
			make_swapchain(r, want.width, want.height)
		}
		wait := time.tick_now()
		image = acquire(r, f, want)
		r.drawable_wait_ms = f32(time.duration_milliseconds(time.tick_since(wait)))
	}
	if image == max(u32) {
		submit_uploads(r, f)
		return
	}

	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	cmd := f.cmd
	vk.BeginCommandBuffer(cmd, &begin)
	// The swapchain is sRGB, so the clear colour is given in linear.
	clear := vk.ClearValue {
		color = {float32 = {linear_from_srgb(r.clear.r), linear_from_srgb(r.clear.g), linear_from_srgb(r.clear.b), r.clear.a}},
	}
	pass := vk.RenderPassBeginInfo {
		sType           = .RENDER_PASS_BEGIN_INFO,
		renderPass      = g.render_pass,
		framebuffer     = g.framebuffers[image],
		renderArea      = {extent = g.extent},
		clearValueCount = 1,
		pClearValues    = &clear,
	}
	vk.CmdBeginRenderPass(cmd, &pass, .INLINE)
	draw_calls := 0
	if r.instance_count > 0 {
		viewport := vk.Viewport{0, 0, f32(g.extent.width), f32(g.extent.height), 0, 1}
		scissor := vk.Rect2D{extent = g.extent}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		vk.CmdBindPipeline(cmd, .GRAPHICS, g.pipeline)
		size := [2]f32{f32(g.extent.width), f32(g.extent.height)}
		vk.CmdPushConstants(cmd, g.pipeline_layout, {.VERTEX}, 0, size_of(size), &size)
		vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g.pipeline_layout, 0, 1, &f.set, 0, nil)
		bound := [2]vk.DescriptorSet{}
		for b in r.batches[:r.batch_count] {
			if b.count == 0 {
				continue
			}
			for t, index in b.textures {
				slot := texture_slot(r, t)
				set := slot.gpu.set if slot != nil else r.textures[0].gpu.set
				if set != bound[index] {
					vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g.pipeline_layout, u32(1 + index), 1, &set, 0, nil)
					bound[index] = set
				}
			}
			vk.CmdDraw(cmd, 4, b.count, 0, b.first)
			draw_calls += 1
		}
	}
	vk.CmdEndRenderPass(cmd)

	if r.capture_path != "" && g.can_capture {
		f.capture = record_capture(r, cmd, image)
	}
	vk.EndCommandBuffer(cmd)

	buffers: [2]vk.CommandBuffer
	n: u32
	if end_uploads(f) {
		buffers[n] = f.upload
		n += 1
	}
	buffers[n] = cmd
	n += 1
	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &f.acquired,
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = n,
		pCommandBuffers      = &buffers[0],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &g.rendered[image],
	}
	if !submit(r, f, &info) {
		return
	}
	present := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &g.rendered[image],
		swapchainCount     = 1,
		pSwapchains        = &g.swapchain,
		pImageIndices      = &image,
	}
	if res := vk.QueuePresentKHR(g.queue, &present); res == .ERROR_OUT_OF_DATE_KHR || res == .SUBOPTIMAL_KHR {
		g.requested = {} // made again next frame
	}
	r.stats = {draw_calls, r.instance_count}

	if f.capture.buffer != 0 {
		vk.WaitForFences(g.device, 1, &f.fence, true, max(u64))
		w, h := uint(g.extent.width), uint(g.extent.height)
		pixels := f.capture.mapped[:w * h * 4]
		if g.format == .R8G8B8A8_SRGB {
			for i := 0; i < len(pixels); i += 4 {
				pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]
			}
		}
		write_tga(r.capture_path, pixels, w, h)
		free_buffer(g, &f.capture)
	}
}

// acquire gets the next swapchain image, making the swapchain again if
// it's out of date. max(u32) if there is none to draw to.
@(private)
acquire :: proc(r: ^Renderer, f: ^Gpu_Frame, want: vk.Extent2D) -> u32 {
	g := &r.gpu
	for _ in 0 ..< 2 {
		if g.swapchain == 0 {
			return max(u32)
		}
		image: u32
		res := vk.AcquireNextImageKHR(g.device, g.swapchain, u64(1e9), f.acquired, 0, &image)
		#partial switch res {
		case .SUCCESS, .SUBOPTIMAL_KHR:
			return image
		case .ERROR_OUT_OF_DATE_KHR:
			make_swapchain(r, want.width, want.height)
		case:
			log.warnf("render: vkAcquireNextImageKHR: %v", res)
			return max(u32)
		}
	}
	return max(u32)
}

// submit_uploads runs the slot's uploads on their own, on a frame that draws
// nothing or when flush_slot needs them done. False if the renderer stopped.
@(private)
submit_uploads :: proc(r: ^Renderer, f: ^Gpu_Frame) -> bool {
	if !end_uploads(f) {
		return true
	}
	info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &f.upload,
	}
	return submit(r, f, &info)
}

// submit queues the slot's command buffers to signal its fence. If the
// queue refuses them, the fence never signals, the acquire semaphore and
// the image stay pending and the uploads the texture caches count on are
// lost, so the renderer stops and draws nothing from then on.
@(private)
submit :: proc(r: ^Renderer, f: ^Gpu_Frame, info: ^vk.SubmitInfo) -> bool {
	g := &r.gpu
	vk.ResetFences(g.device, 1, &f.fence)
	if res := vk.QueueSubmit(g.queue, 1, info, f.fence); res != .SUCCESS {
		log.errorf("render: vkQueueSubmit failed, drawing nothing from now on: %v", res)
		stop(r)
		return false
	}
	f.ready = false
	return true
}

// record_capture copies the drawn image into a host buffer after the
// render pass, and puts it back for presenting.
@(private)
record_capture :: proc(r: ^Renderer, cmd: vk.CommandBuffer, image: u32) -> Gpu_Buffer {
	g := &r.gpu
	w, h := g.extent.width, g.extent.height
	buf, ok := new_buffer(g, int(w * h * 4), {.TRANSFER_DST})
	if !ok {
		return {}
	}
	img := g.images[image]
	image_barrier(cmd, img, .PRESENT_SRC_KHR, .TRANSFER_SRC_OPTIMAL, 0, 1, {.COLOR_ATTACHMENT_OUTPUT}, {.TRANSFER}, {.COLOR_ATTACHMENT_WRITE}, {.TRANSFER_READ})
	region := vk.BufferImageCopy {
		imageSubresource = {{.COLOR}, 0, 0, 1},
		imageExtent      = {w, h, 1},
	}
	vk.CmdCopyImageToBuffer(cmd, img, .TRANSFER_SRC_OPTIMAL, buf.buffer, 1, &region)
	readback := vk.BufferMemoryBarrier {
		sType               = .BUFFER_MEMORY_BARRIER,
		srcAccessMask       = {.TRANSFER_WRITE},
		dstAccessMask       = {.HOST_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = buf.buffer,
		size                = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	vk.CmdPipelineBarrier(cmd, {.TRANSFER}, {.HOST}, {}, 0, nil, 1, &readback, 0, nil)
	image_barrier(cmd, img, .TRANSFER_SRC_OPTIMAL, .PRESENT_SRC_KHR, 0, 1, {.TRANSFER}, {.BOTTOM_OF_PIPE}, {.TRANSFER_READ}, {})
	return buf
}
