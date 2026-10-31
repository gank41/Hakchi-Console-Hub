#!/bin/sh
set -eu
[ "$#" -eq 2 ] || exit 2
cd "$(dirname "$0")/.."
output=$1
zig=$2
[ -d "$output" ] && [ ! -L "$output" ] && [ "$("$zig" version)" = 0.17.0 ]
[ ! -e "$output/bounded-nand-write" ] && [ ! -e "$output/build.json" ]
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a7 -O2 -static -fno-pie -fstack-protector-strong \
 -ffunction-sections -fdata-sections -Wl,--gc-sections -Wl,-z,noexecstack -std=c11 -Wall -Wextra -Werror \
 -DMBEDTLS_CONFIG_FILE='"config.h"' -Itools/bounded-nand-write -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
 tools/bounded-nand-write/main.c tools/bounded-nand-write/bounded_replace.c tools/bounded-nand/bounded_nand_io.c \
 vendor/mbedtls/library/sha256.c vendor/mbedtls/library/platform_util.c -o "$output/bounded-nand-write"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,sys
out=Path(sys.argv[1]);binary=(out/'bounded-nand-write').read_bytes();sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=['tools/bounded-nand-write/main.c','tools/bounded-nand-write/bounded_replace.c','tools/bounded-nand-write/bounded_replace.h','tools/bounded-nand-write/config.h','tools/bounded-nand/bounded_nand_io.c','tools/bounded-nand/bounded_nand_io.h','vendor/mbedtls/library/sha256.c','vendor/mbedtls/library/platform_util.c','scripts/build-bounded-nand-writer.sh']
record={'schemaVersion':1,'scope':'bounded-nand-write-developer-build','compiler':'zig0.17.0','target':'arm-linux-musleabi/cortex_a7','helperBytes':len(binary),'helperSHA256':hashlib.sha256(binary).hexdigest(),'sources':{p:sha(Path(p)) for p in files},'hardwareTested':False,'firmwareEligible':False}
(out/'build.json').write_text(json.dumps(record,indent=2)+'\n')
PY
printf 'WRITE_HELPER=%s/bounded-nand-write\n' "$output"
