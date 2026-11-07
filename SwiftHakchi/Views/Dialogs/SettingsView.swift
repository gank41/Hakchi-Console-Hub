import SwiftUI
import AppKit

/// Settings window (macOS Settings scene)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage("showAdvancedFeatures") private var showAdvancedFeatures = false
    @State private var showPurgeConfirm = false
    @State private var showPurgeGamesConfirm = false
    @State private var showBackupHistory = false
    @State private var backupLocationError: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            updatesTab
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
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
        .frame(width: 620, height: 520)
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

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsHeading("General", description: "Choose how much detail to show.")
            GroupBox("App Mode") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mode", selection: $showAdvancedFeatures) {
                        Text("Easy").tag(false)
                        Text("Advanced").tag(true)
                    }.pickerStyle(.segmented)
                    Text(showAdvancedFeatures
                         ? "Advanced mode shows additional technical tools. The same backups and confirmation steps still apply."
                         : "Easy mode shows the main tools for adding games, backing up and restoring. Switch to Advanced to see extra technical tools.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Spacer()
        }.padding(20)
    }

    private var updatesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsHeading("Updates", description: "Check for a newer version of Hakchi Console Hub.")
            GroupBox("App Updates") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check for a newer installer, then download it from GitHub. Open the downloaded file and drag the app into Applications.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(updates.checking ? "Checking…" : "Check for Updates") { updates.check() }.disabled(updates.checking)
                        if updates.checking { ProgressView().controlSize(.small) }
                    }
                    Text(updates.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("Open Downloads on GitHub", destination: UpdateChecker.downloadsURL)
                    Link("Open Project on GitHub", destination: UpdateChecker.projectURL)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Spacer()
        }.padding(20)
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App Icon").font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)
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

    private var storageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeading("Storage", description: "Choose where your games and console backups are kept on this Mac.")

                GroupBox("Game Library") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The app keeps a copy of each added game in your library. Your original files stay where they are. Libraries and selections are separate for each console.")
                            .foregroundStyle(.secondary)
                        Text("Library location").font(.headline)
                        folderPath(config.workspacePath)
                        Text("Changing this location opens a different library; it does not move your existing files.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Choose Location…") { appState.chooseWorkspace() }
                            Button("Copy Earlier Mac Library…") { appState.copyEarlierMacLibrary() }
                        }
                        .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isInspectingLegacy)
                        Divider().padding(.vertical, 3)
                        Text("Games folder for the selected console").font(.headline)
                        folderPath(config.gamesDirectory.path)
                        Button("Show Games in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([config.gamesDirectory])
                        }
                        .disabled(!FileManager.default.fileExists(atPath: config.gamesDirectory.path))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("Console Backups") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(config.lastConsoleType == .snesUsa
                             ? "SNES library backups include the current menu, added games and saved progress. Restoring to a different console is still being tested."
                             : "Backups help protect your console’s current menu and games before changes are made.")
                            .foregroundStyle(.secondary)
                        folderPath(config.workspace.backups.path)
                        HStack {
                            Button("Choose Folder…") { chooseBackupsFolder() }
                                .disabled(appState.taskRunner.isRunning || appState.isPreparingSync)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([config.workspace.backups])
                            }
                            .disabled(!FileManager.default.fileExists(atPath: config.workspace.backups.path))
                            Button("Backup History…") { showBackupHistory = true }
                        }
                        Text("New backups go to this folder. Earlier backups stay where they are and remain in Backup History.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider().padding(.vertical, 3)
                        Toggle("Create a backup when this console has none", isOn: $config.automaticallyCreateMissingBackup)
                        Toggle("Explain backups during sync", isOn: $config.showBackupExplanation)
                        Text("A verified backup of the current menu is required before syncing. If automatic backup is off, you can choose Back Up Now.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(20)
        }
    }

    private func settingsHeading(_ title: String, description: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.title2.weight(.semibold))
            Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func folderPath(_ path: String) -> some View {
        Text(path)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            .help(path)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeading("Advanced", description: "Optional search settings and library maintenance.")

                GroupBox("Game Information") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("An optional TheGamesDB key lets you search online for game details. Box-art search and built-in game identification do not need a key.")
                            .foregroundStyle(.secondary)
                        LabeledContent("TheGamesDB API Key") {
                            TextField("Optional API key", text: $config.theGamesDbApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Link("Get a TheGamesDB API key", destination: URL(string: "https://api.thegamesdb.net/key.php")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("Cover Art") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Remove saved cover images for the current library and the console cover cache. This also removes artwork you chose yourself.")
                        Text("Replacements are not downloaded automatically. Use Fill Missing Covers in the main window or choose artwork again.")
                            .foregroundStyle(.secondary)
                        Button("Remove Saved Covers…") { showPurgeConfirm = true }
                            .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isInspectingLegacy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }

                GroupBox("Game Library") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Remove the added games and their artwork from this console’s library on your Mac, along with the app’s cached data. Your original game files and games on the console are not changed.")
                        Button("Remove Added Games…") { showPurgeGamesConfirm = true }
                            .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isInspectingLegacy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            .padding(20)
        }
        .alert("Remove Saved Covers?", isPresented: $showPurgeConfirm) {
            Button("Remove Covers", role: .destructive) { appState.gameManager.purgeCoverArt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved covers for the current library, including artwork you chose, and the console cover cache will be deleted. Replacements will not be downloaded automatically.")
        }
        .alert("Remove Added Games?", isPresented: $showPurgeGamesConfirm) {
            Button("Remove from Mac", role: .destructive) { appState.gameManager.purgeAllLocalData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The added games and artwork in this console’s Mac library and the app’s cached data will be permanently deleted. Your original game files and games on the console will not be deleted. You can add the games again later.")
        }
    }
}
