import Foundation
import Darwin
import SwiftHakchiCore

/// A narrow device capability, so every write is a fixed legacy sync operation.
protocol LegacySyncDevice: Sendable {
    func requireLegacyIdentity() async throws
    func inspect() async throws -> LegacyConsoleReport
    func requireIdentity() async throws
    func chipID() async throws -> String
    func upload(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws
    func verify(_ manifest: LegacyMenuStageManifest, operationID: UUID,
                stageBudgetBytes: Int64) async throws
    func inventoryStage(operationID: UUID) async throws -> Data
    func activate(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws
    func accept(_ manifest: LegacyMenuStageManifest, operationID: UUID) async throws
    func inspectOperation(operationID: UUID, treeSHA256: String) async throws -> LegacySyncInspection
    func discard(operationID: UUID, treeSHA256: String) async throws
    func rollback(operationID: UUID, treeSHA256: String) async throws
}

/// Stage and activation are separate calls. The latter records durable intent before its first
/// remote mutation; any ambiguous result stays locked for explicit read-only inspection.
actor LegacySyncTransaction {
    struct UnboundIdentityReview: Sendable {
        let operationID: UUID
        let recordDigest: String
        let fingerprint: String
        let observation: LegacySyncInspection
    }
    private let store: LegacySyncJournalStore
    private let workspace: WorkspacePaths
    private var working = false

    init(store: LegacySyncJournalStore, workspace: WorkspacePaths) {
        self.store = store
        self.workspace = workspace
    }

    /// Review only: reads the local backup, chip ID and operation-specific
    /// console markers. It cannot prove the user's recollection of ownership.
    func reviewUnboundIdentity(operationID: UUID, device: any LegacySyncDevice) async throws -> UnboundIdentityReview {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        return try await unboundIdentityEvidence(operationID: operationID, device: device)
    }

    func bindUnboundIdentity(_ reviewed: UnboundIdentityReview, originalConsoleConfirmed: Bool,
                             device: any LegacySyncDevice,
                             isSessionCurrent: @MainActor @Sendable () -> Bool) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        guard originalConsoleConfirmed else { throw LegacySyncJournalError.invalidTransition }
        working = true; defer { working = false }
        let fresh = try await unboundIdentityEvidence(operationID: reviewed.operationID, device: device)
        guard fresh.recordDigest == reviewed.recordDigest,
              fresh.fingerprint == reviewed.fingerprint,
              Self.sameObservation(fresh.observation, reviewed.observation) else {
            throw LegacyChangeError.refused("The NES or saved operation changed. Review the original NES again; nothing was bound.")
        }
        try await MainActor.run {
            guard isSessionCurrent() else { throw LegacyInspectionError.disconnected }
            try store.bindReviewedIdentity(reviewed.operationID, fingerprint: fresh.fingerprint,
                                           expectedRecordDigest: fresh.recordDigest)
        }
    }

    private func unboundIdentityEvidence(operationID: UUID, device: any LegacySyncDevice) async throws -> UnboundIdentityReview {
        guard let record = try await store.latestUnresolved(), record.operationID == operationID,
              record.effectiveChipIDFingerprint == nil,
              workspace.containsBackup(record.backupDirectory) else {
            throw LegacySyncJournalError.invalidRecord
        }
        try Self.verifyJournalBackup(record)
        try await device.requireIdentity()
        let id = try await device.chipID()
        let fingerprint = BackupManifest.digest(Data(id.utf8))
        guard id.contains(where: { $0 != "0" }), LegacyDeviceIdentity.matches(id, fingerprint: fingerprint) else {
            throw LegacyInspectionError.invalidResponse
        }
        let sidecar = record.backupDirectory.appendingPathComponent(LegacyMenuSnapshot.filename)
        var sidecarInfo = stat()
        let sidecarStatus = lstat(sidecar.path, &sidecarInfo)
        if sidecarStatus == 0 {
            _ = try LegacyMenuSnapshot.verify(directory: record.backupDirectory, expectedChipID: id)
        } else if errno != ENOENT {
            throw LegacyInspectionError.invalidBackup
        }
        let state = try await device.inspectOperation(operationID: operationID, treeSHA256: record.treeSHA256)
        let staged = [.prepared, .uploaded, .verified, .activationIntent, .uncertain].contains(record.phase)
            && state.transaction && state.verified && state.archive && state.stage && state.live
            && !state.old && !state.failed && !state.lock && state.phase == .missing
        let switchingPhase = [.activationIntent, .uncertain].contains(record.phase)
        let lockedEarly = switchingPhase && state.transaction && state.lock && !state.failed
            && (([.ready, .stopped].contains(state.phase) && state.outcome == .beforeRename && state.stage) ||
                (state.phase == .oldMoved && state.outcome == .firstRenameUncertain && state.stage))
        let active = [.activationIntent, .uncertain, .activePendingAcceptance].contains(record.phase)
            && state.transaction && state.outcome == .newTreePresent && !state.failed
            && ((state.lock && [.newActive, .menuStarted].contains(state.phase)) ||
                (state.verified && !state.lock && state.phase == .accepted))
        let rolledBack = [.activationIntent, .uncertain, .activePendingAcceptance].contains(record.phase)
            && state.transaction && state.verified && !state.lock && state.phase == .rolledBack
            && state.outcome == .beforeRename
        guard staged || lockedEarly || active || rolledBack, try await device.chipID() == id else {
            throw LegacyChangeError.refused("The original NES operation could not be matched to an unambiguous transaction marker. No record was changed.")
        }
        return try UnboundIdentityReview(operationID: operationID, recordDigest: record.identityReviewDigest(),
                                         fingerprint: fingerprint, observation: state)
    }

    private static func sameObservation(_ a: LegacySyncInspection, _ b: LegacySyncInspection) -> Bool {
        a.phase == b.phase && a.transaction == b.transaction && a.live == b.live && a.old == b.old
            && a.stage == b.stage && a.failed == b.failed && a.lock == b.lock
            && a.archive == b.archive && a.verified == b.verified
    }

    func stage(operationID: UUID, plan: LegacySyncPlan, manifest: LegacyMenuStageManifest,
               backup: URL, device: any LegacySavedMenuRestoreDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        guard try LegacyGameChangeService.latest(workspace: workspace) == nil else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let evidence = try Self.validateLocal(plan: plan, manifest: manifest, backup: backup,
                                              workspace: workspace)
        let report = try await device.inspect()
        try Self.validateReport(report, against: plan,
                                minimumFreeBytes: plan.requiredStagingBytes)
        guard evidence.observedReport.matchesLayout(of: report),
              evidence.observedReport.visibleCodes == report.visibleCodes else {
            throw LegacyInspectionError.invalidBackup
        }
        try await LegacyCurrentBackup.requireCurrent(evidence.selection,
            report: plan.report, device: device, workspace: workspace)
        let record: LegacySyncJournal
        if let trialCode = plan.trialCode {
            guard plan.consoleOrder == .title else { throw LegacySyncJournalError.invalidRecord }
            record = try LegacySyncJournal(operationID: operationID, reviewSHA256: plan.reviewSHA256,
                archiveSHA256: manifest.archiveSHA256, treeSHA256: manifest.treeSHA256,
                backupSHA256: evidence.sha256, backupDirectory: backup,
                stageDirectory: manifest.menuDirectory.deletingLastPathComponent(),
                trialCode: trialCode, maximumGamesPerPage: plan.maximumGamesPerPage,
                archiveBytes: manifest.archiveBytes, chipIDFingerprint: evidence.selection.chipIDFingerprint)
        } else {
            record = try LegacySyncJournal(operationID: operationID, reviewSHA256: plan.reviewSHA256,
                archiveSHA256: manifest.archiveSHA256, treeSHA256: manifest.treeSHA256,
                backupSHA256: evidence.sha256, backupDirectory: backup,
                stageDirectory: manifest.menuDirectory.deletingLastPathComponent(), scope: .full,
                selectedCodes: plan.selectedGames.map { $0.game.code }.sorted(),
                reviewedLocalCodes: plan.reviewedLocalCodes,
                consoleOrder: plan.consoleOrder,
                maximumGamesPerPage: plan.maximumGamesPerPage, archiveBytes: manifest.archiveBytes,
                structure: plan.structure, chipIDFingerprint: evidence.selection.chipIDFingerprint)
        }
        try await store.begin(record)
        try await Self.requireIdentity(record, device: device)
        try await device.upload(manifest, operationID: operationID)
        try await store.advance(operationID, from: .prepared, to: .uploaded)
        try await Self.requireIdentity(record, device: device)
        try await device.verify(manifest, operationID: operationID,
                                stageBudgetBytes: plan.stageBytes)
        try await store.advance(operationID, from: .uploaded, to: .verified)
    }

    func activate(operationID: UUID, plan: LegacySyncPlan, manifest: LegacyMenuStageManifest,
                  backup: URL, device: any LegacySyncDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        guard LegacyStructureHardwareSupport.canActivate(plan) else {
            throw SyncPlanError.invalidInput("This Structure mode can be previewed but needs a supervised NES hardware trial before activation.")
        }
        working = true; defer { working = false }
        let stored = try await store.load(operationID)
        guard stored.phase == .verified else { throw LegacySyncJournalError.invalidTransition }
        guard try LegacyGameChangeService.latest(workspace: workspace) == nil else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let evidence = try Self.validateLocal(plan: plan, manifest: manifest, backup: backup,
                                              workspace: workspace)
        guard stored.matches(plan), stored.reviewSHA256 == plan.reviewSHA256,
              stored.archiveSHA256 == manifest.archiveSHA256,
              stored.treeSHA256 == manifest.treeSHA256,
              stored.backupSHA256 == evidence.sha256,
              stored.archiveBytes == manifest.archiveBytes,
              stored.backupDirectory == backup.standardizedFileURL,
              stored.stageDirectory == manifest.menuDirectory.deletingLastPathComponent().standardizedFileURL else {
            throw LegacySyncJournalError.invalidRecord
        }
        let report = try await device.inspect()
        // The archive and extracted inactive tree now occupy console storage.
        // The pre-upload two-copy budget no longer applies to this rename-only
        // phase; keep a reserve for transaction markers and menu restart.
        try Self.validateReport(report, against: plan,
                                minimumFreeBytes: 64 * 1024 * 1024)
        try await Self.requireIdentity(stored, device: device)
        try await store.advance(operationID, from: .verified, to: .activationIntent)
        do {
            try await device.activate(manifest, operationID: operationID)
            let observation = try await device.inspectOperation(operationID: operationID,
                                                                treeSHA256: manifest.treeSHA256)
            guard observation.phase == .menuStarted,
                  observation.outcome == .newTreePresent, observation.lock else {
                throw LegacyInspectionError.invalidResponse
            }
            try await store.advance(operationID, from: .activationIntent,
                                    to: .activePendingAcceptance)
        } catch {
            try? await store.markUncertain(operationID)
            throw error
        }
    }

    /// Recover a lost verification receipt by reading every inactive entry. This only advances
    /// the local journal; it never repeats the upload or changes the live console menu.
    func reconcileUploaded(operationID: UUID, manifest: LegacyMenuStageManifest,
                           device: any LegacySyncDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let record = try await store.load(operationID)
        guard record.phase == .uploaded,
              manifest.menuDirectory.deletingLastPathComponent().standardizedFileURL == record.stageDirectory,
              manifest.reviewSHA256 == record.reviewSHA256,
              manifest.archiveSHA256 == record.archiveSHA256,
              manifest.archiveBytes == record.archiveBytes,
              manifest.treeSHA256 == record.treeSHA256,
              manifest.entries.count <= LegacyStageVerification.maximumEntries else {
            throw LegacySyncJournalError.invalidRecord
        }
        let archive = try LegacySyncPlan.SourceFile.capture(manifest.archiveURL)
        guard archive.byteCount == record.archiveBytes,
              archive.sha256 == record.archiveSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        try Self.verifyJournalBackup(record)
        try await Self.requireIdentity(record, device: device)
        let data = try await device.inventoryStage(operationID: operationID)
        let differences = try LegacyStageVerification.compareInventory(data,
            operationID: operationID, expected: manifest.entries)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let description = lines.dropFirst().dropLast(2).joined(separator: "\n") + "\n"
        guard differences.isEmpty,
              BackupManifest.digest(Data(description.utf8)) == manifest.treeSHA256 else {
            throw LegacyInspectionError.invalidResponse
        }
        let state = try await device.inspectOperation(operationID: operationID,
                                                      treeSHA256: manifest.treeSHA256)
        guard state.phase == .missing, state.outcome == .beforeRename,
              state.transaction, state.archive, state.stage, state.verified,
              state.live, !state.old, !state.failed, !state.lock else {
            throw LegacySyncJournalError.invalidTransition
        }
        try await store.advance(operationID, from: .uploaded, to: .verified)
    }

    func accept(operationID: UUID, manifest: LegacyMenuStageManifest,
                mainMenuConfirmed: Bool, device: any LegacySyncDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        guard mainMenuConfirmed else {
            throw LegacyChangeError.refused("Return to the first NES game page and confirm the selected games work before accepting.")
        }
        working = true; defer { working = false }
        let stored = try await store.load(operationID)
        guard stored.phase == .activePendingAcceptance,
              stored.treeSHA256 == manifest.treeSHA256,
              stored.archiveSHA256 == manifest.archiveSHA256,
              stored.archiveBytes == manifest.archiveBytes else {
            throw LegacySyncJournalError.invalidTransition
        }
        try Self.verifyJournalBackup(stored)
        try await Self.requireIdentity(stored, device: device)
        let current = try await device.inspect()
        guard current.activePage == LegacyConsoleReport.gameRoot + "/000" else {
            throw LegacyChangeError.refused("Return to the first NES game page, which has More games… but no Previous games, before accepting the library. The menu and recovery copy are unchanged.")
        }
        do {
            try await device.accept(manifest, operationID: operationID)
            let observation = try await device.inspectOperation(operationID: operationID,
                                                                treeSHA256: manifest.treeSHA256)
            guard observation.phase == .accepted,
                  observation.outcome == .newTreePresent, !observation.lock else {
                throw LegacyInspectionError.invalidResponse
            }
            try await store.advance(operationID, from: .activePendingAcceptance, to: .accepted)
        } catch {
            try? await store.markUncertain(operationID)
            throw error
        }
    }

    func inspectRecovery(operationID: UUID, device: any LegacySyncDevice) async throws -> LegacySyncInspection {
        guard !working else { throw LegacyInspectionError.busy }
        let record = try await store.load(operationID)
        guard record.phase != .accepted else { throw LegacySyncJournalError.invalidTransition }
        if record.effectiveChipIDFingerprint == nil {
            // Read-only inspection does not establish that this is the
            // original console and does not authorize a recovery write.
            try await device.requireIdentity()
            let id = try await device.chipID()
            _ = try LegacyDeviceIdentity.requireReadOnlyInspection(id, fingerprint: nil)
        } else {
            try await Self.requireIdentity(record, device: device)
        }
        return try await device.inspectOperation(operationID: operationID,
                                                 treeSHA256: record.treeSHA256)
    }

    func discardInactive(operationID: UUID, device: any LegacySyncDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let record = try await store.load(operationID)
        guard [.prepared, .uploaded, .verified, .activationIntent, .uncertain].contains(record.phase) else {
            throw LegacySyncJournalError.invalidTransition
        }
        try Self.verifyJournalBackup(record)
        try await Self.requireIdentity(record, device: device)
        let before = try await device.inspectOperation(operationID: operationID,
                                                       treeSHA256: record.treeSHA256)
        guard before.outcome == .beforeRename, !before.old, !before.lock,
              before.phase == .missing else { throw LegacySyncJournalError.invalidTransition }
        if before.transaction || before.stage {
            try await device.discard(operationID: operationID, treeSHA256: record.treeSHA256)
        }
        let after = try await device.inspectOperation(operationID: operationID,
                                                      treeSHA256: record.treeSHA256)
        guard after.outcome == .beforeRename, !after.transaction, !after.stage,
              !after.old, !after.lock, after.phase == .missing else {
            throw LegacyInspectionError.invalidResponse
        }
        try await store.advance(operationID, from: record.phase, to: .discarded)
    }

    func rollback(operationID: UUID, device: any LegacySyncDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let record = try await store.load(operationID)
        guard [.activationIntent, .uncertain, .activePendingAcceptance].contains(record.phase) else {
            throw LegacySyncJournalError.invalidTransition
        }
        try Self.verifyJournalBackup(record)
        try await Self.requireIdentity(record, device: device)
        let before = try await device.inspectOperation(operationID: operationID,
                                                       treeSHA256: record.treeSHA256)
        if before.phase != .rolledBack || before.lock {
            guard before.transaction, before.lock, before.outcome != .inconsistent,
                  before.phase != .accepted else {
                throw LegacySyncJournalError.invalidTransition
            }
            try await device.rollback(operationID: operationID, treeSHA256: record.treeSHA256)
        }
        let after = try await device.inspectOperation(operationID: operationID,
                                                      treeSHA256: record.treeSHA256)
        guard after.phase == .rolledBack, after.outcome == .beforeRename, !after.old,
              !after.lock else { throw LegacyInspectionError.invalidResponse }
        try await store.advance(operationID, from: record.phase, to: .rolledBack)
    }

    func resumeAcceptance(operationID: UUID, mainMenuConfirmed: Bool,
                          device: any LegacySyncDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        guard mainMenuConfirmed else { throw LegacySyncJournalError.invalidTransition }
        working = true; defer { working = false }
        let record = try await store.load(operationID)
        guard record.phase == .uncertain else { throw LegacySyncJournalError.invalidTransition }
        try Self.verifyJournalBackup(record)
        try await Self.requireIdentity(record, device: device)
        let state = try await device.inspectOperation(operationID: operationID,
                                                     treeSHA256: record.treeSHA256)
        guard (state.phase == .menuStarted || state.phase == .accepted),
              state.outcome == .newTreePresent,
              state.lock else { throw LegacySyncJournalError.invalidTransition }
        try await store.advance(operationID, from: .uncertain, to: .activePendingAcceptance)
    }

    func reconcileAccepted(operationID: UUID, mainMenuConfirmed: Bool,
                           device: any LegacySyncDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        guard mainMenuConfirmed else { throw LegacySyncJournalError.invalidTransition }
        working = true; defer { working = false }
        let record = try await store.load(operationID)
        guard [.uncertain, .activePendingAcceptance].contains(record.phase) else { throw LegacySyncJournalError.invalidTransition }
        try Self.verifyJournalBackup(record)
        try await Self.requireIdentity(record, device: device)
        let state = try await device.inspectOperation(operationID: operationID,
                                                     treeSHA256: record.treeSHA256)
        guard state.phase == .accepted, state.outcome == .newTreePresent,
              !state.lock else { throw LegacySyncJournalError.invalidTransition }
        try await store.advance(operationID, from: record.phase, to: .accepted)
    }

    private static func verifyJournalBackup(_ record: LegacySyncJournal) throws {
        try LegacyGameChangeService.verifyBackup(record.backupDirectory)
        let archive = record.backupDirectory.appendingPathComponent("console.tar")
        guard BackupManifest.digest(try Data(contentsOf: archive, options: .mappedIfSafe)) == record.backupSHA256 else {
            throw LegacyInspectionError.invalidBackup
        }
    }

    private static func requireIdentity(_ record: LegacySyncJournal, device: any LegacySyncDevice) async throws {
        guard let fingerprint = record.effectiveChipIDFingerprint else {
            throw LegacyChangeError.refused("This older update has no verified NES identity. Review the original NES before continuing.")
        }
        try await device.requireIdentity()
        guard LegacyDeviceIdentity.matches(try await device.chipID(), fingerprint: fingerprint) else {
            throw LegacyInspectionError.invalidBackup
        }
    }

    private static func validateReport(_ fresh: LegacyConsoleReport,
                                       against plan: LegacySyncPlan,
                                       minimumFreeBytes: Int64) throws {
        try LegacyGameChangeService.validateReport(fresh, against: plan.report)
        guard fresh.visibleCodes == plan.report.visibleCodes else {
            throw LegacyChangeError.refused("The games on the NES changed. Close this window and review the library again.")
        }
        guard fresh.freeBytes >= minimumFreeBytes else {
            throw SyncPlanError.insufficientSpace(required: minimumFreeBytes, available: fresh.freeBytes)
        }
    }

    private struct BackupEvidence {
        let sha256: String
        let observedReport: LegacyConsoleReport
        let selection: LegacyCurrentBackup.Selection
    }

    private static func validateLocal(plan: LegacySyncPlan,
                                      manifest: LegacyMenuStageManifest, backup: URL,
                                      workspace: WorkspacePaths) throws -> BackupEvidence {
        guard manifest.reviewSHA256 == plan.reviewSHA256,
              manifest.archiveBytes > 0, manifest.archiveBytes <= 256 * 1024 * 1024,
              manifest.treeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              plan.stageBytes >= manifest.archiveBytes else {
            throw LegacySyncJournalError.invalidRecord
        }
        try plan.verifyLocalSources()
        let archive = try LegacySyncPlan.SourceFile.capture(manifest.archiveURL)
        guard archive.byteCount == manifest.archiveBytes,
              archive.sha256 == manifest.archiveSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        guard workspace.containsBackup(backup) else { throw LegacyInspectionError.invalidBackup }
        let snapshot = try LegacyMenuSnapshot.verify(directory: backup)
        guard snapshot.observedReport.matchesLayout(of: plan.report),
              snapshot.observedReport.visibleCodes == plan.report.visibleCodes else {
            throw LegacyInspectionError.invalidBackup
        }
        let selection = LegacyCurrentBackup.Selection(directory: backup,
            archiveSHA256: snapshot.manifest.archiveSHA256,
            treeSHA256: snapshot.menuTreeSHA256,
            chipIDFingerprint: snapshot.manifest.chipIDFingerprint,
            observedReport: snapshot.observedReport)
        return BackupEvidence(sha256: snapshot.manifest.archiveSHA256,
                              observedReport: snapshot.observedReport, selection: selection)
    }
}
