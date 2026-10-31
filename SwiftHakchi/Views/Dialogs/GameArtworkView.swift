import SwiftUI
import UniformTypeIdentifiers

/// Local artwork preview. Closing or cancellation never commits the in-flight download.
struct GameArtworkView: View {
    let game: Game
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var candidates: [ArtworkCandidate] = []
    @State private var selected: String?
    @State private var preview: Data?
    @State private var source: GameArtworkStore.Provenance?
    @State private var target: GameArtworkTarget?
    @State private var error: String?
    @State private var working = false
    @State private var request: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Artwork for \(game.name)").font(.title2.bold())
                Spacer()
                Button("Close") { request?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Search \(game.consoleType.displayName) box art without an API key, or choose an image on your Mac. Review the region and preview before applying.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Game title", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("Search Box Art", action: search).disabled(working || query.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Browse…", action: browse)
            }
            HStack(alignment: .top, spacing: 16) {
                List(candidates) { candidate in
                    Button { load(candidate) } label: {
                        HStack {
                            Text(candidate.title).multilineTextAlignment(.leading)
                            Spacer()
                            if selected == candidate.id { Image(systemName: "checkmark") }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.frame(width: 380, height: 330)
                VStack(spacing: 10) {
                    if let preview, let image = NSImage(data: preview) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 210, height: 280)
                    } else {
                        ContentUnavailableView("Choose a cover", systemImage: "photo", description: Text("Select a search result or browse for an image."))
                            .frame(width: 210, height: 280)
                    }
                    if let source { Text(source.provider).font(.caption) }
                }
            }
            if working { ProgressView("Loading artwork…").controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Link("Artwork source and credits", destination: URL(string: "https://github.com/libretro-thumbnails/libretro-thumbnails")!)
                Spacer()
                Button("Apply Artwork", action: apply).buttonStyle(.borderedProminent)
                    .disabled(working || preview == nil || target == nil)
            }
            Text("Artwork is saved only to your local managed game. ROMs and console files stay unchanged. TheGamesDB text metadata search is optional and uses its own API key.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 700)
        .onAppear {
            query = game.name
            do { target = try GameArtworkTarget(game: game, gamesDirectory: AppConfig.shared.gamesDirectory) }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { request?.cancel(); requestID = UUID() }
    }

    private func search() {
        request?.cancel(); let token = UUID(); requestID = token
        preview = nil; source = nil; selected = nil; error = nil; working = true
        candidates = []
        guard let platform = ArtworkPlatform(console: game.consoleType) else {
            error = "Choose a supported console to search for box art."; working = false; return
        }
        let title = query
        request = Task {
            do {
                let results = try await ArtworkCatalogService.shared.search(query: title, platform: platform)
                try Task.checkCancellation()
                guard requestID == token else { return }
                candidates = results; working = false
                if results.isEmpty { error = "No covers matched. Try a shorter search or Browse for an image." }
            } catch {
                guard requestID == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; working = false
            }
        }
    }
    private func load(_ candidate: ArtworkCandidate) {
        guard candidate.platform == ArtworkPlatform(console: game.consoleType) else { return }
        request?.cancel(); let token = UUID(); requestID = token
        preview = nil; source = nil; error = nil; working = true; selected = candidate.id
        request = Task {
            do {
                let data = try await ArtworkCatalogService.shared.download(candidate)
                try Task.checkCancellation()
                guard requestID == token else { return }
                preview = data
                source = .init(provider: "Libretro thumbnails", source: candidate.url.absoluteString, matchedAutomatically: false, savedAt: Date())
                working = false
            } catch {
                guard requestID == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; working = false
            }
        }
    }
    private func browse() {
        request?.cancel(); requestID = UUID(); working = false; error = nil
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]; panel.allowsMultipleSelection = false
        panel.message = "Choose box art to preview. Apply saves a PNG copy; the original image stays unchanged."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8 * 1024 * 1024 else { throw ArtworkError.tooLarge }
            preview = try GameArtworkStore.png(from: Data(contentsOf: url)); selected = nil
            source = .init(provider: "Local image", source: url.lastPathComponent, matchedAutomatically: false, savedAt: Date())
        } catch { preview = nil; source = nil; self.error = error.localizedDescription }
    }
    private func apply() {
        guard let preview, let target, let source, !Task.isCancelled else { return }
        do { try appState.gameManager.applyArtwork(preview, target: target, provenance: source); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
