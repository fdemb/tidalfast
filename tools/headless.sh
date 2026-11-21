#!/bin/sh
# Runs a command under a private headless Weston on Mesa's software Vulkan
# (lavapipe), in its own D-Bus session, with a throwaway HOME, XDG_DATA_HOME,
# XDG_CONFIG_HOME, XDG_CACHE_HOME and XDG_RUNTIME_DIR, so nothing it starts
# (a keyring daemon, the app's settings and caches) touches the user's own.
# The rest of the environment, TIDALFAST_* included, passes through.
#
#   tools/headless.sh [-t seconds] [-s WxH] [-l weston.log] [command [args...]]
#
# The command defaults to build/tidalfast. Its output goes to this script's,
# and the script exits with its exit code, or 124 if it ran past -t (default
# 120 s, 0 for none). -s sets the size of Weston's output (default 1800x1200),
# which a window bigger than it doesn't fit; -l keeps Weston's log. To run
# more than the app inside the session, pass a shell:
#
#   tools/headless.sh sh -c 'build/tidalfast & sleep 5; playerctl -p tidalfast play; wait'
#
# Needs weston, dbus-run-session, GNU timeout and Mesa's lavapipe ICD
# (mesa-vulkan-drivers on Debian and Ubuntu). VK_DRIVER_FILES or
# VK_ICD_FILENAMES, when set, choose the Vulkan driver in its place.

set -u

usage() {
	echo "usage: $0 [-t seconds] [-s WxH] [-l weston.log] [command [args...]]" >&2
	exit 2
}

fail() {
	echo "headless: $*" >&2
	exit 2
}

limit=120
size=1800x1200
weston_log=
while getopts t:s:l:h opt; do
	case $opt in
	t) limit=$OPTARG ;;
	s) size=$OPTARG ;;
	l) weston_log=$OPTARG ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))

case $limit in
'' | *[!0-9.]*) fail "-t takes seconds, not '$limit'" ;;
esac
case $size in *x*) ;; *) fail "-s takes WIDTHxHEIGHT, not '$size'" ;; esac
width=${size%%x*}
height=${size#*x}
case $width in '' | *[!0-9]*) fail "-s takes WIDTHxHEIGHT, not '$size'" ;; esac
case $height in '' | *[!0-9]*) fail "-s takes WIDTHxHEIGHT, not '$size'" ;; esac

if [ $# -eq 0 ]; then
	here=$(cd "$(dirname "$0")" && pwd) || exit 2
	set -- "$here/../build/tidalfast"
	[ -x "$1" ] || fail "no command given and $1 isn't built; run ./build.py"
fi

for tool in weston dbus-run-session timeout; do
	command -v "$tool" > /dev/null 2>&1 || case $tool in
	weston) fail "weston isn't installed (apt install weston)" ;;
	dbus-run-session) fail "dbus-run-session isn't installed (apt install dbus)" ;;
	*) fail "$tool isn't installed (it's in coreutils)" ;;
	esac
done

# The Vulkan loader takes a list of ICD files. All of lavapipe's in the first
# directory that has any go in it, so an arch-suffixed one
# (lvp_icd.x86_64.json) works as well as the plain one, and the loader skips
# those built for another arch.
if [ -z "${VK_DRIVER_FILES:-}" ] && [ -z "${VK_ICD_FILENAMES:-}" ]; then
	icds=
	dirs="${XDG_CONFIG_DIRS:-/etc/xdg}:/etc:${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
	old_ifs=$IFS
	IFS=:
	for dir in $dirs; do
		for f in "$dir"/vulkan/icd.d/lvp_icd*.json; do
			[ -f "$f" ] && icds="${icds:+$icds:}$f"
		done
		[ -n "$icds" ] && break
	done
	IFS=$old_ifs
	[ -n "$icds" ] || fail "Mesa's lavapipe Vulkan driver isn't installed (apt install mesa-vulkan-drivers), or set VK_DRIVER_FILES to another ICD"
	export VK_DRIVER_FILES="$icds" VK_ICD_FILENAMES="$icds"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tidalfast-headless.XXXXXX") || fail "couldn't make a temp directory"
weston_group=
command_group=

# group_alive says whether a process group still has a live process in it.
# Zombies don't count: a container's init may never reap the orphans.
# shellcheck disable=SC2317 # it runs from the trap
group_alive() {
	for stat in /proc/[0-9]*/stat; do
		{ read -r line < "$stat"; } 2> /dev/null || continue
		# After the name: state, parent, process group.
		# shellcheck disable=SC2086
		set -- ${line##*) }
		[ "$3" = "$group" ] && [ "$1" != Z ] && return 0
	done
	return 1
}

# stop_group sends a process group TERM, gives it 5 s to go, then kills it.
# shellcheck disable=SC2317 # it runs from the trap
stop_group() {
	group=$1
	kill -TERM -"$group" 2> /dev/null
	tries=0
	while group_alive; do
		if [ "$tries" -ge 50 ]; then
			kill -KILL -"$group" 2> /dev/null
			break
		fi
		sleep 0.1
		tries=$((tries + 1))
	done
	wait "$group" 2> /dev/null
}

# shellcheck disable=SC2317 # it runs from the trap
cleanup() {
	[ -n "$command_group" ] && stop_group "$command_group"
	[ -n "$weston_group" ] && stop_group "$weston_group"
	rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -m 700 "$tmp/run" "$tmp/data" "$tmp/config" "$tmp/cache" || exit 2
export HOME="$tmp" XDG_DATA_HOME="$tmp/data" XDG_CONFIG_HOME="$tmp/config" \
	XDG_CACHE_HOME="$tmp/cache" XDG_RUNTIME_DIR="$tmp/run"
socket="tidalfast-$$"
unset WAYLAND_SOCKET DISPLAY DBUS_SESSION_BUS_ADDRESS

# Weston and the command each run under timeout, which puts them in a process
# group of their own (with no time limit for Weston), so everything they start
# is stopped with them. They run in the background so that a signal to this
# script runs its trap at once rather than after the command ends.
[ -n "$weston_log" ] || weston_log="$tmp/weston.log"
# The idle time of 0 keeps the output from blanking, which would stop the
# frame callbacks in a long run.
timeout 0 weston --backend=headless --no-config --idle-time=0 --socket="$socket" \
	--width="$width" --height="$height" > "$weston_log" 2>&1 &
weston_group=$!

tries=0
while [ ! -S "$XDG_RUNTIME_DIR/$socket" ]; do
	if ! kill -0 "$weston_group" 2> /dev/null || [ "$tries" -ge 100 ]; then
		echo "headless: weston didn't start; its log:" >&2
		cat "$weston_log" >&2
		exit 2
	fi
	sleep 0.1
	tries=$((tries + 1))
done
export WAYLAND_DISPLAY="$socket"

timeout -k 5 "$limit" dbus-run-session -- "$@" &
command_group=$!
wait "$command_group"
code=$?
[ "$code" -eq 124 ] && echo "headless: the command ran past the time limit of $limit s" >&2
exit "$code"
