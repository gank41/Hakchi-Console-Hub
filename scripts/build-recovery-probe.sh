#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_probe_root="$(pwd)/Builds/Diagnostics"
mkdir -p "$nes_probe_root/build"
swift build --configuration release --scratch-path "$nes_probe_root/build" -Xswiftc -DRECOVERY_DIAGNOSTIC
nes_probe_bin="$(swift build --configuration release --scratch-path "$nes_probe_root/build" -Xswiftc -DRECOVERY_DIAGNOSTIC --show-bin-path)"
nes_probe_package="$(mktemp -d "$nes_probe_root/probe.XXXXXX")"
cp "$nes_probe_bin/SwiftHakchi" "$nes_probe_package/SwiftHakchiRecoveryProbe"
for bundle in "$nes_probe_bin"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$nes_probe_package/$(basename "$bundle")"
done
codesign --force --sign - --timestamp=none "$nes_probe_package/SwiftHakchiRecoveryProbe"
codesign --verify --strict "$nes_probe_package/SwiftHakchiRecoveryProbe"
printf '\nRECOVERY_PROBE_PATH=%s\n' "$nes_probe_package/SwiftHakchiRecoveryProbe"
