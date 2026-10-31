import SwiftUI
import AppKit
import SwiftHakchiCore

struct SNESLibraryBackupHistoryView: View {
    let workspace: WorkspacePaths
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SNESLibraryBackupHistory.Entry] = []
    @State private var selection: URL?
    @State private var working = false
    @State private var message: String?
    @State private var removal: SNESLibraryBackupHistory.Preview?
    @State private var confirmRemoval = false
    @State private var restore: SNESLibrarySnapshotReference?
    @State private var showRestore = false
    private var selected: SNESLibraryBackupHistory.Entry? { entries.first { $0.directory == selection } }
    private var currentHWID: String? { app.deviceManager.nativeSNESContext?.installation.expected.hwid }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Backup History — SNES Classic").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.disabled(working) }
            Text("Backups stay on your Mac. Restore Games and Folders keeps the saves and settings currently on your console.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if working { ProgressView("Checking saved files…") }
            if entries.isEmpty && !working {
                ContentUnavailableView("No SNES library backups yet", systemImage: "externaldrive", description: Text("A library backup appears here after you back up or sync your SNES. Original startup recovery files are managed separately by Console Setup."))
            } else {
                List(entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        if let summary = entry.summary {
                            Text(summary.created.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(summary.gameCount) games • " + bytes(summary.byteCount)).font(.callout)
                            if let currentHWID, summary.hwid != currentHWID { Text("From a different console").font(.caption).foregroundStyle(.secondary) }
                        } else { Text("Backup needs attention").font(.headline); Text(entry.issue ?? "Check this folder in Finder.").font(.caption) }
                        Text(entry.directory.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.padding(.vertical, 4).tag(entry.directory)
                }.disabled(working || app.isPreparingSync)
            }
            if let message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            HStack {
                Button("Refresh") { Task { await reload() } }.disabled(working || app.isPreparingSync)
                Button("Open Backups Folder") { NSWorkspace.shared.open(workspace.backups) }
                Spacer()
                Button("Show in Finder") { if let selection { NSWorkspace.shared.activateFileViewerSelecting([selection]) } }.disabled(selection == nil)
            }
            HStack {
                Button("Move to Trash…") { Task { await reviewRemoval() } }.disabled(working || selected?.summary == nil || app.isPreparingSync)
                Spacer()
                Button("Restore Games and Folders…") { Task { await reviewRestore() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || selected?.summary?.hwid != currentHWID || currentHWID == nil || !app.canReviewLibrarySync)
            }
        }
        .padding(22).frame(minWidth: 640, idealWidth: 760, maxWidth: 860, minHeight: 470, idealHeight: 600, maxHeight: 720)
        .task { await reload() }
        .interactiveDismissDisabled(working)
        .confirmationDialog("Move this Mac backup to the Trash?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Move Backup to Trash", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Your console games and other backups stay. You can recover this backup from the Trash. Empty the Trash in Finder to reclaim Mac storage.")
        }
        .sheet(isPresented: $showRestore, onDismiss: { Task { await reload() } }) {
            SNESLibrarySyncView(restoreSnapshot: restore).environmentObject(app)
        }
    }
    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    private func reload() async {
        guard !working else { return }; working = true; defer { working = false }
        do { let roots = workspace.knownBackupRoots; entries = try await Task.detached { try SNESLibraryBackupHistory.scan(roots: roots) }.value }
        catch { message = error.localizedDescription }
    }
    private func reviewRemoval() async {
        guard let selection, !working else { return }; working = true; message = nil; defer { working = false }
        do {
            let paths = workspace
            removal = try await Task.detached { try SNESLibraryBackupHistory.preview(directory: selection, workspace: paths, journals: SNESLibraryJournalPolicy.ensureRoot()) }.value
            confirmRemoval = true
        } catch { message = error.localizedDescription }
    }
    private func remove() async {
        guard let reviewed = removal, !working else { return }; working = true; message = nil
        do {
            let paths = workspace
            _ = try await Task.detached { try SNESLibraryBackupHistory.moveToTrash(preview: reviewed, workspace: paths, journals: SNESLibraryJournalPolicy.ensureRoot()) }.value
            selection = nil; message = "Backup moved to the Trash."
        } catch { message = error.localizedDescription }
        removal = nil; working = false; await reload()
    }
    private func reviewRestore() async {
        guard let selection, !working, app.deviceManager.consoleType == .snesUsa, app.canReviewLibrarySync, let hwid = currentHWID else { return }
        working = true; message = nil; defer { working = false }
        do {
            let paths = workspace
            let reference = try await Task.detached {
                try SNESLibraryBackupHistory.requireLocation(selection, workspace: paths)
                let backup = try SNESLibraryBackup.open(directory: selection)
                guard backup.inventory.hwid == hwid else { throw SNESLibraryBackupHistory.failure("Choose a backup from this console.") }
                return try SNESLibrarySnapshotReference(backup)
            }.value
            guard self.selection == selection, currentHWID == hwid, app.canReviewLibrarySync else { throw SNESLibraryBackupHistory.failure("The console or selection changed. Review the backup again.") }
            restore = reference; app.isPreparingSync = true; showRestore = true
        } catch { message = error.localizedDescription }
    }
}
