import SwiftUI
import SwiftHakchiCore

/// Keeps the included console game untouched and asks for a source explicitly.
struct IncludedGameCheatSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let included: Game
    @State private var selectedSource: Game?
    @State private var isCopying = false
    @State private var copyProgress = ""
    @State private var copyError: String?
    @State private var copyTask: Task<Void, Never>?

    private var candidates: [Game] {
        IncludedGameCheatSources.matches(for: included, games: appState.gameManager.games)
    }

    var body: some View {
        if let selectedSource {
            GameGenieView(game: selectedSource).environmentObject(appState)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cheat Codes for \(included.name)").font(.title2.bold())
                Text("Make a separate Cheat Code copy. The included game and its saves stay as they are.")
                if included.consoleType == .snesUsa {
                    Text("Copy this game from your connected SNES to this Mac, then choose your cheat codes. Leave the SNES at its game menu during the copy.")
                        .foregroundStyle(.secondary)
                    if isCopying {
                        HStack { ProgressView().controlSize(.small); Text(copyProgress) }
                    } else {
                        Button("Copy From SNES") { copyTask = Task { await copyFromSNES() } }
                            .disabled(!appState.deviceManager.isConnected || appState.deviceManager.consoleType != .snesUsa)
                        if !appState.deviceManager.isConnected || appState.deviceManager.consoleType != .snesUsa {
                            Text("Connect your SNES in the app first, then leave it on the game menu.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Copying an included game directly from this console is not available yet. You can choose a matching game already added to this Mac.").foregroundStyle(.secondary)
                }
                if let copyError { Text(copyError).foregroundStyle(.red) }
                if candidates.isEmpty {
                    Text("No matching game is already on this Mac.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Or choose a game already on this Mac:").font(.headline)
                    Text("A matching name does not guarantee the same game version.").font(.caption).foregroundStyle(.secondary)
                    List(candidates) { candidate in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(candidate.name)
                                if let filename = sourceFilename(candidate) {
                                    Text("File: \(filename)").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Added game · \(candidate.code)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use This Game") { selectedSource = candidate }.disabled(isCopying)
                        }.padding(.vertical, 4)
                    }.frame(minHeight: 100, maxHeight: 220)
                }
                Spacer()
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isCopying) }
            }.padding(22).frame(width: 650).frame(minHeight: 320)
                .onDisappear { copyTask?.cancel() }
        }
    }

    @MainActor private func copyFromSNES() async {
        guard !isCopying, included.isStock, included.consoleType == .snesUsa,
              appState.deviceManager.isConnected, appState.deviceManager.consoleType == .snesUsa,
              let context = appState.deviceManager.nativeSNESContext,
              let connection = appState.deviceManager.nativeSNES else { return }
        isCopying = true; copyError = nil; copyProgress = "Checking your SNES…"
        defer { isCopying = false }
        let session = appState.deviceManager.sessionID
        do {
            let rom = try await connection.readIncludedGame(context, code: included.code) { completed, total in
                await MainActor.run { copyProgress = "Copying from SNES… \(completed * 100 / total)%" }
            }
            try Task.checkCancellation()
            guard appState.deviceManager.sessionID == session, appState.deviceManager.isConnected else { throw LegacyInspectionError.disconnected }
            let digest = GameGenieWorkflow.digest(rom)
            let manager = appState.gameManager
            if let existing = manager.games.first(where: { game in
                game.source == .local && !game.isCheatCodeCopy && game.consoleType == .snesUsa &&
                (try? GameGenieWorkflow.managedSourceDigest(game: game, manager: manager)) == digest
            }) {
                openCopiedSource(existing, manager: manager); return
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HakchiIncluded-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let title = String(included.name.map { character in
                character == "/" || character == ":" || character == "\\" || character.isNewline ? " " : character
            }.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
            let file = temporary.appendingPathComponent((title.isEmpty ? included.code : title) + ".sfc")
            try rom.write(to: file, options: .atomic)
            let before = Set(manager.games.map(\.code))
            _ = try await manager.importROMsResponsive(urls: [file], consoleType: .snesUsa, reviewIncluded: { _ in .keepCopies }, forceUnselected: true) { message, _ in
                await MainActor.run { copyProgress = message }
            }
            guard let index = manager.games.firstIndex(where: { game in
                !before.contains(game.code) && game.source == .local &&
                (try? GameGenieWorkflow.managedSourceDigest(game: game, manager: manager)) == digest
            }) else {
                throw SyncPlanError.invalidInput("The game could not be matched to its verified copy. Check your Mac library before trying again.")
            }
            manager.games[index].isSelected = false
            openCopiedSource(manager.games[index], manager: manager)
        } catch {
            copyError = "Couldn’t prepare this game: \(error.localizedDescription)"
        }
    }

    @MainActor private func openCopiedSource(_ game: Game, manager: GameManagerService) {
        do {
            _ = try GameGenieWorkflow.open(game: game, manager: manager)
            selectedSource = game
        } catch {
            copyError = "The game is safely on your Mac, but Cheat Codes can’t use this game yet: \(error.localizedDescription)"
        }
    }

    private func sourceFilename(_ game: Game) -> String? {
        let folder = URL(fileURLWithPath: game.romPath, isDirectory: true)
        let allowed = ROMImportPolicy.extensions(for: game.consoleType)
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { allowed.contains($0.pathExtension.lowercased()) }
        guard names?.count == 1 else { return nil }
        return names?.first?.lastPathComponent
    }
}
