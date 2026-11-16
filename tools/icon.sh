#!/bin/sh
# tools/icon.sh  renders packaging/icon.svg to the macOS AppIcon.icns, the
# Linux tidalfast.png and the Windows tidalfast.ico that ./build.py packs. Run
# it on macOS after changing the SVG and commit what it writes. Needs
# rsvg-convert (brew install librsvg), iconutil and python3.
#
# The SVG follows Apple's icon grid: an 824 pt tile with a shadow on a 1024 pt
# canvas. The Linux and Windows icons drop the shadow and most of the margin,
# since those desktops don't add their own.
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
iconset=$tmp/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
	rsvg-convert -w $size -h $size < packaging/icon.svg > "$iconset/icon_${size}x${size}.png"
	rsvg-convert -w $((size * 2)) -h $((size * 2)) < packaging/icon.svg > "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o packaging/macos/AppIcon.icns

sed -e '/url(#shadow)/d' -e 's/viewBox="0 0 1024 1024"/viewBox="84 84 856 856"/' packaging/icon.svg > "$tmp/flat.svg"
rsvg-convert -w 512 -h 512 < "$tmp/flat.svg" > packaging/linux/tidalfast.png

# An .ico of PNG entries, which Windows reads at every size since Vista.
for size in 16 24 32 48 64 256; do
	rsvg-convert -w $size -h $size < "$tmp/flat.svg" > "$tmp/$size.png"
done
python3 -I - "$tmp" packaging/windows/tidalfast.ico <<'EOF'
import struct, sys
tmp, out = sys.argv[1:]
sizes = [16, 24, 32, 48, 64, 256]
pngs = [open(f"{tmp}/{s}.png", "rb").read() for s in sizes]
head = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, png in zip(sizes, pngs):
	head += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(png), offset)
	offset += len(png)
open(out, "wb").write(head + b"".join(pngs))
EOF
rm -rf "$tmp"
ls -l packaging/macos/AppIcon.icns packaging/linux/tidalfast.png packaging/windows/tidalfast.ico
