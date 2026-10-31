import Foundation
import SwiftHakchiCore

@MainActor final class ConsoleStructureViewModel: ObservableObject {
    let console: ConsoleType
    private let config: AppConfig
    private var games: [Game]?
    private var stockCodes: Set<String>?
    private var order: ConsoleMenuOrder

    @Published private(set) var draft: ConsoleStructure
    @Published private(set) var graph: ConsoleMenuGraph?
    @Published private(set) var previewIssue: String?

    init(config: AppConfig, console: ConsoleType, games: [Game]?, stockCodes: Set<String>?,
         order: ConsoleMenuOrder = .title) {
        self.config = config
        self.console = console
        self.games = games
        self.stockCodes = stockCodes
        self.order = order
        draft = config.structure(for: console)
        refresh()
    }

    var canSave: Bool {
        (try? draft.validate()) != nil && (draft.mode != .custom || graph != nil)
    }
    var canActivate: Bool {
        guard console == .nes, let graph, let stockCodes else { return false }
        return LegacyStructureHardwareSupport.canActivate(draft, graph: graph, stockCodes: stockCodes)
    }
    var customSelectionDifference: (added: Int, removed: Int)? {
        guard draft.mode == .custom, let games, let custom = draft.custom else { return nil }
        let selected = Set(games.map(\.code))
        let assigned = Set(custom.rootGameCodes + custom.folders.flatMap(\.gameCodes))
        let added = selected.subtracting(assigned).count
        let removed = assigned.subtracting(selected).count
        return added + removed > 0 ? (added, removed) : nil
    }

    func setInventory(games: [Game]?, stockCodes: Set<String>?) {
        self.games = games; self.stockCodes = stockCodes; refresh()
    }
    func setMode(_ mode: ConsoleStructure.Mode) {
        if mode == .custom { startCustom(); return }
        draft.mode = mode; draft.custom = nil
        if draft.folderArt == .custom { draft.folderArt = .classic }
        refresh()
    }
    func setLimit(_ limit: ConsoleMenuLimit) { draft.maximumGamesPerPage = limit; refresh() }
    func setBackPosition(_ value: ConsoleStructure.BackPosition) { draft.backPosition = value; refresh() }
    func setFolderArt(_ value: ConsoleStructure.FolderArt) {
        guard value != .custom || draft.mode == .custom else { return }
        draft.folderArt = value; refresh()
    }
    func resetToAutomatic() { setMode(.automatic) }

    func startCustom() {
        guard draft.mode != .custom else { return }
        let codes = (try? order.ordered(games ?? []))?.map(\.code) ?? games?.map(\.code) ?? []
        let size = min(30, draft.maximumGamesPerPage.rawValue)
        let chunks = stride(from: 0, to: codes.count, by: size).enumerated().map { index, start in
            ConsoleStructure.CustomFolderTree.Folder(id: String(format: "F%04d", index),
                title: "Games \(index + 1)", parentID: nil,
                gameCodes: Array(codes[start..<min(start + size, codes.count)]), artKey: nil)
        }
        draft.mode = .custom
        draft.custom = .init(rootGameCodes: [], folders: chunks)
        refresh()
    }
    func addFolder() {
        guard draft.mode == .custom else { return }
        let existing = Set(draft.custom?.folders.map(\.id) ?? [])
        let number = (0..<10_000).first { !existing.contains(String(format: "F%04d", $0)) }
        guard let number else { return }
        draft.custom?.folders.append(.init(id: String(format: "F%04d", number),
            title: "New folder", parentID: nil, gameCodes: [], artKey: nil))
        refresh()
    }
    func removeFolder(_ id: String) {
        guard draft.mode == .custom, let index = draft.custom?.folders.firstIndex(where: { $0.id == id }) else { return }
        let folder = draft.custom!.folders.remove(at: index)
        draft.custom!.rootGameCodes.append(contentsOf: folder.gameCodes)
        for child in draft.custom!.folders.indices where draft.custom!.folders[child].parentID == id {
            draft.custom!.folders[child].parentID = nil
        }
        refresh()
    }
    func renameFolder(_ id: String, to title: String) {
        guard let index = draft.custom?.folders.firstIndex(where: { $0.id == id }) else { return }
        draft.custom!.folders[index].title = title; refresh()
    }
    func setParent(_ id: String, to parentID: String?) {
        guard let index = draft.custom?.folders.firstIndex(where: { $0.id == id }) else { return }
        draft.custom!.folders[index].parentID = parentID; refresh()
    }
    func moveFolder(_ id: String, by offset: Int) {
        guard let index = draft.custom?.folders.firstIndex(where: { $0.id == id }),
              let count = draft.custom?.folders.count, (0..<count).contains(index + offset) else { return }
        draft.custom!.folders.swapAt(index, index + offset); refresh()
    }
    func setFolderArtwork(_ id: String, key: String?) {
        guard let index = draft.custom?.folders.firstIndex(where: { $0.id == id }) else { return }
        draft.custom!.folders[index].artKey = key; refresh()
    }
    func assignGame(_ code: String, to folderID: String?) {
        guard draft.mode == .custom,
              games?.contains(where: { $0.code == code }) == true,
              folderID == nil || draft.custom?.folders.contains(where: { $0.id == folderID }) == true else { return }
        draft.custom!.rootGameCodes.removeAll { $0 == code }
        for index in draft.custom!.folders.indices {
            draft.custom!.folders[index].gameCodes.removeAll { $0 == code }
        }
        if let folderID, let index = draft.custom!.folders.firstIndex(where: { $0.id == folderID }) {
            draft.custom!.folders[index].gameCodes.append(code)
        } else { draft.custom!.rootGameCodes.append(code) }
        refresh()
    }
    func reconcileCustomSelection() {
        guard draft.mode == .custom, let games, var custom = draft.custom else { return }
        let selected = Set(games.map(\.code))
        custom.rootGameCodes.removeAll { !selected.contains($0) }
        for index in custom.folders.indices {
            custom.folders[index].gameCodes.removeAll { !selected.contains($0) }
        }
        let assigned = Set(custom.rootGameCodes + custom.folders.flatMap(\.gameCodes))
        let missing = ((try? order.ordered(games)) ?? games).map(\.code).filter { !assigned.contains($0) }
        let limit = draft.maximumGamesPerPage.rawValue
        for code in missing {
            if let index = custom.folders.firstIndex(where: { $0.gameCodes.count < limit }) {
                custom.folders[index].gameCodes.append(code)
            } else {
                let existing = Set(custom.folders.map(\.id))
                guard let number = (0..<10_000).first(where: { !existing.contains(String(format: "F%04d", $0)) }) else { return }
                custom.folders.append(.init(id: String(format: "F%04d", number),
                                            title: "New games", parentID: nil,
                                            gameCodes: [code], artKey: nil))
            }
        }
        // Empty leaf folders cannot be rendered; remove them after stale games leave.
        while let index = custom.folders.firstIndex(where: { folder in
            folder.gameCodes.isEmpty && !custom.folders.contains(where: { $0.parentID == folder.id })
        }) {
            custom.folders.remove(at: index)
        }
        draft.custom = custom
        refresh()
    }
    func save() throws {
        guard canSave else { throw ConsoleStructureError.invalidSetting(previewIssue ?? "The layout is incomplete.") }
        try config.setStructure(draft, for: console)
    }
    func copy(to consoles: [ConsoleType]) throws {
        try config.copyStructure(from: console, to: consoles)
    }

    private func refresh() {
        graph = nil
        do {
            try draft.validate()
            guard let games, let stockCodes else {
                previewIssue = "Connect the console and load its game inventory for an exact preview. Settings can still be saved."
                return
            }
            let built = try ConsoleStructurePlanner.make(games: games, stockCodes: stockCodes,
                                                         order: order, structure: draft)
            graph = built; previewIssue = nil
        } catch {
            previewIssue = error.localizedDescription
        }
    }
}
