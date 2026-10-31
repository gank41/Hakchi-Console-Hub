import SwiftUI
import AppKit
import SwiftHakchiCore

struct LegacyBackupHistoryView: View {
    private struct DeletionReview: Identifiable {
        let id = UUID()
        let preview: LegacyBackupDeletion.Preview
        let permanent: Bool
    }

    let workspace: WorkspacePaths
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LegacyBackupHistory.Entry] = []
    @State private var loading = true
    @State private var selectedRestore: LegacyBackupHistory.Entry?
    @State private var deletionReview: DeletionReview?
    @State private var deletionError: String?
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Backup History").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Console snapshots are kept in your chosen Mac backup folder. Backups in earlier folders stay visible; device-bound snapshots can restore a saved NES menu on their original console.")
                .foregroundStyle(.secondary)
            if loading {
                ProgressView("Checking saved backups…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No console backups yet", systemImage: "externaldrive",
                                       description: Text("A verified backup appears here after you back up or sync a console."))
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.createdAt?.formatted(date: .abbreviated, time: .shortened)
                                 ?? entry.directory.lastPathComponent)
                                .font(.headline)
                            Spacer()
                            Text(statusTitle(entry.status))
                                .font(.caption.bold())
                                .foregroundStyle(statusColor(entry.status))
                        }
                        Text(entry.scope).font(.caption).lineLimit(2)
                        Text("\(entry.sourceRoot.path == workspace.backups.path ? "Current folder" : "Previous folder"): \(entry.sourceRoot.path)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        HStack {
                            if let bytes = entry.byteCount {
                                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary))
                            }
                            if let games = entry.gameCount { Text("\(games) visible games") }
                            if let fingerprint = entry.consoleFingerprint {
                                Text("NES ID \(fingerprint)…")
                            }
                            Spacer()
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.directory])
                            }
                            Button("Review Menu Restore…") { selectedRestore = entry }
                                .disabled(entry.status != .restorable || !appState.deviceManager.isConnected)
                                .help(statusExplanation(entry.status))
                            Button("Move to Trash…") { reviewRemoval(entry, permanent: false) }
                                .disabled(deleting || !canOfferRemoval(entry.status))
                            Button("Delete Permanently…") { reviewRemoval(entry, permanent: true) }
                                .disabled(deleting || !canOfferRemoval(entry.status))
                        }
                        .font(.caption)
                        Text(statusExplanation(entry.status))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let deletionError {
                Text(deletionError).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Text(workspace.backups.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("Open Backups Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspace.backups])
                }
                Button("Refresh") { refresh() }
            }
        }
        .padding()
        .frame(minWidth: 660, minHeight: 410)
        .task { refresh() }
        .sheet(item: $selectedRestore) { entry in
            LegacySavedMenuRestoreView(workspace: workspace,
                snapshotDirectory: entry.directory,
                session: appState.deviceManager.sessionID)
                .environmentObject(appState)
        }
        .sheet(item: $deletionReview) { review in
            VStack(alignment: .leading, spacing: 14) {
                Text(review.permanent ? "Delete Backup Permanently?" : "Move Backup to Trash?")
                    .font(.title2.bold())
                Text(review.preview.directory.path)
                    .font(.caption).textSelection(.enabled)
                Text(ByteCountFormatter.string(fromByteCount: review.preview.byteCount,
                    countStyle: .binary))
                Text(review.permanent
                     ? "This removes the selected Mac backup without a recovery option. A menu stored only in this snapshot could no longer be restored."
                     : "This moves only the selected Mac backup to Finder Trash. You can put it back from Trash.")
                if review.preview.isLastRestorable {
                    Text("This is the only verified menu snapshot currently listed. Removing it reduces your restore choices.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { deletionReview = nil }
                    Button(review.permanent ? "Delete Permanently" : "Move to Trash",
                           role: .destructive) {
                        remove(review)
                    }
                    .disabled(deleting)
                }
            }
            .padding()
            .frame(minWidth: 520)
        }
    }

    private func reviewRemoval(_ entry: LegacyBackupHistory.Entry, permanent: Bool) {
        deletionError = nil
        deleting = true
        Task {
            defer { deleting = false }
            do {
                let preview = try await LegacyBackupDeletion(workspace: workspace)
                    .preview(directory: entry.directory)
                guard preview.isEligible else {
                    throw LegacyBackupDeletion.Failure.dependent(preview.dependencies)
                }
                deletionReview = DeletionReview(preview: preview, permanent: permanent)
            } catch { deletionError = error.localizedDescription }
        }
    }

    private func remove(_ review: DeletionReview) {
        deletionError = nil
        deleting = true
        Task {
            defer { deleting = false }
            do {
                let service = LegacyBackupDeletion(workspace: workspace)
                if review.permanent {
                    try await service.deletePermanently(preview: review.preview)
                } else {
                    _ = try await service.moveToTrash(preview: review.preview)
                }
                deletionReview = nil
                refresh()
            } catch {
                deletionReview = nil
                deletionError = error.localizedDescription
                refresh()
            }
        }
    }

    private func refresh() {
        loading = true
        let roots = workspace.knownBackupRoots
        Task {
            let found = await Task.detached(priority: .utility) {
                LegacyBackupHistory.scan(roots: roots)
            }.value
            entries = found
            loading = false
        }
    }

    private func canOfferRemoval(_ status: LegacyBackupHistory.Status) -> Bool {
        if case .invalid = status { return false }
        return true
    }

    private func statusTitle(_ status: LegacyBackupHistory.Status) -> String {
        switch status {
        case .verifiedInspection: return "Verified inspection"
        case .restorable: return "Verified menu snapshot"
        case .invalid: return "Needs attention"
        }
    }

    private func statusColor(_ status: LegacyBackupHistory.Status) -> Color {
        switch status {
        case .verifiedInspection: return .orange
        case .restorable: return .green
        case .invalid: return .red
        }
    }

    private func statusExplanation(_ status: LegacyBackupHistory.Status) -> String {
        switch status {
        case .verifiedInspection:
            return "Archive hash verified. This older snapshot is not bound to a device or enabled for automatic menu restore."
        case .restorable:
            return "This backup is bound to one NES. The connected console must match before a restore preview or transfer can proceed."
        case .invalid(let reason): return reason
        }
    }
}
