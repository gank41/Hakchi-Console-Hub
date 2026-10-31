import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct ConsoleStructurePlannerTests {
    private func games(stock: Int = 30, imported: Int = 132) -> ([Game], Set<String>) {
        var result: [Game] = []
        for index in 0..<(stock + imported) {
            let builtIn = index < stock
            let code = String(format: "CLV-%@-%05d", builtIn ? "P" : "H", index)
            let name = String(format: "Game %03d", index)
            result.append(Game(code: code, desktopContent: "[Desktop Entry]\nName=\(name)\nSortRawTitle=\(name)\n", consoleType: .nes,
                               source: builtIn ? .stock : .local))
        }
        return (result, Set(result.filter(\.isStock).map(\.code)))
    }

    @Test func allTenModesPlaceEachGameExactlyOnce() throws {
        let (games, stock) = games()
        for mode in ConsoleStructure.Mode.allCases {
            if mode == .flat { continue }
            let custom = mode == .custom ? ConsoleStructure.CustomFolderTree(
                rootGameCodes: Array(games.prefix(25).map(\.code)),
                folders: (0..<5).map { index in
                    let slice = Array(games.dropFirst(25).dropFirst(index * 30).prefix(30).map(\.code))
                    return .init(id: "extra\(index)", title: "More games \(index + 1)", parentID: nil,
                                 gameCodes: slice, artKey: nil)
                }) : nil
            let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
                structure: .init(mode: mode, custom: custom))
            try graph.validate(selectedCodes: Set(games.map(\.code)))
            #expect(graph.screens.flatMap(\.gameCodes).count == games.count)
            #expect(graph.screens.first?.number == 0)
        }
    }

    @Test func defaultPagesMatchLegacyPaginatorExactly() throws {
        let (games, stock) = games()
        let ordered = try ConsoleMenuOrder.title.ordered(games).map(\.code)
        let expected = try MenuPaginator.pages(codes: ordered, maximumGamesPerPage: 30)
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
                                                     structure: .init())
        #expect(graph.screens.count == expected.count)
        for (screen, page) in zip(graph.screens, expected) {
            #expect(screen.number == page.number)
            #expect(screen.gameCodes == page.gameCodes)
            #expect(screen.links.first(where: { $0.role == .back })?.target == page.previousPage)
            #expect(screen.links.first(where: { $0.role == .more })?.target == page.nextPage)
        }
    }

    @Test func builtInRootWarnsAboutThirtyFirstNavigationEntry() throws {
        let (games, stock) = games()
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
            structure: .init(mode: .stockRootFoldersEqual))
        #expect(graph.screens[0].gameCodes.count == 30)
        #expect(graph.screens[0].entryCount == 31)
        #expect(graph.warnings.contains(.stockRootHas31Entries))
        #expect(graph.screens[0].links.count == 1)
    }

    @Test func builtInRootWithImportedPagesKeepsStockOutOfAllChildPages() throws {
        let (games, stock) = games(stock: 30, imported: 134)
        let structure = ConsoleStructure(mode: .stockRootPagesEqual, maximumGamesPerPage: .thirtyFive)
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title, structure: structure)
        #expect(Set(graph.screens[0].gameCodes) == stock)
        #expect(graph.screens.count == 5)
        #expect(graph.screens.dropFirst().allSatisfy { $0.gameCodes.count <= 35 && Set($0.gameCodes).isDisjoint(with: stock) })
        #expect(LegacyStructureHardwareSupport.canActivate(structure, graph: graph, stockCodes: stock))
        #expect(!LegacyStructureHardwareSupport.canActivate(.init(mode: .stockRootPagesEqual, maximumGamesPerPage: .thirtyFive, backPosition: .top), graph: graph, stockCodes: stock))
    }

    @Test func builtInRootWithOneDeselectedGameStillFitsConfiguredPages() throws {
        let (games, stock) = games(stock: 29, imported: 103)
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
            structure: .init(mode: .stockRootPagesEqual, maximumGamesPerPage: .twentyFive,
                             backPosition: .top))
        #expect(graph.screens[0].gameCodes.count == 29)
        #expect(graph.screens[0].entryCount == 30)
        #expect(graph.warnings.isEmpty)
    }

    @Test func backPlacementAndFlatLimit() throws {
        let (games, stock) = games(stock: 0, imported: 31)
        #expect(throws: (any Error).self) {
            try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
                                             structure: .init(mode: .flat))
        }
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
            structure: .init(mode: .foldersEqual, backPosition: .top))
        let child = try #require(graph.screens.first(where: { $0.number != 0 && !$0.gameCodes.isEmpty }))
        #expect(child.entries.first == .link(child.links.first(where: { $0.role == .back })!.target))
    }

    @Test func alphabeticalHandlesAccentsNumbersAndOverfullLetters() throws {
        var (games, stock) = games(stock: 0, imported: 55)
        for index in games.indices {
            games[index].name = index == 0 ? "Éclair" : index == 1 ? "7th Guest" : "Alpha \(index)"
            games[index].sortName = games[index].name
        }
        let graph = try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
            structure: .init(mode: .foldersAlphabetical, maximumGamesPerPage: .twenty))
        try graph.validate(selectedCodes: Set(games.map(\.code)))
        #expect(graph.screens.contains(where: { $0.title == "E" }))
        #expect(graph.screens.contains(where: { $0.title == "#" }))
        #expect(graph.screens.contains(where: { $0.title == "A" }))
        #expect(graph.screens.count > 4)
    }

    @Test func malformedGraphsAndCustomCyclesFailClosed() throws {
        let (games, stock) = games(stock: 0, imported: 2)
        let cycle = ConsoleStructure.CustomFolderTree(rootGameCodes: [], folders: [
            .init(id: "A", title: "A", parentID: "B", gameCodes: [games[0].code], artKey: nil),
            .init(id: "B", title: "B", parentID: "A", gameCodes: [games[1].code], artKey: nil)
        ])
        #expect(throws: (any Error).self) {
            try ConsoleStructurePlanner.make(games: games, stockCodes: stock, order: .title,
                                             structure: .init(mode: .custom, custom: cycle))
        }
        let repeated = ConsoleMenuGraph(screens: [
            .init(number: 0, title: "Root", gameCodes: games.map(\.code), links: [
                .init(target: 1, title: "One", role: .folder, artKey: nil),
                .init(target: 1, title: "Again", role: .folder, artKey: nil)]),
            .init(number: 1, title: "Child", gameCodes: [], links: [.init(target: 0, title: "Back", role: .back, artKey: nil)])
        ], warnings: [])
        #expect(throws: (any Error).self) { try repeated.validate(selectedCodes: Set(games.map(\.code))) }

        let missing = ConsoleMenuGraph(screens: [
            .init(number: 0, title: "Root", gameCodes: [games[0].code], links: [])
        ], warnings: [])
        #expect(throws: (any Error).self) { try missing.validate(selectedCodes: Set(games.map(\.code))) }

        let unreachable = ConsoleMenuGraph(screens: [
            .init(number: 0, title: "Root", gameCodes: [games[0].code], links: []),
            .init(number: 1, title: "Lost", gameCodes: [games[1].code], links: [])
        ], warnings: [])
        #expect(throws: (any Error).self) { try unreachable.validate(selectedCodes: Set(games.map(\.code))) }

        let unsafe = ConsoleMenuGraph(screens: [
            .init(number: 0, title: "Bad\nName", gameCodes: games.map(\.code), links: [])
        ], warnings: [])
        #expect(throws: (any Error).self) { try unsafe.validate(selectedCodes: Set(games.map(\.code))) }

        let tooMany = ConsoleMenuGraph(screens: (0..<1000).map { index in
            .init(number: index, title: "Page", gameCodes: index == 0 ? games.map(\.code) : [],
                  links: index < 999 ? [.init(target: index + 1, title: "Next", role: .more, artKey: nil)] : [])
        }, warnings: [])
        #expect(throws: (any Error).self) { try tooMany.validate(selectedCodes: Set(games.map(\.code))) }
    }
}
