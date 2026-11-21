#!/bin/sh
# Runs the built app through its main flows under tools/headless.sh and
# checks its log: once with the fake data and once logged in to
# tests/mock_tidal. Each run drives the app with TIDALFAST_SHELL_TEST, waits
# with wait-ax for what each step should show, and quits. A run passes when
# every awaited node showed, the app quit with 0 before the time limit, and
# its log has no error, panic, failed assertion or sanitizer report, and no
# token, Authorization header or URL with a query.
#
#   tools/smoke.sh [-a app] [-m mock_tidal] [-f mock flags] [-o dir] [-t seconds] [fake] [mock]
#
# -a is a debug build of the app (default build/tidalfast), since only debug
# and measure builds take TIDALFAST_API. -m is the mock server (default
# build/measure/mock_tidal, from ./build.py measure), and -f more flags for
# it, such as -rate-limit-at=20, split at spaces. -o keeps the logs in
# dir, which CI uploads on a failure; without it they go in a temp dir that
# is kept only on a failure. -t is each run's time limit (default 120 s).
# The scenarios to run default to both. Exits 0 when all pass, 1 when one
# fails, 2 when it couldn't run.

set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 2

if [ "${1:-}" = --inside ]; then
	# Inside the headless session: tools/smoke.sh --inside app log. An
	# unlocked throwaway keyring keeps the login without a prompt, which
	# would otherwise hold the keychain calls until a person answered.
	app=$2 log=$3
	if command -v gnome-keyring-daemon > /dev/null 2>&1; then
		echo x | gnome-keyring-daemon --unlock --components=secrets > /dev/null 2>&1
	fi
	"$app" > "$log" 2>&1
	code=$?
	if [ -n "${TIDALFAST_KEYCHAIN:-}" ] && command -v secret-tool > /dev/null 2>&1; then
		secret-tool clear service "$TIDALFAST_KEYCHAIN" > /dev/null 2>&1
	fi
	exit "$code"
fi

usage() {
	echo "usage: $0 [-a app] [-m mock_tidal] [-f mock flags] [-o dir] [-t seconds] [fake] [mock]" >&2
	exit 2
}

app="$here/../build/tidalfast"
mock="$here/../build/measure/mock_tidal"
mock_flags=
out=
limit=120
while getopts a:m:f:o:t:h opt; do
	case $opt in
	a) app=$OPTARG ;;
	m) mock=$OPTARG ;;
	f) mock_flags=$OPTARG ;;
	o) out=$OPTARG ;;
	t) limit=$OPTARG ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
case $limit in '' | *[!0-9]*) echo "smoke: -t takes whole seconds" >&2 && exit 2 ;; esac
scenarios=${*:-fake mock}
for s in $scenarios; do
	case $s in fake | mock) ;; *) usage ;; esac
done

[ -x "$app" ] || {
	echo "smoke: $app isn't built; run ./build.py" >&2
	exit 2
}
case $app in /*) ;; *) app="$PWD/$app" ;; esac
case " $scenarios " in *" mock "*)
	[ -x "$mock" ] || {
		echo "smoke: $mock isn't built; run ./build.py measure" >&2
		exit 2
	}
	;;
esac

keep=1
if [ -z "$out" ]; then
	out=$(mktemp -d "${TMPDIR:-/tmp}/tidalfast-smoke.XXXXXX") || exit 2
	keep=0
fi
mkdir -p "$out" || exit 2
out=$(cd "$out" && pwd) || exit 2

mock_pid=
# shellcheck disable=SC2317 # it runs from the trap
cleanup() {
	if [ -n "$mock_pid" ]; then
		kill "$mock_pid" 2> /dev/null
		wait "$mock_pid" 2> /dev/null
		mock_pid=
	fi
	rm -rf "$out/mock-audio"
	[ "$keep" -eq 0 ] && rm -rf "$out"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# script turns steps, one a line, into TIDALFAST_SHELL_TEST, half a second
# apart, with an empty line for another half second. The waits make the
# timing loose: a step after a wait-ax runs half a second after the node
# showed. A wait's node must be new to the step before it, since the tree
# stays the last frame's until the app draws again.
script() {
	echo "$1" | awk '{ t += 0.5 } NF { printf "%s%g:%s", (n++ ? ";" : ""), t, $0 }'
}

failed=
log=

fail() {
	failed=1
	echo "smoke: $name: FAIL: $*" >&2
}

# check_waits fails for the first wait-ax whose node never showed, or
# that the run never got to.
check_waits() {
	gave_up=$(sed -n 's/^shell: test: gave up waiting for \(.*\) after [0-9]* s.*$/\1/p' "$log" | head -n 1)
	if [ -n "$gave_up" ]; then
		fail "$gave_up never showed"
		return
	fi
	echo "$steps" | sed -n 's/^wait-ax=//p' | while IFS= read -r label; do
		if ! grep -qF "shell: test: $label showed after" "$log"; then
			echo "$label"
			break
		fi
	done > "$out/$name.missing"
	if [ -s "$out/$name.missing" ]; then
		fail "the run ended before $(cat "$out/$name.missing") showed"
	fi
	rm -f "$out/$name.missing"
}

# expect_after fails unless what the step that ran command and the step
# after it printed has a line with text. It and expect_log are left out
# after a failure, which would fail them too.
expect_after() {
	[ -n "$failed" ] && return
	if ! awk -v step=":$1" -v want="$2" '
		/^shell: test step / {
			if (on) on = ++steps < 2
			else if (substr($0, length($0) - length(step) + 1) == step) { on = 1; steps = 0 }
			next
		}
		on && index($0, want) { found = 1 }
		END { exit !found }' "$log"; then
		fail "after $1, no line with: $2"
	fi
}

expect_log() {
	[ -n "$failed" ] && return
	grep -qE "$1" "$log" || fail "no line in the log matches: $1"
}

# check_log fails on errors, crashes and anything AGENTS.md says the log
# must never hold.
check_log() {
	bad=$(grep -nE '^\[(ERROR|FATAL)|[Pp]anic|runtime assertion|unsatisfied ensure|not yet implemented|is out of range|Invalid (slice|dynamic array) indices|(bounds|type assertion) trap|[A-Za-z]+Sanitizer|runtime error:|Assertion .*failed' "$log" | head -n 5)
	[ -z "$bad" ] || fail "the log has an error or a crash:
$bad"
	secret=$(grep -niE 'access_token|refresh_token|client_secret|authorization:|bearer [^ ]|https?://[^ ]*\?' "$log" | head -n 5)
	[ -z "$secret" ] || fail "the log has a token, an Authorization header or a URL with a query:
$secret"
	grep -q '^shell: ax: nothing to press called' "$log" &&
		fail "$(grep -m 1 '^shell: ax: nothing to press called' "$log" | sed 's/^shell: ax: //')"
}

# run runs the app once with the steps and the environment it's given,
# then checks the log.
run() {
	log="$out/$name.log"
	echo "smoke: $name: running"
	started=$(date +%s)
	env TIDALFAST_AUDIO_NULL=1 TIDALFAST_STATUS_BAR=1 TIDALFAST_SHELL_TEST="$(script "$steps")" "$@" \
		"$here/headless.sh" -t "$limit" "$here/smoke.sh" --inside "$app" "$log" > "$out/$name.session.log" 2>&1
	code=$?
	took=$(($(date +%s) - started))
	if [ "$code" -eq 124 ]; then
		fail "the app ran past the time limit of $limit s"
	elif [ "$code" -ne 0 ]; then
		fail "the app exited with $code"
	fi
	if [ ! -s "$log" ]; then
		fail "the app wrote no log; the session's:"
		tail -n 20 "$out/$name.session.log" >&2
		return
	fi
	grep -q '^shell: test step [0-9.]*:quit$' "$log" || fail "the run never got to quit"
	check_waits
	check_log
}

# result prints the end of the log after a failure.
result() {
	if [ -n "$failed" ]; then
		keep=1
		echo "smoke: $name: the last 60 lines of $log:" >&2
		tail -n 60 "$log" >&2
		return 1
	fi
	echo "smoke: $name: ok in $took s"
}

# The fake data: Liked Songs' first two rows are Blue in Green by Miles
# Davis, from Kind of Blue, and שיר לשלום by Queen.
fake() {
	name=fake failed=
	steps="size=1100,700
wait-ax=Play Liked Songs
ax-press=Blue in Green
wait-ax=Playing Blue in Green by Miles Davis
ax-press=Pause
wait-ax=Paused Blue in Green
ax-press=Next
wait-ax=Playing שיר לשלום
key=ctrl+f
commit=Kind
wait-ax=Results for
ax-press=Albums
wait-ax=Kind of Blue, Album
ax-press=Artists
wait-ax=Miles Davis, Artist
ax-press=Songs
wait-ax=Blue in Green, Miles Davis
ax-press=Blue in Green
wait-ax=More options for Blue in Green
ax-press=More options for Blue in Green
wait-ax=Go to album
ax-press=Go to album
wait-ax=Play Kind of Blue
ax-press=More options for Kind of Blue
wait-ax=Go to artist
ax-press=Go to artist
wait-ax=View all top tracks
ax-press=Back
wait-ax=Play Kind of Blue
ax-press=Back
wait-ax=Results for
ax-press=Discover Weekly
wait-ax=Play Discover Weekly
ax-press=Fake data
wait-ax=Settings
ax-press=Settings
wait-ax=Appearance
ax-press=Back
wait-ax=Play Discover Weekly
size=820,700



ax-dump
size=1600,900



ax-dump
quit"
	run TIDALFAST_FAKE=1
	expect_log '^\[INFO \].* search: "Kind": [1-9][0-9]* songs, [1-9][0-9]* albums, [1-9][0-9]* artists'
	expect_after size=820,700 'shell: ax:   button "Close" {782, '
	expect_after size=1600,900 'shell: ax:   button "Close" {1562, '
	result
}

# The mock server: a PKCE login, the sidebar's playlists and the liked
# songs from it, playback, an album, Home and a search.
mock_scenario() {
	name=mock failed=
	mkdir -p "$out/mock-audio" || return 2
	# shellcheck disable=SC2086 # the flags split at spaces
	"$mock" -port=0 -audio-dir="$out/mock-audio" $mock_flags > "$out/mock-server.log" 2>&1 &
	mock_pid=$!
	port=
	tries=0
	while [ -z "$port" ]; do
		port=$(sed -n 's|^mock: listening on http://127\.0\.0\.1:\([0-9]*\)$|\1|p' "$out/mock-server.log")
		[ -n "$port" ] && break
		if ! kill -0 "$mock_pid" 2> /dev/null || [ "$tries" -ge 600 ]; then
			echo "smoke: mock: the mock server didn't start; its log:" >&2
			cat "$out/mock-server.log" >&2
			return 2
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
	api="http://127.0.0.1:$port"
	steps="size=1100,700
wait-ax=Mock User
wait-ax=Road Trip,
wait-ax=Overture (Live), The Mock Ensemble
ax-press=Overture (Live)
wait-ax=Playing Overture (Live)
ax-press=Live at the Mock
wait-ax=Play Live at the Mock
ax-press=Road Trip
wait-ax=Play Road Trip
ax-press=Home
wait-ax=Recommended albums
key=ctrl+f
commit=Jazz
wait-ax=Results for
ax-dump
quit"
	run TIDALFAST_API="$api" TIDALFAST_LOG_HTTP=1 \
		TIDALFAST_KEYCHAIN="tidalfast-smoke-$$-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')" \
		TIDALFAST_PKCE_REDIRECT="$api/android/login/auth?code=mock-pkce-code-1"
	expect_log '^\[INFO \].* search: "Jazz": [1-9][0-9]* songs'
	kill "$mock_pid" 2> /dev/null
	wait "$mock_pid" 2> /dev/null
	mock_pid=
	result
}

status=0
for s in $scenarios; do
	case $s in
	fake) fake || status=1 ;;
	mock)
		mock_scenario
		code=$?
		[ "$code" -gt "$status" ] && status=$code
		;;
	esac
done
[ "$status" -ne 0 ] && echo "smoke: the logs are in $out" >&2
exit "$status"
