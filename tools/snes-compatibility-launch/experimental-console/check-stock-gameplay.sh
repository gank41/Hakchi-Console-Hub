#!/bin/sh
set -eu
w=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
t="$w/.."
d=$(mktemp -d /private/tmp/hc-gameplay-XXXXXXXX)
trap 'rm -rf "$d"' EXIT HUP INT TERM
clang -D_DARWIN_C_SOURCE -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -I "$w" -I "$t" "$w/test-stock-gameplay.c" "$w/stock-gameplay.c" -o "$d/test"
"$d/test"
clang -D_DARWIN_C_SOURCE -DHC_STOCK_REQUIRE_CONSOLE_SUPPORT -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -ffunction-sections -fdata-sections -I "$w" -I "$t" "$w/test-stock-target-support-gate.c" "$w/stock-gameplay.c" -Wl,-dead_strip -o "$d/target-gate"
"$d/target-gate"
echo 'Gameplay session owns capture, launch, shutdown and save finalization'
