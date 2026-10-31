import Foundation
import SwiftHakchiCore

protocol SNESLibraryDiscardDevice: Sendable {
    func discardAttachment(plan: SNESLibrarySyncPlan) async throws -> RecoveryProbeUSBDevice
    func discardCopy(plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation,
                     permit: SNESLibraryDiscardPermit) async throws -> SNESLibraryDiscardResult
    func disconnect() async
}
struct SNESLibraryDiscardResult: Sendable {
    let receipt: SNESLibraryCleanupReceipt, after: SNESLibraryCleanupObservation, inventory: SNESLibraryInventory
    init(plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation,
         permit: SNESLibraryDiscardPermit, request: SNESLibraryCleanupCommands.RemovalRequest, raw: Data,
         after: SNESLibraryCleanupObservation, inventory: SNESLibraryInventory) throws {
        try permit.require(plan: plan, scope: scope, preview: preview)
        guard request.challenge == permit.challenge, request.previewSHA256 == BackupManifest.digest(preview.raw),
              request.contextSHA256 == preview.contextSHA256, after.contextSHA256 == preview.contextSHA256,
              after.scopeSHA256 == scope.reviewSHA256, after.allGone else { throw SNESLibraryInventory.failure() }
        try scope.requireCurrent(plan, inventory: inventory)
        receipt = try .init(raw, request: request, scope: scope); self.after = after; self.inventory = inventory
    }
}
enum SNESLibraryDiscardTransaction {
    static func run(plan: SNESLibrarySyncPlan, journal: SNESLibraryJournal, scope: SNESLibraryDiscardPlan,
                    preview: SNESLibraryCleanupObservation, device: any SNESLibraryDiscardDevice) async throws -> SNESLibraryDiscardResult {
        var dispatched = false
        do {
            try Task.checkCancellation(); try scope.validateSources()
            let attachment = try await device.discardAttachment(plan: plan)
            try Task.checkCancellation()
            let permit = try await journal.beginDiscard(scope: scope, preview: preview, attachment: attachment); dispatched = true
            try Task.checkCancellation(); try permit.require(plan: plan, scope: scope, preview: preview)
            let result = try await device.discardCopy(plan: plan, scope: scope, preview: preview, permit: permit)
            try Task.checkCancellation(); try permit.require(plan: plan, scope: scope, preview: preview)
            try await journal.finishDiscard(scope: scope, preview: preview, receipt: result.receipt, after: result.after, inventory: result.inventory)
            await device.disconnect(); return result
        } catch {
            if dispatched { try? await Task.detached { try await journal.discardUncertain() }.value }
            await device.disconnect(); throw error
        }
    }
}
