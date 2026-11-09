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
swift_flags=()
[[ "$configuration" != release ]] || swift_flags+=(-Xswiftc -DSWIFTHAKCHI_DISTRIBUTION)
[[ -z "${SWIFTHAKCHI_SWIFT_BUILD_SYSTEM:-}" ]] || swift_flags+=(--build-system "$SWIFTHAKCHI_SWIFT_BUILD_SYSTEM")
[[ -z "${SWIFTHAKCHI_SCRATCH_PATH:-}" ]] || swift_flags+=(--scratch-path "$SWIFTHAKCHI_SCRATCH_PATH")
[[ "${SWIFTHAKCHI_DISABLE_SWIFTPM_SANDBOX:-0}" != 1 ]] || swift_flags+=(--disable-sandbox)
swift build "${swift_flags[@]}" --configuration "$configuration"
bin_path="$(swift build "${swift_flags[@]}" --configuration "$configuration" --show-bin-path)"
build_root="${SWIFTHAKCHI_BUILD_ROOT:-$(cd .. && pwd)/Builds}"
output="$build_root/$configuration"
mkdir -p "$output"
package_dir="$(mktemp -d "$output/preview.XXXXXX")"
app="$package_dir/Hakchi Console Hub.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/SwiftHakchi" "$app/Contents/MacOS/SwiftHakchi"
# Mach-O debug symbol tables include absolute local source and object paths.
# Strip only the packaged release copy, before it is signed; keep build products.
if [[ "$configuration" == release ]]; then strip -S "$app/Contents/MacOS/SwiftHakchi"; fi
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
latest="$build_root/Latest.app"
if [[ ! -e "$latest" || -L "$latest" ]]; then ln -sfn "$app" "$latest"; fi
for launcher in "$(cd .. && pwd)/Hakchi Console Hub.app"; do
    # An alternate build root is used for isolated builds and must not change the default launcher.
    [[ -z "${SWIFTHAKCHI_BUILD_ROOT:-}" ]] || continue
    if [[ ! -e "$launcher" || -L "$launcher" ]]; then ln -sfn "$app" "$launcher"; fi
done
printf '\nAPP_BUNDLE_PATH=%s\n' "$app"
