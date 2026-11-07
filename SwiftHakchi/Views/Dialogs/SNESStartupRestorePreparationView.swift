import SwiftUI
import AppKit

struct SNESStartupRestorePreparationView: View {
    private enum Step { case choose, prepared, returnAfterCheck, readyToRestore, returnAfterRestore, complete, stopped, normalBootFailed, uncertain }
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: URL?
    @State private var prepared: SNESPreparedStartupRestore?
    @State private var step: Step = .choose
    @State private var working = false
    @State private var ready = false
    @State private var showApproval = false
    @State private var progress = ""
    @State private var error: String?
    @State private var errorDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Restore Original SNES Startup", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if step == .choose {
                        Text("Choose the saved installation made for this SNES. The app can prepare the original startup files from it on this Mac.")
                        Text("To continue an earlier restore, open its saved restore folder instead. Keep your backups.").foregroundStyle(.secondary)
                        if let selected { Text("Selected: \(selected.lastPathComponent)").textSelection(.enabled) }
                        HStack {
                            Button("Choose Installation…") { chooseFolder(restore: false) }
                            Button("Open Saved Restore…") { chooseFolder(restore: true) }
                        }.disabled(working)
                        Button("Prepare Restore Files") { prepare() }.disabled(working || selected == nil)
                    }
                    if let prepared, step != .choose {
                        Button("Show Restore Record in Finder") { NSWorkspace.shared.activateFileViewerSelecting([prepared.operation]) }
                        if !prepared.hasTestedWriter && step == .prepared {
                            Label("Restore not available for these files yet", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("The startup tool in this record still needs console testing. Your saved files are kept; the console was not changed.")
                        }
                    }
                    if step == .prepared, prepared?.hasTestedWriter == true {
                        Text("First, the app checks that these files belong to the connected SNES. It does not restore anything during this check.")
                        readiness
                        Button("Check This SNES") { run(.preflight) }.disabled(working || !ready)
                    }
                    if step == .returnAfterCheck {
                        Label("Check complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("No startup software was changed. Turn the SNES OFF, unplug USB for 10 seconds, reconnect with RESET released, and turn it ON normally. Check that the game menu and a built-in game work.")
                        HStack {
                            Button("Menu or Game Doesn't Work") { step = .normalBootFailed }
                            Button("Menu and Game Work") { ready = false; step = .readyToRestore }
                        }.disabled(working)
                    }
                    if step == .readyToRestore, prepared?.hasTestedWriter == true {
                        Text("The next step returns this SNES to its original startup software. Added games may no longer appear in its menu until the console is set up again. The app will ask you to confirm before proceeding.")
                        readiness
                        Button("Review and Restore…") { showApproval = true }.disabled(working || !ready)
                    }
                    if step == .readyToRestore, prepared?.hasTestedWriter == false {
                        Label("Restore not available for these files yet", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("The startup tool in this record still needs console testing. Keep the saved restore record.")
                    }
                    if step == .returnAfterRestore {
                        Label("Original startup verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Turn the SNES OFF, unplug USB for 10 seconds, reconnect with RESET released, and turn it ON normally. Check that the game menu and a built-in game work, including picture, sound and controls.")
                        HStack {
                            Button("Menu or Game Doesn't Work") { step = .normalBootFailed }
                            Button("Menu and Game Work") { accept() }
                        }.disabled(working)
                    }
                    if step == .complete {
                        Label("Restore complete", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("The startup was checked and you confirmed normal gameplay. Keep the saved backups on your Mac.")
                    }
                    if step == .stopped {
                        Label("The restore stopped", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Keep the saved record. If the console was in preparation mode, return it to normal startup and check its menu and a built-in game. To try again, prepare a new restore from the saved installation.")
                    }
                    if step == .normalBootFailed {
                        Label("Normal startup needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Keep the saved restore record and your backups. Do not retry the restore until the normal menu and a built-in game work.")
                    }
                    if step == .uncertain {
                        Label("The restore could not be verified", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Keep power and USB connected. Do not restart or retry the restore. Keep the saved record for inspection.")
                    }
                    if working {
                        HStack { ProgressView().controlSize(.small); Text(progress) }
                        Text("Keep the app open. If the SNES is connected, keep power and USB connected.").foregroundStyle(.secondary)
                    }
                    if let error {
                        Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled)
                        if let errorDetail { DisclosureGroup("Details") { Text(errorDetail).textSelection(.enabled) } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.disabled(working) }
        }
        .padding(24).frame(width: 560, height: 560)
        .interactiveDismissDisabled(working)
        .alert("Restore original startup?", isPresented: $showApproval) {
            Button("Cancel", role: .cancel) { }
            Button("Restore Startup") { run(.write) }
        } message: {
            Text("This writes the original startup software to the connected SNES. Added games may no longer appear in its menu. Keep power and USB connected until the app finishes. Your saved record will be kept.")
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Close other Hakchi apps and connect only this SNES. Turn it OFF, unplug USB for 10 seconds, then slide power ON while unplugged. Hold RESET while reconnecting USB, wait five seconds, and release RESET.")
            Toggle("The power light is off and the TV is blank", isOn: $ready).disabled(working)
        }
    }

    private func chooseFolder(restore: Bool) {
        let panel = NSOpenPanel()
        panel.title = restore ? "Open a Saved SNES Restore" : "Choose the Saved SNES Installation"
        panel.message = restore ? "Choose the SNESFirmware folder for the restore you prepared." : "Choose the SNESFirmware folder for this console's earlier installation."
        panel.directoryURL = try? SNESFirmwareJournalPolicy.root()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        error = nil; errorDetail = nil
        if !restore { selected = folder.standardizedFileURL; return }
        working = true; progress = "Checking saved restore…"
        Task {
            defer { working = false }
            do {
                let record = try await appState.openSNESStartupRestore(operation: folder.standardizedFileURL)
                prepared = record.restore; ready = false
                switch record.phase {
                case .prepared: step = .prepared
                case .preflightVerified: step = .returnAfterCheck
                case .readbackVerified: step = .returnAfterRestore
                case .menuAccepted: step = .complete
                case .writeIntent, .uncertain: step = .uncertain
                case .stoppedBeforeWrite, .startupVerified: step = .stopped
                }
            } catch {
                self.error = "The saved restore could not be checked. If it stopped while writing, keep power and USB connected and do not restart or retry."
                errorDetail = error.localizedDescription
            }
        }
    }

    private func prepare() {
        guard let selected else { return }
        working = true; progress = "Checking saved files…"; error = nil; errorDetail = nil
        Task {
            defer { working = false }
            do { prepared = try await appState.prepareSNESStartupRestore(operation: selected); step = .prepared }
            catch { showError(error) }
        }
    }

    private func run(_ mode: SNESFirmwareTransaction.Mode) {
        guard let prepared, ready else { return }
        working = true; error = nil; errorDetail = nil; progress = mode == .write ? "Restoring startup…" : "Checking the SNES…"
        Task {
            defer { working = false; ready = false }
            do {
                try await appState.runSNESStartupRestore(prepared, mode: mode, ready: true, approved: mode == .write) { value in
                    await MainActor.run { progress = simpleProgress(value) }
                }
                step = mode == .write ? .returnAfterRestore : .returnAfterCheck
            } catch {
                step = error is SNESFirmwareTransactionError ? .uncertain : .stopped
                showError(error)
            }
        }
    }

    private func simpleProgress(_ stage: RecoveryStage) -> String {
        switch stage {
        case .readingCurrentKernel, .readingBootloader: return "Checking startup files on the SNES…"
        case .checkingPartitions: return "Checking console storage…"
        case .readingBack: return "Checking the restored startup…"
        default: return stage.title
        }
    }

    private func accept() {
        guard let prepared else { return }
        working = true; progress = "Saving your confirmation…"; error = nil; errorDetail = nil
        Task {
            defer { working = false }
            do { try await appState.acceptSNESStartupRestore(prepared, confirmed: true); step = .complete }
            catch { showError(error) }
        }
    }

    private func showError(_ cause: any Error) {
        if cause is SNESFirmwarePublicationUncertainError || cause is SNESFirmwarePreparationCleanupError || cause is SNESFirmwareTransactionError {
            error = cause.localizedDescription
        } else {
            error = "The operation could not be completed. Keep the saved record and check the details before trying again."
            errorDetail = cause.localizedDescription
        }
    }
}
