#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_assistant_root="$(pwd)/Builds/RecoveryAssistant"
mkdir -p "$nes_assistant_root/build"
swift build --configuration release --scratch-path "$nes_assistant_root/build" -Xswiftc -DRECOVERY_ASSISTANT
nes_assistant_bin="$(swift build --configuration release --scratch-path "$nes_assistant_root/build" -Xswiftc -DRECOVERY_ASSISTANT --show-bin-path)"
nes_assistant_package="$(mktemp -d "$nes_assistant_root/assistant.XXXXXX")"
nes_assistant_app="$nes_assistant_package/NES Recovery Assistant.app"
mkdir -p "$nes_assistant_app/Contents/MacOS" "$nes_assistant_app/Contents/Resources"
cp "$nes_assistant_bin/SwiftHakchi" "$nes_assistant_app/Contents/MacOS/SwiftHakchiRecoveryAssistant"
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
