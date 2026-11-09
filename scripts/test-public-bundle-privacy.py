#!/usr/bin/env python3
"""Regression checks for public bundle privacy scanning."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import io
import tarfile
import zipfile
import re
import shutil

scanner = Path(__file__).with_name('check-public-bundle-privacy.py')
with tempfile.TemporaryDirectory(prefix='privacy-scan-test-') as directory:
    root = Path(directory)
    bundle = root / 'Test.app'
    helper = bundle / 'Contents/Helpers/Helper.app/Contents/MacOS'
    helper.mkdir(parents=True)
    identity = '0123456789abcdef1234567890abcdef'
    home_path = '/Users/privacy-test-person/secret-path'
    mac_address = 'AA:BB:CC:DD:EE:FF'
    raw = bytes.fromhex(identity)
    words = [raw[i:i+4] for i in range(0, len(raw), 4)]
    binary = b'\0'.join([home_path.encode(), identity.encode(), mac_address.encode(),
                         raw, b''.join(reversed(words)),
                         b''.join(word[::-1] for word in words), raw[::-1]])
    (helper / 'Helper').write_bytes(binary)
    (helper / identity).write_bytes(b'safe payload')
    (helper / 'link').symlink_to(home_path)
    if sys.platform == 'darwin':
        subprocess.run(['/usr/bin/xattr', '-w', 'com.example.privacy-test', identity, str(helper / 'Helper')], check=True)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.example.' + identity, 'example', str(helper / 'Helper')], check=True)
    literals = root / 'identifiers.txt'
    literals.write_text(identity + '\n' + home_path + '\n')
    result = subprocess.run([sys.executable, str(scanner), str(bundle), '--literal-file', str(literals)],
                            capture_output=True, text=True, check=False)
    output = result.stdout + result.stderr
    assert result.returncode == 1, output
    for label in ('home path', 'MAC address', 'literal UTF-8', 'raw identifier (original)',
                  'raw identifier (reversed word order)', 'raw identifier (reversed bytes per word)',
                  'raw identifier (reversed words and bytes)', 'PATH NAME MATCH', '<sensitive-path>',
                  'SYMLINK', 'offset=', 'Contents/Helpers/Helper.app'):
        assert label in output, (label, output)
    if sys.platform == 'darwin':
        assert 'XATTR name' in output and 'XATTR value' in output, output
        copy = root / 'metadata-free-copy'
        subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', str(helper / 'Helper'), str(copy)], check=True)
        subprocess.run(['/usr/bin/xattr', '-cs', str(copy)], check=True)
        attr = subprocess.run(['/usr/bin/xattr', '-p', 'com.example.privacy-test', str(copy)], capture_output=True)
        assert attr.returncode != 0, 'metadata-free copy retained the synthetic xattr'
        external = root / 'external'
        external.write_text('external')
        subprocess.run(['/usr/bin/xattr', '-w', 'com.example.privacy-test', 'synthetic', str(external)], check=True)
        tree = root / 'tree'
        tree.mkdir()
        (tree / 'link').symlink_to(external)
        subprocess.run(['/usr/bin/xattr', '-crs', str(tree)], check=True)
        attr = subprocess.run(['/usr/bin/xattr', '-p', 'com.example.privacy-test', str(external)], capture_output=True)
        assert attr.returncode == 0, 'metadata clearing followed a symlink'
    for secret in (identity, home_path, mac_address):
        assert secret not in output, f'scanner exposed a sensitive value: {secret}'
    no_identifiers = subprocess.run([sys.executable, str(scanner), str(bundle)], capture_output=True, text=True)
    assert no_identifiers.returncode != 0
    missing_file = subprocess.run([sys.executable, str(scanner), str(bundle), '--literal-file', str(root/'missing')],
                                  capture_output=True, text=True)
    assert missing_file.returncode != 0
    clean = root / 'Clean.app'
    clean.mkdir()
    clean_result = subprocess.run([sys.executable, str(scanner), str(clean), '--literal-file', str(literals)],
                                  capture_output=True, text=True)
    assert clean_result.returncode == 0, clean_result.stderr

    # Compressed bundled resources must not conceal personal data in file
    # contents or member names, including an archive inside another archive.
    archived = root / 'Archived.app'
    archived.mkdir()
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('nested.txt', identity)
    with tarfile.open(archived / 'resources.tar.gz', 'w:gz') as tar:
        data = inner.getvalue()
        member = tarfile.TarInfo('nested.zip')
        member.size = len(data)
        tar.addfile(member, io.BytesIO(data))
        member = tarfile.TarInfo('name-' + identity)
        member.size = 0
        tar.addfile(member, io.BytesIO(b''))
    archive_result = subprocess.run([sys.executable, str(scanner), str(archived), '--literal-file', str(literals)],
                                    capture_output=True, text=True)
    assert archive_result.returncode == 1, archive_result.stdout + archive_result.stderr
    assert 'ARCHIVE' in archive_result.stdout, archive_result.stdout
    assert identity not in archive_result.stdout + archive_result.stderr
    archive_with_directory = root / 'Directory.app'
    archive_with_directory.mkdir()
    with tarfile.open(archive_with_directory / 'modules.tar', 'w') as tar:
        member = tarfile.TarInfo('module.hmod')
        member.type = tarfile.DIRTYPE
        tar.addfile(member)
    directory_result = subprocess.run([sys.executable, str(scanner), str(archive_with_directory), '--literal-file', str(literals)],
                                      capture_output=True, text=True)
    assert directory_result.returncode == 0, directory_result.stdout + directory_result.stderr
    malformed = root / 'Malformed.app'
    malformed.mkdir()
    (malformed / 'broken.tar.gz').write_bytes(b'not a real archive')
    malformed_result = subprocess.run([sys.executable, str(scanner), str(malformed), '--literal-file', str(literals)],
                                      capture_output=True, text=True)
    assert malformed_result.returncode == 1 and 'ARCHIVE READ ERROR' in malformed_result.stderr
    game = root / 'Game.app'
    game.mkdir()
    (game / 'example.sfc').write_bytes(b'synthetic game content')
    game_result = subprocess.run([sys.executable, str(scanner), str(game), '--literal-file', str(literals)],
                                 capture_output=True, text=True)
    assert game_result.returncode == 1 and 'POTENTIAL GAME OR SAVE' in game_result.stdout
    (game / 'example.sfc').unlink()
    with zipfile.ZipFile(game / 'games.zip', 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('folder/example.sfc', b'synthetic game content')
    game_archive_result = subprocess.run([sys.executable, str(scanner), str(game), '--literal-file', str(literals)],
                                         capture_output=True, text=True)
    assert game_archive_result.returncode == 1 and 'POTENTIAL GAME OR SAVE' in game_archive_result.stdout

    # Only reviewed upstream home-path findings may be disregarded. Supplying
    # an actual matching value as a private literal must still block the scan.
    resources = Path(__file__).resolve().parent.parent / 'SwiftHakchi/Resources'
    upstream = root / 'Upstream.app'
    upstream.mkdir()
    for source, name, member in (
        (resources / 'hakchi.hmod', 'hakchi.hmod', 'lib/modules/3.4.113.29-madmonkey/extra/mali.ko'),
        (resources / 'SNESCompatibilityCore/source.tar.gz', 'source.tar.gz',
         'snes9x2010-fe690dd321fa5a46b5234a2bde089d2518c62b0e/docs/tile-renderer-state.md'),
    ):
        target = upstream / name
        shutil.copyfile(source, target)
        reviewed = subprocess.run([sys.executable, str(scanner), str(upstream), '--literal', 'synthetic-never-present-privacy-marker'],
                                  capture_output=True, text=True)
        assert reviewed.returncode == 0, reviewed.stdout + reviewed.stderr
        with tarfile.open(source, 'r:*') as archive:
            payload = archive.extractfile(member).read()
        match = re.search(rb'/(?:Users|home)/[A-Za-z0-9._-]+/[^\x00\r\n\t ]*', payload)
        assert match is not None
        private = root / 'private-literal'
        private.write_bytes(match.group() + b'\n')
        identified = subprocess.run([sys.executable, str(scanner), str(upstream), '--literal-file', str(private)],
                                    capture_output=True, text=True)
        assert identified.returncode == 1 and 'literal UTF-8' in identified.stdout
        assert match.group().decode() not in identified.stdout + identified.stderr
        with target.open('ab') as stream:
            stream.write(b'changed')
        modified = subprocess.run([sys.executable, str(scanner), str(upstream), '--literal', 'synthetic-never-present-privacy-marker'],
                                  capture_output=True, text=True)
        assert modified.returncode == 1 and 'ARCHIVE home path' in modified.stdout
        target.unlink()

    # Both failing paths must stop before invoking the private DMG builder.
    wrapper = Path(__file__).with_name('build-public-dmg.sh')
    fake_bin = root / 'bin'
    fake_bin.mkdir()
    invoked = root / 'hdiutil-invoked'
    fake_hdiutil = fake_bin / 'hdiutil'
    fake_hdiutil.write_text('#!/bin/sh\ntouch "$PRIVACY_TEST_HDIUTIL_INVOKED"\n')
    fake_hdiutil.chmod(0o755)
    env = os.environ.copy()
    env['PATH'] = str(fake_bin) + os.pathsep + env.get('PATH', '')
    env['PRIVACY_TEST_HDIUTIL_INVOKED'] = str(invoked)
    for identifier_file in (root / 'missing', literals):
        result = subprocess.run(['bash', '-x', str(wrapper), str(bundle), str(identifier_file)],
                                capture_output=True, text=True, env=env)
        assert result.returncode != 0
        assert 'scripts/build-dmg.sh ' not in result.stderr, result.stderr
        assert not invoked.exists()
        for secret in (identity, home_path, mac_address):
            assert secret not in result.stdout + result.stderr
print('Privacy scanner regression checks passed.')
