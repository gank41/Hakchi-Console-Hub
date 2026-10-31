import AppKit
import SwiftUI
import SwiftHakchiCore

@MainActor
private final class LegacyTrialProgress: ObservableObject {
    @Published var fraction: Double?
}

/// Guided first-console trial. Each hardware phase requires a separate reviewed button press.
struct LegacySyncTrialView: View {
    enum Mode { case trial, full }
    let workspace: WorkspacePaths
    let session: UUID
    var mode: Mode = .trial

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var uploadProgress = LegacyTrialProgress()
    @State private var trialCode = ""
    @State private var fullReview: LegacyFullSyncReview?
    @State private var duplicateDecisions: [String: LegacyStockDuplicateReview.Resolution] = [:]
    @State private var excludedCodes: Set<String> = []
    @State private var orderKey = "title"
    @State private var manualOrderCodes: [String] = []
    @State private var compatibilityAcknowledged = false
    @State private var baselineNotice: String?
    @State private var showStructureEditor = false
    @State private var plan: LegacySyncPlan?
    @State private var manifest: LegacyMenuStageManifest?
    @State private var backup: URL?
    @State private var needsBackup = false
    @State private var operationID: UUID?
    @State private var journal: LegacySyncJournal?
    @State private var observation: LegacySyncInspection?
    @State private var working = false
    @State private var confirmed = false
    @State private var rollbackConfirmed = false
    @State private var cleanupComplete = false
    @State private var cleanupPending = false
    @State private var acceptanceConfirmed = false
    @State private var status = "Choose one imported NES game for the first trial."
    @State private var error: String?

    private var sameSession: Bool {
        appState.deviceManager.sessionID == session && appState.deviceManager.isConnected
    }
    private var choices: [Game] {
        appState.gameManager.legacyLocalGames
            .filter { $0.consoleType == .nes && LegacyChangeScripts.validCode($0.code) }
            .sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }
    private var phase: LegacySyncJournal.Phase? { journal?.phase }
    private var syncFinished: Bool {
        mode == .full && phase == .accepted && cleanupComplete && !working
    }
    private var fullOrder: ConsoleMenuOrder {
        switch orderKey {
        case "release": return .releaseDate
        case "publisher": return .publisher
        case "manual": return .manual(manualCodes)
        default: return .title
        }
    }
    private var manualCodes: [String] {
        let selected = visibleReviewCodes.subtracting(excludedCodes)
        let retained = manualOrderCodes.filter { selected.contains($0) }
        let missing = selected.subtracting(retained)
        let byCode = Dictionary(uniqueKeysWithValues:
            (appState.gameManager.legacyRemoteGames.filter(\.isStock)
             + appState.gameManager.legacyLocalGames).map { ($0.code, $0) })
        return retained + missing.sorted {
            let a = byCode[$0]?.name ?? $0, b = byCode[$1]?.name ?? $1
            return (a, $0) < (b, $1)
        }
    }
    private var provisionalCodes: Set<String> {
        guard let fullReview else { return [] }
        return (try? fullReview.proposedCodes(decisions: duplicateDecisions,
                                              defaultUnreviewed: true,
                                              includePreviouslyExcluded: true)) ?? []
    }
    private var visibleReviewCodes: Set<String> {
        provisionalCodes
    }
    private var selectedReviewCodes: Set<String> {
        visibleReviewCodes.subtracting(excludedCodes)
    }
    private var capacityProjection: LegacySyncCapacityEstimate.Projection? {
        fullReview?.capacityEstimate.projected(selectedReviewCodes)
    }
    private var selectedCompatibilityWarnings: [LegacyFullSyncReview.CompatibilityWarning] {
        guard let fullReview else { return [] }
        let selected = visibleReviewCodes.subtracting(excludedCodes)
        return fullReview.compatibilityWarnings.filter { selected.contains($0.code) && $0.requiresAcknowledgement }
    }
    private var reviewGames: [Game] {
        let all = appState.gameManager.legacyRemoteGames.filter(\.isStock)
            + appState.gameManager.legacyLocalGames
        let visible = all.filter { visibleReviewCodes.contains($0.code) }
        if orderKey == "manual" {
            let position = Dictionary(uniqueKeysWithValues: manualCodes.enumerated().map { ($0.element, $0.offset) })
            return visible.sorted { (position[$0.code] ?? Int.max, $0.code)
                < (position[$1.code] ?? Int.max, $1.code) }
        }
        return visible.sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }
    private var canDiscard: Bool {
        guard let phase, let observation else { return false }
        return [.prepared, .uploaded, .verified, .activationIntent, .uncertain].contains(phase)
            && observation.outcome == .beforeRename && observation.phase == .missing
            && !observation.old && !observation.lock
    }
    private var canVerifyUploaded: Bool {
        guard phase == .uploaded, let observation else { return false }
        return observation.phase == .missing && observation.outcome == .beforeRename
            && observation.transaction && observation.archive && observation.stage
            && observation.verified && observation.live && !observation.old
            && !observation.failed && !observation.lock
    }
    private var canRollback: Bool {
        guard let phase, let observation else { return false }
        return [.activationIntent, .uncertain, .activePendingAcceptance].contains(phase)
            && observation.transaction && observation.outcome != .inconsistent
            && observation.phase != .accepted
            && (observation.lock || (observation.phase == .rolledBack && !observation.old))
    }
    private var canResumeAcceptance: Bool {
        phase == .uncertain && (observation?.phase == .menuStarted || observation?.phase == .accepted)
            && observation?.outcome == .newTreePresent && observation?.lock == true
    }
    private var canFinishAcceptance: Bool {
        phase == .uncertain && observation?.phase == .accepted
            && observation?.outcome == .newTreePresent && observation?.lock == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .full ? "Sync NES Game Library" : "Legacy NES Sync Trial").font(.title2.bold())
            if syncFinished {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                        .font(.title.bold()).foregroundStyle(.green)
                    Text("Your updated games are ready on the console.").font(.headline)
                    Text("Temporary console files have been removed. Your recovery backup is saved on this Mac.")
                    if let backup {
                        Button("Show Mac Backup") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
            Text(mode == .full
                ? "Choose your games and folders. A current device backup is saved on your Mac before copying."
                : "Show all 30 built-in games and one edited Mac game. The current game menu stays on the NES for rollback.")
                .foregroundStyle(.secondary)
            if mode == .full && !working && phase != .accepted && phase != .rolledBack && phase != .discarded {
                Text(nextStepExplanation)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            if working {
                VStack(alignment: .leading, spacing: 8) {
                    if let fraction = uploadProgress.fraction {
                        ProgressView(value: fraction)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                    } else {
                        ProgressView(status)
                    }
                    Text(status).font(.callout).textSelection(.enabled)
                    Text("Leave the NES powered and connected, on its first game page. Do not start a game until this step finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if fullReview != nil && plan == nil { capacitySummary }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if phase == .accepted && !working {
                Text(mode == .full ? (cleanupComplete ? "Sync complete. Temporary console copies were removed; backups are on this Mac."
                                       : cleanupPending ? "Games are installed. Cleanup needs attention in Reclaim Space."
                                       : "Library accepted. Finish cleanup in Reclaim Space to release temporary storage.")
                                   : "Trial accepted. The previous menu remains on the NES as a rollback copy.")
                    .foregroundStyle(.green)
            } else if phase == .rolledBack {
                Text("Previous menu restored. Reboot the NES normally to refresh its display.")
                    .foregroundStyle(.green)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if journal == nil && plan == nil && fullReview == nil {
                        if mode == .trial {
                            Picker("Trial game", selection: $trialCode) {
                                ForEach(choices, id: \.code) { game in
                                    Text(game.name + " (" + game.code + ")").tag(game.code)
                                }
                            }
                        }
                        if config.showBackupExplanation {
                            Text("Sync needs a verified Mac backup of this NES’s current menu. The app reuses an exact match; otherwise it makes a new backup before transfer. The previous menu temporarily uses console space during testing.")
                                .font(.callout)
                            Button("Don’t show this explanation again") {
                                config.showBackupExplanation = false
                                config.save()
                            }
                        }
                        if needsBackup {
                            Text("No current verified Mac backup matches this NES. Select Back Up Now to continue.")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let fullReview, plan == nil {
                        if let baselineNotice {
                            Text(baselineNotice).foregroundStyle(.orange)
                        }
                        fullReviewControls(fullReview)
                    }
                    if let plan, let manifest, let backup {
                        Label("\(plan.selectedGames.count) games on \(plan.menuGraph.screens.count) screen(s)", systemImage: "square.grid.2x2")
                        if mode == .trial {
                            Text("Trial: " + (choices.first(where: { $0.code == plan.trialCode })?.name ?? plan.trialCode ?? "Unknown"))
                        } else {
                            Text("\(plan.addedCodes.count) new, \(plan.keptCodes.count) existing and \(plan.removedCodes.count) older custom games removed from the visible menu.")
                            Text("Console order: " + plan.consoleOrder.reviewKey)
                            fullPreviewDetails(plan)
                        }
                        Text("\(plan.removedCodes.count) older custom games will be removed from the console. Their Mac backup is kept. Temporary console copies are removed after you test the new menu and finish syncing.")
                        Text("Required free space: " + ByteCountFormatter.string(fromByteCount: plan.requiredStagingBytes, countStyle: .binary))
                        path("Verified backup", backup)
                        if mode == .full, !cleanupComplete {
                            Text("During an unfinished sync, a temporary copy protects the current menu. Finish Sync removes it after you test the games; recovery backups stay on your Mac.")
                                .font(.caption)
                        }
                        DisclosureGroup("Technical details") {
                            Text("Transfer archive: " + ByteCountFormatter.string(fromByteCount: manifest.archiveBytes, countStyle: .file))
                            path("Prepared files on this Mac", manifest.menuDirectory.deletingLastPathComponent())
                            Text("Folder art: \(plan.structure.folderArt.rawValue); Back: \(plan.structure.backPosition.rawValue). Layout: \(plan.menuGraph.resolvedMode.rawValue).")
                                .font(.caption).foregroundStyle(.secondary)
                            if mode == .full, let operationID, !cleanupComplete {
                                Text("Temporary previous menu: " + LegacySyncCommands.oldPath(for: operationID))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            Text("Review hash: " + plan.reviewSHA256)
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if mode == .full && !LegacyStructureHardwareSupport.canActivate(plan) {
                            Label("This Structure is preview-only until its NES hardware trial is verified.",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } else if let journal {
                        Text("Saved operation: " + journal.operationID.uuidString).font(.caption.monospaced())
                        Text("Phase: " + journal.phase.rawValue).font(.headline)
                        path("Verified backup", journal.backupDirectory)
                        path("Local staged menu", journal.stageDirectory)
                        if plan == nil {
                            Text("This operation was reopened. Inspect the console state before any further action; the app will not repeat an interrupted switch.")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let observation {
                        Text("Console state: " + explanation(for: observation))
                            .font(.callout).textSelection(.enabled)
                        Text("Inactive transfer: archive \(observation.archive ? "present" : "absent"), extracted stage \(observation.stage ? "present" : "absent"), verified marker \(observation.verified ? "present" : "absent"). Console phase: \(observation.phase.rawValue).")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !sameSession {
                        Text("The USB session changed. Close this window, reconnect, and inspect the saved operation.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if (plan != nil && (phase == nil || phase == .verified))
                || (manifest != nil && phase == .activePendingAcceptance)
                || canDiscard || canFinishAcceptance {
                Toggle(confirmationText, isOn: $confirmed)
                    .disabled(working || !sameSession)
            }
            if canRollback {
                Toggle("I reviewed the console inspection and want to restore the old menu. No game is running.", isOn: $rollbackConfirmed)
                    .disabled(working || !sameSession)
            }
            if canResumeAcceptance {
                Toggle("The new menu and game work; I am on the first NES game page (More games…, no Previous games).", isOn: $acceptanceConfirmed)
                    .disabled(working || !sameSession)
            }
            HStack {
                Button("Close") { dismiss() }.disabled(working)
                Spacer()
                if let journal, ![.accepted, .rolledBack, .discarded].contains(journal.phase) {
                    Button("Check Sync Status") { Task { await inspectRecovery() } }
                        .disabled(working || !sameSession)
                }
                if canDiscard {
                    Button("Remove Unused Copy") { Task { await discardInactive() } }
                        .help("Remove the unfinished copy. Your current console games and Mac backup stay.")
                        .disabled(working || !sameSession || !confirmed)
                }
                if canVerifyUploaded {
                    Button("Check Copied Games and Continue") { Task { await verifyUploaded() } }
                        .disabled(working || !sameSession)
                }
                if canRollback {
                    Button("Restore Old Menu") { Task { await rollback() } }
                        .disabled(working || !sameSession || !rollbackConfirmed)
                }
                if canResumeAcceptance {
                    Button(mode == .full ? "Continue Library Review" : "Continue Trial Review") {
                        Task { await resumeAcceptance() }
                    }
                        .disabled(working || !sameSession || !acceptanceConfirmed)
                }
                if canFinishAcceptance {
                    Button("Confirm Sync Finished") { Task { await finishAcceptance() } }
                        .disabled(working || !sameSession || !confirmed)
                }
                if journal == nil && plan == nil && fullReview == nil {
                    Button(needsBackup ? "Back Up Now" : mode == .full ? "Choose Games" : "Prepare Trial Preview") {
                        Task { await prepare(forceBackup: needsBackup) }
                    }
                    .disabled(working || !sameSession || (mode == .trial && trialCode.isEmpty))
                } else if journal == nil && plan == nil && fullReview != nil {
                    Button("Preview Changes") { Task { await prepareFullPreview() } }
                        .disabled(working || !sameSession ||
                                  (!compatibilityAcknowledged && !selectedCompatibilityWarnings.isEmpty)
                                  || (capacityProjection?.headroomBytes ?? 0) < 0)
                } else if journal == nil, plan != nil {
                    Button(mode == .full ? "Step 1. Copy Games to Console" : "Copy Games to Console") { Task { await stage() } }
                        .help("Copy and check the new files first. The console keeps showing its current games until the next step.")
                        .disabled(working || !sameSession || !confirmed
                                  || (plan.map { !LegacyStructureHardwareSupport.canActivate($0) } ?? true))
                } else if phase == .verified, plan != nil {
                    Button(mode == .full ? "Step 2. Show Updated Games" : "Show Trial Games") { Task { await activate() } }
                        .help("Refresh the console menu to show the copied games, then try them before finishing the sync.")
                        .disabled(working || !sameSession || !confirmed
                                  || (plan.map { !LegacyStructureHardwareSupport.canActivate($0) } ?? true))
                } else if phase == .activePendingAcceptance, manifest != nil {
                    Button(mode == .full ? "Step 3. Finish Sync" : "Accept Working Trial") { Task { await accept() } }
                        .disabled(working || !sameSession || !confirmed)
                }
            }
            }
        }
        .padding(24).frame(width: mode == .full ? 760 : 680, height: mode == .full ? 740 : 660)
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $showStructureEditor) {
            let selected = visibleReviewCodes.subtracting(excludedCodes)
            let games = reviewGames.filter { selected.contains($0.code) }
            ConsoleStructureView(console: .nes, games: games,
                stockCodes: Set(games.filter(\.isStock).map(\.code)),
                allowsSyncShortcut: false)
                .environmentObject(appState)
        }
        .task { await loadSavedState() }
        .onChange(of: selectedReviewCodes) { _, _ in updateCapacityStatus() }
        .onDisappear {
            appState.isPreparingSync = false
            appState.legacyCapacityPreview = nil
        }
    }

    private func updateCapacityStatus() {
        appState.legacyCapacityPreview = capacityProjection
    }

    @ViewBuilder private func fullReviewControls(_ review: LegacyFullSyncReview) -> some View {
        Text(review.previouslySelectedCodes == nil ? "First full sync" : "Update the accepted library")
            .font(.headline)
        Text("\(review.duplicateReview.rows.count) imported NES games reviewed against 30 built-in games. \(review.duplicateReview.rows.filter { $0.evidence == .exact }.count) byte-identical copies default to built-in, and you can override each one.")
            .font(.callout)
        Picker("Order on NES", selection: $orderKey) {
            Text("Title").tag("title")
            Text("Release date").tag("release")
            Text("Publisher").tag("publisher")
            Text("Manual").tag("manual")
        }
        Button("Change Folders and Pages…") { showStructureEditor = true }
            .disabled(working)
        Text("If you change duplicate choices or game selection, reopen Structure and match custom folders before preparing the preview.")
            .font(.caption).foregroundStyle(.secondary)
        ConsoleMenuLimitPicker()
        if review.duplicateReview.rows.contains(where: { $0.stockCode != nil }) {
            Text("Built-in matches").font(.headline)
            Text("Exact copies default to the built-in version. Matches with different ROM bytes need a deliberate choice.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Keep Built-in for All New Matches") {
                for row in review.duplicateReview.rows where row.needsDecision
                    && review.suggestedDecisions[row.localCode] == nil {
                    duplicateDecisions[row.localCode] = .keepBuiltIn
                }
            }
            ForEach(review.duplicateReview.rows.filter { $0.stockCode != nil }, id: \.localCode) { row in
                Picker(row.localTitle + " / " + (row.stockTitle ?? "built-in")
                       + (row.evidence == .exact ? " (identical ROM)" : " (different ROM)"),
                       selection: Binding(get: {
                    switch duplicateDecisions[row.localCode] ?? review.suggestedDecisions[row.localCode] {
                    case .keepBuiltIn: return "built-in"
                    case .keepImported: return "imported"
                    case nil: return row.evidence == .exact ? "built-in" : "unreviewed"
                    }
                }, set: { value in
                    duplicateDecisions[row.localCode] = value == "imported" ? .keepImported : .keepBuiltIn
                    excludedCodes.remove(row.localCode)
                    if let stockCode = row.stockCode { excludedCodes.remove(stockCode) }
                })) {
                    if row.needsDecision { Text("Choose a version…").tag("unreviewed") }
                    Text("Keep built-in").tag("built-in")
                    Text("Use imported ROM").tag("imported")
                }
                .pickerStyle(.menu)
            }
        }
        if !review.missingSelectedCodes.isEmpty {
            Text("Previously selected games missing from this Mac").font(.headline)
            Text("Restore each game to the managed library or explicitly confirm removing it from the NES menu.")
                .font(.caption).foregroundStyle(.orange)
            ForEach(review.missingSelectedCodes.sorted(), id: \.self) { code in
                Toggle("Remove " + (appState.gameManager.legacyRemoteGames.first { $0.code == code }?.name ?? code),
                       isOn: Binding(get: { excludedCodes.contains(code) }, set: { remove in
                    if remove { excludedCodes.insert(code) } else { excludedCodes.remove(code) }
                }))
            }
        }
        if !review.compatibilityWarnings.isEmpty {
            let informational = review.compatibilityWarnings.filter { !$0.requiresAcknowledgement }
            if !informational.isEmpty {
                DisclosureGroup("\(informational.count) ROMs contain extra file information") {
                    Text("Their NES headers are valid. Extra bytes after the game data are not a sync error; the original files are kept unchanged.")
                    ForEach(informational, id: \.code) { item in Text(item.title).font(.caption) }
                }.foregroundStyle(.secondary)
            }
            if !selectedCompatibilityWarnings.isEmpty {
                ForEach(selectedCompatibilityWarnings, id: \.code) { warning in
                    Label(warning.title + ": " + warning.detail, systemImage: "exclamationmark.triangle")
                }
                Toggle("Include these games even though their ROM headers could not be checked.",
                       isOn: $compatibilityAcknowledged)
            }
        }
        Text("Games to show on the NES").font(.headline)
        Text("Check games to include them. Unchecking removes them from the next console menu; their Mac files stay in your library.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Select All") { excludedCodes.subtract(visibleReviewCodes) }
                .disabled((review.capacityEstimate.projected(visibleReviewCodes)?.headroomBytes ?? 0) < 0)
                .help("Select all only when the minimum staging estimate fits; the exact preview still checks free space.")
            Button("Select None") { excludedCodes.formUnion(visibleReviewCodes) }
        }
        ForEach(reviewGames, id: \.code) { game in
            let cannotFit = excludedCodes.contains(game.code)
                && !review.capacityEstimate.canInclude(game.code, in: selectedReviewCodes)
            HStack {
                Toggle(isOn: Binding(get: { !excludedCodes.contains(game.code) }, set: { included in
                    if included { excludedCodes.remove(game.code) }
                    else { excludedCodes.insert(game.code) }
                })) {
                    Text(game.name + (game.isStock ? " (built-in)" : ""))
                }
                .disabled(cannotFit)
                if cannotFit {
                    Text("Not enough space").font(.caption2).foregroundStyle(.orange)
                }
                if orderKey == "manual" && !excludedCodes.contains(game.code) {
                    Button("Up") { moveManual(game.code, by: -1) }
                    Button("Down") { moveManual(game.code, by: 1) }
                }
            }
        }
    }

    private var capacitySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(selectedReviewCodes.count) games selected").fontWeight(.semibold)
                Spacer()
                if let estimate = capacityProjection {
                    Text(ByteCountFormatter.string(fromByteCount: estimate.freeBytes, countStyle: .binary) + " free on NES")
                }
            }
            if let estimate = capacityProjection {
                if estimate.headroomBytes < 0 {
                    Text("Needs " + ByteCountFormatter.string(fromByteCount: -estimate.headroomBytes, countStyle: .binary)
                         + " more for the temporary transfer. Remove old transfer files or select fewer games.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Selection fits the transfer estimate · " + ByteCountFormatter.string(fromByteCount: estimate.headroomBytes, countStyle: .binary)
                         + " remaining during copying")
                        .foregroundStyle(.secondary)
                }
            } else { Text("Preview Changes will check the exact space needed.").foregroundStyle(.secondary) }
        }.font(.callout).padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func moveManual(_ code: String, by offset: Int) {
        var codes = manualCodes
        guard let index = codes.firstIndex(of: code), codes.indices.contains(index + offset) else { return }
        codes.swapAt(index, index + offset)
        manualOrderCodes = codes
    }

    @ViewBuilder private func fullPreviewDetails(_ plan: LegacySyncPlan) -> some View {
        let names = Dictionary(uniqueKeysWithValues: plan.selectedGames.map { ($0.game.code, $0.game.name) })
        if !plan.addedCodes.isEmpty {
            DisclosureGroup("New games (\(plan.addedCodes.count))") {
                ForEach(plan.addedCodes.sorted(), id: \.self) { code in
                    Text(names[code] ?? code).font(.caption)
                }
            }
        }
        if !plan.removedCodes.isEmpty {
            DisclosureGroup("Games leaving the visible menu (\(plan.removedCodes.count))") {
                ForEach(plan.removedCodes.sorted(), id: \.self) { code in
                    Text(appState.gameManager.legacyRemoteGames.first(where: { $0.code == code })?.name ?? code)
                        .font(.caption)
                }
            }
        }
        ConsoleLayoutPreview(graph: plan.menuGraph)
        Text("Games on each screen").font(.headline)
        ForEach(plan.menuGraph.screens, id: \.number) { page in
            DisclosureGroup("\(page.number == 0 ? "Main menu" : page.title) · \(page.gameCodes.count) games") {
                ForEach(Array(page.gameCodes.enumerated()), id: \.element) { index, code in
                    if let item = plan.selectedGames.first(where: { $0.game.code == code }) {
                        HStack(spacing: 8) {
                            if let cover = item.coverURL,
                               let image = NSImage(contentsOfFile: cover.path) {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(width: 32, height: 32)
                            } else {
                                Image(systemName: "gamecontroller").frame(width: 32, height: 32)
                            }
                            Text("\(index + 1). " + item.game.name)
                            if item.game.isStock {
                                Text("Built-in art").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(page.links, id: \.target) { link in
                    Text("→ \(link.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nextStepExplanation: String {
        switch phase {
        case .verified:
            return "Step 1 is complete: your games have been copied and checked. Choose Step 2. Show Updated Games to display them on the console."
        case .activePendingAcceptance:
            return "Step 2 is complete: try the updated games on your console. When they work, return to the first menu screen and choose Step 3. Finish Sync to clear the temporary copies. Your backup stays on this Mac."
        case nil where plan != nil:
            return "Check the preview below, then choose Step 1. Copy Games to Console. Your current console menu stays visible while the new files are copied and checked."
        case nil where fullReview != nil:
            return "Choose the games you want and how to organize them, then choose Preview Changes."
        case nil:
            return "Choose Games checks your console and its Mac backup, then lets you choose games and folders."
        default:
            return "Check Sync Status will show what finished and help you continue safely."
        }
    }

    private var confirmationText: String {
        if canDiscard {
            return "Remove only the unfinished copy. Keep my current console games and Mac backup."
        }
        if canFinishAcceptance {
            return "The NES menu and selected games work. Record the console's completed acceptance."
        }
        switch phase {
        case .verified:
            return "The top-level NES menu is visible, no game or demo is running, and I am watching the monitor."
        case .activePendingAcceptance:
            return mode == .full
                ? "The menu, artwork, and sample games work. I’m on the first game page. Finish Sync will save the Mac backup and remove temporary console copies."
                : "The trial game launched, its controls worked, and I returned to the first NES game page."
        default:
            return "I checked the games, folders and free space. The NES is on its first menu screen with no game running."
        }
    }

    private func path(_ label: String, _ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(url.path).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
        }
    }

    private func explanation(for result: LegacySyncInspection) -> String {
        switch result.outcome {
        case .beforeRename: return "Your previous games are still displayed. You can remove the unfinished copy and start again."
        case .firstRenameUncertain: return "The menu change did not finish. Leave the console powered and connected so the app can help restore it."
        case .newTreePresent: return "The new games are installed. Try them on the console before finishing the sync. The previous menu is kept temporarily."
        case .inconsistent: return "The app could not confirm which menu is ready. Leave the NES connected and keep your Mac backups."
        }
    }

    @MainActor private func loadSavedState() async {
        if trialCode.isEmpty {
            trialCode = choices.first(where: { $0.name.localizedCaseInsensitiveContains("zelda ii") })?.code
                ?? choices.first?.code ?? ""
        }
        do {
            journal = try await LegacySyncJournalStore(directory: workspace.journals).latestUnresolved()
            if let journal {
                switch (mode, journal.resolvedScope) {
                case (.trial, .trial), (.full, .full): break
                default:
                    throw SyncPlanError.invalidInput("Another sync operation needs its matching recovery view before starting this one.")
                }
                status = "An earlier sync operation needs inspection."
                operationID = journal.operationID
                backup = journal.backupDirectory
                let file = journal.stageDirectory.appendingPathComponent("manifest.json")
                let saved = try JSONDecoder().decode(LegacyMenuStageManifest.self,
                                                     from: Data(contentsOf: file))
                let archive = try LegacySyncPlan.SourceFile.capture(saved.archiveURL)
                guard saved.menuDirectory.deletingLastPathComponent().standardizedFileURL == journal.stageDirectory,
                      saved.reviewSHA256 == journal.reviewSHA256,
                      saved.archiveSHA256 == journal.archiveSHA256,
                      saved.treeSHA256 == journal.treeSHA256,
                      saved.archiveBytes == journal.archiveBytes,
                      archive.byteCount == journal.archiveBytes,
                      archive.sha256 == journal.archiveSHA256 else {
                    throw LegacySyncJournalError.invalidRecord
                }
                manifest = saved
                if mode == .full, let selectedCodes = journal.selectedCodes {
                    let library = try LegacyBackupLibrary.read(journal.backupDirectory)
                    let hashes = try LegacyBackupLibrary.stockROMHashes(journal.backupDirectory)
                    let accepted = try await LegacySyncJournalStore(directory: workspace.journals)
                        .latestAcceptedFull()
                    let usable = accepted?.selectedCodes.map(Set.init) == library.report.visibleCodes
                        ? accepted : nil
                    let review = try LegacyFullSyncReview.make(
                        localGames: appState.gameManager.legacyLocalGames,
                        remoteGames: library.games, report: saved.reviewReport ?? library.report,
                        factoryROMHashes: hashes, accepted: usable)
                    let restored = try review.selectionForSavedPreview(Set(selectedCodes))
                    fullReview = review
                    duplicateDecisions = restored.decisions
                    excludedCodes = restored.excludedCodes
                    switch journal.consoleOrder ?? .title {
                    case .title: orderKey = "title"
                    case .releaseDate: orderKey = "release"
                    case .publisher: orderKey = "publisher"
                    case .manual(let codes):
                        orderKey = "manual"
                        manualOrderCodes = codes
                    }
                    updateCapacityStatus()
                }
                if journal.phase == .verified {
                    let library = try LegacyBackupLibrary.read(journal.backupDirectory)
                    let reviewReport = saved.reviewReport ?? library.report
                    guard reviewReport.matchesLayout(of: library.report),
                          reviewReport.visibleCodes == library.report.visibleCodes else {
                        throw LegacySyncJournalError.invalidRecord
                    }
                    let savedTrialCode: String?
                    if case .trial(let code) = journal.resolvedScope { savedTrialCode = code }
                    else { savedTrialCode = nil }
                    let rebuilt = try LegacySyncPlan.make(localGames: appState.gameManager.legacyLocalGames,
                        remoteGames: library.games, report: reviewReport,
                        selectedCodes: Set(journal.selectedCodes ?? [savedTrialCode].compactMap { $0 }),
                        maximumGamesPerPage: journal.maximumGamesPerPage,
                        trialCode: savedTrialCode, consoleOrder: journal.consoleOrder ?? .title,
                        reviewedLocalCodes: journal.reviewedLocalCodes ?? [],
                        structure: journal.resolvedStructure,
                        folderArtworkDirectory: workspace.library.appendingPathComponent("FolderArtwork"))
                    guard rebuilt.reviewSHA256 == journal.reviewSHA256 else {
                        throw LegacySyncJournalError.invalidRecord
                    }
                    try rebuilt.verifyLocalSources()
                    plan = rebuilt
                    status = "The copied games have been checked. Review them before showing the updated menu."
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func prepare(forceBackup: Bool = false) async {
        guard !working, sameSession,
              let client = appState.deviceManager.legacyClient,
              let baseline = appState.deviceManager.legacyReport else { return }
        let selected = choices.first(where: { $0.code == trialCode })
        if mode == .trial && selected == nil { return }
        working = true; confirmed = false; error = nil
        needsBackup = false
        uploadProgress.fraction = nil
        defer { working = false }
        do {
            guard try await LegacySyncJournalStore(directory: workspace.journals).latestUnresolved() == nil else {
                throw LegacySyncJournalError.unresolvedOperation
            }
            status = "Checking this NES and its top-level menu…"
            let lease = try await client.reserveForChange()
            let fresh: LegacyConsoleReport
            let saved: URL
            do {
                fresh = try await LegacyConsoleService.inspect(client: lease)
                try LegacyGameChangeService.validateReport(fresh, against: baseline)
                guard fresh.visibleCodes == baseline.visibleCodes else {
                    throw LegacyInspectionError.invalidReport
                }
                let device = LegacySyncLeaseDevice(lease: lease)
                let existing = try await LegacyCurrentBackup.find(report: fresh,
                    device: device, workspace: workspace)
                if let existing {
                    saved = existing.directory
                    status = "Reusing the verified Mac backup that exactly matches this NES…"
                } else {
                    guard config.automaticallyCreateMissingBackup || forceBackup else {
                        needsBackup = true
                        status = "A current Mac backup is required before Sync Library."
                        await lease.release()
                        return
                    }
                    status = "Creating and verifying a Mac backup of this NES…"
                    try workspace.requireActiveBackupsAvailable()
                    saved = try await LegacyConsoleService.backup(client: lease, report: fresh,
                                                                   destination: workspace.backups)
                    let chipID = try await device.chipID()
                    let snapshot = try LegacyMenuSnapshot.verify(directory: saved,
                                                                  expectedChipID: chipID)
                    let selection = LegacyCurrentBackup.Selection(directory: saved,
                        archiveSHA256: snapshot.manifest.archiveSHA256,
                        treeSHA256: snapshot.menuTreeSHA256,
                        chipIDFingerprint: snapshot.manifest.chipIDFingerprint,
                        observedReport: snapshot.observedReport)
                    try await LegacyCurrentBackup.requireCurrent(selection,
                        report: fresh, device: device, workspace: workspace)
                }
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
            if mode == .full {
                status = "Comparing imported games with the verified built-in ROMs…"
                let library = try LegacyBackupLibrary.read(saved)
                let hashes = try LegacyBackupLibrary.stockROMHashes(saved)
                let accepted = try await LegacySyncJournalStore(directory: workspace.journals)
                    .latestAcceptedFull()
                let usable = accepted?.selectedCodes.map(Set.init) == library.report.visibleCodes
                    ? accepted : nil
                baselineNotice = accepted != nil && usable == nil
                    ? "The console menu differs from the last accepted library. This will be a fresh full review of the current NES, not an incremental update."
                    : nil
                fullReview = try LegacyFullSyncReview.make(localGames: appState.gameManager.legacyLocalGames,
                    remoteGames: library.games, report: fresh,
                    factoryROMHashes: hashes, accepted: usable)
                duplicateDecisions = [:]
                if let review = fullReview {
                    excludedCodes = try review.proposedCodes(decisions: [:], defaultUnreviewed: true,
                        includePreviouslyExcluded: true).subtracting(review.proposedCodes(decisions: [:], defaultUnreviewed: true))
                }
                compatibilityAcknowledged = false
                updateCapacityStatus()
                manualOrderCodes = []
                backup = saved
                status = "Library review ready. Confirm possible duplicates and choose console order."
            } else if let selected {
                status = "Building the edited game menu on this Mac…"
                let prepared = try LegacySyncPlan.make(localGames: appState.gameManager.legacyLocalGames,
                    remoteGames: appState.gameManager.legacyRemoteGames, report: fresh,
                    selectedCodes: [selected.code],
                    maximumGamesPerPage: AppConfig.shared.consoleMenuLimit.rawValue,
                    trialCode: selected.code)
                let stages = workspace.root.appendingPathComponent("Stages", isDirectory: true)
                try FileManager.default.createDirectory(at: stages, withIntermediateDirectories: true)
                let rendered = try LegacyMenuStage.build(plan: prepared, in: stages, verifiedBackup: saved)
                plan = prepared; manifest = rendered; backup = saved; operationID = UUID()
                status = "Preview ready. Check your games and folders before copying them to the console."
            }
        } catch { self.error = error.localizedDescription; status = "Preview needs attention." }
    }

    @MainActor private func prepareFullPreview() async {
        guard mode == .full, !working, sameSession,
              let review = fullReview, let backup,
              compatibilityAcknowledged || selectedCompatibilityWarnings.isEmpty else { return }
        working = true; error = nil; confirmed = false
        defer { working = false }
        do {
            if let issue = AppConfig.shared.structureLoadIssue {
                throw ConsoleStructureError.invalidSetting(issue)
            }
            status = "Preparing your games, artwork and folders for the preview…"
            let library = try LegacyBackupLibrary.read(backup)
            let structure = AppConfig.shared.structure(for: .nes)
            let prepared = try review.plan(decisions: duplicateDecisions,
                excludedCodes: excludedCodes, consoleOrder: fullOrder,
                maximumGamesPerPage: structure.maximumGamesPerPage.rawValue,
                structure: structure,
                folderArtworkDirectory: workspace.library.appendingPathComponent("FolderArtwork"),
                selectedCodes: selectedReviewCodes)
            guard prepared.report.matchesLayout(of: library.report),
                  prepared.report.visibleCodes == library.report.visibleCodes else {
                throw LegacyInspectionError.invalidBackup
            }
            let stages = workspace.root.appendingPathComponent("Stages", isDirectory: true)
            try FileManager.default.createDirectory(at: stages, withIntermediateDirectories: true)
            let rendered = try await Task.detached(priority: .userInitiated) {
                try LegacyMenuStage.build(plan: prepared, in: stages, verifiedBackup: backup)
            }.value
            plan = prepared; manifest = rendered; operationID = UUID()
            status = "Full preview ready. Review backup, menu size and space before transfer."
        } catch { self.error = error.localizedDescription; status = "Full preview needs attention." }
    }

    @MainActor private func stage() async {
        guard !working, confirmed, sameSession, let client = appState.deviceManager.legacyClient,
              let plan, let manifest, let backup, let operationID else { return }
        working = true; confirmed = false; error = nil
        uploadProgress.fraction = 0
        defer { working = false; uploadProgress.fraction = nil }
        do {
            guard mode != .full || plan.structure == AppConfig.shared.structure(for: .nes) else {
                throw SyncPlanError.invalidInput("The Structure setting changed. Prepare and review a new menu before transfer.")
            }
            status = "Copying games to the console and checking the files…"
            let lease = try await client.reserveForChange()
            let progressModel = uploadProgress
            let device = LegacySyncLeaseDevice(lease: lease) { sent, total in
                Task { @MainActor in progressModel.fraction = total > 0 ? Double(sent) / Double(total) : nil }
            }
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.stage(operationID: operationID, plan: plan, manifest: manifest,
                                            backup: backup, device: device)
                journal = try await LegacySyncJournalStore(directory: workspace.journals).load(operationID)
                status = "Games copied and checked. Choose Show Updated Games to display them on the NES."
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
        } catch {
            journal = try? await LegacySyncJournalStore(directory: workspace.journals).load(operationID)
            self.error = error.localizedDescription
            status = "Transfer stopped. Inspect the saved operation; no menu switch was requested."
        }
    }

    @MainActor private func activate() async {
        guard !working, confirmed, sameSession, let client = appState.deviceManager.legacyClient,
              let plan, let manifest, let backup, let operationID else { return }
        working = true; confirmed = false; error = nil
        defer { working = false }
        do {
            guard mode != .full || plan.structure == AppConfig.shared.structure(for: .nes) else {
                throw SyncPlanError.invalidInput("The Structure setting changed. Reopen the reviewed operation before switching menus.")
            }
            status = "Refreshing the console menu to show your updated games…"
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.activate(operationID: operationID, plan: plan, manifest: manifest,
                                               backup: backup, device: LegacySyncLeaseDevice(lease: lease))
                journal = try await LegacySyncJournalStore(directory: workspace.journals).load(operationID)
                status = mode == .full
                    ? "Your updated games are ready to try. Check the folders, artwork and games, then return to the first menu screen."
                    : "Trial menu is active. Launch the trial game, test controls, and return to the root menu."
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
        } catch {
            journal = try? await LegacySyncJournalStore(directory: workspace.journals).load(operationID)
            self.error = error.localizedDescription
            status = "Menu switch result needs inspection. Do not repeat it."
        }
    }

    @MainActor private func accept() async {
        guard !working, confirmed, sameSession, let client = appState.deviceManager.legacyClient,
              let manifest, let operationID else { return }
        working = true; confirmed = false; error = nil
        defer { working = false }
        do {
            status = "Checking the owned sync lock and accepting the working trial…"
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.accept(operationID: operationID, manifest: manifest,
                                             mainMenuConfirmed: true,
                                             device: LegacySyncLeaseDevice(lease: lease))
                journal = try await LegacySyncJournalStore(directory: workspace.journals).load(operationID)
                observation = nil
                status = mode == .full ? "Games accepted. Saving the current device backup on this Mac…"
                                       : "Trial accepted. The old menu tree is retained for rollback."
                if mode == .full, let plan {
                    try AppConfig.shared.setStructure(plan.structure, for: .nes)
                    AppConfig.shared.save()
                }
                if mode == .full {
                    do {
                        try await LegacyPostAcceptCleanup.run(workspace: workspace, lease: lease) { message in
                            Task { @MainActor in status = message }
                        }
                        cleanupComplete = true
                        status = "Sync complete. Mac backup verified and temporary console copies removed."
                    } catch {
                        cleanupPending = true
                        self.error = error.localizedDescription
                        status = "Games are installed. Reclaim Space can check the remaining cleanup."
                    }
                }
                await lease.release()
                await appState.refreshLegacyLibraryAfterChange()
            } catch {
                await lease.release()
                throw error
            }
        } catch {
            journal = try? await LegacySyncJournalStore(directory: workspace.journals).load(operationID)
            self.error = error.localizedDescription
            status = "Acceptance needs recovery inspection; the old tree is still retained."
        }
    }

    @MainActor private func inspectRecovery() async {
        guard !working, sameSession, let client = appState.deviceManager.legacyClient,
              let journal else { return }
        working = true; confirmed = false; rollbackConfirmed = false; acceptanceConfirmed = false; error = nil
        defer { working = false }
        do {
            status = "Reading the transaction paths without changing the menu…"
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                observation = try await transaction.inspectRecovery(operationID: journal.operationID,
                    device: LegacySyncLeaseDevice(lease: lease))
                status = "Recovery inspection complete. Choose a reviewed recovery action if needed."
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func verifyUploaded() async {
        guard !working, canVerifyUploaded, sameSession,
              let client = appState.deviceManager.legacyClient,
              let journal, let manifest else { return }
        working = true; error = nil
        defer { working = false }
        do {
            status = "Checking every inactive file against the saved menu preview…"
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.reconcileUploaded(operationID: journal.operationID,
                                                         manifest: manifest,
                                                         device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                observation = nil
                await loadSavedState()
                if plan != nil {
                    status = "Inactive stage verified. The original NES menu is still active. Review before switching."
                }
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "The uploaded stage was not accepted. The original menu remains active."
        }
    }

    @MainActor private func discardInactive() async {
        guard !working, confirmed, canDiscard, sameSession,
              let client = appState.deviceManager.legacyClient, let journal else { return }
        working = true; confirmed = false; error = nil
        defer { working = false }
        do {
            status = "Removing this operation's inactive console files…"
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.discardInactive(operationID: journal.operationID,
                                                       device: LegacySyncLeaseDevice(lease: lease))
                await lease.release()
                self.journal = nil; plan = nil; manifest = nil
                if mode != .full || fullReview == nil { backup = nil }
                operationID = nil; observation = nil
                status = "Inactive transfer discarded. The old menu was left in place."
            } catch { await lease.release(); throw error }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func rollback() async {
        guard !working, rollbackConfirmed, canRollback, sameSession,
              let client = appState.deviceManager.legacyClient, let journal else { return }
        working = true; rollbackConfirmed = false; acceptanceConfirmed = false; error = nil
        defer { working = false }
        do {
            status = "Restoring the retained old menu tree…"
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.rollback(operationID: journal.operationID,
                                               device: LegacySyncLeaseDevice(lease: lease))
                self.journal = try await LegacySyncJournalStore(directory: workspace.journals)
                    .load(journal.operationID)
                observation = nil
                status = "Old menu restored. Check the HDMI menu and controller."
                await lease.release()
                await appState.refreshLegacyLibraryAfterChange()
            } catch { await lease.release(); throw error }
        } catch {
            self.error = error.localizedDescription
            status = "Rollback result needs inspection. Leave the NES connected."
        }
    }

    @MainActor private func resumeAcceptance() async {
        guard !working, acceptanceConfirmed, canResumeAcceptance, sameSession,
              let client = appState.deviceManager.legacyClient, let journal else { return }
        working = true; rollbackConfirmed = false; acceptanceConfirmed = false; error = nil
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.resumeAcceptance(operationID: journal.operationID,
                    mainMenuConfirmed: true, device: LegacySyncLeaseDevice(lease: lease))
                self.journal = try await LegacySyncJournalStore(directory: workspace.journals)
                    .load(journal.operationID)
                observation = nil
                status = mode == .full ? "Working library verified. Review the menu again before accepting."
                                       : "Working trial verified. You can accept it after reviewing the menu again."
                await lease.release()
            } catch { await lease.release(); throw error }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func finishAcceptance() async {
        guard !working, confirmed, canFinishAcceptance, sameSession,
              let client = appState.deviceManager.legacyClient, let journal else { return }
        working = true; confirmed = false; error = nil
        defer { working = false }
        do {
            let lease = try await client.reserveForChange()
            do {
                let transaction = LegacySyncTransaction(
                    store: LegacySyncJournalStore(directory: workspace.journals), workspace: workspace)
                try await transaction.reconcileAccepted(operationID: journal.operationID,
                    mainMenuConfirmed: true, device: LegacySyncLeaseDevice(lease: lease))
                self.journal = try await LegacySyncJournalStore(directory: workspace.journals)
                    .load(journal.operationID)
                observation = nil
                status = mode == .full ? "The NES had already accepted the library. The Mac record now matches."
                                       : "The NES had already accepted the trial. The Mac record now matches."
                await lease.release()
                await appState.refreshLegacyLibraryAfterChange()
            } catch { await lease.release(); throw error }
        } catch { self.error = error.localizedDescription }
    }
}
