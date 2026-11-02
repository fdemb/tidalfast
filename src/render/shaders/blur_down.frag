#version 450
// See blur.vert. Into a target half the source's size: the centre and four
// diagonal taps, each a bilinear average of four texels.

layout(set = 0, binding = 1) uniform sampler linear_sampler;
layout(set = 1, binding = 0) uniform texture2D src;

layout(push_constant) uniform Push {
	vec2 half_pixel; // half a source texel
} push;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;

void main() {
	vec2 h = push.half_pixel;
	vec4 sum = texture(sampler2D(src, linear_sampler), uv) * 4.0;
	sum += texture(sampler2D(src, linear_sampler), uv - h);
	sum += texture(sampler2D(src, linear_sampler), uv + h);
	sum += texture(sampler2D(src, linear_sampler), uv + vec2(h.x, -h.y));
	sum += texture(sampler2D(src, linear_sampler), uv - vec2(h.x, -h.y));
	out_color = sum / 8.0;
}
