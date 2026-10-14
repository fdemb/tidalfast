package tidal

import "core:strings"

// mix_get fetches a mix and its items from pages/mix.
mix_get :: proc(s: ^Session, mix_id: string, allocator := context.allocator) -> (mix: Mix, err: Error) {
	header, items := fetch_mix_page(s, mix_id, allocator) or_return
	mix = header
	if mix.id == "" {
		mix.id = strings.clone(mix_id, allocator)
	}
	mix.items = items
	mix.retrieved = true
	return mix, nil
}

// mix_v2_get fetches a v2 mix by id. The mix page has the v1 header shape,
// so the v2-only fields stay empty.
mix_v2_get :: proc(s: ^Session, mix_id: string, allocator := context.allocator) -> (mix: Mix_V2, err: Error) {
	header, items := fetch_mix_page(s, mix_id, allocator) or_return
	mix.id = header.id if header.id != "" else strings.clone(mix_id, allocator)
	mix.title = header.title
	mix.sub_title = header.sub_title
	mix.short_subtitle = header.short_subtitle
	mix.mix_type_name = header.mix_type_name
	mix.content_behavior = header.content_behaviour
	mix.images = header.images
	mix.items = items
	mix.retrieved = true
	return mix, nil
}

@(private = "file")
fetch_mix_page :: proc(s: ^Session, mix_id: string, allocator: Allocator) -> (header: Mix, items: []Media, err: Error) {
	scratch_begin(allocator)
	params := make_params()
	add_param(&params, "mixId", mix_id)
	add_param(&params, "deviceType", "BROWSER")
	obj, rerr := request_object(s, {method = .GET, path = "pages/mix", params = params[:]}, context.temp_allocator)
	if rerr != nil {
		return {}, nil, remap_error(rerr, .Object_Not_Found, "Mix not found", "Mix unavailable")
	}
	// An empty page means the mix is not available.
	if rows, _ := jarr(obj, "rows"); len(rows) <= 1 {
		return {}, nil, make_error(.Object_Not_Found, "Mix not found")
	}
	p := parser_make(s, allocator)
	page := parse_page(&p, obj)
	if len(page.categories) <= 1 {
		return {}, nil, make_error(.Object_Not_Found, "Mix not found")
	}
	if h, ok := page.categories[0].(Item_Header); ok {
		header, _ = h.item.(Mix)
	}
	if list, ok := page.categories[1].(Item_List); ok {
		out := make([dynamic]Media, 0, len(list.items), allocator)
		for item in list.items {
			#partial switch v in item {
			case Track:
				append(&out, v)
			case Video:
				append(&out, v)
			}
		}
		items = out[:]
	}
	return header, items, nil
}

// mix_image_url returns the mix picture. Sizes: 320, 640, 1500.
mix_image_url :: proc(m: Mix, size := 320) -> (url: string, err: Error) {
	images, ok := m.images.?
	if !ok {
		return "", make_error(.Asset_Not_Available, "No images present.")
	}
	return pick_mix_image(images, size)
}

// mix_v2_image_url returns the mix picture. Sizes: 320, 640, 1500.
mix_v2_image_url :: proc(m: Mix_V2, size := 320) -> (url: string, err: Error) {
	images, ok := m.images.?
	if !ok {
		return "", make_error(.Asset_Not_Available, "No images present.")
	}
	return pick_mix_image(images, size)
}

@(private = "file")
pick_mix_image :: proc(images: Image_Response, size: int) -> (string, Error) {
	switch size {
	case 320:
		return images.small, nil
	case 640:
		return images.medium, nil
	case 1500:
		return images.large, nil
	}
	return "", invalid_resolution(size, size)
}
