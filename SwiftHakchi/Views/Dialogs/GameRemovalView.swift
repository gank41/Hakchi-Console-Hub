import SwiftUI

/// Routes to the existing reviewed console sync or confirmed Mac-library actions.
struct GameRemovalView: View {
    @EnvironmentObject private var appState: AppState
    let removeFromConsole: () -> Void
    let openMacLibrary: () -> Void
    let removeSelected: (Game) -> Void
    let removeAll: () -> Void
    let close: () -> Void

    private var idle: Bool {
        !appState.taskRunner.isRunning && !appState.isPreparingSync && !appState.gameManager.isLoading
    }
    private var consoleReady: Bool {
        idle && appState.deviceManager.consoleType == .nes
            && appState.deviceManager.legacyReport != nil && appState.deviceManager.legacyClient != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove Games").font(.title2.bold())
            Text("Choose where you want to remove games.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("From the console", systemImage: "gamecontroller").font(.headline)
                            Text("Keep the games on your Mac. Open the console game list, uncheck the games you no longer want, then follow the three sync steps.")
                            Text("If a game is already missing from your Mac library, confirm its removal when the game list asks.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Choose Console Games…", action: removeFromConsole).disabled(!consoleReady)
                            if !consoleReady {
                                Text("Connect your NES Classic to change its games. This console-removal workflow currently supports NES.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("From the Mac library", systemImage: "desktopcomputer").font(.headline)
                            Text("Remove a game's imported ROM, name and artwork from this app. Your original ROM file and games already on the console stay where they are.")
                            if appState.gameManager.isInspectingLegacy {
                                Text("Open the Mac library first, select a game, then choose Remove Games again.")
                                Button("Open Mac Library", action: openMacLibrary).disabled(!idle)
                            } else if let game = appState.selectedGame, game.source == .local {
                                Text("Selected: " + game.name).font(.callout.bold())
                                Button("Remove Selected Game…", role: .destructive) { removeSelected(game) }
                                    .disabled(!appState.canChangeGameSelection)
                            } else {
                                Text("Select an imported game in the library first, then choose Remove Games again. Built-in games are kept.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Divider()
                            Text("Starting a new collection?").font(.callout.bold())
                            Text("Remove all imports from this Mac library. The app keeps a recoverable copy, including your edited names and artwork, in Removed Libraries on your Mac.")
                                .font(.callout)
                            Button("Remove All Imported Games…", role: .destructive, action: removeAll)
                                .disabled(!idle || appState.gameManager.legacyLocalGames.isEmpty)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
            }
            HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 640, height: 590)
    }
}
