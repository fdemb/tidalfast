#!/bin/sh
# tools/noto.sh <dir>  copies Noto Sans, the Linux build's text font, into
# assets/fonts. <dir> is the unpacked NotoSans release zip from
# github.com/notofonts/latin-greek-cyrillic (NotoSans-v2.015). It takes the
# unhinted variable font with only the wght axis: Regular to Bold as named
# instances, Regular the default.
set -eu
cd "$(dirname "$0")/.."
cp "$1/NotoSans/unhinted/slim-variable-ttf/NotoSans[wght].ttf" assets/fonts/NotoSans-Variable.ttf
cp "$1/OFL.txt" assets/fonts/LICENSE-NotoSans.txt
ls -l assets/fonts/NotoSans-Variable.ttf
