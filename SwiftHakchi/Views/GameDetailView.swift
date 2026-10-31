import SwiftUI

/// Right panel: game metadata editor with cover art
struct GameDetailView: View {
    @Binding var game: Game
    @EnvironmentObject var appState: AppState
    @State private var showScraper = false
    @State private var showArtwork = false
    @State private var showGameGenie = false

    private var access: GameDetailAccess {
        GameDetailAccess(source: game.source, hasSSH: appState.deviceManager.sshService != nil,
                         isLegacyInspection: appState.gameManager.isInspectingLegacy)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Game Details")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if game.source != .local {
                        Text(appState.gameManager.isInspectingLegacy
                             ? "Legacy console metadata is read only. Disconnect, then import a local ROM copy to edit its name and artwork."
                             : "Console metadata is read only in this editor. Import a local copy to edit its name and artwork.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding([.horizontal, .top])
                    }
                    if appState.gameManager.isInspectingLegacy, game.source == .console, LegacyChangeScripts.validCode(game.code) {
                        Button("Preview Hide Custom Game…") { appState.reviewLegacyChange(game: game) }
                            .disabled(appState.isPreparingSync || appState.taskRunner.isRunning || appState.gameManager.isLoading)
                            .padding(.horizontal)
                    }
                    if game.source == .local, (game.publisher == "UNKNOWN" || game.releaseDate.isEmpty) {
                        Text("Some metadata is unknown or region-dependent. Review this ROM's title, region and dump before using it as a compatibility test.")
                            .font(.caption).foregroundStyle(.orange).padding(.horizontal)
                    }
                    artworkSection
                        .padding(.horizontal)
                    metadataSection
                        .disabled(!access.canEditMetadata)
                        .padding()

                    if access.canDownloadROM {
                        Button("Download from Console") {
                            appState.downloadGameFromConsole(game: game)
                        }
                        .help("Save a copy of this game's ROM from the console to your Mac")
                        .padding(.horizontal)
                    }

                    Divider()

                    descriptionSection
                        .disabled(!access.canEditMetadata)
                        .padding(.horizontal)

                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showGameGenie) {
            GameGenieView(game: game).environmentObject(appState)
        }
        .sheet(isPresented: $showArtwork) {
            GameArtworkView(game: game).environmentObject(appState)
        }
        .sheet(isPresented: $showScraper) {
            ScraperView(game: $game)
                .environmentObject(appState)
        }
    }

    // MARK: - Sections

    private var artworkSection: some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let image = game.coverImage { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
            }.frame(width: 90, height: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text("Box Art").font(.headline)
                if access.canEditMetadata {
                    Button("Find Box Art…") { showArtwork = true }
                    Text("Browse a local image or search online without an API key.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Artwork can be edited on a local managed copy.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Name") {
                HStack {
                    TextField("Name", text: $game.name)
                        .textFieldStyle(.roundedBorder)
                    Button("Revert Name") { game.name = game.defaultName }
                        .disabled(game.source != .local || game.name == game.defaultName)
                        .help("Restore the title captured when this managed game was imported or first loaded. Choose Save to keep it; source ROM filenames stay unchanged.")
                }
            }

            LabeledContent("Sort Name") {
                TextField("Sort Name", text: $game.sortName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(game.source != .local)
                    .help("Sorting metadata is saved for local games. An empty value uses the game name.")
            }

            LabeledContent("Publisher") {
                TextField("Publisher", text: $game.publisher)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Copyright") {
                TextField("Copyright", text: $game.copyright)
                    .textFieldStyle(.roundedBorder)
                    .disabled(game.source != .local)
            }

            LabeledContent("Release Date") {
                TextField("YYYY-MM-DD", text: $game.releaseDate)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            HStack(spacing: 20) {
                LabeledContent("Players") {
                    Stepper("\(game.players)", value: $game.players, in: 1...4)
                }

                Toggle("Simultaneous", isOn: $game.simultaneous)
            }

            LabeledContent("Save Count") {
                Stepper(value: $game.saveCount, in: 0...Int.max) {
                    Text(game.saveCount, format: .number)
                }
                .disabled(game.source != .local)
                .help("Launcher metadata only. Changing it does not create or delete existing save files.")
            }

            LabeledContent("Genre") {
                TextField("Genre", text: $game.genre)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Command Line") {
                TextField("Exec", text: $game.commandLine)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if game.source == .local {
                Text("Edit the title freely, then Save. Source ROM filenames stay unchanged. Search Metadata uses the bundled catalog without a key. Find Box Art searches for images separately without a key. TheGamesDB is an optional text source requiring a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Code: \(game.code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if game.source == .local {
                    if GameGenieSystem(console: game.consoleType) != nil {
                        Button("Cheat Codes…") { showGameGenie = true }
                            .help("Create or update an optional Cheat Codes copy of this game. Sync is a separate step.")
                    }
                    Button("Search Metadata…") {
                        showScraper = true
                    }
                    .help("Search text details such as title, publisher and release date. Use Find Box Art for images.")
                }
                Button("Save") {
                    appState.gameManager.saveGame(game)
                }
                .disabled(game.source != .local)
                .help("Save changes to this game's metadata")
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
            TextEditor(text: $game.description)
                .frame(minHeight: 100)
                .font(.body)
                .border(.separator)
        }
    }

}
