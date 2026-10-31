import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryRestoreTests {
    func backup(_ root: URL, originals: SNESOriginalGamesFrame, menu: SNESLibraryMenu? = nil, legacy: SNESOneGameMenu? = nil, builtinSelectorMode: Int? = nil) async throws -> SNESLibraryBackup {
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), catalog = try SNESLibraryCatalogIdentity.digest(originals)
        var payloads: [String: Data] = ["clover/settings.json": Data("{}".utf8)]
        var raw: Data
        if let legacy {
            let selector = Data("SWIFTHAKCHI_SNES_MENU_SELECTOR_V1\n\(legacy.id.uuidString)\n\(legacy.treeSHA256)\n".utf8)
            payloads["legacy/active-menu"] = selector
            payloads["legacy/menus/\(legacy.id.uuidString)/menu.manifest"] = legacy.manifest
            for (name, data) in legacy.files { payloads["legacy/menus/\(legacy.id.uuidString)/" + name] = data }
            var rows = ["SWIFTHAKCHI_SNES_LIBRARY_INVENTORY_V1 " + nonce.uuidString, "CONTEXT " + fixture.context, "HWID " + fixture.hwid,
                "CATALOG " + catalog, "SPACE 4096 76800 64000", "NAMESPACE absent absent",
                "SELECTOR legacy \(legacy.id.uuidString) \(legacy.treeSHA256) \(BackupManifest.digest(selector))",
                "MENU legacy \(legacy.id.uuidString) \(legacy.treeSHA256) \(legacy.manifest.count) 0 -", "DIR 636c6f766572 448"]
            for (index, path) in payloads.keys.sorted().enumerated() {
                let data = try #require(payloads[path])
                rows.append("FILE \(fixture.hex(path)) \(data.count) \(BackupManifest.digest(data)) 384 0 1 \(index+1) 0")
            }
            raw = Data((rows.joined(separator: "\n") + "\nEND\n").utf8)
        } else {
            raw = Data(String(decoding: try fixture.frame(challenge: nonce, menu: menu), as: UTF8.self).replacingOccurrences(of: "CATALOG " + fixture.catalog, with: "CATALOG " + catalog).utf8)
            if let menu {
                payloads["active-menu"] = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(BackupManifest.digest(try SNESLibraryStartupScripts.manifest(for: menu)))\n".utf8)
                payloads["descriptions/\(menu.id.uuidString).json"] = menu.manifest
                payloads["menus/\(menu.id.uuidString)/menu.manifest"] = try SNESLibraryStartupScripts.manifest(for: menu)
                for (path, data) in menu.files { payloads["menus/\(menu.id.uuidString)/" + path] = data }
                for (path, data) in menu.objects { payloads["objects/" + path] = data }
            }
        }
        if let mode = builtinSelectorMode {
            let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nBUILTIN\n".utf8)
            payloads["active-menu"] = selector
            var rows = String(decoding: raw, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "END" }
            rows = rows.map { $0.hasPrefix("NAMESPACE ") ? "NAMESPACE ready ready" : ($0.hasPrefix("SELECTOR ") ? "SELECTOR builtin - - \(BackupManifest.digest(selector))" : $0) }
            rows.append("FILE \(fixture.hex("active-menu")) \(selector.count) \(BackupManifest.digest(selector)) \(mode) 0 1 999 0")
            rows.append("END"); raw = Data((rows.joined(separator: "\n") + "\n").utf8)
        }
        let inventory = try SNESLibraryInventory(raw: raw, challenge: nonce, contextSHA256: fixture.context, hwid: fixture.hwid, catalogSHA256: catalog)
        let captured = payloads
        return try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { file, offset in
            let data = try #require(captured[file.path]); return Data(data[offset..<min(offset + SNESLibraryBackupChunk.maximumBytes, data.count)])
        }, refresh: { inventory })
    }
    @Test func libraryRestoreRetainsLayoutObjectsAndSavesWithoutOriginalMacFiles() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root), menu = try fixture.menu(review, originals)
        let saved = try await backup(root, originals: originals, menu: menu)
        for directory in Set(menu.sources.map(\.directory)) { try FileManager.default.removeItem(at: URL(fileURLWithPath: directory)) }
        let anotherCapture = UUID()
        let recaptured = try SNESOriginalGamesFrame(originalGamesFrameFixture(challenge: anotherCapture), binding: originalGamesBinding(), challenge: anotherCapture)
        let id = UUID(), restored = try SNESLibraryRestore.prepare(backup: saved, originals: recaptured, expectedHWID: SNESLibraryInventoryTests().hwid, id: id)
        let next = try #require(restored.menu)
        #expect(next.id == id && next.graph == menu.graph && next.description.structure == menu.description.structure)
        #expect(next.objects == menu.objects && next.files == menu.files && next.sources.isEmpty)
        #expect(try saved.read(path: "clover/settings.json") == Data("{}".utf8))
        let material = try SNESLibraryMaterial.freeze(menu: next, in: root)
        try material.validate()
        #expect(throws: (any Error).self) { try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: String(repeating: "2", count: 32)) }
    }
    @Test func originalOneGameSnapshotMigratesToIndependentContentObjects() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try SNESOriginalGamesFrame(originalGamesFrameFixture(), binding: originalGamesBinding(), challenge: originalGamesChallenge)
        let legacy = try SNESOneGameMenu.prepare(originals: originals, code: "CLV-U-ABCDE", metadata: oneGameMetadata,
            rom: oneGameSyntheticROM(), artwork: oneGameSyntheticArt())
        let saved = try await backup(root, originals: originals, legacy: legacy)
        let restored = try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: SNESLibraryInventoryTests().hwid)
        let menu = try #require(restored.menu); try menu.validate()
        #expect(menu.graph.screens.flatMap(\.gameCodes).count == legacy.gameCount)
        #expect(menu.objects.values.contains(try #require(legacy.files["games/CLV-U-ABCDE/CLV-U-ABCDE.sfrom"])))
        let desktop = try #require(menu.files["pages/000/CLV-U-ABCDE/CLV-U-ABCDE.desktop"])
        #expect(String(decoding: desktop, as: UTF8.self).contains("Name=My Arkanoid – Édition"))
        #expect(!String(decoding: desktop, as: UTF8.self).contains("snes-v1/"))
        for (path, raw) in menu.files where path.contains("/CLV-P-") {
            let text = String(decoding: raw, as: UTF8.self)
            #expect(text.contains("SortRawTitle="), "Restored built-in menu entries must use the console's actual key spelling")
            #expect(!text.contains("\nsortrawtitle="))
        }
        #expect(menu.sources.isEmpty)
    }
    @Test func builtInOnlyBackupIsAnExplicitBuiltInSelection() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try SNESOriginalGamesFrame(originalGamesFrameFixture(), binding: originalGamesBinding(), challenge: originalGamesChallenge)
        let saved = try await backup(root, originals: originals)
        #expect(try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: SNESLibraryInventoryTests().hwid).menu == nil)
    }
}
