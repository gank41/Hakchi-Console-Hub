import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryMaterialTests {
    func fixture(_ root: URL, count: Int = 2, romBytes: Int = 65536) throws -> (SNESLibraryCompatibility, SNESOriginalGamesFrame) {
        let originals = try SNESLibraryCompatibilityTests().originals()
        let games = try (1...count).map { number -> Game in
            let code = String(format: "CLV-U-A%04d", number)
            let directory = root.appendingPathComponent(code)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let metadata = "[Desktop Entry]\nName=Imported \(number)\nExec=/untrusted\n[X-CLOVER Game]\nPlayers=1\nReleaseDate=1997-01-01\nSortRawTitle=imported \(number)\n"
            try Data(metadata.utf8).write(to: directory.appendingPathComponent(code + ".desktop"))
            try oneGameSyntheticROM(byteCount: romBytes).write(to: directory.appendingPathComponent(code + ".sfc"))
            try oneGameSyntheticArt().write(to: directory.appendingPathComponent(code + ".png"))
            var game = Game(code: code, desktopContent: metadata, consoleType: .snesUsa, source: .local)
            game.romPath = directory.path
            return game
        }
        return (try SNESLibraryCompatibility.review(games: games, originals: originals), originals)
    }
    func menu(_ review: SNESLibraryCompatibility, _ originals: SNESOriginalGamesFrame,
              mode: ConsoleStructure.Mode = .stockRootPagesEqual, id: UUID = UUID()) throws -> SNESLibraryMenu {
        try .prepare(review: review, originals: originals, selected: Set(review.rows.map { $0.game.code }),
            decisions: [:], order: .title, structure: .init(mode: mode, maximumGamesPerPage: .thirtyFive),
            artwork: .init(more: oneGameSyntheticArt(), back: oneGameSyntheticArt(), custom: [:]), id: id)
    }
    @Test func sharedContentIsStoredOnceAndMetadataOrLayoutDoesNotChangeROMObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root)
        let first = try menu(review, originals)
        #expect(first.objects.keys.filter { $0.hasSuffix(".sfrom") }.count == 1)
        #expect(first.graph.screens[0].gameCodes == originals.entries.map(\.code))
        #expect(first.graph.screens[1].gameCodes.count == 2)
        #expect(first.graph.screens.flatMap(\.gameCodes).count == 4)
        let desktop = try #require(first.files["pages/001/CLV-U-A0001/CLV-U-A0001.desktop"])
        let text = String(decoding: desktop, as: UTF8.self)
        #expect(!text.contains("/untrusted"))
        #expect(text.contains("Path=/var/lib/clover/profiles/0/CLV-U-A0001"))
        #expect(text.contains("-rom /var/lib/swifthakchi/snes-v2/objects/"))
        let path = root.appendingPathComponent("CLV-U-A0001/CLV-U-A0001.desktop")
        let changed = String(decoding: try Data(contentsOf: path), as: UTF8.self).replacingOccurrences(of: "Imported 1", with: "Updated title")
        try Data(changed.utf8).write(to: path)
        var games = review.rows.map(\.game); games[0].name = "Updated title"
        let edited = try SNESLibraryCompatibility.review(games: games, originals: originals)
        let next = try menu(edited, originals, mode: .foldersEqual)
        #expect(Set(first.objects.keys) == Set(next.objects.keys))
        #expect(first.manifest != next.manifest)
        #expect(first.sourceSHA256 != next.sourceSHA256)
    }
    @Test(arguments: ConsoleStructure.Mode.allCases.filter { $0 != .custom })
    func everyLayoutKeepsEachGameExactlyOnce(_ mode: ConsoleStructure.Mode) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root, count: mode == .flat ? 2 : 36)
        let prepared = try menu(review, originals, mode: mode)
        let codes = prepared.graph.screens.flatMap(\.gameCodes)
        #expect(Set(codes).count == codes.count && codes.count == review.rows.count + 2)
        for page in prepared.graph.screens {
            for link in page.links {
                let key = String(format: "pages/%03d/%@/%@.desktop", page.number, link.consoleCode, link.consoleCode)
                let text = String(decoding: try #require(prepared.files[key]), as: UTF8.self)
                #expect(text.contains("Exec=/mnt/swifthakchi/menu-change " + String(format: "%03d", link.target)))
            }
        }
    }
    @Test func capacityCountsOnlyMissingObjectsAndRejectsStaleOrInvalidMeasurements() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root), prepared = try menu(review, originals)
        let now = Date(), identity = String(repeating: "a", count: 64)
        let full = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: identity, freeBytes: 100_000_000, blockSize: 4096, objects: [:])
        let first = try SNESLibraryCapacity.project(menu: prepared, inventory: full, expectedContext: identity, now: now)
        let existing = prepared.objectRecords.reduce(into: [String: SNESLibraryObjects.Record]()) { $0[$1.name] = $1 }
        let reused = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: identity, freeBytes: full.freeBytes, blockSize: 4096, objects: existing, namespaceReady: true)
        let next = try SNESLibraryCapacity.project(menu: prepared, inventory: reused, expectedContext: identity, now: now)
        #expect(next.newObjectBytes == 0 && next.neededToCopy < first.neededToCopy && first.canFit)
        #expect(first.freeAfterFinishing == full.freeBytes - first.newAllocatedBytes)
        #expect(throws: (any Error).self) { try SNESLibraryCapacity.project(menu: prepared, inventory: nil, expectedContext: identity, now: now) }
        #expect(throws: (any Error).self) { try SNESLibraryCapacity.project(menu: prepared, inventory: full, expectedContext: identity, now: now.addingTimeInterval(61)) }
        let small = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: identity, freeBytes: 0, blockSize: 4096, objects: [:])
        #expect(try !SNESLibraryCapacity.project(menu: prepared, inventory: small, expectedContext: identity, now: now).canFit)
        let invalid = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: identity, freeBytes: .max, blockSize: .max, objects: [:])
        #expect(throws: (any Error).self) { try SNESLibraryCapacity.project(menu: prepared, inventory: invalid, expectedContext: identity, now: now) }
    }
    @Test func capacityIncludesWireManifestAndIndependentRestoreDescription() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root), prepared = try menu(review, originals)
        let now = Date(), context = String(repeating: "a", count: 64), block: Int64 = 4096
        let live = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: context, freeBytes: 100_000_000, blockSize: block, objects: [:])
        let result = try SNESLibraryCapacity.project(menu: prepared, inventory: live, expectedContext: context, now: now)
        func allocated(_ bytes: Int) -> Int64 { ((Int64(bytes) + block - 1) / block) * block }
        let objects = prepared.objectRecords.reduce(Int64(0)) { $0 + allocated($1.byteCount) }
        let files = prepared.description.files.reduce(Int64(0)) { $0 + allocated($1.byteCount) }
        let wire = try SNESLibraryStartupScripts.manifest(for: prepared)
        let dirs = Int64(7 + prepared.graph.screens.count + prepared.description.files.count) * block
        #expect(result.newAllocatedBytes == objects + files + allocated(wire.count) + allocated(prepared.manifest.count) + dirs)
    }
    @Test func frozenPackageRejectsChangedSourcesExtraFilesAndLinkedContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root), prepared = try menu(review, originals)
        let package = try SNESLibraryMaterial.freeze(menu: prepared, in: root)
        #expect(try SNESLibraryMaterial.load(directory: package.directory, expectedReviewSHA256: package.reviewSHA256).menu.manifest == prepared.manifest)
        let extra = package.directory.appendingPathComponent("extra")
        try Data([1]).write(to: extra)
        #expect(throws: (any Error).self) { try package.validate() }
        try FileManager.default.removeItem(at: extra)
        let object = package.directory.appendingPathComponent("object-" + prepared.objectRecords[0].name)
        let bytes = try Data(contentsOf: object), target = root.appendingPathComponent("external")
        try bytes.write(to: target); try FileManager.default.removeItem(at: object)
        try FileManager.default.createSymbolicLink(at: object, withDestinationURL: target)
        #expect(throws: (any Error).self) { try package.validate() }
        try FileManager.default.removeItem(at: object); try bytes.write(to: object)
        let source = root.appendingPathComponent("CLV-U-A0001/CLV-U-A0001.png")
        let original = try Data(contentsOf: source)
        try FileManager.default.removeItem(at: source); try original.write(to: source)
        #expect(throws: (any Error).self) { try package.validate() }
    }
    @Test func malformedTitleOrChangedROMCannotEnterMaterial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root)
        let path = root.appendingPathComponent("CLV-U-A0001/CLV-U-A0001.desktop")
        try Data("Name=Bad\u{0}\n".utf8).write(to: path)
        #expect(throws: (any Error).self) { try menu(review, originals) }
        try Data("Name=Imported 1\n".utf8).write(to: path)
        let rom = root.appendingPathComponent("CLV-U-A0001/CLV-U-A0001.sfc")
        try Data([0]).write(to: rom)
        #expect(throws: (any Error).self) { try menu(review, originals) }
    }
    @Test func customFoldersRespectManualOrderBackPositionAndArtwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root)
        let imported = review.rows.map { $0.game.code }, stock = originals.entries.map(\.code)
        let tree = ConsoleStructure.CustomFolderTree(rootGameCodes: stock, folders: [
            .init(id: "my-games", title: "My games", parentID: nil, gameCodes: Array(imported.reversed()), artKey: "custom.png")])
        let menu = try SNESLibraryMenu.prepare(review: review, originals: originals, selected: Set(imported), decisions: [:],
            order: .manual(stock + imported.reversed()), structure: .init(mode: .custom, maximumGamesPerPage: .thirtyFive,
                backPosition: .top, folderArt: .custom, custom: tree),
            artwork: .init(more: oneGameSyntheticArt(), back: oneGameSyntheticArt(), custom: ["custom.png": oneGameSyntheticArt()]))
        #expect(menu.graph.screens[1].entries.first == .link(0))
        #expect(menu.graph.screens[1].gameCodes == Array(imported.reversed()))
        let description = String(decoding: try #require(menu.files["pages/001/CLV-S-00000/CLV-S-00000.desktop"]), as: UTF8.self)
        #expect(description.contains("SortRawTitle=00000"))
        for place in menu.description.placements where place.artwork != nil {
            #expect(place.smallArtwork == place.artwork?.replacingOccurrences(of: ".png", with: "_small.png"))
        }
    }
    @Test(arguments: ["placement", "reference", "extra-object", "schema", "page-overflow"])
    func frozenMaterialRefusesIncompleteOrContradictoryDescriptions(_ fault: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root), menu = try menu(review, originals)
        var raw = try #require(JSONSerialization.jsonObject(with: menu.manifest) as? [String: Any])
        if fault == "schema" { raw["version"] = 99 }
        else if fault == "page-overflow" {
            var graph = try #require(raw["graph"] as? [String: Any]); graph["maximumGamesPerPage"] = Int.max; raw["graph"] = graph
        } else {
            var placements = try #require(raw["placements"] as? [[String: Any]])
            if fault == "placement" { placements.removeLast() }
            if fault == "reference", let index = placements.firstIndex(where: { $0["kind"] as? String == "import" }) {
                placements[index]["rom"] = String(repeating: "0", count: 64) + ".sfrom"
            }
            raw["placements"] = placements
        }
        let altered = try JSONDecoder().decode(SNESLibraryMenu.Manifest.self, from: JSONSerialization.data(withJSONObject: raw))
        var objects = menu.objects
        if fault == "extra-object" { objects[String(repeating: "a", count: 64) + ".png"] = Data([0]) }
        let forged = SNESLibraryMenu(description: altered, files: menu.files, objects: objects, sources: menu.sources,
                                    manifest: try SNESLibraryMenu.encode(altered), sourceSHA256: menu.sourceSHA256)
        #expect(throws: (any Error).self) { try SNESLibraryMaterial.freeze(menu: forged, in: root) }
    }

    @Test func capacityRequiresMatchingContentHashesAndMeasuresNewNamespaceDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try fixture(root), menu = try menu(review, originals)
        let now = Date(), context = String(repeating: "b", count: 64)
        let fresh = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: context, freeBytes: 100_000_000, blockSize: 4096, objects: [:], namespaceReady: false)
        let ready = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: context, freeBytes: fresh.freeBytes, blockSize: 4096, objects: [:], namespaceReady: true)
        let first = try SNESLibraryCapacity.project(menu: menu, inventory: fresh, expectedContext: context, now: now)
        let next = try SNESLibraryCapacity.project(menu: menu, inventory: ready, expectedContext: context, now: now)
        #expect(first.newAllocatedBytes - next.newAllocatedBytes == 4 * 4096)
        let art = try #require(menu.objectRecords.first { $0.name.hasSuffix(".png") })
        let mismatch = SNESLibraryObjects.Record(name: art.name, byteCount: art.byteCount, sha256: String(repeating: "0", count: 64))
        let wrong = SNESLibraryCapacity.Inventory(measuredAt: now, contextSHA256: context, freeBytes: fresh.freeBytes, blockSize: 4096, objects: [art.name: mismatch], namespaceReady: true)
        #expect(throws: (any Error).self) { try SNESLibraryCapacity.project(menu: menu, inventory: wrong, expectedContext: context, now: now) }
    }

}
