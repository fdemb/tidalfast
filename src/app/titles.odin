package app

import "core:fmt"
import "core:strings"

// Rows for the text test list: song titles and artists in several scripts,
// mixed into ROW_COUNT rows. The strings are copied into the persistent
// arena, since literals live in the dylib's image.

ROW_COUNT :: 10_000

Row :: struct {
	title:    string,
	artist:   string,
	duration: string,
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
SUFFIXES := [?]string{"", "", "", "", " (Remastered 2011)", " - Live at Wembley", " (feat. Kendrick Lamar)", " [Extended Mix]", " (Demo)"}

make_rows :: proc() -> []Row {
	rows := make([]Row, ROW_COUNT)
	for &row, i in rows {
		h := u32(i) * 2654435761
		title := TITLES[(h >> 8) % len(TITLES)]
		suffix := SUFFIXES[(h >> 20) % len(SUFFIXES)]
		row.title = fmt.aprintf("%s%s", title, suffix)
		row.artist = strings.clone(ARTISTS[(h >> 14) % len(ARTISTS)])
		seconds := 95 + int(h >> 4) % 400
		row.duration = fmt.aprintf("%d:%02d", seconds / 60, seconds % 60)
	}
	return rows
}
