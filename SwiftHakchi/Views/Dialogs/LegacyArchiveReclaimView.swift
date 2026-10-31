import SwiftUI
import AppKit
import SwiftHakchiCore

struct LegacyArchiveReclaimView: View {
    let workspace: WorkspacePaths
    let session: UUID

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: LegacySyncJournal?
    @State private var preview: LegacyArchiveReclaim.Preview?
    @State private var formerMenuPreview: LegacyOldMenuReclaim.Preview?
    @State private var formerMenuJournal: LegacyOldMenuReclaimJournal?
    @State private var journal: LegacyArchiveReclaimJournal?
    @State private var oldMenuBound = false
    @State private var testedBothMenus = false
    @State private var working = false
    @State private var showRemovalConfirmation = false
    @State private var showFormerMenuConfirmation = false
    @State private var status = "Checking the latest accepted NES menu…"
    @State private var error: String?
    @State private var storage: LegacyStorageReport?
    @State private var historical: LegacyHistoricalCleanup.Record?
    @State private var showHistoricalConfirmation = false
    @State private var currentFormerMenuRemoved = false

    private var sameSession: Bool {
        appState.deviceManager.isConnected && appState.deviceManager.sessionID == session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Reclaim Console Space").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.disabled(working)
            }
            Text("Backups belong on your Mac. Finishing a tested sync removes its temporary console copies automatically. Use this window to clear files left by earlier transfers; installed games and built-in originals stay on the console.")
                .foregroundStyle(.secondary)
            if let storage {
                GroupBox("Console storage") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Free now", value: ByteCountFormatter.string(fromByteCount: storage.freeBytes, countStyle: .binary))
                        LabeledContent("Installed games", value: ByteCountFormatter.string(fromByteCount: storage.activeGameBytes, countStyle: .binary))
                        LabeledContent("Old menus and transfers", value: ByteCountFormatter.string(fromByteCount: storage.temporaryBytes, countStyle: .binary))
                        DisclosureGroup("Storage details") {
                            ForEach(storage.entries) { entry in
                                LabeledContent(entry.label, value: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .binary))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let historical, historical.phase != .completed {
                GroupBox("Old files saved on this Mac") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ByteCountFormatter.string(fromByteCount: historical.bytesToReclaim, countStyle: .binary)
                             + " in \(historical.items.count) older menu and transfer folders")
                            .font(.headline)
                        Text("The complete Mac backup is verified. Only these old folders will be removed; the installed games, built-in originals, and saves stay on the NES.")
                        Button("Show Verified Mac Backup") { NSWorkspace.shared.activateFileViewerSelecting([historical.backupDirectory]) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let candidate {
                GroupBox("Accepted library") {
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Accepted", value: candidate.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Transfer archive", value: journal?.phase == .completed
                            ? "Removed from console"
                            : ByteCountFormatter.string(fromByteCount: candidate.archiveBytes, countStyle: .binary))
                        LabeledContent("Operation", value: candidate.operationID.uuidString)
                            .font(.caption.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if candidate.resolvedScope == .savedMenu {
                    Text(currentFormerMenuRemoved
                         ? "The former on-console menu has been removed. The active games remain on the NES, and both restore snapshots remain on the Mac."
                         : "This accepted menu came from a Mac snapshot. Reclaiming its transfer archive leaves both the active and previous menus on the NES. The former menu needs a separate review before removal.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(currentFormerMenuRemoved
                         ? "The previous menu was removed from the NES. Use Backup History on this Mac to restore a saved library."
                         : oldMenuBound
                         ? "The previous menu has a verified Mac backup. Review All Old Files checks that backup against the console before offering to remove the old copy."
                         : "Verify Former Menu Backup compares the previous NES menu with its Mac archive. It changes only the Mac backup. Review All Old Files checks files before offering to remove them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let preview {
                GroupBox("Reviewed cleanup") {
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Free now", value:
                            ByteCountFormatter.string(fromByteCount: preview.freeBytes, countStyle: .binary))
                        LabeledContent("Archive to remove", value:
                            ByteCountFormatter.string(fromByteCount: preview.archiveBytes, countStyle: .binary))
                        Text("The former game menu stays on the NES for fast rollback. The matching transfer archive and console backup stay on the Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let formerMenuPreview {
                GroupBox("Former menu — read-only review") {
                    VStack(alignment: .leading, spacing: 5) {
                        LabeledContent("Former games", value: "\(formerMenuPreview.previousGameCount)")
                        LabeledContent("Current games", value: "\(formerMenuPreview.currentGameCount)")
                        LabeledContent("Console space occupied", value: ByteCountFormatter.string(
                            fromByteCount: formerMenuPreview.previousAllocatedBytes, countStyle: .binary))
                        LabeledContent("File contents", value: ByteCountFormatter.string(
                            fromByteCount: formerMenuPreview.previousLogicalBytes, countStyle: .binary))
                        LabeledContent("Free now", value: ByteCountFormatter.string(
                            fromByteCount: formerMenuPreview.freeBytes, countStyle: .binary))
                        LabeledContent("Matching Mac backup", value:
                            formerMenuPreview.previousSnapshotDirectory.lastPathComponent)
                        Text("Both NES menus match their Mac snapshots file by file. Console space occupied is measured on this NES; actual free-space gain may differ. Reclaiming this copy ends instant on-console rollback, but its Mac backup remains available in Backup History.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if working { ProgressView(status) }
            else { Text(status).font(.callout) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            if candidate?.resolvedScope == .savedMenu, journal?.phase == .completed,
               formerMenuJournal?.phase != .completed,
               formerMenuJournal?.phase != .uncertain,
               formerMenuJournal?.phase != .removalIntent {
                Toggle("I tested both restored menus, their artwork, an imported game, a built-in game, and controller input", isOn: $testedBothMenus)
                    .toggleStyle(.checkbox)
            }
            HStack {
                if historical?.phase == .uncertain || historical?.phase == .removalIntent {
                    Button("Check Interrupted Old-File Cleanup") { Task { await reconcileHistorical() } }
                        .disabled(working || !sameSession)
                } else {
                    Button("Review All Old Files") { Task { await prepareHistorical() } }
                        .disabled(working || !sameSession || (storage?.temporaryBytes ?? 0) == 0)
                    if historical?.phase == .prepared {
                        Button("Remove Reviewed Old Files…") { showHistoricalConfirmation = true }
                            .disabled(working || !sameSession)
                    }
                }
            }
            HStack {
                if candidate?.resolvedScope == .full, !currentFormerMenuRemoved {
                    Button(oldMenuBound ? "Recheck Former Menu Backup" : "Verify Former Menu Backup") {
                        Task { await bindOldMenu() }
                    }
                        .disabled(working || !sameSession)
                }
                if journal?.phase == .uncertain || journal?.phase == .removalIntent {
                    Button("Check Interrupted Cleanup") { Task { await reconcile() } }
                        .disabled(working || !sameSession)
                } else if journal?.phase != .completed {
                    Button("Check Archive") { Task { await prepare() } }
                        .disabled(working || !sameSession || candidate == nil)
                    Button("Reclaim Archive…") { showRemovalConfirmation = true }
                        .disabled(working || !sameSession || preview == nil)
                }
                if formerMenuJournal?.phase == .uncertain || formerMenuJournal?.phase == .removalIntent {
                    Button("Check Interrupted Former-Menu Cleanup") {
                        Task { await reconcileFormerMenu() }
                    }.disabled(working || !sameSession)
                } else if candidate?.resolvedScope == .savedMenu, journal?.phase == .completed,
                          !currentFormerMenuRemoved {
                    Button("Review Former Menu") { Task { await reviewFormerMenu() } }
                        .disabled(working || !sameSession || !testedBothMenus)
                    Button("Reclaim Former Menu…") { showFormerMenuConfirmation = true }
                        .disabled(working || !sameSession || formerMenuPreview == nil
                                  || formerMenuJournal?.phase != .prepared)
                }
                Spacer()
                Button("Open Mac Backups") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspace.backups])
                }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 380)
        .confirmationDialog("Remove this redundant transfer archive from the NES?",
                            isPresented: $showRemovalConfirmation) {
            Button("Reclaim Archive", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The active games and previous menu remain on the NES. The Mac keeps the verified backup and matching archive. The console must be at its first game page with no game running.")
        }
        .confirmationDialog("Permanently remove the former game menu from the NES?",
                            isPresented: $showFormerMenuConfirmation) {
            Button("Remove Former NES Menu", role: .destructive) {
                Task { await removeFormerMenu() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the reviewed \(formerMenuPreview?.previousGameCount ?? 0)-game former menu is removed. The active \(formerMenuPreview?.currentGameCount ?? 0)-game menu stays. Instant on-console rollback ends; the verified Mac backup remains available for a later staged restore. Keep the NES at its first game page with no game running.")
        }
        .confirmationDialog("Remove the reviewed old files from the NES?", isPresented: $showHistoricalConfirmation) {
            Button("Remove Old Console Files", role: .destructive) { Task { await removeHistorical() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \(ByteCountFormatter.string(fromByteCount: historical?.bytesToReclaim ?? 0, countStyle: .binary)) of verified older menus and transfer files. Their complete backup stays on this Mac. Keep the NES on its first game page with no game running.")
        }
        .task { await loadState() }
        .onDisappear { appState.isPreparingSync = false }
    }

    @MainActor private func reviewFormerMenu() async {
        guard !working, sameSession, let candidate,
              let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil
        status = "Comparing both NES menus with their Mac backups, file by file…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                let result = try await LegacyOldMenuReclaimTransaction(workspace: workspace).prepare(
                    operationID: candidate.operationID,
                    confirmedTestedMenus: testedBothMenus,
                    device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                formerMenuPreview = result
                formerMenuJournal = try await LegacyOldMenuReclaimJournalStore(
                    directory: workspace.journals).load(candidate.operationID)
                status = "Former menu verified. Review the games and matching Mac backup before reclaiming."
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "Former-menu review stopped. No NES files were removed."
        }
    }

    @MainActor private func removeFormerMenu() async {
        guard !working, sameSession, let formerMenuPreview,
              let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil
        status = "Rechecking both menus, then removing only the reviewed former copy…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                try await LegacyOldMenuReclaimTransaction(workspace: workspace)
                    .remove(preview: formerMenuPreview, device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                formerMenuJournal = try await LegacyOldMenuReclaimJournalStore(
                    directory: workspace.journals).load(formerMenuPreview.operationID)
                self.formerMenuPreview = nil
                status = "Former menu removed; the active games were verified. The Mac backup remains."
                try? await appState.deviceManager.refreshLegacyReport()
            } catch { await lease.release(); throw error }
        } catch {
            formerMenuJournal = try? await LegacyOldMenuReclaimJournalStore(
                directory: workspace.journals).load(formerMenuPreview.operationID)
            self.error = error.localizedDescription
            status = formerMenuJournal?.phase == .uncertain
                ? "Result uncertain. Check Interrupted Former-Menu Cleanup before another action."
                : "Former-menu cleanup stopped before deletion. Review its state."
        }
    }

    @MainActor private func reconcileFormerMenu() async {
        guard !working, sameSession, let candidate,
              let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil
        status = "Checking the former directory and active menu without retrying deletion…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                try await LegacyOldMenuReclaimTransaction(workspace: workspace)
                    .reconcile(operationID: candidate.operationID,
                               device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                formerMenuJournal = try await LegacyOldMenuReclaimJournalStore(
                    directory: workspace.journals).load(candidate.operationID)
                formerMenuPreview = nil
                status = formerMenuJournal?.phase == .completed
                    ? "The former menu is absent and active games match their Mac snapshot."
                    : "The former menu is intact. Review it again before reclaiming."
                try? await appState.deviceManager.refreshLegacyReport()
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "The former-menu state could not be confirmed. Deletion was not retried."
        }
    }

    @MainActor private func loadState() async {
        do {
            historical = try LegacyHistoricalCleanup.load(workspace: workspace)
            if let client = appState.deviceManager.legacyClient {
                let result = try await client.execute(.storageReport, timeoutMilliseconds: 30_000)
                guard result.succeeded else { throw LegacyInspectionError.invalidResponse }
                storage = try LegacyStorageReport.parse(result.stdoutData)
            }
            let store = LegacySyncJournalStore(directory: workspace.journals)
            candidate = try await store.latestAcceptedMenu()
            if let candidate {
                oldMenuBound = candidate.resolvedScope == .full &&
                    (try? LegacyMenuSnapshot.verify(directory: candidate.backupDirectory)) != nil
                journal = try? await LegacyArchiveReclaimJournalStore(directory: workspace.journals)
                    .load(candidate.operationID)
                formerMenuJournal = try? await LegacyOldMenuReclaimJournalStore(
                    directory: workspace.journals).load(candidate.operationID)
                let removalProof = try LegacyHistoricalCleanup.formerMenuProof(operationID: candidate.operationID, workspace: workspace)
                currentFormerMenuRemoved = formerMenuJournal?.phase == .completed || removalProof != nil
                if currentFormerMenuRemoved {
                    status = "Former-menu cleanup is complete. The active games and Mac backups remain."
                } else if formerMenuJournal?.phase == .uncertain
                    || formerMenuJournal?.phase == .removalIntent {
                    status = "Former-menu cleanup may have been interrupted. Check its state before another change."
                } else {
                    switch journal?.phase {
                    case .completed: status = "Archive cleanup was recorded as complete. The former menu remains on the NES."
                    case .uncertain, .removalIntent: status = "The previous cleanup may have been interrupted. Check its recorded state before any other action."
                    default: status = "Check the archive to see a fresh, exact cleanup preview."
                    }
                }
            } else {
                status = "No accepted NES menu is available for archive cleanup."
            }
        } catch {
            self.error = error.localizedDescription
            status = "A saved sync record needs review before cleanup."
        }
    }

    @MainActor private func prepareHistorical() async {
        guard !working, sameSession, let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil; status = "Saving old console files on this Mac…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                historical = try await LegacyHistoricalCleanupService(workspace: workspace).prepare(lease: lease) { message in
                    Task { @MainActor in status = message }
                }
                await lease.release()
                status = "Mac backup and old files verified. Review the amount before removing them."
            } catch { await lease.release(); throw error }
        } catch { self.error = error.localizedDescription; status = "Review stopped. No console files were removed." }
    }

    @MainActor private func removeHistorical() async {
        guard !working, sameSession, let historical, let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil; status = "Removing only the reviewed old files…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                try await LegacyHistoricalCleanupService(workspace: workspace).remove(historical, lease: lease) { message in
                    Task { @MainActor in status = message }
                }
                await lease.release()
            } catch { await lease.release(); throw error }
            await loadState()
            status = "Old files removed. Your installed games and Mac backups are ready."
            try? await appState.deviceManager.refreshLegacyReport()
        } catch {
            self.historical = try? LegacyHistoricalCleanup.load(workspace: workspace)
            self.error = error.localizedDescription
            status = "Cleanup needs a connection check. No deletion will be retried automatically."
        }
    }

    @MainActor private func reconcileHistorical() async {
        guard !working, sameSession, let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil; defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                historical = try await LegacyHistoricalCleanupService(workspace: workspace).reconcile(lease: lease)
                await lease.release()
            } catch { await lease.release(); throw error }
            status = historical?.phase == .completed ? "Old-file cleanup is complete." : "Remaining old files match their Mac backup. Review removal before continuing."
        } catch { self.error = error.localizedDescription; status = "The interrupted cleanup still needs review." }
    }

    @MainActor private func bindOldMenu() async {
        guard !working, sameSession, let candidate,
              let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil
        status = "Comparing the former NES menu with its Mac backup, file by file…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                let binder = LegacyOldMenuBinding(workspace: workspace)
                let proof = try await binder.preview(operationID: candidate.operationID,
                                                     device: LegacySyncLeaseDevice(lease: lease))
                _ = try await binder.bind(preview: proof,
                                          device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                oldMenuBound = true
                status = "Former menu matches this NES and now has a verified Mac restore index. No NES files changed."
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "Former-menu proof stopped. The NES and its Mac backup remain unchanged."
        }
    }

    @MainActor private func prepare() async {
        guard !working, sameSession, let candidate, let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil; status = "Verifying the Mac archive and NES menu…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                let result = try await LegacyArchiveReclaimTransaction(workspace: workspace)
                    .prepare(operationID: candidate.operationID, device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                preview = result
                journal = try await LegacyArchiveReclaimJournalStore(directory: workspace.journals)
                    .load(candidate.operationID)
                status = "Archive verified. Review its size, then choose Reclaim Archive if you want to remove it."
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "Cleanup preview stopped. No archive was removed."
        }
    }

    @MainActor private func remove() async {
        guard !working, sameSession, let preview,
              let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil; status = "Removing only the reviewed transfer archive…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                try await LegacyArchiveReclaimTransaction(workspace: workspace)
                    .remove(preview: preview, device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                journal = try await LegacyArchiveReclaimJournalStore(directory: workspace.journals)
                    .load(preview.operationID)
                self.preview = nil
                status = "Transfer archive removed. The current games, previous menu and Mac backups remain."
                try? await appState.deviceManager.refreshLegacyReport()
            } catch { await lease.release(); throw error }
        } catch {
            journal = try? await LegacyArchiveReclaimJournalStore(directory: workspace.journals)
                .load(preview.operationID)
            self.error = error.localizedDescription
            status = "Result uncertain. Check Interrupted Cleanup before another action."
        }
    }

    @MainActor private func reconcile() async {
        guard !working, sameSession, let candidate,
              let client = appState.deviceManager.legacyClient else { return }
        working = true; error = nil; status = "Reading the NES archive and menu state…"
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                try await LegacyArchiveReclaimTransaction(workspace: workspace)
                    .reconcile(operationID: candidate.operationID, device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                journal = try await LegacyArchiveReclaimJournalStore(directory: workspace.journals)
                    .load(candidate.operationID)
                preview = nil
                status = journal?.phase == .completed
                    ? "The archive is absent and the accepted menu is intact. Cleanup is complete."
                    : "The archive is still present. Check it again for a new preview before reclaiming."
                try? await appState.deviceManager.refreshLegacyReport()
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "Could not confirm the console state. No deletion was retried."
        }
    }
}
