#!/bin/sh
# tools/winsdk_case.sh <sdk>  makes the Windows SDK that xwin splats usable
# from a case-sensitive file system. Windows doesn't care how a name is
# spelled; the SDK's headers include each other and the linkers ask for
# libraries in whatever case their authors wrote. This adds a link for
# each spelling: every file in lower case, and every name an #include in
# the headers uses. Run it once after `xwin splat` (docs/windows.md).
set -eu
sdk=${1:?usage: $0 <xwin splat folder>}
cd "$sdk"

# Every file, in lower case: kernel32.lib for Kernel32.Lib.
find . -type f | while read -r f; do
	d=$(dirname "$f")
	b=$(basename "$f")
	l=$(printf %s "$b" | tr 'A-Z' 'a-z')
	[ "$b" = "$l" ] || [ -e "$d/$l" ] || ln -s "$b" "$d/$l"
done

# Every #include'd name as it's written, next to the file it names.
names=$(mktemp)
find . -type f \( -iname '*.h' -o -iname '*.hpp' -o -iname '*.inl' \) -exec grep -hoE '#[[:space:]]*include[[:space:]]*[<"][^>"]+[>"]' {} + |
	sed -E 's/.*[<"]([^>"]+)[>"]/\1/' | tr '\\' '/' | xargs -n1 basename | sort -u > "$names"
find . -type f | while read -r f; do
	printf '%s\t%s\n' "$(basename "$f" | tr 'A-Z' 'a-z')" "$f"
done | sort > "$names.files"
while read -r name; do
	lower=$(printf %s "$name" | tr 'A-Z' 'a-z')
	grep "^$lower	" "$names.files" | cut -f2 | while read -r f; do
		d=$(dirname "$f")
		[ -e "$d/$name" ] || ln -s "$(basename "$f")" "$d/$name"
	done
done < "$names"
rm -f "$names" "$names.files"

# The names Odin's packages and the CRT ask the linker for: User32.lib,
# NtDll.lib, LIBCMT.lib and the rest, which neither of the above makes.
odin=$(command -v odin >/dev/null && odin root || true)
asked=$(mktemp)
{
	[ -n "$odin" ] && grep -rhoE '"system:[A-Za-z0-9_]+\.lib"' "$odin/core" "$odin/base" "$odin/vendor" | sed -E 's/"system:(.*)"/\1/'
	printf '%s\n' LIBCMT.lib OLDNAMES.lib LIBUCRT.lib LIBVCRUNTIME.lib
} | sort -u > "$asked"
while read -r name; do
	lower=$(printf %s "$name" | tr 'A-Z' 'a-z')
	find . -name "$lower" | while read -r f; do
		d=$(dirname "$f")
		[ -e "$d/$name" ] || ln -s "$lower" "$d/$name"
	done
done < "$asked"
rm -f "$asked"
