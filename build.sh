#!/bin/sh
# ./build.sh              debug build of the app, build/tidalfast
# ./build.sh release      optimized build
# ./build.sh measure      what tools/measure runs: an optimized app in build/measure/app that
#                         also reads TIDALFAST_API, the mock server and the measure tool
# ./build.sh libs         only the C libraries in third_party, into build/
# ./build.sh dist         release package in build/dist: TIDALfast.app and a .dmg on macOS,
#                         an AppImage on Linux (needs linuxdeploy, or LINUXDEPLOY=path).
#                         TIDALFAST_VERSION=1.2.3 sets the version, else git describe
#
# TIDALFAST_SIGN_IDENTITY=name signs the macOS app and the dist bundle with
# that code signing identity (see `security find-identity -v -p codesigning`)
# instead of ad hoc. The Keychain then knows the app by its identifier and
# certificate rather than the hash of one build, so a rebuild doesn't ask
# again for the saved login.
set -eu
cd "$(dirname "$0")"

mode=debug
target=all
for arg in "$@"; do
	case "$arg" in
	release) mode=release ;;
	measure) target=measure ;;
	dist) target=dist mode=release ;;
	libs) target=libs ;;
	*) echo "usage: $0 [release] | $0 measure | $0 dist | $0 libs" >&2; exit 1 ;;
	esac
done

if [ "$mode" = release ]; then
	odin_flags="-o:speed"
	clang_flags="-O2"
else
	odin_flags="-debug"
	clang_flags="-g -O0"
fi

sign_identity=${TIDALFAST_SIGN_IDENTITY:-}
bundle_id=com.tidalfast.app

# The commit goes into the app for the launch log (launch_log.odin), in
# full: a short hash of only digits would read as a number.
commit=$(git rev-parse HEAD 2>/dev/null || true)
if [ -n "$commit" ] && ! git diff --quiet HEAD 2>/dev/null; then
	commit="$commit-dirty"
fi
app_flags="-define:TIDALFAST_COMMIT=${commit:-unknown}"

# A tag v1.2.3 gives 1.2.3. Info.plist wants numbers, so anything else is 0.0.0.
version=${TIDALFAST_VERSION:-$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)}
version=${version#v}
[ -n "$version" ] || version=0.0.0

mkdir -p build build/measure

# The oldest macOS the app runs on. Odin and clang otherwise target the
# build machine's version, and the app won't start on anything older.
macos_min=14.0
if [ "$(uname -s)" = Darwin ]; then
	lib_flags="-O2 -fPIC -mmacosx-version-min=$macos_min"
else
	lib_flags="-O2 -fPIC"
fi

# The C libraries live in third_party next to their Odin bindings, which
# link build/<name>/<lib>.a. Each is rebuilt when its source is newer or the
# flags change. kb_text_shape.c adds one export, tidalfast_bidi_class.
c_lib() { # name, library
	dir=third_party/$1
	out=build/$1/$2.a
	if [ ! -f "$out" ] || [ "$dir/$2.h" -nt "$out" ] || [ "$dir/$2.c" -nt "$out" ] || [ "$(cat "build/$1/flags" 2>/dev/null)" != "$lib_flags" ]; then
		mkdir -p "build/$1"
		echo "$lib_flags" > "build/$1/flags"
		cc $lib_flags -c "$dir/$2.c" -o "build/$1/$2.o"
		rm -f "$out"
		ar -rcs "$out" "build/$1/$2.o"
		rm "build/$1/$2.o"
	fi
}
c_lib kbts kb_text_shape
c_lib miniaudio miniaudio
c_lib dr_flac dr_flac
[ "$target" = libs ] && exit 0

# Linux: a Wayland shell in C and a Vulkan renderer. The protocol glue comes
# from wayland-scanner and the shaders from glslangValidator; the app #loads
# the SPIR-V, so shaders are compiled before it.
if [ "$(uname -s)" = Linux ]; then
	protocols=$(pkg-config --variable=pkgdatadir wayland-protocols)
	mkdir -p build/wayland build/shaders
	for xml in stable/xdg-shell/xdg-shell.xml stable/viewporter/viewporter.xml \
		staging/fractional-scale/fractional-scale-v1.xml \
		unstable/xdg-decoration/xdg-decoration-unstable-v1.xml \
		unstable/text-input/text-input-unstable-v3.xml \
		unstable/pointer-gestures/pointer-gestures-unstable-v1.xml; do
		name=$(basename "$xml" .xml)
		if [ ! -f "build/wayland/$name-protocol.c" ]; then
			wayland-scanner client-header "$protocols/$xml" "build/wayland/$name-client-protocol.h"
			wayland-scanner private-code "$protocols/$xml" "build/wayland/$name-protocol.c"
		fi
	done
	for shader in src/render/shaders/*.vert src/render/shaders/*.frag; do
		spv="build/shaders/$(basename "$shader").spv"
		if [ ! -f "$spv" ] || [ "$shader" -nt "$spv" ]; then
			glslangValidator -V --quiet "$shader" -o "$spv"
		fi
	done

	# Odin links the executable: src/app has main, which calls the shell's
	# shell_main. The shell and the protocol glue go in as objects.
	shell_libs="$(pkg-config --libs wayland-client wayland-cursor xkbcommon) -lm"
	shell_objects() { # dir, extra cc flags
		dir=$1
		shift
		rm -rf "$dir"
		mkdir -p "$dir"
		for c in shell/shell_wayland.c shell/scroll.c build/wayland/*-protocol.c; do
			cc -std=gnu11 -fPIC -c "$c" -o "$dir/$(basename "$c" .c).o" \
				-Ishell -Ibuild/wayland -Wall -Wno-unused-parameter "$@" \
				$(pkg-config --cflags wayland-client wayland-cursor xkbcommon)
		done
	}
	app_build() { # out, shell object dir, odin flags
		out=$1
		objects=$2
		shift 2
		odin build src/app -out:"$out" -vet -strict-style "$@" $app_flags \
			-extra-linker-flags:"$(echo "$objects"/*.o) $shell_libs"
	}

	if [ "$target" = dist ]; then
		# An AppDir with the app in usr/bin. linuxdeploy copies the libraries
		# it links into usr/lib and packs the AppImage. It leaves out glibc,
		# fontconfig and FreeType by itself. Wayland, xkbcommon and the Vulkan
		# loader must come from the system too, to match its compositor,
		# keymaps and GPU drivers.
		appdir=build/dist/AppDir
		rm -rf build/dist
		mkdir -p "$appdir/usr/bin"
		shell_objects build/dist/shell $clang_flags
		app_build "$appdir/usr/bin/tidalfast" build/dist/shell $odin_flags
		rm -rf build/dist/shell
		OUTPUT="build/dist/TIDALfast-$version-$(uname -m).AppImage" LINUXDEPLOY_OUTPUT_VERSION="$version" \
			"${LINUXDEPLOY:-linuxdeploy}" --appdir "$appdir" --executable "$appdir/usr/bin/tidalfast" \
			--exclude-library 'libwayland-*' --exclude-library 'libxkbcommon.so*' --exclude-library 'libvulkan.so*' \
			--desktop-file packaging/linux/tidalfast.desktop --icon-file packaging/linux/tidalfast.png \
			--output appimage
		exit 0
	fi

	if [ "$target" = measure ]; then
		mkdir -p build/measure/app
		shell_objects build/measure/shell -O2
		app_build build/measure/app/tidalfast build/measure/shell -o:speed -define:TIDALFAST_MOCK_API=true
		odin build tests/mock_tidal -out:build/measure/mock_tidal -o:speed
		odin build tools/measure -out:build/measure/measure -vet -strict-style
		exit 0
	fi

	shell_objects build/shell $clang_flags
	app_build build/tidalfast.tmp build/shell $odin_flags
	mv -f build/tidalfast.tmp build/tidalfast
	odin build tools/measure -out:build/measure/measure -vet -strict-style
	exit 0
fi

# Odin links the executable: src/app has main, which calls the shell's
# shell_main. The shell goes in as an object, with the frameworks it uses.
shell_object() { # out, extra clang flags
	out=$1
	shift
	clang -c shell/shell.m -o "$out" -fobjc-arc -mmacosx-version-min=$macos_min -Wall -Wno-unused-parameter "$@"
}
app_build() { # out, shell object, odin flags
	out=$1
	object=$2
	shift 2
	odin build src/app -out:"$out" -vet -strict-style -minimum-os-version:$macos_min "$@" $app_flags \
		-extra-linker-flags:"$object -framework Cocoa -framework Metal -framework QuartzCore -framework MediaPlayer"
}

if [ "$target" = dist ]; then
	# TIDALfast.app holds the app in Contents/MacOS and is signed ad hoc: an
	# Apple silicon Mac runs nothing unsigned. The .dmg has the app and a link
	# to /Applications to drag it to.
	bundle=build/dist/TIDALfast.app
	rm -rf build/dist
	mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" build/dist/dmg
	shell_object build/dist/shell.o $clang_flags
	app_build "$bundle/Contents/MacOS/tidalfast" build/dist/shell.o $odin_flags
	rm -rf "$bundle/Contents/MacOS/tidalfast.dSYM" build/dist/shell.o
	sed -e "s/@VERSION@/$version/g" -e "s/@MACOS_MIN@/$macos_min/g" packaging/macos/Info.plist > "$bundle/Contents/Info.plist"
	cp packaging/macos/AppIcon.icns "$bundle/Contents/Resources/"
	codesign --force --sign "${sign_identity:--}" "$bundle"
	cp -R "$bundle" build/dist/dmg/
	ln -s /Applications build/dist/dmg/Applications
	hdiutil create -quiet -volname TIDALfast -srcfolder build/dist/dmg -format ULFO \
		"build/dist/TIDALfast-$version-macos-$(uname -m).dmg"
	rm -rf build/dist/dmg
	exit 0
fi

if [ "$target" = measure ]; then
	mkdir -p build/measure/app
	shell_object build/measure/shell.o -O2
	app_build build/measure/app/tidalfast build/measure/shell.o -o:speed -define:TIDALFAST_MOCK_API=true
	odin build tests/mock_tidal -out:build/measure/mock_tidal -o:speed
	odin build tools/measure -out:build/measure/measure -vet -strict-style
	exit 0
fi

# Link to a temp name, sign, and rename, so a running app keeps the binary it
# mapped. Without TIDALFAST_SIGN_IDENTITY each build has a new ad hoc
# signature, which the login Keychain treats as a different app: it asks
# again for access to the saved TIDAL login.
shell_object build/shell.o $clang_flags
app_build build/tidalfast.tmp build/shell.o $odin_flags
rm -rf build/tidalfast.dSYM
if [ -d build/tidalfast.tmp.dSYM ]; then
	mv build/tidalfast.tmp.dSYM build/tidalfast.dSYM
fi
if [ -n "$sign_identity" ]; then
	codesign --force --sign "$sign_identity" --identifier "$bundle_id" build/tidalfast.tmp
fi
mv -f build/tidalfast.tmp build/tidalfast
odin build tools/measure -out:build/measure/measure -vet -strict-style
