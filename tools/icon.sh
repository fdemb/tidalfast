#!/bin/sh
# tools/icon.sh  renders packaging/icon.svg to the Linux tidalfast.png and the
# Windows tidalfast.ico that ./build.py packs. Run it after changing the SVG
# and commit what it writes. Needs rsvg-convert (brew install librsvg) and
# python3. The macOS icon is packaging/macos/AppIcon.icon, which ./build.py dist
# compiles itself.
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
rsvg-convert -w 512 -h 512 < packaging/icon.svg > packaging/linux/tidalfast.png

# An .ico of PNG entries, which Windows reads at every size since Vista.
for size in 16 24 32 48 64 256; do
	rsvg-convert -w $size -h $size < packaging/icon.svg > "$tmp/$size.png"
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
ls -l packaging/linux/tidalfast.png packaging/windows/tidalfast.ico
