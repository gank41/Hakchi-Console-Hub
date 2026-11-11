#!/bin/sh
set -eu
w=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
t="$w/.."
d=$(mktemp -d /private/tmp/hc-gameplay-image-order-XXXXXXXX)
trap 'rm -rf "$d"' EXIT HUP INT TERM
clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -fsanitize=address,undefined -ffunction-sections -fdata-sections -I "$w" -I "$t" "$w/test-stock-gameplay-image-order.c" "$w/stock-gameplay.c" -Wl,-dead_strip -o "$d/test"
"$d/test"
echo 'Screenshot publication precedes manager completion; failures retain recovery ownership'
