#!/bin/sh
set -eu
w=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
t="$w/.."
c="$w/../../../vendor/mbedtls"
d=$(mktemp -d /tmp/hc-entry-integrated-XXXXXX)
trap 'rm -rf "$d"' EXIT HUP INT TERM
mkdir -m 700 "$d/objects" "$d/profiles" "$d/stage"
mkdir -p "$d/profiles/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
chmod 700 "$d/profiles/CLV-U-ABCDE/hakchi" "$d/profiles/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223"
chmod 700 "$d/profiles/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
printf abc > "$d/objects/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.sfc"
chmod 600 "$d/objects/"*.sfc
clang -std=c11 -D_DARWIN_C_SOURCE -I "$w" "$w/test-console-entry-child.c" "$w/launch-request.c" "$w/startup-status.c" -o "$d/child"
clang -std=c11 -D_DARWIN_C_SOURCE -DHC_HOST_GAME_RUNNER -DHC_ENABLE_RECOVERY_OBSERVER -DHC_ENABLE_MANAGER_INVENTORY -DHC_TEST_PROFILES_DIRECTORY=\"$d/profiles\" -DHC_TEST_OBJECT_DIRECTORY=\"$d/objects\" -Wall -Wextra -Werror -ffunction-sections -fdata-sections -fsanitize=address,undefined -I "$w" -I "$t" -I "$c/include" -I "$c/library" \
 "$w/console-supervisor-main.c" "$w/test-console-entry-driver.c" "$w/test-frontend-manager-handoff.c" "$w/frontend-main-entry.c" "$w/stock-runtime-bridge.c" "$w/stock-game-session.c" "$w/stock-save-session.c" "$w/stock-config.c" "$w/recovery-observer.c" "$w/recovery-clock-wire.c" "$w/recovery-binding.c" "$w/session-owner.c" "$w/periodic-owner.c" "$w/hc-intent-v2.c" "$t/autosave_target.c" "$t/autosave_publish.c" "$w/console-game.c" "$w/console-game-start.c" "$w/console-runtime.c" "$w/console-supervisor.c" "$w/verified-launch.c" "$w/launch-request.c" "$w/nonce-sequence.c" "$w/startup-status.c" "$w/startup-monitor-experimental.c" "$t/arguments.c" "$t/isolated_saves.c" "$t/child_process.c" "$t/control_pipe.c" "$t/owned_directory.c" "$c/library/sha256.c" "$c/library/platform_util.c" -Wl,-dead_strip -lpthread -o "$d/entry"
"$d/entry" --observe-manager-inventory CLV-U-ABCDE ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad > "$d/empty-inventory"
python3 - "$d/empty-inventory" <<'PY'
import pathlib,sys
assert pathlib.Path(sys.argv[1]).read_bytes()==b'HCMINV2\0\0\0'
PY
# Real manager-style paths remain distinct all the way into the verified game handoff.
HC_ENTRY_ROOT="$d" HC_ENTRY_CHILD="$d/child" HC_ENTRY_CHILD_SHA="$(shasum -a 256 "$d/child" | cut -d " " -f 1)" \
HC_EXPECT_MANAGER_SAVE=/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback/savestate \
HC_EXPECT_MANAGER_IMAGE=/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png \
"$d/entry" --game CLV-U-ABCDE --rom /var/lib/swifthakchi/snes-v2/objects/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.sfc --title-code CLV-U-ABCDE --wait-transition-fd 28 --start-transition-fd 31 --finish-transition-fd 33 --save-data-backing-file /var/lib/clover/profiles/0/CLV-U-ABCDE/cartridge.sram --rollback-output-dir /var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback --save-screenshot-on-quit /var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png
mkdir -m 700 "$d/profiles/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad/sessions/checkpoint-ffffffffffffffffffffffffffffffff"
"$d/entry" --observe-manager-inventory CLV-U-ABCDE ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad > "$d/inventory"
if "$d/entry" --observe-manager-inventory CLV-U-WRONG ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad > "$d/foreign-inventory"; then exit 1; fi
test ! -s "$d/foreign-inventory"
if [ -n "${HC_ENTRY_INVENTORY_OUTPUT:-}" ]; then cp "$d/inventory" "$HC_ENTRY_INVENTORY_OUTPUT"; fi
python3 - "$d/inventory" <<'PY'
import pathlib,struct,sys
b=pathlib.Path(sys.argv[1]).read_bytes();assert b[:8]==b'HCMINV2\0' and struct.unpack('<H',b[8:10])[0]==2
pos=10;items=[]
for _ in range(2):
 n=struct.unpack('<H',b[pos:pos+2])[0];pos+=2;items.append(b[pos:pos+n]);pos+=n
assert pos==len(b) and sum(x.startswith(b'HCSHOT1\0') for x in items)==1
assert b'checkpoint-ffffffffffffffffffffffffffffffff' in items
PY
if [ -n "${HC_MANAGER_TIME_RECORD_INPUT:-}" ] && [ -n "${HC_MANAGER_TIME_INVENTORY_OUTPUT:-}" ]; then
  session="$d/profiles/CLV-U-ABCDE/hakchi/snes9x2010-fe690dd3-armhf-glibc223/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad/sessions/checkpoint-07070707070707070707070707070707"
  mkdir -m 700 "$session"
  cp "$HC_MANAGER_TIME_RECORD_INPUT" "$session/manager.meta"
  chmod 600 "$session/manager.meta"
  "$d/entry" --observe-manager-inventory CLV-U-ABCDE ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad > "$HC_MANAGER_TIME_INVENTORY_OUTPUT"
fi
# Invalid title and corrupted ROM must fail before the fixture runner starts.
if HC_ENTRY_ROOT="$d" HC_ENTRY_CHILD="$d/missing" "$d/entry" --game CLV-U-ABCDE --rom /var/lib/swifthakchi/snes-v2/objects/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.sfc --title-code CLV-U-WRONG --wait-transition-fd 28 --start-transition-fd 31 --finish-transition-fd 33 --save-data-backing-file /var/lib/clover/profiles/0/CLV-U-ABCDE/cartridge.sram > "$d/invalid.out" 2> "$d/invalid.err"; then exit 1; fi
rg -q 'Invalid compatibility menu request' "$d/invalid.err"
printf bad > "$d/objects/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.sfc"
if HC_ENTRY_ROOT="$d" HC_ENTRY_CHILD="$d/missing" "$d/entry" --game CLV-U-ABCDE --rom /var/lib/swifthakchi/snes-v2/objects/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.sfc --title-code CLV-U-ABCDE --wait-transition-fd 28 --start-transition-fd 31 --finish-transition-fd 33 --save-data-backing-file /var/lib/clover/profiles/0/CLV-U-ABCDE/cartridge.sram > "$d/invalid.out" 2> "$d/invalid.err"; then exit 1; fi
rg -q 'Compatibility ROM could not be verified' "$d/invalid.err"
