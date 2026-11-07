import SwiftUI

/// Which panel last selected a game
enum SelectionSource {
    case explorer, consoleBar
}

/// Main app window with sidebar game list + detail view
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    /// Fraction of the total width used by the left (explorer) panel, 0.0–1.0
    @State private var splitFraction: CGFloat = 0.50
    @State private var poofLocation: CGPoint = .zero
    @State private var showPoof = false
    @State private var dragOverRemove = false
    @State private var dragLocation: CGPoint = .zero
    @State private var dragLabelText: String = "Remove"
    @State private var isDraggingFromExplorer = false
    /// Tracks which panel last selected a game, so only that panel shows the lift
    @State private var selectionSource: SelectionSource = .explorer

    var body: some View {
        VStack(spacing: 0) {
            // Action bar with common task buttons
            ActionBarView()

            Divider()

            // Top: explorer + detail with a draggable divider
            GeometryReader { geo in
                let minLeft: CGFloat = 300
                let minRight: CGFloat = 300
                let totalWidth = geo.size.width
                let leftWidth = max(minLeft, min(totalWidth - minRight, totalWidth * splitFraction))

                HStack(spacing: 0) {
                    GameGridView(isDraggingFromExplorer: $isDraggingFromExplorer, selectionSource: $selectionSource)
                        .frame(width: leftWidth)

                    // Draggable divider
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 5)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newLeft = leftWidth + value.location.x - value.startLocation.x
                                    splitFraction = max(minLeft / totalWidth, min(1 - minRight / totalWidth, newLeft / totalWidth))
                                }
                        )

                    detailPanel
                        .frame(maxWidth: .infinity)
                }
                // Drop zone — deselects games dragged off the bar
                .onDrop(of: [.text], delegate: PoofDropDelegate(
                    appState: appState,
                    poofLocation: $poofLocation,
                    showPoof: $showPoof,
                    dragOverRemove: $dragOverRemove,
                    dragLocation: $dragLocation,
                    dragLabelText: $dragLabelText,
                    isDraggingFromExplorer: $isDraggingFromExplorer
                ))
                // Dim the explorer + detail when dragging a game off the bar
                .overlay {
                    if dragOverRemove {
                        Color.black.opacity(0.3)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: dragOverRemove)
                // "Remove" / "Hide" speech bubble — follows the dragged icon, clamped to stay visible
                .overlay {
                    if dragOverRemove {
                        let bubbleX = min(max(60, dragLocation.x), geo.size.width - 60)
                        let bubbleY = max(25, dragLocation.y - 110)
                        DockBubbleLabel(text: dragLabelText)
                            .fixedSize()
                            .position(x: bubbleX, y: bubbleY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: dragOverRemove)
                // Poof animation on drop
                .overlay {
                    if showPoof {
                        Image(systemName: "cloud")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                            .position(poofLocation)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.5).combined(with: .opacity),
                                removal: .scale(scale: 1.8).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.easeOut(duration: 0.35), value: showPoof)
            }

            // Bottom: console game bar
            ConsoleGameBar(isDraggingFromExplorer: $isDraggingFromExplorer, selectionSource: $selectionSource)

            // Status bar
            Divider()
            StatusBarView()
        }
        .sheet(isPresented: $appState.showLegacyChange) {
            if let workspace = appState.legacyChangeWorkspace, let session = appState.legacyChangeSession {
                LegacyGameChangeView(game: appState.legacyChangeGame, workspace: workspace, session: session)
                    .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showLegacySyncTrial) {
            LegacySyncTrialView(workspace: AppConfig.shared.workspace,
                                session: appState.deviceManager.sessionID)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showLegacyFullSync) {
            LegacyFullSyncView(workspace: AppConfig.shared.workspace,
                               session: appState.deviceManager.sessionID)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showSNESLibrarySync) {
            SNESLibrarySyncView(originalsOnly: appState.snesLibraryOriginalsOnly).environmentObject(appState)
        }
        .sheet(isPresented: $appState.showLegacyArchiveReclaim) {
            LegacyArchiveReclaimView(workspace: AppConfig.shared.workspace,
                                     session: appState.deviceManager.sessionID)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showInstallConfig) {
            InstallConfigSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showTaskProgress) {
            TaskProgressSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showWaitingForDevice) {
            WaitingDeviceSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showScraper) {
            if let game = appState.selectedGame {
                ScraperView(game: binding(for: game))
                    .environmentObject(appState)
            } else {
                VStack(spacing: 12) {
                    Text("No game selected")
                        .font(.headline)
                    Text("Select a game first, then open the scraper.")
                        .foregroundStyle(.secondary)
                    Button("Close") { appState.showScraper = false }
                }
                .padding(40)
                .frame(minWidth: 300)
            }
        }
        .sheet(isPresented: $appState.showModuleManager) {
            ModuleManagerView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showSNESBackup) {
            SNESBackupView(execute: { progress in try await appState.captureSNESSetup(progress: progress) },
                           prepareRecovery: { backup in try await appState.prepareSNESRecoveryPackage(from: backup) },
                           prepareHelpers: { try await appState.prepareSNESSetupHelpers() },
                           prepareStartup: { backup, recovery, helpers, progress in
                               try await appState.checkSNESStartup(backup: backup, recovery: recovery, helpers: helpers, progress: progress)
                           }, captureMenuSupport: { backup, recovery, helpers, startup, progress in
                               try await appState.captureSNESMenuSupport(backup: backup, recovery: recovery, helpers: helpers, startup: startup, progress: progress)
                           }, captureComponents: { backup, recovery, helpers, startup, support, progress in
                               try await appState.captureSNESOriginalComponents(backup: backup, recovery: recovery, helpers: helpers, startup: startup, support: support, progress: progress)
                           }, captureData: { backup, recovery, helpers, chain, progress, detail in
                               try await appState.backupSNESData(backup: backup, recovery: recovery, helpers: helpers, chain: chain, progress: progress, detail: detail)
                           }, captureRuntime: { backup, recovery, helpers, chain, data, progress in
                               try await appState.captureSNESRuntime(backup: backup, recovery: recovery, helpers: helpers, chain: chain, data: data, progress: progress)
                           }, prepareCandidate: { backup, recovery, helpers, chain, data, runtime, progress in
                               try await appState.prepareSNESStartupCandidate(backup: backup, recovery: recovery, helpers: helpers, chain: chain, data: data, runtime: runtime, progress: progress)
                           }, preflight: { candidate, progress in
                               try await appState.checkSNESStartupCandidate(candidate, progress: progress)
                           }, startTrial: { candidate, preflight, progress in
                               try await appState.runSNESStartupTrial(candidate: candidate, preflight: preflight, progress: progress)
                           }, checkTrial: { candidate, preflight, started, progress in
                               try await appState.runSNESStartupTrial(candidate: candidate, preflight: preflight, started: started, progress: progress)
                           }, captureActive: { backup, helpers, candidate, preflight, started, played, progress in
                               try await appState.captureSNESActiveStartup(backup: backup, helpers: helpers, candidate: candidate,
                                   preflight: preflight, started: started, played: played, progress: progress)
                           }, prepareFirmwarePlan: { backup, helpers, candidate, preflight, started, played, active, data in
                               try await appState.prepareSNESFirmwarePlan(backup: backup, helpers: helpers, candidate: candidate,
                                   preflight: preflight, started: started, played: played, active: active, currentData: data)
                           })
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showRecoveryReadiness, onDismiss: { appState.openRequestedOriginalGamesReview() }) {
            RecoveryReadinessView(backups: AppConfig.shared.workspace.backups, context: appState.recoveryContext, legacySnapshot: appState.deviceManager.legacyReport,
                                  onOriginalGamesReview: appState.deviceManager.consoleType == .snesUsa && appState.canReviewLibrarySync ? { appState.requestOriginalGamesReview() } : nil)
        }
        .sheet(isPresented: $appState.showHelp) {
            HelpView()
        }
        .alert("Remove Game from Mac Library?", isPresented: $appState.showDeleteConfirmation) {
            Button("Remove from Mac", role: .destructive) {
                appState.confirmDeleteSelectedGame()
            }
            Button("Cancel", role: .cancel) {
                appState.showDeleteConfirmation = false
            }
        } message: {
            Text("Remove \"\(appState.selectedGame?.name ?? "")\" and its artwork from this app? Your original ROM file and games on the console stay unchanged. To remove it from the console too, use Sync Library and review the games to remove.")
        }
        .confirmationDialog("Remove all imported games from this library?", isPresented: $appState.showRemoveLocalLibrary) {
            Button("Remove Imported Library", role: .destructive) { appState.removeLocalLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app moves this console’s imported games, titles, and artwork into Removed Libraries on your Mac. Your original ROM folders and games on the console are unchanged. You can then add a new collection.")
        }
        .sheet(isPresented: $appState.showSyncConfirmation) {
            if let plan = appState.preparedPlan {
                SyncReviewView(plan: plan, confirm: appState.confirmSync, cancel: { appState.showSyncConfirmation = false })
            }
        }
        .sheet(isPresented: $appState.showCodeCatalog) {
            GameGenieCatalogView(gameName: "", system: GameGenieSystem(console: AppConfig.shared.lastConsoleType) ?? .nes)
        }
        .sheet(isPresented: $appState.showFolders) {
            let report = appState.deviceManager.legacyReport
            let remote = appState.gameManager.legacyRemoteGames
            let complete = report.map { $0.visibleCodes.isSubset(of: Set(remote.map(\.code))) } ?? false
            ConsoleStructureView(
                console: appState.deviceManager.consoleType == .unknown
                    ? AppConfig.shared.lastConsoleType : appState.deviceManager.consoleType,
                games: complete ? remote.filter { report!.visibleCodes.contains($0.code) } : nil,
                stockCodes: complete ? report?.stockCodes : nil)
                .environmentObject(appState)
        }
        .alert("Console Operation", isPresented: $appState.showOperationError) {
            Button("OK") {}
        } message: {
            Text(appState.operationError ?? "The operation could not be completed.")
        }
        .onAppear {
            appState.gameManager.loadGames()

        }
    }

    /// Always the same view type so HSplitView keeps the divider stable
    @ViewBuilder
    private var detailPanel: some View {
        if let game = appState.selectedGame {
            GameDetailView(game: binding(for: game))
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "info.square")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Click a game card to see its details")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for game: Game) -> Binding<Game> {
        Binding(
            get: {
                appState.gameManager.games.first(where: { $0.id == game.id }) ?? game
            },
            set: { newValue in
                if let index = appState.gameManager.games.firstIndex(where: { $0.id == game.id }) {
                    appState.gameManager.games[index] = newValue
                }
            }
        )
    }
}

/// Drop delegate that deselects games dragged off the console bar with a poof animation.
/// Shows a Dock-style "Remove"/"Hide" speech bubble while hovering.
struct PoofDropDelegate: DropDelegate {
    let appState: AppState
    @Binding var poofLocation: CGPoint
    @Binding var showPoof: Bool
    @Binding var dragOverRemove: Bool
    @Binding var dragLocation: CGPoint
    @Binding var dragLabelText: String
    @Binding var isDraggingFromExplorer: Bool

    func dropEntered(info: DropInfo) {
        // Resolve the game to pick the right label
        for provider in info.itemProviders(for: [.text]) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let gameId = object as? String else { return }
                Task { @MainActor in
                    if let game = appState.gameManager.games.first(where: { $0.id == gameId }) {
                        dragLabelText = game.isStock ? "Hide" : "Remove"
                    }
                }
            }
        }
        dragLocation = info.location
        dragOverRemove = true
    }

    func dropExited(info: DropInfo) {
        dragOverRemove = false
        isDraggingFromExplorer = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragLocation = info.location
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragOverRemove = false
        isDraggingFromExplorer = false
        poofLocation = info.location
        showPoof = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showPoof = false
        }

        for provider in info.itemProviders(for: [.text]) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let gameId = object as? String else { return }
                Task { @MainActor in
                    if let index = appState.gameManager.games.firstIndex(where: { $0.id == gameId }) {
                        appState.gameManager.games[index].isSelected = false
                    }
                }
            }
        }
        return true
    }
}

/// Dock-style "Remove" / "Hide" bubble matching macOS Dock appearance:
/// gray rounded pill with a small downward-pointing triangle.
struct DockBubbleLabel: View {
    let text: String

    private let bubbleColor = Color(white: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(bubbleColor)
                )
            // Triangle pointer
            Triangle()
                .fill(bubbleColor)
                .frame(width: 14, height: 8)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// Downward-pointing triangle for the bubble pointer
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// Toolbar-style action bar with prominent buttons for common tasks
struct ActionBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @State private var isReconnecting = false
    @State private var reconnectStopRequested = false
    @State private var reconnectTask: Task<Void, Never>?
    @State private var showReconnectFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Console", selection: Binding(get: { config.lastConsoleType }, set: { appState.changeLibraryConsole(to: $0) })) {
                    ForEach(ConsoleType.allCases.filter { $0 != .unknown }) { console in
                        Text(console.displayName).tag(console)
                    }
                }.frame(width: 250)
                    .disabled(isReconnecting || appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
                    .help("Choose a local library. A recognized console switches this automatically when connected.")
                if appState.deviceManager.isConnected {
                    Text("Connected: " + appState.deviceManager.consoleType.displayName).foregroundStyle(.secondary)
                }
                Spacer()
            }
        HStack(spacing: 6) {
            if config.lastConsoleType == .snesUsa {
                Button {
                    appState.reviewSNESBackup()
                } label: {
                    Label("Set Up SNES…", systemImage: "cpu")
                }
                .buttonStyle(ActionButtonStyle(role: .primary, compact: true))
                .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
                .help("Start with a backup and console check. First-time SNES setup is a preview.")

                FirmwareActionInfo(title: "Set Up SNES", explanation:
                    "Start by saving the current startup software and checking the console. Follow the separate reviews for each update. This first-time setup flow has not yet been tested on a new SNES.")
            } else {
                Button {
                    appState.requestFlash(.installHakchi)
                } label: {
                    Label("Install Kernel", systemImage: "cpu")
                }
                .buttonStyle(ActionButtonStyle(role: .primary, compact: true))
                .disabled(true)
                .help("Permanently changes console startup software; currently unavailable. Select the info button for details.")

                FirmwareActionInfo(title: "Install Kernel", explanation:
                    "Installs modified startup software in the console's internal storage. It stays installed after power is turned off and can enable custom game management. It does not add games by itself. This action needs a verified original-kernel backup and a guided recovery path, so it is unavailable while installation is validated for each console.")
            }

            // Connect / Disconnect
            Button {
                if isReconnecting {
                    reconnectStopRequested = true
                    reconnectTask?.cancel()
                    appState.deviceManager.manualDisconnect()
                } else if appState.deviceManager.isConnected {
                    appState.deviceManager.manualDisconnect()
                } else {
                    attemptReconnect()
                }
            } label: {
                if isReconnecting {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                        Text(reconnectStopRequested ? "Stopping…" : "Stop Connecting")
                    }
                } else if appState.deviceManager.isConnecting {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                        Text("Connecting…")
                    }
                } else if appState.deviceManager.isConnected {
                    Label("Disconnect", systemImage: "cable.connector.slash")
                } else {
                    Label("Connect", systemImage: "cable.connector")
                }
            }
            .buttonStyle(ActionButtonStyle(role: appState.deviceManager.isConnected ? .connected : .normal, compact: true))
            .disabled(reconnectStopRequested || (!isReconnecting && appState.deviceManager.isConnecting) || appState.taskRunner.isRunning || appState.isPreparingSync)
            .help(isReconnecting ? "Stop the connection attempt" : appState.deviceManager.isConnected ? "Disconnect from console" : "Connect to console")
            .alert("Connection Failed", isPresented: $showReconnectFailed) {
                Button("OK") {}
            } message: {
                if let error = appState.deviceManager.lastConnectionError {
                    Text(error)
                } else if appState.deviceManager.felDevicePresent && !appState.deviceManager.usbMonitor.rndisDevicePresent {
                    Text("This USB identity is shared by older Clovershell firmware and the FEL bootloader. Connect verifies Clovershell before attempting a read-only inspection. A genuine FEL device cannot provide a game library. A USB ID alone does not establish FEL mode. Do not reinstall or reset the console just to connect; preserve its current games and saves first.")
                } else {
                    Text("Could not connect to the console.\n\n\u{2022} If a game or demo is playing, return to the game-selection menu.\n\u{2022} Check the USB cable and reconnect it if needed.\n\u{2022} If another app or virtual machine is using the console's USB connection, disconnect it there first.\n\u{2022} If the console is unresponsive, switch it off, wait a few seconds, then switch it on.\n\nChoose Connect to try again.")
                }
            }

            Button {
                Task { await appState.rebootConsole() }
            } label: {
                Label("Reboot", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ActionButtonStyle(compact: true))
            .disabled(!appState.deviceManager.canInteract)
            .help("Reboot the console")

            Button {
                appState.showFolders = true
            } label: {
                Label("Folder Structure", systemImage: "folder")
            }
            .buttonStyle(ActionButtonStyle(compact: true))
            .disabled(appState.taskRunner.isRunning || appState.isPreparingSync)
            .help("Choose how games and folders appear on the console")

            Button {
                appState.reviewLibrarySync()
            } label: {
                Label("Sync Library", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(ActionButtonStyle(compact: true))
            .disabled(!appState.canReviewLibrarySync)
            .help("Review changes to the connected console's game library before syncing")

            Button {
                appState.showRecoveryReadiness = true
            } label: {
                Label("Restore Console", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(ActionButtonStyle(compact: true))
            .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
            .help("Review original games, startup recovery and save-reset options for this console")

            Button {
                appState.reviewLegacyArchiveReclaim()
            } label: {
                Label("Reclaim Space", systemImage: "externaldrive.badge.minus")
            }
            .buttonStyle(ActionButtonStyle(compact: true))
            .disabled(appState.deviceManager.legacyReport == nil || appState.taskRunner.isRunning
                      || appState.isPreparingSync || appState.gameManager.isLoading)
            .help("Review cleanup of a tested NES library's temporary transfer archive and former menu")

            Spacer()
        }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func attemptReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true; reconnectStopRequested = false
        reconnectTask = Task {
            let success = await appState.deviceManager.reconnect()
            let cancelled = Task.isCancelled
            isReconnecting = false; reconnectStopRequested = false; reconnectTask = nil
            if !success && !cancelled {
                showReconnectFailed = true
            }
        }
    }

}

private struct FirmwareActionInfo: View {
    let title: String
    let explanation: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(title)")
        .help("About \(title)")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(explanation).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

/// Custom button style for the action bar
struct ActionButtonStyle: ButtonStyle {
    enum Role { case primary, normal, connected }

    var role: Role = .normal
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption : .callout)
            .fontWeight(role == .primary ? .semibold : .regular)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(role == .primary || role == .connected ? .white : .primary)
            .background(
                Capsule()
                    .fill(role == .primary ? Color.accentColor : role == .connected ? Color.green : Color.clear)
            )
            .background(
                Capsule()
                    .strokeBorder(.separator, lineWidth: role == .primary ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
