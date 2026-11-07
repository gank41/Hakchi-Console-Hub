#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ $# == 1 ]] || { printf 'Usage: %s /path/to/zig\n' "$0" >&2; exit 2; }
root="$(mktemp -d "${TMPDIR:-/tmp}/snes-portable-helper-test.XXXXXXXX")"
trap 'rm -rf -- "$root"' EXIT
mkdir "$root/first" "$root/second" "$root/refuse"
scripts/build-portable-snes-helpers.sh "$root/first" "$1"
scripts/build-portable-snes-helpers.sh "$root/second" "$1"
cmp "$root/first/bounded-nand-read" "$root/second/bounded-nand-read"
cmp "$root/first/bounded-nand-write" "$root/second/bounded-nand-write"
cmp "$root/first/bounded-nand-read" SwiftHakchi/Resources/SNESPortableHelpers/bounded-nand-read
cmp "$root/first/bounded-nand-write" SwiftHakchi/Resources/SNESPortableHelpers/bounded-nand-write
printf 'keep' > "$root/refuse/bounded-nand-read"
if scripts/build-portable-snes-helpers.sh "$root/refuse" "$1" >/dev/null 2>&1; then
    printf 'Existing output was unexpectedly accepted.\n' >&2; exit 1
fi
[[ "$(cat "$root/refuse/bounded-nand-read")" == keep ]]
[[ ! -e "$root/refuse/bounded-nand-write" ]]
printf 'Portable helper builds match packaged bytes and refuse to overwrite an existing file.\n'
