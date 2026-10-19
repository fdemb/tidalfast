#!/bin/sh
# tools/icons.sh <dir>  cuts Phosphor's fonts down to the icons in ICONS and
# writes them to assets/fonts. <dir> is the unpacked @phosphor-icons/web
# package (npm pack @phosphor-icons/web). Needs fonttools (pyftsubset).
# Each line is a weight, a name and its codepoint, which the ICON_
# constant in src/text/text.odin has too.
set -eu
cd "$(dirname "$0")/.."
src=$1/src

ICONS="
fill play e3d0
fill pause e39e
fill skip-back e5a4
fill skip-forward e5a6
bold shuffle e422
bold repeat e3f6
bold repeat-once e3f8
bold caret-left e138
bold caret-right e13a
bold heart e2a8
fill heart e2a8
bold dots-three e1fe
bold share-network e408
"

for weight in fill bold; do
	Weight=$(printf %s "$weight" | awk '{print toupper(substr($0, 1, 1)) substr($0, 2)}')
	unicodes=$(printf %s "$ICONS" | awk -v w="$weight" '$1 == w {printf "%sU+%s", sep, $3; sep = ","}')
	for line in $(printf %s "$ICONS" | awk -v w="$weight" '$1 == w {print $2 ":" $3}'); do
		name=${line%:*}
		code=${line#*:}
		grep -q "ph-$weight.ph-$name:before" "$src/$weight/style.css" || { echo "no $weight $name" >&2; exit 1; }
		grep -A1 "ph-$weight.ph-$name:before" "$src/$weight/style.css" | grep -q "\\\\$code\"" || { echo "$weight $name isn't U+$code" >&2; exit 1; }
	done
	pyftsubset "$src/$weight/Phosphor-$Weight.ttf" --unicodes="$unicodes" \
		--no-hinting --layout-features= --name-IDs='*' \
		--output-file="assets/fonts/Phosphor-$Weight.ttf"
done
cp "$1/LICENSE" assets/fonts/LICENSE-Phosphor.txt
ls -l assets/fonts/Phosphor-*.ttf
