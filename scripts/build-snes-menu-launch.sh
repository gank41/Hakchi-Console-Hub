#!/bin/sh
set -eu
[ "$#" -eq 2 ] || { printf 'Usage: %s /existing/output-folder /path/to/zig\n' "$0" >&2; exit 2; }
cd "$(dirname "$0")/.."
output=$1
zig=$2
[ -d "$output" ] && [ ! -L "$output" ] && [ -x "$zig" ]
[ "$("$zig" version)" = 0.17.0 ]
[ ! -e "$output/snes-menu-launch" ] && [ ! -e "$output/build.json" ]
compiler_root=$(dirname "$zig")
"$zig" cc -isystem "$compiler_root/lib/libc/include/arm-linux-musl" -isystem "$compiler_root/lib/libc/include/generic-musl" -target arm-linux-musleabi -mcpu=cortex_a7 -O2 -static -nostdlib -ffreestanding -fno-builtin \
    -fomit-frame-pointer -fno-stack-protector -fno-pie -ffunction-sections -fdata-sections -s \
    -std=c11 -Wall -Wextra -Werror -Wl,-e,_start -Wl,--build-id=none -Wl,--gc-sections -Wl,-z,noexecstack \
    tools/snes-menu-launch/main.c -o "$output/snes-menu-launch"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,sys
out=Path(sys.argv[1]);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources=['tools/snes-menu-launch/main.c','scripts/build-snes-menu-launch.sh']
record={'schemaVersion':1,'scope':'fixed-snes-menu-clean-launch','compiler':'zig0.17.0','target':'arm-linux-musleabi/cortex_a7',
 'sourceSHA256':{s:sha(Path(s)) for s in sources},'helperSHA256':sha(out/'snes-menu-launch'),
 'helperBytes':(out/'snes-menu-launch').stat().st_size,'firmwareWritten':False,'hardwareTested':False}
(out/'build.json').write_text(json.dumps(record,indent=2)+'\n')
PY
