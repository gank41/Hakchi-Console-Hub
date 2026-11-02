# Hakchi Console Hub

A work-in-progress macOS app for managing classic mini-console libraries, built with Swift and SwiftUI. This project continues [Swift Hakchi2](https://github.com/mattackerman808/swift-hakchi2), a native macOS rewrite inspired by [Hakchi2 CE](https://github.com/TeamShinkansen/Hakchi2-CE).

> **Development preview:** Some functions require a console that has already been modified. First-time console setup and recovery are not generally available in this preview. Read the status below before making changes to a device.

## Supported consoles and status

| Console | Current status |
| --- | --- |
| NES Classic (USA) | Library management and synchronization have been exercised on one already-modified console. Other devices, layouts and first-time installation need further testing. |
| SNES Classic (USA) | Native game synchronization has been exercised on one prepared console. General first-time setup, other devices and restoration still need independent validation. |
| Famicom Mini, Super Famicom Mini, European models | Library and console choices exist, but hardware operations are not generally verified. |
| Sega Genesis / Mega Drive Mini | Library support is experimental; console setup and synchronization are not ready. |

Games requiring an additional SNES compatibility emulator **cannot yet be synced through the app**. Temporary gameplay and save tests have been performed, but the launcher, persistent save recovery and normal synchronization are not complete. No per-game compatibility is guaranteed.

## Features

- Import game files into a local library, edit metadata and artwork, and organize console menus into folders.
- Review supported NES and SNES sync operations, space requirements, duplicates and backups before applying changes to a recognized, prepared console.
- Search for game metadata and artwork using supported providers.
- Manage cheat codes and create a separate patched game copy where supported. Cheat availability and patching vary by platform and game.
- Review available console restore options. Their availability depends on the console, its setup and verified recovery files.

Firmware installation, memboot, and some recovery and module operations are disabled or limited in this preview. Third-party downloaded cheat-code catalogs are not bundled in this source snapshot; users can supply their own catalog where supported. The app does not include personal game files, console backups, or save data. Obtain your own games and keep your own backups.

## Requirements

- Apple silicon Mac running macOS 14 or later, and a compatible USB connection to the console. The current downloadable preview is Apple silicon only.
- To build from source: Xcode with a recent Swift toolchain; Swift 6 / Xcode 16 or newer is recommended for the test suite. Internet access is needed to resolve Swift Package Manager dependencies on the first build.

## Download

Download the DMG from the [0.2.1 preview release](https://github.com/gank41/Hakchi-Console-Hub/releases/tag/v0.2.1-preview), open it, and drag Hakchi Console Hub into Applications. The preview is experimental: read the console status above before connecting or changing a console.

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

Some screens and tools remain experimental. Do not use the app to install firmware on an untested device or assume that every game, save format, accessory or console revision is supported.

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
