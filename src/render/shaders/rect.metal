// The Metal rect pipeline and blur. build.py on macOS compiles it into
// shaders/metallib/rect.metallib, which metal_darwin.odin loads; the library
// is checked in so a build without Xcode's Metal compiler still has it.

#include <metal_stdlib>
using namespace metal;

struct Instance {
	float4 dst;
	float4 src;
	float4 colors[4];
	float4 radii;
	float border;
	float softness;
	uint flags;
	float extra;
	float4 clip;
};

constant uint TEXTURED = 1;
constant uint NEAREST = 2;
constant uint COVERAGE = 4;
constant uint BACKDROP = 8;
constant uint ADDITIVE = 16;
constant uint GLASS = 32;

struct Fragment_In {
	float4 position [[position]];
	uint iid [[flat]];
};

// Signed distance from p to a box centred on the origin with rounded corners.
// Negative inside.
float box_sdf(float2 p, float2 half_size, float r) {
	float2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Coverage of the inside of an edge at signed distance d, blurred over w
// pixels either side. w = 0.5 is plain antialiasing.
float inside(float d, float w) {
	return 1.0 - smoothstep(-w, w, d);
}

float3 linear_from_srgb(float3 c) {
	return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

float4 premultiply(float4 c) {
	return float4(c.rgb * c.a, c.a);
}

float4 linear_premultiplied(float4 c) {
	return float4(linear_from_srgb(c.rgb) * c.a, c.a);
}

// The backdrop at uv as the backdrop instance draws it: the blur, saturated,
// under its tint. under is that tint and saturation is its extra.
float4 backdrop_at(texture2d<float> tex, sampler s, float2 uv, float4 under, float saturation) {
	float4 b = tex.sample(s, uv);
	float luma = dot(b.rgb, float3(0.2126, 0.7152, 0.0722));
	b.rgb = max(mix(float3(luma), b.rgb, saturation), 0.0);
	return under + b * (1.0 - under.a);
}

// glass is a lens over local, see push_glass in render.odin. The rim is a
// quarter circle in profile, bevel pixels wide: across it what's under the
// lens comes from further out the steeper the glass gets, and the light
// from the top left catches it, less on the far side.
float4 glass(Instance r, float2 local, float2 half_size, float radius, float2 t, texture2d<float> tex, sampler s) {
	float d = box_sdf(local, half_size, radius);
	float2 e = float2(0.5, 0.0);
	float2 grad = float2(box_sdf(local + e.xy, half_size, radius) - box_sdf(local - e.xy, half_size, radius),
	                     box_sdf(local + e.yx, half_size, radius) - box_sdf(local - e.yx, half_size, radius));
	float2 n = grad / max(length(grad), 1e-4);
	float bevel = r.colors[2].y;
	float x = clamp(1.0 + d / bevel, 0.0, 1.0); // 0 where the rim starts, 1 at the edge
	float slope = 1.0 - sqrt(1.0 - x * x);

	float4 under = float4(0.0);
	if (r.flags & BACKDROP) {
		float2 uv = mix(r.src.xy, r.src.zw, t);
		float2 per_pixel = (r.src.zw - r.src.xy) / (half_size * 2.0);
		float2 shift = n * slope * r.colors[2].x * per_pixel;
		float4 tint = linear_premultiplied(r.colors[1]);
		float sat = r.extra;
		float4 red = backdrop_at(tex, s, uv + shift * 0.94, tint, sat);
		float4 green = backdrop_at(tex, s, uv + shift, tint, sat);
		float4 blue = backdrop_at(tex, s, uv + shift * 1.06, tint, sat);
		under = float4(red.r, green.g, blue.b, green.a);
	}
	float4 tint = linear_premultiplied(r.colors[0]);
	float4 color = tint + under * (1.0 - tint.a);

	// The light, added on top as light is.
	float highlight = r.colors[2].z;
	float2 light = normalize(float2(-0.6, -1.0));
	float facing = dot(n, light);
	float line = 1.0 - smoothstep(0.0, r.colors[3].w, -d);
	float catch_light = 0.12 + 0.88 * pow(max(facing, 0.0), 1.5) + 0.5 * pow(max(-facing, 0.0), 1.5);
	float lit = line * catch_light * highlight + slope * slope * (0.2 + 0.8 * max(facing, 0.0)) * 0.2 * highlight;
	// A sheen over the top half, as the glass thins toward its top edge.
	lit += 0.03 * highlight * clamp(-local.y / half_size.y, 0.0, 1.0);
	float glow_r = max(r.colors[3].z, 1.0);
	float2 to_glow = (local + r.dst.xy + half_size - r.colors[3].xy) / glow_r;
	lit += r.colors[2].w * 0.12 * exp(-2.0 * dot(to_glow, to_glow));
	// The side away from the light bends in less light.
	color.rgb *= 1.0 - 0.3 * slope * max(-facing, 0.0);
	color.rgb += float3(lit);
	return color;
}

// The quad covers the rect plus its soft edge, cut down to the clip rect.
// The fragment shader works from the pixel position alone, so clipping the
// quad clips the shape exactly, and a clipped-away instance costs no pixels.
vertex Fragment_In rect_vertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               device const Instance *instances [[buffer(0)]],
                               constant float4 &target [[buffer(1)]]) {
	Instance r = instances[iid];
	float pad = max(r.softness, 0.5) + 1.0;
	float2 p0 = max(r.dst.xy - pad, r.clip.xy);
	float2 p1 = max(min(r.dst.zw + pad, r.clip.zw), p0);
	float2 p = mix(p0, p1, float2(vid & 1, vid >> 1));
	Fragment_In out;
	// target is the render target's origin and size in the drawable's pixels.
	out.position = float4((p - target.xy) / target.zw * float2(2, -2) + float2(-1, 1), 0, 1);
	out.iid = iid;
	return out;
}

fragment float4 rect_fragment(Fragment_In in [[stage_in]],
                              device const Instance *instances [[buffer(0)]],
                              constant float4 &target [[buffer(1)]],
                              texture2d<float> colour_tex [[texture(0)]],
                              texture2d<float> coverage_tex [[texture(1)]],
                              texture2d<float> backdrop_tex [[texture(2)]]) {
	constexpr sampler linear_sampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
	constexpr sampler nearest_sampler(filter::nearest, address::clamp_to_edge);

	Instance r = instances[in.iid];
	// The pixel centre in the drawable, top left origin. target is the render
	// target's origin in the drawable and the drawable pixels per target
	// pixel.
	float2 pixel = in.position.xy * target.zw + target.xy;
	float2 size = max(r.dst.zw - r.dst.xy, 1e-4);
	float2 half_size = size * 0.5;
	float2 local = pixel - (r.dst.xy + half_size);
	float2 t = (pixel - r.dst.xy) / size;

	float radius = local.y < 0 ? (local.x < 0 ? r.radii.x : r.radii.y)
	                           : (local.x < 0 ? r.radii.z : r.radii.w);
	radius = min(radius, min(half_size.x, half_size.y));
	float w = max(r.softness, 0.5);
	float coverage = inside(box_sdf(local, half_size, radius), w);
	if (r.border > 0) {
		float inner = box_sdf(local, half_size - r.border, max(radius - r.border, 0.0));
		coverage *= 1.0 - inside(inner, w);
	}

	float2 tc = saturate(t);
	float4 top = mix(premultiply(r.colors[0]), premultiply(r.colors[1]), tc.x);
	float4 bottom = mix(premultiply(r.colors[2]), premultiply(r.colors[3]), tc.x);
	float4 c = mix(top, bottom, tc.y);
	float3 rgb = c.a > 0 ? c.rgb / c.a : float3(0);
	float4 color = float4(linear_from_srgb(rgb) * c.a, c.a);

	if (r.flags & GLASS) {
		color = glass(r, local, half_size, radius, t, backdrop_tex, linear_sampler);
	} else if (r.flags & BACKDROP) {
		// The blur under the tint, its colours pulled away from their
		// luminance by the saturation. It's premultiplied and keeps its
		// alpha, so what was translucent under it stays so.
		float4 b = backdrop_tex.sample(linear_sampler, mix(r.src.xy, r.src.zw, t));
		float luma = dot(b.rgb, float3(0.2126, 0.7152, 0.0722));
		b.rgb = max(mix(float3(luma), b.rgb, r.extra), 0.0);
		color += b * (1.0 - color.a);
	} else if (r.flags & TEXTURED) {
		float2 uv = mix(r.src.xy, r.src.zw, t);
		if (r.flags & COVERAGE) {
			color *= (r.flags & NEAREST) ? coverage_tex.sample(nearest_sampler, uv) : coverage_tex.sample(linear_sampler, uv);
		} else {
			color *= (r.flags & NEAREST) ? colour_tex.sample(nearest_sampler, uv) : colour_tex.sample(linear_sampler, uv);
		}
	}
	color *= coverage;
	if (r.flags & ADDITIVE) {
		color.a = r.extra * coverage;
	}
	return color;
}

// The dual Kawase filter (Bjorge, 2015). A full-screen triangle per pass.
struct Blur_In {
	float4 position [[position]];
	float2 uv;
};

vertex Blur_In blur_vertex(uint vid [[vertex_id]]) {
	float2 uv = float2((vid << 1) & 2, vid & 2);
	Blur_In out;
	out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
	out.uv = uv;
	return out;
}

// Into a target half the source's size: the centre and four diagonal taps,
// each a bilinear average of four texels. half_pixel is half a source texel.
fragment float4 blur_down(Blur_In in [[stage_in]],
                          texture2d<float> src [[texture(0)]],
                          constant float2 &half_pixel [[buffer(0)]]) {
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float2 uv = in.uv;
	float2 h = half_pixel;
	float4 sum = src.sample(s, uv) * 4.0;
	sum += src.sample(s, uv - h);
	sum += src.sample(s, uv + h);
	sum += src.sample(s, uv + float2(h.x, -h.y));
	sum += src.sample(s, uv - float2(h.x, -h.y));
	return sum / 8.0;
}

// Into a target twice the source's size: eight taps on a ring.
fragment float4 blur_up(Blur_In in [[stage_in]],
                        texture2d<float> src [[texture(0)]],
                        constant float2 &half_pixel [[buffer(0)]]) {
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float2 uv = in.uv;
	float2 h = half_pixel;
	float4 sum = src.sample(s, uv + float2(-h.x * 2.0, 0.0));
	sum += src.sample(s, uv + float2(-h.x, h.y)) * 2.0;
	sum += src.sample(s, uv + float2(0.0, h.y * 2.0));
	sum += src.sample(s, uv + float2(h.x, h.y)) * 2.0;
	sum += src.sample(s, uv + float2(h.x * 2.0, 0.0));
	sum += src.sample(s, uv + float2(h.x, -h.y)) * 2.0;
	sum += src.sample(s, uv + float2(0.0, -h.y * 2.0));
	sum += src.sample(s, uv + float2(-h.x, -h.y)) * 2.0;
	return sum / 12.0;
}
