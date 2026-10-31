import Foundation
import Testing
@testable import SwiftHakchi

struct ConsoleStructureSettingsTests {
    @Test func freshWorkspaceUsesAppSpecificApplicationSupportFolder() {
        guard ProcessInfo.processInfo.environment["SWIFTHAKCHI_WORKSPACE"]?.isEmpty != false else { return }
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hakchi Console Hub", isDirectory: true)
        #expect(AppConfig.defaultWorkspace == expected)
    }
    @Test func oldMenuLimitMigratesWithoutMovingWorkspaceOrLibraryOrder() throws {
        let legacy = Data(#"{"consoleMenuLimit":25,"libraryOrder":"dateModified","workspacePath":"/tmp/structure-legacy"}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: legacy)

        #expect(config.structure(for: .nes).mode == .pagesEqual)
        #expect(config.structure(for: .nes).maximumGamesPerPage == .twentyFive)
        #expect(config.structure(for: .snesUsa).maximumGamesPerPage == .twentyFive)
        #expect(config.libraryOrder == .dateModified)
        #expect(config.workspacePath == "/tmp/structure-legacy")
    }

    @Test func settingsStaySeparateByConsoleAndCopyOnlyTheStructure() throws {
        let config = AppConfig()
        config.workspacePath = "/tmp/structure-project"
        config.libraryOrder = .dateAdded
        let nes = ConsoleStructure(mode: .stockRootFoldersEqual,
                                   maximumGamesPerPage: .twentyFive,
                                   backPosition: .top, folderArt: .letterTiles)
        try config.setStructure(nes, for: .nes)
        #expect(config.structure(for: .snesUsa).mode == .pagesEqual)
        try config.copyStructure(from: .nes, to: [.snesUsa])

        let reopened = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(reopened.structure(for: .nes) == nes)
        #expect(reopened.structure(for: .snesUsa) == nes)
        #expect(reopened.structure(for: .famicom).mode == .pagesEqual)
        #expect(reopened.workspacePath == "/tmp/structure-project")
        #expect(reopened.libraryOrder == .dateAdded)
    }

    @Test func unknownVersionAndUnsafeFolderReferencesFailClosed() throws {
        let badVersion = Data(#"{"structureByConsole":{"nes-usa":{"version":99,"mode":"pagesEqual","maximumGamesPerPage":25,"backPosition":"bottom","folderArt":"classic"}}}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AppConfig.self, from: badVersion) }

        let config = AppConfig()
        let unsafe = ConsoleStructure(mode: .custom, maximumGamesPerPage: .twentyFive,
                                      backPosition: .bottom, folderArt: .custom,
                                      custom: .init(rootGameCodes: [], folders: [
                                        .init(id: "A", title: "Arcade", parentID: nil,
                                              gameCodes: [], artKey: "../../outside.png")
                                      ]))
        #expect(throws: (any Error).self) { try config.setStructure(unsafe, for: .nes) }
        #expect(config.structure(for: .nes).mode == .pagesEqual)
    }

    @Test func appLoadDoesNotSilentlyReplaceUnsupportedSavedStructure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        let original = Data(#"{"workspacePath":"/tmp/keep-workspace","libraryOrder":"dateModified","structureByConsole":{"nes-usa":{"version":99,"mode":"pagesEqual","maximumGamesPerPage":25,"backPosition":"bottom","folderArt":"classic"}}}"#.utf8)
        try original.write(to: file)

        let loaded = AppConfig.load(from: file)
        #expect(loaded.structureLoadIssue != nil)
        #expect(loaded.workspacePath == "/tmp/keep-workspace")
        #expect(loaded.libraryOrder == .dateModified)
        loaded.save(to: file)
        #expect(try Data(contentsOf: file) == original)
        #expect(throws: (any Error).self) { try loaded.updateLegacyMenuLimit(.twenty) }
        #expect(loaded.structureLoadIssue != nil)
        #expect(try Data(contentsOf: file) == original)
    }
}
