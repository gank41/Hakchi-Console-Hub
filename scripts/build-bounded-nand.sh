#!/bin/sh
set -eu
[ "$#" -eq 2 ] || { printf 'Usage: %s /existing/output-folder /path/to/zig\n' "$0" >&2; exit 2; }
cd "$(dirname "$0")/.."
output=$1
zig=$2
[ -d "$output" ] && [ ! -L "$output" ] && [ -x "$zig" ]
[ "$("$zig" version)" = 0.17.0 ] || { printf 'This checked build uses Zig 0.17.0.\n' >&2; exit 2; }
[ ! -e "$output/bounded-nand-read" ] && [ ! -e "$output/build.json" ]
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a7 -O2 -static -nostdlib -ffreestanding -fno-builtin \
    -fomit-frame-pointer -fno-stack-protector -fno-pie -ffunction-sections -fdata-sections \
    -std=c11 -Wall -Wextra -Werror -Wl,-e,_start -Wl,--build-id=none -Wl,--gc-sections -Wl,-z,noexecstack \
    tools/bounded-nand/main.c tools/bounded-nand/bounded_nand_io.c -o "$output/bounded-nand-read"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,sys
out=Path(sys.argv[1]);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources=['tools/bounded-nand/main.c','tools/bounded-nand/bounded_nand_io.c','tools/bounded-nand/bounded_nand_io.h','scripts/build-bounded-nand.sh']
record={'schemaVersion':1,'scope':'bounded-nand-read-developer-build','compiler':'zig0.17.0',
 'target':'arm-linux-musleabi/cortex_a7','sourceSHA256':{s:sha(Path(s)) for s in sources},
 'helperSHA256':sha(out/'bounded-nand-read'),'helperBytes':(out/'bounded-nand-read').stat().st_size,
 'readOnly':True,'firmwareEligible':False,'hardwareTested':False}
(out/'build.json').write_text(json.dumps(record,indent=2)+'\n')
PY
printf 'READ_HELPER=%s/bounded-nand-read\n' "$output"
