"""Exercise the pinned SNES BusyBox in an isolated ARM RAM-only guest.

This test does not connect USB, attach disks, use the network, or write a
console. A generic Debian kernel is used, not the SNES kernel.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def archive(entries):
    result = bytearray()
    for inode, (name, mode, data) in enumerate(entries + [("TRAILER!!!", 0, b"")], 1):
        encoded = name.encode("ascii") + b"\0"
        fields = [inode, mode, 0, 0, 2 if mode & 0xF000 == 0x4000 else 1,
                  0, len(data), 0, 0, 0, 0, len(encoded), 0]
        result += b"070701" + b"".join(("%08x" % value).encode("ascii") for value in fields) + encoded
        result += b"\0" * (-len(result) % 4) + data
        result += b"\0" * (-len(result) % 4)
    result += b"\0" * (-len(result) % 512)
    return bytes(result)


INIT = br'''#!/bin/sh
B=/probe/busybox
"$B" mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
"$B" mount -t proc proc /proc
cd /tmp
fail=0
run() { name=$1; shift; if (set -eu; "$@"); then echo "CASE_PASS:$name"; else echo "CASE_FAIL:$name"; fail=1; fi; }
legacy_mv_unsupported() {
  "$B" mkdir -p /tmp/switch/ready /tmp/switch/target
  printf source > /tmp/switch/ready/save
  if "$B" mv -T /tmp/switch/ready /tmp/switch/target 2>/tmp/mv-error; then return 1; fi
  "$B" grep -q 'invalid option' /tmp/mv-error
  test "$("$B" cat /tmp/switch/ready/save)" = source
  test ! -e /tmp/switch/target/save
}
file_metadata() {
  printf data > /tmp/metadata
  "$B" chmod 600 /tmp/metadata
  TZ=UTC0 "$B" touch -t 202311142213.20 /tmp/metadata
  result=$("$B" stat -c '%s %Y %a' /tmp/metadata)
  test "$result" = '4 1700000000 600'
}
copy_fsync() {
  printf data > /tmp/source
  "$B" dd bs=65536 conv=fsync < /tmp/source > /tmp/destination 2>/dev/null
  test "$("$B" cat /tmp/destination)" = data
}
space_format() {
  values=$("$B" stat -f -c '%S %b %a' /tmp)
  set -- $values; test "$#" = 3
  for value in "$@"; do case "$value" in ''|*[!0-9]*) return 1;; esac; done
}
exclusive_reservation() {
  "$B" mkdir /tmp/reservation
  printf keep > /tmp/reservation/keep
  if "$B" mkdir /tmp/reservation 2>/dev/null; then return 1; fi
  test "$("$B" cat /tmp/reservation/keep)" = keep
}
run legacy_mv_unsupported legacy_mv_unsupported
run file_metadata file_metadata
run copy_fsync copy_fsync
run space_format space_format
run exclusive_reservation exclusive_reservation
if test "$fail" = 0; then echo ALL_CASES_PASSED; else echo SOME_CASES_FAILED; fi
"$B" poweroff -f
'''


def main():
    parser = argparse.ArgumentParser()
    for name in ("kernel", "busybox", "qemu", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    if digest(args.kernel) != "1ae18b60e4720ef744afac6fb51d18a1cd377521072dab55772c2fc09ed290d4":
        raise SystemExit("Unexpected generic ARM kernel")
    if digest(args.busybox) != "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6":
        raise SystemExit("Unexpected SNES BusyBox")
    args.output.mkdir(parents=True, exist_ok=True)
    entries = [(name, 0o40755, b"") for name in (".", "bin", "dev", "proc", "tmp", "probe")]
    entries += [("init", 0o100755, INIT), ("probe/busybox", 0o100755, args.busybox.read_bytes()),
                ("bin/sh", 0o120777, b"../probe/busybox")]
    initrd = args.output / "test.cpio"
    initrd.write_bytes(archive(entries))
    command = [str(args.qemu), "-M", "virt", "-cpu", "cortex-a15", "-m", "192M", "-accel", "tcg",
               "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-no-reboot",
               "-kernel", str(args.kernel), "-initrd", str(initrd), "-append", "console=ttyAMA0 rdinit=/init panic=1"]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, check=False)
    except subprocess.TimeoutExpired as error:
        raise SystemExit("Isolated ARM test timed out") from error
    log = result.stdout
    (args.output / "guest.log").write_bytes(log)
    cases = ("legacy_mv_unsupported", "file_metadata", "copy_fsync", "space_format", "exclusive_reservation")
    passed = {name: ("CASE_PASS:" + name).encode() in log for name in cases}
    print(json.dumps({"cases": passed, "guestExit": result.returncode, "kernel": "generic Linux 6.1 ARM",
                      "busyboxSHA256": digest(args.busybox), "consoleAccessed": False}, indent=2))
    if result.returncode or not all(passed.values()) or b"ALL_CASES_PASSED" not in log or b"SOME_CASES_FAILED" in log:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
