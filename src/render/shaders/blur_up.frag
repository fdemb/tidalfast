#version 450
// See blur.vert. Into a target twice the source's size: eight taps on a
// ring.

layout(set = 0, binding = 1) uniform sampler linear_sampler;
layout(set = 1, binding = 0) uniform texture2D src;

layout(push_constant) uniform Push {
	vec2 half_pixel; // half a source texel
} push;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;

vec4 tap(vec2 offset) {
	return texture(sampler2D(src, linear_sampler), uv + offset);
}

void main() {
	vec2 h = push.half_pixel;
	vec4 sum = tap(vec2(-h.x * 2.0, 0.0));
	sum += tap(vec2(-h.x, h.y)) * 2.0;
	sum += tap(vec2(0.0, h.y * 2.0));
	sum += tap(vec2(h.x, h.y)) * 2.0;
	sum += tap(vec2(h.x * 2.0, 0.0));
	sum += tap(vec2(h.x, -h.y)) * 2.0;
	sum += tap(vec2(0.0, -h.y * 2.0));
	sum += tap(vec2(-h.x, -h.y)) * 2.0;
	out_color = sum / 12.0;
}
