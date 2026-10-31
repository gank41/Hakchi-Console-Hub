#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 2 ;; esac
# The helper has its own build cache and never launches during packaging.
nes_assistant_log="$(mktemp "${TMPDIR:-/tmp}/nes-assistant-build.XXXXXX")"
if ! scripts/build-recovery-assistant.sh > "$nes_assistant_log" 2>&1; then cat "$nes_assistant_log"; exit 1; fi
cat "$nes_assistant_log"
nes_assistant_app="$(sed -n 's/^RECOVERY_ASSISTANT_PATH=//p' "$nes_assistant_log" | tail -1)"
[[ -d "$nes_assistant_app" ]]
swift build --configuration "$configuration"
bin_path="$(swift build --configuration "$configuration" --show-bin-path)"
output="$(pwd)/Builds/$configuration"
mkdir -p "$output"
package_dir="$(mktemp -d "$output/preview.XXXXXX")"
app="$package_dir/Hakchi Console Hub.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/SwiftHakchi" "$app/Contents/MacOS/SwiftHakchi"
cp Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Helpers"
ditto "$nes_assistant_app" "$app/Contents/Helpers/NES Recovery Assistant.app"
codesign --verify --strict "$app/Contents/Helpers/NES Recovery Assistant.app"
cp SwiftHakchi/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for bundle in "$bin_path"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
# Explicit private builds can carry a reviewed offline snapshot. Source data stays
# outside the repository; ordinary public builds do not redistribute downloads.
if [[ -n "${SWIFTHAKCHI_PERSONAL_CATALOGS:-}" ]]; then
    python3 scripts/package-personal-game-genie-catalogs.py "$SWIFTHAKCHI_PERSONAL_CATALOGS" "$app/Contents/Resources/GameGenieCatalogs"
    /usr/libexec/PlistBuddy -c 'Add :SwiftHakchiPersonalCatalogs bool true' "$app/Contents/Info.plist"
fi
[[ -d "$app/Contents/Resources/SwiftHakchi_SwiftHakchi.bundle" ]]
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
latest="$(pwd)/Builds/Latest.app"
if [[ ! -e "$latest" || -L "$latest" ]]; then ln -sfn "$app" "$latest"; fi
for launcher in "$(pwd)/Hakchi Console Hub.app"; do
    if [[ ! -e "$launcher" || -L "$launcher" ]]; then ln -sfn "$app" "$launcher"; fi
done
printf '\nAPP_BUNDLE_PATH=%s\n' "$app"
