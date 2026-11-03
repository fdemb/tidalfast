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
	float extra;
	vec4 clip;
};

layout(std430, set = 0, binding = 0) readonly buffer Instances {
	Instance instances[];
};
layout(set = 0, binding = 1) uniform sampler linear_sampler;
layout(set = 0, binding = 2) uniform sampler nearest_sampler;
layout(set = 1, binding = 0) uniform texture2D colour_tex;
layout(set = 2, binding = 0) uniform texture2D coverage_tex;
layout(set = 3, binding = 0) uniform texture2D backdrop_tex;

// See rect.vert. origin is the render target's origin in the drawable and
// the drawable pixels per target pixel.
layout(push_constant) uniform Push {
	vec4 target;
	vec4 origin;
} push;

layout(location = 0) flat in uint iid;
layout(location = 0) out vec4 out_color;

const uint TEXTURED = 1u;
const uint NEAREST = 2u;
const uint COVERAGE = 4u;
const uint BACKDROP = 8u;
const uint ADDITIVE = 16u;
const uint GLASS = 32u;

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

vec4 linear_premultiplied(vec4 c) {
	return vec4(linear_from_srgb(c.rgb) * c.a, c.a);
}

// The backdrop at uv as the backdrop instance draws it: the blur, saturated,
// under its tint. under is that tint and saturation is its extra.
vec4 backdrop_at(vec2 uv, vec4 under, float saturation) {
	vec4 b = texture(sampler2D(backdrop_tex, linear_sampler), uv);
	float luma = dot(b.rgb, vec3(0.2126, 0.7152, 0.0722));
	b.rgb = max(mix(vec3(luma), b.rgb, saturation), 0.0);
	return under + b * (1.0 - under.a);
}

// glass is a lens over local, see push_glass in render.odin. The rim is a
// quarter circle in profile, bevel pixels wide: across it what's under the
// lens comes from further out the steeper the glass gets, and the light
// from the top left catches it, less on the far side.
vec4 glass(Instance r, vec2 local, vec2 half_size, float radius, vec2 t) {
	float d = box_sdf(local, half_size, radius);
	vec2 e = vec2(0.5, 0.0);
	vec2 grad = vec2(box_sdf(local + e.xy, half_size, radius) - box_sdf(local - e.xy, half_size, radius),
	                 box_sdf(local + e.yx, half_size, radius) - box_sdf(local - e.yx, half_size, radius));
	vec2 n = grad / max(length(grad), 1e-4);
	float bevel = r.colors[2].y;
	float x = clamp(1.0 + d / bevel, 0.0, 1.0); // 0 where the rim starts, 1 at the edge
	float slope = 1.0 - sqrt(1.0 - x * x);

	vec4 under = vec4(0.0);
	if ((r.flags & BACKDROP) != 0u) {
		vec2 uv = mix(r.src.xy, r.src.zw, t);
		vec2 per_pixel = (r.src.zw - r.src.xy) / (half_size * 2.0);
		vec2 shift = n * slope * r.colors[2].x * per_pixel;
		vec4 tint = linear_premultiplied(r.colors[1]);
		float sat = r.extra;
		vec4 red = backdrop_at(uv + shift * 0.94, tint, sat);
		vec4 green = backdrop_at(uv + shift, tint, sat);
		vec4 blue = backdrop_at(uv + shift * 1.06, tint, sat);
		under = vec4(red.r, green.g, blue.b, green.a);
	}
	vec4 tint = linear_premultiplied(r.colors[0]);
	vec4 color = tint + under * (1.0 - tint.a);

	// The light, added on top as light is.
	float highlight = r.colors[2].z;
	vec2 light = normalize(vec2(-0.6, -1.0));
	float facing = dot(n, light);
	float line = 1.0 - smoothstep(0.0, r.colors[3].w, -d);
	float catch_light = 0.12 + 0.88 * pow(max(facing, 0.0), 1.5) + 0.5 * pow(max(-facing, 0.0), 1.5);
	float lit = line * catch_light * highlight + slope * slope * (0.2 + 0.8 * max(facing, 0.0)) * 0.2 * highlight;
	// A sheen over the top half, as the glass thins toward its top edge.
	lit += 0.03 * highlight * clamp(-local.y / half_size.y, 0.0, 1.0);
	float glow_r = max(r.colors[3].z, 1.0);
	vec2 to_glow = (local + r.dst.xy + half_size - r.colors[3].xy) / glow_r;
	lit += r.colors[2].w * 0.12 * exp(-2.0 * dot(to_glow, to_glow));
	// The side away from the light bends in less light.
	color.rgb *= 1.0 - 0.3 * slope * max(-facing, 0.0);
	color.rgb += vec3(lit);
	return color;
}

void main() {
	Instance r = instances[iid];
	// The pixel centre in the drawable, top left origin.
	vec2 pixel = gl_FragCoord.xy * push.origin.zw + push.origin.xy;
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

	if ((r.flags & GLASS) != 0u) {
		color = glass(r, local, half_size, radius, t);
	} else if ((r.flags & BACKDROP) != 0u) {
		// The blur under the tint, its colours pulled away from their
		// luminance by the saturation. It's premultiplied and keeps its
		// alpha, so what was translucent under it stays so.
		vec4 b = texture(sampler2D(backdrop_tex, linear_sampler), mix(r.src.xy, r.src.zw, t));
		float luma = dot(b.rgb, vec3(0.2126, 0.7152, 0.0722));
		b.rgb = max(mix(vec3(luma), b.rgb, r.extra), 0.0);
		color += b * (1.0 - color.a);
	} else if ((r.flags & TEXTURED) != 0u) {
		vec2 uv = mix(r.src.xy, r.src.zw, t);
		if ((r.flags & COVERAGE) != 0u) {
			color *= (r.flags & NEAREST) != 0u ? texture(sampler2D(coverage_tex, nearest_sampler), uv) : texture(sampler2D(coverage_tex, linear_sampler), uv);
		} else {
			color *= (r.flags & NEAREST) != 0u ? texture(sampler2D(colour_tex, nearest_sampler), uv) : texture(sampler2D(colour_tex, linear_sampler), uv);
		}
	}
	out_color = color * coverage;
	if ((r.flags & ADDITIVE) != 0u) {
		out_color.a = r.extra * coverage;
	}
}
