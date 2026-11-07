"""Run a synthetic generated publication in an isolated ARM RAM-only guest.

The console identity, mount and game-process checks are replaced by fixture
checks. The save-copy, metadata, helper and publication commands are real.
"""
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
"$B" mount -t tmpfs -o size=192m tmpfs /var/lib || exit 1
id=$("$B" cat /probe/fixture/stage-id)
N=/var/lib/swifthakchi/snes-v2
stage="$N/save-staging/$id"
parent=/var/lib/clover/profiles/0
target="$parent/CLV-U-A0001"
"$B" mkdir -p "$stage" "$N/objects" "$N/menus" "$parent/CLV-U-ZZZZZ"
"$B" cp /probe/fixture/selector "$N/active-menu"
for name in plan __STAGED_NAMES__; do "$B" cp "/probe/fixture/$name" "$stage/$name"; done
printf 'unrelated' > "$parent/CLV-U-ZZZZZ/save"
__PREPARE_PROFILE__
fail=0
if "$B" sh /probe/publish.sh > /tmp/result; then
  actual=$("$B" sha256sum /tmp/result); expected=$("$B" sha256sum /probe/fixture/receipt)
  files_ok=1
  __VERIFY_FILES__
  if test "${actual%% *}" = "${expected%% *}" && test "$files_ok" = 1 &&
     test "$("$B" cat "$parent/CLV-U-ZZZZZ/save")" = unrelated && __CHECK_PROFILE__; then
    echo CASE_PASS:publication
  else echo CASE_FAIL:publication;fail=1;fi
else echo CASE_FAIL:publication;fail=1;fi
__REFUSAL_SETUP__
if "$B" sh /probe/publish.sh > /tmp/refused; then
  echo CASE_FAIL:existing_profile;fail=1
elif __CHECK_REFUSAL__; then
  echo CASE_PASS:existing_profile
else echo CASE_FAIL:existing_profile;fail=1;fi
if test "$fail" = 0; then echo ALL_CASES_PASSED; else echo SOME_CASES_FAILED; fi
"$B" poweroff -f
'''


def main():
    parser = argparse.ArgumentParser()
    for name in ("kernel", "busybox", "helper", "fixture", "qemu", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    if digest(args.kernel) != "1ae18b60e4720ef744afac6fb51d18a1cd377521072dab55772c2fc09ed290d4":
        raise SystemExit("Unexpected generic ARM kernel")
    if digest(args.busybox) != "440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6":
        raise SystemExit("Unexpected SNES BusyBox")
    source = (args.fixture / "script").read_bytes()
    marker = b"current_selection() {\n"
    if source.count(marker) != 1 or digest(args.helper).encode() not in source:
        raise SystemExit("Fixture does not match the supplied helper")
    mapping = json.loads((args.fixture / "mapping.json").read_text())
    if not isinstance(mapping, dict) or not mapping or len(mapping) > 128:
        raise SystemExit("Invalid synthetic fixture mapping")
    for path, staged in mapping.items():
        if not isinstance(path, str) or not re.fullmatch(r"[A-Za-z0-9_./-]+", path) or any(part in ("", ".", "..") for part in path.split("/")):
            raise SystemExit("Invalid synthetic fixture path")
        if not isinstance(staged, str) or not re.fullmatch(r"[0-9]{4}", staged):
            raise SystemExit("Invalid synthetic fixture file")
    if len(set(mapping.values())) != len(mapping):
        raise SystemExit("Duplicate synthetic fixture file")
    verify = []
    for path, staged in sorted(mapping.items()):
        verify.append('a=$("$B" sha256sum "$target/' + path + '");b=$("$B" sha256sum /probe/fixture/' + staged + ')')
        verify.append('meta=$("$B" stat -c \'%Y %a\' "$target/' + path + '")')
        verify.append('test "${a%% *}" = "${b%% *}" && test "$meta" = \'1700000000 600\' || files_ok=0')
    init = INIT.replace(b"__STAGED_NAMES__", " ".join(sorted(mapping.values())).encode())
    init = init.replace(b"__VERIFY_FILES__", "\n  ".join(verify).encode())
    slot = (args.fixture / "kind").is_file() and (args.fixture / "kind").read_text() == "slot"
    if slot:
        prepare_profile = '''"$B" mkdir -m 700 "$target"
"$B" cp /probe/fixture/prior-sram "$target/cartridge.sram"
"$B" cp /probe/fixture/prior-hash "$target/cartridge.sram.hash"
"$B" chmod 600 "$target/cartridge.sram" "$target/cartridge.sram.hash"
TZ=UTC0 "$B" touch -t 202311142213.20 "$target/cartridge.sram" "$target/cartridge.sram.hash"'''
        prepare_profile += '''
check_prior() {
  a=$("$B" sha256sum "$target/cartridge.sram");b=$("$B" sha256sum /probe/fixture/prior-sram)
  c=$("$B" sha256sum "$target/cartridge.sram.hash");d=$("$B" sha256sum /probe/fixture/prior-hash)
  test "${a%% *}" = "${b%% *}" && test "${c%% *}" = "${d%% *}"
}'''
        check_profile = "check_prior"
        refusal_setup = ":"
        check_refusal = check_profile + ' && test -f "$target/suspendpoint1/state.png"'
    else:
        prepare_profile = ":"
        check_profile = ":"
        refusal_setup = '"$B" rm -rf "$target"\n"$B" mkdir "$target"\nprintf keep > "$target/existing"'
        check_refusal = 'test "$("$B" cat "$target/existing")" = keep'
    for placeholder, value in ((b"__PREPARE_PROFILE__", prepare_profile), (b"__CHECK_PROFILE__", check_profile),
                               (b"__REFUSAL_SETUP__", refusal_setup), (b"__CHECK_REFUSAL__", check_refusal)):
        init = init.replace(placeholder, value.encode())
    script = PREFIX + marker + source.split(marker, 1)[1]
    script = script.replace(b"/mnt/swifthakchi/snes-save-profile-switch", b"/probe/profile-switch")
    args.output.mkdir(parents=True, exist_ok=True)
    entries = [(name, 0o40755, b"") for name in (".", "bin", "dev", "proc", "tmp", "probe", "probe/fixture", "var", "var/lib")]
    entries += [("init", 0o100755, init), ("probe/busybox", 0o100755, args.busybox.read_bytes()),
                ("probe/profile-switch", 0o100755, args.helper.read_bytes()), ("probe/publish.sh", 0o100700, script),
                ("bin/sh", 0o120777, b"../probe/busybox")]
    extra = ("prior-sram", "prior-hash") if slot else ()
    for name in ("stage-id", "plan", "selector", "receipt", *sorted(mapping.values()), *extra):
        entries.append(("probe/fixture/" + name, 0o100600, (args.fixture / name).read_bytes()))
    initrd = args.output / "test.cpio"
    initrd.write_bytes(archive(entries))
    command = [str(args.qemu), "-M", "virt", "-cpu", "cortex-a15", "-m", "256M", "-accel", "tcg",
               "-display", "none", "-monitor", "none", "-serial", "stdio", "-nic", "none", "-no-reboot",
               "-kernel", str(args.kernel), "-initrd", str(initrd), "-append", "console=ttyAMA0 rdinit=/init panic=1"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120, check=False)
    log = result.stdout
    (args.output / "guest.log").write_bytes(log)
    passed = {name: ("CASE_PASS:" + name).encode() in log for name in ("publication", "existing_profile")}
    print(json.dumps({"cases": passed, "guestExit": result.returncode, "helperSHA256": digest(args.helper),
                      "kernel": "generic Linux 6.1 ARM", "consoleChecksReplacedByFixtures": True, "consoleAccessed": False}, indent=2))
    if result.returncode or not all(passed.values()) or b"ALL_CASES_PASSED" not in log or b"SOME_CASES_FAILED" in log:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
