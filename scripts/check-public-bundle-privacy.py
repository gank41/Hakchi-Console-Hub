#!/usr/bin/env python3
"""Scan every regular file in a public app bundle as raw bytes.

Pass known device identifiers in a private --literal-file. This check is not a
substitute for reviewing the app, resources, provenance, and license.
"""
import argparse
import ctypes
import hashlib
import io
import os
from pathlib import Path
import re
import sys
import tarfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=Path, help='packaged .app to inspect')
parser.add_argument('--literal', action='append', default=[], help='known sensitive identifier (prefer --literal-file to avoid process listings)')
parser.add_argument('--literal-file', type=Path, action='append', default=[], help='UTF-8 file containing one known identifier per line')
args = parser.parse_args()
if not args.bundle.is_dir() or args.bundle.is_symlink():
    parser.error('bundle must be an existing, non-symlink directory')
for literal_file in args.literal_file:
    try:
        values = literal_file.read_text(encoding='utf-8').splitlines()
    except (OSError, UnicodeError):
        parser.error('cannot read a supplied literal file')
    if not values or any(not value for value in values):
        parser.error('literal file must contain nonempty identifiers')
    args.literal.extend(values)
if not args.literal:
    parser.error('supply all known sensitive identifiers using --literal or --literal-file')
if any(not value for value in args.literal):
    parser.error('--literal must not be empty')
patterns = [
    ('home path', re.compile(rb'/(?:Users|home)/[A-Za-z0-9._-]+/[^\x00\r\n\t ]*')),
    ('MAC address', re.compile(rb'(?i)(?<![0-9a-f])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])')),
]
for value in args.literal:
    patterns.append(('literal UTF-8', re.compile(re.escape(value.encode('utf-8')))))
    patterns.append(('literal UTF-16LE', re.compile(re.escape(value.encode('utf-16le')))))
    if re.fullmatch(r'(?:[0-9a-fA-F]{8}){4,}', value):
        raw = bytes.fromhex(value)
        words = [raw[i:i + 4] for i in range(0, len(raw), 4)]
        variants = {
            'original': raw,
            'reversed word order': b''.join(reversed(words)),
            'reversed bytes per word': b''.join(word[::-1] for word in words),
            'reversed words and bytes': b''.join(word[::-1] for word in reversed(words)),
        }
        for variant, data in variants.items():
            patterns.append((f'hex identifier ({variant})', re.compile(re.escape(data.hex().encode('ascii')), re.IGNORECASE)))
            patterns.append((f'raw identifier ({variant})', re.compile(re.escape(data))))
def path_matches(relative):
    encoded = ('/' + str(relative)).encode('utf-8', errors='surrogateescape')
    return [(label, match.start()) for label, pattern in patterns
            for match in pattern.finditer(encoded)]


def visible_path(relative):
    return '<sensitive-path>' if path_matches(relative) else str(relative)


def potential_game_or_save(name):
    return Path(name).suffix.lower() in {'.nes', '.sfc', '.smc', '.srm', '.sav', '.state'}


def read_xattrs(path):
    if hasattr(os, 'listxattr'):
        return [(os.fsencode(name), os.getxattr(path, name, follow_symlinks=False))
                for name in os.listxattr(path, follow_symlinks=False)]
    if sys.platform != 'darwin':
        raise OSError('extended attribute APIs unavailable')
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.restype = ctypes.c_ssize_t
    path_bytes = os.fsencode(path)

    def checked(result):
        if result < 0:
            raise OSError(ctypes.get_errno(), 'extended attribute read failed')
        return result

    size = checked(libc.listxattr(path_bytes, None, 0, 1))  # XATTR_NOFOLLOW
    if size == 0:
        return []
    names_buffer = ctypes.create_string_buffer(size)
    actual = checked(libc.listxattr(path_bytes, names_buffer, size, 1))
    names = names_buffer.raw[:actual].split(b'\0')
    result = []
    for name in filter(None, names):
        size = checked(libc.getxattr(path_bytes, name, None, 0, 0, 1))
        value_buffer = ctypes.create_string_buffer(size)
        actual = checked(libc.getxattr(path_bytes, name, value_buffer, size, 0, 1))
        result.append((name, value_buffer.raw[:actual]))
    return result


def inspect_xattrs(path, relative):
    findings = 0
    try:
        for name, value in read_xattrs(path):
            attributes = [('name', name), ('value', value)]
            for part, data in attributes:
                for label, pattern in patterns:
                    for match in pattern.finditer(data):
                        print(f'XATTR {part} ({label}) {visible_path(relative)} offset={match.start()}')
                        findings += 1
    except OSError:
        print(f'XATTR READ ERROR {visible_path(relative)}', file=sys.stderr)
        findings += 1
    return findings


# Inspect recognized bundled archives without extracting their paths. Limits
# make malformed or unexpectedly large archives fail closed instead of making
# a release check exhaust memory. Other formats still require manual review.
ARCHIVE_MEMBER_LIMIT = 64 * 1024 * 1024
ARCHIVE_TOTAL_LIMIT = 256 * 1024 * 1024
ARCHIVE_DEPTH_LIMIT = 4
archive_expanded_bytes = 0

# These byte-identical artifacts contain previously reviewed upstream build or
# documentation paths. This exception applies only to the generic home-path
# heuristic in the exact archive member, never to user-supplied identifiers or
# other checks. See PUBLIC-RELEASE-PRIVACY.md for provenance and limitations.
REVIEWED_UPSTREAM_HOME_PATHS = {
    ('003994b46504959895f40b0b9e91b16951ef4a638feb6312314c8fc4fdbff592',
     'lib/modules/3.4.113.29-madmonkey/extra/mali.ko',
     'fd33317b37e0cd495541029ad6534b0e8759e6e1e41d67cc2393d4dcfb0c764c'),
    ('7d2d2a21c2c00e6c5a83c8b51c18fccb6a9b3764584aa5ceb4b231e3a7c0ab6c',
     'snes9x2010-fe690dd321fa5a46b5234a2bde089d2518c62b0e/docs/tile-renderer-state.md',
     '5c266f2cdc8aa7aae2fff27300cdaf1d8987132c92299028a6535d196c08bc2d'),
}


def inspect_archive(data, relative, depth=0):
    global archive_expanded_bytes
    name = str(relative).lower()
    is_zip = zipfile.is_zipfile(io.BytesIO(data))
    is_tar = name.endswith(('.tar', '.tar.gz', '.tgz', '.hmod'))
    if not is_zip and not is_tar:
        return 0
    if depth >= ARCHIVE_DEPTH_LIMIT:
        print(f'ARCHIVE DEPTH LIMIT {visible_path(relative)}', file=sys.stderr)
        return 1
    findings = 0
    archive_digest = hashlib.sha256(data).hexdigest() if depth == 0 else None

    def inspect_member(member_name, payload, regular):
        member_path = Path(str(relative) + '!' + member_name)
        count = 0
        reviewed_home_paths = regular and (archive_digest, member_name, hashlib.sha256(payload).hexdigest()) in REVIEWED_UPSTREAM_HOME_PATHS
        if potential_game_or_save(member_name):
            print(f'POTENTIAL GAME OR SAVE {visible_path(member_path)}')
            count += 1
        for label, offset in path_matches(member_path):
            print(f'ARCHIVE PATH MATCH ({label}) <sensitive-path> offset={offset}')
            count += 1
        for label, pattern in patterns:
            for match in pattern.finditer(payload):
                if label == 'home path' and reviewed_home_paths:
                    continue
                print(f'ARCHIVE {label} {visible_path(member_path)} offset={match.start()}')
                count += 1
        return count + (inspect_archive(payload, member_path, depth + 1) if regular else 0)

    try:
        with (zipfile.ZipFile(io.BytesIO(data)) if is_zip else
              tarfile.open(fileobj=io.BytesIO(data), mode='r:*')) as archive:
            members = archive.infolist() if is_zip else archive
            for member in members:
                member_name = member.filename if is_zip else member.name
                size = member.file_size if is_zip else member.size
                archive_expanded_bytes += size
                if size > ARCHIVE_MEMBER_LIMIT or archive_expanded_bytes > ARCHIVE_TOTAL_LIMIT:
                    raise ValueError('archive size limit')
                if is_zip:
                    regular = not member.is_dir()
                    payload = archive.read(member) if regular else b''
                elif member.isfile():
                    regular = True
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise ValueError('unreadable member')
                    payload = stream.read(ARCHIVE_MEMBER_LIMIT + 1)
                    if len(payload) != size:
                        raise ValueError('invalid member size')
                else:
                    regular = False
                    payload = member.linkname.encode('utf-8', errors='surrogateescape') if member.issym() or member.islnk() else b''
                findings += inspect_member(member_name, payload, regular)
    except (OSError, ValueError, RuntimeError, EOFError, UnicodeError, NotImplementedError, tarfile.TarError, zipfile.BadZipFile):
        print(f'ARCHIVE READ ERROR {visible_path(relative)}', file=sys.stderr)
        findings += 1
    return findings


issues = inspect_xattrs(args.bundle, Path('.'))
walk_errors = []
for root, dirs, files in os.walk(args.bundle, followlinks=False, onerror=walk_errors.append):
    for name in dirs + files:
        path = Path(root) / name
        relative = path.relative_to(args.bundle)
        for label, offset in path_matches(relative):
            print(f'PATH NAME MATCH ({label}) <sensitive-path> offset={offset}')
            issues += 1
        if path.is_symlink():
            print(f'SYMLINK {visible_path(relative)}')
            issues += 1
        else:
            issues += inspect_xattrs(path, relative)
        if name == 'GameGenieCatalogs' and path.is_dir():
            print(f'PERSONAL CATALOG DIRECTORY {visible_path(relative)}')
            issues += 1
    for name in files:
        path = Path(root) / name
        if path.is_symlink():
            continue
        if potential_game_or_save(name):
            print(f'POTENTIAL GAME OR SAVE {visible_path(path.relative_to(args.bundle))}')
            issues += 1
        if not path.is_file():
            print(f'NOT A REGULAR FILE {visible_path(path.relative_to(args.bundle))}', file=sys.stderr)
            issues += 1
            continue
        try:
            data = path.read_bytes()
        except OSError:
            print(f'READ ERROR {visible_path(path.relative_to(args.bundle))}', file=sys.stderr)
            issues += 1
            continue
        for label, pattern in patterns:
            for match in pattern.finditer(data):
                print(f'{label} {visible_path(path.relative_to(args.bundle))} offset={match.start()}')
                issues += 1
        issues += inspect_archive(data, path.relative_to(args.bundle))
for error in walk_errors:
    try:
        relative = Path(error.filename).relative_to(args.bundle) if error.filename else Path('.')
    except ValueError:
        relative = Path('.')
    print(f'WALK ERROR {visible_path(relative)}', file=sys.stderr)
    issues += 1
print(f'Privacy scan: {issues} finding(s). Review source, resource provenance, ROMs, and other identifiers separately.')
sys.exit(1 if issues else 0)
