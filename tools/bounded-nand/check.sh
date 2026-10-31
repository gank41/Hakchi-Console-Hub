#!/bin/sh
set -eu
cd "$(dirname "$0")"
output=$(mktemp -d "${TMPDIR:-/tmp}/bounded-nand.XXXXXX")
trap 'rm -rf "$output"' EXIT
cc=${CC:-clang}
"$cc" -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined bounded_nand_io.c test_bounded_nand.c -o "$output/tests"
"$output/tests"
# Cross-compile source/ABI checks only. These objects are deliberately not a bootable helper.
for source in bounded_nand_io main; do
    "$cc" --target=armv7-none-linux-gnueabi -mcpu=cortex-a7 -mfloat-abi=soft -ffreestanding -fno-builtin -fomit-frame-pointer -O2 -std=c11 -Wall -Wextra -Werror -c "$source.c" -o "$output/$source.arm.o"
done
printf 'ARM EABI read-only objects compiled; no executable linked or console accessed.\n'
