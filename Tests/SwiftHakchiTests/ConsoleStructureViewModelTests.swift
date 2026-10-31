import Foundation
import Testing
@testable import SwiftHakchi

@Suite @MainActor
struct ConsoleStructureViewModelTests {
    private func games(_ count: Int, stock: Int = 0) -> [Game] {
        (0..<count).map { index in
            let builtIn = index < stock
            let code = String(format: "CLV-%@-%05d", builtIn ? "P" : "H", index)
            return Game(code: code, desktopContent: "Code=\(code)\nName=Game \(index)\n",
                        consoleType: .nes, source: builtIn ? .stock : .local)
        }
    }

    @Test func settingsEditResetAndCopyDoNotMoveGames() throws {
        let config = AppConfig()
        let selected = games(42)
        let model = ConsoleStructureViewModel(config: config, console: .nes,
                                              games: selected, stockCodes: [])
        model.setMode(.foldersEqual)
        model.setLimit(.twenty)
        model.setBackPosition(.top)
        #expect(model.graph?.screens.count == 4)
        try model.save()
        try model.copy(to: [.snesUsa])
        #expect(config.structure(for: .snesUsa).mode == .foldersEqual)
        #expect(config.structure(for: .nes).backPosition == .top)
        #expect(config.workspacePath == AppConfig.defaultWorkspace.path)
        model.resetToAutomatic()
        #expect(model.draft.mode == .automatic)
        #expect(config.structure(for: .nes).mode == .foldersEqual)
    }

    @Test func missingInventoryExplainsIncompletePreview() {
        let model = ConsoleStructureViewModel(config: AppConfig(), console: .nes,
                                              games: nil, stockCodes: nil)
        #expect(model.graph == nil)
        #expect(model.previewIssue != nil)
        #expect(!model.canActivate)
    }

    @Test func crowdedRootWarnsButObservedCombinationCanActivate() {
        let selected = games(31, stock: 30)
        let model = ConsoleStructureViewModel(config: AppConfig(), console: .nes,
            games: selected, stockCodes: Set(selected.filter(\.isStock).map(\.code)))
        model.setMode(.stockRootFoldersEqual)
        #expect(model.graph?.screens[0].entryCount == 31)
        #expect(model.graph?.warnings.contains(.stockRootHas31Entries) == true)
        #expect(!model.canActivate)
        model.setLimit(.twentyFive)
        #expect(model.graph?.screens[0].entryCount == 31)
        #expect(model.canActivate)

        let full = games(162, stock: 30)
        let fullModel = ConsoleStructureViewModel(config: AppConfig(), console: .nes,
            games: full, stockCodes: Set(full.filter(\.isStock).map(\.code)))
        fullModel.setMode(.stockRootFoldersEqual)
        fullModel.setLimit(.twentyFive)
        #expect(fullModel.graph?.screens.count == 8)
        #expect(!fullModel.canActivate)
    }

    @Test func customEditorAssignsEachGameOnceAndRefusesInvalidDraft() throws {
        let selected = games(42)
        let model = ConsoleStructureViewModel(config: AppConfig(), console: .nes,
                                              games: selected, stockCodes: [])
        model.startCustom()
        #expect(model.draft.mode == .custom)
        #expect(model.graph?.screens.flatMap(\.gameCodes).count == 42)
        let first = try #require(model.draft.custom?.folders.first?.id)
        model.renameFolder(first, to: "Favorites")
        model.assignGame(selected[0].code, to: first)
        #expect(model.graph?.screens.flatMap(\.gameCodes).filter { $0 == selected[0].code }.count == 1)
        model.renameFolder(first, to: "Bad\nFolder")
        #expect(model.graph == nil)
        #expect(model.previewIssue != nil)
        #expect(throws: (any Error).self) { try model.save() }
    }

    @Test func customLayoutCanReconcileAddedRemovedAndReplacedSelections() throws {
        let existing = games(42, stock: 1)
        let model = ConsoleStructureViewModel(config: AppConfig(), console: .nes,
            games: existing, stockCodes: [existing[0].code])
        model.startCustom()
        let newImported = Game(code: "CLV-H-NEW00", desktopContent: "Code=CLV-H-NEW00\nName=Replacement\n",
                               consoleType: .nes, source: .local)
        let expanded = existing + [newImported]
        model.setInventory(games: expanded, stockCodes: [existing[0].code])
        #expect(model.graph == nil)
        model.reconcileCustomSelection()
        #expect(model.graph?.screens.flatMap(\.gameCodes).count == expanded.count)

        let changed = Array(existing.dropFirst()) + [newImported]
        model.setInventory(games: changed, stockCodes: [])
        #expect(model.graph == nil)
        model.reconcileCustomSelection()
        let graph = try #require(model.graph)
        #expect(Set(graph.screens.flatMap(\.gameCodes)) == Set(changed.map(\.code)))
        #expect(graph.screens.flatMap(\.gameCodes).count == changed.count)
        #expect(!graph.screens.flatMap(\.gameCodes).contains(existing[0].code))
        try model.save()
    }
}
