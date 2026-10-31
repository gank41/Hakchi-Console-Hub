import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCleanupTransactionTests {
    @Test(arguments: ["fresh", "expired", "refresh-fails", "wrong-context", "still-expired"])
    func timeSpentReviewingRefreshesEvidenceBeforeIntentWithoutRetryingDeletion(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation, scope, live, _) = try await SNESLibraryCleanupJournalTests().accepted(root)
        let initial = try SNESLibraryCleanupJournalTests().preview(scope, context: live.contextSHA256)
        let expired = try SNESLibraryCleanupObservation(initial.raw, scope: scope, challenge: initial.challenge,
            contextSHA256: initial.contextSHA256, measuredAt: Date().addingTimeInterval(-120))
        let fresh = try SNESLibraryCleanupJournalTests().preview(scope, context: live.contextSHA256)
        let foreign = try SNESLibraryCleanupJournalTests().preview(scope, context: String(repeating: "e", count: 64))
        let gone = try SNESLibraryCleanupJournalTests().preview(scope, context: live.contextSHA256, allGone: true)
        let device = SyntheticSNESCleanupDevice(plan: plan, scope: scope, preview: fresh, gone: gone, inventory: live, fault: "success")
        let calls = SNESCleanupRefreshCalls()
        let refresh: @Sendable () async throws -> SNESLibraryCleanupObservation = {
            await calls.record()
            if fault == "refresh-fails" { throw LegacyInspectionError.timeout }
            return fault == "wrong-context" ? foreign : fault == "still-expired" ? expired : fresh
        }
        if ["fresh", "expired"].contains(fault) {
            _ = try await SNESLibraryCleanupTransaction.run(plan: plan, journal: journal, scope: scope,
                preview: fault == "fresh" ? fresh : expired, device: device, refresh: refresh)
            #expect(try await journal.phase() == .finished)
            #expect(try Data(contentsOf: operation.appendingPathComponent("cleanup-0007-preview.txt")) == fresh.raw)
            #expect(await calls.count == (fault == "fresh" ? 0 : 1))
            #expect(await device.counts().removes == 1)
        } else {
            await #expect(throws: (any Error).self) {
                try await SNESLibraryCleanupTransaction.run(plan: plan, journal: journal, scope: scope,
                    preview: expired, device: device, refresh: refresh)
            }
            #expect(try await journal.phase() == .accepted)
            #expect(await calls.count == 1)
            #expect(await device.counts().removes == 0)
        }
        #expect(await device.counts().closes == 1)
        try await journal.close()
    }
    @Test(arguments: ["success", "lost-response", "bad-receipt", "not-gone", "changed-save", "cancelled"])
    func finishingUsesOneDispatchAndKeepsRecoveryWhenResultIsUncertain(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation, scope, live, _) = try await SNESLibraryCleanupJournalTests().accepted(root)
        let preview = try SNESLibraryCleanupJournalTests().preview(scope, context: live.contextSHA256)
        let gone = try SNESLibraryCleanupJournalTests().preview(scope, context: live.contextSHA256, allGone: true)
        let device = SyntheticSNESCleanupDevice(plan: plan, scope: scope, preview: preview, gone: fault == "not-gone" ? preview : gone, inventory: live, fault: fault)
        if fault == "success" {
            _ = try await SNESLibraryCleanupTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: device)
            #expect(try await journal.phase() == .finished)
        } else if fault == "cancelled" {
            let task = Task { try await SNESLibraryCleanupTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: device) }
            while !(await device.started) { await Task.yield() }
            task.cancel(); await #expect(throws: (any Error).self) { try await task.value }
            #expect(try await journal.phase() == .cleanupUncertain)
        } else {
            await #expect(throws: (any Error).self) { try await SNESLibraryCleanupTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: device) }
            #expect(try await journal.phase() == .cleanupUncertain)
        }
        let counts = await device.counts(); #expect(counts.removes == 1 && counts.closes == 1)
        try await journal.close()
        if fault != "success" {
            let recovery = try SNESLibraryJournal.reconciliation(operation: operation, reviewSHA256: plan.reviewSHA256)
            #expect(recovery.excludedMenuID == plan.before.selection.id)
        }
    }

}
private actor SNESCleanupRefreshCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
actor SyntheticSNESCleanupDevice: SNESLibraryCleanupDevice {
    let plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation, gone: SNESLibraryCleanupObservation
    let inventory: SNESLibraryInventory, fault: String
    private var removes = 0, closes = 0
    var started: Bool { removes > 0 }
    init(plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation, gone: SNESLibraryCleanupObservation,
         inventory: SNESLibraryInventory, fault: String) {
        self.plan = plan; self.scope = scope; self.preview = preview; self.gone = gone; self.inventory = inventory; self.fault = fault
    }
    func removeTemporary(plan: SNESLibrarySyncPlan, scope: SNESLibraryCleanupPlan, preview: SNESLibraryCleanupObservation, permit: SNESLibraryCleanupPermit) async throws -> SNESLibraryCleanupResult {
        removes += 1; try permit.require(plan: plan, scope: scope, preview: preview)
        let record = try String(contentsOf: permit.operation.appendingPathComponent("0007.json"), encoding: .utf8); #expect(record.contains("cleanupIntent"))
        if fault == "cancelled" { try await Task.sleep(for: .seconds(10)) }
        if fault == "lost-response" { throw LegacyInspectionError.timeout }
        let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview, runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        var after = inventory
        if fault == "changed-save" {
            let text = String(decoding: inventory.rawFrame, as: UTF8.self).replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8)))
            after = try .init(raw: Data(text.utf8), challenge: inventory.challenge, contextSHA256: inventory.contextSHA256, hwid: inventory.hwid, catalogSHA256: inventory.catalogSHA256)
        }
        return try .init(plan: plan, scope: scope, preview: preview, permit: permit, request: request,
            raw: fault == "bad-receipt" ? request.receipt + Data([10]) : request.receipt, after: gone, inventory: after)
    }
    func disconnect() { closes += 1 }
    func counts() -> (removes: Int, closes: Int) { (removes, closes) }
}
