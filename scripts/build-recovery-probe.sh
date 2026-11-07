#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_probe_root="$(cd .. && pwd)/Builds/Diagnostics"
mkdir -p "$nes_probe_root/build"
# Reuse already-resolved local dependency sources; do not fetch/update for this tool.
if [[ ! -f "$nes_probe_root/build/workspace-state.json" ]]; then
    [[ -f .build/workspace-state.json && -d .build/checkouts && -d .build/repositories ]]
    ditto .build/checkouts "$nes_probe_root/build/checkouts"
    ditto .build/repositories "$nes_probe_root/build/repositories"
    cp .build/workspace-state.json "$nes_probe_root/build/workspace-state.json"
fi
swift build --configuration release --scratch-path "$nes_probe_root/build" --disable-automatic-resolution --skip-update -Xswiftc -DRECOVERY_DIAGNOSTIC
nes_probe_bin="$(swift build --configuration release --scratch-path "$nes_probe_root/build" --disable-automatic-resolution --skip-update -Xswiftc -DRECOVERY_DIAGNOSTIC --show-bin-path)"
nes_probe_package="$(mktemp -d "$nes_probe_root/probe.XXXXXX")"
cp "$nes_probe_bin/SwiftHakchi" "$nes_probe_package/SwiftHakchiRecoveryProbe"
for bundle in "$nes_probe_bin"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$nes_probe_package/$(basename "$bundle")"
done
codesign --force --sign - --timestamp=none "$nes_probe_package/SwiftHakchiRecoveryProbe"
codesign --verify --strict "$nes_probe_package/SwiftHakchiRecoveryProbe"
printf '\nRECOVERY_PROBE_PATH=%s\n' "$nes_probe_package/SwiftHakchiRecoveryProbe"
