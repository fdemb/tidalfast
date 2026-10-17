#!/bin/bash
# Builds and drives a private TIDALfast instance for verification on macOS.
# Everything it builds and runs lives under $TIDALFAST_VERIFY_DIR
# (default /tmp/tidalfast-verify), so build/ and the user's running app are
# never touched. See SKILL.md next to this file.
#
#   verify.sh build                      shell, dylib and mock into $ROOT/bin
#   verify.sh doctor                     read-only health check
#   verify.sh mock-start | mock-stop     tests/mock_tidal on a free port
#   verify.sh run <label> <fake|mock> <steps>
#   verify.sh search <query> [fake|mock] the three-width search proof
#   verify.sh cleanup [--bin]            stop what we started, keep evidence
set -u

REPO=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=${TIDALFAST_VERIFY_DIR:-/tmp/tidalfast-verify}
BIN=$ROOT/bin
STATE=$ROOT/run
EVIDENCE_ROOT=$ROOT/evidence

die() {
	echo "verify: $*" >&2
	exit 1
}

newest_source() {
	find "$REPO/src" "$REPO/shell" -type f \( -name '*.odin' -o -name '*.m' -o -name '*.h' -o -name '*.c' \) -print0 |
		xargs -0 stat -f '%m' | sort -n | tail -1
}

cmd_build() {
	mkdir -p "$BIN"
	cd "$REPO" || die "no repo at $REPO"
	# The dylib links build/kbts/kb_text_shape.a; build it the way build.sh does.
	if [ ! -f build/kbts/kb_text_shape.a ]; then
		mkdir -p build/kbts
		cc -O2 -fPIC -c src/kbts/kb_text_shape.c -o build/kbts/kb_text_shape.o || die "kbts build failed"
		ar -rcs build/kbts/kb_text_shape.a build/kbts/kb_text_shape.o
		rm build/kbts/kb_text_shape.o
	fi
	echo "verify: building shell"
	clang shell/shell.m -o "$BIN/tidalfast" -fobjc-arc -mmacosx-version-min=14.0 \
		-Wall -Wno-unused-parameter -O2 -DHOT_RELOAD=0 \
		-framework Cocoa -framework Metal -framework QuartzCore -framework CoreServices -framework MediaPlayer ||
		die "shell build failed"
	# MOCK_API makes an optimized build honour TIDALFAST_API and
	# TIDALFAST_PKCE_REDIRECT, as ./build.sh measure does.
	echo "verify: building app dylib"
	odin build src/app -build-mode:dll -out:"$BIN/app.tmp.dylib" -vet -strict-style -o:speed \
		-define:TIDALFAST_MOCK_API=true || die "dylib build failed"
	mv -f "$BIN/app.tmp.dylib" "$BIN/app.dylib"
	echo "verify: building mock"
	odin build tests/mock_tidal -out:"$BIN/mock_tidal" -o:speed || die "mock build failed"
	echo "verify: built into $BIN"
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# loopback_url says whether $1 is an http URL on this machine, as mock_tidal
# prints it. An empty one would send the app to real TIDAL on older builds.
loopback_url() {
	[[ ${1:-} =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/.*)?$ ]]
}

# ours says whether pid is a process started from $BIN.
ours() {
	alive "$1" && ps -o command= -p "$1" | grep -q "^$BIN/"
}

cmd_doctor() {
	ok=1
	for f in tidalfast app.dylib mock_tidal; do
		[ -x "$BIN/$f" ] || { echo "FAIL $BIN/$f missing: run verify.sh build"; ok=0; }
	done
	if [ -f "$BIN/app.dylib" ]; then
		built=$(stat -f '%m' "$BIN/app.dylib")
		[ "$built" -ge "$(newest_source)" ] && echo "ok   build is newer than src/ and shell/" ||
			{ echo "FAIL src/ or shell/ changed after the last build: run verify.sh build"; ok=0; }
	fi
	if [ -f "$BIN/tidalfast" ]; then
		strings "$BIN/tidalfast" | grep -q "size wants w,h" && echo "ok   shell has the size= test step" ||
			{ echo "FAIL shell lacks the size= test step"; ok=0; }
	fi
	app=$(cat "$STATE/app.pid" 2>/dev/null)
	if ours "$app"; then echo "BUSY app $app from an earlier run is still up: run verify.sh cleanup"; ok=0; fi
	mock=$(cat "$STATE/mock.pid" 2>/dev/null)
	if [ -n "$mock" ]; then
		url=$(cat "$STATE/mock.url" 2>/dev/null)
		if ! loopback_url "$url"; then
			echo "FAIL mock.url is empty or not a loopback http URL: run verify.sh mock-stop, then mock-start"
			ok=0
		elif ours "$mock" && curl -s -o /dev/null -m 2 "$url/"; then
			echo "ok   mock $mock at $url"
		else
			echo "FAIL mock $mock recorded but not answering: run verify.sh mock-stop"
			ok=0
		fi
	else
		echo "--   no mock running (only fake runs work)"
	fi
	if pgrep -xq AeroSpace; then
		aerospace list-windows --all --count >/dev/null 2>&1 && echo "ok   AeroSpace CLI answers" ||
			{ echo "FAIL AeroSpace runs but its CLI doesn't answer, so windows can't be floated"; ok=0; }
	fi
	for name in $(cat "$STATE/keychains" 2>/dev/null); do
		security find-generic-password -s "$name" >/dev/null 2>&1 && echo "--   test keychain item $name exists (cleanup deletes it)"
	done
	[ $ok = 1 ] && echo "doctor: ready" || { echo "doctor: not ready"; return 1; }
}

cmd_mock_start() {
	mkdir -p "$STATE"
	ours "$(cat "$STATE/mock.pid" 2>/dev/null)" && { echo "verify: mock already at $(cat "$STATE/mock.url")"; return; }
	[ -x "$BIN/mock_tidal" ] || die "no mock: run verify.sh build"
	"$BIN/mock_tidal" -port=0 -audio-dir="$STATE/mock-audio" >"$STATE/mock.log" 2>&1 &
	echo $! >"$STATE/mock.pid"
	for _ in $(seq 1 100); do
		url=$(sed -n 's/^mock: listening on //p' "$STATE/mock.log" | head -1)
		[ -n "$url" ] && break
		/bin/sleep 0.1
	done
	[ -n "$url" ] || die "mock didn't start; see $STATE/mock.log"
	echo "$url" >"$STATE/mock.url"
	echo "verify: mock $(cat "$STATE/mock.pid") at $url"
}

cmd_mock_stop() {
	pid=$(cat "$STATE/mock.pid" 2>/dev/null)
	ours "$pid" && kill "$pid"
	rm -f "$STATE/mock.pid" "$STATE/mock.url"
}

# float_window makes the tiling window manager leave the app's window alone,
# so size= steps stick. Without AeroSpace there is nothing to do.
float_window() {
	pgrep -xq AeroSpace || return 0
	for _ in $(seq 1 50); do
		id=$(aerospace list-windows --all --format '%{window-id} %{app-pid}' 2>/dev/null | awk -v p="$1" '$2 == p { print $1; exit }')
		if [ -n "$id" ]; then
			aerospace layout floating --window-id "$id" && echo "verify: floated window $id" && return 0
		fi
		/bin/sleep 0.1
	done
	echo "verify: couldn't float the window; size= steps may not apply" >&2
	return 1
}

# run launches the app with private settings, cache, keychain and capture
# paths, plays the steps, waits for it to quit and converts the captures.
# capture=@name in steps becomes a capture to name.png in the evidence
# directory.
cmd_run() {
	label=$1 mode=$2 steps=$3
	[ -x "$BIN/tidalfast" ] || die "nothing built: run verify.sh build"
	ours "$(cat "$STATE/app.pid" 2>/dev/null)" && die "an app from an earlier run is still up: run verify.sh cleanup"
	mkdir -p "$STATE"
	EVIDENCE="$EVIDENCE_ROOT/$(date +%Y%m%d-%H%M%S)-$label"
	mkdir -p "$EVIDENCE"
	steps=$(printf '%s' "$steps" | sed -E "s#capture=@([^;|]+)#capture=$EVIDENCE/\\1.tga#g")
	env_args=(
		TIDALFAST_SETTINGS="$STATE/settings.json"
		TIDALFAST_CACHE="$STATE/cache"
		TIDALFAST_CAPTURE="$STATE/frame.tga"
		TIDALFAST_SHELL_TEST="$steps"
		TIDALFAST_AUDIO_NULL=1
	)
	[ -n "${AUDIO_CAPTURE:-}" ] && env_args+=(TIDALFAST_AUDIO_CAPTURE="$EVIDENCE/audio.wav")
	case $mode in
	fake) env_args+=(TIDALFAST_FAKE=1) ;;
	mock)
		url=$(cat "$STATE/mock.url" 2>/dev/null)
		ours "$(cat "$STATE/mock.pid" 2>/dev/null)" || die "no mock running: run verify.sh mock-start"
		loopback_url "$url" || die "mock.url is empty or not a loopback http URL: run verify.sh mock-stop, then mock-start"
		keychain=$(cat "$STATE/keychain" 2>/dev/null)
		if [ -z "$keychain" ]; then
			keychain="tidalfast-verify-$(openssl rand -hex 4)"
			echo "$keychain" >"$STATE/keychain"
			echo "$keychain" >>"$STATE/keychains"
		fi
		env_args+=(
			TIDALFAST_API="$url"
			TIDALFAST_KEYCHAIN="$keychain"
			TIDALFAST_PKCE_REDIRECT="$url/android/login/auth?code=mock-pkce-code-1"
			TIDALFAST_LOG_HTTP=1
		)
		;;
	*) die "mode is fake or mock" ;;
	esac
	echo "$steps" >"$EVIDENCE/steps.txt"
	# env -i keeps the caller's TIDALFAST_ variables out, so the real API or
	# keychain can't leak in.
	env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" "${env_args[@]}" "$BIN/tidalfast" >"$EVIDENCE/app.log" 2>&1 &
	app=$!
	echo $app >"$STATE/app.pid"
	echo "verify: app $app ($mode), evidence in $EVIDENCE"
	float_window $app
	last=$(echo "$steps" | tr ';' '\n' | cut -d: -f1 | sort -n | tail -1)
	deadline=$(( ${last%.*} + 15 ))
	for _ in $(seq 1 $((deadline * 10))); do alive $app || break; /bin/sleep 0.1; done
	if alive $app; then
		echo "verify: app didn't quit by ${deadline}s, killing $app" >&2
		kill $app
	fi
	rm -f "$STATE/app.pid"
	for tga in "$EVIDENCE"/*.tga; do
		[ -f "$tga" ] || continue
		sips -s format png "$tga" --out "${tga%.tga}.png" >/dev/null && rm "$tga"
	done
	echo "$EVIDENCE" >"$STATE/last-evidence"
	ls "$EVIDENCE"
}

png_width() { sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/ { print $2 }'; }

# search proves the search journey: Cmd-F, type, wait out the debounce,
# capture at 1100, 820 and 1600 pt, dump the accessibility tree, quit.
cmd_search() {
	query=$1 mode=${2:-fake}
	# Mock runs log in and load the library first.
	t=3
	[ "$mode" = mock ] && t=8
	at() { awk -v a="$t" -v b="$1" 'BEGIN { print a + b }'; }
	steps="$(at 0):size=1100,700;$(at 0.5):key=cmd+f;$(at 1):commit=$query"
	steps="$steps;$(at 3):capture=@search-1100;$(at 3.5):size=820,700;$(at 5):capture=@search-820"
	steps="$steps;$(at 5.5):size=1600,1000;$(at 7):capture=@search-1600;$(at 7.5):ax-dump;$(at 8):quit"
	cmd_run search "$mode" "$steps" || return 1
	ev=$(cat "$STATE/last-evidence")
	fail=0
	grep -F "search: \"$query\": " "$ev/app.log" || { echo "FAIL no search result line for \"$query\" in app.log"; fail=1; }
	for w in 820 1100 1600; do
		[ -f "$ev/search-$w.png" ] || { echo "FAIL search-$w.png missing"; fail=1; }
	done
	if [ $fail = 0 ]; then
		# Pixel widths must follow the point widths, whatever the scale.
		w820=$(png_width "$ev/search-820.png") w1100=$(png_width "$ev/search-1100.png") w1600=$(png_width "$ev/search-1600.png")
		echo "verify: pixel widths 820pt=$w820 1100pt=$w1100 1600pt=$w1600"
		awk -v a="$w820" -v b="$w1100" -v c="$w1600" 'BEGIN { s = b / 1100; exit !(a == 820 * s && c == 1600 * s) }' ||
			{ echo "FAIL captures aren't 820/1100/1600 pt wide; was the window floated?"; fail=1; }
	fi
	[ $fail = 0 ] && echo "verify: search proof in $ev" || { echo "verify: search proof failed, see $ev"; return 1; }
}

cmd_cleanup() {
	app=$(cat "$STATE/app.pid" 2>/dev/null)
	ours "$app" && kill "$app"
	cmd_mock_stop
	for name in $(cat "$STATE/keychains" 2>/dev/null); do
		case $name in
		tidalfast-verify-*) security delete-generic-password -s "$name" >/dev/null 2>&1 && echo "verify: deleted keychain item $name" ;;
		esac
	done
	rm -rf "$STATE"
	[ "${1:-}" = --bin ] && rm -rf "$BIN"
	echo "verify: cleaned up; evidence kept in $EVIDENCE_ROOT"
}

case ${1:-} in
build) cmd_build ;;
doctor) cmd_doctor ;;
mock-start) cmd_mock_start ;;
mock-stop) cmd_mock_stop ;;
run) [ $# -eq 4 ] || die "usage: verify.sh run <label> <fake|mock> <steps>"; cmd_run "$2" "$3" "$4" ;;
search) [ $# -ge 2 ] || die "usage: verify.sh search <query> [fake|mock]"; cmd_search "$2" "${3:-fake}" ;;
cleanup) cmd_cleanup "${2:-}" ;;
*) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
