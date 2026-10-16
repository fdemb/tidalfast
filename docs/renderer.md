# Renderer

`src/render` draws everything as instances of one quad. Each instance is a rounded box drawn with a signed distance function in the fragment shader. It has four corner colours, four corner radii, a border width, an edge softness, a clip rect, and an optional texture with a source rect. A shadow is a soft-edged box drawn under the real one (`push_shadow`).

The API takes points. The renderer multiplies by the backing scale and rounds rect edges, clip rects and borders to whole pixels, so a 1 pt border is exactly 2 pixels at 2x.

Colours are sRGB with straight alpha, as a design tool shows them. The drawable is `BGRA8Unorm_sRGB`, so the GPU blends in linear space. The shader interpolates gradient colours in premultiplied sRGB, which matches CSS gradients, then converts to linear before blending. Glyph coverage blends in linear space the same way.

Textures come from `texture_create`, `texture_update` and `texture_destroy`. A `Texture` handle carries a generation, so a stale handle draws solid colour. The zero handle is a 1x1 white texture and means "no texture". Formats:

- `R8` is linear coverage for the glyph atlas. The texture swizzle makes it sample as premultiplied white.
- `RGBA8` and `BGRA8` take sRGB colour with alpha premultiplied in sRGB space. That's what a premultiplied `CGBitmapContext` produces, so CoreGraphics output (emoji, decoded images) goes in as is. Pass `mipmapped = true` for a texture drawn smaller than it is. Every update then regenerates the mips.

Colour textures are stored as `_sRGB` formats, and the GPU decodes sRGB before it filters. Uploading premultiplied sRGB bytes directly would decode `alpha * c` instead of giving `alpha * decode(c)`, which makes every translucent texel too dark: 50% white over black came out as 128 instead of 188. So each translucent texel is rewritten as the sRGB encoding of its premultiplied linear colour, `encode(decode(c / a) * a)`. The sample is then premultiplied linear, the same thing the shader makes from a solid colour, and filtering and mipmapping average the right values. Opaque and fully transparent texels don't change, so opaque cover art costs only a scan. The test screen has a black strip with 50% white three ways (an `RGBA8` texel, an `R8` texel and a solid rect), and all three read 188 in a capture.

The rewrite is `convert_premultiplied`, which works in place and touches no renderer state, so a decode worker can run it and pass `converted = true` to `texture_update`. Otherwise `texture_update` runs it on a copy when some texel is translucent. It reads a 256×256 table indexed by alpha and channel byte, built when the dylib loads; a test checks all 65,536 entries against the formula. A 2048×2048 texture with every texel translucent now takes 7 ms to convert and upload with mips, down from 216 ms, in an optimized build (179 ms, from 893 ms, in debug).

`texture_update` writes on the CPU straight away. A mipmapped texture remembers the command buffer of its last mip generation, which reads the whole base level, and the next write waits for it. The glyph atlas has no mips, so its writes never wait.

Batching: a draw call binds two textures, one colour (`RGBA8` or `BGRA8`) and one coverage (`R8`), and an instance flag says which one it samples. Solid instances don't sample, so they join whatever batch is open. A new draw call starts only when a textured instance needs a texture of its kind other than the one the batch already binds. So a list of covers from one page with their labels in the glyph atlas is one draw call. The mock's library took 37 draw calls a frame when each cover and the label next to it broke the batch, and takes 3 now. Clipping is per instance: the vertex shader cuts the quad down to the clip rect, so changing the clip never breaks a batch.

The instance buffer is triple buffered. Each frame writes into one of three shared `MTLBuffer`s and keeps its command buffer. When the slot comes round again, `begin_frame` waits for that command buffer, which has almost always finished already. If a frame pushes more instances than its buffer holds, that slot's buffer doubles, the frame's instances so far are copied over, and the frame keeps going. Each slot keeps its own size, so a slot that grew stays big and the others grow only when they need to.
