#!/bin/sh
# Builds the headless Linux harness in build/linux. See "Measuring on Linux"
# in the README.
#
#   tools/linux/build.sh    the app, its shell, the mock server and the measure tool
#
# The app is the same src/app, built as a shared library. The shell
# (tools/linux/shell.c) runs it without a window, and tools/linux/stubs.c
# stands in for the macOS frameworks: Metal keeps its buffers and textures in
# plain memory, CoreText finds and draws fonts with fontconfig and FreeType,
# the Keychain is an in-memory table.
set -eu
cd "$(dirname "$0")/../.."

out=build/linux
mkdir -p "$out/app" "$out/lib" build/kbts

odin_root=$(odin root)
shadow=$out/odin-root
# A copy of the Odin root with vendor:darwin/Metal swapped for the few types
# src/render uses: the real package needs Obj-C, which only compiles for macOS.
if [ ! -d "$shadow" ] || [ tools/linux/metal/metal.odin -nt "$shadow/vendor/darwin/Metal/metal.odin" ]; then
	rm -rf "$shadow"
	mkdir -p "$shadow/vendor/darwin/Metal"
	for f in "$odin_root"/*; do
		[ "$(basename "$f")" = vendor ] || ln -s "$f" "$shadow/$(basename "$f")"
	done
	for f in "$odin_root"/vendor/*; do
		[ "$(basename "$f")" = darwin ] || ln -s "$f" "$shadow/vendor/$(basename "$f")"
	done
	for f in "$odin_root"/vendor/darwin/*; do
		[ "$(basename "$f")" = Metal ] || ln -s "$f" "$shadow/vendor/darwin/$(basename "$f")"
	done
	cp tools/linux/metal/metal.odin "$shadow/vendor/darwin/Metal/"
fi

if [ ! -f build/kbts/kb_text_shape.a ] || [ src/kbts/kb_text_shape.h -nt build/kbts/kb_text_shape.a ] || [ src/kbts/kb_text_shape.c -nt build/kbts/kb_text_shape.a ]; then
	cc -O2 -fPIC -c src/kbts/kb_text_shape.c -o build/kbts/kb_text_shape.o
	rm -f build/kbts/kb_text_shape.a
	ar -rcs build/kbts/kb_text_shape.a build/kbts/kb_text_shape.o
	rm build/kbts/kb_text_shape.o
fi

# The stubs are one shared library; the frameworks' names point at it so the
# app's foreign imports link unchanged.
cc -O2 -g -fPIC -shared -Wall -Wno-unused-parameter $(pkg-config --cflags freetype2 fontconfig) \
	tools/linux/stubs.c -o "$out/lib/libtidalfast_stubs.so" $(pkg-config --libs freetype2 fontconfig) -lm
for name in CoreFoundation.framework CoreGraphics.framework CoreText.framework Security.framework \
	CoreServices.framework CoreAudio.framework System.framework System objc; do
	ln -sf libtidalfast_stubs.so "$out/lib/lib$name.so"
done
# vendor:curl links -lcurl, and only the runtime libcurl.so.4 may be there.
if ! printf 'int main(void){return 0;}' | cc -x c - -lcurl -o /dev/null 2>/dev/null; then
	curl_so=$(ldconfig -p | awk '/libcurl\.so\.4 / {print $NF; exit}')
	[ -n "$curl_so" ] && ln -sf "$curl_so" "$out/lib/libcurl.so"
fi

ODIN_ROOT=$shadow odin build src/app -build-mode:dll -out:"$out/app/app.dylib" -vet -strict-style -o:speed \
	-define:TIDALFAST_MOCK_API=true -extra-linker-flags:"-L$PWD/$out/lib -Wl,-rpath,\$ORIGIN/../lib"
cc -O2 -g -Wall -Wno-unused-parameter tools/linux/shell.c -o "$out/app/tidalfast" \
	-L"$out/lib" -ltidalfast_stubs -Wl,-rpath,'$ORIGIN/../lib' -ldl -lpthread -lm
odin build tests/mock_tidal -out:"$out/mock_tidal" -o:speed
odin build tools/measure -out:"$out/measure" -vet -strict-style
