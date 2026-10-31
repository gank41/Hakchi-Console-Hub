#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_wire_dir="$(mktemp -d "${TMPDIR:-/tmp}/nes-rndis-wire.XXXXXX")"
trap 'rm -rf -- "$nes_wire_dir"' EXIT
clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I USBBridge/include Tests/ProtocolFaults/rndis_packet_replay.c -o "$nes_wire_dir/test"
"$nes_wire_dir/test"
