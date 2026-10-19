#!/bin/sh
# tools/icon.sh  renders packaging/icon.svg to the macOS AppIcon.icns and the
# Linux tidalfast.png that ./build.sh dist packs. Run it on macOS after
# changing the SVG and commit what it writes. Needs rsvg-convert (brew install
# librsvg) and iconutil.
#
# The SVG follows Apple's icon grid: an 824 pt tile with a shadow on a 1024 pt
# canvas. The Linux icon drops the shadow and most of the margin, since
# Linux desktops don't add their own.
set -eu
cd "$(dirname "$0")/.."

iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
	rsvg-convert -w $size -h $size < packaging/icon.svg > "$iconset/icon_${size}x${size}.png"
	rsvg-convert -w $((size * 2)) -h $((size * 2)) < packaging/icon.svg > "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o packaging/macos/AppIcon.icns
rm -rf "$(dirname "$iconset")"

sed -e '/url(#blur)/d' -e 's/viewBox="0 0 1024 1024"/viewBox="84 84 856 856"/' packaging/icon.svg |
	rsvg-convert -w 512 -h 512 > packaging/linux/tidalfast.png
ls -l packaging/macos/AppIcon.icns packaging/linux/tidalfast.png
