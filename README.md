# Hakchi Console Hub

This is a work-in-progress Apple Silicon macOS app for managing classic mini-consoles & libraries, built with Swift and SwiftUI. This project continues [Swift Hakchi2](https://github.com/mattackerman808/swift-hakchi2), a native macOS rewrite inspired by [Hakchi2 CE](https://github.com/TeamShinkansen/Hakchi2-CE).

Hakchi Console Hub is a GitHub fork of Swift Hakchi2. Hakchi2 CE is a community fork of [ClusterM's original Hakchi2](https://github.com/ClusterM/hakchi2). These are separate GitHub fork networks, and we credit both the original project and the projects that continued its work.

> **Development preview — use at your own risk:** An originally unmodified US SNES Classic was prepared and games were added during supervised development. This preview includes newer setup and recovery tools, but the complete first-time app workflow has not yet been independently verified on a fresh console. Keep backups in a safe place and review the limitations below before making changes.

## What is new in 0.2.3

- Clearer SNES sync steps, with a more visible progress indicator and simpler explanations of backups, restarting and cleanup.
- Cheat-code improvements, including a separate editable copy for supported included SNES games and refreshed NES cheat-code artwork.
- An experimental faster SNES file check ran from memory on one console, but folder navigation still felt slow. It is not installed automatically; further work is needed.

## Supported consoles and status

| Console | Current status |
| --- | --- |
| NES Classic (USA) | The Mac library can be organized. Sync, backup, saved-menu restore and cleanup currently depend on a specific development console and are not generally available to other NES owners. First-time setup is not validated. |
| SNES Classic (USA) | A stock console was prepared during supervised development; added games, folders, artwork and native sync worked on that console. The app includes guided setup, backup and recovery steps, but the complete first-time and replacement-console workflows have not been verified end to end on separate stock hardware. |
| Famicom Mini, Super Famicom Mini, European models | Library and console choices exist, but hardware operations are not generally verified. |
| Sega Genesis / Mega Drive Mini | Library support is experimental; console setup and synchronization are not ready. |

Games requiring an additional SNES compatibility emulator **cannot yet be synced through the app**. Temporary gameplay and save tests have been performed, but the launcher, persistent save recovery and normal synchronization are not complete. No per-game compatibility is guaranteed.

Consoles of the same model generally follow the same basic process, but the app still needs to recognize the connected device and its current software and backup. Regional models, software changes and previously modified consoles can require different handling. The testing above describes what has actually been exercised so far; it is not a separate procedure invented for each individual console.

## Features

- Import game files into a local library, edit metadata and artwork, and organize console menus into folders.
- Review supported SNES sync operations, space requirements, duplicates and backups before applying changes to a recognized, prepared console. NES device operations remain restricted as described below.
- Search for game metadata and artwork using supported providers.
- Manage cheat codes and create a separate patched game copy where supported. Cheat availability and patching vary by platform and game.
- Review available console restore options. Their availability depends on the console, its setup and verified recovery files.
- Copy and verify a library backup to another folder or drive, including added game files and saved data captured in that backup. Review the experimental replacement-console options separately; copying a backup does not itself restore a console.
- Choose simpler instructions or show more detail, check for app updates, and export diagnostic logs for troubleshooting.

Firmware installation, memboot, and some recovery and module operations are disabled or limited in this preview. Third-party downloaded cheat-code catalogs are not bundled in this source snapshot; users can supply their own catalog where supported. The app does not include personal game files, console backups, or save data. Obtain your own games and keep your own backups.

## Current limitations

- **First-time setup:** SNES setup steps are available for review, but the full app-led process still needs end-to-end testing on another stock console. A startup backup is not necessarily original stock software if the console was previously modified. First-time NES setup has not been validated.
- **Backups and recovery:** A verified library backup can be copied to another Mac. Restoring games and progress to a replacement SNES remains experimental and has not been tested between two physical consoles; not all save layouts are supported. A complete SNES data-snapshot restore and factory-like reset are not implemented. Startup-software recovery is separate from library and save restoration. Preserve each console's own recovery files.
- **NES device-specific operations:** Sync, backup verification, saved-menu restore and cleanup are tied to a development console and do not generally work for other NES owners in this preview. First-time firmware setup has not been validated on an unmodified NES. Do not treat the earlier hardware test as validation for other consoles.
- **Other console models:** Genesis / Mega Drive setup and synchronization are not ready; Famicom, Super Famicom and European hardware operations need further verification.
- **Additional emulators:** Games requiring the experimental SNES compatibility emulator cannot yet be synced through the app. Module management and some other advanced tools are incomplete.

## Requirements

- Apple silicon Mac running macOS 14 or later, and a compatible USB connection to the console. The current downloadable preview is Apple silicon only.
- To build from source: Xcode with a recent Swift toolchain; Swift 6 / Xcode 16 or newer is recommended for the test suite. Internet access is needed to resolve Swift Package Manager dependencies on the first build.

## Download

The preview installers are temporarily unavailable while privacy issues are addressed. A corrected installer will be posted when ready. The preview is experimental: read the console status above before connecting or changing a console.

This preview is not signed with a Developer ID and has not been notarized by Apple. macOS may block it or display an unidentified-developer warning. See [Apple's guidance for opening apps safely](https://support.apple.com/102445) before deciding whether to open it. The preview does not contain game ROMs or personal cheat-code catalogs.

## Build from source

```sh
swift build
swift test
./scripts/build-app.sh release
```

Open `Package.swift` in Xcode if you prefer. The packaging script creates an ad-hoc-signed local app under `Builds/` and prints its path. It does not publish a release or connect to a console. Locally built apps are not automatically notarized.

For a fresh configuration, the default workspace is `~/Library/Application Support/Hakchi Console Hub/`. Games and backups are kept in its subfolders; choose another location in Settings if desired. Existing configurations retain their chosen paths. A build may download the open-source Swift dependencies listed in `Package.resolved`.

## Usage

1. Add your own game files with **Add Game Files** and review their metadata and artwork.
2. Select the appropriate console library. Connect a recognized, already-prepared console when you are ready to review a supported sync.
3. Review the proposed games, folder structure, compatibility messages and backup before proceeding. Follow the app's staged instructions and test the updated menu before finishing a sync.
4. Keep recovery files in a safe location. Do not assume that a backup from a different console or region is suitable for yours.

See the [quick-start guide](docs/QUICK-START.md) and the [replacement-console notes](docs/SNES-REPLACEMENT-CONSOLE-MIGRATION.md) for more detail about backups and current limitations.

Some screens and tools remain experimental. Use the preview at your own risk, keep your backups, and check the current status for your console and the features you want to try.

## How it works

The app uses USB recovery and management protocols to inspect compatible consoles, prepare backups and perform supported operations. Some workflows use temporary recovery images; supported game syncs use staged copies and a review before switching menus. The app keeps a local library and console recovery data on the Mac.

## Project structure

```text
SwiftHakchi/       SwiftUI app, models, services and resources
SwiftHakchiCore/   Shared formats and preparation logic
USBBridge/         Native USB and communication bridge
vendor/            Vendored C dependencies
Tests/             Unit and integration tests
scripts/           Local build and packaging scripts
tools/             Console-side tooling and experiments
```

## License and attribution

This preview retains third-party notices, including the LZO and Libretro Database notices in `SwiftHakchi/Resources/ThirdPartyLicenses/` and license files under `vendor/`. The source snapshot also retains binary support payloads inherited from the original Swift Hakchi2 repository.

The upstream Swift Hakchi2 repository did not show a project-level license when this preview was prepared. No new project-wide license has been assumed. Review the upstream project's licensing, binary payloads, third-party artwork, and dependency obligations before publishing or distributing this snapshot. See [THIRD_PARTY.md](THIRD_PARTY.md).

This project is not affiliated with Nintendo or Sega.
