import SwiftUI
import AppKit

/// A saved review and a read-only console check never authorize installation.
struct SNESReviewDraftView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let initialReview: SNESFirstInstallReviewReceipt?
    let reportNormalBootProblem: () -> Void
    let reportFirstStageComplete: () -> Void
    @State private var openedInitialReview = false
    @State private var working = false
    @State private var stopping = false
    @State private var workTask: Task<Void, Never>?
    @State private var summary: SNESFirstInstallReviewSummary?
    @State private var prepared: SNESReviewedConsoleCheck?
    @State private var savedProgress: SNESInstallationProgress?
    @State private var savedInstallation: SNESReviewedInstallationRecord?
    @State private var pendingInstallation: SNESReviewedInstallationRecord?
    @State private var uncertainInstallation: SNESReviewedInstallationRecord?
    @State private var savedUpgradeProgress: SNESInstallationProgress?
    @State private var resumeTarget: SNESMenuSetupResumeTarget?
    @State private var uncertainUpgrade: SNESReviewedUpgradeRecord?
    @State private var triedSavedUpgrade = false
    @State private var ready = false
    @State private var mustReturnToNormal = false
    @State private var normalBootFailed = false
    @State private var preparationUncertain = false
    @State private var checked = false
    @State private var installationBusy = false
    @State private var installationEngaged = false
    @State private var progress = ""
    @State private var error: String?

    init(initialReview: SNESFirstInstallReviewReceipt? = nil, reportNormalBootProblem: @escaping () -> Void,
         reportFirstStageComplete: @escaping () -> Void = {}) {
        self.initialReview = initialReview
        self.reportNormalBootProblem = reportNormalBootProblem
        self.reportFirstStageComplete = reportFirstStageComplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Check Saved SNES Review", systemImage: "folder.badge.questionmark")
                .font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose a saved SNES review to check its backup and prepare a console check. This does not install firmware.")
                    if working {
                        HStack { ProgressView().controlSize(.small); Text(stopping ? "Stopping…" : progress) }
                        Text("Some checks may take several minutes. Keep the app open.").foregroundStyle(.secondary)
                    }
                    if let error {
                        Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled)
                    }
                    if let summary {
                        Label("Saved files checked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        DisclosureGroup("Review details") {
                            Text("\(summary.changedUnits) startup-storage blocks would change if a future installation is approved.")
                            Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([summary.dataDirectory]) }
                        }
                        if prepared == nil && !preparationUncertain && !normalBootFailed && savedInstallation == nil && pendingInstallation == nil && uncertainInstallation == nil {
                            Text("Prepare a check on this Mac, or reopen one that was prepared earlier.")
                            HStack {
                                Button("Prepare Console Check") { prepare(summary) }
                                Button("Open Existing Check…") { chooseOperation(summary) }
                            }.disabled(working || mustReturnToNormal)
                        }
                        Button("Check Saved Installation…") { chooseSavedInstallation(summary) }
                            .disabled(working || mustReturnToNormal || normalBootFailed || installationBusy || installationEngaged)
                        if let savedProgress {
                            Label(savedProgress.title, systemImage: savedProgress.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(savedProgress.needsAttention ? .orange : .green)
                            Text(savedProgress.detail)
                        }
                        if let savedInstallation {
                            Button("Check Saved Menu or Folder Update…") { chooseSavedUpgrade(savedInstallation) }
                                .disabled(working || normalBootFailed || installationBusy)
                            if let savedUpgradeProgress {
                                Label(savedUpgradeProgress.title, systemImage: savedUpgradeProgress.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(savedUpgradeProgress.needsAttention ? .orange : .green)
                                Text(savedUpgradeProgress.detail)
                            }
                            if let uncertainUpgrade,
                               let inspector = SNESFirmwareRecoveryView(app: appState, check: savedInstallation.check, phase: uncertainUpgrade.phase,
                                                                         upgrade: uncertainUpgrade, busy: $installationBusy) {
                                inspector
                            }
                            if !normalBootFailed, let resumeTarget {
                                switch resumeTarget {
                                case .gameFolders(let stage):
                                    if let next = SNESMenuPreparationView(app: appState, record: savedInstallation, busy: $installationBusy, onNormalBootProblem: markNormalBootProblem, stage: stage) { next }
                                case .includedGames(let stage, let upgrade):
                                    if let finish = SNESLibrarySetupCompletionView(app: appState, record: savedInstallation, stage: stage, upgrade: upgrade, busy: $installationBusy) { finish }
                                case .verifyUpgrade(let stage, let upgrade):
                                    if let next = SNESMenuPreparationView(app: appState, record: savedInstallation, busy: $installationBusy, onNormalBootProblem: markNormalBootProblem, stage: stage, resuming: upgrade) { next }
                                }
                            } else if !normalBootFailed && !triedSavedUpgrade,
                                      let next = SNESMenuPreparationView(app: appState, record: savedInstallation, busy: $installationBusy, onNormalBootProblem: markNormalBootProblem) {
                                next
                            }
                        }
                        if !normalBootFailed, let pendingInstallation,
                           let phase = try? SNESReviewedInstallFlow.resumePhase(for: pendingInstallation.phase) {
                            SNESReviewedInstallStepView(app: appState, check: pendingInstallation.check, busy: $installationBusy,
                                engaged: $installationEngaged, onComplete: reportFirstStageComplete,
                                onNormalBootProblem: markNormalBootProblem, initialPhase: phase)
                        }
                        if let uncertainInstallation,
                           let inspector = SNESFirmwareRecoveryView(app: appState, check: uncertainInstallation.check, phase: uncertainInstallation.phase, busy: $installationBusy) {
                            inspector
                        }
                        if normalBootFailed && prepared == nil {
                            Label("Normal startup needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Keep the saved review and backup. Do not continue setup until the SNES starts normally.")
                        }
                    }
                    if let prepared {
                        Button("Show Setup Record in Finder") { NSWorkspace.shared.activateFileViewerSelecting([prepared.operation]) }
                            .disabled(working || installationBusy)
                        if checked && !installationEngaged {
                            Label("The console matched the selected backup during this check.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("No firmware was installed. A future installation needs its own fresh check and approval.")
                        }
                        if normalBootFailed {
                            Label("Normal startup needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Keep the saved review and backup. Do not retry the console check until the SNES starts normally. Close this window and use the SNES setup guide for help.")
                        } else if mustReturnToNormal {
                            Text("Return the SNES to its normal menu") .font(.headline)
                            Text("Turn it OFF, unplug USB for 10 seconds, reconnect with RESET released, then turn it ON normally. Wait for the game-selection menu.")
                            HStack {
                                Button("Menu Doesn't Work") { checked = false; normalBootFailed = true; mustReturnToNormal = false; ready = false; reportNormalBootProblem() }
                                Button("The Normal Menu Is Visible") { mustReturnToNormal = false; ready = false }
                            }.disabled(working)
                        } else if checked {
                            SNESReviewedInstallStepView(app: appState, check: prepared, busy: $installationBusy, engaged: $installationEngaged, onComplete: reportFirstStageComplete, onNormalBootProblem: markNormalBootProblem)
                        } else {
                            Text("Get the SNES ready") .font(.headline)
                            Text("Close other Hakchi apps and connect only the SNES. Turn it OFF, unplug USB for 10 seconds, then slide power ON while unplugged. Hold RESET while reconnecting USB, wait five seconds, and release RESET.")
                            Toggle("The power light is off and the TV is blank", isOn: $ready)
                                .disabled(working)
                            Text("The app temporarily starts recovery software and compares the console with the selected backup. It does not install firmware.")
                                .foregroundStyle(.secondary)
                            Button("Check This SNES") { runCheck() }
                                .disabled(working || !ready)
                        }
                    }
                    Text("First-time setup is a preview. Startup restore has limited preview support.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if working {
                    Button("Stop Check") { stopping = true; workTask?.cancel() }.disabled(stopping)
                } else {
                    Button("Close") { dismiss() }.disabled(mustReturnToNormal || installationBusy)
                }
                Spacer()
                Button("Choose Review Folder…") { chooseFolder() }
                    .disabled(working || mustReturnToNormal || normalBootFailed || preparationUncertain || installationBusy || installationEngaged)
            }
        }
        .padding(24).frame(width: 560, height: 590)
        .interactiveDismissDisabled(working || mustReturnToNormal || installationBusy)
        .onAppear {
            guard !openedInitialReview, let initialReview else { return }
            openedInitialReview = true
            loadReview(directory: initialReview.directory, expected: initialReview)
        }
    }

    private func start(_ title: String, action: @escaping @MainActor () async -> Void) {
        error = nil; working = true; stopping = false; progress = title
        workTask = Task {
            defer { working = false; stopping = false; workTask = nil }
            await action()
        }
    }

    private func markNormalBootProblem() {
        normalBootFailed = true
        reportNormalBootProblem()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Saved SNES Review"
        panel.message = "Choose the folder named SNES-First-Install-Review."
        panel.directoryURL = appState.snesBackupsDirectory
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        loadReview(directory: directory)
    }

    private func loadReview(directory: URL, expected: SNESFirstInstallReviewReceipt? = nil) {
        summary = nil; prepared = nil; checked = false; savedProgress = nil; savedInstallation = nil; pendingInstallation = nil; uncertainInstallation = nil
        savedUpgradeProgress = nil; resumeTarget = nil; uncertainUpgrade = nil; triedSavedUpgrade = false
        start("Checking saved files…") {
            do {
                let result = try await appState.inspectSNESFirstInstallReview(directory: directory)
                if let expected { try result.requireReceipt(expected) }
                try Task.checkCancellation()
                summary = result
            } catch { self.error = Task.isCancelled ? "The check was stopped." : error.localizedDescription }
        }
    }

    private func receipt(_ summary: SNESFirstInstallReviewSummary) -> SNESFirstInstallReviewReceipt {
        .init(directory: summary.reviewDirectory, sha256: summary.reviewSHA256)
    }

    private func prepare(_ summary: SNESFirstInstallReviewSummary) {
        savedProgress = nil
        start("Preparing the check on this Mac…") {
            do {
                // Retain the operation even if cancellation arrives after publication.
                prepared = try await appState.prepareSNESReviewedConsoleCheck(review: receipt(summary))
            } catch {
                preparationUncertain = error is SNESFirmwarePublicationUncertainError || error is SNESFirmwarePreparationCleanupError
                self.error = preparationUncertain ? error.localizedDescription : (Task.isCancelled ? "Preparation stopped." : error.localizedDescription)
            }
        }
    }

    private func chooseOperation(_ summary: SNESFirstInstallReviewSummary) {
        let panel = NSOpenPanel()
        panel.title = "Open a Prepared Console Check"
        panel.message = "Choose the saved SNESFirmware operation folder."
        panel.directoryURL = try? SNESFirmwareJournalPolicy.root()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let operation = panel.url else { return }
        savedProgress = nil
        start("Checking the saved operation…") {
            do { prepared = try await appState.reopenSNESReviewedConsoleCheck(operation: operation, review: receipt(summary)) }
            catch { self.error = Task.isCancelled ? "The check was stopped." : error.localizedDescription }
        }
    }

    private func chooseSavedInstallation(_ summary: SNESFirstInstallReviewSummary) {
        let panel = NSOpenPanel()
        panel.title = "Check a Saved Installation"
        panel.message = "Choose the saved SNES installation folder. This only checks files on this Mac."
        panel.directoryURL = try? SNESFirmwareJournalPolicy.root()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let operation = panel.url else { return }
        savedProgress = nil; savedInstallation = nil; pendingInstallation = nil; uncertainInstallation = nil
        savedUpgradeProgress = nil; resumeTarget = nil; uncertainUpgrade = nil; triedSavedUpgrade = false
        start("Checking the saved installation…") {
            do {
                let result = try await appState.reopenSNESReviewedInstallation(operation: operation, review: receipt(summary))
                try Task.checkCancellation()
                savedProgress = SNESInstallationProgress(phase: result.phase)
                savedInstallation = result.phase == .menuAccepted ? result : nil
                if result.phase == .menuAccepted {
                    prepared = nil; checked = false; reportFirstStageComplete()
                } else if (try? SNESReviewedInstallFlow.resumePhase(for: result.phase)) != nil {
                    pendingInstallation = result; prepared = nil; checked = false; installationEngaged = true
                } else if result.phase == .writeIntent || result.phase == .uncertain {
                    uncertainInstallation = result; prepared = nil; checked = false; installationEngaged = true
                }
            } catch {
                self.error = Task.isCancelled ? "The check was stopped." : "The saved installation could not be verified. Keep its backup and do not try the update again until the files have been checked. \(error.localizedDescription)"
            }
        }
    }

    private func chooseSavedUpgrade(_ installation: SNESReviewedInstallationRecord) {
        let panel = NSOpenPanel()
        panel.title = "Check a Saved Menu or Folder Update"
        panel.message = "Choose the saved update folder. This only checks files on this Mac."
        panel.directoryURL = try? SNESFirmwareJournalPolicy.root()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let operation = panel.url else { return }
        savedUpgradeProgress = nil; resumeTarget = nil; uncertainUpgrade = nil; triedSavedUpgrade = true
        start("Checking the saved update…") {
            do {
                let result = try await appState.reopenSNESMenuUpgrade(operation: operation, after: installation.check)
                try Task.checkCancellation()
                savedUpgradeProgress = SNESInstallationProgress(phase: result.phase)
                if result.phase == .writeIntent || result.phase == .uncertain { uncertainUpgrade = result }
                else { resumeTarget = try SNESMenuSetupResumeTarget.resolve(result) }
            } catch {
                self.error = Task.isCancelled ? "The check was stopped." : "This update could not be confirmed as complete. Keep its backup and review its saved record before continuing. \(error.localizedDescription)"
            }
        }
    }

    private func runCheck() {
        guard let prepared, ready else { return }
        checked = false
        // Every attempted recovery session must end with a normal boot before retrying.
        mustReturnToNormal = true
        start("Checking the connected SNES…") {
            do {
                try await appState.runSNESReviewedConsoleCheck(prepared, ready: true) { stage in
                    await MainActor.run { progress = stage.title }
                }
                checked = true
            } catch { self.error = Task.isCancelled ? "The console check was stopped." : error.localizedDescription }
        }
    }
}
