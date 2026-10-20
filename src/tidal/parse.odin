package tidal

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

// Parser turns TIDAL JSON into models. Everything it produces is allocated
// with `allocator`. Public so an app can parse cached responses.
Parser :: struct {
	allocator:       mem.Allocator,
	listen_base_url: string,
	share_base_url:  string,
	has_user:        bool,
	user_id:         i64,
	user_kind:       User_Kind,

	// Context for the generic list mappers, which take no extra arguments.
	album:           ^Album, // parent album for parse_track/parse_media
	date_added:      json.Value, // overrides "dateAdded" of the next item
	artist_roles:    json.Value, // overrides "artistRoles" of the next item
}

parser_make :: proc(s: ^Session, allocator := context.allocator) -> Parser {
	p := Parser {
		allocator       = allocator,
		listen_base_url = s.config.listen_base_url,
		share_base_url  = s.config.share_base_url,
	}
	sync.guard(&s.mutex)
	if u, ok := s.user.?; ok {
		p.has_user = true
		p.user_id = u.id
		p.user_kind = u.kind
	}
	return p
}

@(private)
pstr :: proc(p: ^Parser, obj: json.Object, key: string) -> string {
	return strings.clone(jstr(obj, key), p.allocator)
}

@(private)
pstrings :: proc(p: ^Parser, obj: json.Object, key: string) -> []string {
	arr, ok := jarr(obj, key)
	if !ok {
		return nil
	}
	out := make([dynamic]string, 0, len(arr), p.allocator)
	for v in arr {
		if s, is_str := v.(json.String); is_str {
			append(&out, strings.clone(s, p.allocator))
		}
	}
	return out[:]
}

@(private)
date_added :: proc(p: ^Parser, obj: json.Object) -> Maybe(time.Time) {
	if s, ok := p.date_added.(json.String); ok {
		if t, tok := parse_datetime(s); tok {
			return t
		}
	}
	return jdate(obj, "dateAdded")
}

@(private)
artist_role_from_string :: proc(s: string) -> Artist_Role {
	switch s {
	case "MAIN":
		return .Main
	case "FEATURED":
		return .Featured
	case "CONTRIBUTOR":
		return .Contributor
	case "ARTIST":
		return .Artist
	}
	return .Unknown
}

parse_artist :: proc(p: ^Parser, obj: json.Object) -> Artist {
	a: Artist
	a.id = ji64(obj, "id")
	a.name = pstr(p, obj, "name")

	// Artists do not have roles as playlist creators.
	if jtruthy(obj["type"]) || jtruthy(obj["artistTypes"]) {
		roles := make([dynamic]Artist_Role, 0, 2, p.allocator)
		if types, ok := jarr(obj, "artistTypes"); ok {
			for t in types {
				if str, is_str := t.(json.String); is_str {
					append(&roles, artist_role_from_string(str))
				}
			}
		} else {
			append(&roles, artist_role_from_string(jstr(obj, "type")))
		}
		a.roles = roles[:]
		if len(roles) > 0 {
			a.role = roles[0]
		}
	}

	a.picture = pstr(p, obj, "picture")
	if !jhas(obj, "picture") {
		a.picture = DEFAULT_ARTIST_IMG
	}
	a.user_date_added = date_added(p, obj)
	a.listen_url = fmt.aprintf("%s/artist/%d", p.listen_base_url, a.id, allocator = p.allocator)
	a.share_url = fmt.aprintf("%s/artist/%d", p.share_base_url, a.id, allocator = p.allocator)
	return a
}

parse_artists :: proc(p: ^Parser, arr: json.Array) -> []Artist {
	out := make([]Artist, len(arr), p.allocator)
	n := 0
	for v in arr {
		if obj, ok := v.(json.Object); ok {
			out[n] = parse_artist(p, obj)
			n += 1
		}
	}
	return out[:n]
}

// primary_artist parses obj, the JSON's "artist". When it has the same id as
// artists[0] it returns that instead, so the two share one Artist.
@(private = "file")
primary_artist :: proc(p: ^Parser, obj: json.Object, artists: []Artist) -> ^Artist {
	if len(artists) > 0 && ji64(obj, "id") == artists[0].id {
		return &artists[0]
	}
	return new_clone(parse_artist(p, obj), p.allocator)
}

// parse_album parses an album. Pass artists (have_artists = true) to reuse
// the artists already parsed for a track instead of the album JSON's.
parse_album :: proc(p: ^Parser, obj: json.Object, artist: ^Artist = nil, artists: []Artist = nil, have_artists := false) -> Album {
	artist, artists := artist, artists
	if !have_artists {
		// The artists can be missing or empty, e.g. for removed albums
		if arr, ok := jarr(obj, "artists"); ok {
			artists = parse_artists(p, arr)
		}
	}

	// Sometimes the artist field is not filled, an example is 140196345
	if !jhas(obj, "artist") {
		// Without any artist information, keep the artist we were given (if any)
		if len(artists) > 0 {
			artist = &artists[0]
		}
	} else if artist == nil {
		artist = primary_artist(p, obj["artist"].(json.Object) or_else nil, artists)
	}

	a: Album
	a.id = ji64(obj, "id")
	a.name = pstr(p, obj, "title")
	a.cover = pstr(p, obj, "cover")
	a.video_cover = pstr(p, obj, "videoCover")
	a.duration = jint(obj, "duration")
	a.available = jbool(obj, "streamReady")
	a.ad_supported_ready = jbool(obj, "adSupportedStreamReady")
	a.dj_ready = jbool(obj, "djReady")
	a.allow_streaming = jbool(obj, "allowStreaming")
	a.premium_streaming_only = jbool(obj, "premiumStreamingOnly")
	a.num_tracks = jint(obj, "numberOfTracks")
	a.num_videos = jint(obj, "numberOfVideos")
	a.num_volumes = jint(obj, "numberOfVolumes")
	a.copyright = pstr(p, obj, "copyright")
	a.upc = pstr(p, obj, "upc")
	a.version = pstr(p, obj, "version")
	a.explicit = jbool(obj, "explicit")
	a.popularity = jint(obj, "popularity", -1)
	a.type = pstr(p, obj, "type")
	a.audio_quality = pstr(p, obj, "audioQuality")
	a.audio_modes = pstrings(p, obj, "audioModes")
	if meta, ok := jobj(obj, "mediaMetadata"); ok {
		a.media_metadata_tags = pstrings(p, meta, "tags")
	}
	a.artist = artist
	a.artists = artists
	a.release_date = jdate(obj, "releaseDate")
	a.tidal_release_date = jdate(obj, "streamStartDate")
	a.user_date_added = date_added(p, obj)
	a.listen_url = fmt.aprintf("%s/album/%d", p.listen_base_url, a.id, allocator = p.allocator)
	a.share_url = fmt.aprintf("%s/album/%d", p.share_base_url, a.id, allocator = p.allocator)
	return a
}

// List-mapper adapter: albums.
@(private)
parse_album_simple :: proc(p: ^Parser, obj: json.Object) -> Album {
	return parse_album(p, obj)
}

@(private)
parse_media_info :: proc(p: ^Parser, obj: json.Object, m: ^Media_Info, album: ^Album) {
	// The artists can be missing or empty, e.g. for tracks that were removed
	artists: []Artist
	if arr, ok := jarr(obj, "artists"); ok {
		artists = parse_artists(p, arr)
	}

	// Sometimes the artist field is not filled, example: 62300893
	artist: ^Artist
	if a, ok := jobj(obj, "artist"); ok {
		artist = primary_artist(p, a, artists)
	} else if len(artists) > 0 {
		artist = &artists[0]
	}

	album := album
	if album == nil {
		if a, ok := jobj(obj, "album"); ok && len(a) > 0 {
			album = new_clone(parse_album(p, a, artist, artists, true), p.allocator)
		}
	}
	m.album = album

	m.id = ji64(obj, "id")
	m.title = pstr(p, obj, "title")
	m.duration = jint(obj, "duration")
	m.explicit = jbool(obj, "explicit")
	m.allow_streaming = jbool(obj, "allowStreaming")
	m.stream_ready = jbool(obj, "streamReady")
	m.stem_ready = jbool(obj, "stemReady")
	m.dj_ready = jbool(obj, "djReady")
	m.ad_supported_stream_ready = jbool(obj, "adSupportedStreamReady")
	// Removed media does not have a release date
	m.stream_start_date = jdate(obj, "streamStartDate")
	// Items from playlists and favorites have a date added attribute.
	m.date_added = date_added(p, obj)
	m.track_num = jint(obj, "trackNumber", 1)
	m.volume_num = jint(obj, "volumeNumber", 1)
	m.popularity = jint(obj, "popularity", -1)
	m.artist = artist
	m.artists = artists
	m.type = pstr(p, obj, "type")

	roles_value := p.artist_roles if p.artist_roles != nil else obj["artistRoles"]
	if roles, ok := roles_value.(json.Array); ok {
		out := make([dynamic]Role_Credit, 0, len(roles), p.allocator)
		for r in roles {
			if ro, is_obj := r.(json.Object); is_obj {
				append(&out, Role_Credit{category_id = ji64(ro, "categoryId"), category = pstr(p, ro, "category")})
			}
		}
		m.artist_roles = out[:]
	}
}

// parse_track parses a track. Pass album to share it instead of parsing the
// sparse album in the track JSON.
parse_track :: proc(p: ^Parser, obj: json.Object, album: ^Album = nil) -> Track {
	t: Track
	parse_media_info(p, obj, &t.media, album)
	t.pay_to_stream = jbool(obj, "payToStream")
	t.premium_streaming_only = jbool(obj, "premiumStreamingOnly")
	t.editable = jbool(obj, "editable")
	t.upload = jbool(obj, "upload")
	t.spotlighted = jbool(obj, "spotlighted")

	t.url = pstr(p, obj, "url")
	if t.album != nil {
		t.listen_url = fmt.aprintf("%s/album/%d/track/%d", p.listen_base_url, t.album.id, t.id, allocator = p.allocator)
	} else {
		t.listen_url = fmt.aprintf("%s/track/%d", p.listen_base_url, t.id, allocator = p.allocator)
	}
	t.share_url = fmt.aprintf("%s/track/%d", p.share_base_url, t.id, allocator = p.allocator)

	t.audio_quality = pstr(p, obj, "audioQuality")
	t.audio_modes = pstrings(p, obj, "audioModes")

	// Fields that are only valid when the track is available
	if t.allow_streaming {
		t.access_type = pstr(p, obj, "accessType") if jhas(obj, "accessType") else "None"
		if meta, ok := jobj(obj, "mediaMetadata"); ok {
			t.media_metadata_tags = pstrings(p, meta, "tags")
		}
		if jhas(obj, "index") {
			t.index = ji64(obj, "index")
		}
		t.item_uuid = pstr(p, obj, "itemUuid")
		t.isrc = pstr(p, obj, "isrc")
		t.description = pstr(p, obj, "description")
		t.version = pstr(p, obj, "version")
		t.copyright = pstr(p, obj, "copyright")
		t.bpm = jint(obj, "bpm")
		t.key = pstr(p, obj, "key")
		t.key_scale = pstr(p, obj, "keyScale")
		t.peak = jf64(obj, "peak")
		t.replay_gain = jf64(obj, "replayGain")
		if mixes, ok := jobj(obj, "mixes"); ok {
			t.mixes = make(map[string]string, len(mixes), p.allocator)
			for k, v in mixes {
				if id, is_str := v.(json.String); is_str {
					t.mixes[strings.clone(k, p.allocator)] = strings.clone(id, p.allocator)
				}
			}
		}
	}

	if t.version != "" {
		t.full_name = fmt.aprintf("%s (%s)", t.title, t.version, allocator = p.allocator)
	} else {
		t.full_name = t.title
	}
	return t
}

// List-mapper adapter: tracks, sharing p.album when set.
@(private)
parse_track_in_album :: proc(p: ^Parser, obj: json.Object) -> Track {
	return parse_track(p, obj, p.album)
}

parse_video :: proc(p: ^Parser, obj: json.Object, album: ^Album = nil) -> Video {
	v: Video
	parse_media_info(p, obj, &v.media, album)
	v.release_date = jdate(obj, "releaseDate")
	v.video_quality = pstr(p, obj, "quality")
	v.image_id = pstr(p, obj, "imageId")
	v.image_path = pstr(p, obj, "imagePath")
	v.vibrant_color = pstr(p, obj, "vibrantColor")
	v.ads_pre_paywall_only = jbool(obj, "adsPrePaywallOnly")
	v.ads_url = pstr(p, obj, "adsUrl")

	if v.artist != nil {
		v.listen_url = fmt.aprintf("%s/artist/%d/video/%d", p.listen_base_url, v.artist.id, v.id, allocator = p.allocator)
	} else {
		v.listen_url = fmt.aprintf("%s/video/%d", p.listen_base_url, v.id, allocator = p.allocator)
	}
	v.share_url = fmt.aprintf("%s/video/%d", p.share_base_url, v.id, allocator = p.allocator)
	return v
}

@(private)
parse_video_simple :: proc(p: ^Parser, obj: json.Object) -> Video {
	return parse_video(p, obj)
}

// parse_media picks Track or Video by the "type" field. Types like Event and
// Live are videos.
parse_media :: proc(p: ^Parser, obj: json.Object, album: ^Album = nil) -> Media {
	t := jstr(obj, "type")
	if !jhas(obj, "type") || t == "Track" {
		return parse_track(p, obj, album)
	}
	return parse_video(p, obj, album)
}

@(private)
parse_media_in_album :: proc(p: ^Parser, obj: json.Object) -> Media {
	return parse_media(p, obj, p.album)
}

parse_lyrics :: proc(p: ^Parser, obj: json.Object) -> Lyrics {
	return Lyrics {
		track_id = ji64(obj, "trackId"),
		provider = pstr(p, obj, "lyricsProvider"),
		provider_track_id = ji64(obj, "providerCommontrackId"),
		provider_lyrics_id = ji64(obj, "providerLyricsId"),
		text = pstr(p, obj, "lyrics"),
		subtitles = pstr(p, obj, "subtitles"),
		right_to_left = jbool(obj, "isRightToLeft"),
	}
}

parse_stream :: proc(p: ^Parser, obj: json.Object) -> Stream {
	st := Stream {
		track_id = ji64(obj, "trackId", -1),
		audio_mode = pstr(p, obj, "audioMode"),
		audio_quality = pstr(p, obj, "audioQuality"),
		manifest_mime_type = pstr(p, obj, "manifestMimeType"),
		manifest_hash = pstr(p, obj, "manifestHash"),
		manifest = pstr(p, obj, "manifest"),
		asset_presentation = pstr(p, obj, "assetPresentation") if jhas(obj, "assetPresentation") else "FULL",
		// Not reported for low and hi-res qualities. Assume 16 bit / 44.1 kHz.
		bit_depth = jint(obj, "bitDepth", 16),
		sample_rate = jint(obj, "sampleRate", 44100),
	}
	st.track_replay_gain, st.track_peak_amplitude, st.album_replay_gain, st.album_peak_amplitude = playback_gain(obj)
	return st
}

parse_user :: proc(p: ^Parser, obj: json.Object) -> User {
	u: User
	switch {
	case "username" in obj:
		u.kind = .Logged_In_User
	case "firstName" in obj:
		u.kind = .Fetched_User
	case:
		u.kind = .Playlist_Creator
	}
	// When searching, TIDAL does not show up as a creator in the json data.
	u.id = ji64(obj, "id") if len(obj) > 0 else 0

	switch u.kind {
	case .Logged_In_User:
		u.username = pstr(p, obj, "username")
		u.email = pstr(p, obj, "email")
		fallthrough
	case .Fetched_User:
		u.first_name = pstr(p, obj, "firstName")
		u.last_name = pstr(p, obj, "lastName")
		u.picture_id = pstr(p, obj, "picture")
	case .Playlist_Creator:
		switch {
		case u.id == 0 || !p.has_user:
			u.name = "TIDAL"
		case "name" in obj:
			u.name = pstr(p, obj, "name")
		case u.id == p.user_id:
			u.name = "me"
		case:
			u.name = "user"
		}
	}
	return u
}

// parse_playlist parses a playlist (or the "data" of a v2 playlist item) and
// marks it as a user playlist when the logged in user created it.
parse_playlist :: proc(p: ^Parser, root: json.Object) -> Playlist {
	obj := root
	if data, ok := jobj(root, "data"); ok {
		obj = data
	}

	pl: Playlist
	pl.id = pstr(p, obj, "uuid")
	pl.trn = fmt.aprintf("trn:playlist:%s", pl.id, allocator = p.allocator)
	pl.name = pstr(p, obj, "title")
	pl.num_tracks = jint(obj, "numberOfTracks")
	pl.num_videos = jint(obj, "numberOfVideos")
	pl.description = pstr(p, obj, "description")
	pl.duration = jint(obj, "duration")

	// These can be missing from the /pages endpoints
	pl.last_updated = jdate(obj, "lastUpdated")
	pl.created = jdate(obj, "created")
	if jhas(obj, "publicPlaylist") {
		pl.public = jbool(obj, "publicPlaylist")
	}
	if jtruthy(obj["popularity"]) {
		pl.popularity = jint(obj, "popularity")
	}

	pl.type = pstr(p, obj, "type")
	pl.picture = pstr(p, obj, "image")
	pl.square_picture = pstr(p, obj, "squareImage")
	if promoted, ok := jarr(obj, "promotedArtists"); ok && len(promoted) > 0 {
		pl.promoted_artists = parse_artists(p, promoted)
	}
	pl.last_item_added_at = jdate(obj, "lastItemAddedAt")
	pl.user_date_added = date_added(p, obj)

	if creator, ok := jobj(obj, "creator"); ok && len(creator) > 0 {
		if pl.type == "ARTIST" && jtruthy(creator["id"]) {
			pl.creator = parse_artist(p, creator)
		} else {
			pl.creator = parse_user(p, creator)
		}
	}

	pl.listen_url = fmt.aprintf("%s/playlist/%s", p.listen_base_url, pl.id, allocator = p.allocator)
	pl.share_url = fmt.aprintf("%s/playlist/%s", p.share_base_url, pl.id, allocator = p.allocator)

	// Playlists the logged in user created can be edited.
	if pl.id != "" && p.has_user && p.user_kind == .Logged_In_User {
		creator_id: i64 = -1
		switch c in pl.creator {
		case Artist:
			creator_id = c.id
		case User:
			creator_id = c.id
		}
		pl.is_user_playlist = creator_id == p.user_id
	}
	return pl
}

parse_folder :: proc(p: ^Parser, obj: json.Object) -> Folder {
	f: Folder
	data, _ := jobj(obj, "data")
	f.trn = pstr(p, obj, "trn")
	f.id = pstr(p, data, "id")
	f.name = pstr(p, obj, "name")
	f.parent = pstr(p, obj, "parent")
	f.added = jdate(obj, "addedAt")
	f.created = jdate(data, "createdAt")
	f.last_modified = jdate(data, "lastModifiedAt")
	f.total_number_of_items = jint(data, "totalNumberOfItems")
	f.listen_url = fmt.aprintf("%s/folder/%s", p.listen_base_url, f.id, allocator = p.allocator)
	return f
}

@(private)
mix_type_from_string :: proc(s: string) -> Mix_Type {
	for name, t in MIX_TYPE_NAMES {
		if t != .Unknown && name == s {
			return t
		}
	}
	return .Unknown
}

@(private)
parse_image_response :: proc(p: ^Parser, obj: json.Object) -> Image_Response {
	url :: proc(p: ^Parser, obj: json.Object, key: string) -> string {
		size, _ := jobj(obj, key)
		return pstr(p, size, "url")
	}
	return Image_Response{small = url(p, obj, "SMALL"), medium = url(p, obj, "MEDIUM"), large = url(p, obj, "LARGE")}
}

// For v2 mixes from pages, where images come as a list of sizes.
@(private)
parse_image_list :: proc(p: ^Parser, arr: json.Array) -> Image_Response {
	url :: proc(p: ^Parser, arr: json.Array, i: int) -> string {
		if len(arr) == 0 {
			return ""
		}
		o, _ := arr[min(i, len(arr) - 1)].(json.Object)
		return pstr(p, o, "url")
	}
	return Image_Response{small = url(p, arr, 0), medium = url(p, arr, 1), large = url(p, arr, 2)}
}

@(private)
parse_text_info :: proc(p: ^Parser, obj: json.Object) -> Text_Info {
	return Text_Info{text = pstr(p, obj, "text"), color = pstr(p, obj, "color")}
}

parse_mix :: proc(p: ^Parser, obj: json.Object) -> Mix {
	m: Mix
	m.id = value_id_string(obj["id"], p.allocator)
	m.title = pstr(p, obj, "title")
	m.sub_title = pstr(p, obj, "subTitle")
	m.mix_type_name = pstr(p, obj, "mixType")
	m.mix_type = mix_type_from_string(m.mix_type_name)
	m.content_behaviour = pstr(p, obj, "contentBehavior")
	m.short_subtitle = pstr(p, obj, "shortSubtitle")
	if images, ok := jobj(obj, "images"); ok {
		m.images = parse_image_response(p, images)
	}
	return m
}

parse_mix_v2 :: proc(p: ^Parser, obj: json.Object) -> Mix_V2 {
	m: Mix_V2
	m.id = value_id_string(obj["id"], p.allocator)
	if jtruthy(obj["mixType"]) {
		m.mix_type_name = pstr(p, obj, "mixType")
		m.date_added = date_added(p, obj)
		m.title = pstr(p, obj, "title")
		m.sub_title = pstr(p, obj, "subTitle")
		if images, ok := jobj(obj, "images"); ok {
			m.images = parse_image_response(p, images)
		}
		if images, ok := jobj(obj, "detailImages"); ok {
			m.detail_images = parse_image_response(p, images)
		}
		m.master = jbool(obj, "master")
		if info, ok := jobj(obj, "titleTextInfo"); ok {
			m.title_text_info = parse_text_info(p, info)
		}
		if info, ok := jobj(obj, "subTitleTextInfo"); ok {
			m.sub_title_text_info = parse_text_info(p, info)
		}
		m.updated = jdate(obj, "updated")
	} else if jtruthy(obj["type"]) {
		// Mixes returned from pages use a different shape.
		m.country_code = pstr(p, obj, "countryCode")
		m.is_stable_id = jbool(obj, "isStableId")
		m.artifact_id_type = pstr(p, obj, "trackGroupId")
		m.content_behavior = pstr(p, obj, "contentBehavior")
		if images, ok := jarr(obj, "mixImages"); ok {
			m.images = parse_image_list(p, images)
		}
		if images, ok := jarr(obj, "detailMixImages"); ok {
			m.detail_images = parse_image_list(p, images)
		}
		if info, ok := jobj(obj, "titleTextInfo"); ok {
			ti := parse_text_info(p, info)
			m.title_text_info = ti
			m.title = ti.text
		}
		if info, ok := jobj(obj, "subtitleTextInfo"); ok {
			ti := parse_text_info(p, info)
			m.sub_title_text_info = ti
			m.sub_title = ti.text
		}
		if info, ok := jobj(obj, "shortSubtitleTextInfo"); ok {
			ti := parse_text_info(p, info)
			m.short_subtitle_text_info = ti
			m.short_subtitle = ti.text
		}
		// Epoch milliseconds here
		if jtruthy(obj["updated"]) {
			ms := ji64(obj, "updated")
			m.updated = time.unix(ms / 1000, (ms % 1000) * 1_000_000)
		}
	}
	return m
}

parse_genre :: proc(p: ^Parser, obj: json.Object) -> Genre {
	image_path, _ := strings.replace_all(jstr(obj, "image"), "-", "/", context.temp_allocator)
	return Genre {
		name = pstr(p, obj, "name"),
		path = pstr(p, obj, "path"),
		playlists = jbool(obj, "hasPlaylists"),
		artists = jbool(obj, "hasArtists"),
		albums = jbool(obj, "hasAlbums"),
		tracks = jbool(obj, "hasTracks"),
		videos = jbool(obj, "hasVideos"),
		image = fmt.aprintf("http://resources.wimpmusic.com/images/%s/460x306.jpg", image_path, allocator = p.allocator),
	}
}

// parse_item_by_type parses obj by a TIDAL type name such as "TRACK",
// "album" or "Playlist". mix_v2 selects the v2 mix shape.
parse_item_by_type :: proc(p: ^Parser, type_name: string, obj: json.Object, mix_v2 := false) -> (item: Item, ok: bool) {
	// Search top hits use plural names ("ARTISTS"); no singular one ends in S.
	t := strings.trim_suffix(strings.to_upper(type_name, context.temp_allocator), "S")
	switch t {
	case "ARTIST":
		return parse_artist(p, obj), true
	case "ALBUM":
		return parse_album(p, obj), true
	case "TRACK":
		return parse_track(p, obj, p.album), true
	case "VIDEO":
		return parse_video(p, obj, p.album), true
	case "PLAYLIST":
		return parse_playlist(p, obj), true
	case "MIX":
		if mix_v2 {
			return parse_mix_v2(p, obj), true
		}
		return parse_mix(p, obj), true
	}
	log.debugf("Item type '%s' not implemented", type_name)
	return nil, false
}

// map_items parses typed lists: each entry of
// list["items"] is parsed, unwrapping {"item": ..., "created": ...} entries.
@(private)
map_items :: proc(p: ^Parser, list: json.Object, $T: typeid, parse: proc(p: ^Parser, obj: json.Object) -> T) -> []T {
	items, _ := jarr(list, "items")
	out := make([dynamic]T, 0, len(items), p.allocator)
	map_items_into(p, list, &out, parse)
	return out[:]
}

@(private)
map_items_into :: proc(p: ^Parser, list: json.Object, out: ^[dynamic]$T, parse: proc(p: ^Parser, obj: json.Object) -> T) {
	items, _ := jarr(list, "items")
	for v in items {
		obj := v.(json.Object) or_continue
		if inner, has := jobj(obj, "item"); has {
			// Move the created date into the item, like for playlist tracks.
			p.date_added = obj["created"]
			append(out, parse(p, inner))
			p.date_added = nil
		} else {
			append(out, parse(p, obj))
		}
	}
}

// map_items for lists that mix types; entries are {"type": ..., "item": ...}.
@(private)
map_any_items :: proc(p: ^Parser, list: json.Object) -> []Item {
	items, _ := jarr(list, "items")
	out := make([dynamic]Item, 0, len(items), p.allocator)
	for v in items {
		obj := v.(json.Object) or_continue
		inner, has := jobj(obj, "item")
		if !has {
			continue
		}
		p.date_added = obj["created"]
		p.artist_roles = obj["roles"]
		if item, ok := parse_item_by_type(p, jstr(obj, "type"), inner); ok {
			append(&out, item)
		}
		p.date_added = nil
		p.artist_roles = nil
	}
	return out[:]
}
