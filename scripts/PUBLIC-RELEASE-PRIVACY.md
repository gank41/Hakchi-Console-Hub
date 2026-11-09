# Public release build privacy check

`scripts/build-app.sh release` strips Mach-O debug symbols from the packaged
main executable, and the assistant build does the same to its packaged helper.
This happens before ad-hoc signing. It leaves SwiftPM build products and dSYMs
intact: do not distribute those or other build caches without separate review.
Debug builds of the main app retain their debug symbols.

To use isolated output and an independent SwiftPM cache, set absolute paths in
`SWIFTHAKCHI_BUILD_ROOT` and `SWIFTHAKCHI_SCRATCH_PATH`. The latter must already
contain SwiftPM's `workspace-state.json`, `checkouts`, and `repositories`, as
required to build the assistant without resolving dependencies. For example,
copy those three items from an existing resolved cache to a new scratch
location. The assistant has its own build cache inside the chosen build root.
Setting `SWIFTHAKCHI_BUILD_ROOT` also prevents changing the default launcher
symlink. `SWIFTHAKCHI_DISABLE_SWIFTPM_SANDBOX=1` is available for restricted
build environments. `SWIFTHAKCHI_SWIFT_BUILD_SYSTEM=native` can select SwiftPM’s
native build engine on toolchains that support it; the normal SwiftPM default
remains unchanged. Do not set `SWIFTHAKCHI_PERSONAL_CATALOGS` for public builds.

For a public DMG, use the wrapper with a private identifiers file. The wrapper
copies the app into a private staging directory, clears extended attributes
without following symlinks, checks that none remain, scans that exact copy, and
only then passes it to the DMG builder. `scripts/build-dmg.sh` by itself is
for private/local packaging and does not perform this check:

```sh
scripts/build-public-dmg.sh "/path/to/Hakchi Console Hub.app" \
  /path/to/private-identifiers.txt
```

To scan a bundle without creating a DMG:

```sh
python3 scripts/check-public-bundle-privacy.py "/path/to/Hakchi Console Hub.app" \
  --literal-file /path/to/private-identifiers.txt
```

Use a private file with one known sensitive serial, identifier, or path per
line. At least one identifier must be supplied; include every known value.
The `--literal` option is also available, but command-line arguments may appear
in process listings, so prefer the private file. The
scanner reads complete files as bytes, including symbol tables. It reports
common ASCII macOS/Linux home paths, colon-form MAC addresses, supplied UTF-8 and UTF-16LE
literals, raw and case-insensitive hex identifiers (at least 16 bytes, in four-byte words), including reversed word order and byte order within words, symlinks, and personal catalog directories. It also checks entry names and extended attribute names and values, and hides
locations containing matching identifiers. It also inspects ZIP files and
recognized tar archives (including `.tar.gz`, `.tgz` and `.hmod`) without
extracting them to disk. Nested archives are scanned within size and depth
limits. Common NES/SNES ROM and save filename extensions are flagged. The
scanner fails if extended attributes or recognized archives cannot be read.
It exits nonzero for any finding or unreadable file. It prints each finding’s category, bundle-relative
location, and byte offset without printing the matched bytes. File names and
locations themselves may still be sensitive, so share output with care. A clean scan does not establish that no other
identifiers, personal data, ROMs, or unlicensed content are present. Other
archive formats and identifier encodings need separate inspection. Review the
source and packaged resources separately, including archive contents,
and inspect the final distribution image after creation. The ad-hoc signed app is not Developer ID signed or
notarized.

### Reviewed upstream home-path references

The scanner disregards only generic home-path matches inside two specific
archive members when both the complete archive and member bytes match the
hard-coded SHA-256 values in the scanner. It still scans those bytes and all
other archive members for supplied identifiers and all other finding types.
Changes to either archive fail closed into ordinary scanning; updating an
artifact requires a new provenance and privacy review. This is not a license
or redistribution approval.

* `hakchi.hmod`, SHA-256 `003994b46504959895f40b0b9e91b16951ef4a638feb6312314c8fc4fdbff592`,
  contains 27 build-path matches in `lib/modules/3.4.113.29-madmonkey/extra/mali.ko`
  (member SHA-256 `fd33317b37e0cd495541029ad6534b0e8759e6e1e41d67cc2393d4dcfb0c764c`).
  The archive matches the locally stored `coloboxp/swift-hakchi2` upstream Git
  checkout at commit `863be80fac70bf7bed2f3e1ade9dfb7ebc900418`.
* Snes9x 2010 `source.tar.gz`, SHA-256 `7d2d2a21c2c00e6c5a83c8b51c18fccb6a9b3764584aa5ceb4b231e3a7c0ab6c`,
  contains four documentation path matches in
  `snes9x2010-fe690dd321fa5a46b5234a2bde089d2518c62b0e/docs/tile-renderer-state.md`
  (member SHA-256 `5c266f2cdc8aa7aae2fff27300cdaf1d8987132c92299028a6535d196c08bc2d`).
  The member's Git blob `4d288b210b6967eb40f36291543434374b402c67`
  matches the public `libretro/snes9x2010` repository at the pinned commit.
  The whole archive also matches the previously recorded source archive pin;
  this member comparison does not independently validate the rest of the archive.
