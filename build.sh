#!/bin/sh
# ./build.sh              debug build of the shell and the app dylib
# ./build.sh app          rebuild only the app dylib; a running shell reloads it
# ./build.sh release      optimized build, hot reload watcher off
# ./build.sh release app  optimized app dylib only
# ./build.sh measure      what tools/measure runs: an optimized app in build/measure/app that
#                         also reads TIDALFAST_API, the mock server and the measure tool
set -eu
cd "$(dirname "$0")"

mode=debug
target=all
for arg in "$@"; do
	case "$arg" in
	release) mode=release ;;
	app) target=app ;;
	measure) target=measure ;;
	*) echo "usage: $0 [release] [app] | $0 measure" >&2; exit 1 ;;
	esac
done

if [ "$mode" = release ]; then
	odin_flags="-o:speed"
	clang_flags="-O2 -DHOT_RELOAD=0"
else
	odin_flags="-debug"
	clang_flags="-g -O0"
fi

# The commit goes into the app for the launch log (launch_log.odin), in
# full: a short hash of only digits would read as a number.
commit=$(git rev-parse HEAD 2>/dev/null || true)
if [ -n "$commit" ] && ! git diff --quiet HEAD 2>/dev/null; then
	commit="$commit-dirty"
fi
app_flags="-define:TIDALFAST_COMMIT=${commit:-unknown}"

mkdir -p build build/measure

# kb_text_shape's C source lives in src/kbts next to its bindings, which
# link build/kbts/kb_text_shape.a. Rebuilt when the source is newer. The .c
# file adds one export, tidalfast_bidi_class.
if [ ! -f build/kbts/kb_text_shape.a ] || [ src/kbts/kb_text_shape.h -nt build/kbts/kb_text_shape.a ] || [ src/kbts/kb_text_shape.c -nt build/kbts/kb_text_shape.a ]; then
	mkdir -p build/kbts
	cc -O2 -fPIC -c src/kbts/kb_text_shape.c -o build/kbts/kb_text_shape.o
	rm -f build/kbts/kb_text_shape.a
	ar -rcs build/kbts/kb_text_shape.a build/kbts/kb_text_shape.o
	rm build/kbts/kb_text_shape.o
fi

# Linux: a Wayland shell in C and a Vulkan renderer. The protocol glue comes
# from wayland-scanner and the shaders from glslangValidator; the app #loads
# the SPIR-V, so shaders are compiled before it.
if [ "$(uname -s)" = Linux ]; then
	protocols=$(pkg-config --variable=pkgdatadir wayland-protocols)
	mkdir -p build/wayland build/shaders
	for xml in stable/xdg-shell/xdg-shell.xml stable/viewporter/viewporter.xml \
		staging/fractional-scale/fractional-scale-v1.xml \
		unstable/xdg-decoration/xdg-decoration-unstable-v1.xml \
		unstable/text-input/text-input-unstable-v3.xml; do
		name=$(basename "$xml" .xml)
		if [ ! -f "build/wayland/$name-protocol.c" ]; then
			wayland-scanner client-header "$protocols/$xml" "build/wayland/$name-client-protocol.h"
			wayland-scanner private-code "$protocols/$xml" "build/wayland/$name-protocol.c"
		fi
	done
	for stage in vert frag; do
		if [ ! -f "build/shaders/rect.$stage.spv" ] || [ "src/render/shaders/rect.$stage" -nt "build/shaders/rect.$stage.spv" ]; then
			glslangValidator -V --quiet "src/render/shaders/rect.$stage" -o "build/shaders/rect.$stage.spv"
		fi
	done

	shell_build() { # out, extra cc flags
		out=$1
		shift
		cc -std=gnu11 shell/shell_wayland.c build/wayland/*-protocol.c -o "$out" \
			-Ishell -Ibuild/wayland -Wall -Wno-unused-parameter "$@" \
			$(pkg-config --cflags --libs wayland-client wayland-cursor xkbcommon) -lm -ldl
	}

	if [ "$target" = measure ]; then
		mkdir -p build/measure/app
		odin build src/app -build-mode:dll -out:build/measure/app/app.so -vet -strict-style -o:speed -define:TIDALFAST_MOCK_API=true $app_flags
		if [ ! -f build/measure/app/tidalfast ] || [ shell/shell_wayland.c -nt build/measure/app/tidalfast ] || [ shell/platform.h -nt build/measure/app/tidalfast ]; then
			shell_build build/measure/app/tidalfast -O2 -DHOT_RELOAD=0
		fi
		odin build tests/mock_tidal -out:build/measure/mock_tidal -o:speed
		odin build tools/measure -out:build/measure/measure -vet -strict-style
		exit 0
	fi

	odin build src/app -build-mode:dll -out:build/app.tmp.so -vet -strict-style $odin_flags $app_flags
	mv -f build/app.tmp.so build/app.so
	if [ "$target" = all ] && { [ ! -f build/tidalfast ] || [ shell/shell_wayland.c -nt build/tidalfast ] || [ shell/platform.h -nt build/tidalfast ] || [ "$(cat build/shell-mode 2>/dev/null)" != "$mode" ]; }; then
		echo "$mode" > build/shell-mode
		shell_build build/tidalfast $clang_flags
	fi
	if [ "$target" = all ]; then
		odin build tools/measure -out:build/measure/measure -vet -strict-style
	fi
	exit 0
fi

if [ "$target" = measure ]; then
	mkdir -p build/measure/app
	odin build src/app -build-mode:dll -out:build/measure/app/app.dylib -vet -strict-style -o:speed -define:TIDALFAST_MOCK_API=true $app_flags
	if [ ! -f build/measure/app/tidalfast ] || [ shell/shell.m -nt build/measure/app/tidalfast ] || [ shell/platform.h -nt build/measure/app/tidalfast ]; then
		clang shell/shell.m -o build/measure/app/tidalfast -fobjc-arc -mmacosx-version-min=14.0 \
			-Wall -Wno-unused-parameter -O2 -DHOT_RELOAD=0 \
			-framework Cocoa -framework Metal -framework QuartzCore -framework CoreServices -framework MediaPlayer
	fi
	odin build tests/mock_tidal -out:build/measure/mock_tidal -o:speed
	odin build tools/measure -out:build/measure/measure -vet -strict-style
	exit 0
fi

# Build to a temp name and rename, so the shell's watcher never sees a half
# written dylib.
odin build src/app -build-mode:dll -out:build/app.tmp.dylib -vet -strict-style $odin_flags $app_flags
rm -rf build/app.dylib.dSYM
[ -d build/app.tmp.dylib.dSYM ] && mv build/app.tmp.dylib.dSYM build/app.dylib.dSYM
mv -f build/app.tmp.dylib build/app.dylib

# The shell is relinked only when its source or the build mode changes.
# clang's output differs from build to build, and each new binary has a new
# ad-hoc signature, which the login Keychain treats as a different app: it
# would ask again for access to the saved TIDAL login after every build.
if [ "$target" = all ] && { [ ! -f build/tidalfast ] || [ shell/shell.m -nt build/tidalfast ] || [ shell/platform.h -nt build/tidalfast ] || [ "$(cat build/shell-mode 2>/dev/null)" != "$mode" ]; }; then
	echo "$mode" > build/shell-mode
	clang shell/shell.m -o build/tidalfast -fobjc-arc -mmacosx-version-min=14.0 \
		-Wall -Wno-unused-parameter $clang_flags \
		-framework Cocoa -framework Metal -framework QuartzCore -framework CoreServices -framework MediaPlayer
fi

if [ "$target" = all ]; then
	odin build tools/measure -out:build/measure/measure -vet -strict-style
fi
