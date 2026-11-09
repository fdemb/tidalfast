#!/bin/sh
# Builds tests/shell_win32/shell_check.c, the Windows shell with a stub app
# in place of the Odin one, and runs it: on Windows itself, or under Wine on
# an Xvfb with a Wine prefix of its own. It needs neither Odin nor the
# Windows SDK: mingw-w64's gcc builds it (apt install mingw-w64 wine64 xvfb).
#
#   tests/shell_win32/run.sh            build and run both runs
#   tests/shell_win32/run.sh <shell.c>  the same against another shell_win32.c, such as an older one
set -eu
cd "$(dirname "$0")/../.."

out=${TMPDIR:-/tmp}/tidalfast-shell-check
mkdir -p "$out"
shell_c=${1:-shell/shell_win32.c}
cp "$shell_c" "$out/shell_win32.c"
cp shell/common.h shell/platform.h "$out/"
sed 's|"../../shell/shell_win32.c"|"shell_win32.c"|' tests/shell_win32/shell_check.c > "$out/shell_check.c"

cc=${CC:-x86_64-w64-mingw32-gcc}
# Older mingw-w64 headers lack the dark title bar's attribute.
"$cc" -std=c11 -O1 -g -Wall -Wno-unused-parameter -DDWMWA_USE_IMMERSIVE_DARK_MODE=20 -I"$out" \
	"$out/shell_check.c" shell/common.c -o "$out/shell_check.exe" \
	-luser32 -lgdi32 -limm32 -ldwmapi -lshell32 -lole32

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
	"$out/shell_check.exe"
	"$out/shell_check.exe" endsession
	exit
	;;
esac

export WINEPREFIX="$out/wineprefix" WINEDEBUG=-all
[ -d "$WINEPREFIX" ] || wine wineboot -u >/dev/null 2>&1
display=:$((90 + $$ % 9))
Xvfb "$display" -screen 0 1600x1000x24 >/dev/null 2>&1 &
xvfb=$!
trap 'kill $xvfb 2>/dev/null' EXIT
sleep 1
failed=0
DISPLAY=$display wine "$out/shell_check.exe" || failed=1
DISPLAY=$display wine "$out/shell_check.exe" endsession || failed=1
exit $failed
