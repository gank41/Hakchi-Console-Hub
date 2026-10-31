#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
app="${1:?Pass the signed app bundle printed by build-app.sh}"
[[ -d "$app/Contents" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.swifthakchi.app ]]
codesign --verify --deep --strict "$app"
product="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
output="$(pwd)/Distributions"
mkdir -p "$output"
image="$output/$product-$version-build$build.dmg"
[[ ! -e "$image" ]] || { printf 'Refusing to overwrite %s\n' "$image" >&2; exit 1; }
stage="$(mktemp -d "$output/.dmg-stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me.txt" <<TEXT
$product $version (build $build)

Drag $product into Applications to install this development preview.
No game ROMs are included. Your existing console games and saves stay on the console until you review a change in the app.

Use Add Game Files to copy your files into the Mac library. Settings > Storage shows the Games and Backups folders.

Hardware testing so far: NES library sync on an already modified NES, and native US SNES setup and library sync. First-time setup on a stock NES and other console models still need independent hardware testing.

This local development image has not been notarized or published. It is not the public release package. Any personal offline catalog snapshot in this app remains part of this private development build.
TEXT
hdiutil create -volname "$product" -srcfolder "$stage" -format UDZO -imagekey zlib-level=9 "$image"
hdiutil verify "$image"
printf '\nDMG_PATH=%s\n' "$image"
