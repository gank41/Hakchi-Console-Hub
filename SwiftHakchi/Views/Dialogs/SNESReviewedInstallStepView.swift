import SwiftUI

/// The first installation stage only. It does not claim game-sync setup is finished.
struct SNESReviewedInstallStepView: View {
    @StateObject private var flow: SNESReviewedInstallFlow
    @Binding private var busy: Bool
    @Binding private var engaged: Bool
    private let app: AppState
    private let check: SNESReviewedConsoleCheck
    private let onComplete: () -> Void
    private let onNormalBootProblem: () -> Void
    @State private var ready = false
    @State private var showApproval = false

    init(app: AppState, check: SNESReviewedConsoleCheck, busy: Binding<Bool>, engaged: Binding<Bool>, onComplete: @escaping () -> Void, onNormalBootProblem: @escaping () -> Void,
         initialPhase: SNESReviewedInstallFlow.Phase = .ready) {
        _busy = busy; _engaged = engaged; self.app = app; self.check = check; self.onComplete = onComplete; self.onNormalBootProblem = onNormalBootProblem
        _flow = StateObject(wrappedValue: SNESReviewedInstallFlow(
            install: { progress in try await app.runSNESReviewedInstallation(check, ready: true, approved: true, progress: progress) },
            checkMenu: { try await app.checkSNESReviewedInstallation(check, ready: true) },
            accept: { try await app.acceptSNESReviewedInstallation(check, confirmed: true) }, initialPhase: initialPhase))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch flow.phase {
            case .ready:
                Text("First startup update").font(.headline)
                Text("This is the first part of setup. More startup and game-folder steps follow before you can sync games.")
                    .foregroundStyle(.secondary)
                Text("This app's first-time update has not yet been tested on a new SNES.").foregroundStyle(.secondary)
                Text("Turn the SNES OFF and unplug USB for 10 seconds. Slide power ON while unplugged, hold RESET while reconnecting USB, wait five seconds, then release RESET.")
                Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(busy)
                Button("Review First Startup Update…") { engaged = true; showApproval = true }.disabled(!ready || busy)
            case .writing:
                HStack { ProgressView().controlSize(.small); Text(flow.stage.title) }
                Text("Keep power and USB connected until the update finishes.").foregroundStyle(.secondary)
            case .restart:
                Label("Startup update checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Turn the SNES OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                HStack {
                    Button("Menu Doesn't Work") { flow.reportMenuProblem(); onNormalBootProblem() }.disabled(busy)
                    Button("Menu Is Visible") { run { await flow.checkMenu(visible: true) } }.disabled(busy)
                }
            case .verifying:
                HStack { ProgressView().controlSize(.small); Text("Checking the normal startup…") }
            case .gameTest:
                Text("Play one built-in game. Check the picture, sound and controls, then press RESET to return to the game menu.")
                HStack {
                    Button("Game Doesn't Work") { run { await flow.confirmGame(works: false) } }.disabled(busy)
                    Button("Game Works") { run { await flow.confirmGame(works: true); if flow.phase == .firstStageComplete { onComplete() } } }.disabled(busy)
                }
            case .completing:
                HStack { ProgressView().controlSize(.small); Text("Saving your confirmation…") }
            case .firstStageComplete:
                Label("First startup update complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Keep the backup and continue with the menu and game-folder steps below. This first step alone does not enable game syncing.")
                if let next = SNESMenuPreparationView(app: app, record: .init(check: check, phase: .menuAccepted), busy: $busy, onNormalBootProblem: onNormalBootProblem) { next }
            case .stopped:
                Label("Update stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Keep the saved review and backup. Return the SNES to its normal menu and check a built-in game before trying another setup.")
            case .uncertain:
                Label("Update needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Keep power and USB connected. Do not restart or retry the update. Keep the saved review and backup for help.")
            case .needsAttention:
                Label("Console needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Keep the saved review and backup. Do not repeat the update; check the saved installation record before continuing.")
            }
            if let error = flow.error { DisclosureGroup("Details") { Text(error).textSelection(.enabled) } }
        }
        .alert("Install the first startup update?", isPresented: $showApproval) {
            Button("Cancel", role: .cancel) { engaged = false }
            Button("Install First Update") { run { await flow.install(ready: ready, approved: true) } }
        } message: {
            Text("This writes startup software to the SNES. This app's first-time setup has not yet been tested on a new SNES. More setup is needed before syncing games. Keep power and USB connected until the app finishes.")
        }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; await action() }
    }
}
