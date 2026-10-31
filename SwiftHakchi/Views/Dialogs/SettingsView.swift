import SwiftUI
import AppKit

/// Settings window (macOS Settings scene)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @State private var showPurgeConfirm = false
    @State private var showPurgeGamesConfirm = false
    @State private var showBackupHistory = false
    @State private var backupLocationError: String?

    var body: some View {
        TabView {
            consoleTab
                .tabItem {
                    Label("Console", systemImage: "gamecontroller")
                }

            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            storageTab
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }

            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .frame(width: 560, height: 390)
        .onChange(of: config.appIconID) { _, value in
            config.save(); AppIconCatalog.apply(value)
        }
        .onChange(of: config.lastConsoleType) { _, _ in config.save() }
        .onChange(of: config.separateGameStorage) { _, _ in config.save() }
        .onChange(of: config.uploadCompressed) { _, _ in config.save() }
        .onChange(of: config.maxGameSize) { _, _ in config.save() }
        .onChange(of: config.automaticallyCreateMissingBackup) { _, _ in config.save() }
        .onChange(of: config.showBackupExplanation) { _, _ in config.save() }
        .onChange(of: config.theGamesDbApiKey) { _, _ in config.save() }
        .sheet(isPresented: $showBackupHistory) {
            if config.lastConsoleType == .snesUsa {
                SNESLibraryBackupHistoryView(workspace: config.workspace).environmentObject(appState)
            } else {
                LegacyBackupHistoryView(workspace: config.workspace)
            }
        }
        .alert("Backups Folder Needs Attention", isPresented: Binding(
            get: { backupLocationError != nil },
            set: { if !$0 { backupLocationError = nil } }
        )) {
            Button("OK") { backupLocationError = nil }
        } message: {
            Text(backupLocationError ?? "Choose a writable folder.")
        }
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App Icon").font(.headline)
            Text("Alternate icons show only while the app is running. The installed app keeps the default POW Block icon.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 12) {
                    ForEach(AppIconCatalog.choices) { choice in
                        Button {
                            config.appIconID = choice.id
                        } label: {
                            VStack(spacing: 5) {
                                if let image = AppIconCatalog.image(for: choice.id) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 44)
                                }
                                Text(choice.title).font(.caption).lineLimit(2).frame(height: 30)
                            }
                            .frame(maxWidth: .infinity).padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(config.appIconID == choice.id ? Color.accentColor.opacity(0.12) : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(config.appIconID == choice.id ? Color.accentColor : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use " + choice.title + " app icon")
                        .accessibilityValue(config.appIconID == choice.id ? "Selected" : "")
                    }
                }.padding(2)
            }
            Button("Use Default Icon") { config.appIconID = AppIconCatalog.defaultID }
        }.padding()
    }

    private var consoleTab: some View {
        Form {
            Text("Choose the console from the Console menu at the top of the main window. Its local library changes immediately.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("TheGamesDB API Key") {
                    TextField("API Key", text: $config.theGamesDbApiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 250)
                }

                Text("Optional: searches text metadata for a selected local game. Saving a key never changes your library automatically. Box-art search and bundled ROM identification need no key. [TheGamesDB key page](https://api.thegamesdb.net/key.php).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Fill Missing Covers (no key)") {
                    appState.fillMissingCoverArt()
                }
                .disabled(appState.gameManager.isInspectingLegacy || appState.taskRunner.isRunning)
                .help("Find unique title/region cover matches without overwriting existing artwork")
            }
        }
        .padding()
    }

    private var storageTab: some View {
        Form {
            Toggle("Upload games compressed (planned)", isOn: $config.uploadCompressed)
                .disabled(true)
                .help("Compress ROMs during sync to save storage on the console")

            Text("Game libraries and selections are kept separately for each console.").font(.caption)

            LabeledContent("Max game size (planned)") {
                TextField("MB", value: $config.maxGameSize, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(true)
            }

            LabeledContent("Workspace") {
                Text(config.workspacePath).font(.caption).lineLimit(1).truncationMode(.middle)
                Button("Change...") { appState.chooseWorkspace() }
                    .disabled(appState.taskRunner.isRunning || appState.isPreparingSync)
            }
            Button("Copy Earlier Mac Library...") { appState.copyEarlierMacLibrary() }
                .disabled(appState.taskRunner.isRunning || appState.isPreparingSync)
            LabeledContent("Games folder") {
                Text(config.gamesDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([config.gamesDirectory])
                }
                .disabled(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
            }
            Text("Imported ROMs, game details and artwork are copied here. Your original ROM files stay where they were.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Backups Folder") {
                Text(config.workspace.backups.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Choose…") { chooseBackupsFolder() }
                    .disabled(appState.taskRunner.isRunning || appState.isPreparingSync)
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([config.workspace.backups])
                }
                .disabled(!FileManager.default.fileExists(atPath: config.workspace.backups.path))
            }
            Button("Backup History…") { showBackupHistory = true }
            Toggle("Create a Mac backup when the current console has none",
                   isOn: $config.automaticallyCreateMissingBackup)
            Toggle("Show backup explanation during sync", isOn: $config.showBackupExplanation)
            Text("Sync always requires a verified backup of the current console menu. Turning off automatic creation offers Back Up Now before transfer.")
                .font(.caption).foregroundStyle(.secondary)
            Text("New console backups go to the selected folder. Existing backups stay in their earlier folders and remain listed in Backup History. Changing this folder does not move your ROM library.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func chooseBackupsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backups Folder"
        panel.message = "New console backups will be saved here. Existing backups will stay where they are."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = config.workspace.backups
        if panel.runModal() == .OK, let selected = panel.url {
            do {
                try config.setBackupDirectory(selected)
                config.save()
            }
            catch { backupLocationError = error.localizedDescription }
        }
    }

    private var advancedTab: some View {
        Form {
            Section("Cover Art") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purge All Cover Art")
                        Text("Deletes all cached cover images and re-downloads them from the game database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Purge & Re-download...") {
                        showPurgeConfirm = true
                    }
                    .help("Delete all cached cover art and re-download from the game database")
                    .alert("Purge All Cover Art?", isPresented: $showPurgeConfirm) {
                        Button("Purge & Re-download", role: .destructive) {
                            appState.gameManager.purgeCoverArt()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will delete all cover art images and re-download them. Games without a database match will show placeholder art until new covers are added.")
                    }
                }
            }

            Section("Game Library") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purge All Imported Games")
                        Text("Removes all imported ROMs, cached data, and cover art. Built-in console games are not affected. Your original ROM files are not deleted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Purge Library...") {
                        showPurgeGamesConfirm = true
                    }
                    .help("Remove all imported games, cached data, and cover art from the library")
                    .alert("Purge Game Library?", isPresented: $showPurgeGamesConfirm) {
                        Button("Purge Everything", role: .destructive) {
                            appState.gameManager.purgeAllLocalData()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will delete all imported games, cached covers, and downloaded data. Your original ROM files on disk are not affected. You will need to re-import your games.")
                    }
                }
            }
        }
        .padding()
    }
}
