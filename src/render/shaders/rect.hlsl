// The Direct3D 11 rect pipeline and blur, a port of rect.vert, rect.frag,
// blur.vert, blur_down.frag and blur_up.frag. Keep them doing the same.
// build.py on Windows compiles each entry point with fxc into shaders/dxbc, which
// d3d11_windows.odin loads; the bytecode is checked in so a cross-build
// needs no fxc.

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

StructuredBuffer<Instance> instances : register(t0);
Texture2D colour_tex : register(t1); // the blur's source in the blur passes
Texture2D coverage_tex : register(t2);
Texture2D backdrop_tex : register(t3);
SamplerState linear_sampler : register(s0);
SamplerState nearest_sampler : register(s1);

// target is the render target's origin and size in the drawable's pixels,
// origin the target's origin in the drawable and the drawable pixels per
// target pixel. SV_InstanceID starts at 0 for every draw, so first is the
// batch's first instance. half_pixel is half a source texel, for the blur.
cbuffer Frame : register(b0) {
	float4 target;
	float4 origin;
	float2 half_pixel;
	uint first;
	uint unused;
};

static const uint TEXTURED = 1u;
static const uint NEAREST = 2u;
static const uint COVERAGE = 4u;
static const uint BACKDROP = 8u;
static const uint ADDITIVE = 16u;
static const uint GLASS = 32u;

struct Rect_Varyings {
	float4 pos : SV_Position;
	nointerpolation uint iid : IID;
};

// The quad covers the rect plus its soft edge, cut down to the clip rect.
Rect_Varyings vs_rect(uint vid : SV_VertexID, uint instance : SV_InstanceID) {
	uint i = instance + first;
	Instance r = instances[i];
	float pad = max(r.softness, 0.5) + 1.0;
	float2 p0 = max(r.dst.xy - pad, r.clip.xy);
	float2 p1 = max(min(r.dst.zw + pad, r.clip.zw), p0);
	float2 p = lerp(p0, p1, float2(float(vid & 1u), float(vid >> 1u)));
	float2 ndc = (p - target.xy) / target.zw * 2.0 - 1.0;
	Rect_Varyings o;
	// Direct3D's clip space has y up, the pixels y down.
	o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
	o.iid = i;
	return o;
}

float box_sdf(float2 p, float2 half_size, float r) {
	float2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float inside(float d, float w) {
	return 1.0 - smoothstep(-w, w, d);
}

float3 linear_from_srgb(float3 c) {
	float3 lo = c / 12.92;
	float3 hi = pow(max((c + 0.055) / 1.055, 0.0), 2.4);
	return c <= 0.04045 ? lo : hi;
}

float4 premultiply(float4 c) {
	return float4(c.rgb * c.a, c.a);
}

float4 linear_premultiplied(float4 c) {
	return float4(linear_from_srgb(c.rgb) * c.a, c.a);
}

float4 backdrop_at(float2 uv, float4 under, float saturation) {
	float4 b = backdrop_tex.SampleLevel(linear_sampler, uv, 0);
	float luma = dot(b.rgb, float3(0.2126, 0.7152, 0.0722));
	b.rgb = max(lerp(luma.xxx, b.rgb, saturation), 0.0);
	return under + b * (1.0 - under.a);
}

float4 glass(Instance r, float2 local, float2 half_size, float radius, float2 t) {
	float d = box_sdf(local, half_size, radius);
	float2 e = float2(0.5, 0.0);
	float2 grad = float2(box_sdf(local + e.xy, half_size, radius) - box_sdf(local - e.xy, half_size, radius),
	                     box_sdf(local + e.yx, half_size, radius) - box_sdf(local - e.yx, half_size, radius));
	float2 n = grad / max(length(grad), 1e-4);
	float bevel = r.colors[2].y;
	float x = clamp(1.0 + d / bevel, 0.0, 1.0);
	float slope = 1.0 - sqrt(1.0 - x * x);

	float4 under = 0.0;
	if ((r.flags & BACKDROP) != 0u) {
		float2 uv = lerp(r.src.xy, r.src.zw, t);
		float2 per_pixel = (r.src.zw - r.src.xy) / (half_size * 2.0);
		float2 shift = n * slope * r.colors[2].x * per_pixel;
		float4 tint = linear_premultiplied(r.colors[1]);
		float sat = r.extra;
		float4 red = backdrop_at(uv + shift * 0.94, tint, sat);
		float4 green = backdrop_at(uv + shift, tint, sat);
		float4 blue = backdrop_at(uv + shift * 1.06, tint, sat);
		under = float4(red.r, green.g, blue.b, green.a);
	}
	float4 tint = linear_premultiplied(r.colors[0]);
	float4 color = tint + under * (1.0 - tint.a);

	float highlight = r.colors[2].z;
	float2 light = normalize(float2(-0.6, -1.0));
	float facing = dot(n, light);
	float line_ = 1.0 - smoothstep(0.0, r.colors[3].w, -d);
	float catch_light = 0.12 + 0.88 * pow(max(facing, 0.0), 1.5) + 0.5 * pow(max(-facing, 0.0), 1.5);
	float lit = line_ * catch_light * highlight + slope * slope * (0.2 + 0.8 * max(facing, 0.0)) * 0.2 * highlight;
	lit += 0.03 * highlight * clamp(-local.y / half_size.y, 0.0, 1.0);
	float glow_r = max(r.colors[3].z, 1.0);
	float2 to_glow = (local + r.dst.xy + half_size - r.colors[3].xy) / glow_r;
	lit += r.colors[2].w * 0.12 * exp(-2.0 * dot(to_glow, to_glow));
	color.rgb *= 1.0 - 0.3 * slope * max(-facing, 0.0);
	color.rgb += lit;
	return color;
}

float4 ps_rect(Rect_Varyings v) : SV_Target {
	Instance r = instances[v.iid];
	float2 pixel = v.pos.xy * origin.zw + origin.xy;
	float2 size = max(r.dst.zw - r.dst.xy, 1e-4);
	float2 half_size = size * 0.5;
	float2 local = pixel - (r.dst.xy + half_size);
	float2 t = (pixel - r.dst.xy) / size;

	float radius = local.y < 0.0 ? (local.x < 0.0 ? r.radii.x : r.radii.y)
	                             : (local.x < 0.0 ? r.radii.z : r.radii.w);
	radius = min(radius, min(half_size.x, half_size.y));
	float w = max(r.softness, 0.5);
	float coverage = inside(box_sdf(local, half_size, radius), w);
	if (r.border > 0.0) {
		float inner = box_sdf(local, half_size - r.border, max(radius - r.border, 0.0));
		coverage *= 1.0 - inside(inner, w);
	}

	float2 tc = saturate(t);
	float4 top = lerp(premultiply(r.colors[0]), premultiply(r.colors[1]), tc.x);
	float4 bottom = lerp(premultiply(r.colors[2]), premultiply(r.colors[3]), tc.x);
	float4 c = lerp(top, bottom, tc.y);
	float3 rgb = c.a > 0.0 ? c.rgb / c.a : 0.0;
	float4 color = float4(linear_from_srgb(rgb) * c.a, c.a);

	// The texture's coordinates and their derivatives come before the
	// branches, which vary per instance, so the mips pick as on Vulkan.
	float2 uv = lerp(r.src.xy, r.src.zw, t);
	float2 dx = ddx(uv), dy = ddy(uv);
	if ((r.flags & GLASS) != 0u) {
		color = glass(r, local, half_size, radius, t);
	} else if ((r.flags & BACKDROP) != 0u) {
		float4 b = backdrop_tex.SampleLevel(linear_sampler, uv, 0);
		float luma = dot(b.rgb, float3(0.2126, 0.7152, 0.0722));
		b.rgb = max(lerp(luma.xxx, b.rgb, r.extra), 0.0);
		color += b * (1.0 - color.a);
	} else if ((r.flags & TEXTURED) != 0u) {
		bool nearest = (r.flags & NEAREST) != 0u;
		if ((r.flags & COVERAGE) != 0u) {
			// R8 coverage samples as premultiplied white.
			float a = nearest ? coverage_tex.SampleGrad(nearest_sampler, uv, dx, dy).r : coverage_tex.SampleGrad(linear_sampler, uv, dx, dy).r;
			color *= a;
		} else {
			color *= nearest ? colour_tex.SampleGrad(nearest_sampler, uv, dx, dy) : colour_tex.SampleGrad(linear_sampler, uv, dx, dy);
		}
	}
	float4 out_color = color * coverage;
	if ((r.flags & ADDITIVE) != 0u) {
		out_color.a = r.extra * coverage;
	}
	return out_color;
}

// The dual Kawase filter (Bjorge, 2015). A full-screen triangle per pass.
struct Blur_Varyings {
	float4 pos : SV_Position;
	float2 uv : UV;
};

Blur_Varyings vs_blur(uint vid : SV_VertexID) {
	Blur_Varyings o;
	o.uv = float2(float((vid << 1u) & 2u), float(vid & 2u));
	o.pos = float4(o.uv.x * 2.0 - 1.0, 1.0 - o.uv.y * 2.0, 0.0, 1.0);
	return o;
}

float4 tap(float2 uv) {
	return colour_tex.SampleLevel(linear_sampler, uv, 0);
}

// Into a target half the source's size: the centre and four diagonal taps,
// each a bilinear average of four texels.
float4 ps_blur_down(Blur_Varyings v) : SV_Target {
	float2 h = half_pixel;
	float4 sum = tap(v.uv) * 4.0;
	sum += tap(v.uv - h);
	sum += tap(v.uv + h);
	sum += tap(v.uv + float2(h.x, -h.y));
	sum += tap(v.uv - float2(h.x, -h.y));
	return sum / 8.0;
}

// Into a target twice the source's size: eight taps on a ring.
float4 ps_blur_up(Blur_Varyings v) : SV_Target {
	float2 h = half_pixel;
	float4 sum = tap(v.uv + float2(-h.x * 2.0, 0.0));
	sum += tap(v.uv + float2(-h.x, h.y)) * 2.0;
	sum += tap(v.uv + float2(0.0, h.y * 2.0));
	sum += tap(v.uv + float2(h.x, h.y)) * 2.0;
	sum += tap(v.uv + float2(h.x * 2.0, 0.0));
	sum += tap(v.uv + float2(h.x, -h.y)) * 2.0;
	sum += tap(v.uv + float2(0.0, -h.y * 2.0));
	sum += tap(v.uv + float2(-h.x, -h.y)) * 2.0;
	return sum / 12.0;
}
