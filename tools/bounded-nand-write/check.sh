#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output=$(mktemp -d "${TMPDIR:-/tmp}/bounded-write.XXXXXX")
trap 'rm -rf "$output"' EXIT
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
 tools/bounded-nand/bounded_nand_io.c tools/bounded-nand-write/bounded_replace.c tools/bounded-nand-write/test_bounded_replace.c -o "$output/test"
UBSAN_OPTIONS=halt_on_error=1 ASAN_OPTIONS=halt_on_error=1 "$output/test"
clang --target=armv7-none-linux-gnueabi -mcpu=cortex-a7 -mfloat-abi=soft -ffreestanding -O2 -std=c11 -Wall -Wextra -Werror \
 -c tools/bounded-nand-write/bounded_replace.c -o "$output/replace.arm.o"
printf 'Bounded replacement ARM object compiled; no console accessed.\n'
