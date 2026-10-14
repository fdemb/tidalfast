package tidal

import "core:time"

// Model types are plain data. Optional values are Maybe, nil pointers or
// empty strings/slices.

DEFAULT_ARTIST_IMG :: "1e01cdb6-f15d-4d8b-8440-a047976c1cac"
DEFAULT_ALBUM_IMG :: "0dfd3368-3aa1-49a3-935f-10ffb39803c0"

Artist_Role :: enum {
	Unknown,
	Main,
	Featured,
	Contributor,
	Artist,
}

Artist :: struct {
	id:              i64,
	name:            string,
	roles:           []Artist_Role,
	role:            Maybe(Artist_Role),
	picture:         string,
	user_date_added: Maybe(time.Time),
	bio:             string, // only set by ARTIST_HEADER page modules
	listen_url:      string,
	share_url:       string,
}

Album :: struct {
	id:                     i64,
	name:                   string,
	cover:                  string,
	video_cover:            string,
	type:                   string,
	duration:               int,
	available:              bool, // streamReady
	ad_supported_ready:     bool,
	dj_ready:               bool,
	allow_streaming:        bool,
	premium_streaming_only: bool,
	num_tracks:             int,
	num_videos:             int,
	num_volumes:            int,
	tidal_release_date:     Maybe(time.Time),
	release_date:           Maybe(time.Time),
	user_date_added:        Maybe(time.Time),
	copyright:              string,
	upc:                    string,
	version:                string,
	explicit:               bool,
	popularity:             int,
	audio_quality:          string,
	audio_modes:            []string,
	media_metadata_tags:    []string,
	artist:                 ^Artist,
	artists:                []Artist,
	listen_url:             string,
	share_url:              string,
}

// One credit in ITEM_LIST_WITH_ROLES page modules.
Role_Credit :: struct {
	category_id: i64,
	category:    string,
}

// Fields shared by tracks and videos.
Media_Info :: struct {
	id:                        i64,
	title:                     string,
	duration:                  int, // seconds
	explicit:                  bool,
	popularity:                int,
	allow_streaming:           bool,
	stream_ready:              bool,
	stem_ready:                bool,
	dj_ready:                  bool,
	ad_supported_stream_ready: bool,
	stream_start_date:         Maybe(time.Time), // aka tidal_release_date
	date_added:                Maybe(time.Time), // set for playlist and favorite items
	track_num:                 int,
	volume_num:                int,
	artist:                    ^Artist,
	artists:                   []Artist,
	artist_roles:              []Role_Credit,
	album:                     ^Album,
	type:                      string,
	// https://listen.tidal.com/track/<id> or .../album/<album_id>/track/<id>
	listen_url:                string,
	// https://tidal.com/browse/track/<id>
	share_url:                 string,
}

Track :: struct {
	using media:            Media_Info,
	access_type:            string,
	spotlighted:            bool,
	pay_to_stream:          bool,
	premium_streaming_only: bool,
	editable:               bool,
	upload:                 bool,
	audio_quality:          string,
	audio_modes:            []string,
	media_metadata_tags:    []string,
	index:                  Maybe(i64),
	item_uuid:              string,
	isrc:                   string,
	description:            string,
	version:                string,
	copyright:              string,
	url:                    string,
	bpm:                    int,
	key:                    string,
	key_scale:              string,
	peak:                   f64,
	replay_gain:            f64,
	mixes:                  map[string]string, // mix type -> mix id, e.g. "TRACK_MIX"
	full_name:              string, // "title (version)" or title
}

Video :: struct {
	using media:          Media_Info,
	release_date:         Maybe(time.Time),
	video_quality:        string, // missing for videos from /pages
	image_id:             string, // aka cover
	image_path:           string,
	vibrant_color:        string,
	ads_pre_paywall_only: bool,
	ads_url:              string,
}

Media :: union {
	Track,
	Video,
}

Lyrics :: struct {
	track_id:           i64,
	provider:           string,
	provider_track_id:  i64,
	provider_lyrics_id: i64,
	text:               string,
	subtitles:          string, // with timestamps
	right_to_left:      bool,
}

User_Kind :: enum {
	Playlist_Creator,
	Fetched_User,
	Logged_In_User,
}

// User covers every kind of user; kind says which fields are set.
// Playlist_Creator: id, name. Fetched_User: id, first/last name, picture.
// Logged_In_User: all of the above plus username and email.
User :: struct {
	kind:       User_Kind,
	id:         i64,
	name:       string, // "TIDAL", "me", "user" or the creator name
	first_name: string,
	last_name:  string,
	picture_id: string,
	username:   string,
	email:      string,
}

Creator :: union {
	Artist,
	User,
}

Playlist :: struct {
	id:                 string,
	trn:                string,
	name:               string,
	num_tracks:         int,
	num_videos:         int,
	creator:            Creator,
	description:        string,
	duration:           int,
	last_updated:       Maybe(time.Time),
	created:            Maybe(time.Time),
	type:               string,
	public:             Maybe(bool),
	popularity:         Maybe(int),
	promoted_artists:   []Artist,
	last_item_added_at: Maybe(time.Time),
	picture:            string,
	square_picture:     string,
	user_date_added:    Maybe(time.Time),
	// True when the logged in user created it, which
	// enables the user_playlist_* procs.
	is_user_playlist:   bool,
	etag:               string,
	listen_url:         string,
	share_url:          string,
}

Folder :: struct {
	trn:                   string,
	id:                    string,
	parent_folder_id:      string,
	name:                  string,
	parent:                string,
	added:                 Maybe(time.Time),
	created:               Maybe(time.Time),
	last_modified:         Maybe(time.Time),
	total_number_of_items: int,
	listen_url:            string,
}

Mix_Type :: enum {
	Unknown,
	Welcome_Mix,
	Video_Daily,
	Daily,
	Discovery,
	New_Release,
	Track,
	Artist,
	Songwriter,
	Producer,
	History_Alltime,
	History_Monthly,
	History_Yearly,
}

MIX_TYPE_NAMES := [Mix_Type]string {
	.Unknown         = "",
	.Welcome_Mix     = "WELCOME_MIX",
	.Video_Daily     = "VIDEO_DAILY_MIX",
	.Daily           = "DAILY_MIX",
	.Discovery       = "DISCOVERY_MIX",
	.New_Release     = "NEW_RELEASE_MIX",
	.Track           = "TRACK_MIX",
	.Artist          = "ARTIST_MIX",
	.Songwriter      = "SONGWRITER_MIX",
	.Producer        = "PRODUCER_MIX",
	.History_Alltime = "HISTORY_ALLTIME_MIX",
	.History_Monthly = "HISTORY_MONTHLY_MIX",
	.History_Yearly  = "HISTORY_YEARLY_MIX",
}

Image_Response :: struct {
	small:  string,
	medium: string,
	large:  string,
}

Text_Info :: struct {
	text:  string,
	color: string,
}

// A mix from TIDAL, e.g. listen.tidal.com/view/pages/my_collection_my_mixes.
// Used for artist/track radios, recommendations and historical plays.
Mix :: struct {
	id:                string,
	title:             string,
	sub_title:         string,
	mix_type:          Mix_Type,
	mix_type_name:     string, // raw value, also set for types missing from Mix_Type
	content_behaviour: string,
	short_subtitle:    string,
	images:            Maybe(Image_Response),
	items:             []Media, // filled by mix_get
	retrieved:         bool,
}

// A mix from TIDAL's v2 endpoints.
Mix_V2 :: struct {
	id:                       string,
	mix_type_name:            string,
	country_code:             string,
	date_added:               Maybe(time.Time),
	artifact_id_type:         string,
	content_behavior:         string,
	images:                   Maybe(Image_Response),
	detail_images:            Maybe(Image_Response),
	master:                   bool,
	is_stable_id:             bool,
	title:                    string,
	sub_title:                string,
	short_subtitle:           string,
	title_text_info:          Maybe(Text_Info),
	sub_title_text_info:      Maybe(Text_Info),
	short_subtitle_text_info: Maybe(Text_Info),
	updated:                  Maybe(time.Time),
	items:                    []Media, // filled by mix_v2_get
	retrieved:                bool,
}

Genre :: struct {
	name:      string,
	path:      string,
	playlists: bool,
	artists:   bool,
	albums:    bool,
	tracks:    bool,
	videos:    bool,
	image:     string,
}

Stream :: struct {
	track_id:             i64,
	audio_mode:           string, // STEREO, DOLBY_ATMOS
	audio_quality:        string, // LOW, HIGH, LOSSLESS, HI_RES_LOSSLESS
	manifest_mime_type:   string,
	manifest_hash:        string,
	manifest:             string, // base64
	asset_presentation:   string,
	album_replay_gain:    f64,
	album_peak_amplitude: f64,
	track_replay_gain:    f64,
	track_peak_amplitude: f64,
	bit_depth:            int,
	sample_rate:          int,
}

Dash_Segment :: struct {
	url:      string,
	duration: f64, // seconds
}

Dash_Info :: struct {
	duration:            time.Duration,
	content_type:        string,
	mime_type:           string,
	codecs:              string,
	init_url:            string, // initialization segment, "" when there is none
	media_url:           string, // segment URL template
	timescale:           int,
	start_number:        int,
	audio_sampling_rate: int,
	segments:            []Dash_Segment, // media segments in playback order
	// init_url (when set) followed by every segment URL: download them in
	// this order and concatenate to get the file.
	urls:                []string,
}

Stream_Manifest :: struct {
	manifest_mime_type: string,
	manifest_parsed:    string, // decoded BTS JSON
	codecs:             string, // MP3, AAC, MP4A, FLAC, EAC3, AC4, ...
	mime_type:          string,
	encryption_type:    string,
	encryption_key:     string,
	sample_rate:        int,
	urls:               []string,
	file_extension:     string,
	dash_info:          Maybe(Dash_Info),
}

// Anything a page row, a search top hit or a polymorphic list can hold.
Item :: union {
	Artist,
	Album,
	Track,
	Video,
	Playlist,
	Mix,
	Mix_V2,
	Page_Item,
	Page_Link,
}

// Pagination link of a page category ("show more" / "view all").
More :: struct {
	api_path: string,
	title:    string,
}

// A page from https://listen.tidal.com/view/pages/ or the v2 home feed.
Page :: struct {
	title:      string,
	categories: []Page_Category,
}

Page_Category :: union {
	Item_List,
	Page_Links,
	Featured_Items,
	Text_Block,
	Link_List,
	Item_Header,
}

// A row of items. v1 ALBUM_LIST, TRACK_LIST, MIXED_TYPES_LIST, ... and the v2
// home feed lists (TRACK_LIST, SHORTCUT_LIST, HORIZONTAL_LIST,
// HORIZONTAL_LIST_WITH_CONTEXT). `type` holds the module type.
Item_List :: struct {
	type:        string,
	module_id:   string,
	title:       string,
	subtitle:    string,
	description: string,
	more:        Maybe(More),
	items:       []Item,
}

// Links to other parts of TIDAL. Fetch one with page_link_get.
Page_Links :: struct {
	title: string,
	more:  Maybe(More),
	items: []Page_Link,
}

Featured_Items :: struct {
	title:       string,
	description: string,
	items:       []Page_Item,
}

Text_Block :: struct {
	text: string,
	icon: string,
}

// Articles or social profiles.
Link_List :: struct {
	title:       string,
	description: string,
	items:       []Link,
}

Link :: struct {
	type:  string,
	title: string,
	url:   string,
}

// The header module of an artist, album or mix page.
Item_Header :: struct {
	item: Item,
}

Page_Link :: struct {
	title:    string,
	icon:     string,
	api_path: string,
	image_id: string,
}

// A featured entry. Fetch the full object with page_item_get.
Page_Item :: struct {
	header:           string,
	short_header:     string,
	short_sub_header: string,
	image_id:         string,
	type:             string,
	artifact_id:      string,
	text:             string,
	featured:         bool,
}

Link_Login :: struct {
	// Seconds until the code expires
	expires_in:                f64,
	// The code the user should enter at the uri
	user_code:                 string,
	verification_uri:          string,
	// verification_uri with the code included
	verification_uri_complete: string,
	// Seconds between authorization checks
	interval:                  f64,
	device_code:               string,
}

Search_Type :: enum {
	Artist,
	Album,
	Track,
	Video,
	Playlist,
	Mix,
}

Search_Types :: bit_set[Search_Type]

SEARCH_ALL :: Search_Types{.Artist, .Album, .Track, .Video, .Playlist, .Mix}

Search_Results :: struct {
	artists:   []Artist,
	albums:    []Album,
	tracks:    []Track,
	videos:    []Video,
	playlists: []Playlist,
	top_hit:   Maybe(Item),
}

Album_Order :: enum {
	Artist,
	Date_Added,
	Name,
	Release_Date,
}
ALBUM_ORDER_NAMES := [Album_Order]string {
	.Artist       = "ARTIST",
	.Date_Added   = "DATE",
	.Name         = "NAME",
	.Release_Date = "RELEASE_DATE",
}

Artist_Order :: enum {
	Date_Added,
	Name,
}
ARTIST_ORDER_NAMES := [Artist_Order]string {
	.Date_Added = "DATE",
	.Name       = "NAME",
}

Item_Order :: enum {
	Album,
	Artist,
	Date,
	Index,
	Length,
	Name,
}
ITEM_ORDER_NAMES := [Item_Order]string {
	.Album  = "ALBUM",
	.Artist = "ARTIST",
	.Date   = "DATE",
	.Index  = "INDEX",
	.Length = "LENGTH",
	.Name   = "NAME",
}

Mix_Order :: enum {
	Date_Added,
	Mix_Type,
	Name,
}
MIX_ORDER_NAMES := [Mix_Order]string {
	.Date_Added = "DATE",
	.Mix_Type   = "MIX_TYPE",
	.Name       = "NAME",
}

Playlist_Order :: enum {
	Date_Created,
	Name,
}
PLAYLIST_ORDER_NAMES := [Playlist_Order]string {
	.Date_Created = "DATE",
	.Name         = "NAME",
}

Video_Order :: enum {
	Artist,
	Date_Added,
	Name,
}
VIDEO_ORDER_NAMES := [Video_Order]string {
	.Artist     = "ARTIST",
	.Date_Added = "DATE",
	.Name       = "NAME",
}

Order_Direction :: enum {
	Ascending,
	Descending,
}
ORDER_DIRECTION_NAMES := [Order_Direction]string {
	.Ascending  = "ASC",
	.Descending = "DESC",
}
