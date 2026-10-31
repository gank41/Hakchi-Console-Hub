import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESCloverMenuTextTests {
    @Test func libraryExportAvoidsMCPNumericEscapeAmbiguityWithoutEditingTheMacSource() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (originalReview, originals) = try fixture.fixture(root, count: 1)
        let template = try #require(originalReview.rows.first?.game)
        let path = root.appendingPathComponent(template.code + "/" + template.code + ".desktop")
        let metadata = Data("[Desktop Entry]\nName=Madden NFL '94\n[X-CLOVER Game]\nPlayers=1\nReleaseDate=1993-10-01\nSortRawPublisher=Publisher '01\nCopyright=Studio '93\n".utf8)
        try metadata.write(to: path)
        var game = Game(code: template.code, desktopContent: String(decoding: metadata, as: UTF8.self), consoleType: .snesUsa, source: .local)
        game.romPath = template.romPath
        let review = try SNESLibraryCompatibility.review(games: [game], originals: originals)
        let menu = try fixture.menu(review, originals).withNativeArtwork()
        let desktop = try #require(menu.files["pages/001/\(game.code)/\(game.code).desktop"])
        let fields = try SNESOneGameMenu.fields(desktop)
        #expect(fields["name"] == "Madden NFL ’94")
        #expect(fields["sortrawpublisher"] == "Publisher ’01")
        #expect(fields["copyright"] == "Studio ’93")
        #expect(game.name == "Madden NFL '94")
        #expect(try Data(contentsOf: path) == metadata)
        try menu.validate()
    }
    @Test func aNewRestoreNormalizesLegacyMenuTextWithoutChangingItsBackup() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try SNESLibraryCompatibilityTests().originals()
        let metadata = Data(String(decoding: oneGameMetadata, as: UTF8.self).replacingOccurrences(of: "My Arkanoid – Édition", with: "Madden NFL '94").utf8)
        let legacy = try SNESOneGameMenu.prepare(originals: originals, code: "CLV-U-ABCDE", metadata: metadata,
            rom: oneGameSyntheticROM(), artwork: oneGameSyntheticArt())
        let saved = try await SNESLibraryRestoreTests().backup(root, originals: originals, legacy: legacy)
        let restored = try #require(try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: saved.inventory.hwid).menu)
        let path = "pages/000/CLV-U-ABCDE/CLV-U-ABCDE.desktop"
        #expect(try SNESOneGameMenu.fields(#require(restored.files[path]))["name"] == "Madden NFL ’94")
        #expect(try SNESOneGameMenu.fields(saved.read(path: "legacy/menus/\(legacy.id.uuidString)/games/CLV-U-ABCDE/CLV-U-ABCDE.desktop"))["name"] == "Madden NFL '94")
        try saved.validate()
    }

    @Test func frozenNativeMenusStayExactWhileANewRestoreGetsSafeText() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryMaterialTests(), (review, originals) = try fixture.fixture(root, count: 1)
        let original = try fixture.menu(review, originals).withNativeArtwork()
        let path = "pages/001/CLV-U-A0001/CLV-U-A0001.desktop"
        var files = original.files
        let bytes = try #require(files[path])
        files[path] = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Name=Imported 1", with: "Name=Madden NFL '94").utf8)
        let m = original.description
        let records = m.files.map { r in SNESLibraryMenu.FileRecord(path: r.path, byteCount: files[r.path]!.count, sha256: BackupManifest.digest(files[r.path]!)) }
        let manifest = SNESLibraryMenu.Manifest(version: m.version, id: m.id, catalogSHA256: m.catalogSHA256, graph: m.graph,
            structure: m.structure, order: m.order, objects: m.objects, files: records, stock: m.stock, placements: m.placements)
        let unsafe = SNESLibraryMenu(description: manifest, files: files, objects: original.objects, sources: [],
            manifest: try SNESLibraryMenu.encode(manifest), sourceSHA256: BackupManifest.digest(try SNESLibraryMenu.encode([SNESLibrarySourceFile]())))
        try unsafe.validate()
        let material = try SNESLibraryMaterial.freeze(menu: unsafe, in: root)
        let reopened = try SNESLibraryMaterial.load(directory: material.directory, expectedReviewSHA256: material.reviewSHA256)
        #expect(reopened.menu.files[path] == files[path]) // Recovery must not silently rewrite approved evidence.
        let saved = try await SNESLibraryRestoreTests().backup(root, originals: originals, menu: reopened.menu)
        let restored = try #require(try SNESLibraryRestore.prepare(backup: saved, originals: originals, expectedHWID: saved.inventory.hwid).menu)
        #expect(try SNESOneGameMenu.fields(#require(restored.files[path]))["name"] == "Madden NFL ’94")
        #expect(try SNESOneGameMenu.fields(saved.read(path: "menus/\(unsafe.id.uuidString)/" + path))["name"] == "Madden NFL '94")
    }

    @Test func allDigitYearsAreSafeAndOrdinaryApostrophesStayUnchanged() throws {
        let cases = (0...9).map { ("Season '\($0)4", "Season ’\($0)4") } + [
            ("Dragon's Lair", "Dragon's Lair"), ("Rock 'n Roll", "Rock 'n Roll"), ("Already ’94", "Already ’94")]
        for (input, expected) in cases {
            let raw = Data("[Desktop Entry]\nName=\(input)\n[X-CLOVER Game]\nSortRawTitle=\(input)\nSortRawPublisher=\(input)\nCopyright=\(input)\n".utf8)
            let result = try SNESLibraryMenu.cloverDesktop(raw), fields = try SNESOneGameMenu.fields(result)
            for key in ["name", "sortrawtitle", "sortrawpublisher", "copyright"] { #expect(fields[key] == expected) }
            #expect(try SNESLibraryMenu.cloverDesktop(result) == result)
        }
    }

    @Test func transformedByteLimitsAndControlRejectionStayEnforced() throws {
        func desktop(_ name: String) -> Data { Data("[Desktop Entry]\nName=\(name)\n[X-CLOVER Game]\nCopyright=\n".utf8) }
        let accepted = try SNESLibraryMenu.cloverDesktop(desktop(String(repeating: "A", count: 252) + "'9"))
        #expect(try SNESOneGameMenu.fields(accepted)["name"]?.utf8.count == 256)
        #expect(throws: (any Error).self) { try SNESLibraryMenu.cloverDesktop(desktop(String(repeating: "A", count: 253) + "'9")) }
        #expect(throws: (any Error).self) { try SNESLibraryMenu.cloverDesktop(desktop("Bad\u{0085}'94")) }
    }

}
