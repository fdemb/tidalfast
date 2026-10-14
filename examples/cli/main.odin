// Small CLI over the tidal package. Each command allocates its results in
// one arena, the way a UI view would, and frees them all at once.
package main

import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"

import tidal "../../tidal"

SESSION_FILE :: "tidal-session.json"

usage :: proc() {
	fmt.eprintln(`usage: cli <command> [args]

  login                 log in with a device code (saved to ` + SESSION_FILE + `)
  device-code           request a device code and print it, without logging in
  search <query>        search artists, albums and tracks
  track <id>            show a track and its stream URLs
  album <id>            list an album's tracks
  home                  list the rows of the home page
  favorites             list favorite tracks`)
}

main :: proc() {
	context.logger = log.create_console_logger(.Warning)

	if len(os.args) < 2 {
		usage()
		os.exit(2)
	}

	s := tidal.session_create(quality = .High_Lossless)
	defer tidal.session_destroy(s)

	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	view := vmem.arena_allocator(&arena)

	err: tidal.Error
	switch os.args[1] {
	case "login":
		ok: bool
		ok, err = tidal.login_session_file(s, SESSION_FILE)
		if ok {
			if u, has := tidal.session_user(s, view); has {
				fmt.printfln("Logged in as %s (user %d)", u.username, u.id)
			}
		}
	case "device-code":
		err = device_code(s, view)
	case "search":
		err = with_login(s, proc(s: ^tidal.Session, view: mem.Allocator) -> tidal.Error {
			return search(s, arg(2), view)
		}, view)
	case "track":
		err = with_login(s, proc(s: ^tidal.Session, view: mem.Allocator) -> tidal.Error {
			return show_track(s, id_arg(2), view)
		}, view)
	case "album":
		err = with_login(s, proc(s: ^tidal.Session, view: mem.Allocator) -> tidal.Error {
			return show_album(s, id_arg(2), view)
		}, view)
	case "home":
		err = with_login(s, show_home, view)
	case "favorites":
		err = with_login(s, show_favorites, view)
	case:
		usage()
		os.exit(2)
	}

	if err != nil {
		fmt.eprintln("error:", tidal.error_string(err, view))
		os.exit(1)
	}
}

arg :: proc(i: int) -> string {
	if i >= len(os.args) {
		usage()
		os.exit(2)
	}
	return os.args[i]
}

id_arg :: proc(i: int) -> i64 {
	id, ok := strconv.parse_i64(arg(i))
	if !ok {
		fmt.eprintln("not a numeric id:", os.args[i])
		os.exit(2)
	}
	return id
}

with_login :: proc(s: ^tidal.Session, run: proc(s: ^tidal.Session, view: mem.Allocator) -> tidal.Error, view: mem.Allocator) -> tidal.Error {
	if err := tidal.session_load_file(s, SESSION_FILE); err != nil {
		fmt.eprintln("not logged in, run: cli login")
		return err
	}
	return run(s, view)
}

device_code :: proc(s: ^tidal.Session, view: mem.Allocator) -> tidal.Error {
	link := tidal.login_device_start(s, view) or_return
	fmt.printfln("Visit https://%s (code %s, expires in %vs)", link.verification_uri_complete, link.user_code, int(link.expires_in))
	return nil
}

search :: proc(s: ^tidal.Session, query: string, view: mem.Allocator) -> tidal.Error {
	r := tidal.search(s, query, {.Artist, .Album, .Track}, limit = 5, allocator = view) or_return
	if top, ok := r.top_hit.?; ok {
		fmt.printfln("Top hit: %v", item_title(top))
	}
	fmt.println("\nArtists:")
	for a in r.artists {
		fmt.printfln("  %-10d %s", a.id, a.name)
	}
	fmt.println("\nAlbums:")
	for a in r.albums {
		fmt.printfln("  %-10d %s - %s", a.id, artist_name(a.artist), a.name)
	}
	fmt.println("\nTracks:")
	for t in r.tracks {
		fmt.printfln("  %-10d %s - %s", t.id, artist_name(t.artist), t.full_name)
	}
	return nil
}

show_track :: proc(s: ^tidal.Session, id: i64, view: mem.Allocator) -> tidal.Error {
	t := tidal.track_get(s, id, with_album = true, allocator = view) or_return
	fmt.printfln("%s - %s", artist_name(t.artist), t.full_name)
	if t.album != nil {
		fmt.printfln("Album:    %s (%v)", t.album.name, tidal.album_year(t.album^))
		cover, _ := tidal.album_image_url(s, t.album^, 640, view)
		fmt.printfln("Cover:    %s", cover)
	}
	fmt.printfln("Quality:  %s, ISRC %s", t.audio_quality, t.isrc)

	stream := tidal.track_stream(s, id, view) or_return
	fmt.printfln("Stream:   %s, %d bit / %d Hz", stream.audio_quality, stream.bit_depth, stream.sample_rate)
	manifest := tidal.stream_get_manifest(stream, view) or_return
	fmt.printfln("Manifest: %s, codec %s, %d URL(s), %s", stream.manifest_mime_type, manifest.codecs, len(manifest.urls), manifest.file_extension)
	if len(manifest.urls) > 0 {
		fmt.printfln("First:    %s", manifest.urls[0])
	}
	return nil
}

show_album :: proc(s: ^tidal.Session, id: i64, view: mem.Allocator) -> tidal.Error {
	album := tidal.album_get(s, id, view) or_return
	fmt.printfln("%s - %s, %d tracks", artist_name(album.artist), album.name, album.num_tracks)
	tracks := tidal.album_tracks(s, id, parent = &album, allocator = view) or_return
	for t in tracks {
		fmt.printfln("  %2d. %s", t.track_num, t.full_name)
	}
	return nil
}

show_home :: proc(s: ^tidal.Session, view: mem.Allocator) -> tidal.Error {
	page := tidal.home(s, allocator = view) or_return
	for category in page.categories {
		#partial switch c in category {
		case tidal.Item_List:
			fmt.printfln("%s (%d)", c.title, len(c.items))
			for item, i in c.items {
				if i == 5 {
					fmt.println("  ...")
					break
				}
				fmt.printfln("  %s", item_title(item))
			}
		}
	}
	return nil
}

show_favorites :: proc(s: ^tidal.Session, view: mem.Allocator) -> tidal.Error {
	tracks := tidal.favorites_tracks_paginated(s, .Date, .Descending, view) or_return
	fmt.printfln("%d favorite tracks", len(tracks))
	for t in tracks[:min(20, len(tracks))] {
		fmt.printfln("  %s - %s", artist_name(t.artist), t.full_name)
	}
	return nil
}

artist_name :: proc(a: ^tidal.Artist) -> string {
	return a.name if a != nil else "?"
}

item_title :: proc(item: tidal.Item) -> string {
	switch v in item {
	case tidal.Artist:
		return v.name
	case tidal.Album:
		return v.name
	case tidal.Track:
		return v.full_name
	case tidal.Video:
		return v.title
	case tidal.Playlist:
		return v.name
	case tidal.Mix:
		return v.title
	case tidal.Mix_V2:
		return v.title
	case tidal.Page_Item:
		return v.header
	case tidal.Page_Link:
		return v.title
	}
	return ""
}
