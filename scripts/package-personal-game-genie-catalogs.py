#!/usr/bin/env python3
"""Package a private, previously reviewed catalog snapshot; never fetch source data."""
import hashlib
import json
from pathlib import Path
import shutil
import stat
import sys


def ordinary(path, maximum=16 * 1024 * 1024):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > maximum:
        raise ValueError("Catalog input must be an ordinary bounded file")
    return path.read_bytes()


def package(source, destination):
    if source.is_symlink() or not source.is_dir() or destination.exists():
        raise ValueError("Choose an ordinary source folder and a new destination")
    payloads = {}
    manifest = {"personalUseOnly": True, "catalogs": {}}
    for system in ("nes", "snes", "genesis"):
        name = f"catalog-{system}-v2.json"
        data = ordinary(source / name)
        value = json.loads(data)
        if value.get("version") != 2 or value.get("system") != system or not isinstance(value.get("effects"), list):
            raise ValueError("A reviewed v2 catalog for every system is required")
        payloads[name] = data
        manifest["catalogs"][system] = {"sha256": hashlib.sha256(data).hexdigest(), "effectGroups": len(value["effects"])}
    terms = ordinary(source / "Downloads" / "nes" / "source-terms.html", maximum=2 * 1024 * 1024)
    destination.mkdir(mode=0o700)
    try:
        for name, data in payloads.items():
            (destination / name).write_bytes(data)
        (destination / "source-terms.html").write_bytes(terms)
        (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (destination / "README.txt").write_text(
            "Personal catalog build. These downloaded catalogs are for personal, noncommercial home use.\n"
            "Source notices and terms are retained. This build is not the public catalog distribution.\n"
            "Public distribution requires an appropriate catalog license or source permission.\n")
    except BaseException:
        shutil.rmtree(destination)
        raise
    print("PERSONAL_CODE_CATALOGS_INCLUDED=nes,snes,genesis")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: package-personal-game-genie-catalogs.py SOURCE DESTINATION")
    package(Path(sys.argv[1]), Path(sys.argv[2]))
