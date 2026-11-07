#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if [[ $# != 2 || "$1" != /* || ! -d "$1" || -L "$1" || ! -x "$2" ]]; then
    printf 'Usage: %s /existing/output-directory /path/to/zig\n' "$0" >&2
    exit 2
fi
output="$1"
zig="$2"
if [[ "$("$zig" version)" != 0.17.0 ]]; then
    printf 'The reviewed helper build requires Zig 0.17.0.\n' >&2
    exit 1
fi
for name in bounded-nand-read bounded-nand-write build.json; do
    if [[ -e "$output/$name" || -L "$output/$name" ]]; then
        printf 'Refusing to replace %s.\n' "$output/$name" >&2
        exit 1
    fi
done
stage="$(mktemp -d "$output/.snes-portable.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a7 -O2 -static -nostdlib \
    -ffreestanding -fno-builtin -fomit-frame-pointer -fno-stack-protector -fno-pie \
    -ffunction-sections -fdata-sections -g0 -s -std=c11 -Wall -Wextra -Werror \
    -Wl,-e,_start -Wl,--build-id=none -Wl,--gc-sections -Wl,-z,noexecstack \
    tools/bounded-nand/main.c tools/bounded-nand/bounded_nand_io.c \
    -o "$stage/bounded-nand-read"
"$zig" cc -target arm-linux-musleabi -mcpu=cortex_a7 -O2 -static -fno-pie \
    -fstack-protector-strong -ffunction-sections -fdata-sections -Wl,--gc-sections \
    -Wl,-z,noexecstack -Wl,--build-id=none -g0 -s -std=c11 -Wall -Wextra -Werror \
    -DMBEDTLS_CONFIG_FILE='"config.h"' -Itools/bounded-nand-write \
    -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
    tools/bounded-nand-write/main.c tools/bounded-nand-write/bounded_replace.c \
    tools/bounded-nand/bounded_nand_io.c vendor/mbedtls/library/sha256.c \
    vendor/mbedtls/library/platform_util.c -o "$stage/bounded-nand-write"

python3 - "$stage" "$output" <<'PY'
import hashlib, json, os, pathlib, sys

stage, output = map(pathlib.Path, sys.argv[1:])
expected = {
    'bounded-nand-read': (2560, '15d3cf5a75cc2ce3ef0cdf830ee6ec5251a5014f45fc8fac1fa26c8d783e0952'),
    'bounded-nand-write': (31512, '0cc4f84437c0028e041e05b67de2369d4cbd636d8c4a071a16d63b06a92a8494'),
}
for name, (size, digest) in expected.items():
    data = (stage / name).read_bytes()
    if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
        sys.exit(f'{name} differs from the reviewed portable helper.')
    if b'/Users/' in data or b'/Development/NES' in data:
        sys.exit(f'{name} contains a private development path.')
manifest = {'format': 1, 'zigVersion': '0.17.0', 'hardwareTested': False,
            'firmwareWriteAuthorized': False,
            'helpers': {name: {'size': size, 'sha256': digest}
                        for name, (size, digest) in expected.items()}}
(stage / 'build.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
created = []
try:
    for name in (*expected, 'build.json'):
        os.link(stage / name, output / name)
        created.append(name)
except OSError:
    for name in reversed(created):
        target, source = output / name, stage / name
        if target.exists() and os.path.samestat(target.stat(), source.stat()):
            target.unlink()
    raise
PY
printf 'Built and verified portable SNES helpers in %s.\n' "$output"
