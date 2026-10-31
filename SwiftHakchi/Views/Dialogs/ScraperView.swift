import SwiftUI

/// Explicit text lookup; offline catalog is the default and needs no account.
struct ScraperView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @Binding var game: Game
    @State private var query: String
    @State private var online = false
    @State private var showArtwork = false
    @State private var results: [MetadataCandidate] = []
    @State private var selectedID: String?
    @State private var errorMessage: String?
    @State private var target: GameArtworkTarget?
    @State private var request: SearchRequest?
    private struct SearchRequest: Hashable { let id = UUID(); let query: String; let platform: Int; let console: ConsoleType; let gameCode: String }

    init(game: Binding<Game>) {
        _game = game; _query = State(initialValue: game.wrappedValue.name)
    }
    private var selected: MetadataCandidate? { results.first { $0.id == selectedID } }
    private var hasKey: Bool { !AppConfig.shared.theGamesDbApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Game Metadata").font(.title2.bold())
                Spacer()
                Button("Find Box Art…") { showArtwork = true }
                    .help("Search cover images separately; applying text metadata does not replace artwork.")
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Source", selection: $online) {
                Text("Bundled catalog (no key)").tag(false)
                Text("TheGamesDB (API key)").tag(true)
            }.pickerStyle(.segmented)
            Text(online ? (hasKey ? "Online text lookup. Artwork is managed separately." : "Optional: add a TheGamesDB API key in Settings → Console, or use the bundled catalog.")
                 : "Text details only: title, publisher, date and players. Use Find Box Art for images.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text("Results for " + game.consoleType.displayName).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search game name", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                Button("Search") { search() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (online && !hasKey))
            }
            if request != nil { ProgressView("Searching…") }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            List(results, selection: $selectedID) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).font(.headline)
                    Text([result.region ?? "Region unknown", result.publisher ?? "Publisher unknown", result.releaseDate ?? "Date unknown", result.players.map { "\($0)P" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let overview = result.overview { Text(overview).font(.caption).lineLimit(2) }
                }.padding(.vertical, 3).tag(result.id)
            }.listStyle(.inset)
            HStack {
                Text("\(results.count) candidates").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply Metadata") { applySelected() }.disabled(selected == nil || target == nil || request != nil)
            }
        }.padding().frame(width: 620, height: 510)
        .sheet(isPresented: $showArtwork) {
            GameArtworkView(game: game).environmentObject(appState)
        }
        .onAppear {
            do { target = try GameArtworkTarget(game: game, gamesDirectory: AppConfig.shared.gamesDirectory); search() }
            catch { errorMessage = error.localizedDescription }
        }
        .onChange(of: query) { _, _ in reset() }
        .onChange(of: online) { _, _ in reset() }
        .onChange(of: game.consoleType) { _, _ in reset() }
        .onChange(of: game.code) { _, _ in reset() }
        .task(id: request) {
            guard let current = request else { return }
            do {
                let found = try await appState.gameManager.searchMetadata(name: current.query, apiKey: AppConfig.shared.theGamesDbApiKey, platform: current.platform)
                try Task.checkCancellation()
                guard request == current, game.consoleType == current.console, game.code == current.gameCode else { return }
                let family = ArtworkPlatform(console: current.console)?.rawValue
                results = found.filter { $0.platform == family }.map { MetadataCandidate(title: $0.title, region: nil, releaseDate: $0.releaseDate, players: $0.players,
                    publisher: $0.publisher, genre: $0.genre, overview: $0.overview, platform: $0.platform ?? "TheGamesDB") }
                // Different provider IDs can have identical text; display each distinct candidate once.
                var ids = Set<String>(); results = results.filter { ids.insert($0.id).inserted }
                request = nil
                if results.isEmpty { errorMessage = "No matches. Try a shorter title or edit the details manually." }
            } catch is CancellationError { }
            catch { if request == current { request = nil; errorMessage = error.localizedDescription } }
        }
    }
    private func reset() { request = nil; selectedID = nil; results = []; errorMessage = nil }
    private func search() {
        reset()
        if online {
            guard hasKey else { return }
            guard let platform = ScraperService.platformId(for: game.consoleType) else {
                errorMessage = "Choose a supported console before searching metadata."; return
            }
            request = SearchRequest(query: query, platform: platform, console: game.consoleType, gameCode: game.code)
        } else {
            results = GameDatabase.shared.search(name: query, consoleType: game.consoleType)
            if results.isEmpty { errorMessage = "No bundled matches. Try a shorter title or edit the details manually." }
        }
    }
    private func applySelected() {
        guard let selected, let target, game.code == target.code else { return }
        do { try appState.gameManager.validateArtworkTarget(target) }
        catch { errorMessage = error.localizedDescription; return }
        var updated = game
        updated.name = selected.title
        if let date = selected.releaseDate { updated.releaseDate = date }
        if let players = selected.players { updated.players = players }
        if let publisher = selected.publisher { updated.publisher = publisher }
        if let genre = selected.genre { updated.genre = genre }
        if let overview = selected.overview { updated.description = overview }
        guard appState.gameManager.saveGame(updated) else { errorMessage = "Could not save metadata. Your previous file is unchanged."; return }
        dismiss()
    }
}

extension ScraperService.SearchResult: Hashable {
    static func == (lhs: ScraperService.SearchResult, rhs: ScraperService.SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
