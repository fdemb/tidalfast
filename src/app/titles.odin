package app

import "core:fmt"
import "core:strings"

// Fake tracks for the test screens and the library table: song titles and
// artists in several scripts, mixed into ROW_COUNT rows with made-up albums,
// dates and durations. The strings are copied into the persistent arena,
// since literals live in the dylib's image.

ROW_COUNT :: 10_000

Row :: struct {
	title:    string,
	artist:   string,
	album:    string,
	added:    string, // date added
	duration: string,
	cover:    string, // album cover image id, "" in the fake data
	seconds:  int,
	id:       i64, // TIDAL track id, 0 in the fake data
	album_id: i64,
	artists:  []Artist_Ref, // each artist in artist; nil in the fake data
	track:    int, // number on its album
}

// Artist_Ref is one of a track's or an album's artists: its TIDAL id and
// where its name is in the artist string that joins them all.
Artist_Ref :: struct {
	id:         i64,
	start, end: i32,
}

artist_name :: proc(joined: string, a: Artist_Ref) -> string {
	return joined[a.start:a.end]
}

// first_artist is the id of the first artist, or 0.
first_artist :: proc(artists: []Artist_Ref) -> i64 {
	return artists[0].id if len(artists) > 0 else 0
}

@(private = "file")
TITLES := [?]string {
	"Blue in Green",
	"So What",
	"Hamburg Sinfonietta",
	"Strawberry Fields Forever",
	"Bohemian Rhapsody",
	"Smells Like Teen Spirit",
	"Paranoid Android",
	"A Day in the Life",
	"Teardrop",
	"Windowlicker",
	"Midnight City",
	"Dreams",
	"Hyperballad",
	"Pyramid Song",
	"Born Slippy .NUXX",
	"Avril 14th",
	"Jóga",
	"Svefn-g-englar",
	"Où est la fête ?",
	"Bésame Mucho",
	"Garota de Ipanema",
	"Ça plane pour moi",
	"Die Moritat von Mackie Messer",
	"Wszystko czego dziś chcę",
	"Kocham wolność",
	"Звезда по имени Солнце",
	"Группа крови",
	"Ήρθες",
	"Last Night a DJ Saved My Life",
	"Everything In Its Right Place",
	"Can't Stop the Feeling!",
	"I Wanna Dance with Somebody (Who Loves Me)",
	"Symphony No. 9 in D Minor, Op. 125: IV. Presto",
	"Concerto for Two Violins in D Minor, BWV 1043: I. Vivace",
	"夜に駆ける",
	"千本桜",
	"真夜中のドア〜stay with me",
	"晴天",
	"月亮代表我的心",
	"小幸运",
	"봄날",
	"밤편지",
	"Dynamite",
	"تملی معاک",
	"أنا لحبيبي",
	"عيونك",
	"سهرانة",
	"إنت عمري",
	"שיר לשלום",
	"ירושלים של זהב",
	"הללויה",
	"Ya Rayah يا رايح",
	"Hava Nagila הבה נגילה",
	"Lose Yourself 🔥",
	"Happy 😀",
	"Despacito 💃🕺",
	"Rainbow 🏳️‍🌈",
	"Polska 🇵🇱 Gola!",
	"Family 👨‍👩‍👧 Road Trip",
	"Love Story ❤️",
	"Moonlight 🌙✨",
}

@(private = "file")
ARTISTS := [?]string {
	"Miles Davis",
	"Boards of Canada",
	"The Beatles",
	"Queen",
	"Nirvana",
	"Radiohead",
	"Massive Attack",
	"Aphex Twin",
	"M83",
	"Fleetwood Mac",
	"Björk",
	"Sigur Rós",
	"Underworld",
	"Daft Punk",
	"Ennio Morricone",
	"Kino",
	"Kult",
	"Ludwig van Beethoven",
	"Itzhak Perlman, Pinchas Zukerman",
	"YOASOBI",
	"初音ミク",
	"松原みき",
	"周杰伦",
	"邓丽君",
	"BTS",
	"아이유",
	"عمرو دياب",
	"فيروز",
	"أم كلثوم",
	"Rachid Taha",
	"עופרה חזה",
	"נעמי שמר",
	"Eminem",
	"Luis Fonsi, Daddy Yankee",
}

@(private = "file")
ALBUMS := [?]string {
	"Kind of Blue",
	"Music Has the Right to Children",
	"Sgt. Pepper's Lonely Hearts Club Band",
	"A Night at the Opera",
	"Nevermind",
	"OK Computer",
	"Mezzanine",
	"Windowlicker EP",
	"Hurry Up, We're Dreaming",
	"Rumours",
	"Post",
	"Ágætis byrjun",
	"Second Toughest in the Infants",
	"Discovery",
	"Gruppa krovi",
	"Symphony No. 9 \"Choral\"",
	"THE BOOK",
	"Pocket Lover",
	"Love Yourself: Her",
	"Palette",
	"Nour El Ein",
	"Diwân",
	"The Marshall Mathers LP",
	"VIDA",
	"夜に駆ける",
	"Shades of Yemen",
}

@(private = "file")
MONTHS := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

@(private = "file")
SUFFIXES := [?]string{"", "", "", "", " (Remastered 2011)", " - Live at Wembley", " (feat. Kendrick Lamar)", " [Extended Mix]", " (Demo)"}

make_rows :: proc(allocator := context.allocator) -> []Row {
	context.allocator = allocator
	rows := make([]Row, ROW_COUNT)
	for &row, i in rows {
		h := u32(i) * 2654435761
		title := TITLES[(h >> 8) % len(TITLES)]
		suffix := SUFFIXES[(h >> 20) % len(SUFFIXES)]
		row.title = fmt.aprintf("%s%s", title, suffix)
		row.artist = strings.clone(ARTISTS[(h >> 14) % len(ARTISTS)])
		row.album = strings.clone(ALBUMS[(h >> 11) % len(ALBUMS)])
		day := (h >> 3) % 28 + 1
		row.added = fmt.aprintf("%s %d, %d", MONTHS[(h >> 17) % 12], day, 2016 + (ROW_COUNT - i) * 9 / ROW_COUNT)
		seconds := 95 + int(h >> 4) % 400
		row.seconds = seconds
		row.duration = fmt.aprintf("%d:%02d", seconds / 60, seconds % 60)
	}
	return rows
}
