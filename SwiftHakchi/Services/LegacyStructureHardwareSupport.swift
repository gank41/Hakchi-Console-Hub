import Foundation

/// Modes may be reviewed and staged before their console behavior is verified.
enum LegacyStructureHardwareSupport {
    static func canActivate(_ structure: ConsoleStructure) -> Bool {
        structure.mode == .pagesEqual && structure.backPosition == .bottom
            && structure.folderArt == .classic && structure.custom == nil
    }

    static func canActivate(_ plan: LegacySyncPlan) -> Bool {
        canActivate(plan.structure, graph: plan.menuGraph, stockCodes: plan.report.stockCodes)
    }

    static func canActivate(_ structure: ConsoleStructure, graph: ConsoleMenuGraph,
                            stockCodes: Set<String>) -> Bool {
        if canActivate(structure) { return true }
        // This bounded layout combines the 30-game factory root with the same
        // sequential Previous/More pages used by the existing NES adapter.
        if structure.mode == .stockRootPagesEqual,
           structure.maximumGamesPerPage == .thirtyFive,
           structure.backPosition == .bottom, structure.folderArt == .classic,
           structure.custom == nil, graph.resolvedMode == .stockRootPagesEqual,
           graph.maximumGamesPerPage == 35, stockCodes.count == 30,
           let root = graph.screens.first, Set(root.gameCodes) == stockCodes {
            do { try graph.validate(selectedCodes: Set(graph.screens.flatMap(\.gameCodes))) }
            catch { return false }
            if graph.screens.count == 1 { return root.links.isEmpty }
            guard root.links.count == 1, root.links[0].role == .folder,
                  root.links[0].target == 1 else { return false }
            for page in graph.screens.dropFirst() {
                let last = page.number == graph.screens.count - 1
                guard !page.gameCodes.isEmpty, page.gameCodes.count <= 35,
                      Set(page.gameCodes).isDisjoint(with: stockCodes), page.backPosition == .bottom,
                      page.links.count == (last ? 1 : 2),
                      page.links.contains(where: { $0.role == .back && $0.target == page.number - 1 }),
                      last || page.links.contains(where: { $0.role == .more && $0.target == page.number + 1 }) else { return false }
            }
            return true
        }
        guard structure.mode == .stockRootFoldersEqual,
              structure.maximumGamesPerPage == .twentyFive,
              structure.backPosition == .bottom, structure.folderArt == .classic,
              structure.custom == nil, graph.resolvedMode == .stockRootFoldersEqual,
              stockCodes.count == 30, graph.screens.count == 3 else { return false }
        let root = graph.screens[0], hub = graph.screens[1], leaf = graph.screens[2]
        return Set(root.gameCodes) == stockCodes && root.gameCodes.count == 30
            && root.links.count == 1 && root.links[0].role == .folder && root.links[0].target == 1
            && hub.gameCodes.isEmpty && hub.links.count == 2
            && hub.links.contains(where: { $0.role == .back && $0.target == 0 })
            && hub.links.contains(where: { $0.role == .folder && $0.target == 2 })
            && leaf.gameCodes.count == 1 && !stockCodes.contains(leaf.gameCodes[0])
            && leaf.links.count == 1 && leaf.links[0].role == .back && leaf.links[0].target == 1
    }
}
