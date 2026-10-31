import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct LegacyFullSyncPlanTests {
    private func game(_ code: String, name: String, source: GameSource,
                      release: String = "", publisher: String = "") -> Game {
        let rom = source == .stock
            ? "/usr/share/games/nes/kachikachi/\(code)/\(code).nes"
            : "/var/games/\(code)/game.nes"
        return Game(code: code, desktopContent: "Code=\(code)\nName=\(name)\nReleaseDate=\(release)\nX-SwiftHakchi-Publisher=\(publisher)\nExec=/bin/clover-kachikachi-wr \(rom)",
                    consoleType: .nes, source: source)
    }

    private func local(_ code: String, name: String, release: String, publisher: String,
                       in root: URL) throws -> Game {
        let folder = root.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x4E, 0x45, 0x53, 0x1A] + Array(repeating: 0, count: 64)).write(to: folder.appendingPathComponent("game.nes"))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent(code + ".png"))
        let desktop = "[Desktop Entry]\nCode=\(code)\nName=\(name)\nReleaseDate=\(release)\nX-SwiftHakchi-Publisher=\(publisher)\nExec=/bin/clover-kachikachi-wr /var/games/\(code)/game.nes\nIcon=/var/games/\(code)/\(code).png\n"
        try Data(desktop.utf8).write(to: folder.appendingPathComponent(code + ".desktop"))
        var result = Game(desktopFile: DesktopFile(string: desktop), consoleType: .nes,
                          basePath: root.path, source: .local)
        result.isSelected = false // Full initial scope is explicit; stale checkbox state does not decide it.
        return result
    }

    private func report(stock: Set<String>) -> LegacyConsoleReport {
        LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
            scriptVersion: "[master]v1.0.3-110(7f31082)",
            activePage: LegacyConsoleReport.gameRoot + "/000", freeBytes: 512 * 1024 * 1024,
            savesPath: "/var/lib/clover/profiles/0", stockCodes: stock, visibleCodes: stock)
    }

    @Test func consoleOrderUsesMetadataAndStableMissingFallback() throws {
        let a = game("CLV-H-AAAAA", name: "Zed", source: .local, release: "1988-01-01", publisher: "Zeta")
        let b = game("CLV-H-BBBBB", name: "Alpha", source: .local, release: "1985", publisher: "Alpha")
        let c = game("CLV-H-CCCCC", name: "Beta", source: .local)
        #expect(try ConsoleMenuOrder.title.ordered([a, b, c]).map(\.code) == [b.code, c.code, a.code])
        #expect(try ConsoleMenuOrder.releaseDate.ordered([a, b, c]).map(\.code) == [b.code, a.code, c.code])
        #expect(try ConsoleMenuOrder.publisher.ordered([a, b, c]).map(\.code) == [b.code, a.code, c.code])
        #expect(try ConsoleMenuOrder.manual([c.code, a.code, b.code]).ordered([a, b, c]).map(\.code) == [c.code, a.code, b.code])
        #expect(throws: SyncPlanError.self) {
            try ConsoleMenuOrder.manual([a.code, b.code]).ordered([a, b, c])
        }
    }

    @Test func fullScopeIncludesDeselectedLocalGamesAndOrderChangesReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try local("CLV-H-AAAAA", name: "Zed", release: "1985", publisher: "Zeta", in: root)
        let second = try local("CLV-H-BBBBB", name: "Alpha", release: "1990", publisher: "Alpha", in: root)
        let stockCodes = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let stock = stockCodes.map { game($0, name: $0, source: .stock) }
        let selected = stockCodes.union([first.code, second.code])
        let titled = try LegacySyncPlan.make(localGames: [first, second], remoteGames: stock,
            report: report(stock: stockCodes), selectedCodes: selected,
            maximumGamesPerPage: 25, trialCode: nil, consoleOrder: .title)
        let dated = try LegacySyncPlan.make(localGames: [first, second], remoteGames: stock,
            report: report(stock: stockCodes), selectedCodes: selected,
            maximumGamesPerPage: 25, trialCode: nil, consoleOrder: .releaseDate)
        #expect(titled.selectedGames.count == 32)
        #expect(Set(titled.selectedGames.map { $0.game.code }) == selected)
        #expect(titled.reviewSHA256 != dated.reviewSHA256)
        #expect(titled.pages.flatMap(\.gameCodes) == titled.selectedGames.map { $0.game.code })
        #expect(dated.pages.flatMap(\.gameCodes) == dated.selectedGames.map { $0.game.code })
        for (position, item) in dated.selectedGames.enumerated() {
            #expect(DesktopFile(data: item.desktopData).sortName == String(format: "A%05d", position))
        }
        let saved = try LegacySyncJournal(operationID: UUID(),
            reviewSHA256: dated.reviewSHA256,
            archiveSHA256: String(repeating: "b", count: 64),
            treeSHA256: String(repeating: "c", count: 64),
            backupSHA256: String(repeating: "d", count: 64),
            backupDirectory: root, stageDirectory: root,
            scope: .full, selectedCodes: Array(selected).sorted(), consoleOrder: .releaseDate,
            maximumGamesPerPage: 25, archiveBytes: 8192)
        #expect(saved.matches(dated))
        #expect(!saved.matches(titled))
    }
}
