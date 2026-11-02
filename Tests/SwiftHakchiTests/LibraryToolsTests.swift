import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized) @MainActor
struct LibraryToolsTests {
    func game(_ code: String, _ name: String) -> Game {
        Game(code: code, desktopContent: "Code=\(code)\nName=\(name)", consoleType: .nes, source: .local)
    }
    @Test func orderUsesEditedNameAndStableDateTies() {
        var a = game("CLV-H-AAAAA", "Zebra"), b = game("CLV-H-BBBBB", "beta")
        #expect(LibraryOrder.nameAscending.ordered([a,b]).map(\.code) == [b.code,a.code])
        a.name = "Alpha"
        #expect(LibraryOrder.nameAscending.ordered([b,a]).map(\.code) == [a.code,b.code])
        #expect(LibraryOrder.nameDescending.ordered([a,b]).map(\.code) == [b.code,a.code])
        a.addedAt = Date(timeIntervalSince1970: 100); b.addedAt = Date(timeIntervalSince1970: 200)
        a.modifiedAt = Date(timeIntervalSince1970: 300)
        #expect(LibraryOrder.dateAdded.ordered([a,b]).map(\.code) == [b.code,a.code])
        #expect(LibraryOrder.dateModified.ordered([b,a]).map(\.code) == [a.code,b.code])
        b.modifiedAt = a.modifiedAt
        #expect(LibraryOrder.dateModified.ordered([b,a]).map(\.code) == [a.code,b.code])
    }
    @Test func cheatCopiesCanBeSortedFirstEvenAfterRenaming() throws {
        let plain = game("CLV-H-AAAAA", "A game")
        var copy = game("CLV-H-BBBBB", "Z game [Cheat Code]")
        copy.name = "Renamed copy"
        let other = game("CLV-H-CCCCC", "Another game")
        #expect(copy.isCheatCodeCopy && !plain.isCheatCodeCopy)
        #expect(LibraryOrder.cheatCodesFirst.ordered([plain, other, copy]).map(\.code) == [copy.code, plain.code, other.code])
        #expect(try JSONDecoder().decode(LibraryOrder.self, from: JSONEncoder().encode(LibraryOrder.cheatCodesFirst)) == .cheatCodesFirst)
    }
    @Test func timestampsPersistWithoutLeakingIntoConsoleMetadata() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let old = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = old }
        let source = root.appendingPathComponent("test.nes"); try NESROMIdentityTests.rom().write(to: source)
        let manager = GameManagerService(); try manager.importROMs(urls: [source], consoleType: .nes)
        var game = try #require(manager.games.first)
        let added = try #require(game.addedAt)
        game.name = "A changed title"; manager.saveGame(game)
        let reloaded = GameManagerService(); reloaded.loadGames()
        let saved = try #require(reloaded.games.first { $0.id == game.id })
        #expect(abs(try #require(saved.addedAt).timeIntervalSince(added)) < 0.001)
        #expect(try #require(saved.modifiedAt) >= added)
        #expect(saved.name == "A changed title")
        #expect(!SyncPlanAdapter.desktopFile(for: saved).serialize().contains("X-SwiftHakchi-AddedAt"))
        #expect(!SyncPlanAdapter.desktopFile(for: saved).serialize().contains("X-SwiftHakchi-ModifiedAt"))
    }
    @Test func legacyDatesUseFilesystemAndDoNotRewriteMetadataOnLoad() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CLV-H-AAAAA"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("CLV-H-AAAAA.desktop")
        let data = Data("Code=CLV-H-AAAAA\nName=Old title".utf8); try data.write(to: file)
        let creation = try file.resourceValues(forKeys: [.creationDateKey]).creationDate
        let loaded = Game(desktopFile: DesktopFile(data: data), consoleType: .nes, basePath: root.path)
        #expect(loaded.addedAt == creation)
        #expect(try Data(contentsOf: file) == data)
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.libraryOrder == .nameAscending)
        config.libraryOrder = .dateModified
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)).libraryOrder == .dateModified)
    }
}
