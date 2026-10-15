package tidal

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:fmt"
import "core:log"
import "core:mem"

Quality :: enum {
	Low_96k,
	Low_320k,
	High_Lossless,
	Hi_Res_Lossless,
}

QUALITY_NAMES := [Quality]string {
	.Low_96k         = "LOW",
	.Low_320k        = "HIGH",
	.High_Lossless   = "LOSSLESS",
	.Hi_Res_Lossless = "HI_RES_LOSSLESS",
}

DEFAULT_QUALITY :: Quality.Low_320k

Video_Quality :: enum {
	High,
	Medium,
	Low,
	Audio_Only,
}

VIDEO_QUALITY_NAMES := [Video_Quality]string {
	.High       = "HIGH",
	.Medium     = "MEDIUM",
	.Low        = "LOW",
	.Audio_Only = "AUDIO_ONLY",
}

DEFAULT_VIDEO_QUALITY :: Video_Quality.High

// Config holds endpoints, OAuth clients and request defaults.
//
// The maximum item_limit is 10000. Some endpoints cap at 100 items; use
// offsets to page past that. Changing alac requires logging in again.
// alac = false turns video streams into audio-only streams, and num_videos
// becomes num_tracks in playlists.
//
// Fields may be changed after session_create, before the session is used
// from several threads.
Config :: struct {
	api_oauth2_token:    string,
	api_device_auth:     string,
	api_pkce_auth:       string,
	api_v1_location:     string,
	api_v2_location:     string,
	openapi_v2_location: string,
	// Format strings taking (image id with '-' replaced by '/', width, height).
	image_url:           string,
	image_url_origin:    string,
	video_url:           string,
	video_url_origin:    string,
	listen_base_url:     string,
	share_base_url:      string,
	pkce_uri_redirect:   string,

	client_id:           string,
	client_secret:       string,
	client_id_pkce:      string,
	client_secret_pkce:  string,
	// PKCE state, generated once per Config.
	client_unique_key:   string,
	code_verifier:       string,
	code_challenge:      string,

	item_limit:          int,
	// Stop sending requests for a while after TIDAL answers with a rate limit
	// (HTTP 429) or an anti-abuse rejection. While backing off, requests fail
	// with .Backing_Off instead of reaching TIDAL.
	backoff:             bool,
	quality:             Quality,
	video_quality:       Video_Quality,
	alac:                bool,
	// Per-request timeout in seconds, 0 for none.
	timeout_seconds:     int,
}

// config_make builds a Config with TIDAL's endpoints, the OAuth clients and
// fresh PKCE state. Generated strings are allocated with allocator.
config_make :: proc(
	quality := DEFAULT_QUALITY,
	video_quality := DEFAULT_VIDEO_QUALITY,
	item_limit := 1000,
	alac := true,
	backoff := true,
	allocator := context.allocator,
) -> Config {
	c := Config {
		api_oauth2_token    = "https://auth.tidal.com/v1/oauth2/token",
		api_device_auth     = "https://auth.tidal.com/v1/oauth2/device_authorization",
		api_pkce_auth       = "https://login.tidal.com/authorize",
		api_v1_location     = "https://api.tidal.com/v1/",
		api_v2_location     = "https://api.tidal.com/v2/",
		openapi_v2_location = "https://openapi.tidal.com/v2/",
		image_url           = "https://resources.tidal.com/images/%s/%dx%d.jpg",
		image_url_origin    = "https://resources.tidal.com/images/%s/origin.jpg",
		video_url           = "https://resources.tidal.com/videos/%s/%dx%d.mp4",
		video_url_origin    = "https://resources.tidal.com/videos/%s/origin.mp4",
		listen_base_url     = "https://listen.tidal.com",
		share_base_url      = "https://tidal.com/browse",
		pkce_uri_redirect   = "https://tidal.com/android/login/auth",
		quality             = quality,
		video_quality       = video_quality,
		alac                = alac,
		backoff             = backoff,
		item_limit          = item_limit,
		timeout_seconds     = 30,
	}

	if item_limit > 10000 {
		log.warn("Item limit was set above 10000, which is not supported by TIDAL, setting to 10000")
		c.item_limit = 10000
	}

	// OAuth client authorization
	c.client_id = double_b64("WmxneVNuaGtiVzUw", "V2xkTE1HbDRWQT09", allocator)
	c.client_secret = double_b64(
		"TVU1dU9VRm1SRUZxZUhKblNrWktZa3RPVjB4bFFY",
		"bExSMVpIYlVsT2RWaFFVRXhJVmxoQmRuaEJaejA9",
		allocator,
	)
	if c.client_secret == "" && c.client_id != "" {
		c.client_secret = c.client_id
	}

	// PKCE client authorization. client_id stays the fallback for non-PKCE logins.
	c.code_verifier, c.client_unique_key = pkce_new_state(allocator)
	c.code_challenge = pkce_challenge(c.code_verifier, allocator)

	c.client_id_pkce = double_b64("TmtKRVUxSmtjRXM=", "NWFIRkZRbFJuVlE9PQ==", allocator)
	c.client_secret_pkce = double_b64(
		"ZUdWMVVHMVpOMjVpY0ZvNVNVbGlURUZqVVQ=",
		"a3pjMmhyWVRGV1RtaGxWVUZ4VGpaSlkzTjZhbFJIT0QwPQ==",
		allocator,
	)
	return c
}

// pkce_new_state makes a random PKCE code verifier (32 bytes, unpadded
// base64url) and client unique key (64 bits in hex).
pkce_new_state :: proc(allocator := context.allocator) -> (code_verifier, client_unique_key: string) {
	key: u64
	crypto.rand_bytes(mem.ptr_to_bytes(&key))
	client_unique_key = fmt.aprintf("%x", key, allocator = allocator)
	verifier_bytes: [32]u8
	crypto.rand_bytes(verifier_bytes[:])
	code_verifier = base64.encode(verifier_bytes[:], base64.ENC_URL_TABLE, allocator, {.No_Padding})
	return
}

// pkce_challenge is the S256 code challenge for a PKCE code verifier:
// unpadded base64url of its SHA-256.
pkce_challenge :: proc(verifier: string, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)verifier)
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:])
	return base64.encode(digest[:], base64.ENC_URL_TABLE, allocator, {.No_Padding})
}

// Decodes the concatenation of base64-decoding a and b.
@(private)
double_b64 :: proc(a, b: string, allocator: mem.Allocator) -> string {
	x, _ := base64.decode(a, allocator = context.temp_allocator)
	y, _ := base64.decode(b, allocator = context.temp_allocator)
	joined := make([]u8, len(x) + len(y), context.temp_allocator)
	copy(joined, x)
	copy(joined[len(x):], y)
	out, _ := base64.decode(string(joined), allocator = allocator)
	return string(out)
}
