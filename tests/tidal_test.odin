package tidal_tests

import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/xml"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

import tidal "../src/tidal"

// Arena for one test's results.
@(private = "file")
Test_Arena :: struct {
	arena: vmem.Arena,
}

@(private = "file")
arena_begin :: proc(a: ^Test_Arena) -> mem.Allocator {
	_ = vmem.arena_init_growing(&a.arena)
	return vmem.arena_allocator(&a.arena)
}

@(private = "file")
parse_obj :: proc(t: ^testing.T, src: string, allocator: mem.Allocator) -> json.Object {
	v, err := json.parse_string(src, .JSON, true, allocator)
	testing.expect_value(t, err, json.Error.None)
	obj, ok := v.(json.Object)
	testing.expect(t, ok)
	return obj
}

@(private = "file")
test_parser :: proc(allocator: mem.Allocator) -> tidal.Parser {
	return tidal.Parser {
		allocator = allocator,
		listen_base_url = "https://listen.tidal.com",
		share_base_url = "https://tidal.com/browse",
		has_user = true,
		user_id = 123,
		user_kind = .Logged_In_User,
	}
}

TRACK_JSON :: `{"id":77646170,"title":"Hey Jude","duration":431,"replayGain":-9.3,"peak":0.977,"allowStreaming":true,
"streamReady":true,"adSupportedStreamReady":true,"djReady":true,"stemReady":false,"streamStartDate":"2017-08-25T00:00:00.000+0000",
"premiumStreamingOnly":false,"trackNumber":21,"volumeNumber":1,"version":"Remastered 2015","popularity":71,
"copyright":"(C) 2015 Apple Corps Ltd","bpm":74,"key":"F","keyScale":"MAJOR","url":"http://www.tidal.com/track/77646170",
"isrc":"GBAYE0601690","editable":false,"explicit":false,"audioQuality":"LOSSLESS","audioModes":["STEREO"],
"mediaMetadata":{"tags":["LOSSLESS","HIRES_LOSSLESS"]},"upload":false,"accessType":"PUBLIC","spotlighted":false,
"artist":{"id":3634161,"name":"The Beatles","handle":null,"type":"MAIN","picture":"8d99ee7c-4fa5-4b2f-b1d6-3a8e8b6c3f42"},
"artists":[{"id":3634161,"name":"The Beatles","handle":null,"type":"MAIN","picture":"8d99ee7c-4fa5-4b2f-b1d6-3a8e8b6c3f42"},
{"id":1,"name":"Guest","type":"FEATURED","picture":null}],
"album":{"id":77646148,"title":"1 (Remastered)","cover":"9a56f482-e9cf-46c3-bb21-82710e7854d4","vibrantColor":"#e2c7a4","videoCover":null},
"mixes":{"TRACK_MIX":"001603cb31f9ab3a4b2bc3f3d3b2c3"}}`

ALBUM_JSON :: `{"id":77646148,"title":"1 (Remastered)","duration":4740,"streamReady":true,"allowStreaming":true,
"numberOfTracks":27,"numberOfVideos":0,"numberOfVolumes":1,"releaseDate":"2000-11-13","copyright":"(C) 2015 Apple Corps",
"type":"ALBUM","version":null,"url":"http://www.tidal.com/album/77646148","cover":"9a56f482-e9cf-46c3-bb21-82710e7854d4",
"videoCover":null,"explicit":false,"upc":"00602547657343","popularity":80,"audioQuality":"LOSSLESS","audioModes":["STEREO"],
"mediaMetadata":{"tags":["LOSSLESS"]},"artist":{"id":3634161,"name":"The Beatles","type":"MAIN"},
"artists":[{"id":3634161,"name":"The Beatles","type":"MAIN"}]}`

PLAYLIST_JSON :: `{"uuid":"36ea71a8-445e-41a4-82ab-6628c581535d","title":"My list","numberOfTracks":3,"numberOfVideos":0,
"creator":{"id":123},"description":"desc","duration":600,"lastUpdated":"2023-01-02T10:00:00.000+0000",
"created":"2022-12-01T09:00:00.000+0000","type":"USER","publicPlaylist":false,"url":"http://www.tidal.com/playlist/x",
"image":"aaaa-bbbb","popularity":0,"squareImage":"cccc-dddd","promotedArtists":[],"lastItemAddedAt":"2023-01-02T10:00:00.000+0000"}`

@(test)
config_values :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	c := tidal.config_make(allocator = allocator)
	testing.expect_value(t, c.client_id, "fX2JxdmntZWK0ixT")
	testing.expect_value(t, c.client_id_pkce, "6BDSRdpK9hqEBTgU")
	testing.expect_value(t, len(c.client_secret), 44)
	testing.expect_value(t, len(c.code_verifier), 43)
	testing.expect_value(t, c.code_challenge, tidal.pkce_challenge(c.code_verifier, allocator))
	testing.expect_value(t, tidal.pkce_challenge("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", allocator), "fR4ifSAEy-7Mu6g7FHZulPKrtjqdAnUCwRFAJt2JFsA")

	capped := tidal.config_make(item_limit = 20000, allocator = allocator)
	testing.expect_value(t, capped.item_limit, 10000)
}

@(test)
datetimes :: proc(t: ^testing.T) {
	expect_unix :: proc(t: ^testing.T, s: string, want: i64, loc := #caller_location) {
		got, ok := tidal.parse_datetime(s)
		testing.expect(t, ok, s, loc = loc)
		testing.expect_value(t, time.time_to_unix(got), want, loc = loc)
	}
	expect_unix(t, "2019-04-26", 1556236800)
	expect_unix(t, "2014-06-02T00:00:00.000+0000", 1401667200)
	expect_unix(t, "2014-06-02T02:00:00.000+02:00", 1401667200)
	expect_unix(t, "2014-06-01T19:00:00-0500", 1401667200)
	expect_unix(t, "2023-05-01T10:00:00Z", 1682935200)
	_, bad := tidal.parse_datetime("yesterday")
	testing.expect(t, !bad)

	naive, ok := tidal.parse_datetime("2025-01-02T03:04:05.123456")
	testing.expect(t, ok)
	s := tidal.format_datetime_naive(naive, context.temp_allocator)
	testing.expect_value(t, s, "2025-01-02T03:04:05.123456")

	d, dok := tidal.parse_iso_duration("PT3M5.123S")
	testing.expect(t, dok)
	testing.expect_value(t, d, 185123 * time.Millisecond)
}

@(test)
parse_track :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	p := test_parser(allocator)
	tr := tidal.parse_track(&p, parse_obj(t, TRACK_JSON, allocator))
	testing.expect_value(t, tr.id, 77646170)
	testing.expect_value(t, tr.title, "Hey Jude")
	testing.expect_value(t, tr.full_name, "Hey Jude (Remastered 2015)")
	testing.expect_value(t, tr.duration, 431)
	testing.expect_value(t, tr.track_num, 21)
	testing.expect_value(t, tr.isrc, "GBAYE0601690")
	testing.expect_value(t, tr.bpm, 74)
	testing.expect_value(t, tr.peak, 0.977)
	testing.expect_value(t, tr.replay_gain, -9.3)
	testing.expect_value(t, tr.access_type, "PUBLIC")
	testing.expect_value(t, tr.mixes["TRACK_MIX"], "001603cb31f9ab3a4b2bc3f3d3b2c3")
	testing.expect(t, tidal.track_is_lossless(tr))
	testing.expect(t, tidal.track_is_hi_res_lossless(tr))
	testing.expect(t, !tidal.track_is_dolby_atmos(tr))

	testing.expect(t, tr.artist != nil)
	testing.expect_value(t, tr.artist.name, "The Beatles")
	testing.expect_value(t, tr.artist.role.?, tidal.Artist_Role.Main)
	testing.expect_value(t, len(tr.artists), 2)
	testing.expect_value(t, tr.artists[1].picture, tidal.DEFAULT_ARTIST_IMG)

	// The sparse album reuses the track's artists.
	testing.expect(t, tr.album != nil)
	testing.expect_value(t, tr.album.id, 77646148)
	testing.expect_value(t, tr.album.name, "1 (Remastered)")
	testing.expect_value(t, len(tr.album.artists), 2)
	testing.expect_value(t, tr.listen_url, "https://listen.tidal.com/album/77646148/track/77646170")
	testing.expect_value(t, tr.share_url, "https://tidal.com/browse/track/77646170")

	start, has_start := tr.stream_start_date.?
	testing.expect(t, has_start)
	testing.expect_value(t, time.time_to_unix(start), 1503619200)

	// A parent album replaces the sparse one.
	parent := tidal.Album {
		id   = 1,
		name = "Parent",
	}
	tr2 := tidal.parse_track(&p, parse_obj(t, TRACK_JSON, allocator), &parent)
	testing.expect(t, tr2.album == &parent)
	testing.expect_value(t, tr2.listen_url, "https://listen.tidal.com/album/1/track/77646170")
}

// The primary artist is parsed once when it also leads "artists".
@(test)
primary_artist_is_parsed_once :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	p := test_parser(allocator)
	tr := tidal.parse_track(&p, parse_obj(t, TRACK_JSON, allocator))
	testing.expect(t, tr.artist == &tr.artists[0])
	al := tidal.parse_album(&p, parse_obj(t, ALBUM_JSON, allocator))
	testing.expect(t, al.artist == &al.artists[0])

	other := tidal.parse_track(&p, parse_obj(t, `{"id":1,"artist":{"id":9,"name":"Other"},"artists":[{"id":3634161,"name":"The Beatles"}]}`, allocator))
	testing.expect(t, other.artist != &other.artists[0])
	testing.expect_value(t, other.artist.name, "Other")
}

@(test)
parse_album_and_media :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	p := test_parser(allocator)
	al := tidal.parse_album(&p, parse_obj(t, ALBUM_JSON, allocator))
	testing.expect_value(t, al.num_tracks, 27)
	testing.expect_value(t, al.upc, "00602547657343")
	testing.expect_value(t, al.version, "")
	testing.expect_value(t, tidal.album_year(al).?, 2000)
	testing.expect_value(t, al.listen_url, "https://listen.tidal.com/album/77646148")
	testing.expect(t, al.artist != nil && al.artist.id == 3634161)

	video := parse_obj(t, `{"id":5,"title":"Clip","type":"Music Video","imageId":"ab-cd","artists":[{"id":9,"name":"A"}],"album":null}`, allocator)
	m := tidal.parse_media(&p, video)
	v, is_video := m.(tidal.Video)
	testing.expect(t, is_video)
	testing.expect_value(t, v.image_id, "ab-cd")
	testing.expect(t, v.album == nil)
	testing.expect_value(t, v.listen_url, "https://listen.tidal.com/artist/9/video/5")

	track := parse_obj(t, `{"id":6,"title":"Song","type":"Track","allowStreaming":false}`, allocator)
	_, is_track := tidal.parse_media(&p, track).(tidal.Track)
	testing.expect(t, is_track)
}

@(test)
parse_playlist_ownership :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	p := test_parser(allocator)
	pl := tidal.parse_playlist(&p, parse_obj(t, PLAYLIST_JSON, allocator))
	testing.expect_value(t, pl.id, "36ea71a8-445e-41a4-82ab-6628c581535d")
	testing.expect_value(t, pl.trn, "trn:playlist:36ea71a8-445e-41a4-82ab-6628c581535d")
	testing.expect_value(t, pl.public.?, false)
	testing.expect(t, pl.popularity == nil)
	testing.expect(t, pl.is_user_playlist)
	creator, is_user := pl.creator.(tidal.User)
	testing.expect(t, is_user)
	testing.expect_value(t, creator.kind, tidal.User_Kind.Playlist_Creator)
	testing.expect_value(t, creator.name, "me")

	// v2 wrapper with a creator that is someone else
	wrapped := strings.concatenate({`{"data":`, strings.replace_all(PLAYLIST_JSON, `"id":123`, `"id":7`, allocator) or_else "", `}`}, allocator)
	pl2 := tidal.parse_playlist(&p, parse_obj(t, wrapped, allocator))
	testing.expect(t, !pl2.is_user_playlist)
	creator2, _ := pl2.creator.(tidal.User)
	testing.expect_value(t, creator2.name, "user")

	img, err := tidal.playlist_image_url(&tidal.Session{config = tidal.config_make(allocator = allocator)}, pl, 320, allocator = allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, img, "https://resources.tidal.com/images/cccc/dddd/320x320.jpg")
}

@(test)
parse_pages :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	v1 := strings.concatenate(
		{
			`{"title":"Explore","rows":[`,
			`{"modules":[{"type":"ALBUM_LIST","title":"New albums","pagedList":{"items":[`, ALBUM_JSON, `]},"showMore":{"apiPath":"pages/albums","title":"More"}}]},`,
			`{"modules":[{"type":"MIXED_TYPES_LIST","title":"Mixed","pagedList":{"items":[{"type":"TRACK","item":`, TRACK_JSON, `},{"type":"PLAYLIST","item":`, PLAYLIST_JSON, `}]}}]},`,
			`{"modules":[{"type":"SOMETHING_NEW","title":"x"}]},`,
			`{"modules":[{"type":"PAGE_LINKS","title":"Genres","pagedList":{"items":[{"title":"Pop","icon":"","apiPath":"pages/genre_pop","imageId":"abc"}]}}]},`,
			`{"modules":[{"type":"TEXT_BLOCK","text":"hello","icon":"info"}]}`,
			`]}`,
		},
		allocator,
	)
	p := test_parser(allocator)
	page := tidal.parse_page(&p, parse_obj(t, v1, allocator))
	testing.expect_value(t, page.title, "Explore")
	// The unknown module is skipped.
	testing.expect_value(t, len(page.categories), 4)

	albums, ok := page.categories[0].(tidal.Item_List)
	testing.expect(t, ok)
	testing.expect_value(t, albums.more.?.api_path, "pages/albums")
	_, is_album := albums.items[0].(tidal.Album)
	testing.expect(t, is_album)

	mixed, _ := page.categories[1].(tidal.Item_List)
	testing.expect_value(t, len(mixed.items), 2)
	_, is_track := mixed.items[0].(tidal.Track)
	_, is_playlist := mixed.items[1].(tidal.Playlist)
	testing.expect(t, is_track && is_playlist)

	links, _ := page.categories[2].(tidal.Page_Links)
	testing.expect_value(t, links.items[0].api_path, "pages/genre_pop")

	flat := tidal.page_flatten(page, allocator)
	testing.expect_value(t, len(flat), 4)

	v2 := strings.concatenate(
		{
			`{"items":[{"type":"HORIZONTAL_LIST","moduleId":"m1","title":"Because you liked","items":[`,
			`{"type":"ALBUM","data":`, ALBUM_JSON, `},`,
			`{"type":"MIX","data":{"id":"0123abc","type":"TRACK_MIX","mixImages":[{"url":"s"},{"url":"m"},{"url":"l"}],"detailMixImages":[],`,
			`"titleTextInfo":{"text":"Mix title","color":"#fff"},"subtitleTextInfo":{"text":"sub","color":"#000"},"shortSubtitleTextInfo":{"text":"short","color":"#000"},"updated":1700000000000}},`,
			`{"type":"UNKNOWN","data":{}}]},`,
			`{"type":"TRACK_LIST","title":"Tracks","items":[{"type":"TRACK","data":`, TRACK_JSON, `}]},`,
			`{"type":"NEW_V2_THING","items":[]}]}`,
		},
		allocator,
	)
	home := tidal.parse_page(&p, parse_obj(t, v2, allocator))
	testing.expect_value(t, len(home.categories), 2)
	row, _ := home.categories[0].(tidal.Item_List)
	testing.expect_value(t, row.module_id, "m1")
	testing.expect_value(t, row.description, "Because you liked")
	testing.expect_value(t, len(row.items), 2)
	mix, is_mix := row.items[1].(tidal.Mix_V2)
	testing.expect(t, is_mix)
	testing.expect_value(t, mix.title, "Mix title")
	testing.expect_value(t, mix.short_subtitle, "short")
	testing.expect_value(t, mix.images.?.large, "l")
	testing.expect_value(t, time.time_to_unix(mix.updated.?), 1700000000)
}

MPD :: `<?xml version='1.0' encoding='UTF-8'?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-main:2011" type="static" minBufferTime="PT3.993S" mediaPresentationDuration="PT3M5.123S"><Period id="0"><AdaptationSet id="0" contentType="audio" mimeType="audio/mp4" segmentAlignment="true"><Representation id="FLAC,44100,16" codecs="flac" bandwidth="1000000" audioSamplingRate="44100"><SegmentTemplate timescale="44100" initialization="https://sp.example/0.mp4?a=1&amp;b=2" media="https://sp.example/$Number$.mp4?a=1&amp;b=2" startNumber="1"><SegmentTimeline><S d="176128" r="3"/><S d="12345"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`

EXPECTED_HLS :: "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n" +
	"#EXT-X-MAP:URI=\"https://sp.example/0.mp4?a=1&b=2\"\n" +
	"#EXTINF:3.993832,\nhttps://sp.example/1.mp4?a=1&b=2\n" +
	"#EXTINF:3.993832,\nhttps://sp.example/2.mp4?a=1&b=2\n" +
	"#EXTINF:3.993832,\nhttps://sp.example/3.mp4?a=1&b=2\n" +
	"#EXTINF:3.993832,\nhttps://sp.example/4.mp4?a=1&b=2\n" +
	"#EXTINF:0.279932,\nhttps://sp.example/5.mp4?a=1&b=2\n" +
	"#EXT-X-ENDLIST\n"

@(test)
dash_manifest :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	stream := tidal.Stream {
		manifest_mime_type = "application/dash+xml",
		manifest           = base64.encode(transmute([]u8)string(MPD), allocator = allocator),
	}
	m, err := tidal.stream_get_manifest(stream, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.codecs, "FLAC")
	testing.expect_value(t, m.mime_type, "audio/mp4")
	testing.expect_value(t, m.sample_rate, 44100)
	testing.expect_value(t, m.file_extension, ".m4a")
	// Initialization, then segments 1-5: r="3" means four segments.
	testing.expect_value(t, len(m.urls), 6)
	testing.expect_value(t, m.urls[0], "https://sp.example/0.mp4?a=1&b=2")
	testing.expect_value(t, m.urls[5], "https://sp.example/5.mp4?a=1&b=2")
	dash := m.dash_info.?
	testing.expect_value(t, dash.init_url, "https://sp.example/0.mp4?a=1&b=2")
	testing.expect_value(t, len(dash.segments), 5)
	testing.expect_value(t, dash.segments[4].duration, 12345.0 / 44100.0)

	hls, herr := tidal.manifest_hls(m, allocator)
	testing.expect_value(t, herr, nil)
	testing.expect_value(t, hls, EXPECTED_HLS)
}

@(test)
dash_segment_numbering :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	// Three entries repeated once each: six segments numbered from startNumber.
	mpd := `<MPD mediaPresentationDuration="PT24S"><Period><AdaptationSet contentType="audio"><Representation mimeType="audio/mp4" codecs="flac" audioSamplingRate="44100"><SegmentTemplate timescale="1" initialization="https://cdn.example/init.mp4" media="https://cdn.example/segment-$Number$.m4s" startNumber="7"><SegmentTimeline><S d="4" r="1"/><S d="4" r="1"/><S d="4" r="1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	d, err := tidal.dash_info_from_mpd(mpd, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, d.mime_type, "audio/mp4") // from the Representation
	testing.expect_value(t, d.init_url, "https://cdn.example/init.mp4")
	testing.expect_value(t, len(d.segments), 6)
	testing.expect_value(t, d.segments[0].url, "https://cdn.example/segment-7.m4s")
	testing.expect_value(t, d.segments[5].url, "https://cdn.example/segment-12.m4s")
	testing.expect_value(t, len(d.urls), 7)
	total := 0.0
	for seg in d.segments {
		total += seg.duration
	}
	testing.expect_value(t, total, 24.0)

	// r="-1" fills the period; $Time$ and padded $Number$.
	open_ended := `<MPD mediaPresentationDuration="PT10S"><Period><AdaptationSet><Representation id="a1" bandwidth="320000"><SegmentTemplate timescale="10" media="$RepresentationID$/$Bandwidth$/$Number%05d$-$Time$.m4s"><SegmentTimeline><S t="0" d="40" r="-1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	d2, err2 := tidal.dash_info_from_mpd(open_ended, allocator)
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, d2.init_url, "")
	testing.expect_value(t, len(d2.segments), 3)
	testing.expect_value(t, d2.segments[0].url, "a1/320000/00001-0.m4s")
	testing.expect_value(t, d2.segments[2].url, "a1/320000/00003-80.m4s")
	testing.expect_value(t, len(d2.urls), 3)

	// Fixed-duration template without a timeline.
	fixed := `<MPD mediaPresentationDuration="PT9S"><Period><AdaptationSet><Representation><SegmentTemplate timescale="1" duration="4" startNumber="0" media="s$Number$.m4s"/></Representation></AdaptationSet></Period></MPD>`
	d3, err3 := tidal.dash_info_from_mpd(fixed, allocator)
	testing.expect_value(t, err3, nil)
	testing.expect_value(t, len(d3.segments), 3)
	testing.expect_value(t, d3.segments[2].url, "s2.m4s")
	testing.expect_value(t, d3.segments[2].duration, 1.0)
}

@(test)
dash_duration_fallbacks :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	body :: `<Period%s><AdaptationSet><Representation codecs="flac"><SegmentTemplate timescale="10" media="$Number$.mp4" initialization="i.mp4"><SegmentTimeline><S d="40" r="1"/><S d="25"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`

	// No mediaPresentationDuration: the timeline gives 10.5 s.
	missing := fmt.tprintf(`<MPD type="static">`+body, "")
	d, err := tidal.dash_info_from_mpd(missing, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, d.duration, 10500 * time.Millisecond)
	testing.expect_value(t, len(d.segments), 3)

	// One the parser can't read falls back the same way.
	bad := fmt.tprintf(`<MPD mediaPresentationDuration="10.5">`+body, "")
	d2, err2 := tidal.dash_info_from_mpd(bad, allocator)
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, d2.duration, 10500 * time.Millisecond)

	// Period@duration comes before the timeline.
	period := fmt.tprintf(`<MPD>`+body, ` duration="PT11S"`)
	d3, err3 := tidal.dash_info_from_mpd(period, allocator)
	testing.expect_value(t, err3, nil)
	testing.expect_value(t, d3.duration, 11 * time.Second)

	// Surrounding spaces are fine.
	padded, pok := tidal.parse_iso_duration(" PT4S ")
	testing.expect(t, pok)
	testing.expect_value(t, padded, 4 * time.Second)

	// An open-ended timeline needs a duration from somewhere.
	open_ended := `<MPD><Period><AdaptationSet><Representation><SegmentTemplate timescale="1" media="$Number$.mp4"><SegmentTimeline><S d="4" r="-1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	_, err4 := tidal.dash_info_from_mpd(open_ended, allocator)
	testing.expect(t, err4 != nil)
}

@(test)
mpd_keeps_ninth_attribute :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	// TIDAL's root element: the duration is its ninth attribute. Odin's
	// core:encoding/xml from 2026-10-09 to at least 2026-10-16 drops it.
	mpd := `<?xml version='1.0' encoding='UTF-8'?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:cenc="urn:mpeg:cenc:2013" xsi:schemaLocation="urn:mpeg:dash:schema:mpd:2011 DASH-MPD.xsd" profiles="urn:mpeg:dash:profile:isoff-main:2011" type="static" minBufferTime="PT3.993S" mediaPresentationDuration="PT10S"><Period id="0"><AdaptationSet><Representation codecs="flac"><SegmentTemplate timescale="1" media="$Number$.mp4" initialization="i.mp4"><SegmentTimeline><S d="4" r="-1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>`
	d, err := tidal.dash_info_from_mpd(mpd, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, d.duration, 10 * time.Second)
	testing.expect_value(t, len(d.segments), 3)
}

@(test)
mpd_outline_hides_text :: proc(t: ^testing.T) {
	doc, err := xml.parse_string(MPD, allocator = context.temp_allocator)
	testing.expect_value(t, err, nil)
	outline := tidal.mpd_outline(doc, context.temp_allocator)
	testing.expect(t, strings.contains(outline, `mediaPresentationDuration="PT9M9.999S"`))
	testing.expect(t, strings.contains(outline, `initialization=<32 bytes>`))
	testing.expect(t, strings.contains(outline, `2 S elements, first: S d="999999" r="9"`))
	testing.expect(t, !strings.contains(outline, "sp.example"))
	testing.expect(t, !strings.contains(outline, "176128"))
}

@(test)
bts_manifest :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	bts := `{"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":["https://sp.example/track.flac?token=1"]}`
	stream := tidal.Stream {
		manifest_mime_type = "application/vnd.tidal.bts",
		manifest           = base64.encode(transmute([]u8)string(bts), allocator = allocator),
	}
	m, err := tidal.stream_get_manifest(stream, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.codecs, "FLAC")
	testing.expect_value(t, m.file_extension, ".flac")
	testing.expect_value(t, m.encryption_type, "NONE")
	// encryptionType is set but keyId is absent, so there is no key.
	testing.expect(t, !tidal.manifest_is_encrypted(m))
	_, herr := tidal.manifest_hls(m, allocator)
	testing.expect(t, tidal.is_error(herr, .Mpd_Not_Available))

	unknown := tidal.Stream {
		manifest_mime_type = "application/vnd.apple.mpegurl",
	}
	_, uerr := tidal.stream_get_manifest(unknown, allocator)
	testing.expect(t, tidal.is_error(uerr, .Unknown_Manifest_Format))
}

// A stream without ReplayGain leaves the volume alone, 0 dB at peak 1.0,
// whichever call read it.
@(test)
missing_replay_gain_is_0_db :: proc(t: ^testing.T) {
	a: Test_Arena
	allocator := arena_begin(&a)
	defer vmem.arena_destroy(&a.arena)

	bts := `{"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":["https://sp.example/track.flac"]}`
	src := fmt.tprintf(
		`{{"trackId":1,"audioQuality":"LOSSLESS","manifestMimeType":"application/vnd.tidal.bts","manifest":"%s"}}`,
		base64.encode(transmute([]u8)string(bts), allocator = allocator),
	)
	obj := parse_obj(t, src, allocator)
	p := test_parser(allocator)
	st := tidal.parse_stream(&p, obj)
	testing.expect_value(t, st.track_replay_gain, 0)
	testing.expect_value(t, st.album_replay_gain, 0)
	testing.expect_value(t, st.track_peak_amplitude, 1)
	testing.expect_value(t, st.album_peak_amplitude, 1)

	info, err := tidal.parse_playback_info(obj, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, info.track_gain, 0)
	testing.expect_value(t, info.album_gain, 0)
	testing.expect_value(t, info.track_peak, 1)
	testing.expect_value(t, info.album_peak, 1)
	testing.expect_value(t, info.url, "https://sp.example/track.flac")
}

@(test)
pkce_url :: proc(t: ^testing.T) {
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	url := tidal.pkce_login_url(s, context.temp_allocator)
	testing.expect(t, strings.has_prefix(url, "https://login.tidal.com/authorize?response_type=code&redirect_uri=https%3A%2F%2Ftidal.com%2Fandroid%2Flogin%2Fauth&client_id=6BDSRdpK9hqEBTgU"))
	testing.expect(t, strings.contains(url, "&code_challenge_method=S256&restrict_signup=true"))

	err := tidal.login_pkce_complete(s, "not a url")
	testing.expect(t, tidal.is_error(err, .Invalid_Argument))
}

@(test)
image_urls :: proc(t: ^testing.T) {
	s := tidal.session_create()
	defer tidal.session_destroy(s)
	al := tidal.Album {
		cover = "9a56f482-e9cf-46c3-bb21-82710e7854d4",
	}
	url, err := tidal.album_image_url(s, al, 640, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, url, "https://resources.tidal.com/images/9a56f482/e9cf/46c3/bb21/82710e7854d4/640x640.jpg")
	origin, _ := tidal.album_image_url(s, {}, 0, context.temp_allocator)
	testing.expect_value(t, origin, "https://resources.tidal.com/images/0dfd3368/3aa1/49a3/935f/10ffb39803c0/origin.jpg")
	_, bad := tidal.album_image_url(s, al, 123, context.temp_allocator)
	testing.expect(t, tidal.is_error(bad, .Invalid_Argument))
	_, no_video := tidal.album_video_url(s, al)
	testing.expect(t, tidal.is_error(no_video, .Asset_Not_Available))
}

@(test)
url_for_log_drops_query :: proc(t: ^testing.T) {
	testing.expect_value(t, tidal.url_for_log("https://login.tidal.com/android/login/auth?code=secret&state=x"), "https://login.tidal.com/android/login/auth")
	testing.expect_value(t, tidal.url_for_log("https://api.tidal.com/v1/tracks/1#t=secret"), "https://api.tidal.com/v1/tracks/1")
	testing.expect_value(t, tidal.url_for_log("https://resources.tidal.com/images/a/b/320x320.jpg"), "https://resources.tidal.com/images/a/b/320x320.jpg")
}

// A manifest that fails to parse says which check failed, not "no HTTP
// response": the response came, it just didn't decode.
@(test)
error_summary_names_the_parse_step :: proc(t: ^testing.T) {
	err: tidal.Error = tidal.Api_Error{kind = .Manifest_Decode, message = "Manifest has no URLs"}
	testing.expect_value(t, tidal.error_summary(err, context.temp_allocator), "Manifest_Decode: Manifest has no URLs")
	stream := tidal.Stream {
		manifest_mime_type = "application/dash+xml",
		manifest           = base64.encode(transmute([]u8)string("<foo/>"), allocator = context.temp_allocator),
	}
	_, merr := tidal.stream_get_manifest(stream, context.temp_allocator)
	testing.expect_value(t, tidal.error_summary(merr, context.temp_allocator), "Manifest_Decode: MPD: missing MPD element")
	err2: tidal.Error = tidal.Api_Error{kind = .Network, message = "HTTP request failed"}
	testing.expect_value(t, tidal.error_summary(err2, context.temp_allocator), "Network, no HTTP response")
}
