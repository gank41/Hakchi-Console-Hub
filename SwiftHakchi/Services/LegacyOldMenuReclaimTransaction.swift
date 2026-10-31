import Foundation
import SwiftHakchiCore

/// Records the exact former tree before deletion and reconciles a lost response
/// without replaying a potentially partial recursive remove.
actor LegacyOldMenuReclaimTransaction {
    private let workspace: WorkspacePaths
    private let syncStore: LegacySyncJournalStore
    private let archiveStore: LegacyArchiveReclaimJournalStore
    private let store: LegacyOldMenuReclaimJournalStore
    private var working = false

    init(workspace: WorkspacePaths) {
        self.workspace = workspace
        syncStore = LegacySyncJournalStore(directory: workspace.journals)
        archiveStore = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        store = LegacyOldMenuReclaimJournalStore(directory: workspace.journals)
    }

    func prepare(operationID: UUID, confirmedTestedMenus: Bool,
                 device: any LegacyOldMenuReclaimDevice) async throws
        -> LegacyOldMenuReclaim.Preview {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        guard try await syncStore.latestUnresolved() == nil,
              try await archiveStore.latestUnresolved() == nil,
              try await archiveStore.load(operationID).phase == .completed else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let pending = try await store.latestUnresolved()
        guard pending == nil || pending?.phase == .prepared else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        guard confirmedTestedMenus else {
            throw LegacySyncJournalError.invalidRecord
        }
        let preview = try await LegacyOldMenuReclaim.preview(operationID: operationID,
            workspace: workspace, confirmedTestedMenus: confirmedTestedMenus, device: device)
        if let pending, pending.operationID == operationID {
            guard pending.currentTreeSHA256 == preview.currentTreeSHA256,
                  pending.previousTreeSHA256 == preview.previousTreeSHA256,
                  pending.previousSnapshotSHA256 == preview.previousSnapshotSHA256,
                  pending.chipIDFingerprint == preview.chipIDFingerprint else {
                throw LegacySyncJournalError.invalidRecord
            }
        }
        if pending?.operationID != operationID || pending?.testedMenus != true {
            if let pending { try await store.advance(pending.operationID, from: .prepared, to: .abandoned) }
            try await store.begin(LegacyOldMenuReclaimJournal(operationID: operationID,
                currentTreeSHA256: preview.currentTreeSHA256,
                previousTreeSHA256: preview.previousTreeSHA256,
                previousSnapshotSHA256: preview.previousSnapshotSHA256,
                chipIDFingerprint: preview.chipIDFingerprint,
                createdAt: Date(), phase: .prepared, testedMenus: true))
        }
        return preview
    }

    func remove(preview: LegacyOldMenuReclaim.Preview,
                device: any LegacyOldMenuReclaimDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let journal = try await store.load(preview.operationID)
        guard journal.phase == .prepared, journal.testedMenus == true,
              journal.currentTreeSHA256 == preview.currentTreeSHA256,
              journal.previousTreeSHA256 == preview.previousTreeSHA256,
              journal.previousSnapshotSHA256 == preview.previousSnapshotSHA256,
              journal.chipIDFingerprint == preview.chipIDFingerprint,
              try await syncStore.latestUnresolved() == nil,
              try await archiveStore.latestUnresolved() == nil,
              try await archiveStore.load(preview.operationID).phase == .completed else {
            throw LegacySyncJournalError.invalidTransition
        }
        let fresh = try await LegacyOldMenuReclaim.preview(operationID: preview.operationID,
            workspace: workspace, confirmedTestedMenus: true, device: device)
        guard fresh.previousOperationID == preview.previousOperationID,
              fresh.firstOperationID == preview.firstOperationID,
              fresh.currentTreeSHA256 == preview.currentTreeSHA256,
              fresh.previousTreeSHA256 == preview.previousTreeSHA256,
              fresh.previousSnapshotSHA256 == preview.previousSnapshotSHA256,
              fresh.chipIDFingerprint == preview.chipIDFingerprint else {
            throw LegacySyncJournalError.invalidRecord
        }
        try await store.advance(preview.operationID, from: .prepared, to: .removalIntent)
        do {
            try await device.removeOldMenu(operationID: preview.operationID,
                liveTreeSHA256: preview.currentTreeSHA256,
                oldTreeSHA256: preview.previousTreeSHA256)
            try await requireAbsent(journal: journal, device: device)
            try await store.advance(preview.operationID, from: .removalIntent, to: .completed)
        } catch {
            try? await store.advance(preview.operationID, from: .removalIntent, to: .uncertain)
            throw error
        }
    }

    func reconcile(operationID: UUID, device: any LegacyOldMenuReclaimDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let journal = try await store.load(operationID)
        guard (journal.phase == .removalIntent || journal.phase == .uncertain),
              journal.testedMenus == true else {
            throw LegacySyncJournalError.invalidTransition
        }
        let record = try await syncStore.load(operationID)
        guard record.phase == .accepted, record.treeSHA256 == journal.currentTreeSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        try await device.requireIdentity()
        guard LegacyDeviceIdentity.matches(try await device.chipID(),
                                           fingerprint: journal.chipIDFingerprint) else {
            throw LegacyInspectionError.invalidBackup
        }
        let state = try await device.inspectOperation(operationID: operationID,
                                                      treeSHA256: journal.currentTreeSHA256)
        if state.old {
            let fresh = try await LegacyOldMenuReclaim.preview(operationID: operationID,
                workspace: workspace, confirmedTestedMenus: true, device: device)
            guard fresh.previousTreeSHA256 == journal.previousTreeSHA256,
                  fresh.previousSnapshotSHA256 == journal.previousSnapshotSHA256 else {
                throw LegacySyncJournalError.invalidRecord
            }
            try await store.advance(operationID, from: journal.phase, to: .prepared)
        } else {
            try await requireAbsent(journal: journal, device: device)
            try await store.advance(operationID, from: journal.phase, to: .completed)
        }
    }

    private func requireAbsent(journal: LegacyOldMenuReclaimJournal,
                               device: any LegacyOldMenuReclaimDevice) async throws {
        try await device.requireIdentity()
        let chipID = try await device.chipID()
        guard LegacyDeviceIdentity.matches(chipID, fingerprint: journal.chipIDFingerprint) else {
            throw LegacyInspectionError.invalidBackup
        }
        let record = try await syncStore.load(journal.operationID)
        guard record.phase == .accepted, record.treeSHA256 == journal.currentTreeSHA256,
              workspace.containsBackup(record.backupDirectory) else {
            throw LegacySyncJournalError.invalidRecord
        }
        let snapshot = try LegacyMenuSnapshot.verify(directory: record.backupDirectory,
                                                     expectedChipID: chipID)
        guard snapshot.menuTreeSHA256 == journal.currentTreeSHA256 else {
            throw LegacyInspectionError.invalidBackup
        }
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        guard report.visibleCodes == Set(record.selectedCodes ?? []) else {
            throw LegacyInspectionError.invalidReport
        }
        let state = try await device.inspectOperation(operationID: journal.operationID,
                                                      treeSHA256: journal.currentTreeSHA256)
        guard state.phase == .accepted, state.transaction, state.live,
              !state.old, !state.stage, !state.failed, !state.lock else {
            throw LegacyInspectionError.invalidResponse
        }
        let live = try await device.inventoryLive(operationID: journal.operationID)
        guard try LegacyStageVerification.compareInventory(live,
            operationID: journal.operationID, expected: snapshot.entries).isEmpty else {
            throw LegacyInspectionError.invalidResponse
        }
    }
}
