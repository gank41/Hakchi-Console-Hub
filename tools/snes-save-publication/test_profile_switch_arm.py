"""Test a save-profile switch helper in a no-network, RAM-only ARM guest."""
import argparse
import json
from pathlib import Path
import subprocess
from test_busybox_arm import archive, digest

INIT = br'''#!/bin/sh
B=/probe/busybox
"$B" mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
"$B" mount -t proc proc /proc
fail=0
id=01234567-89AB-CDEF-0123-456789ABCDEF
stage=/var/lib/swifthakchi/snes-v2/save-staging/$id
parent=/var/lib/clover/profiles/0
code=CLV-U-ABC01
run() { name=$1; shift; if (set -eu; "$@"); then echo "CASE_PASS:$name"; else echo "CASE_FAIL:$name"; fail=1; fi; }
fixture() {
  "$B" rm -rf /var/lib/swifthakchi /var/lib/clover /tmp/hold
  "$B" mkdir -p "$stage/publication" "$parent/$code" /tmp/hold
  "$B" chmod 700 "$stage/publication" "$parent/$code"
  printf save > "$stage/publication/data"
  set -- $("$B" stat -c '%d %i' "$stage/publication") $("$B" stat -c '%d %i' "$parent/$code")
  source_dev=$1;source_ino=$2;dest_dev=$3;dest_ino=$4
}
switch_profile() { /probe/profile-switch "$id" "$code" "$source_dev" "$source_ino" "$dest_dev" "$dest_ino"; }
success() {
  fixture; switch_profile
  test "$("$B" cat "$parent/$code/data")" = save
  test ! -e "$stage/publication"
}
occupied() {
  fixture; printf keep > "$parent/$code/keep"
  if switch_profile; then return 1; fi
  test "$("$B" cat "$parent/$code/keep")" = keep
  test "$("$B" cat "$stage/publication/data")" = save
}
changed_reservation() {
  fixture; "$B" mv "$parent/$code" /tmp/hold/old; "$B" mkdir "$parent/$code"
  if switch_profile; then return 1; fi
  test "$("$B" cat "$stage/publication/data")" = save
}
destination_link() {
  fixture; "$B" mv "$parent/$code" /tmp/hold/old; "$B" ln -s /tmp/hold "$parent/$code"
  if switch_profile; then return 1; fi
  test -L "$parent/$code"; test "$("$B" cat "$stage/publication/data")" = save
}
source_link() {
  fixture; "$B" mv "$stage/publication" /tmp/hold/old; "$B" ln -s /tmp/hold/old "$stage/publication"
  if switch_profile; then return 1; fi
  test -L "$stage/publication"; test "$("$B" cat /tmp/hold/old/data)" = save
}
changed_source() {
  fixture; "$B" mv "$stage/publication" /tmp/hold/old; "$B" mkdir -m 700 "$stage/publication"
  if switch_profile; then return 1; fi
  test "$("$B" cat /tmp/hold/old/data)" = save
}
source_ancestor_link() {
  fixture
  "$B" mv /var/lib/swifthakchi/snes-v2/save-staging /tmp/hold/staging
  "$B" ln -s /tmp/hold/staging /var/lib/swifthakchi/snes-v2/save-staging
  if switch_profile; then return 1; fi
  test "$("$B" cat /tmp/hold/staging/$id/publication/data)" = save
}
wrong_permissions() {
  fixture; "$B" chmod 777 "$stage/publication"
  if switch_profile; then return 1; fi
  "$B" chmod 700 "$stage/publication"; "$B" chmod 777 "$parent/$code"
  if switch_profile; then return 1; fi
  test "$("$B" cat "$stage/publication/data")" = save
}
wrong_device() {
  fixture; source_dev=$((source_dev + 1))
  if switch_profile; then return 1; fi
  test "$("$B" cat "$stage/publication/data")" = save
}
bad_arguments() {
  fixture
  if /probe/profile-switch "$id" '../escape' "$source_dev" "$source_ino" "$dest_dev" "$dest_ino"; then return 1; fi
  if /probe/profile-switch '../escape' "$code" "$source_dev" "$source_ino" "$dest_dev" "$dest_ino"; then return 1; fi
  test "$("$B" cat "$stage/publication/data")" = save
}
slot_fixture() {
  fixture
  printf keep > "$parent/$code/cartridge.sram"
  "$B" mkdir -m 700 "$parent/$code/suspendpoint1"
  set -- $("$B" stat -c '%d %i' "$parent/$code/suspendpoint1") $("$B" stat -c '%d %i' "$parent/$code")
  dest_dev=$1;dest_ino=$2;profile_dev=$3;profile_ino=$4
}
switch_slot() { /probe/profile-switch "$id" "$code" suspendpoint1 "$source_dev" "$source_ino" "$dest_dev" "$dest_ino" "$profile_dev" "$profile_ino"; }
slot_success() {
  slot_fixture; switch_slot
  test "$("$B" cat "$parent/$code/cartridge.sram")" = keep
  test "$("$B" cat "$parent/$code/suspendpoint1/data")" = save
  test ! -e "$stage/publication"
}
slot_occupied() {
  slot_fixture; printf other > "$parent/$code/suspendpoint1/other"
  if switch_slot; then return 1; fi
  test "$("$B" cat "$parent/$code/cartridge.sram")" = keep
  test "$("$B" cat "$parent/$code/suspendpoint1/other")" = other
  test "$("$B" cat "$stage/publication/data")" = save
}
slot_profile_replaced() {
  slot_fixture; "$B" mv "$parent/$code" /tmp/hold/profile
  "$B" mkdir -p "$parent/$code/suspendpoint1"
  if switch_slot; then return 1; fi
  test "$("$B" cat /tmp/hold/profile/cartridge.sram)" = keep
  test "$("$B" cat "$stage/publication/data")" = save
}
slot_destination_replaced() {
  slot_fixture; "$B" mv "$parent/$code/suspendpoint1" /tmp/hold/slot
  "$B" ln -s /tmp/hold/slot "$parent/$code/suspendpoint1"
  if switch_slot; then return 1; fi
  test -L "$parent/$code/suspendpoint1"
  test "$("$B" cat "$parent/$code/cartridge.sram")" = keep
  test "$("$B" cat "$stage/publication/data")" = save
}
slot_profile_permissions_changed() {
  slot_fixture; "$B" chmod 777 "$parent/$code"
  if switch_slot; then return 1; fi
  test "$("$B" cat "$parent/$code/cartridge.sram")" = keep
  test "$("$B" cat "$stage/publication/data")" = save
}
slot_invalid_name() {
  slot_fixture
  if /probe/profile-switch "$id" "$code" ../escape "$source_dev" "$source_ino" "$dest_dev" "$dest_ino" "$profile_dev" "$profile_ino"; then return 1; fi
  if /probe/profile-switch "$id" "$code" suspendpoint5 "$source_dev" "$source_ino" "$dest_dev" "$dest_ino" "$profile_dev" "$profile_ino"; then return 1; fi
  test "$("$B" cat "$parent/$code/cartridge.sram")" = keep
  test "$("$B" cat "$stage/publication/data")" = save
}
run success success
run occupied occupied
run changed_reservation changed_reservation
run destination_link destination_link
run source_link source_link
run changed_source changed_source
run source_ancestor_link source_ancestor_link
run wrong_permissions wrong_permissions
run wrong_device wrong_device
run bad_arguments bad_arguments
run slot_success slot_success
run slot_occupied slot_occupied
run slot_profile_replaced slot_profile_replaced
run slot_destination_replaced slot_destination_replaced
run slot_profile_permissions_changed slot_profile_permissions_changed
run slot_invalid_name slot_invalid_name
if test "$fail" = 0; then echo ALL_CASES_PASSED; else echo SOME_CASES_FAILED; fi
"$B" poweroff -f
'''


def main():
    parser = argparse.ArgumentParser()
    for name in ("kernel", "busybox", "helper", "qemu", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--empty-test", type=Path)
    args = parser.parse_args()
    if digest(args.kernel) != "1ae18b60e4720ef744afac6fb51d18a1cd377521072dab55772c2fc09ed290d4":
        raise SystemExit("Unexpected generic ARM kernel")
    if digest(args.busybox) != "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6":
        raise SystemExit("Unexpected SNES BusyBox")
    args.output.mkdir(parents=True, exist_ok=True)
    init = INIT
    if args.empty_test:
        extra = b'run repeated_empty_check /probe/test-empty /tmp/empty-check\n'
        init = init.replace(b'if test "$fail" = 0; then', extra + b'if test "$fail" = 0; then')
    entries = [(name, 0o40755, b"") for name in (".", "bin", "dev", "proc", "tmp", "probe", "var", "var/lib")]
    entries += [("init", 0o100755, init), ("probe/busybox", 0o100755, args.busybox.read_bytes()),
                ("probe/profile-switch", 0o100755, args.helper.read_bytes()), ("bin/sh", 0o120777, b"../probe/busybox")]
    if args.empty_test:
        entries.append(("probe/test-empty", 0o100755, args.empty_test.read_bytes()))
    initrd = args.output / "test.cpio"
    initrd.write_bytes(archive(entries))
    command = [str(args.qemu), "-M", "virt", "-cpu", "cortex-a15", "-m", "192M", "-accel", "tcg",
               "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-no-reboot",
               "-kernel", str(args.kernel), "-initrd", str(initrd), "-append", "console=ttyAMA0 rdinit=/init panic=1"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, check=False)
    log = result.stdout
    (args.output / "guest.log").write_bytes(log)
    cases = ("success", "occupied", "changed_reservation", "destination_link", "source_link", "changed_source",
             "source_ancestor_link", "wrong_permissions", "wrong_device", "bad_arguments", "slot_success", "slot_occupied",
             "slot_profile_replaced", "slot_destination_replaced", "slot_profile_permissions_changed", "slot_invalid_name")
    if args.empty_test:
        cases += ("repeated_empty_check",)
    passed = {name: ("CASE_PASS:" + name).encode() in log for name in cases}
    print(json.dumps({"cases": passed, "guestExit": result.returncode, "helperSHA256": digest(args.helper),
                      "kernel": "generic Linux 6.1 ARM", "consoleAccessed": False}, indent=2))
    if result.returncode or not all(passed.values()) or b"ALL_CASES_PASSED" not in log or b"SOME_CASES_FAILED" in log:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
