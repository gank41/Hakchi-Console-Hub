#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_assistant_root="${SWIFTHAKCHI_BUILD_ROOT:-$(cd .. && pwd)/Builds}/RecoveryAssistant"
seed_build="${SWIFTHAKCHI_SCRATCH_PATH:-.build}"
mkdir -p "$nes_assistant_root/build"
if [[ ! -f "$nes_assistant_root/build/workspace-state.json" ]]; then
    [[ -f "$seed_build/workspace-state.json" && -d "$seed_build/checkouts" && -d "$seed_build/repositories" ]]
    ditto "$seed_build/checkouts" "$nes_assistant_root/build/checkouts"
    ditto "$seed_build/repositories" "$nes_assistant_root/build/repositories"
    cp "$seed_build/workspace-state.json" "$nes_assistant_root/build/workspace-state.json"
fi
swift_flags=()
swift_flags+=(-Xswiftc -DSWIFTHAKCHI_DISTRIBUTION)
[[ -z "${SWIFTHAKCHI_SWIFT_BUILD_SYSTEM:-}" ]] || swift_flags+=(--build-system "$SWIFTHAKCHI_SWIFT_BUILD_SYSTEM")
[[ "${SWIFTHAKCHI_DISABLE_SWIFTPM_SANDBOX:-0}" != 1 ]] || swift_flags+=(--disable-sandbox)
swift build "${swift_flags[@]}" --configuration release --scratch-path "$nes_assistant_root/build" --disable-automatic-resolution --skip-update -Xswiftc -DRECOVERY_ASSISTANT
nes_assistant_bin="$(swift build "${swift_flags[@]}" --configuration release --scratch-path "$nes_assistant_root/build" --disable-automatic-resolution --skip-update -Xswiftc -DRECOVERY_ASSISTANT --show-bin-path)"
nes_assistant_package="$(mktemp -d "$nes_assistant_root/assistant.XXXXXX")"
nes_assistant_app="$nes_assistant_package/NES Recovery Assistant.app"
mkdir -p "$nes_assistant_app/Contents/MacOS" "$nes_assistant_app/Contents/Resources"
cp "$nes_assistant_bin/SwiftHakchi" "$nes_assistant_app/Contents/MacOS/SwiftHakchiRecoveryAssistant"
# Remove local source and object paths in debug symbols before signing.
strip -S "$nes_assistant_app/Contents/MacOS/SwiftHakchiRecoveryAssistant"
cp SwiftHakchi/Resources/AppIcon.icns "$nes_assistant_app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string NES Recovery Assistant' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string NES Recovery Assistant' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.swifthakchi.recovery-assistant' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.0' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string SwiftHakchiRecoveryAssistant' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSPrincipalClass string NSApplication' "$nes_assistant_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$nes_assistant_app/Contents/Info.plist"
for bundle in "$nes_assistant_bin"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$nes_assistant_app/Contents/Resources/$(basename "$bundle")"
done
plutil -lint "$nes_assistant_app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$nes_assistant_app"
codesign --verify --strict "$nes_assistant_app"
ln -sfn "$nes_assistant_app" "$nes_assistant_root/Latest.app"
printf '\nRECOVERY_ASSISTANT_PATH=%s\n' "$nes_assistant_app"
