// A minimal Metal path: clear, then solid rects. Phase 1 replaces the
// pipeline with the full instanced rect renderer behind the same procs.
package render

import "core:fmt"
import "core:os"
import MTL "vendor:darwin/Metal"

Rect :: struct {
	x, y, w, h: f32, // points, origin top left
}

Color :: [4]f32

MAX_RECTS :: 4096

Instance :: struct {
	rect:  [4]f32,
	color: Color,
}

// Renderer is plain data so it can live in the app's persistent memory. The
// Metal objects are owned by the Obj-C runtime, not by the dylib, so they
// survive a reload. The pipeline is rebuilt on reload because the shader
// source lives in the dylib.
Renderer :: struct {
	device:     id, // id<MTLDevice>
	layer:      id, // CAMetalLayer*
	queue:      id, // id<MTLCommandQueue>
	pipeline:   id, // id<MTLRenderPipelineState>
	width:      f32, // points
	height:     f32,
	clear:      Color,
	instances:  [MAX_RECTS]Instance,
	rect_count: int,
	// Debug: when set, end_frame waits for the GPU and writes each frame to
	// this path as a TGA. Set it before init.
	capture_path: string,
}

// Compiled at runtime with newLibraryWithSource. The Metal compiler is not
// part of the command line tools, and keeping the source here means shader
// edits hot reload with the rest of the dylib.
SHADER_SOURCE :: `
#include <metal_stdlib>
using namespace metal;

struct Instance {
	float4 rect;
	float4 color;
};

struct Vertex_Out {
	float4 position [[position]];
	float4 color;
};

vertex Vertex_Out rect_vertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              constant Instance *instances [[buffer(0)]],
                              constant float2 &viewport [[buffer(1)]]) {
	Instance inst = instances[iid];
	float2 corner = float2(vid & 1, vid >> 1);
	float2 p = inst.rect.xy + corner * inst.rect.zw;
	Vertex_Out out;
	out.position = float4(p.x / viewport.x * 2 - 1, 1 - p.y / viewport.y * 2, 0, 1);
	out.color = inst.color;
	return out;
}

fragment float4 rect_fragment(Vertex_Out in [[stage_in]]) {
	return in.color;
}
`

init :: proc(r: ^Renderer, device, layer: rawptr) -> bool {
	r.device = device
	r.layer = layer
	r.queue = msg(r.device, "newCommandQueue")
	if r.capture_path != "" {
		msg_bool(r.layer, "setFramebufferOnly:", false)
	}
	r.pipeline = build_pipeline(r)
	return r.pipeline != nil
}

// reload rebuilds the pipeline from this dylib's shader source. If that
// fails, the old pipeline stays in place and reload returns false.
reload :: proc(r: ^Renderer) -> bool {
	pipeline := build_pipeline(r)
	if pipeline == nil {
		return false
	}
	release(r.pipeline)
	r.pipeline = pipeline
	return true
}

destroy :: proc(r: ^Renderer) {
	release(r.pipeline)
	release(r.queue)
	r^ = {}
}

// build_pipeline returns a new pipeline, or nil after logging why it failed.
@(private)
build_pipeline :: proc(r: ^Renderer) -> id {
	err: id
	library := msg_proc(proc "c" (id, SEL, id, id, ^id) -> id)(r.device, sel_registerName("newLibraryWithSource:options:error:"), ns_string(SHADER_SOURCE), nil, &err)
	if library == nil {
		fmt.eprintln("render: shader compile failed:", error_string(err))
		return nil
	}
	defer release(library)

	vs := msg_id(library, "newFunctionWithName:", ns_string("rect_vertex"))
	fs := msg_id(library, "newFunctionWithName:", ns_string("rect_fragment"))
	defer release(vs)
	defer release(fs)

	desc := new_object("MTLRenderPipelineDescriptor")
	defer release(desc)
	msg_id(desc, "setVertexFunction:", vs)
	msg_id(desc, "setFragmentFunction:", fs)
	att := msg_uint(msg(desc, "colorAttachments"), "objectAtIndexedSubscript:", 0)
	pixel_format := msg_proc(proc "c" (id, SEL) -> MTL.PixelFormat)(r.layer, sel_registerName("pixelFormat"))
	msg_uint(att, "setPixelFormat:", uint(pixel_format))
	msg_bool(att, "setBlendingEnabled:", true)
	msg_uint(att, "setSourceRGBBlendFactor:", uint(MTL.BlendFactor.SourceAlpha))
	msg_uint(att, "setDestinationRGBBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))
	msg_uint(att, "setSourceAlphaBlendFactor:", uint(MTL.BlendFactor.One))
	msg_uint(att, "setDestinationAlphaBlendFactor:", uint(MTL.BlendFactor.OneMinusSourceAlpha))

	pipeline := msg_proc(proc "c" (id, SEL, id, ^id) -> id)(r.device, sel_registerName("newRenderPipelineStateWithDescriptor:error:"), desc, &err)
	if pipeline == nil {
		fmt.eprintln("render: pipeline failed:", error_string(err))
		return nil
	}
	return pipeline
}

begin_frame :: proc(r: ^Renderer, width, height: f32, clear: Color) {
	r.width = width
	r.height = height
	r.clear = clear
	r.rect_count = 0
}

push_rect :: proc(r: ^Renderer, rect: Rect, color: Color) {
	if r.rect_count == MAX_RECTS {
		return
	}
	r.instances[r.rect_count] = {{rect.x, rect.y, rect.w, rect.h}, color}
	r.rect_count += 1
}

// end_frame encodes the frame and presents it. The caller must be inside an
// autorelease pool; the shell wraps every frame in one.
end_frame :: proc(r: ^Renderer) {
	if r.pipeline == nil || r.width <= 0 || r.height <= 0 {
		return
	}
	drawable := msg(r.layer, "nextDrawable")
	if drawable == nil {
		return
	}

	pass := msg(objc_getClass("MTLRenderPassDescriptor"), "renderPassDescriptor")
	color := msg_uint(msg(pass, "colorAttachments"), "objectAtIndexedSubscript:", 0)
	msg_id(color, "setTexture:", msg(drawable, "texture"))
	msg_uint(color, "setLoadAction:", uint(MTL.LoadAction.Clear))
	msg_uint(color, "setStoreAction:", uint(MTL.StoreAction.Store))
	clear := MTL.ClearColor{f64(r.clear.r), f64(r.clear.g), f64(r.clear.b), f64(r.clear.a)}
	msg_proc(proc "c" (id, SEL, MTL.ClearColor))(color, sel_registerName("setClearColor:"), clear)

	cmd := msg(r.queue, "commandBuffer")
	enc := msg_id(cmd, "renderCommandEncoderWithDescriptor:", pass)
	if r.rect_count > 0 {
		// A fresh buffer per frame, so the GPU never reads memory the CPU is
		// writing. Phase 1 replaces this with a triple-buffered ring.
		buf := msg_proc(proc "c" (id, SEL, rawptr, uint, uint) -> id)(r.device, sel_registerName("newBufferWithBytes:length:options:"), &r.instances[0], uint(r.rect_count * size_of(Instance)), 0)
		defer release(buf)
		viewport := [2]f32{r.width, r.height}
		msg_id(enc, "setRenderPipelineState:", r.pipeline)
		msg_proc(proc "c" (id, SEL, id, uint, uint))(enc, sel_registerName("setVertexBuffer:offset:atIndex:"), buf, 0, 0)
		msg_proc(proc "c" (id, SEL, rawptr, uint, uint))(enc, sel_registerName("setVertexBytes:length:atIndex:"), &viewport, size_of(viewport), 1)
		msg_proc(proc "c" (id, SEL, uint, uint, uint, uint))(enc, sel_registerName("drawPrimitives:vertexStart:vertexCount:instanceCount:"), uint(MTL.PrimitiveType.TriangleStrip), 0, 4, uint(r.rect_count))
	}
	msg(enc, "endEncoding")

	capture: id
	texture := msg(drawable, "texture")
	tex_w := msg_proc(proc "c" (id, SEL) -> uint)(texture, sel_registerName("width"))
	tex_h := msg_proc(proc "c" (id, SEL) -> uint)(texture, sel_registerName("height"))
	if r.capture_path != "" {
		capture = encode_capture(r, cmd, texture, tex_w, tex_h)
	}

	msg_id(cmd, "presentDrawable:", drawable)
	msg(cmd, "commit")

	if capture != nil {
		msg(cmd, "waitUntilCompleted")
		write_tga(r.capture_path, ([^]byte)(msg(capture, "contents"))[:tex_w * tex_h * 4], tex_w, tex_h)
		release(capture)
	}
}

// MTLOrigin and MTLSize.
@(private)
Origin :: struct {
	x, y, z: uint,
}
@(private)
Size :: struct {
	width, height, depth: uint,
}

@(private)
encode_capture :: proc(r: ^Renderer, cmd, texture: id, w, h: uint) -> id {
	MTL_RESOURCE_STORAGE_MODE_SHARED :: 0
	buf := msg_proc(proc "c" (id, SEL, uint, uint) -> id)(r.device, sel_registerName("newBufferWithLength:options:"), w * h * 4, MTL_RESOURCE_STORAGE_MODE_SHARED)
	blit := msg(cmd, "blitCommandEncoder")
	msg_proc(proc "c" (id, SEL, id, uint, uint, Origin, Size, id, uint, uint, uint))(
		blit,
		sel_registerName("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:"),
		texture, 0, 0, {}, {w, h, 1}, buf, 0, w * 4, w * h * 4,
	)
	msg(blit, "endEncoding")
	return buf
}

// write_tga writes BGRA pixels, top row first.
@(private)
write_tga :: proc(path: string, pixels: []byte, w, h: uint) {
	header := [18]byte{2 = 2, 12 = u8(w), 13 = u8(w >> 8), 14 = u8(h), 15 = u8(h >> 8), 16 = 32, 17 = 0x28}
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("render: capture failed:", err)
		return
	}
	defer os.close(f)
	os.write(f, header[:])
	os.write(f, pixels)
}
