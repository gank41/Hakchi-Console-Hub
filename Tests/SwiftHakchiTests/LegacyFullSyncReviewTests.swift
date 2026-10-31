import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct LegacyFullSyncReviewTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rom(extra: Int = 0) -> Data {
        var header = Data(repeating: 0, count: 16)
        header.replaceSubrange(0..<4, with: [0x4E, 0x45, 0x53, 0x1A])
        header[4] = 1
        return header + Data(repeating: 0x4B, count: 16_384 + extra)
    }

    private func local(_ code: String, name: String, extra: Int = 0, in root: URL) throws -> Game {
        let folder = root.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rom(extra: extra).write(to: folder.appendingPathComponent("game.nes"))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent(code + ".png"))
        let desktop = "[Desktop Entry]\nCode=\(code)\nName=\(name)\nExec=/bin/clover-kachikachi-wr /var/games/\(code)/game.nes\nIcon=/var/games/\(code)/\(code).png\n"
        try Data(desktop.utf8).write(to: folder.appendingPathComponent(code + ".desktop"))
        var game = Game(desktopFile: DesktopFile(string: desktop), consoleType: .nes,
                        basePath: root.path, source: .local)
        game.isSelected = false
        return game
    }

    private func stock() -> ([Game], [String: String], LegacyConsoleReport) {
        let games = (0..<30).map { index -> Game in
            let code = String(format: "CLV-P-%05d", index)
            let name = index == 0 ? "METROID™" : "Stock \(index)"
            return Game(code: code,
                desktopContent: "Code=\(code)\nName=\(name)\nExec=/bin/clover-kachikachi-wr /usr/share/games/nes/kachikachi/\(code)/\(code).nes",
                consoleType: .nes, source: .stock)
        }
        let hashes = Dictionary(uniqueKeysWithValues: games.enumerated().map {
            ($0.element.code, BackupManifest.digest(Data([UInt8($0.offset)])))
        })
        let codes = Set(games.map(\.code))
        let report = LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
            scriptVersion: "[master]v1.0.3-110(7f31082)",
            activePage: LegacyConsoleReport.gameRoot + "/000", freeBytes: 512 * 1024 * 1024,
            savesPath: "/var/lib/clover/profiles/0", stockCodes: codes, visibleCodes: codes)
        return (games, hashes, report)
    }

    private func withVisible(_ original: LegacyConsoleReport, _ codes: Set<String>) -> LegacyConsoleReport {
        LegacyConsoleReport(bootVersion: original.bootVersion, kernelVersion: original.kernelVersion,
            scriptVersion: original.scriptVersion, activePage: original.activePage,
            freeBytes: original.freeBytes, savesPath: original.savesPath,
            stockCodes: original.stockCodes, visibleCodes: codes)
    }

    @Test func validROMFooterIsInformationalButInvalidHeaderNeedsReview() {
        let footer = LegacyFullSyncReview.CompatibilityWarning(code: "CLV-H-AAAAA", title: "Game",
            trailingBytes: 128, detail: "Extra information")
        let invalid = LegacyFullSyncReview.CompatibilityWarning(code: "CLV-H-BBBBB", title: "Other",
            trailingBytes: nil, detail: "Invalid header")
        #expect(!footer.requiresAcknowledgement)
        #expect(invalid.requiresAcknowledgement)
    }

    @Test func selectAllCanReincludePreviouslyExcludedGamesAndResumeThatPreview() throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let excluded = try local("CLV-H-AAAAA", name: "Previously unchecked", in: folder)
        let (stock, hashes, report) = stock()
        let priorCodes = report.stockCodes.subtracting([stock[1].code])
        var accepted = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: String(repeating: "a", count: 64), archiveSHA256: String(repeating: "b", count: 64),
            treeSHA256: String(repeating: "c", count: 64), backupSHA256: String(repeating: "d", count: 64),
            backupDirectory: folder, stageDirectory: folder, scope: .full,
            selectedCodes: priorCodes.sorted(), reviewedLocalCodes: [excluded.code],
            consoleOrder: .title, maximumGamesPerPage: 25, archiveBytes: 8192)
        accepted.phase = .accepted
        let review = try LegacyFullSyncReview.make(localGames: [excluded], remoteGames: stock,
            report: withVisible(report, priorCodes), factoryROMHashes: hashes, accepted: accepted)
        #expect(!(try review.proposedCodes(decisions: [:])).contains(excluded.code))
        let all = try review.proposedCodes(decisions: [:], includePreviouslyExcluded: true)
        #expect(all.contains(excluded.code))
        #expect(all.contains(stock[1].code))
        let plan = try review.plan(decisions: [:], excludedCodes: [], consoleOrder: .title,
                                  maximumGamesPerPage: 25, selectedCodes: all)
        #expect(Set(plan.selectedGames.map { $0.game.code }) == all)
        let saved = try review.selectionForSavedPreview(all)
        #expect(saved.excludedCodes.isEmpty)
    }

    @Test func initialReviewIncludesAllLocalGamesButRequiresUncertainMatchDecision() throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let metroid = try local("CLV-H-AAAAA", name: "Metroid", in: folder)
        let newGame = try local("CLV-H-BBBBB", name: "A New Game", extra: 128, in: folder)
        let (stock, hashes, report) = stock()
        let review = try LegacyFullSyncReview.make(localGames: [metroid, newGame],
            remoteGames: stock, report: report, factoryROMHashes: hashes, accepted: nil)
        #expect(review.duplicateReview.rows.first(where: { $0.localCode == metroid.code })?.evidence == .titleCandidate)
        #expect(review.compatibilityWarnings.first(where: { $0.code == newGame.code })?.trailingBytes == 128)
        #expect(throws: SyncPlanError.self) {
            try review.plan(decisions: [:], excludedCodes: [], consoleOrder: .title, maximumGamesPerPage: 25)
        }
        let plan = try review.plan(decisions: [metroid.code: .keepBuiltIn], excludedCodes: [],
                                   consoleOrder: .title, maximumGamesPerPage: 25)
        let estimate = try #require(review.capacityEstimate.projected(Set(plan.selectedGames.map { $0.game.code })))
        #expect(estimate.requiredBytes <= plan.requiredStagingBytes)
        #expect(plan.selectedGames.count == 31)
        #expect(plan.selectedGames.contains { $0.game.code == newGame.code })
        #expect(!plan.selectedGames.contains { $0.game.code == metroid.code })
        #expect(plan.reviewedLocalCodes == [metroid.code, newGame.code])
        let art = folder.appendingPathComponent(newGame.code).appendingPathComponent(newGame.code + ".png")
        try Data([4, 5, 6]).write(to: art)
        #expect(throws: SyncPlanError.self) { try plan.verifyLocalSources() }
    }

    @Test func savedPreviewRestoresDuplicateChoiceAndDeselectedGames() throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let metroid = try local("CLV-H-AAAAA", name: "Metroid", in: folder)
        let other = try local("CLV-H-BBBBB", name: "Other game", in: folder)
        let (stock, hashes, report) = stock()
        let review = try LegacyFullSyncReview.make(localGames: [metroid, other],
            remoteGames: stock, report: report, factoryROMHashes: hashes, accepted: nil)
        let saved = report.stockCodes.subtracting([stock[0].code]).union([metroid.code])

        let restored = try review.selectionForSavedPreview(saved)

        #expect(restored.decisions[metroid.code] == .keepImported)
        #expect(restored.excludedCodes == [other.code])
        #expect(try review.proposedCodes(decisions: restored.decisions,
            defaultUnreviewed: true).subtracting(restored.excludedCodes) == saved)
    }

    @Test func laterUpdatePreservesAcceptedSelectionAndAddsOnlyNewImports() throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let metroid = try local("CLV-H-AAAAA", name: "Metroid", in: folder)
        let existing = try local("CLV-H-BBBBB", name: "Existing", in: folder)
        let added = try local("CLV-H-CCCCC", name: "New Arrival", in: folder)
        let (stock, hashes, report) = stock()
        var accepted = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64),
            treeSHA256: String(repeating: "c", count: 64),
            backupSHA256: String(repeating: "d", count: 64),
            backupDirectory: folder, stageDirectory: folder,
            scope: .full, selectedCodes: (report.stockCodes.union([existing.code])).sorted(),
            reviewedLocalCodes: [metroid.code, existing.code], consoleOrder: .title,
            maximumGamesPerPage: 25, archiveBytes: 8192)
        accepted.phase = .accepted
        let currentReport = withVisible(report, report.stockCodes.union([existing.code]))
        let review = try LegacyFullSyncReview.make(localGames: [metroid, existing, added],
            remoteGames: stock, report: currentReport, factoryROMHashes: hashes, accepted: accepted)
        #expect(review.newLocalCodes == [added.code])
        #expect(review.suggestedDecisions[metroid.code] == .keepBuiltIn)
        let plan = try review.plan(decisions: [:], excludedCodes: [],
                                   consoleOrder: .title, maximumGamesPerPage: 25)
        #expect(plan.selectedGames.contains { $0.game.code == existing.code })
        #expect(plan.selectedGames.contains { $0.game.code == added.code })
        #expect(!plan.selectedGames.contains { $0.game.code == metroid.code })
        let withRemoval = try review.plan(decisions: [:], excludedCodes: [existing.code],
                                          consoleOrder: .title, maximumGamesPerPage: 25)
        #expect(!withRemoval.selectedGames.contains { $0.game.code == existing.code })
        let override = try review.plan(decisions: [metroid.code: .keepImported],
                                       excludedCodes: [], consoleOrder: .title,
                                       maximumGamesPerPage: 25)
        #expect(override.selectedGames.contains { $0.game.code == metroid.code })
        #expect(!override.selectedGames.contains { $0.game.code == stock[0].code })
        #expect(try review.proposedCodes(decisions: [metroid.code: .keepImported])
            .contains(metroid.code))
    }

    @Test func acceptedExactOverrideSurvivesUpdateAndStaleConsoleBaselineRefuses() throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let imported = try local("CLV-H-AAAAA", name: "Metroid", in: folder)
        let (stock, initialHashes, report) = stock()
        var hashes = initialHashes
        hashes[stock[0].code] = BackupManifest.digest(rom())
        let selected = report.stockCodes.subtracting([stock[0].code]).union([imported.code])
        var accepted = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64),
            treeSHA256: String(repeating: "c", count: 64),
            backupSHA256: String(repeating: "d", count: 64),
            backupDirectory: folder, stageDirectory: folder,
            scope: .full, selectedCodes: selected.sorted(), reviewedLocalCodes: [imported.code],
            consoleOrder: .title, maximumGamesPerPage: 25, archiveBytes: 8192)
        accepted.phase = .accepted
        let currentReport = withVisible(report, selected)
        let review = try LegacyFullSyncReview.make(localGames: [imported], remoteGames: stock,
            report: currentReport, factoryROMHashes: hashes, accepted: accepted)
        #expect(review.duplicateReview.rows[0].evidence == .exact)
        #expect(review.suggestedDecisions[imported.code] == .keepImported)
        let plan = try review.plan(decisions: [:], excludedCodes: [],
                                   consoleOrder: .title, maximumGamesPerPage: 25)
        #expect(plan.selectedGames.contains { $0.game.code == imported.code })
        #expect(!plan.selectedGames.contains { $0.game.code == stock[0].code })
        #expect(throws: SyncPlanError.self) {
            try LegacyFullSyncReview.make(localGames: [imported], remoteGames: stock,
                report: report, factoryROMHashes: hashes, accepted: accepted)
        }
    }

    @Test func missingPreviouslySelectedROMNeedsExplicitRemoval() throws {
        let folder = try root(); defer { try? FileManager.default.removeItem(at: folder) }
        let (stock, hashes, report) = stock()
        let missing = "CLV-H-AAAAA"
        let selected = report.stockCodes.union([missing])
        var accepted = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64),
            treeSHA256: String(repeating: "c", count: 64),
            backupSHA256: String(repeating: "d", count: 64),
            backupDirectory: folder, stageDirectory: folder,
            scope: .full, selectedCodes: selected.sorted(), reviewedLocalCodes: [missing],
            consoleOrder: .title, maximumGamesPerPage: 25, archiveBytes: 8192)
        accepted.phase = .accepted
        let installed = Game(code: missing,
            desktopContent: "Code=\(missing)\nName=Missing game\nExec=/bin/clover-kachikachi-wr /var/games/\(missing)/game.nes",
            consoleType: .nes, source: .console)
        let review = try LegacyFullSyncReview.make(localGames: [], remoteGames: stock + [installed],
            report: withVisible(report, selected), factoryROMHashes: hashes, accepted: accepted)
        #expect(review.missingSelectedCodes == [missing])
        #expect(throws: SyncPlanError.self) {
            try review.plan(decisions: [:], excludedCodes: [],
                consoleOrder: .title, maximumGamesPerPage: 25)
        }
        let plan = try review.plan(decisions: [:], excludedCodes: [missing],
                                   consoleOrder: .title, maximumGamesPerPage: 25)
        #expect(plan.removedCodes == [missing])
    }
}
