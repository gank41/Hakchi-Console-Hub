#!/bin/sh
# Developer build only; output is not installed or authorized for console use.
set -eu
[ "$#" -eq 2 ] || exit 2
cd "$(dirname "$0")/../.."
output=$1
zig=$2
[ -d "$output" ] && [ ! -L "$output" ] && [ "$("$zig" version)" = 0.17.0 ]
[ ! -e "$output/snes-save-profile-switch" ] && [ ! -L "$output/snes-save-profile-switch" ]
[ ! -e "$output/build.json" ] && [ ! -L "$output/build.json" ]
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a7 -O2 -static -fno-pie -fstack-protector-strong \
  -ffunction-sections -fdata-sections -g0 -s -Wl,--build-id=none -Wl,--gc-sections -Wl,-z,noexecstack -std=c11 -Wall -Wextra -Werror \
  tools/snes-save-publication/profile_switch.c -o "$output/snes-save-profile-switch"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, sys
out = Path(sys.argv[1])
binary = (out / 'snes-save-profile-switch').read_bytes()
if b'/Users/' in binary or b'/Development/NES' in binary:
    sys.exit('Helper contains a private development path.')
source = Path('tools/snes-save-publication/profile_switch.c').read_bytes()
record = {'schemaVersion': 1, 'scope': 'snes-save-profile-switch-developer-build',
          'compiler': 'zig0.17.0', 'target': 'arm-linux-musleabi/cortex_a7',
          'helperBytes': len(binary), 'helperSHA256': hashlib.sha256(binary).hexdigest(),
          'sourceSHA256': hashlib.sha256(source).hexdigest(),
          'hardwareTested': False, 'consoleWriteAuthorized': False}
(out / 'build.json').write_text(json.dumps(record, indent=2) + '\n')
PY
printf 'PROFILE_SWITCH_BUILD=%s\n' "$output"
