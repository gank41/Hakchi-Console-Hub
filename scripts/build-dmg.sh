#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# Private/local packaging only. Public builds must use build-public-dmg.sh.
printf 'Local DMG builder: public releases require the build-public-dmg.sh check.\n' >&2
app="${1:?Pass the signed app bundle printed by build-app.sh}"
[[ -d "$app/Contents" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.swifthakchi.app ]]
codesign --verify --deep --strict "$app"
product="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
output="${HAKCHI_DMG_OUTPUT:-$(cd .. && pwd)/Distributions}"
mkdir -p "$output"
image="$output/$product-$version-build$build.dmg"
[[ ! -e "$image" ]] || { printf 'Refusing to overwrite %s\n' "$image" >&2; exit 1; }
stage="$(mktemp -d "$output/.dmg-stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/Read Me.txt" <<TEXT
$product $version (build $build)

Drag $product into Applications to install this development preview.
No game ROMs are included. Your existing console games and saves stay on the console until you review a change in the app.

Use Add Game Files to copy your files into the Mac library. Settings > Storage shows the Games and Backups folders.

Hardware testing so far: NES library sync on an already modified NES, and native US SNES setup and library sync. First-time setup on a stock NES and other console models still need independent hardware testing.

This preview is not signed with a Developer ID or notarized by Apple. macOS may warn you before opening it. Check the project page for current console support and instructions.
TEXT
python="${DMGBUILD_PYTHON:-python3}"
if ! "$python" -c 'import importlib.metadata, sys; import dmgbuild; sys.exit(importlib.metadata.version("dmgbuild") != "1.6.7")' >/dev/null 2>&1; then
    printf 'Install dmgbuild 1.6.7 for Python 3.10 or later before building the installer.\n' >&2
    exit 1
fi
"$python" -m dmgbuild -s scripts/dmg-layout.py -D "app=$app" -D "readme=$stage/Read Me.txt" "$product" "$image"
hdiutil verify "$image"
printf '\nDMG_PATH=%s\n' "$image"
