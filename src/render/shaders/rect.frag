#version 450
// See rect.vert.

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
layout(set = 0, binding = 1) uniform sampler linear_sampler;
layout(set = 0, binding = 2) uniform sampler nearest_sampler;
layout(set = 1, binding = 0) uniform texture2D colour_tex;
layout(set = 2, binding = 0) uniform texture2D coverage_tex;

layout(location = 0) flat in uint iid;
layout(location = 0) out vec4 out_color;

const uint TEXTURED = 1u;
const uint NEAREST = 2u;
const uint COVERAGE = 4u;

// Signed distance from p to a box centred on the origin with rounded corners.
// Negative inside.
float box_sdf(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Coverage of the inside of an edge at signed distance d, blurred over w
// pixels either side. w = 0.5 is plain antialiasing.
float inside(float d, float w) {
	return 1.0 - smoothstep(-w, w, d);
}

vec3 linear_from_srgb(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThanEqual(c, vec3(0.04045)));
}

vec4 premultiply(vec4 c) {
	return vec4(c.rgb * c.a, c.a);
}

void main() {
	Instance r = instances[iid];
	vec2 pixel = gl_FragCoord.xy; // pixel centre, top left origin
	vec2 size = max(r.dst.zw - r.dst.xy, 1e-4);
	vec2 half_size = size * 0.5;
	vec2 local = pixel - (r.dst.xy + half_size);
	vec2 t = (pixel - r.dst.xy) / size;

	float radius = local.y < 0.0 ? (local.x < 0.0 ? r.radii.x : r.radii.y)
	                             : (local.x < 0.0 ? r.radii.z : r.radii.w);
	radius = min(radius, min(half_size.x, half_size.y));
	float w = max(r.softness, 0.5);
	float coverage = inside(box_sdf(local, half_size, radius), w);
	if (r.border > 0.0) {
		float inner = box_sdf(local, half_size - r.border, max(radius - r.border, 0.0));
		coverage *= 1.0 - inside(inner, w);
	}

	vec2 tc = clamp(t, 0.0, 1.0);
	vec4 top = mix(premultiply(r.colors[0]), premultiply(r.colors[1]), tc.x);
	vec4 bottom = mix(premultiply(r.colors[2]), premultiply(r.colors[3]), tc.x);
	vec4 c = mix(top, bottom, tc.y);
	vec3 rgb = c.a > 0.0 ? c.rgb / c.a : vec3(0.0);
	vec4 color = vec4(linear_from_srgb(rgb) * c.a, c.a);

	if ((r.flags & TEXTURED) != 0u) {
		vec2 uv = mix(r.src.xy, r.src.zw, t);
		if ((r.flags & COVERAGE) != 0u) {
			color *= (r.flags & NEAREST) != 0u ? texture(sampler2D(coverage_tex, nearest_sampler), uv) : texture(sampler2D(coverage_tex, linear_sampler), uv);
		} else {
			color *= (r.flags & NEAREST) != 0u ? texture(sampler2D(colour_tex, nearest_sampler), uv) : texture(sampler2D(colour_tex, linear_sampler), uv);
		}
	}
	out_color = color * coverage;
}
