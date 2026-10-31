import Foundation
import SwiftHakchiCore

/// A read-only cleanup preview is replaceable; a sent deletion is not. Keep
/// all new menu mutations blocked until an ambiguous deletion is reconciled.
enum LegacyCleanupWriteGate {
    static func requireClear(workspace: WorkspacePaths) async throws {
        if let historical = try LegacyHistoricalCleanup.load(workspace: workspace),
           historical.phase == .removalIntent || historical.phase == .uncertain {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let archives = LegacyArchiveReclaimJournalStore(directory: workspace.journals)
        let formerMenus = LegacyOldMenuReclaimJournalStore(directory: workspace.journals)
        if let archive = try await archives.latestUnresolved(),
           archive.phase == .removalIntent || archive.phase == .uncertain {
            throw LegacySyncJournalError.unresolvedOperation
        }
        let pendingFormer = try await formerMenus.latestUnresolved()
        if let former = pendingFormer,
           former.phase == .removalIntent || former.phase == .uncertain {
            throw LegacySyncJournalError.unresolvedOperation
        }
    }
}
