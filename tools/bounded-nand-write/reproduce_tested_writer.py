"""Create a research-only path-free copy of the recorded SNES writer.

This does not authorize or perform a console operation. It accepts a rebuilt
ELF only when its normalized bytes match the reviewed digest exactly.
"""
import hashlib
import os
from pathlib import Path
import struct
import sys
import tempfile

EXPECTED = "7d1e5fb9657baa7294790e538eadfc4a1446b233a8839851849fc0c652471e7a"
MAXIMUM_BYTES = 2 * 1024 * 1024


def normalized(data: bytes) -> bytes:
    if not 52 <= len(data) <= MAXIMUM_BYTES:
        raise ValueError("Invalid writer size")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    if (header[0][:7] != b"\x7fELF\x01\x01\x01" or header[1:3] != (2, 40)
            or header[9] != 32 or not 1 <= header[10] <= 128
            or header[5] < 52 or header[5] + header[9] * header[10] > len(data)):
        raise ValueError("Invalid ARM executable")
    segments = [struct.unpack_from("<IIIIIIII", data, header[5] + i * header[9]) for i in range(header[10])]
    if any(segment[1] + segment[4] > len(data) for segment in segments):
        raise ValueError("Invalid program segment")
    end = max(segment[1] + segment[4] for segment in segments)
    if not 52 <= end <= header[6] <= len(data):
        raise ValueError("Debug sections overlap program content")
    candidate = bytearray(data[:end])
    struct.pack_into("<I", candidate, 32, 0)
    struct.pack_into("<HHH", candidate, 46, 0, 0, 0)
    if candidate[52:] != data[52:end] or any(marker in candidate for marker in (b"/Users/", b"/Development/NES")):
        raise ValueError("Private paths or changed program content")
    if hashlib.sha256(candidate).hexdigest() != EXPECTED:
        raise ValueError("Writer does not match the reviewed research copy")
    return bytes(candidate)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python3 reproduce_tested_writer.py SOURCE_ELF NEW_OUTPUT")
    source, output = map(Path, sys.argv[1:])
    with source.open("rb") as stream:
        data = stream.read(MAXIMUM_BYTES + 1)
    candidate = normalized(data)
    descriptor, temporary = tempfile.mkstemp(prefix=".snes-writer-", dir=output.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(candidate)
            stream.flush()
            os.fchmod(stream.fileno(), 0o500)
            os.fsync(stream.fileno())
        os.link(temporary, output)
    finally:
        os.unlink(temporary)
    print("Created research-only writer; console firmware use is not authorized.")


if __name__ == "__main__":
    main()
