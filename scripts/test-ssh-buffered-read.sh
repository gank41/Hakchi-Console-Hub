#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
nes_ssh_dir="$(mktemp -d "${TMPDIR:-/tmp}/nes-ssh-replay.XXXXXX")"
trap 'rm -rf -- "$nes_ssh_dir"' EXIT
# Match SPM's generated umbrella name while including the canonical vendor header.
printf '#include "%s/vendor/libssh2/include/libssh2.h"\n' "$PWD" > "$nes_ssh_dir/LibSSH2.h"
# Uncalled session-open functions retain vendor symbol references. Dynamic lookup
# keeps this replay limited to the stubbed channel/TCP boundary it actually invokes.
clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$nes_ssh_dir" -I USBBridge/include -I vendor/libssh2/include \
  -Wl,-undefined,dynamic_lookup \
  Tests/ProtocolFaults/ssh_buffered_read_replay.c -o "$nes_ssh_dir/test"
"$nes_ssh_dir/test"
clang -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I USBBridge/include Tests/ProtocolFaults/tcp_poll_close_replay.c -o "$nes_ssh_dir/close-test"
"$nes_ssh_dir/close-test"
