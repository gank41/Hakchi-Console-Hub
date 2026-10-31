import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryReviewDraftTests {
    @Test(arguments: ["unsupported-rom", "missing-art"])
    func unavailableGamesStaySelectedUntilTheUserExplicitlyChoosesToSkipThem(_ fault: String) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root)
        let bad = initial.rows[1].game, folder = URL(fileURLWithPath: bad.romPath)
        if fault == "unsupported-rom" { try Data("not a ROM".utf8).write(to: folder.appendingPathComponent(bad.code + ".sfc")) }
        else { try FileManager.default.removeItem(at: folder.appendingPathComponent(bad.code + ".png")) }
        let review = try SNESLibraryCompatibility.review(games: initial.rows.map(\.game), originals: originals)
        let cache = try SNESLibraryObjectCache.prepare(review: review), selected = Set(review.rows.map { $0.game.code })
        var draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache, selected: selected,
            structure: .init(mode: .stockRootPagesEqual), order: .title)
        #expect(draft.unavailableCodes == [bad.code] && draft.selected == selected)
        #expect(draft.effectiveImportCount == 1)
        #expect(throws: (any Error).self) { try draft.menu() }
        draft.setAllowSkippingUnavailable(true)
        let menu = try draft.menu()
        #expect(draft.selected == selected && draft.effectiveImportCount == 1)
        #expect(menu.description.placements.filter { $0.kind == "import" }.count == 1)
        #expect(!menu.description.placements.contains { $0.code == bad.code })
    }
    @Test func changedSelectionsAndStructureInvalidateTheDraftWithoutReimportingFiles() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try SNESLibraryMaterialTests().fixture(root), cache = try SNESLibraryObjectCache.prepare(review: review)
        let selected = Set(review.rows.map { $0.game.code })
        var draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache, selected: selected,
            structure: .init(mode: .stockRootPagesEqual), order: .title)
        let old = draft.fingerprint, code = review.rows[0].game.code
        try draft.setSelected(code, selected: false)
        #expect(draft.fingerprint != old && draft.selected.count == 1)
        let next = draft.fingerprint
        draft.setStructure(.init(mode: .stockRootFoldersEqual))
        #expect(draft.fingerprint != next)
        #expect(try draft.menu().description.structure.mode == .stockRootFoldersEqual)
        #expect(throws: (any Error).self) { try draft.setSelected("foreign", selected: true) }
        #expect(draft.selected.count == 1)
    }
    @Test func changedCachedSourcesRequireARefreshBeforePreparingConsoleMaterial() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (review, originals) = try SNESLibraryMaterialTests().fixture(root), cache = try SNESLibraryObjectCache.prepare(review: review)
        let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache, selected: Set(review.rows.map { $0.game.code }),
            structure: .init(), order: .title)
        _ = try draft.menu()
        let game = review.rows[0].game, file = URL(fileURLWithPath: game.romPath).appendingPathComponent(game.code + ".sfc"), data = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try data.write(to: file)
        #expect(throws: (any Error).self) { try draft.menu() }
        #expect(draft.selected.count == 2)
    }
    @Test(arguments: [false, true]) func uncertainBuiltInMatchesNeedAChoiceAndKeepOnlyOneVersion(_ unavailable: Bool) throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root, count: 1)
        let stock = try #require(originals.entries.first), desktop = try #require(stock.files.first { $0.name.hasSuffix(".desktop") })
        let title = try #require(SNESOneGameMenu.fields(desktop.data)["name"])
        var game = initial.rows[0].game
        let path = URL(fileURLWithPath: game.romPath).appendingPathComponent(game.code + ".desktop")
        let updated = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "Name=Imported 1", with: "Name=" + title)
        try Data(updated.utf8).write(to: path); game = Game(code: game.code, desktopContent: updated, consoleType: .snesUsa, source: .local); game.romPath = path.deletingLastPathComponent().path
        if unavailable { try Data("not a ROM".utf8).write(to: path.deletingLastPathComponent().appendingPathComponent(game.code + ".sfc")) }
        let review = try SNESLibraryCompatibility.review(games: [game], originals: originals), cache = try SNESLibraryObjectCache.prepare(review: review)
        var draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache, selected: [game.code], structure: .init(), order: .title)
        #expect(draft.unresolvedDuplicateCodes == [game.code])
        #expect(throws: (any Error).self) { try draft.menu() }
        if unavailable { draft.setAllowSkippingUnavailable(true) }
        else { try draft.setDecision(game.code, resolution: .keepBuiltIn) }
        let menu = try draft.menu()
        #expect(draft.unresolvedDuplicateCodes.isEmpty && !menu.description.placements.contains { $0.code == game.code })
        #expect(menu.description.stock.count == originals.entries.count)
        #expect(draft.effectiveImportCount == 0 && draft.selected == [game.code])

    }
    @Test func irregularNativeCandidateEntersTheNormalMenuWithoutChangingItsSource() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root, count: 1)
        let game = initial.rows[0].game
        var rom = oneGameSyntheticROM(byteCount: 2*1024*1024)
        rom.removeLast(512*1024)
        let path = URL(fileURLWithPath: game.romPath).appendingPathComponent(game.code + ".sfc")
        try rom.write(to: path)
        let review = try SNESLibraryCompatibility.review(games: [game], originals: originals)
        let cache = try SNESLibraryObjectCache.prepare(review: review)
        let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache,
            selected: [game.code], structure: .init(mode: .stockRootPagesEqual), order: .title)
        #expect(review.rows[0].readiness == .ready && draft.effectiveImportCount == 1)
        let menu = try draft.menu()
        #expect(menu.description.placements.filter { $0.kind == "import" }.map(\.code) == [game.code])
        #expect(try Data(contentsOf: path) == rom && game.isSelected)
    }
    @Test func compatibilityRequestUsesCurrentDraftSelectionAndDuplicateChoice() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root, count: 1)
        let original = try #require(originals.entries.first), game = initial.rows[0].game
        let source = try #require(initial.rows[0].source)
        let row = SNESLibraryCompatibility.Row(game: game, source: source, prepared: nil,
            issue: "Needs support", matches: [original.code], evidence: .possible, preparationError: .unsupportedCartridge)
        let review = SNESLibraryCompatibility(rows: [row], stockCodes: Set(originals.entries.map(\.code)))
        let cache = try SNESLibraryObjectCache.prepare(review: review)
        var draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache,
            selected: [game.code], structure: .init(), order: .title)
        let token = Data([7] + Array(repeating: 0, count: 15))
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityLaunch(code: game.code, session: token, epoch: 4) }
        #expect(throws: (any Error).self) { try draft.compatibilityLayoutPreview() }
        try draft.setDecision(game.code, resolution: .keepImported)
        let result = try draft.prepareCompatibilityLaunch(code: game.code, session: token, epoch: 4)
        #expect(result.frame.count == 107)
        let batch = try draft.prepareCompatibilityLaunches(sessions: [game.code: token], epoch: 4)
        #expect(batch[game.code]?.frame == result.frame)
        let replacement = try draft.compatibilityMenuPreview(sessions: [game.code: token], epoch: 4)
        #expect(replacement.resolvedCodes.contains(game.code) && !replacement.resolvedCodes.contains(original.code))
        #expect(Set(try draft.compatibilityLayoutPreview().screens.flatMap(\.gameCodes)) == replacement.resolvedCodes)
        #expect(throws: (any Error).self) { try draft.menu() } // Local review does not enable console sync.
        draft.setAllowSkippingUnavailable(true)
        #expect(try draft.prepareCompatibilityLaunches(sessions: [:], epoch: 4).isEmpty)
        #expect(throws: (any Error).self) { try draft.compatibilityLayoutPreview() }
        draft.setAllowSkippingUnavailable(false)
        try draft.setSelected(game.code, selected: false)
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityLaunch(code: game.code, session: token, epoch: 4) }
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityLaunches(sessions: [game.code: token], epoch: 4) }
        #expect(try draft.prepareCompatibilityLaunches(sessions: [:], epoch: 4).isEmpty)
        try draft.setSelected(game.code, selected: true)
        try draft.setDecision(game.code, resolution: .keepBuiltIn)
        let builtIn = try draft.compatibilityMenuPreview(sessions: [:], epoch: 4)
        #expect(!builtIn.resolvedCodes.contains(game.code) && builtIn.resolvedCodes.contains(original.code) && builtIn.requests.isEmpty)
    }
    @Test func compatibilitySelectionPreparesOnlyItsOwnBackupReferences() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root, count: 1)
        let candidate = try #require(initial.rows.first), game = candidate.game
        let unsupported = SNESLibraryCompatibility.Row(game: game, source: candidate.source, prepared: nil,
            issue: "Needs support", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge)
        let review = SNESLibraryCompatibility(rows: [unsupported], stockCodes: initial.stockCodes)
        let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: SNESLibraryObjectCache.prepare(review: review),
                                               selected: [game.code], structure: .init(), order: .title)
        let f = SNESLibraryInventoryTests(), nonce = UUID(), inventory = try f.parse(f.frame(challenge: nonce), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let token = Data([7] + Array(repeating: 0, count: 15))
        let refs = try draft.prepareCompatibilityRecoveryReferences(backup: backup, current: inventory, root: root, sessions: [game.code: token], epoch: 4)
        let reference = try #require(refs[game.code])
        #expect(Set(refs.keys) == [game.code] && reference.evidence.original == .absent)
        #expect(reference.evidence.romSHA256 == candidate.source?.sha256)
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityRecoveryReferences(backup: backup, current: inventory, root: root, sessions: [game.code: token], epoch: 4) }
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityRecoveryReferences(backup: backup, current: inventory, root: root, sessions: [:], epoch: 4) }
        #expect(throws: (any Error).self) { try draft.menu() } // Preparation is still not permission to sync.
    }
    @Test func compatibilityReferenceBatchPreflightsAllNamesBeforeCreatingAny() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root, count: 2)
        let rows = initial.rows.map { SNESLibraryCompatibility.Row(game: $0.game, source: $0.source, prepared: nil,
            issue: "Needs support", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge) }
        let review = SNESLibraryCompatibility(rows: rows, stockCodes: initial.stockCodes)
        let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: SNESLibraryObjectCache.prepare(review: review),
                                               selected: Set(rows.map { $0.game.code }), structure: .init(), order: .title)
        let f = SNESLibraryInventoryTests(), nonce = UUID(), inventory = try f.parse(f.frame(challenge: nonce), challenge: nonce)
        let backup = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let tokens = [rows[0].game.code: Data([1] + Array(repeating: 0, count: 15)), rows[1].game.code: Data([2] + Array(repeating: 0, count: 15))]
        let blocker = root.appendingPathComponent("SNES-Compatibility-02" + String(repeating: "00", count: 15) + "-4")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityRecoveryReferences(backup: backup, current: inventory, root: root, sessions: tokens, epoch: 4) }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blocker.path).isEmpty)
        try FileManager.default.removeItem(at: blocker)
        let duplicateToken = Data([1] + Array(repeating: 0, count: 15))
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityRecoveryReferences(backup: backup, current: inventory, root: root, sessions: [rows[0].game.code: duplicateToken, rows[1].game.code: duplicateToken], epoch: 4) }
        let references = try draft.prepareCompatibilityRecoveryReferences(backup: backup, current: inventory, root: root, sessions: tokens, epoch: 4)
        #expect(Set(references.keys) == Set(rows.map { $0.game.code }))
        #expect(Set(references.values.map { $0.directory.lastPathComponent }).count == 2)
    }
    @Test func returningToOriginalGamesNeedsNoROMCopiesAndKeepsAllBuiltIns() throws {
        let originals = try SNESLibraryCompatibilityTests().originals(), menu = try SNESLibraryMenu.originalGames(originals: originals)
        #expect(menu.objects.isEmpty && menu.sources.isEmpty && menu.graph.screens.count == 1)
        #expect(menu.description.stock.count == originals.entries.count && menu.description.placements.allSatisfy { $0.kind == "stock" })
        try menu.validate(); try SNESLibraryRestore.validateStock(menu, originals: originals)
    }
    @Test func compatibilityPreviewUsesTheActualFolderPlannerAndRespectsSkipChoice() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root)
        let first = initial.rows[0]
        let unsupported = SNESLibraryCompatibility.Row(game: first.game, source: first.source, prepared: nil,
            issue: "Needs support", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge)
        let review = SNESLibraryCompatibility(rows: [unsupported, initial.rows[1]], stockCodes: initial.stockCodes)
        let cache = try SNESLibraryObjectCache.prepare(review: review), selected = Set(review.rows.map { $0.game.code })
        var draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache, selected: selected,
            structure: .init(mode: .stockRootPagesEqual, maximumGamesPerPage: .thirtyFive), order: .title)
        let token = Data([7] + Array(repeating: 0, count: 15))
        let preview = try draft.compatibilityMenuPreview(sessions: [first.game.code: token], epoch: 4)
        let visible = try draft.compatibilityLayoutPreview()
        #expect(Set(visible.screens.flatMap(\.gameCodes)) == preview.resolvedCodes)
        #expect(preview.resolvedCodes == initial.stockCodes.union(selected))
        #expect(Set(preview.graph.screens.flatMap(\.gameCodes)) == preview.resolvedCodes)
        #expect(Set(preview.requests.keys) == [first.game.code])
        #expect(Set(preview.graph.screens[0].gameCodes) == initial.stockCodes)
        #expect(throws: (any Error).self) { try draft.menu() }
        draft.setAllowSkippingUnavailable(true)
        let skipped = try draft.compatibilityMenuPreview(sessions: [:], epoch: 4)
        #expect(skipped.requests.isEmpty && !skipped.resolvedCodes.contains(first.game.code))
        #expect(skipped.resolvedCodes.contains(initial.rows[1].game.code))
    }
    @Test func compatibilityMenuContentPreservesROMAndArtworkWithoutEnablingSync() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root, count: 1)
        let old = initial.rows[0]
        let candidate = SNESLibraryCompatibility.Row(game: old.game, source: old.source, prepared: nil,
            issue: "Needs support", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge)
        let review = SNESLibraryCompatibility(rows: [candidate], stockCodes: initial.stockCodes)
        let cache = try SNESLibraryObjectCache.prepare(review: review)
        let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache,
            selected: [candidate.game.code], structure: .init(), order: .title)
        let token = Data([7] + Array(repeating: 0, count: 15))
        let content = try draft.prepareCompatibilityObjects(sessions: [candidate.game.code: token], epoch: 4)
        let item = try #require(content.items[candidate.game.code])
        let source = URL(fileURLWithPath: candidate.game.romPath).appendingPathComponent(candidate.game.code + ".sfc")
        #expect(item.rom.hasSuffix(".sfc"))
        #expect(content.objects[item.rom] == (try Data(contentsOf: source)))
        #expect(content.objects[item.artwork] != nil && content.objects[item.smallArtwork] != nil)
        #expect(throws: (any Error).self) { try draft.menu() }
        let metadata = source.deletingLastPathComponent().appendingPathComponent(candidate.game.code + ".desktop")
        let oldMetadata = try Data(contentsOf: metadata)
        try Data("[Desktop Entry]\nName=Changed\n".utf8).write(to: metadata)
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityObjects(sessions: [candidate.game.code: token], epoch: 4) }
        try oldMetadata.write(to: metadata)
        let artwork = source.deletingLastPathComponent().appendingPathComponent(candidate.game.code + ".png")
        let oldArtwork = try Data(contentsOf: artwork), outside = root.appendingPathComponent("outside.png")
        try oldArtwork.write(to: outside); try FileManager.default.removeItem(at: artwork)
        try FileManager.default.createSymbolicLink(at: artwork, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityObjects(sessions: [candidate.game.code: token], epoch: 4) }
        try FileManager.default.removeItem(at: artwork); try oldArtwork.write(to: artwork)
        try Data([1,2,3]).write(to: source)
        #expect(throws: (any Error).self) { try draft.prepareCompatibilityObjects(sessions: [candidate.game.code: token], epoch: 4) }
    }
    @Test func compatibilityMenuContentSharesIdenticalObjectsAcrossGames() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (initial, originals) = try SNESLibraryMaterialTests().fixture(root)
        let rows = initial.rows.map { row in
            SNESLibraryCompatibility.Row(game: row.game, source: row.source, prepared: nil,
                issue: "Needs support", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge)
        }
        let review = SNESLibraryCompatibility(rows: rows, stockCodes: initial.stockCodes)
        let cache = try SNESLibraryObjectCache.prepare(review: review), selected = Set(rows.map { $0.game.code })
        let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache,
            selected: selected, structure: .init(), order: .title)
        let sessions = [rows[0].game.code: Data([1] + Array(repeating: 0, count: 15)), rows[1].game.code: Data([2] + Array(repeating: 0, count: 15))]
        let content = try draft.prepareCompatibilityObjects(sessions: sessions, epoch: 4)
        #expect(content.items.count == 2 && content.objects.count == 3 && content.sources.count == 6)
        #expect(content.items[rows[0].game.code]?.rom == content.items[rows[1].game.code]?.rom)
    }
    @Test func mixedCompatibilityMenuCandidateIsVersionedAndCannotBeTransferred() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (firstReview, originals) = try SNESLibraryMaterialTests().fixture(root)
        var initial = firstReview
        if let gamePath = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_SOURCE_GAME"],
           let romPath = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_SOURCE_ROM"] {
            let source = URL(fileURLWithPath: gamePath, isDirectory: true)
            let code = source.lastPathComponent
            let directory = root.appendingPathComponent(code, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let rom = URL(fileURLWithPath: romPath)
            guard rom.deletingLastPathComponent().standardizedFileURL == source.standardizedFileURL else { throw SNESLibraryMenu.failure() }
            for name in [code + ".desktop", code + ".png", rom.lastPathComponent] {
                try Data(contentsOf: source.appendingPathComponent(name)).write(to: directory.appendingPathComponent(name))
            }
            let desktop = try String(contentsOf: directory.appendingPathComponent(code + ".desktop"), encoding: .utf8)
            var game = Game(code: code, desktopContent: desktop, consoleType: .snesUsa, source: .local)
            game.romPath = directory.path
            let actual = try SNESLibraryCompatibility.review(games: [game], originals: originals)
            #expect(actual.rows.first?.readiness == .appSupportNeeded)
            initial = SNESLibraryCompatibility(rows: [try #require(actual.rows.first), firstReview.rows[1]], stockCodes: firstReview.stockCodes)
        } else if let path = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_SOURCE_ROM"] {
            let first = try #require(initial.rows.first)
            let source = URL(fileURLWithPath: path), ext = source.pathExtension.lowercased()
            guard ["sfc", "smc"].contains(ext) else { throw SNESLibraryMenu.failure() }
            let directory = URL(fileURLWithPath: first.game.romPath)
            let synthetic = directory.appendingPathComponent(first.game.code + ".sfc")
            if ext != "sfc" { try FileManager.default.removeItem(at: synthetic) }
            try Data(contentsOf: source).write(to: directory.appendingPathComponent(first.game.code + "." + ext))
            initial = try SNESLibraryCompatibility.review(games: initial.rows.map(\.game), originals: originals)
        }
        let first = initial.rows[0]
        let compatibility = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_SOURCE_GAME"] == nil
            ? SNESLibraryCompatibility.Row(game: first.game, source: first.source, prepared: nil,
                issue: "Needs support", matches: [], evidence: .distinct, preparationError: .unsupportedCartridge)
            : first
        let review = SNESLibraryCompatibility(rows: [compatibility, initial.rows[1]], stockCodes: initial.stockCodes)
        let cache = try SNESLibraryObjectCache.prepare(review: review)
        let draft = try SNESLibraryReviewDraft(review: review, originals: originals, cache: cache,
            selected: Set(review.rows.map { $0.game.code }), structure: .init(mode: .stockRootPagesEqual), order: .title)
        let token = Data([7] + Array(repeating: 0, count: 15))
        if let fixture = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_REQUEST_FIXTURE"] {
            let request = try draft.prepareCompatibilityLaunch(code: first.game.code, session: token, epoch: 4)
            try request.frame.write(to: URL(fileURLWithPath: fixture), options: .atomic)
        }
        let art = SNESLibraryMenu.NavigationArtwork(more: oneGameSyntheticArt(), back: oneGameSyntheticArt(), custom: [:])
        let candidate = try draft.compatibilityMenuCandidate(sessions: [first.game.code: token], epoch: 4, artwork: art)
        #expect(candidate.description.version == 3)
        let sourceName = try #require(first.source?.filename)
        #expect(candidate.description.placements.contains { $0.code == first.game.code && $0.kind == "compat" && $0.rom?.hasSuffix("." + URL(fileURLWithPath: sourceName).pathExtension.lowercased()) == true })
        #expect(candidate.description.placements.contains { $0.code == initial.rows[1].game.code && $0.kind == "import" && $0.rom?.hasSuffix(".sfrom") == true })
        #expect(Set(candidate.graph.screens[0].gameCodes) == initial.stockCodes)
        let placement = try #require(candidate.description.placements.first { $0.code == first.game.code })
        let rom = try #require(placement.rom), originalROM = URL(fileURLWithPath: first.game.romPath).appendingPathComponent(sourceName)
        #expect(candidate.objects[rom] == (try Data(contentsOf: originalROM)))
        let desktop = String(format: "pages/%03d/%@/%@.desktop", placement.page, first.game.code, first.game.code)
        let desktopData = try #require(candidate.files[desktop])
        let exec = try #require(SNESOneGameMenu.fields(desktopData)["exec"])
        #expect(exec == "/mnt/swifthakchi/hc-snes-superv --game \(first.game.code) --rom \(SNESLibraryMenu.namespace)/objects/\(rom)")
        try candidate.validate()
        var raw = try #require(JSONSerialization.jsonObject(with: candidate.manifest) as? [String: Any]); raw["version"] = 1
        let forged = try JSONDecoder().decode(SNESLibraryMenu.Manifest.self, from: JSONSerialization.data(withJSONObject: raw))
        let disguised = SNESLibraryMenu(description: forged, files: candidate.files, objects: candidate.objects, sources: candidate.sources,
            manifest: try SNESLibraryMenu.encode(forged), sourceSHA256: candidate.sourceSHA256)
        #expect(throws: (any Error).self) { try disguised.validate() }
        #expect(throws: (any Error).self) { try SNESLibraryMaterial.freeze(menu: candidate, in: root) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SNES-Library-" + candidate.id.uuidString).path))
        let offline = try SNESLibraryMaterial.freezeCompatibilityCandidate(menu: candidate, in: root)
        let loaded = try SNESLibraryMaterial.loadCompatibilityCandidate(directory: offline.directory, expectedReviewSHA256: offline.reviewSHA256)
        #expect(loaded.menu.manifest == candidate.manifest)
        #expect(loaded.menu.objects == candidate.objects)
        if let fixture = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_EXEC_FIXTURE"] {
            let reloadedDesktop = try #require(loaded.menu.files[desktop])
            let reloadedExec = try #require(SNESOneGameMenu.fields(reloadedDesktop)["exec"])
            #expect(reloadedExec == exec)
            try Data(reloadedExec.utf8).write(to: URL(fileURLWithPath: fixture), options: .atomic)
        }
        if let fixture = ProcessInfo.processInfo.environment["HC_COMPAT_MENU_ROM_FIXTURE"] {
            try #require(loaded.menu.objects[rom]).write(to: URL(fileURLWithPath: fixture), options: .atomic)
        }
        #expect(throws: (any Error).self) { try SNESLibraryMaterial.load(directory: offline.directory, expectedReviewSHA256: offline.reviewSHA256) }
        #expect(throws: (any Error).self) { try offline.validate() }
        let objectFile = offline.directory.appendingPathComponent("object-" + rom)
        try Data([0]).write(to: objectFile)
        #expect(throws: (any Error).self) { try SNESLibraryMaterial.loadCompatibilityCandidate(directory: offline.directory, expectedReviewSHA256: offline.reviewSHA256) }
        #expect(throws: (any Error).self) { try SNESLibraryStartupScripts.manifest(for: candidate) }
        let nativeCandidate = try candidate.withNativeArtwork()
        #expect(nativeCandidate.description.version == 4)
        try nativeCandidate.validate()
        #expect(nativeCandidate.objects[rom] == (try Data(contentsOf: originalROM)))
        for item in nativeCandidate.description.placements where item.kind != "stock" {
            let prefix=String(format:"pages/%03d/%@/%@",item.page,item.code,item.code)
            #expect(nativeCandidate.files[prefix+".png"] != nil)
            #expect(nativeCandidate.files[prefix+"_small.png"] != nil)
            let text=try #require(nativeCandidate.files[prefix+".desktop"])
            #expect(try SNESOneGameMenu.fields(text)["icon"] == nativeCandidate.consoleRoot+"/"+prefix+".png")
        }
        let nativeRoot=root.appendingPathComponent("candidate-native")
        try FileManager.default.createDirectory(at:nativeRoot,withIntermediateDirectories:true)
        let frozen=try SNESLibraryMaterial.freezeCompatibilityCandidate(menu:nativeCandidate,in:nativeRoot)
        let reloaded=try SNESLibraryMaterial.loadCompatibilityCandidate(directory:frozen.directory,expectedReviewSHA256:frozen.reviewSHA256)
        #expect(reloaded.menu.manifest == nativeCandidate.manifest)
        #expect(throws:(any Error).self){try SNESLibraryMaterial.load(directory:frozen.directory,expectedReviewSHA256:frozen.reviewSHA256)}
        #expect(throws:(any Error).self){try frozen.validate()}
        #expect(throws:(any Error).self){try SNESLibraryStartupScripts.manifest(for:nativeCandidate)}
        let offlineManifest=try SNESLibraryStartupScripts.compatibilityCandidateManifest(for:nativeCandidate)
        let manifestText=try #require(String(data:offlineManifest,encoding:.utf8))
        #expect(manifestText.hasPrefix("SWIFTHAKCHI_SNES_LIBRARY_V4\n"))
        #expect(manifestText.contains(" \(first.game.code) compat "))
        #expect(manifestText.contains("OBJECT \(rom) "))
        #expect(manifestText.contains("_small.png "))
        #expect(try nativeCandidate.withNativeArtwork().manifest == nativeCandidate.manifest)
        let rejectedRoot=root.appendingPathComponent("no-production")
        try FileManager.default.createDirectory(at:rejectedRoot,withIntermediateDirectories:true)
        #expect(throws:(any Error).self){try SNESLibraryMaterial.freeze(menu:nativeCandidate,in:rejectedRoot)}
        #expect(try FileManager.default.contentsOfDirectory(atPath:rejectedRoot.path).isEmpty)
        let candidateGuard = try SNESLibraryMaterialGuard.prepareCompatibilityCandidate(frozen)
        try candidateGuard.require()
        #expect(throws:(any Error).self){try SNESLibraryMaterialGuard.prepare(frozen)}
        let mismatched = SNESLibraryMaterial(directory:frozen.directory,reviewSHA256:frozen.reviewSHA256,menu:candidate)
        #expect(throws:(any Error).self){try SNESLibraryMaterialGuard.prepareCompatibilityCandidate(mismatched)}
        let thumbnail=try #require(nativeCandidate.description.files.first(where:{$0.path.hasSuffix("_small.png")}))
        try Data([0]).write(to:frozen.directory.appendingPathComponent("file-"+thumbnail.sha256))
        #expect(throws:(any Error).self){try candidateGuard.require()}
        #expect(throws:(any Error).self){try SNESLibraryMaterial.loadCompatibilityCandidate(directory:frozen.directory,expectedReviewSHA256:frozen.reviewSHA256)}
    }
}
