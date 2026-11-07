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
    @State private var activity = "Checking…"
    @State private var message: String?
    @State private var comparisonSelection: URL?
    @State private var saveComparison: SNESLibrarySaveComparison?
    @State private var removal: SNESLibraryBackupHistory.Preview?
    @State private var confirmRemoval = false
    @State private var restore: SNESLibrarySnapshotReference?
    @State private var showRestore = false
    @State private var replacement: SNESLibraryReplacement?
    @State private var replacementSaves: SNESReplacementSaveReview?
    @State private var saveOptions: [SNESReplacementSaveReview.GameOption] = []
    @State private var selectedSaveCodes: Set<String> = []
    @State private var savedSaveReview: SNESReplacementSaveReviewStore.Receipt?
    @State private var replacementReference: SNESLibrarySnapshotReference?
    @State private var replacementContextSHA256: String?
    @State private var syncingReplacementReference: SNESLibrarySnapshotReference?
    @State private var pendingSaveTransfer: SNESReplacementSaveJournal.Pending?
    @State private var pendingSaveSummary: SNESReplacementSaveJournal.PublicationSummary?
    @State private var pendingRefreshID = UUID()
    @State private var stagingOptions: [SNESReplacementSaveJournal.StagingOption] = []
    @State private var selectedStagingGroup: Int?
    @State private var stagingContextSHA256: String?
    @State private var publicationPreview: SNESReplacementSavePublicationPreview?
    @State private var helperReady = false
    @State private var stagingApproval: SNESReplacementSaveJournal.StagingOption?
    @State private var stagingApprovalReview: SNESReplacementSaveReviewStore.Receipt?
    @State private var stagingApprovalContext: String?
    @State private var helperApproval: SNESReplacementSavePublicationPreview?
    @State private var publicationApproval: SNESReplacementSavePublicationPreview?
    @State private var helperApprovalOperation: URL?
    @State private var publicationApprovalOperation: URL?
    @State private var finishApprovalOperation: URL?
    @State private var confirmStaging = false
    @State private var confirmHelper = false
    @State private var confirmPublication = false
    @State private var confirmFinish = false
    private var selected: SNESLibraryBackupHistory.Entry? { entries.first { $0.directory == selection } }
    private var currentHWID: String? { app.deviceManager.nativeSNESContext?.installation.expected.hwid }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Backup History — SNES Classic").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.disabled(working) }
            Text("Backups stay on your Mac. Restore Games and Folders keeps the saves and settings currently on your console.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if working { ProgressView(activity) }
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
            if let result = saveComparison, comparisonSelection == selection,
               message?.hasPrefix("Saved-game files:") == true,
               !result.gameDifferences.isEmpty || result.otherDifferences.changed + result.otherDifferences.backupOnly + result.otherDifferences.consoleOnly > 0 {
                DisclosureGroup("See which saved files differ") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(result.gameDifferences.sorted {
                                let order = gameName($0.gameCode).localizedStandardCompare(gameName($1.gameCode))
                                return order == .orderedSame ? $0.gameCode < $1.gameCode : order == .orderedAscending
                            }) { game in
                                VStack(alignment: .leading) {
                                    Text(gameName(game.gameCode)).fontWeight(.medium)
                                    Text(differenceDescription(game.differences)).foregroundStyle(.secondary)
                                }
                            }
                            if result.otherDifferences.changed + result.otherDifferences.backupOnly + result.otherDifferences.consoleOnly > 0 {
                                VStack(alignment: .leading) {
                                    Text("Other saved files").fontWeight(.medium)
                                    Text(differenceDescription(result.otherDifferences)).foregroundStyle(.secondary)
                                }
                            }
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }
            }
            if let pendingSaveTransfer {
                GroupBox("An earlier saved-game transfer needs checking") {
                    VStack(alignment: .leading, spacing: 6) {
                        if pendingSaveTransfer.phase == .prepared {
                            Text("This review was never sent to the console. You can close it and keep both backups.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Close Unstarted Review") { Task { await closeUnstartedSaveTransfer() } }
                                .disabled(working || !app.canReviewLibrarySync)
                        } else if [.writeIntent, .uncertain].contains(pendingSaveTransfer.phase), pendingSaveTransfer.stage != nil {
                            Text("Keep both backups. This check looks for temporary saved files and does not copy, delete, or restore progress.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Check Previous Transfer") { Task { await inspectPendingSaveTransfer() } }
                                .disabled(working || !app.canReviewLibrarySync)
                            if pendingSaveTransfer.phase == .uncertain {
                                Button("Review Saved Files…") { Task { await previewPendingSavePublication() } }
                                    .disabled(working || !app.canReviewLibrarySync)
                                if let preview = publicationPreview {
                                    Text("\(preview.summary.saveDescription) • \(preview.summary.fileCount) files • \(bytes(preview.summary.byteCount))")
                                    if helperReady {
                                        Button("Copy Saved Data…") {
                                            publicationApproval = preview; publicationApprovalOperation = pendingSaveTransfer.operation; confirmPublication = true
                                        }
                                            .disabled(working || !app.canReviewLibrarySync)
                                    } else {
                                        Button("Prepare Temporary Helper…") {
                                            helperApproval = preview; helperApprovalOperation = pendingSaveTransfer.operation; confirmHelper = true
                                        }
                                            .disabled(working || !app.canReviewLibrarySync)
                                    }
                                }
                            }
                        } else if [.publicationIntent, .publicationUncertain].contains(pendingSaveTransfer.phase) {
                            Text("Check whether the reviewed saved files are visible. This does not finish or retry the transfer.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Check Saved Files") { Task { await inspectPendingSavePublication() } }
                                .disabled(working || !app.canReviewLibrarySync)
                        } else if pendingSaveTransfer.phase == .publicationVerified {
                            if let item = pendingSaveSummary {
                                Text("The copied files were checked and backed up. Load \(item.saveDescription.lowercased()) for \(gameName(item.gameCode)) on the console, then return to the game menu.")
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("The saved-game details could not be opened. Keep the backups and refresh before finishing.")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Finish After Testing…") { finishApprovalOperation = pendingSaveTransfer.operation; confirmFinish = true }
                                .disabled(working || pendingSaveSummary == nil || !app.canReviewLibrarySync)
                        } else {
                            Text("This transfer needs a separate review. Keep both backups and do not retry automatically.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Show Record in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pendingSaveTransfer.operation]) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let replacement {
                GroupBox("Replacement console review") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(replacement.menu?.description.placements.filter { $0.kind == "import" }.count ?? 0) added games and \(replacement.saveFiles.count) saved-game files found.")
                        if !replacement.unmatchedProfileFiles.isEmpty {
                            Text("\(replacement.unmatchedProfileFiles.count) profile files do not match these games and need a separate review.")
                                .foregroundStyle(.orange)
                        }
                        if let replacementSaves {
                            Text("Replacement backup: \(replacementSaves.entries.filter { $0.disposition == .new }.count) new, \(replacementSaves.entries.filter { $0.disposition == .unchanged }.count) already match, \(replacementSaves.entries.filter { $0.disposition == .conflict }.count) need a choice.")
                            let missing = replacementSaves.entries.filter { $0.gameMatch == .addedGameMissing }.count
                            let different = replacementSaves.entries.filter { $0.gameMatch == .addedGameDifferent }.count
                            if missing > 0 { Text("\(missing) saved files belong to added games not currently on the replacement.").foregroundStyle(.orange) }
                            if different > 0 { Text("\(different) saved files belong to added games that differ on the replacement.").foregroundStyle(.orange) }
                            Text("This compares saved files and game details. It does not yet confirm that saved games or suspend points will work on the replacement.")
                                .foregroundStyle(.secondary)
                            if !saveOptions.isEmpty {
                                DisclosureGroup("Choose saved games to review") {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(saveOptions) { option in
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Toggle(option.title, isOn: Binding(
                                                        get: { selectedSaveCodes.contains(option.code) },
                                                        set: { if $0 { selectedSaveCodes.insert(option.code) } else { selectedSaveCodes.remove(option.code) } }))
                                                        .disabled(working || !option.eligible)
                                                    if let reason = option.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                                }
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 140)
                                    Text("This saves a review on the Mac. You can then review one saved-data set at a time.").font(.caption).foregroundStyle(.secondary)
                                    Button("Save Selected Review") { Task { await saveSelectedReview() } }
                                        .disabled(working || selectedSaveCodes.isEmpty || !app.canReviewLibrarySync)
                                }
                            }
                            if let savedSaveReview {
                                Button("Show Saved Review in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedSaveReview.directory]) }
                                Button("Review Saved-Game Copy…") { Task { await reviewStagingOptions() } }
                                    .disabled(working || pendingSaveTransfer != nil || !app.canReviewLibrarySync)
                                if !stagingOptions.isEmpty {
                                    Picker("Saved data", selection: $selectedStagingGroup) {
                                        ForEach(stagingOptions) { option in
                                            Text("\(gameName(option.summary.gameCode)) — \(option.summary.saveDescription)").tag(Optional(option.group))
                                        }
                                    }
                                    Text("One saved-data set is copied at a time. Only supported sets are shown.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Copy Temporary Files…") {
                                        stagingApproval = stagingOptions.first(where: { $0.group == selectedStagingGroup })
                                        stagingApprovalReview = savedSaveReview; stagingApprovalContext = stagingContextSHA256
                                        confirmStaging = stagingApproval != nil && stagingApprovalReview != nil && stagingApprovalContext != nil
                                    }
                                        .disabled(working || selectedStagingGroup == nil || !app.canReviewLibrarySync)
                                }
                            }
                        } else {
                            Text("Make a current backup of the replacement to compare its saved games.")
                                .foregroundStyle(.secondary)
                        }
                        Text("Review games and saved progress separately before copying.").foregroundStyle(.secondary)
                        Button("Open Saved Review…") { chooseSavedSaveReview() }
                            .disabled(working || !app.canReviewLibrarySync)
                        Button("Review Copying Games…") { beginReplacementCopy() }
                            .disabled(working || replacementReference == nil || !app.canReviewLibrarySync)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Refresh") { Task { await reload() } }.disabled(working || app.isPreparingSync)
                Button("Back Up This SNES") { Task { await backUpCurrentSNES() } }
                    .disabled(working || app.deviceManager.consoleType != .snesUsa || !app.canReviewLibrarySync)
                    .help("Save and verify a fresh copy of the current SNES library and saved games on this Mac.")
                Button("Open Backups Folder") { NSWorkspace.shared.open(workspace.backups) }
                Button("Compare Saved Games") { Task { await compareSameConsoleSaves() } }
                    .disabled(working || selected?.summary?.hwid != currentHWID || currentHWID == nil || !app.canReviewLibrarySync)
                    .help("Compare this Mac backup with the connected SNES without copying or changing saved data.")
                Spacer()
                Button("Show in Finder") { if let selection { NSWorkspace.shared.activateFileViewerSelecting([selection]) } }.disabled(selection == nil)
            }
            HStack {
                Button("Copy Backup to Another Mac…") { choosePortableExport() }
                    .disabled(working || selected?.summary == nil || app.isPreparingSync)
                Button("Add Backup from Another Mac…") { choosePortableImport() }
                    .disabled(working || app.isPreparingSync)
                Spacer()
            }
            HStack {
                Button("Move to Trash…") { Task { await reviewRemoval() } }.disabled(working || selected?.summary == nil || app.isPreparingSync)
                Spacer()
                Button("Review for Replacement…") { Task { await reviewReplacement() } }
                    .disabled(working || selected?.summary == nil || currentHWID == nil || selected?.summary?.hwid == currentHWID || !app.canReviewLibrarySync)
                Button("Restore Games and Folders…") { Task { await reviewRestore() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || selected?.summary?.hwid != currentHWID || currentHWID == nil || !app.canReviewLibrarySync)
            }
        }
        .padding(22).frame(minWidth: 640, idealWidth: 760, maxWidth: 860, minHeight: 470, idealHeight: 600, maxHeight: 720)
        .task { await reload() }
        .onChange(of: selection) { _, _ in
            if comparisonSelection != nil { message = nil; comparisonSelection = nil; saveComparison = nil }
            clearReplacement()
        }
        .onChange(of: savedSaveReview?.sha256) { _, _ in clearStagingReview() }
        .onChange(of: savedSaveReview?.directory) { _, _ in clearStagingReview() }
        .onChange(of: app.deviceManager.nativeSNESContext?.sha256) { _, _ in
            if comparisonSelection != nil { message = nil; comparisonSelection = nil; saveComparison = nil }
            clearReplacement(); pendingSaveTransfer = nil; pendingSaveSummary = nil; publicationPreview = nil; helperReady = false
            stagingApproval = nil; stagingApprovalReview = nil; stagingApprovalContext = nil
            helperApproval = nil; publicationApproval = nil
            helperApprovalOperation = nil; publicationApprovalOperation = nil; finishApprovalOperation = nil
            Task { await refreshPendingSaveTransfer() }
        }
        .interactiveDismissDisabled(working)
        .confirmationDialog("Move this Mac backup to the Trash?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Move Backup to Trash", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Your console games and other backups stay. You can recover this backup from the Trash. Empty the Trash in Finder to reclaim Mac storage.")
        }
        .confirmationDialog("Copy temporary saved files?", isPresented: $confirmStaging, titleVisibility: .visible) {
            Button("Copy Temporary Files") { Task { await stageSelectedSave() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let option = stagingApproval {
                Text("\(option.summary.saveDescription) for \(gameName(option.summary.gameCode)): \(option.summary.fileCount) files, \(bytes(option.summary.byteCount)). This copies a temporary set to the console; it does not replace saved data. Keep the console connected and keep both Mac backups.")
            }
        }
        .confirmationDialog("Prepare the temporary helper?", isPresented: $confirmHelper, titleVisibility: .visible) {
            Button("Prepare Helper") { Task { await deliverPendingHelper() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This places a checked helper in temporary console memory. It does not copy saved progress or install firmware. Keep the console connected.")
        }
        .confirmationDialog("Copy this saved data?", isPresented: $confirmPublication, titleVisibility: .visible) {
            Button("Copy Saved Data") { Task { await publishPendingSave() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let item = publicationApproval?.summary {
                Text("\(item.saveDescription) for \(gameName(item.gameCode)): \(item.fileCount) files, \(bytes(item.byteCount)). This experimental step writes the reviewed saved data. Existing saves are checked and kept. Keep the console connected and keep both backups; an interruption may need recovery.")
            }
        }
        .confirmationDialog("Finish this transfer?", isPresented: $confirmFinish, titleVisibility: .visible) {
            Button("I Tested It — Finish") { Task { await finishPendingSave() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let item = pendingSaveSummary {
                Text("Choose Finish only after loading \(item.saveDescription.lowercased()) for \(gameName(item.gameCode)) and checking that it works. The app will make a fresh Mac backup and close the recovery record. Temporary console files will remain; nothing is deleted.")
            }
        }
        .sheet(isPresented: $showRestore, onDismiss: { restore = nil; syncingReplacementReference = nil; Task { await reload() } }) {
            SNESLibrarySyncView(restoreSnapshot: restore, replacementSnapshot: syncingReplacementReference).environmentObject(app)
        }
    }
    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    private func gameName(_ code: String) -> String {
        app.gameManager.games.first(where: { $0.code == code })?.name
            ?? app.deviceManager.nativeSNESContext?.installation.originals.frame.gameTitle(for: code)
            ?? code
    }
    private func differenceDescription(_ difference: SNESLibrarySaveComparison.Differences) -> String {
        var parts: [String] = []
        if difference.changed > 0 { parts.append("\(difference.changed) different") }
        if difference.backupOnly > 0 { parts.append("\(difference.backupOnly) only in backup") }
        if difference.consoleOnly > 0 { parts.append("\(difference.consoleOnly) only on SNES") }
        return "Files: " + parts.joined(separator: " • ")
    }
    private func reload() async {
        guard !working else { return }; working = true; defer { working = false }
        do {
            let roots = workspace.knownBackupRoots
            entries = try await Task.detached { try SNESLibraryBackupHistory.scan(roots: roots) }.value
            await refreshPendingSaveTransfer()
        }
        catch { message = error.localizedDescription }
    }
    private func choosePortableExport() {
        guard let selection, !working else { return }
        let panel = NSOpenPanel(); panel.title = "Choose Where to Copy the Backup"
        panel.message = "Choose a folder or drive. The copy includes games and saved progress, but not this console's startup recovery files."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await copyPortableBackup(from: selection, to: destination, importing: false) }
    }
    private func choosePortableImport() {
        guard !working else { return }
        let panel = NSOpenPanel(); panel.title = "Choose an SNES Backup Folder"
        panel.message = "Choose the SNES-Library folder copied from the other Mac. The app will check it before adding it here."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task { await copyPortableBackup(from: source, to: workspace.backups, importing: true) }
    }
    private func copyPortableBackup(from source: URL, to destination: URL, importing: Bool) async {
        guard !working else { return }
        working = true; activity = "Copying and checking the backup…"; message = nil
        defer { working = false; activity = "Checking…" }
        do {
            if importing {
                try workspace.requireActiveBackupsAvailable()
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try SNESLibraryBackupHistory.requireLocation(source, workspace: workspace)
            }
            let copied = try await Task.detached { try SNESPortableLibraryBackup.copy(source, to: destination) }.value
            if importing {
                let roots = workspace.knownBackupRoots
                entries = try await Task.detached { try SNESLibraryBackupHistory.scan(roots: roots) }.value
                selection = copied
                message = "Backup added and checked on this Mac. To use it on a different SNES, set up that SNES first, then choose Review for Replacement. No console was changed."
            } else {
                message = "Backup copied and checked. Bring the SNES-Library folder to the other Mac, then choose Add Backup from Another Mac. No console was changed."
                NSWorkspace.shared.activateFileViewerSelecting([copied])
            }
        } catch { message = error.localizedDescription }
    }
    private func refreshPendingSaveTransfer() async {
        let refreshID = UUID(); pendingRefreshID = refreshID
        guard let context = app.deviceManager.nativeSNESContext else { pendingSaveTransfer = nil; pendingSaveSummary = nil; return }
        let expectedContext = context.sha256, hwid = context.installation.expected.hwid
        do {
            let root = try SNESLibraryJournalPolicy.root()
            let found = try await Task.detached {
                guard FileManager.default.fileExists(atPath: root.path) else { return nil as SNESReplacementSaveJournal.Pending? }
                return try SNESReplacementSaveJournal.pending(root: root, hwid: hwid)
            }.value
            var summary: SNESReplacementSaveJournal.PublicationSummary?
            if let found, found.phase == .publicationVerified, let stage = found.stage {
                do {
                    let originals = context.installation.originals.frame
                    let journal = try await Task.detached { try SNESReplacementSaveJournal(operation: found.operation, reviewSHA256: found.reviewSHA256, originals: originals) }.value
                    do { summary = try await journal.publicationSummary(group: stage.group); try await journal.close() }
                    catch { try? await journal.close(); throw error }
                } catch { summary = nil }
            }
            guard pendingRefreshID == refreshID, app.deviceManager.nativeSNESContext?.sha256 == expectedContext else { return }
            if pendingSaveTransfer?.operation != found?.operation {
                publicationPreview = nil; helperReady = false
            }
            pendingSaveTransfer = found; pendingSaveSummary = summary
        } catch {
            guard pendingRefreshID == refreshID, app.deviceManager.nativeSNESContext?.sha256 == expectedContext else { return }
            pendingSaveTransfer = nil; pendingSaveSummary = nil; message = "A previous transfer could not be checked. Keep both backups. \(error.localizedDescription)"
        }
    }
    private func inspectPendingSaveTransfer() async {
        guard !working, app.canReviewLibrarySync, let pending = pendingSaveTransfer, let stage = pending.stage,
              let context = app.deviceManager.nativeSNESContext, let session = app.deviceManager.nativeSNES else { return }
        working = true; message = nil; defer { working = false }
        do {
            let originals = context.installation.originals.frame
            let journal = try await Task.detached {
                try SNESReplacementSaveJournal(operation: pending.operation, reviewSHA256: pending.reviewSHA256, originals: originals)
            }.value
            let outcome: SNESReplacementSaveStageInspectionReceipt.Outcome
            do {
                outcome = try await session.inspectReplacementSaveStage(journal: journal, group: stage.group)
                try await journal.close()
            } catch { try? await journal.close(); throw error }
            guard app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  pendingSaveTransfer?.operation == pending.operation else {
                throw SNESLibraryBackupHistory.failure("The console connection changed. Check the transfer again.")
            }
            switch outcome {
            case .absent:
                message = "No temporary copy was found. This does not confirm whether progress was restored. Keep both backups; do not retry automatically."
            case .incomplete:
                message = "The temporary copy is incomplete. Your backups are still needed; nothing was restored or removed. Do not retry automatically."
            case .verified:
                message = "The temporary saved files match the review. They have not been restored to the game. Keep both backups and choose Review Saved Files for the next step."
            }
        } catch { message = "The previous transfer could not be checked. Nothing was changed; keep both backups. \(error.localizedDescription)" }
    }
    private func previewPendingSavePublication() async {
        guard !working, app.canReviewLibrarySync, let pending = pendingSaveTransfer, let stage = pending.stage,
              pending.phase == .uncertain, let context = app.deviceManager.nativeSNESContext,
              let session = app.deviceManager.nativeSNES else { return }
        working = true; message = nil; defer { working = false }
        do {
            let originals = context.installation.originals.frame
            let journal = try await Task.detached {
                try SNESReplacementSaveJournal(operation: pending.operation, reviewSHA256: pending.reviewSHA256, originals: originals)
            }.value
            let preview: SNESReplacementSavePublicationPreview
            do {
                preview = try await session.previewReplacementSavePublication(journal: journal, group: stage.group)
                try await journal.close()
            } catch { try? await journal.close(); throw error }
            guard app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  pendingSaveTransfer?.operation == pending.operation else {
                throw SNESLibraryBackupHistory.failure("The console connection changed. Check the transfer again.")
            }
            publicationPreview = preview; helperReady = false
            let item = preview.summary
            let place = item.existingProfile ? "This game already has saved files that must be kept." : "This game does not have a saved-data folder yet."
            let game = app.gameManager.games.first(where: { $0.code == item.gameCode })?.name ?? item.gameCode
            message = "\(item.saveDescription) for \(game): \(item.fileCount) files, \(bytes(item.byteCount)). \(place) The temporary files match. Nothing has been copied to the game yet. Keep both backups."
        } catch { message = "The saved files could not be reviewed. Nothing was changed; keep both backups. \(error.localizedDescription)" }
    }
    private func inspectPendingSavePublication() async {
        guard !working, app.canReviewLibrarySync, let pending = pendingSaveTransfer,
              let context = app.deviceManager.nativeSNESContext, let session = app.deviceManager.nativeSNES else { return }
        working = true; message = nil; defer { working = false }
        do {
            let originals = context.installation.originals.frame
            let journal = try await Task.detached {
                try SNESReplacementSaveJournal(operation: pending.operation, reviewSHA256: pending.reviewSHA256, originals: originals)
            }.value
            let outcome: SNESReplacementSaveProfileRecovery.Outcome
            do {
                outcome = try await session.inspectReplacementSavePublication(journal: journal)
                if outcome == .published {
                    try workspace.requireActiveBackupsAvailable()
                    if try await journal.phase() == .publicationIntent { try await journal.markProfilePublicationUncertain() }
                    _ = try await session.verifyReplacementSaveBeforeTesting(journal: journal, backupRoot: workspace.backups)
                }
                try await journal.close()
            } catch { try? await journal.close(); throw error }
            guard app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  pendingSaveTransfer?.operation == pending.operation else {
                throw SNESLibraryBackupHistory.failure("The console connection changed. Check the transfer again.")
            }
            switch outcome {
            case .absent:
                message = "The reviewed saved files are not visible. Keep both backups; the temporary copy still needs a separate check."
            case .reserved:
                message = "An empty folder for the saved data is visible. Keep both backups; the transfer needs further review."
            case .published:
                await refreshPendingSaveTransfer()
                message = "The reviewed saved files are present and backed up. Test this saved game or suspend point on the console, then return here to finish."
            case .needsReview:
                message = "Some files are incomplete or different. Keep both backups; do not retry automatically."
            }
        } catch { message = "The saved files could not be checked. No console files were changed; keep the Mac backups. \(error.localizedDescription)" }
    }
    private func reviewStagingOptions() async {
        guard !working, pendingSaveTransfer == nil, let receipt = savedSaveReview, let replacement,
              let context = app.deviceManager.nativeSNESContext, context.sha256 == replacementContextSHA256,
              let session = app.deviceManager.nativeSNES, app.canReviewLibrarySync else { return }
        working = true; message = nil; stagingOptions = []; selectedStagingGroup = nil; defer { working = false }
        do {
            let before = try await session.observe(context), originals = context.installation.originals.frame
            let options = try await Task.detached {
                let review = try SNESReplacementSaveReviewStore.open(receipt, originals: originals)
                try review.plan.requireReplacement(replacement)
                return try SNESReplacementSaveJournal.stagingOptions(review: review, before: before.inventory,
                    runtimeSHA256: context.installation.expected.runtimeSHA256)
            }.value
            let after = try await session.observe(context)
            guard app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  savedSaveReview?.sha256 == receipt.sha256, savedSaveReview?.directory == receipt.directory, pendingSaveTransfer == nil,
                  before.inventory.stateSHA256 == after.inventory.stateSHA256,
                  before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256 else {
                throw SNESLibraryBackupHistory.failure("The console or review changed. Review it again.")
            }
            stagingOptions = options; selectedStagingGroup = options.first?.group; stagingContextSHA256 = context.sha256
            message = options.isEmpty ? "No saved-data sets in this review can be copied by this version. Nothing was changed." :
                "Choose a saved-data set to review. Nothing has been copied yet."
        } catch { message = "The saved files could not be reviewed. Nothing was changed. \(error.localizedDescription)" }
    }
    private func stageSelectedSave() async {
        guard !working, pendingSaveTransfer == nil, let receipt = savedSaveReview, let replacement,
              let chosen = stagingApproval, let approvedReview = stagingApprovalReview,
              receipt.directory == approvedReview.directory, receipt.sha256 == approvedReview.sha256,
              stagingOptions.contains(where: { $0.group == chosen.group }),
              let context = app.deviceManager.nativeSNESContext, context.sha256 == stagingContextSHA256,
              context.sha256 == stagingApprovalContext,
              let session = app.deviceManager.nativeSNES, app.canReviewLibrarySync else { return }
        let group = chosen.group
        working = true; message = nil; defer { working = false }
        var journal: SNESReplacementSaveJournal?
        do {
            let before = try await session.observe(context), originals = context.installation.originals.frame
            let review = try await Task.detached {
                let review = try SNESReplacementSaveReviewStore.open(receipt, originals: originals)
                try review.plan.requireReplacement(replacement)
                let options = try SNESReplacementSaveJournal.stagingOptions(review: review, before: before.inventory,
                    runtimeSHA256: context.installation.expected.runtimeSHA256)
                guard let current = options.first(where: { $0.group == group }),
                      current.summary.gameCode == chosen.summary.gameCode, current.summary.saveDescription == chosen.summary.saveDescription,
                      current.summary.fileCount == chosen.summary.fileCount, current.summary.byteCount == chosen.summary.byteCount,
                      current.summary.existingProfile == chosen.summary.existingProfile else { throw SNESLibraryInventory.failure() }
                return review
            }.value
            guard app.deviceManager.nativeSNESContext?.sha256 == context.sha256, savedSaveReview?.sha256 == receipt.sha256, savedSaveReview?.directory == receipt.directory else { throw SNESLibraryInventory.failure() }
            let prepared = try await Task.detached { try SNESReplacementSaveJournal.prepare(review: review, root: SNESLibraryJournalPolicy.ensureRoot()) }.value
            journal = try await Task.detached { try SNESReplacementSaveJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, originals: originals) }.value
            guard let journal else { throw SNESLibraryInventory.failure() }
            let result = try await session.stageReplacementSave(journal: journal, group: group, approved: true)
            try await journal.close(); self.stagingOptions = []; selectedStagingGroup = nil
            await refreshPendingSaveTransfer()
            message = result == .verified ? "The temporary saved files were copied and checked. Review them before the next step." : "The temporary copy needs checking. Keep both backups."
        } catch {
            if let journal { try? await journal.close() }
            await refreshPendingSaveTransfer()
            message = "The temporary copy did not finish. It may need checking; keep both backups. \(error.localizedDescription)"
        }
    }
    private func deliverPendingHelper() async {
        guard !working, let pending = pendingSaveTransfer, pending.operation == helperApprovalOperation, let preview = helperApproval,
              let context = app.deviceManager.nativeSNESContext, context.sha256 == preview.inventory.contextSHA256,
              let session = app.deviceManager.nativeSNES, app.canReviewLibrarySync else { return }
        working = true; message = nil; helperReady = false; defer { working = false }
        do {
            let originals = context.installation.originals.frame
            let journal = try await Task.detached { try SNESReplacementSaveJournal(operation: pending.operation, reviewSHA256: pending.reviewSHA256, originals: originals) }.value
            do { try await session.deliverReplacementSaveHelper(journal: journal, preview: preview, approved: true); try await journal.close() }
            catch { try? await journal.close(); throw error }
            guard app.deviceManager.nativeSNESContext?.sha256 == context.sha256, pendingSaveTransfer?.operation == pending.operation else { throw SNESLibraryInventory.failure() }
            helperReady = true; message = "The temporary helper is ready. Review the saved-data copy before continuing."
        } catch { publicationPreview = nil; message = "The helper could not be prepared. No saved data was copied; keep both backups. \(error.localizedDescription)" }
    }
    private func publishPendingSave() async {
        guard !working, helperReady, let pending = pendingSaveTransfer, pending.operation == publicationApprovalOperation, let preview = publicationApproval,
              let context = app.deviceManager.nativeSNESContext, context.sha256 == preview.inventory.contextSHA256,
              let session = app.deviceManager.nativeSNES, app.canReviewLibrarySync else { return }
        working = true; message = nil; defer { working = false }
        do {
            let originals = context.installation.originals.frame
            let journal = try await Task.detached { try SNESReplacementSaveJournal(operation: pending.operation, reviewSHA256: pending.reviewSHA256, originals: originals) }.value
            do { _ = try await session.publishReplacementSave(journal: journal, preview: preview, approved: true); try await journal.close() }
            catch { try? await journal.close(); throw error }
            publicationPreview = nil; helperReady = false
            await refreshPendingSaveTransfer()
            message = "The saved files were copied and checked. On the console, load this saved game or suspend point and test it, then return to the game menu and check the files here. Keep both backups."
        } catch {
            publicationPreview = nil; helperReady = false
            await refreshPendingSaveTransfer()
            message = "The copy could not be confirmed. It may have changed the saved files. Keep both backups and check the transfer before retrying. \(error.localizedDescription)"
        }
    }
    private func finishPendingSave() async {
        guard !working, pendingSaveSummary != nil, let pending = pendingSaveTransfer, pending.phase == .publicationVerified, pending.operation == finishApprovalOperation,
              let context = app.deviceManager.nativeSNESContext, let session = app.deviceManager.nativeSNES,
              app.canReviewLibrarySync else { return }
        working = true; message = nil; defer { working = false }
        do {
            try workspace.requireActiveBackupsAvailable()
            let originals = context.installation.originals.frame
            let journal = try await Task.detached { try SNESReplacementSaveJournal(operation: pending.operation, reviewSHA256: pending.reviewSHA256, originals: originals) }.value
            let backup: SNESLibrarySnapshotReference
            do {
                backup = try await session.finishReplacementSavePublication(journal: journal, backupRoot: workspace.backups, confirmed: true)
                try await journal.close()
            } catch { try? await journal.close(); throw error }
            await refreshPendingSaveTransfer()
            message = "Finished. A new Mac backup was saved at \(backup.directory.path). Temporary console files were kept."
        } catch { message = "The transfer could not be finished. The recovery record and backups were kept. If files from another game changed or a saved file was removed, they need a separate review. \(error.localizedDescription)" }
    }
    private func closeUnstartedSaveTransfer() async {
        guard !working, app.canReviewLibrarySync, let pending = pendingSaveTransfer, pending.phase == .prepared,
              let context = app.deviceManager.nativeSNESContext else { return }
        pendingRefreshID = UUID(); working = true; message = nil; defer { working = false }
        do {
            try await Task.detached {
                try SNESReplacementSaveJournal.closeUnsentReview(operation: pending.operation, reviewSHA256: pending.reviewSHA256)
            }.value
            guard app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  pendingSaveTransfer?.operation == pending.operation else { return }
            pendingSaveTransfer = nil
            message = "Closed the unstarted review. No console files or backups were changed."
        } catch { message = "The review could not be closed. Keep both backups. \(error.localizedDescription)" }
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
            syncingReplacementReference = nil; restore = reference; app.isPreparingSync = true; showRestore = true
        } catch { message = error.localizedDescription }
    }
    /// A fresh Mac backup uses only read operations on the console. The backup
    /// is reopened and the console is rechecked before reporting success.
    private func backUpCurrentSNES() async {
        guard !working, app.deviceManager.consoleType == .snesUsa, app.canReviewLibrarySync,
              let context = app.deviceManager.nativeSNESContext, let session = app.deviceManager.nativeSNES else { return }
        working = true; activity = "Backing up and checking the SNES. Keep it at the game menu and connected…"
        message = nil; comparisonSelection = nil; saveComparison = nil
        defer { working = false; activity = "Checking…" }
        var savedDirectory: URL?
        do {
            try workspace.requireActiveBackupsAvailable()
            let before = try await session.observe(context)
            let backup = try await session.captureBackup(before, root: workspace.backups, allowCreation: true, forceNew: true)
            savedDirectory = backup.directory
            let after = try await session.observe(context)
            let verified = try await Task.detached { try SNESLibraryBackup.open(directory: backup.directory) }.value
            guard verified.manifestSHA256 == backup.manifestSHA256,
                  verified.inventory.snapshotSHA256 == before.inventory.snapshotSHA256,
                  verified.inventory.stateSHA256 == before.inventory.stateSHA256,
                  before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256,
                  before.inventory.stateSHA256 == after.inventory.stateSHA256,
                  app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  app.canReviewLibrarySync else { throw SNESLibraryBackupHistory.failure("The SNES or its connection changed during the backup.") }
            try await session.requireCurrent(context)
            try verified.validate(); try backup.validate()
            let roots = workspace.knownBackupRoots
            entries = try await Task.detached { try SNESLibraryBackupHistory.scan(roots: roots) }.value
            selection = verified.directory
            message = "Fresh backup verified on this Mac. It includes the current game library, settings and saved-game files. No console files were changed."
        } catch {
            if let savedDirectory {
                message = "A backup was saved at \(savedDirectory.path), but the final console check did not finish. Keep it and try again. \(error.localizedDescription)"
            } else {
                message = "The backup did not finish. Your console files were not changed. \(error.localizedDescription)"
            }
        }
    }

    /// Read-only comparison for the currently connected console. It creates
    /// no replacement plan, recovery record, backup, or console write permit.
    private func compareSameConsoleSaves() async {
        guard let selection, !working, app.deviceManager.consoleType == .snesUsa,
              app.canReviewLibrarySync, let context = app.deviceManager.nativeSNESContext,
              let session = app.deviceManager.nativeSNES else { return }
        working = true; activity = "Reading the SNES and checking the backup. This may take a few minutes…"
        message = nil; comparisonSelection = nil; saveComparison = nil
        defer { working = false; activity = "Checking…" }
        do {
            let before = try await session.observe(context), paths = workspace
            let (result, backup) = try await Task.detached {
                try SNESLibraryBackupHistory.requireLocation(selection, workspace: paths)
                let backup = try SNESLibraryBackup.open(directory: selection)
                return (try SNESLibrarySaveComparison.compare(backup: backup, observed: before.inventory), backup)
            }.value
            let after = try await session.observe(context)
            try await Task.detached { try backup.validate() }.value
            guard self.selection == selection, app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  app.canReviewLibrarySync, before.inventory.stateSHA256 == after.inventory.stateSHA256,
                  before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256 else {
                throw SNESLibraryBackupHistory.failure("The console or selected backup changed. Try the comparison again.")
            }
            comparisonSelection = selection
            saveComparison = result
            message = "Saved-game files: \(result.matching) match, \(result.changed) differ, \(result.backupOnly) only in the backup, and \(result.consoleOnly) only on the console. Differences can reflect progress made since this backup. Nothing was copied or changed."
        } catch {
            guard self.selection == selection, app.deviceManager.nativeSNESContext?.sha256 == context.sha256 else { return }
            comparisonSelection = selection
            message = "Could not compare saved games. Nothing was copied or changed. \(error.localizedDescription)"
        }
    }

    private func reviewReplacement() async {
        guard let selection, !working, app.deviceManager.consoleType == .snesUsa, app.canReviewLibrarySync,
              let context = app.deviceManager.nativeSNESContext, let reader = app.deviceManager.nativeSNES else { return }
        let hwid = context.installation.expected.hwid
        working = true; message = nil; clearReplacement(); defer { working = false }
        do {
            let before = try await reader.observe(context)
            let paths = workspace, originals = context.installation.originals.frame
            let (plan, saveReview, options, reference) = try await Task.detached {
                try SNESLibraryBackupHistory.requireLocation(selection, workspace: paths)
                let backup = try SNESLibraryBackup.open(directory: selection)
                let plan = try SNESLibraryRestore.prepareReplacement(backup: backup, originals: originals, destinationHWID: hwid)
                let current = try SNESLibraryBackup.matching(inventory: before.inventory, roots: paths.knownBackupRoots)
                let comparison = try current.map { try plan.compareSaves(to: $0) }
                let options = try comparison.map { try plan.saveOptions(comparison: $0) } ?? []
                return (plan, comparison, options, try SNESLibrarySnapshotReference(backup))
            }.value
            let after = try await reader.observe(context)
            guard self.selection == selection, app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  app.canReviewLibrarySync, before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256,
                  before.inventory.stateSHA256 == after.inventory.stateSHA256 else { throw SNESLibraryBackupHistory.failure("The console or selection changed. Review the backup again.") }
            try saveReview?.validate()
            replacement = plan; replacementSaves = saveReview; saveOptions = options; replacementReference = reference; replacementContextSHA256 = context.sha256
        } catch { message = error.localizedDescription }
    }
    private func clearStagingReview() {
        stagingOptions = []; selectedStagingGroup = nil; stagingContextSHA256 = nil
        stagingApproval = nil; stagingApprovalReview = nil; stagingApprovalContext = nil
    }
    private func clearReplacement() {
        replacement = nil; replacementSaves = nil; saveOptions = []; selectedSaveCodes = []; savedSaveReview = nil
        replacementReference = nil; replacementContextSHA256 = nil
        stagingOptions = []; selectedStagingGroup = nil; stagingContextSHA256 = nil
    }

    private func saveSelectedReview() async {
        guard !working, let replacement, let comparison = replacementSaves, !selectedSaveCodes.isEmpty,
              let context = app.deviceManager.nativeSNESContext, context.sha256 == replacementContextSHA256,
              let reader = app.deviceManager.nativeSNES, app.canReviewLibrarySync else { return }
        let chosen = selectedSaveCodes, expectedSelection = selection, root = workspace.backups
        working = true; message = nil; defer { working = false }
        do {
            let before = try await reader.observe(context)
            let review = try await Task.detached {
                try comparison.requireCurrent(before.inventory)
                let plan = try SNESReplacementSavePlan.prepare(replacement: replacement, comparison: comparison, gameCodes: chosen)
                return try SNESReplacementSaveEnvelope.prepare(plan: plan)
            }.value
            let after = try await reader.observe(context)
            try await Task.detached { try comparison.requireCurrent(after.inventory) }.value
            guard selection == expectedSelection, app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  app.canReviewLibrarySync else { throw SNESLibraryBackupHistory.failure("The console or selection changed. Review the backup again.") }
            let receipt = try await Task.detached { try SNESReplacementSaveReviewStore.save(review, root: root) }.value
            savedSaveReview = receipt
            message = "Saved the review on this Mac. No saved progress was copied to the console."
        } catch { message = error.localizedDescription }
    }

    private func chooseSavedSaveReview() {
        guard !working, replacement != nil, app.canReviewLibrarySync else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a Saved-Game Review"
        panel.message = "Choose the saved SNES-Save-Review folder. This checks the review without copying anything."
        panel.directoryURL = workspace.backups
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await openSavedSaveReview(directory) }
    }

    private func openSavedSaveReview(_ directory: URL) async {
        guard !working, let replacement, let context = app.deviceManager.nativeSNESContext,
              context.sha256 == replacementContextSHA256, let reader = app.deviceManager.nativeSNES, app.canReviewLibrarySync else { return }
        let expectedSelection = selection, originals = context.installation.originals.frame
        working = true; message = nil; defer { working = false }
        do {
            let before = try await reader.observe(context)
            let (review, result) = try await Task.detached {
                let review = try SNESReplacementSaveReviewStore.open(directory: directory, originals: originals)
                try review.plan.requireReplacement(replacement)
                let result = try SNESReplacementSaveRecovery.inspect(plan: review.plan, observed: before.inventory)
                return (review, result)
            }.value
            let after = try await reader.observe(context)
            guard selection == expectedSelection, app.deviceManager.nativeSNESContext?.sha256 == context.sha256,
                  app.canReviewLibrarySync, before.inventory.snapshotSHA256 == after.inventory.snapshotSHA256,
                  before.inventory.stateSHA256 == after.inventory.stateSHA256 else {
                throw SNESLibraryBackupHistory.failure("The console or selection changed. Review the backup again.")
            }
            savedSaveReview = .init(directory: directory.standardizedFileURL, sha256: review.sha256)
            if !result.conflictingPaths.isEmpty {
                message = "Some saved files conflict with the replacement. Nothing was copied; these files need a separate review."
            } else if !result.canResume {
                message = "A saved-game set is only partly present. Nothing was copied; it needs a separate review."
            } else if result.pendingPaths.isEmpty {
                message = "The reviewed files are already present. Nothing was copied; check the games and progress on the console."
            } else {
                message = "The review has \(result.pendingPaths.count) files not yet on the replacement. Choose Review Saved-Game Copy to see which sets can be copied."
            }
        } catch { message = error.localizedDescription }
    }
    private func beginReplacementCopy() {
        guard replacement != nil, replacementReference != nil, app.canReviewLibrarySync,
              app.deviceManager.nativeSNESContext?.sha256 == replacementContextSHA256 else {
            clearReplacement(); message = "The console or selection changed. Review the backup again."; return
        }
        restore = nil; syncingReplacementReference = replacementReference; app.isPreparingSync = true; showRestore = true
    }
}
