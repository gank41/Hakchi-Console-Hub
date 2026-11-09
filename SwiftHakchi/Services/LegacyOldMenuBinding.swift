import Foundation
import Darwin
import SwiftHakchiCore

protocol LegacyOldMenuBindingDevice: LegacySavedMenuRestoreDevice {
    func inventoryOld(operationID: UUID) async throws -> Data
}

/// Proves an older inspection archive is the exact former menu on this NES
/// before adding a device-bound restore index to the Mac backup.
actor LegacyOldMenuBinding {
    struct StepError: LocalizedError {
        let step: String
        let cause: Error

        var errorDescription: String? {
            "The former-menu check stopped while \(step): \(cause.localizedDescription)"
        }
    }

    struct Preview: Sendable {
        let operationID: UUID
        let backupDirectory: URL
        let archiveSHA256: String
        let oldTreeSHA256: String
        let activeTreeSHA256: String
        let chipIDFingerprint: String
        let oldGameCount: Int
        let recordDigest: String
        let recordWasUnbound: Bool
    }

    private let workspace: WorkspacePaths
    private let store: LegacySyncJournalStore

    init(workspace: WorkspacePaths) {
        self.workspace = workspace
        store = LegacySyncJournalStore(directory: workspace.journals)
    }

    func preview(operationID: UUID, device: any LegacyOldMenuBindingDevice) async throws -> Preview {
        guard try await store.latestUnresolved() == nil,
              try LegacyGameChangeService.latest(workspace: workspace) == nil else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let record = try await store.load(operationID)
        guard record.phase == .accepted,
              workspace.containsBackup(record.backupDirectory),
              record.stageDirectory.deletingLastPathComponent().standardizedFileURL.path
                == workspace.root.appendingPathComponent("Stages").path else {
            throw LegacySyncJournalError.invalidRecord
        }
        let saved = try LegacyMenuSnapshot.inspectUnbound(directory: record.backupDirectory)
        guard saved.archiveSHA256 == record.backupSHA256 else {
            throw LegacyInspectionError.invalidBackup
        }
        let stage = try stageManifest(for: record)
        let chipID = try await checked("reading console identity") {
            try await device.requireIdentity()
            return try await device.chipID()
        }
        _ = try LegacyDeviceIdentity.requireReadOnlyInspection(chipID, fingerprint: record.effectiveChipIDFingerprint)
        let sidecar = record.backupDirectory.appendingPathComponent(LegacyMenuSnapshot.filename)
        var info = stat()
        if lstat(sidecar.path, &info) == 0 {
            let bound = try LegacyMenuSnapshot.verify(directory: record.backupDirectory,
                                                      expectedChipID: chipID)
            guard bound.menuTreeSHA256 == saved.treeSHA256 else {
                throw LegacyInspectionError.invalidBackup
            }
        } else if errno != ENOENT {
            throw LegacyInspectionError.invalidBackup
        }
        let report = try await checked("reading the active-menu report") {
            let report = try await device.inspect()
            try LegacyGameChangeService.validateReport(report)
            return report
        }
        switch record.resolvedScope {
        case .trial(let trialCode):
            let stagedCodes = LegacyMenuSnapshot.gameCodes(stage.entries)
            guard stagedCodes == report.stockCodes.union([trialCode]), stagedCodes == report.visibleCodes else {
                throw LegacyInspectionError.invalidReport
            }
        case .full, .savedMenu:
            guard record.selectedCodes.map(Set.init) == report.visibleCodes else {
                throw LegacyInspectionError.invalidReport
            }
        }
        let state = try await checked("checking the accepted menu transaction") {
            try await device.inspectOperation(operationID: operationID,
                                              treeSHA256: record.treeSHA256)
        }
        guard state.phase == .accepted, state.outcome == .newTreePresent,
              state.transaction, state.live, state.old, !state.stage,
              !state.failed, !state.lock else {
            throw LegacySyncJournalError.invalidTransition
        }
        let live = try await checked("reading the active-menu inventory") {
            try await device.inventoryLive(operationID: operationID)
        }
        try await checked("comparing active-menu inventory") {
            let differences = try LegacyStageVerification.compareInventory(live,
                operationID: operationID, expected: stage.entries,
                allowGeneratedPageFonts: true)
            guard differences.isEmpty else {
                throw LegacyChangeError.refused("The active menu differs from its saved record: "
                    + differences.prefix(3).joined(separator: "; "))
            }
        }
        let old = try await checked("reading the former-menu inventory") {
            try await device.inventoryOld(operationID: operationID)
        }
        try await checked("comparing former-menu inventory") {
            let differences = try LegacyStageVerification.compareInventory(old,
                operationID: operationID, expected: saved.entries)
            guard differences.isEmpty else {
                throw LegacyChangeError.refused("The retained menu differs from its Mac backup: "
                    + differences.prefix(3).joined(separator: "; "))
            }
        }
        guard try await device.chipID() == chipID else { throw LegacyInspectionError.invalidBackup }
        return Preview(operationID: operationID, backupDirectory: record.backupDirectory,
            archiveSHA256: saved.archiveSHA256, oldTreeSHA256: saved.treeSHA256,
            activeTreeSHA256: record.treeSHA256,
            chipIDFingerprint: BackupManifest.digest(Data(chipID.utf8)),
            oldGameCount: LegacyMenuSnapshot.gameCodes(saved.entries).count,
            recordDigest: try record.identityReviewDigest(), recordWasUnbound: record.effectiveChipIDFingerprint == nil)
    }

    func bind(preview reviewed: Preview,
              device: any LegacyOldMenuBindingDevice) async throws -> LegacyMenuSnapshot.Verified {
        let fresh = try await preview(operationID: reviewed.operationID, device: device)
        guard !reviewed.recordWasUnbound, !fresh.recordWasUnbound,
              fresh.recordDigest == reviewed.recordDigest,
              fresh.backupDirectory.path == reviewed.backupDirectory.path,
              fresh.archiveSHA256 == reviewed.archiveSHA256,
              fresh.oldTreeSHA256 == reviewed.oldTreeSHA256,
              fresh.activeTreeSHA256 == reviewed.activeTreeSHA256,
              fresh.chipIDFingerprint == reviewed.chipIDFingerprint else {
            throw LegacyInspectionError.invalidBackup
        }
        let chipID = try await device.chipID()
        guard LegacyDeviceIdentity.matches(chipID, fingerprint: fresh.chipIDFingerprint) else {
            throw LegacyInspectionError.invalidBackup
        }
        let verified: LegacyMenuSnapshot.Verified
        if FileManager.default.fileExists(atPath:
            fresh.backupDirectory.appendingPathComponent(LegacyMenuSnapshot.filename).path) {
            verified = try LegacyMenuSnapshot.verify(directory: fresh.backupDirectory,
                                                     expectedChipID: chipID)
        } else {
            verified = try LegacyMenuSnapshot.record(directory: fresh.backupDirectory,
                                                     chipID: chipID)
        }
        guard verified.manifest.archiveSHA256 == fresh.archiveSHA256,
              verified.menuTreeSHA256 == fresh.oldTreeSHA256 else {
            throw LegacyInspectionError.invalidBackup
        }
        return verified
    }

    /// Binds only the accepted journal. Creating a restore index remains a
    /// separate action after explicit original-console confirmation.
    func bindReviewedAcceptedIdentity(preview reviewed: Preview, originalConsoleConfirmed: Bool,
                                      device: any LegacyOldMenuBindingDevice,
                                      isSessionCurrent: @MainActor @Sendable () -> Bool) async throws {
        guard originalConsoleConfirmed, reviewed.recordWasUnbound else {
            throw LegacySyncJournalError.invalidTransition
        }
        let fresh = try await preview(operationID: reviewed.operationID, device: device)
        guard fresh.recordWasUnbound, fresh.recordDigest == reviewed.recordDigest,
              fresh.backupDirectory == reviewed.backupDirectory,
              fresh.archiveSHA256 == reviewed.archiveSHA256,
              fresh.oldTreeSHA256 == reviewed.oldTreeSHA256,
              fresh.activeTreeSHA256 == reviewed.activeTreeSHA256,
              fresh.chipIDFingerprint == reviewed.chipIDFingerprint else {
            throw LegacyInspectionError.invalidBackup
        }
        try await MainActor.run {
            guard isSessionCurrent() else { throw LegacyInspectionError.disconnected }
            try store.bindReviewedAcceptedIdentity(reviewed.operationID, fingerprint: fresh.chipIDFingerprint,
                                                   expectedRecordDigest: fresh.recordDigest)
        }
    }

    private func stageManifest(for record: LegacySyncJournal) throws -> LegacyMenuStageManifest {
        let file = record.stageDirectory.appendingPathComponent("manifest.json")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 1024 * 1024 else {
            throw LegacySyncJournalError.invalidRecord
        }
        let stage = try JSONDecoder().decode(LegacyMenuStageManifest.self,
                                             from: Data(contentsOf: file))
        guard stage.treeSHA256 == record.treeSHA256,
              stage.archiveSHA256 == record.archiveSHA256,
              stage.archiveBytes == record.archiveBytes,
              LegacyMenuSnapshot.treeDigest(stage.entries) == record.treeSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        if record.effectiveChipIDFingerprint == nil {
            guard stage.menuDirectory.deletingLastPathComponent().standardizedFileURL == record.stageDirectory,
                  stage.archiveURL.standardizedFileURL == record.stageDirectory.appendingPathComponent("menu.tar").standardizedFileURL else {
                throw LegacySyncJournalError.invalidRecord
            }
            let archive = try LegacySyncPlan.SourceFile.capture(stage.archiveURL)
            guard archive.byteCount == record.archiveBytes, archive.sha256 == record.archiveSHA256 else {
                throw LegacySyncJournalError.invalidRecord
            }
        }
        return stage
    }

    private func checked<T>(_ step: String, _ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { throw StepError(step: step, cause: error) }
    }
}
