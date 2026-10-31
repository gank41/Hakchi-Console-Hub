import Foundation
import SwiftHakchiCore

/// Pure layout planner. It opens no local files and never contacts a console.
enum ConsoleStructurePlanner {
    private struct Draft {
        var title: String
        var codes: [String]
        var links: [ConsoleMenuGraph.Link] = []
    }

    static func make(games: [Game], stockCodes: Set<String>, order: ConsoleMenuOrder,
                     structure: ConsoleStructure) throws -> ConsoleMenuGraph {
        try structure.validate()
        guard !games.isEmpty, Set(games.map(\.code)).count == games.count,
              games.allSatisfy({ SyncPlanner.validCode($0.code) && !$0.code.hasPrefix("CLV-S-") }),
              stockCodes.isSubset(of: Set(games.map(\.code))),
              stockCodes.allSatisfy({ code in games.contains(where: { $0.code == code && $0.isStock }) }) else {
            throw SyncPlanError.invalidInput("Choose valid, distinct games and an exact built-in inventory.")
        }
        let ordered = try order.ordered(games)
        let builtIn = ordered.filter { stockCodes.contains($0.code) }
        let imported = ordered.filter { !stockCodes.contains($0.code) }
        let limit = structure.maximumGamesPerPage.rawValue
        let stockRoot: Bool
        let mode: ConsoleStructure.Mode
        switch structure.mode {
        case .automatic, .stockRootAutomatic:
            stockRoot = structure.mode == .stockRootAutomatic
            let count = stockRoot ? imported.count : games.count
            let pageCount = (count + limit - 1) / limit
            mode = pageCount < 12 ? (stockRoot ? .stockRootPagesEqual : .pagesEqual)
                                  : (stockRoot ? .stockRootFoldersEqual : .foldersEqual)
        default:
            stockRoot = [.stockRootPagesEqual, .stockRootFoldersEqual, .stockRootFoldersAlphabetical].contains(structure.mode)
            mode = structure.mode
        }
        var drafts = [Draft(title: "Games", codes: [])]
        func screen(_ title: String, _ codes: [String] = []) -> Int {
            let number = drafts.count
            drafts.append(Draft(title: title, codes: codes))
            return number
        }
        func link(_ source: Int, _ target: Int, _ role: ConsoleMenuGraph.Role,
                  _ title: String, _ art: String? = nil) {
            drafts[source].links.append(.init(target: target, title: title, role: role, artKey: art))
        }
        func pages(_ sourceCodes: [String], root: Int, reserveRoot: Bool) throws {
            guard !sourceCodes.isEmpty else { return }
            let pages = try MenuPaginator.pages(codes: sourceCodes, maximumGamesPerPage: limit)
            if reserveRoot {
                let first = drafts.count
                for page in pages { _ = screen("Games \(page.number + 1)", page.gameCodes) }
                link(root, first, .folder, "More games...")
                for page in pages {
                    let number = first + page.number
                    link(number, page.previousPage.map { first + $0 } ?? root, .back, "Previous games")
                    if let next = page.nextPage { link(number, first + next, .more, "More games...") }
                }
            } else {
                // Preserve exact page numbering and link targets of the accepted menu.
                drafts[0].codes = pages[0].gameCodes
                for page in pages.dropFirst() { _ = screen("Games \(page.number + 1)", page.gameCodes) }
                for page in pages {
                    if let previous = page.previousPage { link(page.number, previous, .back, "Previous games") }
                    if let next = page.nextPage { link(page.number, next, .more, "More games...") }
                }
            }
        }
        func equalFolders(_ sourceCodes: [String], root: Int, useHub: Bool) throws {
            guard !sourceCodes.isEmpty else { return }
            let parent: Int
            if useHub {
                parent = screen("More games")
                link(root, parent, .folder, "More games...")
                link(parent, root, .back, "Previous games")
            } else { parent = root }
            let parts = try MenuPaginator.pages(codes: sourceCodes, maximumGamesPerPage: limit)
            for part in parts {
                let child = screen("Games \(part.number + 1)", part.gameCodes)
                link(parent, child, .folder, "Games \(part.number + 1)")
                link(child, parent, .back, "Previous games")
            }
        }
        func alphabetical(_ sourceGames: [Game], root: Int, useHub: Bool) throws {
            guard !sourceGames.isEmpty else { return }
            let parent: Int
            if useHub {
                parent = screen("More games")
                link(root, parent, .folder, "More games...")
                link(parent, root, .back, "Previous games")
            } else { parent = root }
            let groups = Dictionary(grouping: sourceGames, by: firstLetter)
            for letter in groups.keys.sorted() {
                let codes = groups[letter]!.map(\.code)
                if codes.count <= limit {
                    let child = screen(letter, codes)
                    link(parent, child, .folder, letter)
                    link(child, parent, .back, "Previous games")
                } else {
                    let group = screen(letter)
                    link(parent, group, .folder, letter)
                    link(group, parent, .back, "Previous games")
                    let parts = try MenuPaginator.pages(codes: codes, maximumGamesPerPage: limit)
                    for part in parts {
                        let child = screen("\(letter) \(part.number + 1)", part.gameCodes)
                        link(group, child, .folder, "\(letter) \(part.number + 1)")
                        link(child, group, .back, "Previous games")
                    }
                }
            }
        }
        if stockRoot { drafts[0].codes = builtIn.map(\.code) }
        switch mode {
        case .flat:
            guard games.count <= 30 else { throw SyncPlanError.invalidInput("One screen supports at most 30 games. Choose pages or folders.") }
            drafts[0].codes = ordered.map(\.code)
        case .pagesEqual:
            try pages(ordered.map(\.code), root: 0, reserveRoot: false)
        case .stockRootPagesEqual:
            try pages(imported.map(\.code), root: 0, reserveRoot: true)
        case .foldersEqual:
            try equalFolders(ordered.map(\.code), root: 0, useHub: false)
        case .stockRootFoldersEqual:
            try equalFolders(imported.map(\.code), root: 0, useHub: true)
        case .foldersAlphabetical:
            try alphabetical(ordered, root: 0, useHub: false)
        case .stockRootFoldersAlphabetical:
            try alphabetical(imported, root: 0, useHub: true)
        case .custom:
            guard let custom = structure.custom else { throw SyncPlanError.invalidInput("Custom folders are missing.") }
            let rank = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.code, $0.offset) })
            func orderedCodes(_ codes: [String]) -> [String] {
                codes.sorted { (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1) }
            }
            drafts[0].codes = orderedCodes(custom.rootGameCodes)
            var numberByID: [String: Int] = [:]
            for folder in custom.folders { numberByID[folder.id] = screen(folder.title, orderedCodes(folder.gameCodes)) }
            for folder in custom.folders {
                let child = numberByID[folder.id]!
                let parent = folder.parentID.flatMap { numberByID[$0] } ?? 0
                link(parent, child, .folder, folder.title, folder.artKey)
                link(child, parent, .back, "Previous games")
                guard !folder.gameCodes.isEmpty || custom.folders.contains(where: { $0.parentID == folder.id }) else {
                    throw SyncPlanError.invalidInput("A custom folder cannot be empty.")
                }
            }
        case .automatic, .stockRootAutomatic:
            fatalError("Automatic layout must resolve before building a graph.")
        }
        let screens = drafts.enumerated().map { number, draft in
            ConsoleMenuGraph.Screen(number: number, title: draft.title, gameCodes: draft.codes,
                                    links: draft.links, backPosition: structure.backPosition)
        }
        let crowded = screens[0].gameCodes.count == 30 && screens[0].entryCount == 31
        let graph = ConsoleMenuGraph(screens: screens, warnings: crowded ? [.stockRootHas31Entries] : [],
                                     maximumGamesPerPage: limit, resolvedMode: mode)
        try graph.validate(selectedCodes: Set(games.map(\.code)))
        return graph
    }

    private static func firstLetter(_ game: Game) -> String {
        let folded = game.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
        guard let first = folded.unicodeScalars.first,
              (65...90).contains(first.value) else { return "#" }
        return String(first)
    }
}
