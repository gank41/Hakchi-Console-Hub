"""Rebuild a path-free research writer. This does not authorize firmware writes."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parent.parent
NORMALIZER = REPO / "tools/bounded-nand-write/reproduce_tested_writer.py"
BUILDER = REPO / "scripts/build-bounded-nand-writer.sh"
PINNED_SOURCES = {
    "tools/bounded-nand-write/main.c": "ca399b966fab7e622169515c54b92692c39e25255db1a44fafbc426b41a7e9a7",
    "tools/bounded-nand-write/bounded_replace.c": "2391e6404245089c382ba9b6e1da6bca3c8fb1ad870f44e66a909c7a24ec4f88",
    "tools/bounded-nand-write/bounded_replace.h": "f6cdbb5ebf950315a503bfd64821caee185ef05896661194f8d9bfe5b2c54885",
    "tools/bounded-nand-write/config.h": "b98622375a7d7761717ff50f56dfcf3be895fd91f63f5caf8de651b7a4c03165",
    "tools/bounded-nand/bounded_nand_io.c": "b5b11e3315341b4cce6dd2eacea07381e0329314c496093b7ff3878ebe189bd8",
    "tools/bounded-nand/bounded_nand_io.h": "b232fab0cf461afec09b3772b75edb627e2ec3fe4edda5f7fdf4aa7be100d591",
    "vendor/mbedtls/library/sha256.c": "4f928e5dcc0a2baf08634fc759309a3dbda52bb69ead14ff6c2dccafd8267453",
    "vendor/mbedtls/library/platform_util.c": "5e195c161ebf03afc4640fb0c8f8aa1a962390fc447a02cd91f7545b5d224a4b",
    "scripts/build-bounded-nand-writer.sh": "475bd64bd6b2edbadfb5ac95966a33adc6d2e1d599118fe038a5aad92f7170ca",
}


def check_sources() -> None:
    for name, digest in PINNED_SOURCES.items():
        if hashlib.sha256((REPO / name).read_bytes()).hexdigest() != digest:
            raise ValueError("A recorded writer source file differs from the earlier build.")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python3 build-reproduced-snes-writer.py NEW_OUTPUT_DIRECTORY ZIG")
    supplied = Path(sys.argv[1])
    zig = Path(sys.argv[2])
    if not supplied.is_absolute() or not zig.is_absolute() or not supplied.name or os.path.lexists(supplied):
        raise SystemExit("Choose a new output directory and an absolute Zig path.")
    parent = supplied.parent.resolve(strict=True)
    output = parent / supplied.name
    check_sources()
    with tempfile.TemporaryDirectory(prefix=".snes-writer-", dir=parent) as temporary:
        working = Path(temporary)
        raw = working / "raw"
        raw.mkdir(mode=0o700)
        subprocess.run([str(BUILDER), str(raw), str(zig)], cwd=REPO, check=True)
        check_sources()
        stage = working / "publish"
        stage.mkdir(mode=0o700)
        writer = stage / "bounded-nand-write"
        subprocess.run([sys.executable, str(NORMALIZER), str(raw / "bounded-nand-write"), str(writer)], cwd=REPO, check=True)
        original = json.loads((raw / "build.json").read_text())
        if original.get("sources") != PINNED_SOURCES:
            raise ValueError("The builder's source record does not match the recorded build.")
        record = {
            "scope": "snes-writer-reproduction-research-only",
            "schemaVersion": 1,
            "sha256": "7d1e5fb9657baa7294790e538eadfc4a1446b233a8839851849fc0c652471e7a",
            "hardwareTested": False,
            "firmwareWriteAuthorized": False,
            "sourceProvenanceVerified": False,
            "reportedSourceBuild": original,
        }
        with (stage / "build.json").open("x") as manifest:
            manifest.write(json.dumps(record, sort_keys=True, indent=2) + "\n")
            manifest.flush()
            os.fsync(manifest.fileno())
        directory = os.open(stage, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        check_sources()
        # macOS exclusive rename publishes the complete directory in one step.
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(stage), os.fsencode(output), 4) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        directory = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    print("Research writer created. Console firmware use is not authorized.")


if __name__ == "__main__":
    main()
