import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryStartupScriptsTests {
    @Test(arguments: ["valid", "valid-smc", "valid-smc-header", "wrong-game", "wrong-helper", "wrong-kind", "changed-object"])
    func offlineCompatibilityVerifierChecksTheWholeMenu(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (menu, originals, code) = try await MainActor.run {
            let (firstReview, originals) = try SNESLibraryMaterialTests().fixture(root)
            var initial = firstReview
            if fault == "valid", let source = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_SOURCE_ROM"] {
                let game = firstReview.rows[0].game, destination = URL(fileURLWithPath: game.romPath).appendingPathComponent(game.code + ".sfc")
                guard URL(fileURLWithPath: source).pathExtension.lowercased() == "sfc" else { throw SNESLibraryMenu.failure() }
                try Data(contentsOf: URL(fileURLWithPath: source)).write(to: destination)
                initial = try SNESLibraryCompatibility.review(games: firstReview.rows.map(\.game), originals: originals)
            }
            if fault == "valid-smc" || fault == "valid-smc-header" {
                let game = firstReview.rows[0].game, directory = URL(fileURLWithPath: game.romPath)
                let source = directory.appendingPathComponent(game.code + ".sfc"), dest = directory.appendingPathComponent(game.code + ".smc")
                if fault == "valid-smc-header" {
                    try (Data(repeating: 0, count: 512) + Data(contentsOf: source)).write(to: dest)
                    try FileManager.default.removeItem(at: source)
                } else { try FileManager.default.moveItem(at: source, to: dest) }
                initial = try SNESLibraryCompatibility.review(games: firstReview.rows.map(\.game), originals: originals)
            }
            let first = initial.rows[0]
            let compat = SNESLibraryCompatibility.Row(game: first.game, source: first.source, prepared: nil,
                issue: "Needs support", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge)
            let review = SNESLibraryCompatibility(rows: [compat, initial.rows[1]], stockCodes: initial.stockCodes)
            let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: SNESLibraryObjectCache.prepare(review: review),
                selected: Set(review.rows.map { $0.game.code }), structure: .init(mode: .stockRootPagesEqual), order: .title)
            let art = SNESLibraryMenu.NavigationArtwork(more: oneGameSyntheticArt(), back: oneGameSyntheticArt(), custom: [:])
            let candidate = try draft.compatibilityMenuCandidate(sessions: [first.game.code: Data([7] + Array(repeating: 0, count: 15))], epoch: 4, artwork: art)
            return (try candidate.withNativeArtwork(), originals, first.game.code)
        }
        let namespace = root.appendingPathComponent("console"), base = namespace.appendingPathComponent("menus/" + menu.id.uuidString)
        func put(_ url: URL, _ data: Data) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for (name, data) in menu.files { try put(base.appendingPathComponent(name), data) }
        for (name, data) in menu.objects { try put(namespace.appendingPathComponent("objects/" + name), data) }
        let stockRoot = root.appendingPathComponent("stock")
        for entry in originals.entries {
            for file in entry.files where file.name.hasSuffix(".desktop") { try put(stockRoot.appendingPathComponent(entry.code + "/" + file.name), file.data) }
        }
        var manifest = try SNESLibraryStartupScripts.compatibilityCandidateManifest(for: menu)
        let placement = try #require(menu.description.placements.first { $0.code == code })
        let desktop = String(format: "pages/%03d/%@/%@.desktop", placement.page, code, code)
        if fault == "wrong-game" || fault == "wrong-helper" {
            let original = try #require(menu.files[desktop]), text = String(decoding: original, as: UTF8.self)
            let modified = fault == "wrong-game" ? text.replacingOccurrences(of: "--game " + code, with: "--game CLV-U-ZZZZZ") : text.replacingOccurrences(of: "/mnt/swifthakchi/hc-snes-superv", with: "/mnt/swifthakchi/unverified")
            #expect(modified != text)
            let bytes = Data(modified.utf8); try put(base.appendingPathComponent(desktop), bytes)
            let before = "FILE \(desktop) \(original.count) \(BackupManifest.digest(original))"
            let after = "FILE \(desktop) \(bytes.count) \(BackupManifest.digest(bytes))"
            let value = String(decoding: manifest, as: UTF8.self); #expect(value.contains(before)); manifest = Data(value.replacingOccurrences(of: before, with: after).utf8)
        } else if fault == "wrong-kind" {
            let before = " \(code) compat ", value = String(decoding: manifest, as: UTF8.self)
            #expect(value.contains(before)); manifest = Data(value.replacingOccurrences(of: before, with: " \(code) import ").utf8)
        } else if fault == "changed-object" {
            let rom = try #require(placement.rom), bytes = try #require(menu.objects[rom])
            var changed = bytes; changed[0] ^= 1; try put(namespace.appendingPathComponent("objects/" + rom), changed)
        }
        try put(base.appendingPathComponent("menu.manifest"), manifest)
        let selector = namespace.appendingPathComponent("active-menu")
        try put(selector, Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(BackupManifest.digest(manifest))\n".utf8))
        let bb = root.appendingPathComponent("busybox")
        try put(bb, Data("""
        #!/bin/sh
        case "$1" in
          stat) case "$3" in '%h') /usr/bin/stat -f '%l' "$4";; '%u') echo 0;; '%s') /usr/bin/stat -f '%z' "$4";; *) exit 97;; esac;;
          *) exec "$@";;
        esac
        """.utf8)); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bb.path)
        let script = try SNESLibraryStartupScripts.experimentalCompatibilityVerifier().replacingOccurrences(of: "/mnt/swifthakchi/busybox", with: bb.path)
            .replacingOccurrences(of: SNESLibraryMenu.namespace, with: namespace.path).replacingOccurrences(of: "/usr/share/games", with: stockRoot.path)
            .replacingOccurrences(of: #"icon="$N/objects/$art""#, with: #"icon=""# + SNESLibraryMenu.namespace + #"/objects/$art""#)
            .replacingOccurrences(of: #"icon="$large""#, with: #"icon=""# + SNESLibraryMenu.namespace + #"/menus/$id/pages/$page/$code/$code.png""#)
            .replacingOccurrences(of: "-v kind=\"$kind\" -v code=\"$code\" -v root=\"$N/objects/\"", with: "-v kind=\"$kind\" -v code=\"$code\" -v root=\"" + SNESLibraryMenu.namespace + "/objects/\"")
        let file = root.appendingPathComponent("verify.sh"); try put(file, Data(script.utf8))
        let process = Process(), output = Pipe(), error = Pipe(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]; process.standardOutput = output; process.standardError = error
        try process.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(), stderr = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if ["valid", "valid-smc", "valid-smc-header"].contains(fault) { #expect(process.terminationStatus == 0, "\(String(decoding: stderr, as: UTF8.self))"); #expect(String(decoding: stdout, as: UTF8.self) == base.path + "/pages/000\n") }
        else { #expect(process.terminationStatus != 0) }
        if fault == "valid", let execPath = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_EXEC_FIXTURE"],
           let romPath = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_ROM_FIXTURE"] {
            guard process.terminationStatus == 0, String(decoding: stdout, as: UTF8.self) == base.path + "/pages/000\n" else { throw SNESLibraryMenu.failure() }
            let entry = try #require(menu.description.placements.first { $0.code == code })
            let romName = try #require(entry.rom)
            let desktopData = try #require(menu.files[desktop])
            let exec = try #require(SNESOneGameMenu.fields(desktopData)["exec"])
            try Data(exec.utf8).write(to: URL(fileURLWithPath: execPath), options: .atomic)
            try #require(menu.objects[romName]).write(to: URL(fileURLWithPath: romPath), options: .atomic)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_TEST_READONLY_SNES_PARALLEL_VERIFIER"] == "1"))
    @MainActor func liveParallelCandidateReadsCurrentMenuWithoutInstallingIt() async throws {
        try RecoveryProbeUSBRegistry.requireOrdinaryAppClosed()
        let devices = try RecoveryProbeUSBRegistry.inventory()
        guard devices.count == 1, let device = devices.first, ConsoleAttachmentPolicy.kind(of: device) == .nativeSNES else { throw SNESLibraryMenu.failure() }
        let client = LegacyInspectionClient()
        try await client.connect(timeoutMilliseconds: 5000)
        do {
            let result = try await client.readSNESParallelVerifierCandidate()
            await client.disconnect()
            #expect(result.succeeded)
            #expect(result.stderr.isEmpty)
            let value = String(decoding: result.stdoutData, as: UTF8.self)
            #expect(value == "/usr/share/games\n" || (value.hasPrefix("/var/lib/swifthakchi/snes-v2/menus/") && value.hasSuffix("/pages/000\n")))
        } catch {
            await client.disconnect()
            throw error
        }
    }
    @Test func oldStartupRecipeRemainsByteExact() {
        #expect(BackupManifest.digest(Data(SNESLibraryStartupScripts.verifier.utf8)) == "92c5438b38bcc8e89382b6d333ebacc62683a4ace42e4e44abc3c5ced5f2ddae")
        #expect(BackupManifest.digest(Data(SNESLibraryStartupScripts.legacyVerifier.utf8)) == "cac56e7005ad94bec9b99162c4090c8c761241973ceb1e8920361e96af42ab00")
        #expect(BackupManifest.digest(Data(SNESLibraryStartupScripts.legacyArtworkVerifier.utf8)) == "d45187b4a8029bb303ac5691cb0e7fbcb4a4df50497fb61afc9fb76acc0bcfe0")
    }

    @Test(arguments: ["valid", "large", "decimal-pages", "inactive", "builtin", "missing", "changed", "linked", "hardlink", "extra", "object", "selector", "path", "duplicate", "target"])
    func onlyACompleteBoundedMenuCanReachStartup(_ fault: String) async throws {
        try await checkNativeMenu(fault, experimental: false)
    }
    @Test(arguments: ["valid", "large", "decimal-pages", "builtin", "changed", "path"])
    func experimentalVerifierKeepsNativeMenusAndRejectsDamage(_ fault: String) async throws {
        try await checkNativeMenu(fault, experimental: true)
    }
    @Test(arguments: ["valid", "inactive", "builtin", "missing", "changed", "linked", "hardlink", "extra", "object", "selector", "path", "duplicate", "target", "worker-producer-failure", "worker-checksum-failure", "worker-manifest-change"])
    func parallelVerifierCandidateRetainsNativeMenuSafety(_ fault: String) async throws {
        try await checkNativeMenu(fault, experimental: false, parallel: true)
    }
    private func checkNativeMenu(_ fault: String, experimental: Bool, parallel: Bool = false) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (menu, originals) = try await MainActor.run {
            let helper = SNESLibraryMaterialTests(), (review, originals) = try helper.fixture(root, count: fault == "decimal-pages" ? 220 : fault == "large" ? 70 : 2)
            let menu = try fault == "decimal-pages" ? SNESLibraryMenu.prepare(review:review, originals:originals, selected:Set(review.rows.map { $0.game.code }), decisions:[:], order:.title, structure:.init(mode:.stockRootPagesEqual,maximumGamesPerPage:.twenty), artwork:.init(more:oneGameSyntheticArt(),back:oneGameSyntheticArt(),custom:[:])):helper.menu(review, originals)
            return (menu, originals)
        }
        let namespace = root.appendingPathComponent("console"), base = namespace.appendingPathComponent("menus/" + menu.id.uuidString)
        func put(_ url: URL, _ data: Data) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for (name, data) in menu.files { try put(base.appendingPathComponent(name), data) }
        for (name, data) in menu.objects { try put(namespace.appendingPathComponent("objects/" + name), data) }
        let stockRoot = root.appendingPathComponent("stock")
        for entry in originals.entries {
            for file in entry.files where file.name.hasSuffix(".desktop") { try put(stockRoot.appendingPathComponent(entry.code + "/" + file.name), file.data) }
        }
        var manifest = try SNESLibraryStartupScripts.manifest(for: menu)
        let first = try #require(menu.description.files.first)
        let target = base.appendingPathComponent(first.path)
        switch fault {
        case "missing": try FileManager.default.removeItem(at: target)
        case "changed": try Data("Name=Wrong\n".utf8).write(to: target)
        case "linked": try FileManager.default.removeItem(at: target); try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("outside"))
        case "hardlink": try FileManager.default.linkItem(at: target, to: root.appendingPathComponent("outside"))
        case "extra": try put(base.appendingPathComponent("pages/000/extra"), Data([0]))
        case "object": try FileManager.default.removeItem(at: namespace.appendingPathComponent("objects/" + menu.objectRecords[0].name))
        case "path": manifest = Data(String(decoding: manifest, as: UTF8.self).replacingOccurrences(of: first.path, with: "pages/../escape").utf8)
        case "duplicate": manifest.append(Data("ENTRY 000 000 CLV-U-A0001 import - - - -\n".utf8))
        case "target": manifest = Data(String(decoding: manifest, as: UTF8.self).replacingOccurrences(of: "CLV-S-00001 link 001", with: "CLV-S-00001 link 999").utf8)
        default: break
        }
        try put(base.appendingPathComponent("menu.manifest"), manifest)
        if let path = ProcessInfo.processInfo.environment[fault == "decimal-pages" ? "SWIFTHAKCHI_SNES_LIBRARY_DECIMAL_EXPORT":"SWIFTHAKCHI_SNES_LIBRARY_EXPORT"], ["valid", "decimal-pages"].contains(fault) {
            let destination = URL(fileURLWithPath: path)
            let stocks = Dictionary(uniqueKeysWithValues: originals.entries.flatMap { entry in
                entry.files.filter { $0.name.hasSuffix(".desktop") }.map { (entry.code + "/" + $0.name, $0.data.base64EncodedString()) }
            })
            let fixture: [String: Any] = ["id": menu.id.uuidString, "manifest": manifest.base64EncodedString(),
                "files": menu.files.mapValues { $0.base64EncodedString() }, "objects": menu.objects.mapValues { $0.base64EncodedString() }, "stock": stocks]
            try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: destination.appendingPathComponent("fixture.json"))
            try Data(SNESLibraryStartupScripts.verifier.utf8).write(to: destination.appendingPathComponent("verify.sh"))
        }
        let hash = BackupManifest.digest(manifest), selector = namespace.appendingPathComponent("active-menu")
        var selection = "SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(hash)\n"
        if fault == "builtin" { selection = "SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n" }
        if fault == "selector" { selection += "extra\n" }
        try put(selector, Data(selection.utf8))
        let bb = root.appendingPathComponent("busybox")
        let shim = """
        #!/bin/sh
        if test "${HC_FAIL_WORKER:-}" = producer && test "$1" = awk; then
          for arg in "$@"; do test "$arg" != part=2 || exit 88; done
        fi
        if test "${HC_FAIL_WORKER:-}" = checksum && test "$1" = sha256sum && test "${2:-}" = -c; then exit 89; fi
        if test "${HC_FAIL_WORKER:-}" = manifest-change && test "$1" = sha256sum && test "${2:-}" = -c; then printf x >> "$HC_TEST_MANIFEST"; fi
        case "$1" in
          stat) case "$3" in '%h') /usr/bin/stat -f '%l' "$4";; '%u') echo 0;; '%s') /usr/bin/stat -f '%z' "$4";; *) exit 97;; esac;;
          *) exec "$@";;
        esac
        """
        try put(bb, Data(shim.utf8)); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bb.path)
        let source = try parallel ? SNESLibraryStartupScripts.parallelChecksumVerifierCandidate() : (experimental ? SNESLibraryStartupScripts.experimentalCompatibilityVerifier() : SNESLibraryStartupScripts.verifier)
        let script = source.replacingOccurrences(of: "/mnt/swifthakchi/busybox", with: bb.path)
            .replacingOccurrences(of: SNESLibraryMenu.namespace, with: namespace.path).replacingOccurrences(of: "/usr/share/games", with: stockRoot.path)
            .replacingOccurrences(of: #"icon="$N/objects/$art""#, with: #"icon=""# + SNESLibraryMenu.namespace + #"/objects/$art""#)
            .replacingOccurrences(of: #"icon="$large""#, with: #"icon=""# + SNESLibraryMenu.namespace + #"/menus/$id/pages/$page/$code/$code.png""#)
            // Files live in a host sandbox; their generated console commands keep the canonical native paths.
            .replacingOccurrences(of: "-v kind=\"$kind\" -v code=\"$code\" -v root=\"$N/objects/\"",
                                  with: "-v kind=\"$kind\" -v code=\"$code\" -v root=\"" + SNESLibraryMenu.namespace + "/objects/\"")
        let file = root.appendingPathComponent("verify.sh"); try put(file, Data(script.utf8))
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path] + (fault == "inactive" ? [menu.id.uuidString, hash] : [])
        if fault.hasPrefix("worker-") {
            let failure = fault == "worker-producer-failure" ? "producer" : (fault == "worker-manifest-change" ? "manifest-change" : "checksum")
            process.environment = ProcessInfo.processInfo.environment.merging(["HC_FAIL_WORKER": failure, "HC_TEST_MANIFEST": base.appendingPathComponent("menu.manifest").path]) { _, new in new }
        }
        process.standardOutput = output; process.standardError = error
        try process.run(); let stdout = output.fileHandleForReading.readDataToEndOfFile(), stderr = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(try Data(contentsOf: selector) == Data(selection.utf8))
        if ["valid", "large", "decimal-pages", "inactive", "builtin"].contains(fault) {
            #expect(process.terminationStatus == 0, "\(String(decoding: stderr, as: UTF8.self))")
            #expect(String(decoding: stdout, as: UTF8.self) == (fault == "builtin" ? stockRoot.path : base.path + "/pages/000") + "\n")
        } else { #expect(process.terminationStatus != 0) }
    }
}
