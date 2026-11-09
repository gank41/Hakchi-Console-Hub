import Foundation
import Combine
import SwiftHakchiCore

/// One foreground workflow owns USB. Each native operation still enforces its own checked context and journal permit.
@MainActor final class SNESLibrarySyncModel: ObservableObject {
    @Published private(set) var phase: SNESLibraryWorkflowPhase = .reading
    @Published private(set) var draft: SNESLibraryReviewDraft?
    @Published private(set) var graph: ConsoleMenuGraph?
    @Published private(set) var compatibilityLayoutOnly = false
    @Published private(set) var projection: SNESLibraryCapacity?
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var message = ""
    @Published private(set) var detail: String?
    @Published private(set) var backupDirectory: URL?
    @Published private(set) var reclaimBytes: Int64 = 0
    @Published private(set) var addedGames = 0
    @Published private(set) var removedGames = 0
    @Published private(set) var totalGames = 0
    @Published var createFinalBackup = false
    @Published private(set) var isReturningPrevious=false
    @Published private var canReturnToPrevious=false
    private var rollbackReview:SNESLibraryInventory?
    let originalsOnly: Bool
    let restoreSnapshot: SNESLibrarySnapshotReference?
    let replacementSnapshot: SNESLibrarySnapshotReference?
    private var restoredMenu: SNESLibraryMenu?, restoreSource: SNESLibraryBackup?
    var isRestoringReplacement: Bool { replacementSnapshot != nil }
    var isRestoringSavedGames: Bool { restoreSnapshot != nil || replacementSnapshot != nil }
    var originalGameCount: Int { records?.installation.originals.frame.entries.count ?? 0 }
    private weak var app: AppState?
    private let workspace: WorkspacePaths
    private var records: SNESLibraryOwnerRecords?
    private var session: SNESLibraryConnectionSession?, context: SNESLibraryContext?, observation: SNESLibraryObservation?
    private var journal: SNESLibraryJournal?, operation: URL?, plan: SNESLibrarySyncPlan?, scope: SNESLibraryCleanupPlan?, cleanup: SNESLibraryCleanupObservation?
    private var discardReview: SNESLibraryConnectionSession.DiscardReview?
    private enum BackupContinuation { case prepare, confirmTest, inspect, deferredCleanup }
    private var backupContinuation = BackupContinuation.prepare, backupCreationApproved = false
    private var unownedMaterial: SNESLibraryMaterial?
    private var reviewedFingerprint: String?
    private var navigation: SNESLibraryMenu.NavigationArtwork?
    private var ownsConnection = false, closed = false
    private var pendingReviewContext: SNESLibraryContext?
    private var deferredBackupForReuse: SNESLibraryBackup?
    private var approvedRecoveryBackupForReview = false
    init(app: AppState, originalsOnly: Bool = false, restoreSnapshot: SNESLibrarySnapshotReference? = nil,
         replacementSnapshot: SNESLibrarySnapshotReference? = nil) {
        self.app = app; self.originalsOnly = originalsOnly; self.restoreSnapshot = restoreSnapshot
        self.replacementSnapshot = replacementSnapshot; workspace = AppConfig.shared.workspace
    }
    var canRetryOpening: Bool { phase == .interrupted && journal == nil }
    var canInspectInterruptedSync: Bool { phase == .interrupted && journal != nil && plan != nil }
    var canReviewDiscard: Bool { [.interrupted, .copied].contains(phase) && journal != nil && plan != nil && !canReviewPreviousGames }
    var canReviewPreviousGames:Bool {canReturnToPrevious && [.testing,.restart,.interrupted].contains(phase) && journal != nil && plan != nil}
    var selectedGameCount: Int { restoredMenu?.description.placements.filter { $0.kind == "import" }.count ?? plan?.material.menu.description.placements.filter { $0.kind == "import" }.count ?? draft?.effectiveImportCount ?? 0 }
    private func fail(_ text: String) -> SyncPlanError { .invalidInput(text) }
    private func binding() async throws -> (SNESLibraryConnectionSession, SNESLibraryContext) {
        guard !closed else { throw CancellationError() }
        if let session, let context {
            try await session.requireCurrent(context); return (session, context)
        }
        guard let records else { throw fail("Connect the SNES, then reopen Sync Library.") }
        try records.installation.validate(); try records.index.validate()
        let attachments = try RecoveryProbeUSBRegistry.inventory()
        guard let attachment = ConsoleAttachmentPolicy.single(attachments), ConsoleAttachmentPolicy.kind(of: attachment) == .nativeSNES else {
            throw fail("Connect only the SNES and leave it at the game-selection menu.")
        }
        let source = SNESLibraryConnectionSession(attachment: attachment, io: NativeSNESLibraryIO(attachment: attachment))
        let value = try await source.connect(sessionID: UUID()) { hwid, version in
            try records.installation.validate(); try records.index.validate()
            guard records.installation.expected.hwid == hwid, records.installation.expected.deviceVersion == version else { throw SNESLibraryInstallation.failure() }
            return records
        }
        guard !closed, !Task.isCancelled else { await source.disconnect(); throw CancellationError() }
        session = source; context = value; return (source, value)
    }
    func start() async {
        guard let app else { return }
        do {
            guard let current = app.deviceManager.nativeSNESContext, let reader = app.deviceManager.nativeSNES else { throw fail("Connect your SNES before opening Sync Library.") }
            try await reader.requireCurrent(current)
            records = try current.ownerRecords()
            pendingReviewContext = current
            if current.supportsLibraryRecovery, try await openPendingReview(current) {
                guard try await journal?.phase() == .finishedKeepingPrevious else { return }
                phase = .deferredReady
                message = "Before this sync, the app will back up your current console and remove the previous sync’s old copy. Your current games and saves stay."
                return
            }
            try await openReview(current, app: app)
        } catch is SNESLibraryBackupCreationRequired {
            backupCreationApproved = false; phase = .backupNeeded; detail = nil
            message = "A recovery backup is needed before the previous console copy can be removed. Choose Back Up Now and Review to continue."
        } catch {
            await session?.disconnect(); session = nil; context = nil
            phase = .interrupted; detail = error.localizedDescription; message = "The SNES review could not be opened. Your saved recovery files are kept."
        }
    }
    private func openReview(_ current: SNESLibraryContext, app: AppState) async throws {
            let originals = current.installation.originals.frame
            guard restoreSnapshot == nil || replacementSnapshot == nil else { throw fail("Choose one saved library to review.") }
            if let snapshot = replacementSnapshot ?? restoreSnapshot {
                guard !originalsOnly else { throw fail("Choose either a saved library or the original games.") }
                try SNESLibraryBackupHistory.requireLocation(snapshot.directory, workspace: workspace)
                let saved = try snapshot.reopen()
                let material = try SNESLibraryRestore.prepareForSync(backup: saved, originals: originals,
                    destinationHWID: current.installation.expected.hwid, scope: isRestoringReplacement ? .replacementConsole : .sameConsole)
                restoredMenu = try material.menu ?? SNESLibraryMenu.originalGames(originals: originals)
                restoreSource = saved
            }
            let games = originalsOnly || isRestoringSavedGames ? [] : app.gameManager.games.filter { $0.source == .local && $0.consoleType == .snesUsa && $0.isSelected }
            let compatibility = try SNESLibraryCompatibility.review(games: games, originals: originals)
            let cache = try SNESLibraryObjectCache.prepare(review: compatibility)
            draft = try .init(review: compatibility, originals: originals, cache: cache, selected: Set(games.filter(\.isSelected).map(\.code)),
                structure: AppConfig.shared.structure(for: .snesUsa), order: .title)
            navigation = try SNESLibraryNavigationArtwork.standard()
            if !current.supportsLibrarySync || !current.supportsNativeArtwork {
                phase = .needsSetup; message = "This SNES needs setup before games can be synced. Open Set Up SNES to review the preview setup steps. Your console has not been changed."
                rebuildPreview(); return
            }
            if !ownsConnection { await app.deviceManager.pauseForRecovery(); ownsConnection = true }
            let (source, value) = try await binding()
            let observed = try await source.observe(value)
            observation = observed; freeBytes = observed.capacity.freeBytes
            phase = .review
            message = isRestoringReplacement ? "Review games and folders from the other SNES. Saved-game progress is not copied yet; saves already on this console are kept." : isRestoringSavedGames ? "Restore this saved game library and its folders. Keep the saves and settings currently on your console and leave your Mac library unchanged." : originalsOnly ? "Show only the console’s original games. Your added games are backed up on the Mac before this change; saves and your Mac library stay." : "Review your selected games and console folders."
            rebuildPreview()
    }
    /// Retry only opening a review; interrupted writes always use the saved-operation inspection instead.
    func retryOpening() async {
        guard canRetryOpening, let app else { return }
        phase = .reading; detail = nil
        await session?.disconnect(); session = nil; context = nil
        if ownsConnection { ownsConnection = false; app.deviceManager.resumeAfterExclusive() }
        guard await app.deviceManager.reconnect() else {
            phase = .interrupted; message = "Connect the SNES and leave its game-selection menu visible, then try again."
            detail = app.deviceManager.lastConnectionError; return
        }
        await start()
    }
    private func openPendingReview(_ current: SNESLibraryContext) async throws -> Bool {
        let root = try SNESLibraryJournalPolicy.ensureRoot()
        guard let pending = try SNESLibraryJournal.pending(root: root, hwid: current.installation.expected.hwid) else { return false }
        if pending.phase == .prepared {
            try SNESLibraryJournal.closeUnsentReview(operation: pending.operation, reviewSHA256: pending.reviewSHA256)
            return false
        }
        let raw = try RestoreDirectory(pending.operation).read("plan.json", maximum: 24 * 1024 * 1024)
        let saved = try SNESLibrarySyncPlan.load(data: raw, expectedReviewSHA256: pending.reviewSHA256,
            originals: current.installation.originals.frame, purpose: .recovery)
        guard let app else { throw CancellationError() }
        await app.deviceManager.pauseForRecovery(); ownsConnection = true
        journal = try .init(operation: pending.operation, reviewSHA256: saved.reviewSHA256, plan: saved)
        plan = saved; operation = pending.operation; graph = saved.material.menu.graph; compatibilityLayoutOnly = false
        backupDirectory = pending.backupReference?.directory ?? saved.backup.directory
        totalGames = saved.material.menu.description.stock.count + selectedGameCount
        phase = .interrupted
        message = "An earlier sync is unfinished. Check what reached the console before continuing. Games will not be copied again automatically."
        return true
    }
    /// Reads the saved operation before offering its next step; this never retries a transfer or menu write.
    func inspectInterruptedSync() async {
        guard canInspectInterruptedSync, let records else { return }
        phase = .reading; detail = nil;canReturnToPrevious=false
        do {
            try await useFrozenPlan()
            guard let plan, let journal else { throw fail("The saved sync review is missing.") }
            await session?.disconnect(); session = nil; context = nil
            let (source, value) = try await binding()
            switch try await journal.phase() {
            case .finishedKeepingPrevious:
                phase = .deferredReady
                message = "Before the next sync, the app needs to safely remove the previous game-menu copy. Leave the SNES at its game menu, then choose Continue Sync."
            case .rollbackIntent,.rollbackUncertain,.rollbackAwaitingRestart:
                isReturningPrevious=true
                if try await journal.phase() == .rollbackIntent {try await journal.rollbackUncertain()}
                let observed=try await source.observe(value)
                if observed.inventory.selection == plan.before.selection {
                    let previous=try await journal.rollbackAttachment()
                    if value.attachment.registryEntryID != previous.registryEntryID {
                        let proof=try await source.verifyRestarted(plan:plan,previousAttachment:previous,destination:.previous)
                        try await journal.noteRolledBack(proof);try await showReturnedCopyReview(source)
                    } else {phase = .rollbackRestart;message="The console is set to show your previous games. Restart the SNES normally to see them on your TV."}
                } else {
                    try SNESLibraryActiveCheck.require(plan,inventory:observed.inventory,preserveProfiles:false)
                    canReturnToPrevious=true;phase = .interrupted
                    message="The earlier return stopped before changing the console’s game menu. Review Return to Previous Games for a new attempt."
                }
                freeBytes=observed.capacity.freeBytes
            case .rolledBack:
                isReturningPrevious=true;try await showReturnedCopyReview(source)
            case .copyIntent, .copyUncertain:
                let permit = try await journal.reconciliation()
                _ = try await source.observe(value, reconciliation: permit)
                // Only the normal, complete inventory can prove the inactive copy is ready.
                let observed = try await source.observe(value)
                try await journal.recordInspectedCopy(observed.inventory)
                freeBytes = observed.capacity.freeBytes; phase = .copied
                message = "The copied games have been checked. Choose Show Updated Games to set up the console’s game menu. The sync is not finished yet."
            case .copied:
                let observed = try await source.observe(value)
                try SNESLibraryInactiveCheck.require(plan, inventory: observed.inventory)
                freeBytes = observed.capacity.freeBytes; phase = .copied
                message = "The copied games have been checked. Choose Show Updated Games to set up the console’s game menu. The sync is not finished yet."
            case .selectionIntent, .selectionUncertain:
                do {
                    let observed = try await source.observe(value)
                    if observed.inventory.selection == plan.before.selection {
                        try await journal.recordInspectedCopy(observed.inventory)
                        phase = .copied; message = "The console is still set to show the previous games. The copied games are ready; choose Show Updated Games to continue."
                    } else {
                        try SNESLibraryActiveCheck.require(plan, inventory: observed.inventory, preserveProfiles: false)
                        canReturnToPrevious=true;phase = .restart; message = "The updated console game menu is ready. Restart the SNES normally to show it on your TV."
                    }
                    freeBytes = observed.capacity.freeBytes
                } catch {
                    await session?.disconnect(); session = nil; context = nil
                    let (freshSource, _) = try await binding(), permit = try await journal.reconciliation()
                    let review = try await freshSource.reviewDiscard(plan: plan, reconciliation: permit)
                    discardReview = review; reclaimBytes = review.preview.presentFileBytes; freeBytes = review.preview.freeBytes
                    phase = .readyToDiscard
                    message = "An unfinished menu setting stopped this change. Remove the unshown copy to start again; your playable games and saves stay."
                }
            case .awaitingRestart:
                let observed = try await source.observe(value)
                try SNESLibraryActiveCheck.require(plan, inventory: observed.inventory, preserveProfiles: false)
                freeBytes = observed.capacity.freeBytes;canReturnToPrevious=true;phase = .restart
                message = "The updated console game menu is ready. Restart the SNES normally to show it on your TV."
            case .awaitingTest:
                let previous = try await journal.restartAttachment()
                if value.attachment != previous {
                    let proof = try await source.verifyRestarted(plan: plan, previousAttachment: previous)
                    try await journal.noteRestarted(proof)
                } else {
                    let observed = try await source.observe(value)
                    try SNESLibraryActiveCheck.require(plan, inventory: observed.inventory, preserveProfiles: false)
                    freeBytes = observed.capacity.freeBytes
                }
                canReturnToPrevious=true;phase = .testing; message = "Your updated game menu is ready. Choose whether to save an additional backup, then finish syncing."
            case .discardIntent, .discardUncertain:
                if try await journal.phase() == .discardIntent { try await journal.discardUncertain() }
                let permit = try await journal.reconciliation()
                let review = try await source.reviewDiscard(plan: plan, reconciliation: permit)
                if review.preview.allGone {
                    let final = try await source.observe(value, reconciliation: permit)
                    try await journal.recordInspectedDiscard(scope: review.scope, preview: review.preview, inventory: final.inventory)
                    freeBytes = final.capacity.freeBytes; phase = .cancelled
                    message = "The unfinished copy is removed. Your previous games and saves remain on the console."
                } else {
                    discardReview = review; reclaimBytes = review.preview.presentFileBytes; freeBytes = review.preview.freeBytes
                    phase = .readyToDiscard; message = "Review removal of the remaining unfinished copy. Your playable games will stay."
                }
            case .accepted, .cleanupIntent, .cleanupUncertain:
                if try await journal.phase() == .cleanupIntent { try await journal.cleanupUncertain() }
                let permit = try await journal.reconciliation()
                let reference = try await journal.currentBackup()
                guard let reference else { throw fail("Locate this sync's Mac backup before continuing.") }
                let accepted = try reference.reopen(), before = try await source.observe(value, reconciliation: permit)
                phase = .savingBackup
                try workspace.requireActiveBackupsAvailable()
                try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                backupContinuation = .inspect
                let current = try await source.captureBackup(before, root: workspace.backups, material: plan.material, reusing: [accepted, plan.backup], allowCreation: AppConfig.shared.automaticallyCreateMissingBackup || backupCreationApproved)
                backupCreationApproved = false
                let fresh = try await source.observe(value, reconciliation: permit)
                try await journal.accept(backup: current, originals: records.installation.originals.frame, current: fresh.inventory)
                let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: fresh.inventory, backup: current, originals: records.installation.originals.frame)
                let updatedPermit = try await journal.reconciliation()
                let preview = try await source.previewCleanup(plan: plan, scope: scope, reconciliation: updatedPermit)
                self.scope = scope; cleanup = preview; backupDirectory = current.directory; reclaimBytes = preview.presentFileBytes
                freeBytes = preview.freeBytes; phase = .readyToFinish
                message = "Your current games and saves are backed up on the Mac. Finish syncing to remove the older console copy."
            default: throw fail("Close this review and reopen Sync Library to read its current status.")
            }
            if phase.isTerminal { await clearFinishedCache() }
        } catch is SNESLibraryBackupCreationRequired {
            backupCreationApproved = false; phase = .backupNeeded; detail = nil
            message = "A current Mac backup is required before continuing. Choose Back Up Now and Review to create it. Your console has not been changed by this check."
        } catch {
            backupCreationApproved = false
            await session?.disconnect(); session = nil; context = nil
            phase = .interrupted; detail = error.localizedDescription
            message = "The unfinished sync could not be verified. Its Mac backup and saved operation are kept. No transfer or menu write was retried."
        }
    }
    func reviewDiscardCopy() async {
        guard canReviewDiscard else { return }
        phase = .reading; detail = nil; discardReview = nil
        do {
            try await useFrozenPlan()
            guard let plan, let journal else { throw fail("The saved sync review is missing.") }
            let state = try await journal.phase()
            guard [.copyIntent, .copyUncertain, .copied, .selectionIntent, .selectionUncertain, .discardIntent, .discardUncertain].contains(state) else {
                throw fail("This menu may already be in use. Check Unfinished Sync to finish it or restore a Mac backup.")
            }
            if state == .discardIntent { try await journal.discardUncertain() }
            let (source, _) = try await binding(), permit = try await journal.reconciliation()
            let review = try await source.reviewDiscard(plan: plan, reconciliation: permit)
            discardReview = review; reclaimBytes = review.preview.presentFileBytes; freeBytes = review.preview.freeBytes
            phase = .readyToDiscard; message = "Remove only the unfinished copy. Your currently playable games and saves stay on the console."
        } catch {
            await session?.disconnect(); session = nil; context = nil
            phase = .interrupted; detail = error.localizedDescription
            message = "The unfinished copy could not be reviewed. Nothing was removed."
        }
    }
    private func discardCopy() async throws {
        guard let plan, let journal, let review = discardReview else { throw fail("Review the unfinished copy before removing it.") }
        phase = .discarding
        let (source, _) = try await binding()
        let result = try await SNESLibraryDiscardTransaction.run(plan: plan, journal: journal, scope: review.scope, preview: review.preview, device: source)
        freeBytes = result.inventory.capacity.freeBytes; discardReview = nil; session = nil; context = nil
        phase = .cancelled; message = "The unfinished copy is removed. Your previous games and saves remain on the console."
    }
    private func clearPrepared() async throws {
        if let journal {
            guard try await journal.phase() == .prepared else { throw fail("Finish or recover the current sync before changing this review.") }
            try await journal.cancelUnstarted(); try? await journal.purgePreparedMaterial(); try await journal.close()
        }
        journal = nil; plan = nil; operation = nil; reviewedFingerprint = nil
    }
    func select(_ code: String, selected: Bool) async {
        guard phase.canEdit, var value = draft else { return }
        do {
            try await clearPrepared(); try value.setSelected(code, selected: selected); draft = value; phase = .review
            app?.gameManager.setSelection(selected, codes: [code]); detail = nil; rebuildPreview()
        } catch { detail = error.localizedDescription }
    }
    func selectAll(_ selected: Bool) async {
        guard phase.canEdit, var value = draft else { return }
        do {
            try await clearPrepared()
            for row in value.review.rows { try value.setSelected(row.game.code, selected: selected) }
            draft = value; phase = .review; app?.gameManager.setSelection(selected, codes: Set(value.review.rows.map { $0.game.code })); rebuildPreview()
        } catch { detail = error.localizedDescription }
    }
    func decide(_ code: String, choice: SNESLibraryCompatibility.Resolution?) async {
        guard phase.canEdit, var value = draft else { return }
        do { try await clearPrepared(); try value.setDecision(code, resolution: choice); draft = value; phase = .review; rebuildPreview() }
        catch { detail = error.localizedDescription }
    }
    func keepBuiltIns() async {
        guard phase.canEdit, var value = draft else { return }
        do {
            try await clearPrepared()
            for row in value.review.rows where !row.matches.isEmpty { try value.setDecision(row.game.code, resolution: .keepBuiltIn) }
            draft = value; phase = .review; rebuildPreview()
        } catch { detail = error.localizedDescription }
    }
    func skipUnavailable(_ skip: Bool) async {
        guard phase.canEdit, var value = draft else { return }
        do { try await clearPrepared(); value.setAllowSkippingUnavailable(skip); draft = value; phase = .review; rebuildPreview() }
        catch { detail = error.localizedDescription }
    }
    func setMode(_ mode: ConsoleStructure.Mode) async {
        guard phase.canEdit, var value = draft else { return }
        do {
            try await clearPrepared(); var structure = value.structure; structure.mode = mode; value.setStructure(structure)
            try AppConfig.shared.setStructure(structure, for: .snesUsa); AppConfig.shared.save()
            draft = value; phase = .review; rebuildPreview()
        } catch { detail = error.localizedDescription }
    }
    func setLimit(_ limit: ConsoleMenuLimit) async {
        guard phase.canEdit, var value = draft else { return }
        do {
            try await clearPrepared(); var structure = value.structure; structure.maximumGamesPerPage = limit; value.setStructure(structure)
            try AppConfig.shared.setStructure(structure, for: .snesUsa); AppConfig.shared.save()
            draft = value; phase = .review; rebuildPreview()
        } catch { detail = error.localizedDescription }
    }
    var stockCodes: Set<String> { draft?.review.stockCodes ?? [] }
    var previewGames: [Game] {
        let local = draft?.review.rows.map(\.game) ?? []
        let stock = records?.installation.originals.frame.entries.compactMap { entry -> Game? in
            guard let desktop = entry.files.first(where: { $0.name == entry.code + ".desktop" }), let text = String(data: desktop.data, encoding: .utf8) else { return nil }
            return Game(code: entry.code, desktopContent: text, consoleType: .snesUsa, source: .stock)
        } ?? []
        return local + stock
    }
    func useSavedStructure() async {
        guard phase.canEdit, var value = draft else { return }
        do { try await clearPrepared(); value.setStructure(AppConfig.shared.structure(for: .snesUsa)); draft = value; phase = .review; rebuildPreview() }
        catch { detail = error.localizedDescription }
    }
    func setOrder(_ order: ConsoleMenuOrder) async {
        guard phase.canEdit, var value = draft else { return }
        do { try await clearPrepared(); value.setOrder(order); draft = value; phase = .review; rebuildPreview() }
        catch { detail = error.localizedDescription }
    }
    private func reviewedMenu() throws -> SNESLibraryMenu {
        if let restoredMenu { return try restoredMenu.withNativeArtwork() }
        if originalsOnly {
            guard let records else { throw fail("Reconnect the console before reviewing its original games.") }
            return try SNESLibraryMenu.originalGames(originals: records.installation.originals.frame).withNativeArtwork()
        }
        guard let draft else { throw fail("Refresh the selected games before reviewing this sync.") }
        return try draft.menu(artwork: navigation).withNativeArtwork()
    }
    private func rebuildPreview() {
        guard let draft else { return }
        do {
            let menu = try reviewedMenu(); graph = menu.graph; compatibilityLayoutOnly = false
            if let observation { projection = try SNESLibraryCapacity.project(menu: menu, inventory: observation.capacity, expectedContext: observation.context.sha256) }
            else { projection = nil }
            detail = nil
        } catch {
            projection = nil; detail = error.localizedDescription
            if !originalsOnly && !isRestoringSavedGames, let layout = try? draft.compatibilityLayoutPreview() {
                graph = layout; compatibilityLayoutOnly = true
            } else { graph = nil; compatibilityLayoutOnly = false }
        }
    }
    func refreshSpace() async {
        guard phase.canEdit else { return }
        do {
            try await clearPrepared(); phase = .reading
            let (source, value) = try await binding(), observed = try await source.observe(value)
            observation = observed; freeBytes = observed.capacity.freeBytes; phase = .review; rebuildPreview()
        } catch { phase = .review; detail = error.localizedDescription }
    }
    func perform() async {
        guard let action = phase.action, action != .close else { return }
        detail = nil
        do {
            switch action {
            case .rollback: try await returnPreviousGames()
            case .checkRollbackRestart: try await checkPreviousRestart()
            case .prepare: try await prepare()
            case .clearDeferred:
                try await clearPreviousCopyForNextSync()
                guard let current = pendingReviewContext, let app else { throw fail("Reconnect the SNES and reopen Sync Library.") }
                try await openReview(current, app: app)
            case .createBackup:
                backupCreationApproved = true
                switch backupContinuation {
                case .prepare: phase = .review; try await prepare()
                case .confirmTest: try await confirmTest()
                case .inspect: phase = .interrupted; await inspectInterruptedSync()
                case .deferredCleanup:
                    try await clearPreviousCopyForNextSync()
                    guard let current = pendingReviewContext, let app else { throw fail("Reconnect the SNES and reopen Sync Library.") }
                    try await openReview(current, app: app)
                }
            case .copy: try await copy()
            case .show: try await show()
            case .checkRestart: try await checkRestart()
            case .confirmTest: try await confirmTest()
            case .finish: try await finish()
            case .discard: try await discardCopy()
            case .close: break
            }
            if phase.isTerminal { await clearFinishedCache() }
        } catch is SNESLibraryBackupCreationRequired {
            backupCreationApproved = false; phase = .backupNeeded; detail = nil
            message = "A current Mac backup is required before continuing. Choose Back Up Now and Review to create it. Your console has not been changed by this step."
        } catch {
            backupCreationApproved = false
            if let unused = unownedMaterial {
                try? SNESLibraryJournal.discardUnsentMaterial(unused, root: unused.directory.deletingLastPathComponent().deletingLastPathComponent())
                unownedMaterial = nil
            }
            await session?.disconnect(); session = nil; context = nil
            detail = error.localizedDescription
            if let journal, (try? await journal.phase()) == .prepared { phase = .ready }
            else { phase = .interrupted }
            message = "This step did not complete. Your Mac backup and sync record are kept."
        }
    }
    private func prepare() async throws {
        guard phase == .review, let draft, let records else { throw fail("Refresh the review before preparing this sync.") }
        phase = .preparing
        try restoreSource?.validate()
        let menu = try reviewedMenu(), root = try SNESLibraryJournalPolicy.ensureRoot(), materials = root.appendingPathComponent("Prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let (source, value) = try await binding(); guard value.supportsLibrarySync && value.supportsNativeArtwork else { throw fail("Update the SNES setup before copying games.") }
        try workspace.requireActiveBackupsAvailable()
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let before = try await source.observe(value), roots = workspace.knownBackupRoots
        let matching = try await Task.detached { try SNESLibraryBackup.matching(inventory: before.inventory, roots: roots) }.value
        backupContinuation = .prepare
        let backup = try await source.captureBackup(before, root: workspace.backups, reusing: [matching, deferredBackupForReuse].compactMap { $0 }, allowCreation: AppConfig.shared.automaticallyCreateMissingBackup || backupCreationApproved || approvedRecoveryBackupForReview)
        backupCreationApproved = false
        approvedRecoveryBackupForReview = false; deferredBackupForReuse = nil
        let fresh = try await source.observe(value)
        // Don't create a full temporary ROM package for a failed read or an unanswered backup decision.
        let material = try SNESLibraryMaterial.freeze(menu: menu, in: materials)
        unownedMaterial = material
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: fresh.inventory, capacity: fresh.capacity,
            installation: records.installation.reference, originals: records.installation.originals.frame)
        guard plan.projection.canFit else { throw fail("Uncheck some games to make room for this copy, then review again.") }
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: root)
        journal = try .init(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        let oldCodes = Set(fresh.inventory.files.compactMap { file -> String? in
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            guard name.hasPrefix("CLV-U-"), name.hasSuffix(".desktop") else { return nil }; return String(name.dropLast(8))
        })
        let newCodes = Set(menu.description.placements.filter { $0.kind == "import" }.map(\.code))
        addedGames = newCodes.subtracting(oldCodes).count; removedGames = oldCodes.subtracting(newCodes).count
        totalGames = menu.description.stock.count + newCodes.count
        self.plan = plan; operation = prepared.operation; reviewedFingerprint = draft.fingerprint; unownedMaterial = nil
        observation = fresh; projection = plan.projection; backupDirectory = backup.directory; freeBytes = fresh.capacity.freeBytes
        phase = .ready; message = "The reviewed games fit. Your current console library is backed up on the Mac."
    }
    private func copy() async throws {
        guard let plan, let journal, draft?.fingerprint == reviewedFingerprint else { throw fail("Your selection changed. Review it again before copying.") }
        phase = .copying
        let (source, _) = try await binding()
        let result = try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: source)
        freeBytes = result.after.capacity.freeBytes; projection = nil
        session = nil; context = nil; observation = nil
        // Finish the exact bytes already copied, independent of later edits to the editable library.
        try await useFrozenPlan()
        phase = .copied; message = "The games are copied and checked. Choose Show Updated Games to set up the console’s game menu. The sync is not finished yet."
    }
    private func useFrozenPlan() async throws {
        guard let old = plan, let operation, let records else { throw fail("The saved sync review is missing.") }
        try await journal?.close(); journal = nil
        let frozen = try SNESLibrarySyncPlan.load(data: old.data, expectedReviewSHA256: old.reviewSHA256, originals: records.installation.originals.frame, purpose: .recovery)
        plan = frozen; journal = try .init(operation: operation, reviewSHA256: frozen.reviewSHA256, plan: frozen)
    }
    /// Read-only review; the later confirmed action obtains its own fresh native state.
    func reviewPreviousGames() async {
        guard canReviewPreviousGames else {return}
        phase = .reading;detail=nil;canReturnToPrevious=false
        do {
            try await useFrozenPlan()
            guard let plan,let journal else {throw fail("The saved sync review is missing.")}
            let (source,value)=try await binding(),observed=try await source.observe(value)
            try SNESLibraryActiveCheck.require(plan,inventory:observed.inventory,preserveProfiles:false)
            if try await journal.phase() == .selectionIntent {try await journal.selectionUncertain()}
            if try await journal.phase() == .rollbackIntent {try await journal.rollbackUncertain()}
            rollbackReview=observed.inventory;freeBytes=observed.capacity.freeBytes;backupDirectory=plan.backup.directory
            isReturningPrevious=true;phase = .readyToRollback
            message="Return to the game menu from before this sync. Games and saves stay on the console. You will restart normally afterward, then review removal of the unfinished copy."
        } catch {
            await session?.disconnect();session=nil;context=nil;phase = .interrupted;detail=error.localizedDescription
            message="The previous-menu review stopped. Check this unfinished sync before trying another action."
        }
    }
    private func returnPreviousGames() async throws {
        guard let plan,let journal,let review=rollbackReview else {throw fail("Review the return to previous games first.")}
        phase = .returningPrevious;canReturnToPrevious=false
        let (source,_)=try await binding()
        _=try await SNESLibraryRollbackTransaction.run(plan:plan,journal:journal,device:source,review:review)
        session=nil;context=nil;rollbackReview=nil;phase = .rollbackRestart
        message="The console is set to show your previous games. Restart the SNES normally to see them on your TV."
    }
    private func showReturnedCopyReview(_ source:SNESLibraryConnectionSession) async throws {
        guard let plan,let journal else {throw fail("The saved sync review is missing.")}
        let permit=try await journal.reconciliation(),review=try await source.reviewDiscard(plan:plan,reconciliation:permit)
        discardReview=review;reclaimBytes=review.preview.presentFileBytes;freeBytes=review.preview.freeBytes
        isReturningPrevious=true;phase = .readyToDiscard
        message="Your previous menu is checked. Review removal of the unfinished sync copy; your playable games and saves stay."
    }
    private func checkPreviousRestart() async throws {
        guard let plan,let journal else {throw fail("The saved sync review is missing.")}
        phase = .checkingRestart
        let (source,_)=try await binding(),previous=try await journal.rollbackAttachment()
        let proof=try await source.verifyRestarted(plan:plan,previousAttachment:previous,destination:.previous)
        try await journal.noteRolledBack(proof)
        try await showReturnedCopyReview(source)
    }
    private func show() async throws {
        guard let plan, let journal else { throw fail("The saved sync review is missing.") }
        phase = .savingSelection; let (source, _) = try await binding()
        _ = try await SNESLibrarySelectionTransaction.run(plan: plan, journal: journal, device: source)
        session = nil; context = nil
        phase = .restart; message = "Restart the SNES normally to show the updated game menu on your TV. Then return here to continue."
    }
    private func checkRestart() async throws {
        guard let plan, let journal else { throw fail("The saved sync review is missing.") }
        phase = .checkingRestart; let (source, _) = try await binding()
        let previous = try await journal.restartAttachment()
        let proof = try await source.verifyRestarted(plan: plan, previousAttachment: previous)
        try await journal.noteRestarted(proof)
        canReturnToPrevious=true;phase = .testing; message = "Your updated game menu is ready. Choose whether to save an additional backup, then finish syncing."
    }
    /// Reclaim the one deferred previous copy before starting a new sync. The
    /// ordinary current backup and the original cleanup checks remain required.
    private func clearPreviousCopyForNextSync() async throws {
        guard let plan, let journal, let records, try await journal.phase() == .finishedKeepingPrevious else {
            throw fail("The previous sync needs to be checked before continuing.")
        }
        phase = .clearingPrevious
        let (source, value) = try await binding()
        let before = try await source.observe(value)
        try SNESLibraryActiveCheck.require(plan, inventory: before.inventory, preserveProfiles: false)
        try workspace.requireActiveBackupsAvailable()
        try FileManager.default.createDirectory(at: workspace.backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let roots = workspace.knownBackupRoots
        let matching = try await Task.detached { try SNESLibraryBackup.matching(inventory: before.inventory, roots: roots) }.value
        backupContinuation = .deferredCleanup
        let current = try await source.captureBackup(before, root: workspace.backups, material: plan.material,
            reusing: [matching, plan.backup].compactMap { $0 }, allowCreation: AppConfig.shared.automaticallyCreateMissingBackup || backupCreationApproved)
        let approvedForReview = backupCreationApproved
        backupCreationApproved = false
        let fresh = try await source.observe(value)
        try await journal.accept(backup: current, originals: records.installation.originals.frame, current: fresh.inventory)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: fresh.inventory, backup: current, originals: records.installation.originals.frame)
        let preview = try await source.previewCleanup(plan: plan, scope: scope)
        if preview.allGone {
            let permit = try await journal.reconciliation()
            let inventory = try await source.observe(value, reconciliation: permit)
            let updated = try await source.previewCleanup(plan: plan, scope: scope, reconciliation: permit)
            try await journal.recordInspectedCleanup(scope: scope, preview: updated, inventory: inventory.inventory)
            freeBytes = updated.freeBytes
            await source.disconnect()
        } else {
            let result = try await SNESLibraryCleanupTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: source,
                refresh: {
                    let permit = try await journal.reconciliation()
                    return try await source.previewCleanup(plan: plan, scope: scope, reconciliation: permit)
                })
            freeBytes = result.after.freeBytes
        }
        session = nil; context = nil
        if let issue = try await journal.closeCompleted() { detail = issue }
        self.journal = nil; self.plan = nil; operation = nil; self.scope = nil; cleanup = nil
        deferredBackupForReuse = current; approvedRecoveryBackupForReview = approvedForReview
        backupDirectory = current.directory; canReturnToPrevious = false
    }
    private func confirmTest() async throws {
        guard let plan, let journal, let records else { throw fail("The saved sync review is missing.") }
        if !createFinalBackup {
            phase = .checkingCompletion
            let (source, value) = try await binding()
            let current = try await source.observe(value)
            try await journal.finishKeepingPrevious(current: current.inventory)
            freeBytes = current.capacity.freeBytes
            await source.disconnect(); session = nil; context = nil; canReturnToPrevious = false
            phase = .complete
            message = "Sync complete. Your updated games are ready. No additional backup was created. The previous console copy will be removed safely during your next sync. To change console setup or transfer saves first, open Sync Library and choose Continue Sync."
            return
        }
        phase = .savingBackup; let (source, value) = try await binding(), before = try await source.observe(value)
        backupContinuation = .confirmTest
        let current = try await source.captureBackup(before, root: workspace.backups, material: plan.material, reusing: [plan.backup], allowCreation: true)
        backupCreationApproved = false
        let fresh = try await source.observe(value)
        try await journal.accept(backup: current, originals: records.installation.originals.frame, current: fresh.inventory)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: plan, current: fresh.inventory, backup: current, originals: records.installation.originals.frame)
        let preview = try await source.previewCleanup(plan: plan, scope: scope)
        self.scope = scope; cleanup = preview; backupDirectory = current.directory; reclaimBytes = preview.presentFileBytes
        freeBytes = preview.freeBytes; phase = .readyToFinish
        message = "Your current games and saves are backed up. The app is finishing the sync."
        try await finish()
    }
    private func finish() async throws {
        guard let plan, let journal, let scope, let cleanup else { throw fail("Refresh the cleanup review before finishing.") }
        phase = .finishing; let (source, value) = try await binding()
        if cleanup.allGone {
            let permit = try await journal.reconciliation()
            let current = try await source.observe(value, reconciliation: permit)
            let fresh = try await source.previewCleanup(plan: plan, scope: scope, reconciliation: permit)
            try await journal.recordInspectedCleanup(scope: scope, preview: fresh, inventory: current.inventory)
            await source.disconnect(); session = nil; context = nil; freeBytes = fresh.freeBytes
            phase = .complete; message = "Sync complete. The temporary console files were already removed, and your Mac backup is kept."
            return
        }
        let result = try await SNESLibraryCleanupTransaction.run(plan: plan, journal: journal, scope: scope, preview: cleanup, device: source,
            refresh: {
                let reconciliation = try await journal.reconciliation()
                return try await source.previewCleanup(plan: plan, scope: scope, reconciliation: reconciliation)
            })
        session = nil; context = nil; freeBytes = result.after.freeBytes
        phase = .complete; message = "Sync complete. Your updated games are ready, and temporary console copies have been removed."
    }
    private func clearFinishedCache() async {
        guard let journal else { return }
        do { if let issue = try await journal.closeCompleted() { detail = issue }; self.journal = nil }
        catch { detail = "Your console change is complete and Mac backups are kept. Close this review before starting another operation." }
    }
    func close() async {
        guard !closed else { return }; closed = true
        if !phase.isBusy, let journal {
            if (try? await journal.phase()) == .prepared { try? await journal.cancelUnstarted() }
            if let state = try? await journal.phase(), state.isTerminal { try? await journal.purgePreparedMaterial() }
        }
        try? await journal?.close(); journal = nil
        await session?.disconnect(); session = nil; context = nil
        if ownsConnection, let app { ownsConnection = false; app.deviceManager.resumeAfterExclusive() }
    }
}
