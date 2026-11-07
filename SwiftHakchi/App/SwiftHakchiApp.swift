import SwiftUI
import AppKit

#if !RECOVERY_DIAGNOSTIC && !RECOVERY_ASSISTANT
@main
#endif
struct SwiftHakchiApp: App {
    @StateObject private var appState = AppState(startDeviceMonitoring: ProcessInfo.processInfo.environment["SWIFTHAKCHI_DISABLE_USB_MONITOR"] != "1")

    init() {
        // When running via `swift run` (not from a .app bundle), macOS treats
        // the process as a background/CLI tool — no dock icon, no menu bar.
        // Setting .regular makes it behave as a normal GUI app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        AppIconCatalog.apply(AppConfig.shared.appIconID)
    }

    var body: some Scene {
        WindowGroup("Hakchi Console Hub") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    // Disable tab bar — removes "Show Tab Bar" from View menu
                    for window in NSApplication.shared.windows {
                        window.tabbingMode = .disallowed
                    }
                }
        }
        .commands {
            AboutCommands()
            FileCommands(appState: appState)
            EditCommands(appState: appState)
            GameCommands(appState: appState)
            KernelCommands(appState: appState)
            ModulesCommands(appState: appState)
            ToolsCommands(appState: appState)
            HelpCommands(appState: appState)
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// Each Commands struct is a standalone SwiftUI Commands conformance
// that takes an @ObservedObject so menu items update reactively.

struct FileCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Game Files") {
                appState.addROMs()
            }
            .keyboardShortcut("o")
            .disabled(appState.gameManager.isInspectingLegacy)

            Button("Import from Console") {
                Task { await appState.importFromConsole() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!appState.deviceManager.canInteract || appState.taskRunner.isRunning || appState.isPreparingSync)

            Divider()

            Button("Sync") {
                Task { await appState.syncGames() }
            }
            .keyboardShortcut("s")
            .disabled(!appState.deviceManager.canInteract || appState.taskRunner.isRunning || appState.isPreparingSync)
        }
    }
}

struct EditCommands: Commands {
    @ObservedObject var appState: AppState

    private var canDelete: Bool {
        appState.selectedGame?.source == .local && appState.canChangeGameSelection
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Remove from Mac Library…") {
                appState.deleteSelectedGame()
            }
            .keyboardShortcut(.delete)
            .disabled(!canDelete)

            Button("Select All Custom Games for Sync") {
                appState.setAllCustomGamesSelectedForSync(true)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!appState.canChangeGameSelection)

            Button("Select No Custom Games for Sync") {
                appState.setAllCustomGamesSelectedForSync(false)
            }
            .disabled(!appState.canChangeGameSelection)
        }
    }
}

struct GameCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Game") {
            Button("Next Game") {
                appState.selectNextGame()
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Button("Previous Game") {
                appState.selectPreviousGame()
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Divider()

            Button("Scraper...") {
                appState.showScraper = true
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(appState.selectedGame == nil)

            Button("Download from Console") {
                if let game = appState.selectedGame {
                    appState.downloadGameFromConsole(game: game)
                }
            }
            .keyboardShortcut("d")
            .disabled(appState.selectedGame == nil || appState.deviceManager.sshService == nil)
        }
    }
}

struct KernelCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @AppStorage("showAdvancedFeatures") private var showAdvancedFeatures = false

    var body: some Commands {
        CommandMenu("Console") {
            if showAdvancedFeatures {
                Button("Advanced NES Recovery Assistant…") {
                    Task {
                        do { try await RecoveryAssistantLauncher.open(workspace:AppConfig.shared.workspace.root) }
                        catch { appState.reportOperationError(error.localizedDescription) }
                    }
                }
                .disabled(appState.recoveryContext.console != .nes || appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
                Text("Save edits and quit this app before starting recovery.")
            }
            Button("Restore Console…") { appState.showRecoveryReadiness = true }
                .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
            Divider()

            if config.lastConsoleType == .snesUsa {
                Button("Set Up SNES…") { appState.reviewSNESBackup() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
            } else if showAdvancedFeatures {
                Button("Install Kernel (Persistent)") { appState.requestFlash(.installHakchi) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(true)
            }

            if showAdvancedFeatures {
                Divider()
                Button("Memboot (Temporary)") {
                    appState.requestFlash(.memboot)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(true)
            }

            Divider()

            Button("Reboot") {
                Task { await appState.rebootConsole() }
            }
            .disabled(!appState.deviceManager.canInteract || appState.taskRunner.isRunning || appState.isPreparingSync)

            Button("Shutdown") {
                Task { await appState.shutdownConsole() }
            }
            .disabled(!appState.deviceManager.canInteract || appState.taskRunner.isRunning || appState.isPreparingSync)
        }
    }
}

struct ModulesCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage("showAdvancedFeatures") private var showAdvancedFeatures = false

    var body: some Commands {
        if showAdvancedFeatures {
            CommandMenu("Modules") {
                Button("Module Manager...") {
                    appState.showModuleManager = true
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

struct ToolsCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage("showAdvancedFeatures") private var showAdvancedFeatures = false

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Export Troubleshooting Logs…") { DiagnosticLogExport.present(logs: AppConfig.shared.workspace.logs) }
            Divider()
            Button("Cheat Codes…") { appState.showCodeCatalog = true }
            Button("Automatic Folders...") { appState.showFolders = true }
            Button("Back Up Console...") { appState.exportConsoleBackup() }
                .disabled((!appState.deviceManager.canSync && appState.deviceManager.legacyReport == nil) || appState.taskRunner.isRunning || appState.gameManager.isLoading || appState.isPreparingSync)
            Button("Review Legacy Change / Undo…") { appState.reviewLegacyChange() }
                .disabled(appState.deviceManager.legacyReport == nil || appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading || appState.isPreparingSync)
            if showAdvancedFeatures {
                Button("Review Legacy NES Sync Trial…") { appState.reviewLegacySyncTrial() }
                    .disabled(appState.deviceManager.legacyReport == nil || appState.taskRunner.isRunning
                              || appState.isPreparingSync || appState.gameManager.isLoading)
            }
            Button("Sync Library / Update Game Library…") { appState.reviewLibrarySync() }
                .disabled(!appState.canReviewLibrarySync)
            if showAdvancedFeatures {
                Button("Reclaim Console Space…") { appState.reviewLegacyArchiveReclaim() }
                    .disabled(appState.deviceManager.legacyReport == nil || appState.taskRunner.isRunning
                              || appState.isPreparingSync || appState.gameManager.isLoading)
            }
            Button("Recover Interrupted Sync") { appState.recoverInterruptedSync() }
                .disabled(!appState.deviceManager.canSync || appState.taskRunner.isRunning)
            Button("Reset Selections to Installed Games") { appState.gameManager.resetSelectionsToInstalled() }
                .disabled(appState.taskRunner.isRunning || appState.gameManager.isInspectingLegacy)
            Divider()
            Button("Scraper...") {
                appState.showScraper = true
            }

            if showAdvancedFeatures {
                Divider()
                Button("Dump Stock Kernel") {
                    appState.requestFlash(.dumpStockKernel)
                }
                .disabled(!appState.deviceManager.canInteract || appState.taskRunner.isRunning || appState.isPreparingSync)
            }
        }
    }
}

struct HelpCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Hakchi Console Hub Help") {
                appState.showHelp = true
            }
            .keyboardShortcut("?")
        }
    }
}

struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Hakchi Console Hub") {
                let credits = NSMutableAttributedString()
                let style = NSMutableParagraphStyle()
                style.alignment = .center

                credits.append(NSAttributedString(
                    string: "Beta software · Built with Swift\nManage games and backups for classic mini consoles.\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: style,
                    ]
                ))

                let url = URL(string: "https://github.com/mattackerman808/swift-hakchi2")!
                credits.append(NSAttributedString(
                    string: "Original project on GitHub",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .link: url,
                        .paragraphStyle: style,
                    ]
                ))

                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: credits,
                ])
            }
            Button("Check for Updates…") { UpdateChecker.shared.check() }
                .disabled(UpdateChecker.shared.checking)
        }
    }
}
