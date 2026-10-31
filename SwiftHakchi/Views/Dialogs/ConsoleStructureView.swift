import SwiftUI
import SwiftHakchiCore

struct ConsoleStructureView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var config = AppConfig.shared
    @StateObject private var model: ConsoleStructureViewModel
    @State private var showCustomManager = false
    @State private var copyTargets: Set<ConsoleType> = []
    @State private var error: String?
    private let games: [Game]
    private let allowsSyncShortcut: Bool

    init(console: ConsoleType, games: [Game]?, stockCodes: Set<String>?,
         allowsSyncShortcut: Bool = true) {
        self.games = games ?? []
        self.allowsSyncShortcut = allowsSyncShortcut
        _model = StateObject(wrappedValue: ConsoleStructureViewModel(config: .shared,
            console: console, games: games, stockCodes: stockCodes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Console Structure").font(.title2.bold())
            Text("Choose where games and folders will appear on the \(model.console.displayName). Saving a layout does not change the console until you review and sync it.")
                .foregroundStyle(.secondary)
            if let issue = config.structureLoadIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let graph = model.graph {
                        ConsoleLayoutPreview(graph: graph)
                        Divider()
                    }
                    Picker("Organization", selection: Binding(get: { model.draft.mode },
                        set: { model.setMode($0) })) {
                        ForEach(ConsoleStructure.Mode.allCases, id: \.self) { mode in
                            Text(mode.displayTitle).tag(mode)
                        }
                    }.accessibilityLabel("Console game organization")
                    Text(model.draft.mode.explanation).font(.caption).foregroundStyle(.secondary)
                    Picker("Maximum games per page or folder", selection: Binding(get: {
                        model.draft.maximumGamesPerPage
                    }, set: { model.setLimit($0) })) {
                        ForEach(ConsoleMenuLimit.allCases) { limit in Text(limit.menuTitle).tag(limit) }
                    }
                    Picker("Back folder button position", selection: Binding(get: {
                        model.draft.backPosition
                    }, set: { model.setBackPosition($0) })) {
                        Text("Top").tag(ConsoleStructure.BackPosition.top)
                        Text("Bottom").tag(ConsoleStructure.BackPosition.bottom)
                    }
                    Picker("Folder images set", selection: Binding(get: {
                        model.draft.folderArt
                    }, set: { model.setFolderArt($0) })) {
                        Text("Classic").tag(ConsoleStructure.FolderArt.classic)
                        Text("Letter tiles").tag(ConsoleStructure.FolderArt.letterTiles)
                        if model.draft.mode == .custom {
                            Text("Custom images").tag(ConsoleStructure.FolderArt.custom)
                        }
                    }
                    if model.draft.maximumGamesPerPage.isNotRecommended {
                        Label("50–100 games on one screen is not recommended; test menu performance before accepting.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if model.draft.mode == .custom {
                        Button("Manage Custom Folders…") { showCustomManager = true }
                        if let difference = model.customSelectionDifference {
                            Text("The selected library changed: \(difference.added) new game(s), \(difference.removed) no longer selected. Match it to these games before saving.")
                                .foregroundStyle(.orange)
                            Button("Match Custom Folders to Selected Games") {
                                model.reconcileCustomSelection()
                            }
                        }
                    }
                    Button("Reset to Automatic") { model.resetToAutomatic() }
                    preview
                    copySection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save Structure") { save(sync: false) }
                    .disabled(!model.canSave)
                if allowsSyncShortcut {
                    Button("Save and Review Sync") { save(sync: true) }
                        .disabled(!model.canSave || !model.canActivate
                                  || appState.deviceManager.legacyReport == nil)
                        .help(model.canActivate ? "Open the reviewed NES library sync." :
                              "This layout can be previewed but needs a supervised NES hardware trial before activation.")
                }
            }
        }
        .padding(24).frame(minWidth: 700, minHeight: 650)
        .sheet(isPresented: $showCustomManager) {
            FoldersManagerView(model: model, games: games,
                artworkDirectory: config.workspace.library.appendingPathComponent("FolderArtwork"))
        }
    }

    @ViewBuilder private var preview: some View {
        Divider()
        Text("Games on each screen").font(.headline)
        if let graph = model.graph {
            Text("\(graph.screens.reduce(0) { $0 + $1.gameCodes.count }) games across \(graph.screens.count) screens")
                .font(.callout)
            artworkPreview(graph)
            if !model.canActivate {
                Label("Preview only for this console until a supervised hardware trial passes.",
                      systemImage: "eye").foregroundStyle(.orange)
            }
            let names = Dictionary(uniqueKeysWithValues: games.map { ($0.code, $0.name) })
            ForEach(graph.screens, id: \.number) { screen in
                DisclosureGroup("\(screen.number == 0 ? "Main menu" : screen.title) · \(screen.gameCodes.count) games") {
                    ForEach(screen.entries, id: \.self) { entry in
                        switch entry {
                        case .game(let code): Text(names[code] ?? code).font(.caption)
                        case .link(let target):
                            Text("→ " + (screen.links.first(where: { $0.target == target })?.title ?? "Folder")
                                 )
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            Text(model.previewIssue ?? "Preview is unavailable.")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func artworkPreview(_ graph: ConsoleMenuGraph) -> some View {
        let folderLinks = graph.screens.flatMap(\.links).filter { $0.role != .back }
        if !folderLinks.isEmpty {
            Text("Folder artwork preview").font(.callout.bold())
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(folderLinks.prefix(8).enumerated()), id: \.offset) { _, link in
                        VStack(spacing: 4) {
                            if let data = try? ConsoleFolderArtwork.previewData(for: link,
                                style: model.draft.folderArt,
                                artworkDirectory: config.workspace.library.appendingPathComponent("FolderArtwork")),
                               let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(width: 54, height: 54)
                            } else {
                                Image(systemName: "folder.fill").font(.system(size: 38))
                                    .frame(width: 54, height: 54)
                            }
                            Text(link.title).lineLimit(1).font(.caption2)
                        }
                        .frame(width: 90)
                    }
                }
            }
            if model.draft.folderArt == .classic {
                Text("The console’s classic folder pictures will be included when you copy your games.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var copySection: some View {
        DisclosureGroup("Copy to Other Collections") {
            Text("Copy only the organization settings. Games and ROM files stay in their own collections.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ConsoleType.allCases.filter { $0 != .unknown && $0 != model.console }) { console in
                Toggle(console.displayName, isOn: Binding(get: { copyTargets.contains(console) },
                    set: { selected in
                        if selected { copyTargets.insert(console) } else { copyTargets.remove(console) }
                    }))
            }
            Button("Copy Structure Settings") {
                do {
                    try model.save()
                    try model.copy(to: Array(copyTargets))
                    config.save()
                    error = nil
                } catch { self.error = error.localizedDescription }
            }.disabled(copyTargets.isEmpty || !model.canSave)
        }
    }

    private func save(sync: Bool) {
        do {
            try model.save()
            config.save()
            error = nil
            dismiss()
            if sync { appState.reviewLegacyFullSync() }
        } catch { self.error = error.localizedDescription }
    }
}

extension ConsoleStructure.Mode {
    var displayTitle: String {
        switch self {
        case .flat: return "Disable pages and folders"
        case .custom: return "Custom — use folders manager"
        case .automatic: return "Automatic"
        case .stockRootAutomatic: return "Original games in root → Automatic in subfolder"
        case .pagesEqual: return "Pages, split games equally"
        case .stockRootPagesEqual: return "Original games in root → Pages, split equally"
        case .foldersEqual: return "Folders, split games equally"
        case .stockRootFoldersEqual: return "Original games in root → Folders, split equally"
        case .foldersAlphabetical: return "Folders, split by first letter"
        case .stockRootFoldersAlphabetical: return "Original games in root → Folders by first letter"
        }
    }

    var explanation: String {
        switch self {
        case .flat: return "Put every game on one screen, up to 30 total entries."
        case .custom: return "Assign each game to the root or a named folder."
        case .automatic, .stockRootAutomatic: return "Use balanced pages for smaller libraries and folders when 12 or more game screens would be needed."
        case .pagesEqual, .stockRootPagesEqual: return "Balance games across pages with Previous and More links."
        case .foldersEqual, .stockRootFoldersEqual: return "Balance games among folders, each with a Back link."
        case .foldersAlphabetical, .stockRootFoldersAlphabetical: return "Group games by first letter, with extra pages for large letters."
        }
    }
}
