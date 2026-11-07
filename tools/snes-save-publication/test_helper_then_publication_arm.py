"""Exercise generated helper delivery followed by save publication in RAM."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from test_busybox_arm import archive, digest

PREFIX = br'''set -eu
set -o pipefail
set -f
export LC_ALL=C
B=/probe/busybox
M=/mnt
R=/mnt/swifthakchi
N=/var/lib/swifthakchi/snes-v2
L=/var/lib/swifthakchi/snes-v1
device=$("$B" stat -c '%d' /var/lib)
regular() { test -f "$1" && test ! -L "$1" && test "$("$B" stat -c '%u' "$1")" = 0 && test "$("$B" stat -c '%h' "$1")" = 1; }
directory() { test -d "$1" && test ! -L "$1" && test "$("$B" stat -c '%u' "$1")" = 0; }
data_directory() { directory "$1" && test "$("$B" stat -c '%d' "$1")" = "$device"; }
no_game() { :; }
'''
INIT = br'''#!/bin/sh
B=/probe/busybox
"$B" mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
"$B" mount -t proc proc /proc
"$B" mount -t tmpfs -o size=8m,mode=755 tmpfs /mnt || exit 1
"$B" mount -t tmpfs -o size=192m tmpfs /var/lib || exit 1
"$B" mkdir -m 755 /mnt/swifthakchi
id=$("$B" cat /probe/save/stage-id)
N=/var/lib/swifthakchi/snes-v2
stage="$N/save-staging/$id"
parent=/var/lib/clover/profiles/0
target="$parent/CLV-U-A0001"
"$B" mkdir -p "$stage" "$N/objects" "$N/menus" "$target"
"$B" chmod 700 "$target"
"$B" cp /probe/save/selector "$N/active-menu"
for name in plan __STAGED_NAMES__; do "$B" cp "/probe/save/$name" "$stage/$name"; done
"$B" cp /probe/save/prior-sram "$target/cartridge.sram"
"$B" cp /probe/save/prior-hash "$target/cartridge.sram.hash"
"$B" chmod 600 "$target/cartridge.sram" "$target/cartridge.sram.hash"
TZ=UTC0 "$B" touch -t 202311142213.20 "$target/cartridge.sram" "$target/cartridge.sram.hash"
fail=0
if "$B" sh /probe/publish.sh >/tmp/early; then
  echo CASE_FAIL:missing_helper;fail=1
elif test ! -e "$target/suspendpoint1"; then echo CASE_PASS:missing_helper
else echo CASE_FAIL:missing_helper;fail=1;fi
if "$B" sh /probe/deliver.sh </probe/helper/input >/tmp/helper-result &&
   test "$("$B" sha256sum /tmp/helper-result | "$B" cut -d ' ' -f1)" = "$("$B" sha256sum /probe/helper/receipt | "$B" cut -d ' ' -f1)"; then
  echo CASE_PASS:helper
else echo CASE_FAIL:helper;fail=1;fi
if "$B" sh /probe/publish.sh >/tmp/save-result; then
  a=$("$B" sha256sum /tmp/save-result); b=$("$B" sha256sum /probe/save/receipt)
  files_ok=1
  __VERIFY_FILES__
  p=$("$B" sha256sum "$target/cartridge.sram"); q=$("$B" sha256sum /probe/save/prior-sram)
  r=$("$B" sha256sum "$target/cartridge.sram.hash"); s=$("$B" sha256sum /probe/save/prior-hash)
  if test "${a%% *}" = "${b%% *}" && test "$files_ok" = 1 && test "${p%% *}" = "${q%% *}" && test "${r%% *}" = "${s%% *}"; then
    echo CASE_PASS:publication
  else echo CASE_FAIL:publication;fail=1;fi
else echo CASE_FAIL:publication;fail=1;fi
if test "$fail" = 0; then echo ALL_CASES_PASSED; else echo SOME_CASES_FAILED; fi
"$B" poweroff -f
'''


def main():
    parser = argparse.ArgumentParser()
    for name in ("kernel", "busybox", "helper-fixture", "save-fixture", "qemu", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    if digest(args.kernel) != "1ae18b60e4720ef744afac6fb51d18a1cd377521072dab55772c2fc09ed290d4" or digest(args.busybox) != "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6":
        raise SystemExit("Unexpected ARM test inputs")
    helper_source = (args.helper_fixture / "script").read_bytes()
    save_source = (args.save_fixture / "script").read_bytes()
    helper_marker, save_marker = b"# SNES_HELPER_DELIVERY_BODY\n", b"current_selection() {\n"
    if helper_source.count(helper_marker) != 1 or save_source.count(save_marker) != 1 or (args.save_fixture / "kind").read_text() != "slot":
        raise SystemExit("Invalid generated fixture")
    mapping = json.loads((args.save_fixture / "mapping.json").read_text())
    if not mapping or len(mapping) > 128 or any(not re.fullmatch(r"[A-Za-z0-9_./-]+", path) or any(p in ("", ".", "..") for p in path.split("/")) or not re.fullmatch(r"[0-9]{4}", name) for path, name in mapping.items()):
        raise SystemExit("Invalid synthetic save mapping")
    verify = []
    for path, name in sorted(mapping.items()):
        verify.append('a=$("$B" sha256sum "$target/' + path + '");b=$("$B" sha256sum /probe/save/' + name + ')')
        verify.append('test "${a%% *}" = "${b%% *}" || files_ok=0')
    init = INIT.replace(b"__STAGED_NAMES__", " ".join(sorted(mapping.values())).encode()).replace(b"__VERIFY_FILES__", "\n  ".join(verify).encode())
    delivery = PREFIX + b"current_selection() { :; }\n" + helper_source.split(helper_marker, 1)[1]
    publication = PREFIX + save_marker + save_source.split(save_marker, 1)[1]
    entries = [(name, 0o40755, b"") for name in (".", "bin", "dev", "proc", "tmp", "probe", "probe/helper", "probe/save", "mnt", "var", "var/lib")]
    entries += [("init", 0o100755, init), ("probe/busybox", 0o100755, args.busybox.read_bytes()),
                ("probe/deliver.sh", 0o100700, delivery), ("probe/publish.sh", 0o100700, publication), ("bin/sh", 0o120777, b"../probe/busybox")]
    entries += [("probe/helper/" + name, 0o100600, (args.helper_fixture / name).read_bytes()) for name in ("input", "receipt")]
    names = ("stage-id", "plan", "selector", "receipt", "prior-sram", "prior-hash", *sorted(mapping.values()))
    entries += [("probe/save/" + name, 0o100600, (args.save_fixture / name).read_bytes()) for name in names]
    args.output.mkdir(parents=True, exist_ok=True)
    initrd = args.output / "test.cpio"; initrd.write_bytes(archive(entries))
    command = [str(args.qemu), "-M", "virt", "-cpu", "cortex-a15", "-m", "256M", "-accel", "tcg", "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-no-reboot", "-kernel", str(args.kernel), "-initrd", str(initrd), "-append", "console=ttyAMA0 rdinit=/init panic=1"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, check=False)
    log = result.stdout; (args.output / "guest.log").write_bytes(log)
    passed = {name: ("CASE_PASS:" + name).encode() in log for name in ("missing_helper", "helper", "publication")}
    print(json.dumps({"cases": passed, "guestExit": result.returncode, "kernel": "generic Linux 6.1 ARM", "consoleChecksReplacedByFixtures": True, "consoleAccessed": False}, indent=2))
    if result.returncode or not all(passed.values()) or b"ALL_CASES_PASSED" not in log or b"SOME_CASES_FAILED" in log:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
