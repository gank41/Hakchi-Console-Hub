import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct LegacyStockDuplicateReviewTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func local(_ code: String, name: String, bytes: Data, in root: URL) throws -> Game {
        let folder = root.appendingPathComponent(code, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("game.nes"))
        var game = Game(code: code, desktopContent: "Code=\(code)\nName=\(name)\nExec=/bin/clover-kachikachi-wr /var/games/\(code)/game.nes",
                        consoleType: .nes, source: .local)
        game.romPath = folder.path
        return game
    }

    private func stock(_ code: String, name: String) -> Game {
        Game(code: code, desktopContent: "Code=\(code)\nName=\(name)\nExec=/bin/clover-kachikachi-wr /usr/share/games/nes/kachikachi/\(code)/\(code).nes",
             consoleType: .nes, source: .stock)
    }

    @Test func exactBytesKeepBuiltInByDefaultEvenWhenNamesDiffer() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x4E, 0x45, 0x53, 0x1A, 1, 2, 3])
        let imported = try local("CLV-H-AAAAA", name: "Mario Three (edited)", bytes: bytes, in: root)
        let builtIn = stock("CLV-P-AAAAA", name: "Super Mario Bros. 3")
        let review = try LegacyStockDuplicateReview.make(local: [imported], stock: [builtIn],
            factoryROMHashes: [builtIn.code: BackupManifest.digest(bytes)])
        #expect(review.rows.count == 1)
        #expect(review.rows[0].evidence == .exact)
        #expect(review.rows[0].stockCode == builtIn.code)
        #expect(try review.resolvedCodes(decisions: [:]) == [builtIn.code])
        #expect(try review.resolvedCodes(decisions: [imported.code: .keepImported]) == [imported.code])
    }

    @Test func sameTitleDifferentBytesNeedsExplicitDecision() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let imported = try local("CLV-H-BBBBB", name: "Metroid", bytes: Data([1, 2]), in: root)
        let builtIn = stock("CLV-P-BBBBB", name: "METROID™")
        let review = try LegacyStockDuplicateReview.make(local: [imported], stock: [builtIn],
            factoryROMHashes: [builtIn.code: BackupManifest.digest(Data([3, 4]))])
        #expect(review.rows[0].evidence == .titleCandidate)
        #expect(throws: SyncPlanError.self) { try review.resolvedCodes(decisions: [:]) }
        #expect(try review.resolvedCodes(decisions: [imported.code: .keepBuiltIn]) == [builtIn.code])
        #expect(try review.resolvedCodes(decisions: [imported.code: .keepImported]) == [imported.code])
    }

    @Test func reviewedAliasesDoNotMergeDistinctSubtitles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let zelda = try local("CLV-H-CCCCC", name: "Zelda 2: The Adventure of Link", bytes: Data([1]), in: root)
        let punch = try local("CLV-H-DDDDD", name: "Punch-Out!!", bytes: Data([2]), in: root)
        let stockZelda = stock("CLV-P-CCCCC", name: "Zelda II - The Adventure of Link")
        let stockPunch = stock("CLV-P-DDDDD", name: "Punch-Out!! Featuring Mr. Dream")
        let review = try LegacyStockDuplicateReview.make(local: [zelda, punch], stock: [stockZelda, stockPunch],
            factoryROMHashes: [stockZelda.code: BackupManifest.digest(Data([3])),
                               stockPunch.code: BackupManifest.digest(Data([4]))])
        #expect(review.rows.first(where: { $0.localCode == zelda.code })?.evidence == .aliasCandidate)
        #expect(review.rows.first(where: { $0.localCode == punch.code })?.evidence == .distinct)
        #expect(throws: SyncPlanError.self) { try review.resolvedCodes(decisions: [:]) }
        #expect(try review.resolvedCodes(decisions: [zelda.code: .keepBuiltIn]) ==
                [stockZelda.code, stockPunch.code, punch.code])
    }

    @Test func incompleteFactoryHashesRefuseReview() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let imported = try local("CLV-H-EEEEE", name: "Excitebike", bytes: Data([1]), in: root)
        let builtIn = stock("CLV-P-EEEEE", name: "Excitebike")
        #expect(throws: SyncPlanError.self) {
            try LegacyStockDuplicateReview.make(local: [imported], stock: [builtIn], factoryROMHashes: [:])
        }
    }
}
