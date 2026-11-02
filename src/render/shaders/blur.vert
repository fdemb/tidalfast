#version 450
// The dual Kawase filter (Bjorge, 2015), a port of blur_vertex, blur_down
// and blur_up in metal_darwin.odin. A full-screen triangle per pass.

layout(location = 0) out vec2 uv;

void main() {
	uint vid = uint(gl_VertexIndex);
	uv = vec2(float((vid << 1u) & 2u), float(vid & 2u));
	// Vulkan's clip space has y down, like the texture coordinates.
	gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
