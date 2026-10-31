import SwiftUI

private enum LibraryLayout: String, CaseIterable { case list = "List", grid = "Grid" }
private enum LibraryFilter: String, CaseIterable { case all = "All Games", custom = "Custom Games", original = "Original Games" }
private enum GameRemovalAction {
    case console, local, selected(Game), all(ConsoleType)
}

/// A named, compact library alongside the cover grid, for large collections.
struct GameGridView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @Binding var isDraggingFromExplorer: Bool
    @Binding var selectionSource: SelectionSource
    @State private var gameToDelete: Game?
    @State private var layout: LibraryLayout = .list
    @State private var filter: LibraryFilter = .all
    @State private var showRemoval = false
    @State private var removalAction: GameRemovalAction?

    private var displayed: [Game] {
        appState.filteredGames.filter {
            filter == .all || (filter == .original ? $0.isStock : !$0.isStock)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appState.gameManager.isInspectingLegacy ? "Local and NES Games" : "Local Game Library").font(.headline)
                Spacer()
                Picker("Library view", selection: $layout) {
                    ForEach(LibraryLayout.allCases, id: \.self) { mode in
                        Image(systemName: mode == .list ? "list.bullet" : "square.grid.2x2").tag(mode)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 80).help("Switch between a compact list and named cover cards")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            HStack {
                HStack(spacing: 4) {
                    TextField("Search games", text: $appState.searchText).textFieldStyle(.plain)
                    if !appState.searchText.isEmpty {
                        Button { appState.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear game search").help("Clear search")
                    }
                }.padding(5).background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(.quaternary) }
                Button("Add Game Files") { appState.addROMs() }
                    .disabled(appState.gameManager.isInspectingLegacy || appState.taskRunner.isRunning)
                Button("Remove Games…") { showRemoval = true }
                    .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
                    .help("Choose whether to remove games from the console or from your Mac library.")
                Menu {
                    Button("Add ROM Folder…") { appState.addROMFolder() }
                        .disabled(appState.gameManager.isInspectingLegacy || appState.taskRunner.isRunning)
                    Button("Import from Console") { Task { await appState.importFromConsole() } }
                        .disabled(appState.deviceManager.sshService == nil || appState.taskRunner.isRunning)
                    Button("Fill Missing Covers (no key)") { appState.fillMissingCoverArt() }
                        .disabled(appState.gameManager.isInspectingLegacy || appState.taskRunner.isRunning || appState.gameManager.games.allSatisfy { $0.source != .local })
                    Divider()
                    Button("Replace Imported Library from Folder…") { appState.replaceROMFolder() }
                        .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
                    Button("Remove Imported Library…", role: .destructive) { appState.showRemoveLocalLibrary = true }
                        .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading
                                  || appState.gameManager.legacyLocalGames.isEmpty)
                    Button("Open Removed Libraries in Finder") {
                        let directory = config.workspace.library.appendingPathComponent("Removed Libraries", isDirectory: true)
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("Library actions, including key-free missing cover lookup")
            }.padding(.horizontal, 12)
            HStack {
                Picker("Show", selection: $filter) { ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .frame(maxWidth: 220)
                Picker("Sort", selection: $config.libraryOrder) {
                    ForEach(LibraryOrder.allCases) { Text($0.label).tag($0) }
                }.frame(maxWidth: 245).onChange(of: config.libraryOrder) { _, _ in config.save() }
                Spacer()
                Text("\(displayed.count) games").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 6)
            bulkSelectionControls
            if appState.gameManager.isInspectingLegacy {
                HStack {
                    Text("Your edited local games are shown alongside older NES-only games. Disconnect to edit the local library.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Local Library") { appState.deviceManager.manualDisconnect() }
                        .disabled(appState.taskRunner.isRunning || appState.isPreparingSync)
                }.padding(.horizontal, 12).padding(.bottom, 6)
            } else {
                Text("NES: .nes/.fds · SNES preparation: .sfc/.smc/.sfrom · ZIP/7z archives accepted.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6).help(ROMImportPolicy.guidance)
            }
            Divider()
            if layout == .list { list } else { grid }
        }
        .sheet(isPresented: $showRemoval, onDismiss: performRemovalAction) {
            GameRemovalView(
                removeFromConsole: { removalAction = .console; showRemoval = false },
                openMacLibrary: { removalAction = .local; showRemoval = false },
                removeSelected: { removalAction = .selected($0); showRemoval = false },
                removeAll: { removalAction = .all(config.lastConsoleType); showRemoval = false },
                close: { showRemoval = false })
                .environmentObject(appState)
        }
        .alert("Remove Game from Mac Library?", isPresented: Binding(get: { gameToDelete != nil }, set: { if !$0 { gameToDelete = nil } })) {
            Button("Remove from Mac", role: .destructive) {
                if let game = gameToDelete {
                    if appState.selectedGame?.id == game.id { appState.selectedGame = nil }
                    appState.gameManager.deleteGame(game); gameToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { gameToDelete = nil }
        } message: {
            Text("Remove \"\(gameToDelete?.name ?? "")\" and its artwork from this app? Your original ROM file and games on the console stay unchanged. To remove it from the console too, use Sync Library and review the games to remove.")
        }
    }

    private var bulkSelectionControls: some View {
        let games = displayed
        let selectedCount = games.filter(\.isSelected).count
        let codes = Set(games.map(\.code))
        return HStack {
            Button("Select All") { appState.setGamesSelectedForSync(true, codes: codes) }
                .disabled(games.isEmpty || selectedCount == games.count)
                .help("Check all games matching the current search and Show filter, including games offscreen. Sync is a separate action.")
            Button("Select None") { appState.setGamesSelectedForSync(false, codes: codes) }
                .disabled(selectedCount == 0)
                .help("Uncheck all games matching the current search and Show filter. Games outside this view stay unchanged.")
            Spacer()
            if appState.deviceManager.legacyReport != nil {
                Text("\(games.filter(\.isOnConsole).count) of \(games.count) shown on NES")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(selectedCount) of \(games.count) shown selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!appState.canChangeGameSelection)
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var list: some View {
        List {
            ForEach([true, false], id: \.self) { original in
                let group = displayed.filter { $0.isStock == original }
                if !group.isEmpty {
                    Section(original ? "Original Games" : "Custom Games") {
                        ForEach(group) { game in
                            let duplicate = includedMatch(game)
                            HStack(spacing: 10) {
                                Toggle("Select \(game.name)", isOn: Binding(get: {
                                    appState.gameManager.games.first(where: { $0.id == game.id })?.isSelected ?? false
                                }, set: { value in
                                    guard !appState.gameManager.isInspectingLegacy,
                                          let index = appState.gameManager.games.firstIndex(where: { $0.id == game.id }) else { return }
                                    appState.gameManager.games[index].isSelected = value
                                })).labelsHidden().toggleStyle(.checkbox)
                                    .disabled(appState.gameManager.isInspectingLegacy || appState.taskRunner.isRunning)
                                Button { select(game) } label: {
                                    HStack(spacing: 10) {
                                        thumbnail(game).id(game.artworkRevision)
                                            .opacity(duplicate != nil && !game.isSelected ? 0.55 : 1)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(game.name).font(.body.weight(.medium)).lineLimit(1)
                                                .foregroundStyle(duplicate != nil && !game.isSelected ? .secondary : .primary)
                                            if let duplicate { duplicateNote(duplicate, selected: game.isSelected) }
                                            Text(game.publisher == "UNKNOWN" ? "Metadata needs review" : [game.publisher, game.releaseDate].filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        if game.isOnConsole { Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Installed on console") }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                            .listRowBackground(appState.selectedGame?.id == game.id ? Color.accentColor.opacity(0.14) : .clear)
                            .onDrag { isDraggingFromExplorer = true; return NSItemProvider(object: game.id as NSString) }
                            .contextMenu { deleteAction(game) }
                        }
                    }
                }
            }
        }.overlay { empty }
    }
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 144, maximum: 170), spacing: 12)], spacing: 14) {
                ForEach(displayed) { game in
                    let duplicate = includedMatch(game)
                    Button { select(game) } label: {
                        VStack(spacing: 4) {
                            GameCardView(game: game, isActive: appState.selectedGame?.id == game.id && selectionSource == .explorer, isOnBar: game.isSelected).id(game.artworkRevision)
                                .opacity(duplicate != nil && !game.isSelected ? 0.55 : 1)
                            if let duplicate { duplicateNote(duplicate, selected: game.isSelected) }
                        }
                    }.buttonStyle(.plain)
                    .onDrag { isDraggingFromExplorer = true; return NSItemProvider(object: game.id as NSString) }
                    .contextMenu { deleteAction(game) }
                }
            }.padding(12)
        }.overlay { empty }
    }
    @ViewBuilder private var empty: some View {
        if displayed.isEmpty {
            ContentUnavailableView("No matching games", systemImage: "gamecontroller",
                                   description: Text(appState.gameManager.isInspectingLegacy ? "Change the filter or switch to your local library." : "Add Game Files or change the search and filter."))
        }
    }
    private func includedMatch(_ game: Game) -> Game? {
        guard game.source == .local else { return nil }
        return IncludedGameDuplicates.match(title: game.name, originalTitle: game.defaultName,
            console: game.consoleType, stock: appState.gameManager.knownIncludedGames)
    }
    private func duplicateNote(_ original: Game, selected: Bool) -> some View {
        Label(selected ? "Matches built-in title" : "Not selected · matches built-in title", systemImage: "square.on.square")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            .help("Built-in: \(original.name). A matching name may be a different version. Select this copy only if you want it included in your sync review.")
    }
    private func thumbnail(_ game: Game) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            if let image = game.coverImage { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: game.isStock ? "star" : "gamecontroller").foregroundStyle(.secondary) }
        }.frame(width: 36, height: 44)
    }
    @ViewBuilder private func deleteAction(_ game: Game) -> some View {
        if game.source == .local {
            Button("Remove from Mac Library…", role: .destructive) { gameToDelete = game }
                .disabled(!appState.canChangeGameSelection)
        }
    }
    private func performRemovalAction() {
        guard let action = removalAction else { return }
        removalAction = nil
        guard !appState.taskRunner.isRunning, !appState.isPreparingSync,
              !appState.gameManager.isLoading else { return }
        switch action {
        case .console: appState.reviewLegacyFullSync()
        case .local: appState.deviceManager.manualDisconnect()
        case .selected(let game):
            guard appState.canChangeGameSelection,
                  appState.gameManager.games.contains(where: { $0.id == game.id && $0.source == .local }) else { return }
            gameToDelete = game
        case .all(let console):
            guard config.lastConsoleType == console else { return }
            appState.showRemoveLocalLibrary = true
        }
    }
    private func select(_ game: Game) { appState.selectedGame = game; selectionSource = .explorer }
}
