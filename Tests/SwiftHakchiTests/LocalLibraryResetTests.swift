import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct LocalLibraryResetTests {
    @Test func replacingLibraryPreservesMatchingEditsButUsesNewROMFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = AppConfig(); config.workspacePath = root.appendingPathComponent("workspace").path
        config.lastConsoleType = .nes
        let original = root.appendingPathComponent("OLD TITLE.nes")
        let renamed = root.appendingPathComponent("New filename.nes")
        let bytes = Data([78, 69, 83, 26, 1] + Array(repeating: UInt8(0), count: 11 + 16384))
        try bytes.write(to: original); try bytes.write(to: renamed)
        let manager = GameManagerService(config: config)
        try manager.importROMs(urls: [original], consoleType: .nes)
        var edited = try #require(manager.games.first)
        edited.name = "My Edited Title"; edited.publisher = "Edited Publisher"; edited.releaseDate = "1988"
        let art = config.gamesDirectory.appendingPathComponent(edited.code).appendingPathComponent(edited.code + ".png")
        try Data([1, 2, 3]).write(to: art); edited.coverArtPath = art.path
        #expect(manager.saveGame(edited))
        let archived = try manager.replaceLocalLibrary(urls: [renamed], consoleType: .nes, preservingEdits: true)
        let replacement = try #require(manager.games.first)
        #expect(replacement.name == edited.name)
        #expect(replacement.publisher == edited.publisher)
        #expect(replacement.releaseDate == "1988")
        #expect(replacement.commandLine.contains("New filename.nes"))
        #expect(!replacement.commandLine.contains("OLD TITLE.nes"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(replacement.coverArtPath))) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: archived.appendingPathComponent(edited.code).appendingPathComponent("OLD TITLE.nes").path))
        manager.loadGames()
        #expect(manager.games.first?.name == "My Edited Title")
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func failedReplacementRestoresPreviousLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = AppConfig(); config.workspacePath = root.appendingPathComponent("workspace").path
        config.lastConsoleType = .nes
        let original = root.appendingPathComponent("Original.nes")
        try Data([78, 69, 83, 26] + Array(repeating: UInt8(0), count: 60)).write(to: original)
        let badArchive = root.appendingPathComponent("broken.zip")
        try Data([0]).write(to: badArchive)
        let manager = GameManagerService(config: config)
        try manager.importROMs(urls: [original], consoleType: .nes)
        let code = try #require(manager.games.first?.code)
        #expect(throws: (any Error).self) {
            try manager.replaceLocalLibrary(urls: [badArchive], consoleType: .nes, preservingEdits: true)
        }
        #expect(manager.games.contains { $0.code == code })
        #expect(FileManager.default.fileExists(atPath: config.gamesDirectory.appendingPathComponent(code).appendingPathComponent("Original.nes").path))
    }
    @Test func switchingConsoleDoesNotCarryNESStockGamesIntoSNESLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .snesUsa
        let manager = GameManagerService(config: config)
        manager.games = [Game(code: "CLV-P-AAAAA", desktopContent: "Name=NES Game\n", consoleType: .nes, source: .stock)]
        manager.loadGames()
        #expect(manager.games.isEmpty)
    }
    @Test func removingLibraryKeepsRecoverableFilesAndOtherConsoleLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig(); config.workspacePath = root.path; config.lastConsoleType = .nes
        let directory = config.gamesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("game.nes"))
        let snes = config.workspace.gamesDirectory(systemCode: ConsoleType.snesUsa.syncCode)
        try FileManager.default.createDirectory(at: snes, withIntermediateDirectories: true)
        try Data([4]).write(to: snes.appendingPathComponent("other.sfc"))
        let manager = GameManagerService(config: config)
        let archived = try manager.archiveLocalLibrary()
        #expect(try Data(contentsOf: archived.appendingPathComponent("game.nes")) == Data([1, 2, 3]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: snes.appendingPathComponent("other.sfc").path))
    }
}
