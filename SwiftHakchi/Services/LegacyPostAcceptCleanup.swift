import Foundation
import SwiftHakchiCore

/// Acceptance never repeats a menu switch. Cleanup has its own durable record;
/// a failed connection leaves installed games accepted and reports cleanup pending.
enum LegacyPostAcceptCleanup {
    static func run(workspace: WorkspacePaths, lease: LegacySessionLease,
                    progress: @Sendable (String) -> Void) async throws {
        guard let accepted = try await LegacySyncJournalStore(directory: workspace.journals).latestAcceptedMenu() else {
            throw LegacySyncJournalError.invalidRecord
        }
        let archiveStore = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        if (try? await archiveStore.load(accepted.operationID).phase) != .completed {
            progress("Removing the verified transfer archive from the NES…")
            let archiveService = LegacyArchiveReclaimTransaction(workspace: workspace)
            let device = LegacySyncLeaseDevice(lease: lease)
            let preview = try await archiveService.prepare(operationID: accepted.operationID, device: device)
            try await archiveService.remove(preview: preview, device: device)
        }
        let service = LegacyHistoricalCleanupService(workspace: workspace)
        let record: LegacyHistoricalCleanup.Record
        do { record = try await service.prepare(lease: lease, progress: progress) }
        catch LegacyHistoricalCleanup.Failure.noOldFiles { return }
        try await service.remove(record, lease: lease, progress: progress)
    }
}
