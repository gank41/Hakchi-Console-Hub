#!/bin/sh
set -eu
w=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
t="$w/.."
d=$(mktemp -d /private/tmp/hc-gameplay-transition-XXXXXXXX)
trap 'rm -rf "$d"' EXIT HUP INT TERM
clang -std=c11 -D_DARWIN_C_SOURCE -DHC_STOCK_REQUIRE_MANAGER_TRANSITION -DHC_STOCK_GAMEPLAY_CLOCK_TEST -Wall -Wextra -Werror -fsanitize=address,undefined -ffunction-sections -fdata-sections -I "$w" -I "$t" "$w/test-stock-gameplay-transition.c" "$w/stock-gameplay.c" -Wl,-dead_strip -o "$d/test"
"$d/test"
printf '%s\n' 'Game session orders wait, child start, save finalization and manager completion'
