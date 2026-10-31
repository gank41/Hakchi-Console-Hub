import Foundation
import Testing
import Combine
@testable import SwiftHakchi
@testable import SwiftHakchiCore

@Suite(.serialized) @MainActor
struct BulkSelectionTests {
    func game(_ code: String, source: GameSource = .local, selected: Bool = false) -> Game {
        var value = Game(code: code, desktopContent: "Code=\(code)\nName=\(code)", consoleType: .nes, source: source)
        value.isSelected = selected
        return value
    }
    @Test func bulkActionsOnlyChangeRequestedGamesAndPublishOnce() {
        let manager = GameManagerService()
        manager.games = [game("CLV-H-AAAAA"), game("CLV-H-BBBBB"), game("CLV-H-CCCCC", selected: true), game("CLV-P-AAAAA", source: .stock, selected: true)]
        var publications = 0
        let observation = manager.$games.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        manager.setSelection(true, codes: ["CLV-H-AAAAA", "CLV-H-BBBBB", "unknown"])
        #expect(manager.games.map(\.isSelected) == [true,true,true,true])
        #expect(publications == 1)
        manager.setSelection(false, codes: ["CLV-H-AAAAA", "CLV-H-BBBBB"])
        #expect(manager.games.map(\.isSelected) == [false,false,true,true])
        #expect(publications == 2)
        manager.setSelection(false, codes: [])
        #expect(publications == 2)
    }
    @Test func selectionPersistsForCustomAndOriginalGamesAndInspectionIsReadOnly() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared; let previous = config.workspacePath
        config.workspacePath = root.path; defer { config.workspacePath = previous }
        let manager = GameManagerService()
        manager.games = [game("CLV-H-AAAAA"), game("CLV-P-AAAAA", source: .stock)]
        manager.configureSelection(deviceID: "BULK-TEST", consoleType: .nes)
        let codes = Set(manager.games.map(\.code))
        manager.setSelection(true, codes: codes)
        let store = ConsoleProfileStore(directory: config.workspace.profiles)
        #expect(try store.load(deviceID: "BULK-TEST", systemCode: "nes-usa")?.selectedCustomCodes == ["CLV-H-AAAAA"])
        #expect(try store.load(deviceID: "BULK-TEST", systemCode: "nes-usa")?.hiddenStockCodes.isEmpty == true)
        manager.setSelection(false, codes: codes)
        let saved = try store.load(deviceID: "BULK-TEST", systemCode: "nes-usa")
        #expect(saved?.selectedCustomCodes.isEmpty == true)
        #expect(saved?.hiddenStockCodes == ["CLV-P-AAAAA"])
        manager.isLoading = true; manager.setSelection(true, codes: codes)
        #expect(manager.games.allSatisfy { !$0.isSelected })
        manager.isLoading = false
        manager.mergeInspectionGames([game("CLV-H-AAAAA", source: .console)])
        manager.setSelection(true, codes: codes)
        #expect(manager.games.allSatisfy { !$0.isSelected })
        #expect(try store.load(deviceID: "BULK-TEST", systemCode: "nes-usa") == saved)
        manager.clearConsoleGames()
        #expect(manager.games.allSatisfy { !$0.isSelected })
    }
}
