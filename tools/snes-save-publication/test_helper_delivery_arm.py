"""Run the generated helper delivery body in an isolated, RAM-only ARM guest."""
import argparse
import json
from pathlib import Path
import subprocess
from test_busybox_arm import archive, digest

PREFIX = br'''set -eu
set -o pipefail
set -f
export LC_ALL=C
B=/probe/busybox
M=/mnt
R=/mnt/swifthakchi
regular() { test -f "$1" && test ! -L "$1" && test "$("$B" stat -c '%u' "$1")" = 0 && test "$("$B" stat -c '%h' "$1")" = 1; }
directory() { test -d "$1" && test ! -L "$1" && test "$("$B" stat -c '%u' "$1")" = 0; }
current_selection() { :; }
no_game() { :; }
'''
INIT = br'''#!/bin/sh
B=/probe/busybox
"$B" mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
"$B" mount -t proc proc /proc
"$B" mount -t tmpfs -o size=8m,mode=755 tmpfs /mnt || exit 1
"$B" mkdir -m 755 /mnt/swifthakchi
H=/mnt/swifthakchi/snes-save-profile-switch
fail=0
run() { name=$1; shift; if (set -eu; "$@"); then echo "CASE_PASS:$name"; else echo "CASE_FAIL:$name"; fail=1; fi; }
matching() { a=$("$B" sha256sum "$1");b=$("$B" sha256sum "$2");test "${a%% *}" = "${b%% *}"; }
first() {
  "$B" sh /probe/deliver.sh </probe/input >/tmp/result
  matching /tmp/result /probe/receipt
  test "$("$B" stat -c '%s %a' "$H")" = '17544 700'
}
repeat() { "$B" sh /probe/deliver.sh </probe/input >/tmp/result;matching /tmp/result /probe/receipt; }
same_truncated() {
  "$B" head -c 10 /probe/input >/tmp/short
  before=$("$B" sha256sum "$H")
  if "$B" sh /probe/deliver.sh </tmp/short >/tmp/result; then return 1; fi
  after=$("$B" sha256sum "$H"); test "$before" = "$after"
}
different() {
  printf keep > "$H"
  if "$B" sh /probe/deliver.sh </probe/input >/tmp/result; then return 1; fi
  test "$("$B" cat "$H")" = keep
}
link() {
  "$B" rm "$H"; printf keep > /tmp/original; "$B" ln -s /tmp/original "$H"
  if "$B" sh /probe/deliver.sh </probe/input >/tmp/result; then return 1; fi
  test -L "$H" && test "$("$B" cat /tmp/original)" = keep
}
truncated() {
  "$B" rm "$H"; "$B" head -c 10 /probe/input >/tmp/short
  if "$B" sh /probe/deliver.sh </tmp/short >/tmp/result; then return 1; fi
  test "$("$B" stat -c '%s %a' "$H")" = '10 600'
}
run first first
run repeat repeat
run same_truncated same_truncated
run different different
run link link
run truncated truncated
if test "$fail" = 0; then echo ALL_CASES_PASSED; else echo SOME_CASES_FAILED; fi
"$B" poweroff -f
'''


def main():
    parser = argparse.ArgumentParser()
    for name in ("kernel", "busybox", "fixture", "qemu", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    if digest(args.kernel) != "1ae18b60e4720ef744afac6fb51d18a1cd377521072dab55772c2fc09ed290d4":
        raise SystemExit("Unexpected generic ARM kernel")
    if digest(args.busybox) != "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6":
        raise SystemExit("Unexpected SNES BusyBox")
    source = (args.fixture / "script").read_bytes()
    marker = b"# SNES_HELPER_DELIVERY_BODY\n"
    if source.count(marker) != 1:
        raise SystemExit("Invalid generated delivery fixture")
    script = PREFIX + source.split(marker, 1)[1]
    entries = [(name, 0o40755, b"") for name in (".", "bin", "dev", "proc", "tmp", "probe", "mnt")]
    entries += [("init", 0o100755, INIT), ("probe/busybox", 0o100755, args.busybox.read_bytes()),
                ("probe/deliver.sh", 0o100700, script), ("bin/sh", 0o120777, b"../probe/busybox")]
    entries += [("probe/" + name, 0o100600, (args.fixture / name).read_bytes()) for name in ("input", "receipt")]
    args.output.mkdir(parents=True, exist_ok=True)
    initrd = args.output / "test.cpio"
    initrd.write_bytes(archive(entries))
    command = [str(args.qemu), "-M", "virt", "-cpu", "cortex-a15", "-m", "192M", "-accel", "tcg",
               "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-no-reboot",
               "-kernel", str(args.kernel), "-initrd", str(initrd), "-append", "console=ttyAMA0 rdinit=/init panic=1"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, check=False)
    log = result.stdout
    (args.output / "guest.log").write_bytes(log)
    passed = {name: ("CASE_PASS:" + name).encode() in log for name in ("first", "repeat", "same_truncated", "different", "link", "truncated")}
    print(json.dumps({"cases": passed, "guestExit": result.returncode, "kernel": "generic Linux 6.1 ARM",
                      "consoleChecksReplacedByFixtures": True, "consoleAccessed": False}, indent=2))
    if result.returncode or not all(passed.values()) or b"ALL_CASES_PASSED" not in log or b"SOME_CASES_FAILED" in log:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
