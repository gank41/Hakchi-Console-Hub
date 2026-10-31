import SwiftUI
import SwiftHakchiCore

struct LegacySavedMenuRestoreView: View {
    let workspace: WorkspacePaths
    let snapshotDirectory: URL
    let session: UUID

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var preview: LegacySavedMenuRestore.Preview?
    @State private var journal: LegacySyncJournal?
    @State private var recovery: LegacySyncInspection?
    @State private var working = false
    @State private var status = "Choose Review Saved Menu to check this Mac backup and the connected NES."
    @State private var error: String?
    @State private var showTransfer = false
    @State private var showSwitch = false
    @State private var showAccept = false
    @State private var showRollback = false

    private var sameSession: Bool {
        appState.deviceManager.isConnected && appState.deviceManager.sessionID == session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Restore Saved NES Menu").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.disabled(working)
            }
            Text("This restores only a saved game menu. Firmware and save states are untouched. The menu currently on the NES is retained for rollback until you test and accept the restored one.")
                .foregroundStyle(.secondary)
            GroupBox("Selected Mac backup") {
                Text(snapshotDirectory.lastPathComponent).font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let preview {
                GroupBox("Restore preview") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Games in saved menu", value: "\(preview.selectedCodes.count)")
                        LabeledContent("Console free space", value: ByteCountFormatter.string(
                            fromByteCount: preview.freeBytes, countStyle: .binary))
                        LabeledContent("Space needed to stage safely", value: ByteCountFormatter.string(
                            fromByteCount: preview.requiredBytes, countStyle: .binary))
                        LabeledContent("Source archive", value: preview.snapshotDirectory.lastPathComponent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let journal {
                Text("Operation \(journal.operationID.uuidString) · \(journal.phase.rawValue)")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            if working { ProgressView(status) }
            else { Text(status).font(.callout) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                if journal == nil {
                    Button("Review Saved Menu") { Task { await prepare() } }
                        .disabled(working || !sameSession)
                    Button("Transfer Inactive Copy…") { showTransfer = true }
                        .disabled(working || !sameSession || preview == nil)
                } else if let journal {
                    switch journal.phase {
                    case .prepared, .uploaded:
                        Button("Check Transfer") { Task { await checkRecovery() } }
                            .disabled(working || !sameSession)
                        if journal.phase == .uploaded {
                            Button("Confirm Verified Transfer") { Task { await reconcileUploaded() } }
                                .disabled(working || !sameSession)
                        }
                        Button("Discard Inactive Copy") { Task { await discard() } }
                            .disabled(working || !sameSession || recovery?.outcome != .beforeRename)
                    case .verified:
                        Button("Switch NES Menu…") { showSwitch = true }
                            .disabled(working || !sameSession)
                        Button("Discard Inactive Copy") { Task { await discard() } }
                            .disabled(working || !sameSession)
                    case .activationIntent, .uncertain:
                        Button("Check Recovery") { Task { await checkRecovery() } }
                            .disabled(working || !sameSession)
                        if recovery?.phase == .accepted && recovery?.outcome == .newTreePresent {
                            Button("Confirm Accepted Menu") { Task { await reconcileAccepted() } }
                                .disabled(working || !sameSession)
                        } else if recovery?.outcome == .newTreePresent {
                            Button("Continue to Testing") { Task { await resumeAcceptance() } }
                                .disabled(working || !sameSession)
                            Button("Restore Previous Menu…") { showRollback = true }
                                .disabled(working || !sameSession)
                        }
                        if recovery?.outcome == .beforeRename {
                            Button("Restore Previous Menu…") { showRollback = true }
                                .disabled(working || !sameSession)
                        }
                    case .activePendingAcceptance:
                        Button("Accept Working Menu…") { showAccept = true }
                            .disabled(working || !sameSession)
                        Button("Restore Previous Menu…") { showRollback = true }
                            .disabled(working || !sameSession)
                    case .accepted, .discarded, .rolledBack: EmptyView()
                    }
                }
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 650, minHeight: 420)
        .confirmationDialog("Transfer this menu to an inactive folder on the NES?",
                            isPresented: $showTransfer) {
            Button("Transfer Inactive Copy") { Task { await transfer() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The menu shown on your TV will not change yet. Keep the NES connected during the transfer.")
        }
        .confirmationDialog("Switch to this saved menu?", isPresented: $showSwitch) {
            Button("Switch NES Menu") { Task { await activate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Return to the first NES game page with no game or demo running, then watch the TV. Your current menu is retained for rollback.")
        }
        .confirmationDialog("Have you tested the restored menu and games?", isPresented: $showAccept) {
            Button("Accept Working Menu") { Task { await accept() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Check the pages and artwork, launch an imported game and a built-in game, confirm controller input, then return to the first game page before accepting.")
        }
        .confirmationDialog("Return to the previous menu?", isPresented: $showRollback) {
            Button("Restore Previous Menu") { Task { await rollback() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved menu trial will end and the menu kept on the NES will be restored.")
        }
        .task { await loadState() }
    }

    @MainActor private func loadState() async {
        do {
            journal = try await LegacySyncJournalStore(directory: workspace.journals).latestUnresolved()
            if let journal {
                guard journal.resolvedScope == .savedMenu else {
                    throw LegacySyncJournalError.unresolvedOperation
                }
                status = "An interrupted saved-menu operation needs review before starting another."
            }
        } catch {
            self.error = error.localizedDescription
            status = "A saved operation needs review before restoring a menu."
        }
    }

    @MainActor private func withDevice(_ operation: @escaping (LegacySavedMenuRestoreDevice) async throws -> Void) async {
        guard !working, sameSession, let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                try await operation(LegacySyncLeaseDevice(lease: lease))
                await lease.release()
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "The operation stopped. Review its saved state before trying another action."
            journal = try? await LegacySyncJournalStore(directory: workspace.journals).latestUnresolved()
        }
    }

    @MainActor private func refreshJournal(_ id: UUID) async {
        journal = try? await LegacySyncJournalStore(directory: workspace.journals).load(id)
    }

    @MainActor private func prepare() async {
        status = "Checking the backup, device identity, live menu and free space…"
        await withDevice { device in
            let result = try await LegacySavedMenuRestore(workspace: workspace)
                .prepare(snapshotDirectory: snapshotDirectory, device: device)
            await MainActor.run {
                preview = result
                status = "Review the game count and space estimate, then transfer an inactive copy."
            }
        }
    }

    @MainActor private func transfer() async {
        guard let preview else { return }
        status = "Transferring and checking the inactive saved menu…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace).transfer(preview, device: device)
            await refreshJournal(preview.operationID)
            status = "Inactive menu verified. Return to the first game page before switching."
        }
    }

    @MainActor private func activate() async {
        guard let id = journal?.operationID else { return }
        status = "Switching menus and checking the NES response…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace).activate(operationID: id, device: device)
            await refreshJournal(id)
            status = "Saved menu is active. Test its pages, artwork and games before accepting."
        }
        await refreshVisibleMenu(if: .activePendingAcceptance)
    }

    @MainActor private func accept() async {
        guard let id = journal?.operationID else { return }
        status = "Accepting the tested menu…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace).accept(
                operationID: id, mainMenuConfirmed: true, device: device)
            await refreshJournal(id)
            status = "Saved menu accepted. The previous menu remains on the NES for rollback."
        }
        await refreshVisibleMenu(if: .accepted)
    }

    @MainActor private func checkRecovery() async {
        guard let id = journal?.operationID else { return }
        status = "Reading the interrupted operation without retrying a menu switch…"
        await withDevice { device in
            let state = try await LegacySavedMenuRestore(workspace: workspace)
                .inspectRecovery(operationID: id, device: device)
            recovery = state
            switch state.outcome {
            case .newTreePresent:
                status = "The saved menu is active. Check its games before accepting or restoring the previous menu."
            case .beforeRename:
                status = "The original menu is still active. You may discard the inactive copy."
            case .firstRenameUncertain, .inconsistent:
                status = "The menu state needs manual recovery review. Keep the NES and Mac backup connected."
            }
        }
    }

    @MainActor private func reconcileUploaded() async {
        guard let id = journal?.operationID else { return }
        status = "Checking every inactive menu file after the interrupted transfer…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace)
                .reconcileUploaded(operationID: id, device: device)
            await refreshJournal(id)
            status = "Inactive menu verified. Return to the first game page before switching."
        }
    }

    @MainActor private func resumeAcceptance() async {
        guard let id = journal?.operationID else { return }
        status = "Checking that the saved menu is active…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace)
                .resumeAcceptance(operationID: id, mainMenuConfirmed: true, device: device)
            await refreshJournal(id)
            status = "Test the saved menu and games, then accept them from the first page."
        }
    }

    @MainActor private func reconcileAccepted() async {
        guard let id = journal?.operationID else { return }
        status = "Checking the already accepted NES menu…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace)
                .reconcileAccepted(operationID: id, mainMenuConfirmed: true, device: device)
            await refreshJournal(id)
            status = "The accepted saved menu is confirmed. The previous menu remains on the NES."
        }
        await refreshVisibleMenu(if: .accepted)
    }

    @MainActor private func discard() async {
        guard let id = journal?.operationID else { return }
        status = "Removing only the inactive transfer…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace)
                .discardInactive(operationID: id, device: device)
            await refreshJournal(id)
            status = "Inactive transfer discarded. The active NES menu is unchanged."
        }
    }

    @MainActor private func rollback() async {
        guard let id = journal?.operationID else { return }
        status = "Restoring the previous menu…"
        await withDevice { device in
            try await LegacySavedMenuRestore(workspace: workspace)
                .rollback(operationID: id, device: device)
            await refreshJournal(id)
            status = "Previous menu restored. Check the NES screen and a game."
        }
        await refreshVisibleMenu(if: .rolledBack)
    }

    @MainActor private func refreshVisibleMenu(if expectedPhase: LegacySyncJournal.Phase) async {
        guard journal?.phase == expectedPhase else { return }
        do {
            try await appState.deviceManager.refreshLegacyReport()
        } catch {
            self.error = "The menu changed, but its game count and free-space display could not refresh. Reconnect the NES to update them. \(error.localizedDescription)"
        }
    }
}
