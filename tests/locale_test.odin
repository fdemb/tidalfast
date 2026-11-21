package tidal_tests

import "core:fmt"
import "core:testing"
import "core:time"

import app "../src/app"
import "../src/sys"
import tidal "../src/tidal"

@(test)
locale_normalize_takes_os_names :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"pl_PL.UTF-8", "pl_PL"},
		{"pl_PL.UTF-8@euro", "pl_PL"},
		{"de_DE@euro", "de_DE"},
		{"pl-PL", "pl_PL"},
		{"en_GB", "en_GB"},
		{"zh-Hans-CN", "zh_CN"},
		{"zh_Hant_TW", "zh_TW"},
		{"en_US_POSIX", "en_US"},
		{"sr-Latn-RS", "sr_RS"},
		{"EN-gb", "en_GB"},
		{" fr_CA ", "fr_CA"},
		// A language alone gets its likely region.
		{"en", "en_US"},
		{"de", "de_DE"},
		{"ja", "ja_JP"},
		{"pt", "pt_BR"},
		{"nb", "nb_NO"},
		{"es-419", "es_ES"},
		{"zh-Hans", "zh_CN"},
		// Nothing usable falls back.
		{"C", "en_US"},
		{"C.UTF-8", "en_US"},
		{"POSIX", "en_US"},
		{"", "en_US"},
		{"xx", "en_US"},
		{"fil_PH", "en_US"},
		{"english", "en_US"},
		{"e1_US", "en_US"},
		{"_US", "en_US"},
		{".UTF-8", "en_US"},
		{"пл_PL", "en_US"},
	}
	for c in cases {
		got := sys.locale_normalize(c[0], context.temp_allocator)
		testing.expectf(t, got == c[1], "%q: got %q, want %q", c[0], got, c[1])
	}
}

@(test)
system_locale_is_well_formed :: proc(t: ^testing.T) {
	l := sys.locale(context.temp_allocator)
	ok := len(l) == 5 && l[2] == '_'
	for i in ([]int{0, 1}) {
		ok &&= l[i] >= 'a' && l[i] <= 'z'
	}
	for i in ([]int{3, 4}) {
		ok &&= l[i] >= 'A' && l[i] <= 'Z'
	}
	testing.expectf(t, ok, "sys.locale() = %q", l)
}

@(test)
app_locale_is_pinned_against_the_mock :: proc(t: ^testing.T) {
	testing.expect_value(t, app.session_locale("", true, context.temp_allocator), "en_US")
	testing.expect_value(t, app.session_locale("pl_PL.UTF-8", true, context.temp_allocator), "pl_PL")
	testing.expect_value(t, app.session_locale("de-AT", false, context.temp_allocator), "de_AT")
	testing.expect_value(t, app.session_locale("nonsense", false, context.temp_allocator), "en_US")
}

@(private = "file")
locale_session :: proc(t: ^testing.T, m: ^Mock, locale: string) -> ^tidal.Session {
	s := tidal.session_create(locale = locale)
	s.config.api_v1_location = m.base_url
	s.config.api_v2_location = fmt.tprintf("%sv2/", m.base_url)
	s.config.api_oauth2_token = "http://127.0.0.1:1/token" // must never be called
	err := tidal.load_oauth_session(s, "Bearer", "access", "refresh", time.time_add(time.now(), time.Hour))
	testing.expect_value(t, err, nil)
	return s
}

@(test)
session_sends_its_locale :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)

	s := locale_session(t, &m, "pl_PL")
	defer tidal.session_destroy(s)
	_, err := tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.last_query["locale"], "pl_PL")

	// A request's own value wins.
	_, err = tidal.request(s, {method = .GET, path = "echo", params = {{"locale", "de_DE"}}}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.last_query["locale"], "de_DE")

	// The v2 API isn't sent it.
	_, _ = tidal.request(s, {method = .GET, path = "echo", base_url = s.config.api_v2_location}, context.temp_allocator)
	testing.expect_value(t, mock_count(&m, "GET /v2/echo?"), 1)
	testing.expect(t, "locale" not_in m.last_query)

	// It isn't login state, so it outlives a sign-out.
	tidal.session_clear_auth(s)
	err = tidal.load_oauth_session(s, "Bearer", "access", "refresh", time.time_add(time.now(), time.Hour))
	testing.expect_value(t, err, nil)
	_, err = tidal.request(s, {method = .GET, path = "echo"}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.last_query["locale"], "pl_PL")
}

@(test)
session_without_locale_sends_en_us :: proc(t: ^testing.T) {
	m: Mock
	mock_start(&m)
	defer mock_stop(&m)

	s := locale_session(t, &m, "")
	defer tidal.session_destroy(s)
	_, err := tidal.home(s, context.temp_allocator)
	_ = err
	testing.expect_value(t, mock_count(&m, "GET /pages/home?"), 1)
	testing.expect_value(t, m.last_query["locale"], "en_US")
}

@(test)
keychain_item_with_a_locale_still_restores :: proc(t: ^testing.T) {
	// Items saved before the locale left the login state carry one.
	s := tidal.session_create(locale = "pl_PL")
	defer tidal.session_destroy(s)
	old := `{"token_type":"Bearer","access_token":"a","refresh_token":"r","expiry":0,"session_id":"","country_code":"PL","locale":"en_US","user_id":5,"is_pkce":false,"client_id":""}`
	testing.expect(t, app.auth_restore(s, transmute([]u8)string(old)))
	testing.expect_value(t, s.country_code, "PL")
	testing.expect_value(t, s.config.locale, "pl_PL")
}
