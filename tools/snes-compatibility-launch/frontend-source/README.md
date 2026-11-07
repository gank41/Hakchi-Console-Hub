# Experimental SNES frontend source

The bundled ARM frontend is an experimental RetroArch 1.7.0 build based on
commit `0a2b44273da17d1b2372cd16469bb74791f7ac95`, with four source files
modified for save reporting and file-close handling. The bundled binary was
rebuilt with compiler file-prefix mapping to remove local development paths;
it has not been verified on a console. The unchanged source
archive is `RetroArch-1.7.0.tar.gz`; the patch is at
`SwiftHakchi/Resources/SNESCompatibilityFrontend/frontend.patch`.

Run `python3 tools/snes-compatibility-launch/frontend-source/verify-source.py`
from the repository root to verify the archive and reconstruct the four
reviewed source files in a temporary directory. This checks source integrity;
it does not build the frontend or verify it on a console.

`configure-arguments.json` records the configure arguments and target used for
the experimental build. Rebuilding also requires a compatible ARM toolchain,
headers and link sysroot; a portable, independently verified rebuild recipe is
still needed. The upstream GPL license is included with the app resource and
in `SwiftHakchi/Resources/ThirdPartyLicenses/RetroArch-GPLv3.txt`.

This material does not enable installation, compatibility sync or gameplay.
