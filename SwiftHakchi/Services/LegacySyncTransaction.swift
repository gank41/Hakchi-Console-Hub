import Foundation
import SwiftHakchiCore

/// A narrow device capability, so every write is a fixed legacy sync operation.
protocol LegacySyncDevice: Sendable {
    func inspect() async throws -> LegacyConsoleReport
    func requireIdentity() async throws
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
    private let store: LegacySyncJournalStore
    private let workspace: WorkspacePaths
    private var working = false

    init(store: LegacySyncJournalStore, workspace: WorkspacePaths) {
        self.store = store
        self.workspace = workspace
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
                archiveBytes: manifest.archiveBytes)
        } else {
            record = try LegacySyncJournal(operationID: operationID, reviewSHA256: plan.reviewSHA256,
                archiveSHA256: manifest.archiveSHA256, treeSHA256: manifest.treeSHA256,
                backupSHA256: evidence.sha256, backupDirectory: backup,
                stageDirectory: manifest.menuDirectory.deletingLastPathComponent(), scope: .full,
                selectedCodes: plan.selectedGames.map { $0.game.code }.sorted(),
                reviewedLocalCodes: plan.reviewedLocalCodes,
                consoleOrder: plan.consoleOrder,
                maximumGamesPerPage: plan.maximumGamesPerPage, archiveBytes: manifest.archiveBytes,
                structure: plan.structure)
        }
        try await store.begin(record)
        try await device.upload(manifest, operationID: operationID)
        try await store.advance(operationID, from: .prepared, to: .uploaded)
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
        try await device.requireIdentity()
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
        try LegacyGameChangeService.verifyBackup(record.backupDirectory)
        try await device.requireIdentity()
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
        try LegacyGameChangeService.verifyBackup(stored.backupDirectory)
        try await device.requireIdentity()
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
        try await device.requireIdentity()
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
        try LegacyGameChangeService.verifyBackup(record.backupDirectory)
        try await device.requireIdentity()
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
        try LegacyGameChangeService.verifyBackup(record.backupDirectory)
        try await device.requireIdentity()
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
        try LegacyGameChangeService.verifyBackup(record.backupDirectory)
        try await device.requireIdentity()
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
        guard record.phase == .uncertain else { throw LegacySyncJournalError.invalidTransition }
        try LegacyGameChangeService.verifyBackup(record.backupDirectory)
        try await device.requireIdentity()
        let state = try await device.inspectOperation(operationID: operationID,
                                                     treeSHA256: record.treeSHA256)
        guard state.phase == .accepted, state.outcome == .newTreePresent,
              !state.lock else { throw LegacySyncJournalError.invalidTransition }
        try await store.advance(operationID, from: .uncertain, to: .accepted)
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
