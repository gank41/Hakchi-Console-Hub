import SwiftUI
import SwiftHakchiCore

enum LegacyChangeReviewPolicy {
    static func canApply(confirmed: Bool, busy: Bool, sameSession: Bool, createdAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return confirmed && !busy && sameSession && age >= 0 && age < 300
    }
}

/// The service owns the lease and transaction; the sheet owns presentation and confirmation.
struct LegacyGameChangeView: View {
    let game: Game?
    let workspace: WorkspacePaths
    let session: UUID
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var plan: LegacyChangePlan?
    @State private var record: LegacyChangeRecord?
    @State private var status = "Preparing read-only preview…"
    @State private var error: String?
    @State private var preparing = true
    @State private var applying = false
    @State private var confirmed = false
    private var sameSession: Bool { appState.deviceManager.sessionID == session && appState.deviceManager.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(record == nil ? "Preview Hide Custom Game" : "Legacy Game Change")
                .font(.title2.bold())
            Text("First reversible NES test • Original games and saves stay in place")
                .foregroundStyle(.secondary)
            if preparing || applying { ProgressView(status).frame(maxWidth: .infinity, alignment: .leading) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let current = record?.plan ?? plan {
                        Text(current.name).font(.headline)
                        Text("\(current.target.code) • Page \(current.target.page)").font(.system(.body, design: .monospaced))
                        Text(record?.phase == .restored ? "The original game entry has been restored." : "Hide removes this entry from its menu page. It retains the ROM, makes a preservation copy, and restarts the NES menu. This does not free storage or establish a lag improvement.")
                        Text("Preservation space: approximately \(ByteCountFormatter.string(fromByteCount: current.target.bytes, countStyle: .file)) plus safety reserve.")
                        pathRow("Verified games and saves backup", current.backup)
                        pathRow("Original Windows kernel evidence", current.recovery)
                        Text("Kernel recognition is not unique console identity. Firmware restore remains unavailable.").font(.caption).foregroundStyle(.secondary)
                        if let record {
                            pathRow("Local transaction record", LegacyGameChangeService.journalURL(id: record.id, workspace: workspace))
                            if record.phase == .pending {
                                Text("The result is uncertain. Review and restore checks the console marker and the previous process before doing anything. Keep the console connected and retain all backups.")
                            }
                        } else {
                            Text("Preview expires after five minutes or a reconnect. Cancel changes no console files.").font(.caption)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if !sameSession { Text("Connection changed. Close and reconnect before preparing another preview or reviewing recovery.").foregroundStyle(.red) }
                }
            }
            if !preparing, record?.phase != .restored, plan != nil || record != nil {
                Toggle(record?.phase == .pending
                       ? "I can see this NES over HDMI, it is powered on, and no game or demo is running. An interrupted menu may be blank."
                       : "I can see the NES game-selection menu over HDMI, with no game or automatic demo running.", isOn: $confirmed)
                    .disabled(applying || !sameSession)
            }
            HStack {
                Button(record == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(applying)
                Spacer()
                if let record, record.phase != .restored {
                    Button(record.phase == .pending ? "Review and Restore" : "Undo Hide") { Task { await undo(record) } }
                        .disabled(!confirmed || applying || preparing || !sameSession)
                } else if let plan, record == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Button("Hide This Game") { Task { await apply(plan) } }
                            .disabled(!LegacyChangeReviewPolicy.canApply(confirmed: confirmed, busy: preparing || applying, sameSession: sameSession, createdAt: plan.createdAt, now: context.date))
                    }
                }
            }
        }
        .padding(24).frame(width: 640, height: 600)
        .interactiveDismissDisabled(applying)
        .task { await prepare() }
        .onDisappear {
            appState.isPreparingSync = false
            Task { await appState.legacyChanges.cancel() }
        }
    }
    private func pathRow(_ title: String, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(url.path).font(.caption).textSelection(.enabled)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
        }
    }
    @MainActor private func prepare() async {
        defer { preparing = false }
        do {
            guard sameSession, let client = appState.deviceManager.legacyClient, let report = appState.deviceManager.legacyReport else { throw LegacyInspectionError.disconnected }
            if let previous = try LegacyGameChangeService.latest(workspace: workspace) { record = previous; return }
            guard let game else { status = "No pending or applied legacy change."; error = status; return }
            plan = try await appState.legacyChanges.prepare(game: game, client: client, report: report, workspace: workspace)
        } catch is CancellationError {
            await appState.legacyChanges.cancel()
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func apply(_ plan: LegacyChangePlan) async {
        guard !applying, sameSession else { return }
        applying = true; status = "Preserving the game and changing its menu entry…"; error = nil
        defer { applying = false; confirmed = false }
        do {
            record = try await appState.legacyChanges.apply(id: plan.id, mainMenuConfirmed: confirmed, workspace: workspace)
            await appState.refreshLegacyLibraryAfterChange()
        } catch {
            self.error = error.localizedDescription
            self.plan = nil
            record = try? LegacyGameChangeService.latest(workspace: workspace)
        }
    }
    @MainActor private func undo(_ previous: LegacyChangeRecord) async {
        guard !applying, sameSession, let client = appState.deviceManager.legacyClient else { return }
        applying = true; status = "Checking the transaction and restoring the menu entry…"; error = nil
        defer { applying = false; confirmed = false }
        do {
            record = try await appState.legacyChanges.undo(record: previous, client: client, mainMenuConfirmed: confirmed, workspace: workspace)
            await appState.refreshLegacyLibraryAfterChange()
        } catch { self.error = error.localizedDescription }
    }
}
