import SwiftUI
import AppKit

/// Offline prerequisites only. There is deliberately no console action in this sheet.
struct RecoveryReadinessView: View {
    let backups: URL
    let context: ConsoleRecoveryContext
    let legacySnapshot: LegacyConsoleReport?
    var onOriginalGamesReview: (() -> Void)? = nil
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var service = RecoveryPreflightService()
    private struct CheckedReport {
        let context: ConsoleRecoveryContext
        let report: RecoveryReadinessReport
    }
    private struct CheckKey: Hashable { let context: ConsoleRecoveryContext; let refresh: UUID }
    @State private var checked: CheckedReport?
    @State private var checkID = UUID()
    @State private var showSNESBackupHistory = false
    @State private var showSNESOriginalStartup = false
    @State private var ownsSNESStartupRestore = false
    @State private var checkingFullDataBackup = false
    @State private var fullDataBackupMessage: String?
    @State private var fullDataBackupPassed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore Console").font(.title2.bold())
            Text(context.targetDescription).font(.headline)
            Text("Choose the kind of recovery you need. The check below reads backups on this Mac; it does not change the console.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if context.console == .snesUsa {
                        Text("A factory reset is not available yet. You can show the included games or review the original startup below. Neither option erases your saves and settings. The app cannot yet restore a complete console-data snapshot.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("If you skipped the backup at the end of your last sync, open Sync Library and choose Continue Sync before restoring startup or transferring saves. This lets the app safely remove the previous game-menu copy.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        GroupBox("Check a Full Console Backup") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Choose a full-data backup to check its files on this Mac. This does not connect to or change the console.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Choose Backup to Check…") { checkFullDataBackup() }
                                    .disabled(checkingFullDataBackup)
                                if checkingFullDataBackup {
                                    ProgressView("Checking backup files… This may take a few minutes.")
                                }
                                if let fullDataBackupMessage {
                                    Label(fullDataBackupMessage, systemImage: fullDataBackupPassed ? "checkmark.circle" : "exclamationmark.triangle")
                                        .foregroundStyle(fullDataBackupPassed ? Color.green : Color.orange)
                                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                        GroupBox("Restore Games and Folders") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Choose a saved SNES library backup to review the games and folders it contains. Your current console saves and settings are kept.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Open SNES Backup History…") { showSNESBackupHistory = true }
                                    .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
                                Text("You can also review a backup for a replacement SNES. Copying saved progress is experimental and has not yet been tested on a replacement console.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                    }
                    GroupBox("Recovery choices") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(context.choices, id: \.rawValue) { choice in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.title).fontWeight(.medium)
                                    Text(choice.explanation).font(.callout).foregroundStyle(.secondary)
                                    if choice == .returnToBuiltInGames, let onOriginalGamesReview {
                                        Button("Review Original Games…") { onOriginalGamesReview(); dismiss() }
                                            .padding(.top, 4)
                                    } else if choice == .restoreOriginalStartup && context.console == .snesUsa {
                                        Button("Review Original SNES Startup…") {
                                            guard !appState.taskRunner.isRunning, !appState.isPreparingSync, !appState.gameManager.isLoading else { return }
                                            appState.isPreparingSync = true
                                            ownsSNESStartupRestore = true
                                            showSNESOriginalStartup = true
                                        }
                                            .padding(.top, 4)
                                            .disabled(appState.taskRunner.isRunning || appState.isPreparingSync || appState.gameManager.isLoading)
                                    } else {
                                        Text("Not available in this screen yet").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if choice != context.choices.last { Divider() }
                            }
                        }.padding(4)
                    }
                    Text("Your Mac library and backups stay on the computer. Added games can be removed without erasing saves or restoring startup software.")
                        .font(.callout).foregroundStyle(.secondary)
                    if context.console == .nes, let legacySnapshot {
                        GroupBox("Last NES connection") {
                            Text("Kernel \(legacySnapshot.kernelVersion). This saved connection report is not refreshed by the local backup check.")
                                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let checked, checked.context == context {
                        let report = checked.report
                        evidence("Original startup backup", check: report.kernel)
                        evidence(context.console == .snesUsa ? "Factory reset tools" : "Recovery tools", check: report.payload)
                        if !report.warnings.isEmpty {
                            DisclosureGroup("Other recovery material warnings (\(report.warnings.count))") {
                                ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                                    Text(warning).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else {
                        ProgressView("Checking local recovery material…").frame(maxWidth: .infinity).padding(20)
                    }
                }.padding(.trailing, 6)
            }
            HStack {
                Button("Recheck Backups") { checked = nil; checkID = UUID() }.disabled(checked?.context != context)
                Button("Open Backups Folder") { NSWorkspace.shared.open(backups) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(minWidth: 570, idealWidth: 680, maxWidth: 800, minHeight: 480, idealHeight: 680, maxHeight: 780)
        .sheet(isPresented: $showSNESBackupHistory) {
            SNESLibraryBackupHistoryView(workspace: AppConfig.shared.workspace)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSNESOriginalStartup, onDismiss: {
            if ownsSNESStartupRestore { ownsSNESStartupRestore = false; appState.isPreparingSync = false }
        }) {
            SNESStartupRestorePreparationView().environmentObject(appState)
        }
        .task(id: CheckKey(context: context, refresh: checkID)) {
            checked = nil
            let capturedContext = context
            let report = await service.inspect(backups: backups, console: capturedContext.console)
            guard !Task.isCancelled else { return }
            checked = CheckedReport(context: capturedContext, report: report)
        }
    }

    private func checkFullDataBackup() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Full Console Backup"
        panel.message = "Select the SNES full-data backup folder. The app will only read its files."
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        checkingFullDataBackup = true; fullDataBackupMessage = nil; fullDataBackupPassed = false
        Task {
            defer { checkingFullDataBackup = false }
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    try SNESPortableDataSnapshot.inspect(directory: directory).byteCount
                }.value
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                fullDataBackupPassed = true
                fullDataBackupMessage = "Backup files passed the check (\(size)); their origin has not been verified. Full console-data restore is not available yet. To review games and saved progress for another compatible SNES, use a library backup in SNES Backup History."
            } catch {
                fullDataBackupMessage = "The backup could not be checked. Keep the original and choose another backup or check the folder. No console was changed."
            }
        }
    }

    private func evidence(_ title: String, check: RecoveryCheck) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 7) {
                Label(check.status == .verified ? "Verified on this Mac" : check.status == .missing ? "No backup found" : check.status == .unavailable ? "Support coming later" : "Could not verify",
                      systemImage: check.status == .verified ? "checkmark.circle" : check.status == .unavailable ? "info.circle" : "exclamationmark.triangle")
                    .foregroundStyle(check.status == .verified ? Color.green : check.status == .unavailable ? Color.secondary : Color.orange)
                Text(check.detail).font(.callout).textSelection(.enabled)
                if let path = check.path { Text(path.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}
