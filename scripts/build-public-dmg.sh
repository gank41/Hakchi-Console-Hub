#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ $# -ne 2 ]]; then
    printf 'Usage: %s /path/to/app /path/to/private-identifiers.txt\n' "$0" >&2
    exit 2
fi
app="$1"
identifiers="$2"
[[ -d "$app" && ! -L "$app" ]] || { printf 'App must be an existing, non-symlink directory.\n' >&2; exit 1; }
[[ -f "$identifiers" && -r "$identifiers" ]] || { printf 'A readable private identifiers file is required.\n' >&2; exit 1; }
# The private staging directory prevents outside mutation between scan and packaging.
stage="$(mktemp -d "${TMPDIR:-/tmp}/hakchi-public-dmg.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
snapshot="$stage/Hakchi Console Hub.app"
ditto --norsrc --noextattr "$app" "$snapshot"
# Some macOS versions still preserve xattrs despite ditto's flags. Clear them
# without following symlinks, then fail closed if any remain or cannot be read.
if ! /usr/bin/xattr -crs "$snapshot" >/dev/null 2>&1; then
    printf 'Could not clear staged extended attributes.\n' >&2
    exit 1
fi
if ! /usr/bin/xattr -rs "$snapshot" > "$stage/remaining-xattrs" 2>/dev/null; then
    printf 'Could not inspect staged extended attributes.\n' >&2
    exit 1
fi
[[ ! -s "$stage/remaining-xattrs" ]] || { printf 'Staged extended attributes remain.\n' >&2; exit 1; }
python3 scripts/check-public-bundle-privacy.py "$snapshot" --literal-file "$identifiers"
scripts/build-dmg.sh "$snapshot"
