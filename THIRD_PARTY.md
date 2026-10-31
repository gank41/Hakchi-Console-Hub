# Third-party material and publication review

This file records known provenance. It is not a grant of rights or a completed redistribution audit.

- **Upstream project:** [mattackerman808/swift-hakchi2](https://github.com/mattackerman808/swift-hakchi2). The public repository did not show a project-level license at the time of review. Confirm the applicable terms with its maintainer before distributing derivatives outside the permissions granted by the relevant platform terms. No new project-wide license is asserted in this snapshot.
- **Inherited console-support payloads:** `SwiftHakchi/Resources/fes1.bin`, `hakchi.hmod`, and `basehmods.tar` match the upstream checkout byte for byte. Their individual contents and redistribution terms require review. These are upstream support files, not backups captured from a console; their presence must not be interpreted as a completed licensing review.
- **Mbed TLS 3.6.2:** vendored sources in `vendor/mbedtls`; upstream license text in `vendor/mbedtls/LICENSE`. Individual source headers state the applicable license choices.
- **libssh2 1.11.1:** vendored sources in `vendor/libssh2`; upstream license text in `vendor/libssh2/COPYING`.
- **miniLZO / LZO1X-999 2.10:** GPL-2.0-or-later notices and source provenance are retained in `vendor/minilzo/` and `SwiftHakchi/Resources/ThirdPartyLicenses/`. Review the obligations for the combined distribution.
- **Libretro Database-derived Genesis metadata:** CC BY-SA 4.0; attribution, source revision and the full license are retained in `SwiftHakchi/Resources/ThirdPartyLicenses/`.
- **Swift packages:** `Package.resolved` identifies SWCompression and BitByteData. They are fetched from their upstream repositories at build time; check their licenses and notices for distribution.
- **Icons and cheat-code artwork:** the app includes platform-inspired artwork in `SwiftHakchi/Resources/AppIcons/`, `AppIcon.icns`, and `SwiftHakchi/Resources/CheatCodes/`. Confirm their provenance and permission for public distribution, including any third-party marks or images.
- **Game-code catalogs:** personal downloads and website source data are not included in this public-source snapshot. Verify redistribution permission before adding any third-party catalog to a release.

Before publishing, review all bundled binary and media contents, the upstream project's terms, all dependency notices and any generated release package. Do not include game ROMs, original console images, saves, backups, private keys, personal libraries, or hardware identifiers.
