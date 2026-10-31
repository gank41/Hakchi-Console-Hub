#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_bound_dir="$(mktemp -d "${TMPDIR:-/tmp}/nes-bound-usb.XXXXXX")"
trap 'rm -rf -- "$nes_bound_dir"' EXIT
clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I USBBridge/include \
  -framework IOKit -framework CoreFoundation Tests/ProtocolFaults/usb_bound_open_replay.c -o "$nes_bound_dir/test"
"$nes_bound_dir/test"
printf '#include "%s/vendor/libssh2/include/libssh2.h"\n' "$PWD" > "$nes_bound_dir/LibSSH2.h"
clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
  -fsanitize=address,undefined -fno-omit-frame-pointer -I "$nes_bound_dir" -I USBBridge/include \
  -I vendor/libssh2/include -Wl,-undefined,dynamic_lookup \
  Tests/ProtocolFaults/bound_stack_replay.c -o "$nes_bound_dir/stack-test"
"$nes_bound_dir/stack-test"
