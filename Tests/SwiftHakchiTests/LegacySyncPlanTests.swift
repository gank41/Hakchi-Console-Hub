import Foundation
import Testing
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct LegacySyncPlanTests {
    private func report(stock: Set<String>, installed: Set<String> = []) -> LegacyConsoleReport {
        LegacyConsoleReport(bootVersion: "1.0.1", kernelVersion: "3.4.112.madmonkey",
                            scriptVersion: "[master]v1.0.3-110(7f31082)",
                            activePage: LegacyConsoleReport.gameRoot + "/000", freeBytes: 512 * 1024 * 1024,
                            savesPath: "/var/lib/clover/profiles/0", stockCodes: stock,
                            visibleCodes: stock.union(installed))
    }

    private func game(_ code: String, name: String, source: GameSource) -> Game {
        let launchROM = source == .stock
            ? "/usr/share/games/nes/kachikachi/\(code)/\(code).nes"
            : "/var/games/\(code)/game.nes"
        var value = Game(code: code, desktopContent: "Code=\(code)\nName=\(name)\nExec=/bin/clover-kachikachi-wr \(launchROM)",
                         consoleType: .nes, source: source)
        value.isSelected = true
        return value
    }

    private func local(_ code: String, name: String, in root: URL) throws -> Game {
        let folder = root.appendingPathComponent(code, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x4E, 0x45, 0x53, 0x1A] + Array(repeating: 0, count: 64)).write(to: folder.appendingPathComponent("game.nes"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: folder.appendingPathComponent(code + ".png"))
        let desktop = "[Desktop Entry]\nCode=\(code)\nName=\(name)\nExec=/bin/clover-kachikachi-wr /var/games/\(code)/game.nes\nIcon=/var/games/\(code)/\(code).png\n"
        try Data(desktop.utf8).write(to: folder.appendingPathComponent(code + ".desktop"))
        var value = Game(desktopFile: DesktopFile(string: desktop), consoleType: .nes, basePath: root.path, source: .local)
        value.isSelected = true
        return value
    }

    @Test func localEditsWinAndTrialKeepsStockGames() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let code = "CLV-H-AAAAA", old = "CLV-H-BBBBB"
        var edited = try local(code, name: "Edited Title", in: root)
        edited.publisher = "Edited Publisher"
        let stockCodes = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let remote = stockCodes.map { game($0, name: $0, source: .stock) }
            + [game(code, name: "OLD UPPERCASE", source: .console), game(old, name: "Old Game", source: .console)]
        let plan = try LegacySyncPlan.make(localGames: [edited], remoteGames: remote,
            report: report(stock: stockCodes, installed: [code, old]), selectedCodes: [code],
            maximumGamesPerPage: 25, trialCode: code)
        #expect(plan.selectedGames.count == 31)
        #expect(plan.selectedGames.first(where: { $0.game.code == code })?.game.name == "Edited Title")
        #expect(plan.selectedGames.first(where: { $0.game.code == code })?.game.publisher == "Edited Publisher")
        #expect(plan.selectedGames.first(where: { $0.game.code == code })?.coverURL != nil)
        #expect(plan.addedCodes.isEmpty)
        #expect(plan.removedCodes == [old])
        #expect(plan.keptCodes == [code])
        #expect(plan.pages.allSatisfy { $0.gameCodes.count <= 25 })
        #expect(plan.requiredStagingBytes > 64 * 1024 * 1024)
    }

    @Test func missingSelectionDuplicatesAndChangedSourcesRefuse() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let code = "CLV-H-AAAAA"
        let localGame = try local(code, name: "Edited", in: root)
        let stockCodes = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let remote = stockCodes.map { game($0, name: "Stock", source: .stock) }
        let device = report(stock: stockCodes)
        #expect(throws: SyncPlanError.self) {
            try LegacySyncPlan.make(localGames: [localGame], remoteGames: remote, report: device,
                                    selectedCodes: [], maximumGamesPerPage: 25, trialCode: nil)
        }
        #expect(throws: SyncPlanError.self) {
            try LegacySyncPlan.make(localGames: [localGame, localGame], remoteGames: remote, report: device,
                                    selectedCodes: [code], maximumGamesPerPage: 25, trialCode: code)
        }
        let plan = try LegacySyncPlan.make(localGames: [localGame], remoteGames: remote, report: device,
                                          selectedCodes: [code], maximumGamesPerPage: 25, trialCode: code)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(code).appendingPathComponent("game.nes"))
        #expect(throws: SyncPlanError.self) { try plan.verifyLocalSources() }
    }

    @Test func inspectionKeepsEditedLocalGameAndSelection() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let manager = GameManagerService()
        let localGame = try local("CLV-H-AAAAA", name: "Edited Name", in: root)
        manager.games = [localGame]
        manager.mergeInspectionGames([game("CLV-H-AAAAA", name: "OLD NAME", source: .console),
                                      game("CLV-H-BBBBB", name: "Old Only", source: .console)])
        #expect(manager.games.first(where: { $0.code == localGame.code })?.name == "Edited Name")
        #expect(manager.games.first(where: { $0.code == localGame.code })?.isSelected == true)
        #expect(manager.games.first(where: { $0.code == localGame.code })?.isOnConsole == true)
        #expect(manager.legacyRemoteGames.count == 2)
        manager.clearConsoleGames()
        #expect(manager.games.map(\.code) == [localGame.code])
    }

    @Test func missingArtUnsupportedLauncherAndLinkedROMRefuseReview() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let code = "CLV-H-AAAAA"
        let original = try local(code, name: "Trial", in: root)
        let stockCodes = Set((0..<30).map { String(format: "CLV-P-%05d", $0) })
        let remote = stockCodes.map { game($0, name: "Stock", source: .stock) }
        let device = report(stock: stockCodes)
        var unsupported = original
        unsupported.commandLine = "/bin/retroarch /var/games/\(code)/game.nes"
        #expect(throws: SyncPlanError.self) {
            try LegacySyncPlan.make(localGames: [unsupported], remoteGames: remote, report: device,
                                    selectedCodes: [code], maximumGamesPerPage: 25, trialCode: code)
        }
        let cover = root.appendingPathComponent(code).appendingPathComponent(code + ".png")
        try FileManager.default.removeItem(at: cover)
        #expect(throws: (any Error).self) {
            try LegacySyncPlan.make(localGames: [original], remoteGames: remote, report: device,
                                    selectedCodes: [code], maximumGamesPerPage: 25, trialCode: code)
        }
        try Data([1]).write(to: cover)
        let rom = root.appendingPathComponent(code).appendingPathComponent("game.nes")
        try FileManager.default.removeItem(at: rom)
        try FileManager.default.createSymbolicLink(at: rom, withDestinationURL: cover)
        #expect(throws: SyncPlanError.self) {
            try LegacySyncPlan.make(localGames: [original], remoteGames: remote, report: device,
                                    selectedCodes: [code], maximumGamesPerPage: 25, trialCode: code)
        }
    }
}
