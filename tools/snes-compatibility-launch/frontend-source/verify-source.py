#!/usr/bin/env python3
"""Check that the bundled RetroArch patch recreates the reviewed source files.

This is a source-integrity check, not a build, console install, or launch test.
"""
import argparse
import hashlib
import pathlib
import subprocess
import sys
import tarfile
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ARCHIVE = HERE / "RetroArch-1.7.0.tar.gz"
PATCH = ROOT / "SwiftHakchi/Resources/SNESCompatibilityFrontend/frontend.patch"
ARCHIVE_SHA = "8c04ce583b28d1b27f695b56182edab672fcc5f50472bbcb02f1011a49667e48"
PATCH_SHA = "c2eca527410551290c0ed72933d082214abf8a49cf55a805cde744a0388291ee"
PREFIX = "RetroArch-0a2b44273da17d1b2372cd16469bb74791f7ac95/"
EXPECTED = {
    "retroarch.c": "771d669a8bf57d88b64c935a5ed252ec7b6399c61becf4977388fadd4587c600",
    "tasks/task_save.c": "c7f496bc85c660f482b79ebdfd9f452825ef4c2c2e5d23dc86b3bef638c9cc9f",
    "libretro-common/streams/file_stream.c": "3106690d51d0aa554a985fff5f2d3b80b85aced7ca0fc898641b6d627b97653b",
    "libretro-common/vfs/vfs_implementation.c": "53e1fac6cf4635ae050511525215cde215241b37c258fde6d859e289142ab69f",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify(archive, patch):
    archive_bytes, patch_bytes = archive.read_bytes(), patch.read_bytes()
    if sha(archive_bytes) != ARCHIVE_SHA or sha(patch_bytes) != PATCH_SHA:
        raise ValueError("source archive or patch does not match the reviewed material")
    with tempfile.TemporaryDirectory(prefix="hc-frontend-source-") as folder:
        root = pathlib.Path(folder)
        with tarfile.open(archive, "r:gz") as source:
            names = source.getnames()
            for name in EXPECTED:
                member_name = PREFIX + name
                if names.count(member_name) != 1:
                    raise ValueError("missing or duplicate source file")
                member = source.getmember(member_name)
                if not member.isfile() or member.size > 2 * 1024 * 1024:
                    raise ValueError("unexpected source member")
                stream = source.extractfile(member)
                if stream is None:
                    raise ValueError("source file is unavailable")
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(stream.read())
        subprocess.run(["patch", "--batch", "--forward", "-p1"], input=patch_bytes,
                       cwd=root, check=True, stdout=subprocess.DEVNULL)
        for name, expected in EXPECTED.items():
            if sha((root / name).read_bytes()) != expected:
                raise ValueError("patched frontend source does not match the reviewed build")
    print("Reviewed frontend source archive and four patched files match.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=pathlib.Path, default=ARCHIVE)
    parser.add_argument("--patch", type=pathlib.Path, default=PATCH)
    args = parser.parse_args()
    try:
        verify(args.archive, args.patch)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"Source verification failed: {error}", file=sys.stderr)
        sys.exit(1)
