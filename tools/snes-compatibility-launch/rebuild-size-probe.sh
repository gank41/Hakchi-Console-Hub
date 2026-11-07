#!/bin/sh
# Rebuild-check the bundled ARM save-size probe without modifying the package.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
resource="$repo/SwiftHakchi/Resources/SNESCompatibilityProbe"
archive="$repo/SwiftHakchi/Resources/SNESCompatibilityCore/source.tar.gz"
zig=${ZIG:-zig}
[ "$("$zig" version)" = 0.17.0 ] || { echo 'Zig 0.17.0 is required for this byte-for-byte check.' >&2; exit 1; }
[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" = 7d2d2a21c2c00e6c5a83c8b51c18fccb6a9b3764584aa5ceb4b231e3a7c0ab6c ] || { echo 'Unexpected core source archive.' >&2; exit 1; }
[ "$(shasum -a 256 "$resource/core-size-probe.c" | cut -d ' ' -f 1)" = 7844d7971c7da6a28998497916e9eaee16575596e8a5ab018475e06ecbdd9ebd ] || { echo 'Unexpected probe source.' >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hc-size-probe.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
header=snes9x2010-fe690dd321fa5a46b5234a2bde089d2518c62b0e/libretro/libretro-common/include/libretro.h
tar -xzf "$archive" -C "$tmp" "$header"
"$zig" cc -target arm-linux-gnueabihf.2.23 -O2 -s -Wall -Wextra -Werror -Wno-misleading-indentation -ffile-prefix-map="$resource"=/source -I "$(dirname "$tmp/$header")" "$resource/core-size-probe.c" -ldl -o "$tmp/size-probe"
cmp "$tmp/size-probe" "$resource/size-probe"
echo 'Bundled ARM save-size probe rebuilt byte-for-byte.'
