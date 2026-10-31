package tidal

import "core:encoding/json"
import "core:log"

// page_get fetches a page from the /pages endpoints, e.g. "pages/explore".
// deviceType defaults to BROWSER.
page_get :: proc(s: ^Session, endpoint: string, params: []Param = nil, allocator := context.allocator) -> (page: Page, err: Error) {
	return fetch_page(s, endpoint, params, "BROWSER", allocator)
}

@(private)
fetch_page :: proc(s: ^Session, endpoint: string, params: []Param, device_type: string, allocator: Allocator) -> (page: Page, err: Error) {
	scratch_begin(allocator)
	all := make_params()
	has_device := false
	for p in params {
		if p.key == "deviceType" {
			has_device = true
		}
	}
	if !has_device {
		add_param(&all, "deviceType", device_type)
	}
	append(&all, ..params)
	obj := request_object(s, {method = .GET, path = endpoint, params = all[:]}, context.temp_allocator) or_return
	p := parser_make(s, allocator)
	return parse_page(&p, obj), nil
}

// page_link_get fetches the page a Page_Link points to.
page_link_get :: proc(s: ^Session, link: Page_Link, allocator := context.allocator) -> (page: Page, err: Error) {
	return fetch_page(s, link.api_path, nil, "DESKTOP", allocator)
}

// page_more fetches the full list behind a category's "show more" or "view
// all" link.
page_more :: proc(s: ^Session, more: More, allocator := context.allocator) -> (page: Page, err: Error) {
	page = page_get(s, more.api_path, nil, allocator) or_return
	if page.title == "" {
		page.title = more.title
	}
	return page, nil
}

// page_item_get fetches the full object a featured Page_Item points to.
page_item_get :: proc(s: ^Session, item: Page_Item, allocator := context.allocator) -> (result: Item, err: Error) {
	switch item.type {
	case "PLAYLIST":
		return playlist_get(s, item.artifact_id, allocator)
	case "VIDEO", "TRACK", "ARTIST", "ALBUM":
		id := value_i64(json.String(item.artifact_id), -1)
		if id < 0 {
			return nil, make_error(.Invalid_Argument, "Invalid artifact id")
		}
		switch item.type {
		case "VIDEO":
			return video_get(s, id, allocator)
		case "TRACK":
			return track_get(s, id, allocator = allocator)
		case "ARTIST":
			return artist_get(s, id, allocator)
		case "ALBUM":
			return album_get(s, id, allocator)
		}
	}
	return nil, make_error(.Invalid_Argument, "PageItem type not implemented")
}

// page_flatten lists every item on the page in reading order, like
// Text blocks and link lists are skipped.
page_flatten :: proc(page: Page, allocator := context.allocator) -> []Item {
	out := make([dynamic]Item, allocator)
	for category in page.categories {
		switch c in category {
		case Item_List:
			append(&out, ..c.items)
		case Page_Links:
			for l in c.items {
				append(&out, l)
			}
		case Featured_Items:
			for i in c.items {
				append(&out, i)
			}
		case Item_Header:
			append(&out, c.item)
		case Text_Block, Link_List:
		}
	}
	return out[:]
}

// parse_page parses a page's rows. Unknown module types are skipped.
parse_page :: proc(p: ^Parser, obj: json.Object) -> Page {
	page := Page{title = pstr(p, obj, "title")}
	categories := make([dynamic]Page_Category, p.allocator)
	rows, _ := jarr(obj, "rows")
	for row in rows {
		row_obj := row.(json.Object) or_continue
		modules, _ := jarr(row_obj, "modules")
		if len(modules) == 0 {
			continue
		}
		module := modules[0].(json.Object) or_continue
		if c, parsed := parse_category(p, module); parsed {
			append(&categories, c)
		}
	}
	page.categories = categories[:]
	return page
}

@(private)
parse_more :: proc(p: ^Parser, obj: json.Object) -> Maybe(More) {
	if show_more, ok := jobj(obj, "showMore"); ok {
		return More{api_path = pstr(p, show_more, "apiPath"), title = pstr(p, show_more, "title")}
	}
	if jhas(obj, "viewAll") {
		return More{api_path = pstr(p, obj, "viewAll"), title = pstr(p, obj, "title")}
	}
	return nil
}

@(private)
Typed_Parser :: enum {
	Album,
	Artist,
	Track,
	Playlist,
	Video,
	Mix,
}

@(private)
parse_typed_list :: proc(p: ^Parser, list: json.Object, kind: Typed_Parser) -> []Item {
	items, _ := jarr(list, "items")
	out := make([dynamic]Item, 0, len(items), p.allocator)
	for v in items {
		obj := v.(json.Object) or_continue
		if inner, has := jobj(obj, "item"); has {
			p.date_added = obj["created"]
			obj = inner
		}
		switch kind {
		case .Album:
			append(&out, parse_album(p, obj))
		case .Artist:
			append(&out, parse_artist(p, obj))
		case .Track:
			append(&out, parse_track(p, obj))
		case .Playlist:
			append(&out, parse_playlist(p, obj))
		case .Video:
			append(&out, parse_video(p, obj))
		case .Mix:
			append(&out, parse_mix(p, obj))
		}
		p.date_added = nil
	}
	return out[:]
}

@(private)
parse_category :: proc(p: ^Parser, obj: json.Object) -> (category: Page_Category, ok: bool) {
	category_type := jstr(obj, "type")
	paged, _ := jobj(obj, "pagedList")

	list_base :: proc(p: ^Parser, obj: json.Object) -> Item_List {
		return Item_List{type = pstr(p, obj, "type"), title = pstr(p, obj, "title"), description = pstr(p, obj, "description"), more = parse_more(p, obj)}
	}

	switch category_type {
	case "PAGE_LINKS_CLOUD", "PAGE_LINKS":
		links := Page_Links {
			title = pstr(p, obj, "title"),
			more  = parse_more(p, obj),
		}
		items, _ := jarr(paged, "items")
		out := make([dynamic]Page_Link, 0, len(items), p.allocator)
		for v in items {
			item := v.(json.Object) or_continue
			append(&out, Page_Link{title = pstr(p, item, "title"), icon = pstr(p, item, "icon"), api_path = pstr(p, item, "apiPath"), image_id = pstr(p, item, "imageId")})
		}
		links.items = out[:]
		return links, true

	case "FEATURED_PROMOTIONS", "MULTIPLE_TOP_PROMOTIONS":
		featured := Featured_Items {
			title       = pstr(p, obj, "title"),
			description = pstr(p, obj, "description"),
		}
		items, _ := jarr(obj, "items")
		out := make([dynamic]Page_Item, 0, len(items), p.allocator)
		for v in items {
			item := v.(json.Object) or_continue
			append(
				&out,
				Page_Item {
					header = pstr(p, item, "header"),
					short_header = pstr(p, item, "shortHeader"),
					short_sub_header = pstr(p, item, "shortSubHeader"),
					image_id = pstr(p, item, "imageId"),
					type = pstr(p, item, "type"),
					artifact_id = value_id_string(item["artifactId"], p.allocator),
					text = pstr(p, item, "text"),
					featured = jbool(item, "featured"),
				},
			)
		}
		featured.items = out[:]
		return featured, true

	case "ALBUM_LIST", "ARTIST_LIST", "TRACK_LIST", "PLAYLIST_LIST", "VIDEO_LIST", "MIX_LIST":
		kind: Typed_Parser
		switch category_type {
		case "ALBUM_LIST":
			kind = .Album
		case "ARTIST_LIST":
			kind = .Artist
		case "TRACK_LIST":
			kind = .Track
		case "PLAYLIST_LIST":
			kind = .Playlist
		case "VIDEO_LIST":
			kind = .Video
		case "MIX_LIST":
			kind = .Mix
		}
		list := list_base(p, obj)
		list.items = parse_typed_list(p, paged, kind)
		return list, true

	case "MIX_HEADER":
		mix, _ := jobj(obj, "mix")
		return Item_Header{item = parse_mix(p, mix)}, true

	case "ARTIST_HEADER":
		artist_obj, _ := jobj(obj, "artist")
		artist := parse_artist(p, artist_obj)
		// "bio" is an object with the text and its source.
		if bio, is_obj := jobj(obj, "bio"); is_obj {
			artist.bio = pstr(p, bio, "text")
		} else {
			artist.bio = pstr(p, obj, "bio")
		}
		return Item_Header{item = artist}, true

	case "ALBUM_HEADER":
		album, _ := jobj(obj, "album")
		return Item_Header{item = parse_album(p, album)}, true

	case "HIGHLIGHT_MODULE":
		// Unwrap the highlights, dropping their subtitles.
		list := list_base(p, obj)
		highlights, _ := jarr(obj, "highlights")
		out := make([dynamic]Item, 0, len(highlights), p.allocator)
		for v in highlights {
			h := v.(json.Object) or_continue
			entry := jobj(h, "item") or_continue
			inner := jobj(entry, "item") or_continue
			if item, parsed := parse_item_by_type(p, jstr(entry, "type"), inner); parsed {
				append(&out, item)
			}
		}
		list.items = out[:]
		return list, true

	case "MIXED_TYPES_LIST", "ALBUM_ITEMS", "ITEM_LIST_WITH_ROLES":
		list := list_base(p, obj)
		list.items = map_any_items(p, paged)
		return list, true

	case "TEXT_BLOCK":
		return Text_Block{text = pstr(p, obj, "text"), icon = pstr(p, obj, "icon")}, true

	case "ARTICLE_LIST", "SOCIAL":
		links := Link_List {
			title       = pstr(p, obj, "title"),
			description = pstr(p, obj, "description"),
		}
		items: json.Array
		if category_type == "ARTICLE_LIST" {
			items, _ = jarr(paged, "items")
		} else {
			items, _ = jarr(obj, "socialProfiles")
		}
		out := make([dynamic]Link, 0, len(items), p.allocator)
		for v in items {
			item := v.(json.Object) or_continue
			url := pstr(p, item, "link") if jhas(item, "link") else pstr(p, item, "url")
			append(&out, Link{type = pstr(p, item, "type"), title = pstr(p, item, "title"), url = url})
		}
		links.items = out[:]
		return links, true
	}

	log.debugf("PageType %s not implemented", category_type)
	return nil, false
}
