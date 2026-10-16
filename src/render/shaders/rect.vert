#version 450
// The Vulkan rect pipeline, a port of SHADER_SOURCE in metal_darwin.odin.
// build.sh compiles it to build/shaders/rect.vert.spv, which
// vulkan_linux.odin loads. Keep the two backends' shaders doing the same.

struct Instance {
	vec4 dst;
	vec4 src;
	vec4 colors[4];
	vec4 radii;
	float border;
	float softness;
	uint flags;
	float pad;
	vec4 clip;
};

layout(std430, set = 0, binding = 0) readonly buffer Instances {
	Instance instances[];
};

layout(push_constant) uniform Push {
	vec2 viewport;
} push;

layout(location = 0) flat out uint iid;

// The quad covers the rect plus its soft edge, cut down to the clip rect.
// The fragment shader works from the pixel position alone, so clipping the
// quad clips the shape exactly, and a clipped-away instance costs no pixels.
void main() {
	Instance r = instances[gl_InstanceIndex];
	float pad = max(r.softness, 0.5) + 1.0;
	vec2 p0 = max(r.dst.xy - pad, r.clip.xy);
	vec2 p1 = max(min(r.dst.zw + pad, r.clip.zw), p0);
	uint vid = uint(gl_VertexIndex);
	vec2 p = mix(p0, p1, vec2(float(vid & 1u), float(vid >> 1u)));
	// Vulkan's clip space has y down, like the pixels.
	gl_Position = vec4(p / push.viewport * 2.0 - 1.0, 0.0, 1.0);
	iid = uint(gl_InstanceIndex);
}
