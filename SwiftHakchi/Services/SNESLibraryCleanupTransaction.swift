import Foundation
import SwiftHakchiCore

protocol SNESLibraryCleanupDevice: Sendable {
    func removeTemporary(plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation,
                         permit: SNESLibraryCleanupPermit) async throws -> SNESLibraryCleanupResult
    func disconnect() async
}
/// Evidence from one cleanup attempt. Parsed receipts alone never authorize a write.
struct SNESLibraryCleanupResult: Sendable {
    let receipt: SNESLibraryCleanupReceipt, after: SNESLibraryCleanupObservation, inventory: SNESLibraryInventory
    init(plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation, permit: SNESLibraryCleanupPermit,
         request: SNESLibraryCleanupCommands.RemovalRequest, raw: Data, after: SNESLibraryCleanupObservation, inventory: SNESLibraryInventory) throws {
        try permit.require(plan: plan, scope: scope, preview: preview)
        guard request.challenge == permit.challenge, request.previewSHA256 == BackupManifest.digest(preview.raw),
              request.contextSHA256 == preview.contextSHA256, after.contextSHA256 == preview.contextSHA256,
              after.scopeSHA256 == scope.reviewSHA256, after.allGone else { throw SNESLibraryInventory.failure() }
        try scope.requireCurrent(plan, inventory: inventory)
        receipt = try .init(raw, request: request, scope: scope); self.after = after; self.inventory = inventory
    }
}
enum SNESLibraryCleanupTransaction {
    static func run(plan: SNESLibrarySyncPlan, journal: SNESLibraryJournal, scope: SNESLibraryCleanupPlan,
                    preview: SNESLibraryCleanupObservation, device: any SNESLibraryCleanupDevice,
                    refresh: (@Sendable () async throws -> SNESLibraryCleanupObservation)? = nil) async throws -> SNESLibraryCleanupResult {
        var dispatched = false
        do {
            try Task.checkCancellation(); try plan.requireSources(); try scope.validateSources()
            var current = preview
            if !(0...60).contains(Date().timeIntervalSince(preview.measuredAt)) {
                guard let refresh else { throw SNESLibraryInventory.failure() }
                current = try await refresh()
                try Task.checkCancellation()
                guard current.scopeSHA256 == preview.scopeSHA256, current.scopeSHA256 == scope.reviewSHA256,
                      current.contextSHA256 == preview.contextSHA256 else { throw SNESLibraryInventory.failure() }
            }
            // Refresh is read-only and precedes durable intent. The journal keeps
            // its original freshness gate; an uncertain deletion is never retried.
            let permit = try await journal.beginCleanup(scope: scope, preview: current); dispatched = true
            try Task.checkCancellation(); try permit.require(plan: plan, scope: scope, preview: current)
            let result = try await device.removeTemporary(plan: plan, scope: scope, preview: current, permit: permit)
            try Task.checkCancellation(); try permit.require(plan: plan, scope: scope, preview: current)
            try await journal.finishCleanup(scope: scope, preview: current, receipt: result.receipt, after: result.after, inventory: result.inventory)
            await device.disconnect(); return result
        } catch {
            if dispatched { try? await Task.detached { try await journal.cleanupUncertain() }.value }
            await device.disconnect(); throw error
        }
    }
}
