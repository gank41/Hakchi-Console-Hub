import Foundation
import SwiftHakchiCore

/// Records intent before the only remote deletion and never retries an uncertain result.
actor LegacyArchiveReclaimTransaction {
    private let workspace: WorkspacePaths
    private let syncStore: LegacySyncJournalStore
    private let reclaimStore: LegacyArchiveReclaimJournalStore
    private var working = false

    init(workspace: WorkspacePaths) {
        self.workspace = workspace
        syncStore = LegacySyncJournalStore(directory: workspace.journals)
        reclaimStore = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
    }

    func prepare(operationID: UUID, device: any LegacyArchiveReclaimDevice) async throws -> LegacyArchiveReclaim.Preview {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        guard try await syncStore.latestUnresolved() == nil,
              try LegacyGameChangeService.latest(workspace: workspace) == nil else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let record = try await syncStore.load(operationID)
        let pending = try await reclaimStore.latestUnresolved()
        guard pending == nil || pending?.phase == .prepared else {
            throw LegacySyncJournalError.unresolvedOperation
        }
        if pending?.operationID == operationID {
            guard pending?.archiveSHA256 == record.archiveSHA256,
                  pending?.treeSHA256 == record.treeSHA256,
                  pending?.archiveBytes == record.archiveBytes else {
                throw LegacySyncJournalError.invalidRecord
            }
        }
        let preview = try await LegacyArchiveReclaim.preview(record: record,
                                                              workspace: workspace, device: device)
        if pending?.operationID != operationID {
            if let pending {
                try await reclaimStore.advance(pending.operationID, from: .prepared, to: .abandoned)
            }
            try await reclaimStore.begin(LegacyArchiveReclaimJournal(operationID: operationID,
                archiveSHA256: record.archiveSHA256, treeSHA256: record.treeSHA256,
                archiveBytes: record.archiveBytes, createdAt: Date(), phase: .prepared))
        }
        return preview
    }

    func remove(preview: LegacyArchiveReclaim.Preview,
                device: any LegacyArchiveReclaimDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        try await LegacyCleanupWriteGate.requireClear(workspace: workspace)
        let journal = try await reclaimStore.load(preview.operationID)
        guard journal.phase == .prepared,
              journal.archiveSHA256 == preview.archiveSHA256,
              journal.treeSHA256 == preview.treeSHA256,
              journal.archiveBytes == preview.archiveBytes,
              try await syncStore.latestUnresolved() == nil else {
            throw LegacySyncJournalError.invalidTransition
        }
        let record = try await syncStore.load(preview.operationID)
        let fresh = try await LegacyArchiveReclaim.preview(record: record,
                                                            workspace: workspace, device: device)
        guard fresh.archiveBytes == preview.archiveBytes,
              fresh.archiveSHA256 == preview.archiveSHA256,
              fresh.treeSHA256 == preview.treeSHA256 else {
            throw LegacySyncJournalError.invalidRecord
        }
        try await reclaimStore.advance(preview.operationID, from: .prepared, to: .removalIntent)
        do {
            try await device.removeArchive(operationID: preview.operationID,
                treeSHA256: preview.treeSHA256, archiveSHA256: preview.archiveSHA256,
                archiveBytes: preview.archiveBytes)
            try await requireAbsent(journal: journal, device: device)
            try await reclaimStore.advance(preview.operationID, from: .removalIntent, to: .completed)
        } catch {
            try? await reclaimStore.advance(preview.operationID, from: .removalIntent, to: .uncertain)
            throw error
        }
    }

    func reconcile(operationID: UUID, device: any LegacyArchiveReclaimDevice) async throws {
        guard !working else { throw LegacyInspectionError.busy }
        working = true; defer { working = false }
        let journal = try await reclaimStore.load(operationID)
        guard journal.phase == .uncertain || journal.phase == .removalIntent else {
            throw LegacySyncJournalError.invalidTransition
        }
        let record = try await syncStore.load(operationID)
        guard record.phase == .accepted, record.archiveSHA256 == journal.archiveSHA256,
              record.treeSHA256 == journal.treeSHA256,
              record.archiveBytes == journal.archiveBytes else {
            throw LegacySyncJournalError.invalidRecord
        }
        try await device.requireIdentity()
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        let state = try await device.inspectOperation(operationID: operationID,
                                                      treeSHA256: journal.treeSHA256)
        if state.archive {
            _ = try await LegacyArchiveReclaim.preview(record: record,
                                                        workspace: workspace, device: device)
            try await reclaimStore.advance(operationID, from: journal.phase, to: .prepared)
        } else {
            try await requireAbsent(journal: journal, device: device)
            try await reclaimStore.advance(operationID, from: journal.phase, to: .completed)
        }
    }

    private func requireAbsent(journal: LegacyArchiveReclaimJournal,
                               device: any LegacyArchiveReclaimDevice) async throws {
        try await device.requireIdentity()
        let report = try await device.inspect()
        try LegacyGameChangeService.validateReport(report)
        let state = try await device.inspectOperation(operationID: journal.operationID,
                                                      treeSHA256: journal.treeSHA256)
        guard state.phase == .accepted, state.outcome == .newTreePresent,
              state.transaction, state.live, state.old, !state.stage,
              !state.failed, !state.lock, !state.archive else {
            throw LegacyInspectionError.invalidResponse
        }
        let archive = try await device.inspectArchive(operationID: journal.operationID,
            treeSHA256: journal.treeSHA256, archiveSHA256: journal.archiveSHA256,
            archiveBytes: journal.archiveBytes)
        guard !archive.archivePresent, archive.archiveBytes == 0 else {
            throw LegacyInspectionError.invalidResponse
        }
    }
}
