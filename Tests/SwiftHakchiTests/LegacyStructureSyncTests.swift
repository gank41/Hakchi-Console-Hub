import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct LegacyStructureSyncTests {
    private let fixture = LegacyMenuStageTests()

    private func inputs(_ root: URL) throws -> ([Game], [Game], LegacyConsoleReport, Set<String>) {
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let local = try fixture.localGame("CLV-H-AAAAA", root: root)
        return ([local], stock.map(fixture.stockGame), fixture.report(stock), stock.union([local.code]))
    }

    private func plan(_ root: URL, structure: ConsoleStructure,
                      order: ConsoleMenuOrder = .title) throws -> LegacySyncPlan {
        let (local, remote, report, selected) = try inputs(root)
        return try LegacySyncPlan.make(localGames: local, remoteGames: remote, report: report,
            selectedCodes: selected, maximumGamesPerPage: structure.maximumGamesPerPage.rawValue,
            trialCode: nil, consoleOrder: order, reviewedLocalCodes: [local[0].code],
            structure: structure)
    }

    private func journal(_ root: URL, structure: ConsoleStructure?) throws -> LegacySyncJournal {
        let (_, _, _, selected) = try inputs(root)
        let digest = String(repeating: "a", count: 64)
        return try LegacySyncJournal(operationID: UUID(), reviewSHA256: digest,
            archiveSHA256: digest, treeSHA256: digest, backupSHA256: digest,
            backupDirectory: root.appendingPathComponent("backup"), stageDirectory: root.appendingPathComponent("stage"),
            scope: .full, selectedCodes: selected.sorted(), reviewedLocalCodes: ["CLV-H-AAAAA"],
            consoleOrder: .title, maximumGamesPerPage: structure?.maximumGamesPerPage.rawValue ?? 25,
            archiveBytes: 4096, structure: structure)
    }

    @Test func oldFullJournalReopensAsOriginalPages() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try journal(root, structure: nil)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "structure")
        let decoded = try JSONDecoder().decode(LegacySyncJournal.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.resolvedStructure.mode == .pagesEqual)
        #expect(decoded.resolvedStructure.maximumGamesPerPage == .twentyFive)
        #expect(decoded.structure == nil)
    }

    @Test func savedStructureRoundTripsAndRejectsUnknownVersion() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let structure = ConsoleStructure(mode: .stockRootFoldersEqual, backPosition: .top)
        let saved = try journal(root, structure: structure)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(LegacySyncJournal.self, from: data).resolvedStructure == structure)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var snapshot = try #require(json["structure"] as? [String: Any])
        snapshot["version"] = 99; json["structure"] = snapshot
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LegacySyncJournal.self,
                from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func changedFolderTitleArtAndManualOrderInvalidateReview() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stock = (0..<30).map { String(format: "CLV-P-%05d", $0) }
        func custom(_ title: String, _ art: ConsoleStructure.FolderArt) -> ConsoleStructure {
            .init(mode: .custom, folderArt: art,
                  custom: .init(rootGameCodes: stock, folders: [
                    .init(id: "one", title: title, parentID: nil,
                          gameCodes: ["CLV-H-AAAAA"], artKey: nil)
                  ]))
        }
        let first = try plan(root, structure: custom("Imported", .classic))
        let renamed = try plan(root, structure: custom("Other games", .classic))
        let differentArt = try plan(root, structure: custom("Imported", .letterTiles))
        let manual = try plan(root, structure: custom("Imported", .classic),
            order: .manual(["CLV-H-AAAAA"] + stock.reversed()))
        #expect(Set([first.reviewSHA256, renamed.reviewSHA256,
                     differentArt.reviewSHA256, manual.reviewSHA256]).count == 4)
        let saved = try journal(root, structure: first.structure)
        #expect(saved.matches(first))
        #expect(!saved.matches(renamed))
        #expect(!saved.matches(differentArt))
        #expect(!saved.matches(manual))
    }

    @Test func onlyObservedStructureOptionsCanActivate() {
        #expect(LegacyStructureHardwareSupport.canActivate(.init()))
        #expect(!LegacyStructureHardwareSupport.canActivate(.init(mode: .stockRootFoldersEqual,
            maximumGamesPerPage: .twentyFive, backPosition: .bottom, folderArt: .classic)))
        #expect(!LegacyStructureHardwareSupport.canActivate(.init(mode: .stockRootFoldersEqual)))
        #expect(!LegacyStructureHardwareSupport.canActivate(.init(mode: .stockRootFoldersEqual,
            maximumGamesPerPage: .twentyFive, backPosition: .top)))
        #expect(!LegacyStructureHardwareSupport.canActivate(.init(mode: .stockRootFoldersEqual,
            maximumGamesPerPage: .twentyFive, folderArt: .letterTiles)))
        #expect(!LegacyStructureHardwareSupport.canActivate(.init(mode: .pagesEqual, backPosition: .top)))
    }

    @Test func laterGameAdditionKeepsAcceptedStructure() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let stock = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let old = try fixture.localGame("CLV-H-AAAAA", root: root)
        let added = try fixture.localGame("CLV-H-BBBBB", root: root)
        let structure = ConsoleStructure(mode: .stockRootFoldersEqual,
                                         maximumGamesPerPage: .twentyFive)
        let digest = String(repeating: "a", count: 64)
        var accepted = try LegacySyncJournal(operationID: UUID(), reviewSHA256: digest,
            archiveSHA256: digest, treeSHA256: digest, backupSHA256: digest,
            backupDirectory: root.appendingPathComponent("backup"),
            stageDirectory: root.appendingPathComponent("stage"), scope: .full,
            selectedCodes: stock.union([old.code]).sorted(), reviewedLocalCodes: [old.code],
            consoleOrder: .title, maximumGamesPerPage: 25, archiveBytes: 4096,
            structure: structure)
        accepted.phase = .accepted
        let prior = fixture.report(stock)
        let report = LegacyConsoleReport(bootVersion: prior.bootVersion,
            kernelVersion: prior.kernelVersion, scriptVersion: prior.scriptVersion,
            activePage: prior.activePage, freeBytes: prior.freeBytes, savesPath: prior.savesPath,
            stockCodes: stock, visibleCodes: stock.union([old.code]))
        let hashes = Dictionary(uniqueKeysWithValues: stock.map { ($0, BackupManifest.digest(Data([1]))) })
        let review = try LegacyFullSyncReview.make(localGames: [old, added],
            remoteGames: stock.map(fixture.stockGame), report: report,
            factoryROMHashes: hashes, accepted: accepted)
        let next = try review.plan(decisions: [:], excludedCodes: [], consoleOrder: .title,
                                   maximumGamesPerPage: 30)
        #expect(next.structure == structure)
        #expect(next.maximumGamesPerPage == 25)
        #expect(next.selectedGames.contains { $0.game.code == added.code })
    }
}
