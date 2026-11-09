import Foundation
import SwiftHakchiCore

protocol LegacyOldMenuReclaimDevice: LegacyOldMenuBindingDevice {
    func inspectOldMenu(operationID: UUID, liveTreeSHA256: String,
                        oldTreeSHA256: String) async throws -> Int64
    func removeOldMenu(operationID: UUID, liveTreeSHA256: String,
                       oldTreeSHA256: String) async throws
}

/// Read-only proof for the former menu retained by a completed restore-and-return trial.
/// The former tree is never inferred from an archive's name or from a game count alone.
enum LegacyOldMenuReclaim {
    struct Preview: Sendable {
        let operationID: UUID
        let firstOperationID: UUID
        let previousOperationID: UUID
        let previousSnapshotDirectory: URL
        let previousSnapshotSHA256: String
        let previousTreeSHA256: String
        let currentTreeSHA256: String
        let chipIDFingerprint: String
        let previousGameCount: Int
        let currentGameCount: Int
        let previousLogicalBytes: Int64
        let previousAllocatedBytes: Int64
        let freeBytes: Int64
    }

    static func preview(operationID: UUID, workspace: WorkspacePaths,
                        confirmedTestedMenus: Bool,
                        device: any LegacyOldMenuReclaimDevice) async throws -> Preview {
        guard confirmedTestedMenus else {
            throw LegacyChangeError.refused("Test both saved menus, their artwork, an imported game, a built-in game, and controller input before reviewing former-menu removal.")
        }
        let store = LegacySyncJournalStore(directory: workspace.journals)
        let selectionChipID = try await device.chipID()
        guard try await store.latestUnresolved() == nil,
              try LegacyGameChangeService.latest(workspace: workspace) == nil,
              try await store.latestAcceptedMenu(matchingChipID: selectionChipID)?.operationID == operationID else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let current = try await store.load(operationID)
        guard current.phase == .accepted, current.resolvedScope == .savedMenu,
              let currentBinding = current.savedMenuBinding,
              workspace.containsBackup(current.backupDirectory) else {
            throw LegacySyncJournalError.invalidRecord
        }
        let previous = try await store.load(currentBinding.previousOperationID)
        guard previous.phase == .accepted, previous.resolvedScope == .savedMenu,
              previous.treeSHA256 == currentBinding.previousTreeSHA256,
              let previousBinding = previous.savedMenuBinding,
              workspace.containsBackup(previous.backupDirectory) else {
            throw LegacySyncJournalError.invalidRecord
        }
        let first = try await store.load(previousBinding.previousOperationID)
        guard first.phase == .accepted,
              first.resolvedScope == .full || first.resolvedScope == .savedMenu,
              first.treeSHA256 == previousBinding.previousTreeSHA256,
              first.selectedCodes == current.selectedCodes,
              first.operationID != current.operationID,
              first.operationID != previous.operationID,
              previous.operationID != current.operationID else {
            throw LegacySyncJournalError.invalidRecord
        }

        try await device.requireIdentity()
        let chipID = try await device.chipID()
        guard chipID == selectionChipID else { throw LegacyInspectionError.invalidBackup }
        let chipFingerprint = BackupManifest.digest(Data(chipID.utf8))
        guard currentBinding.chipIDFingerprint == chipFingerprint,
              previousBinding.chipIDFingerprint == chipFingerprint else {
            throw LegacyInspectionError.invalidBackup
        }
        let currentSnapshot = try LegacyMenuSnapshot.verify(directory: current.backupDirectory,
                                                              expectedChipID: chipID)
        let previousSnapshot = try LegacyMenuSnapshot.verify(directory: previous.backupDirectory,
                                                               expectedChipID: chipID)
        guard currentSnapshot.manifest.archiveSHA256 == current.backupSHA256,
              currentSnapshot.manifest.archiveSHA256 == currentBinding.snapshotArchiveSHA256,
              previousSnapshot.manifest.archiveSHA256 == previous.backupSHA256,
              previousSnapshot.manifest.archiveSHA256 == previousBinding.snapshotArchiveSHA256,
              currentSnapshot.menuTreeSHA256 == current.treeSHA256,
              previousSnapshot.menuTreeSHA256 == previous.treeSHA256,
              LegacyMenuSnapshot.gameCodes(currentSnapshot.entries) == Set(current.selectedCodes ?? []),
              LegacyMenuSnapshot.gameCodes(previousSnapshot.entries) == Set(previous.selectedCodes ?? []) else {
            throw LegacyInspectionError.invalidBackup
        }
        try verifyReturnedMenuMatchesFirstStage(first, returned: currentSnapshot.entries)
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        guard report.visibleCodes == Set(current.selectedCodes ?? []),
              report.stockCodes == currentSnapshot.observedReport.stockCodes,
              report.bootVersion == currentSnapshot.observedReport.bootVersion,
              report.kernelVersion == currentSnapshot.observedReport.kernelVersion,
              report.scriptVersion == currentSnapshot.observedReport.scriptVersion else {
            throw LegacyInspectionError.invalidReport
        }
        let state = try await device.inspectOperation(operationID: operationID,
                                                      treeSHA256: current.treeSHA256)
        guard state.phase == .accepted, state.outcome == .newTreePresent,
              state.transaction, state.live, state.old, !state.stage,
              !state.failed, !state.lock else {
            throw LegacySyncJournalError.invalidTransition
        }
        let live = try await device.inventoryLive(operationID: operationID)
        let liveDifferences = try LegacyStageVerification.compareInventory(live,
            operationID: operationID, expected: currentSnapshot.entries)
        guard liveDifferences.isEmpty else {
            throw LegacyChangeError.refused("The current menu differs from its Mac snapshot: "
                + liveDifferences.prefix(3).joined(separator: "; "))
        }
        let old = try await device.inventoryOld(operationID: operationID)
        let oldDifferences = try LegacyStageVerification.compareInventory(old,
            operationID: operationID, expected: previousSnapshot.entries)
        guard oldDifferences.isEmpty else {
            throw LegacyChangeError.refused("The retained menu differs from its Mac snapshot: "
                + oldDifferences.prefix(3).joined(separator: "; "))
        }
        let allocatedBytes = try await device.inspectOldMenu(operationID: operationID,
            liveTreeSHA256: current.treeSHA256,
            oldTreeSHA256: previousSnapshot.menuTreeSHA256)
        let bytes = previousSnapshot.entries.reduce(Int64(0)) { sum, entry in
            entry.kind == .regular ? sum + entry.byteCount : sum
        }
        return Preview(operationID: operationID, firstOperationID: first.operationID,
            previousOperationID: previous.operationID,
            previousSnapshotDirectory: previous.backupDirectory,
            previousSnapshotSHA256: previousSnapshot.manifest.archiveSHA256,
            previousTreeSHA256: previousSnapshot.menuTreeSHA256,
            currentTreeSHA256: currentSnapshot.menuTreeSHA256,
            chipIDFingerprint: chipFingerprint,
            previousGameCount: LegacyMenuSnapshot.gameCodes(previousSnapshot.entries).count,
            currentGameCount: LegacyMenuSnapshot.gameCodes(currentSnapshot.entries).count,
            previousLogicalBytes: bytes, previousAllocatedBytes: allocatedBytes,
            freeBytes: report.freeBytes)
    }

    private static func verifyReturnedMenuMatchesFirstStage(_ first: LegacySyncJournal,
        returned: [LegacyMenuStageManifest.Entry]) throws {
        let file = first.stageDirectory.appendingPathComponent("manifest.json")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 1024 * 1024 else {
            throw LegacySyncJournalError.invalidRecord
        }
        let stage = try JSONDecoder().decode(LegacyMenuStageManifest.self, from: Data(contentsOf: file))
        guard stage.treeSHA256 == first.treeSHA256,
              stage.archiveSHA256 == first.archiveSHA256,
              stage.archiveBytes == first.archiveBytes,
              LegacyMenuSnapshot.treeDigest(stage.entries) == first.treeSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        var actual = Dictionary(uniqueKeysWithValues: returned.map { ($0.relativePath, $0) })
        for entry in stage.entries {
            guard let found = actual.removeValue(forKey: entry.relativePath),
                  found.kind == entry.kind, found.byteCount == entry.byteCount,
                  found.sha256 == entry.sha256, found.linkTarget == entry.linkTarget else {
                throw LegacyInspectionError.invalidBackup
            }
        }
        for entry in actual.values {
            guard entry.relativePath.range(of: #"^[0-9]{3}/(copyright|title)\.fnt$"#,
                                           options: .regularExpression) != nil,
                  entry.kind == .regular, entry.byteCount >= 0,
                  entry.byteCount <= 1024 * 1024,
                  entry.sha256?.range(of: #"^[a-f0-9]{64}$"#,
                                      options: .regularExpression) != nil else {
                throw LegacyInspectionError.invalidBackup
            }
        }
    }
}
