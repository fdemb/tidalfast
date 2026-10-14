#!/bin/sh
# ./build.sh              debug build of the shell and the app dylib
# ./build.sh app          rebuild only the app dylib; a running shell reloads it
# ./build.sh release      optimized build, hot reload watcher off
# ./build.sh release app  optimized app dylib only
set -eu
cd "$(dirname "$0")"

mode=debug
target=all
for arg in "$@"; do
	case "$arg" in
	release) mode=release ;;
	app) target=app ;;
	*) echo "usage: $0 [release] [app]" >&2; exit 1 ;;
	esac
done

if [ "$mode" = release ]; then
	odin_flags="-o:speed"
	clang_flags="-O2 -DHOT_RELOAD=0"
else
	odin_flags="-debug"
	clang_flags="-g -O0"
fi

mkdir -p build

# Build to a temp name and rename, so the shell's watcher never sees a half
# written dylib.
odin build src/app -build-mode:dll -out:build/app.tmp.dylib -vet -strict-style $odin_flags
rm -rf build/app.dylib.dSYM
[ -d build/app.tmp.dylib.dSYM ] && mv build/app.tmp.dylib.dSYM build/app.dylib.dSYM
mv -f build/app.tmp.dylib build/app.dylib

if [ "$target" = all ]; then
	clang shell/shell.m -o build/tidalfast -fobjc-arc -mmacosx-version-min=14.0 \
		-Wall -Wno-unused-parameter $clang_flags \
		-framework Cocoa -framework Metal -framework QuartzCore -framework CoreServices
fi
