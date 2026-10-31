#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_fault_dir="$(mktemp -d "${TMPDIR:-/tmp}/nes-fel-fault.XXXXXX")"
trap 'rm -rf -- "$nes_fault_dir"' EXIT
clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I USBBridge/include Tests/ProtocolFaults/fel_allocation_fault.c -o "$nes_fault_dir/test"
"$nes_fault_dir/test"
