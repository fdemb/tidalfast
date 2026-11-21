#!/bin/sh
# Checks that an idle window uses no CPU (AGENTS.md, "Idle CPU"). Runs the app
# with fake data under tools/headless.sh, gives it time to settle, then reads
# its CPU time, all threads, from /proc/<pid>/stat over a window of seconds,
# and fails if it moved by more than a few clock ticks.
#
#   tools/idle_check.sh [-a app] [-w seconds] [-m ticks] [-l app.log]
#
# -a is the app (default build/tidalfast), -w the window (default 10 s) and -m
# the most ticks of CPU time allowed in it (default 5; a tick is 1/CLK_TCK s,
# 10 ms on Linux). An idle window measures 0, on a loaded machine too, and
# one that draws every frame on software Vulkan 800 or more. -l keeps the
# app's log, whose end is printed on a failure. Exits 0 when idle, 1 when
# not, 2 when it couldn't measure.

set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 2

if [ "${1:-}" = --inside ]; then
	# Inside the headless session: tools/idle_check.sh --inside app window max log
	app=$2 window=$3 max=$4 log=$5

	ticks() {
		{ read -r line < "/proc/$1/stat"; } 2> /dev/null || return 1
		# After the name: state is field 3, utime 14 and stime 15.
		# shellcheck disable=SC2086
		set -- ${line##*) }
		echo $((${12} + ${13}))
	}

	TIDALFAST_FAKE=1 TIDALFAST_AUDIO_NULL=1 TIDALFAST_SHELL_TEST="1:size=1100,700" "$app" > "$log" 2>&1 &
	pid=$!
	# The fake library, the fonts, MPRIS and the first frames land in the first
	# few seconds, later on a loaded machine. It has settled after a second
	# with no CPU time, or 30 s, whichever is first: a window that never
	# settles is measured all the same, and fails.
	sleep 3
	settled=3
	before=
	while :; do
		now=$(ticks "$pid") || {
			echo "idle_check: the app exited before it settled; its log:" >&2
			cat "$log" >&2
			exit 2
		}
		if [ "$now" = "$before" ] || [ "$settled" -ge 30 ]; then break; fi
		before=$now
		sleep 1
		settled=$((settled + 1))
	done
	before=$now
	sleep "$window"
	after=$(ticks "$pid") || {
		echo "idle_check: the app exited while it was measured; its log:" >&2
		tail -n 40 "$log" >&2
		exit 2
	}
	kill -TERM "$pid"
	wait "$pid"
	used=$((after - before))
	hz=$(getconf CLK_TCK)
	ms=$((used * 1000 / hz))
	if [ "$used" -gt "$max" ]; then
		echo "idle_check: FAIL: the idle window used $used ticks ($ms ms) of CPU in $window s, more than $max, after $settled s to settle; the end of the app's log:" >&2
		tail -n 40 "$log" >&2
		exit 1
	fi
	echo "idle_check: ok: the idle window used $used ticks ($ms ms) of CPU in $window s (at most $max), after $settled s to settle"
	exit 0
fi

app="$here/../build/tidalfast"
window=10
max=5
log=
while getopts a:w:m:l:h opt; do
	case $opt in
	a) app=$OPTARG ;;
	w) window=$OPTARG ;;
	m) max=$OPTARG ;;
	l) log=$OPTARG ;;
	*)
		echo "usage: $0 [-a app] [-w seconds] [-m ticks] [-l app.log]" >&2
		exit 2
		;;
	esac
done
case $window$max in
'' | *[!0-9]*) echo "idle_check: -w and -m take whole numbers" >&2 && exit 2 ;;
esac
[ -x "$app" ] || {
	echo "idle_check: $app isn't built; run ./build.py" >&2
	exit 2
}
case $app in /*) ;; *) app="$PWD/$app" ;; esac

tmp=
if [ -z "$log" ]; then
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/tidalfast-idle.XXXXXX") || exit 2
	trap 'rm -rf "$tmp"' EXIT
	log="$tmp/app.log"
fi
case $log in /*) ;; *) log="$PWD/$log" ;; esac

"$here/headless.sh" -t $((window + 60)) "$here/idle_check.sh" --inside "$app" "$window" "$max" "$log"
