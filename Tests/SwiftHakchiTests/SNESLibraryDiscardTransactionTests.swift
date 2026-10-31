import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryDiscardTransactionTests {
    @Test(arguments: ["success", "lost-response", "bad-receipt", "not-gone", "cancelled"])
    func removalUsesOneDispatchAndNeverRetriesAnUncertainResult(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        let live = try SNESLibraryCopyTransactionTests().after(plan)
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: live, upload: nil)
        let preview = try SNESLibraryDiscardJournalTests().preview(scope, context: live.contextSHA256)
        let gone = try SNESLibraryDiscardJournalTests().preview(scope, context: live.contextSHA256, gone: true)
        let device = SyntheticSNESDiscardDevice(inventory: plan.before, gone: fault == "not-gone" ? preview : gone, fault: fault)
        if fault == "success" {
            _ = try await SNESLibraryDiscardTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: device)
            #expect(try await journal.phase() == .discarded)
        } else if fault == "cancelled" {
            let task = Task { try await SNESLibraryDiscardTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: device) }
            while !(await device.started) { await Task.yield() }
            task.cancel(); await device.release(); await #expect(throws: (any Error).self) { try await task.value }
            #expect(try await journal.phase() == .discardUncertain)
        } else {
            await #expect(throws: (any Error).self) { try await SNESLibraryDiscardTransaction.run(plan: plan, journal: journal, scope: scope, preview: preview, device: device) }
            #expect(try await journal.phase() == .discardUncertain)
        }
        let counts = await device.counts(); #expect(counts.removes == 1 && counts.closes == 1)
        try await journal.close()
        if fault != "success" { #expect(try SNESLibraryJournal.reconciliation(operation: operation, reviewSHA256: plan.reviewSHA256).excludedMenuID == plan.material.menu.id) }
    }
}
actor SyntheticSNESDiscardDevice: SNESLibraryDiscardDevice {
    let inventory: SNESLibraryInventory, gone: SNESLibraryCleanupObservation, fault: String
    private var removes = 0, closes = 0
    private var paused: CheckedContinuation<Void,Never>?
    var started: Bool { paused != nil }
    func release() { paused?.resume(); paused=nil }
    init(inventory: SNESLibraryInventory, gone: SNESLibraryCleanupObservation, fault: String) { self.inventory = inventory; self.gone = gone; self.fault = fault }
    func discardAttachment(plan: SNESLibrarySyncPlan) -> RecoveryProbeUSBDevice { SNESLibraryContextTests.device() }
    func discardCopy(plan: SNESLibrarySyncPlan, scope: SNESLibraryDiscardPlan, preview: SNESLibraryCleanupObservation,
                     permit: SNESLibraryDiscardPermit) async throws -> SNESLibraryDiscardResult {
        removes += 1; try permit.require(plan: plan, scope: scope, preview: preview)
        try permit.claimDispatch()
        #expect(throws: (any Error).self) { try permit.claimDispatch() }
        let records=try FileManager.default.contentsOfDirectory(atPath:permit.operation.path).filter {$0.range(of:#"^[0-9]{4}\.json$"#,options:.regularExpression) != nil}.sorted()
        let last=try #require(records.last)
        let record = try String(contentsOf: permit.operation.appendingPathComponent(last), encoding: .utf8)
        #expect(record.contains("discardIntent"))
        if fault == "cancelled" { await withCheckedContinuation { paused=$0 } }
        if fault == "lost-response" { throw LegacyInspectionError.timeout }
        let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview, runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        return try .init(plan: plan, scope: scope, preview: preview, permit: permit, request: request,
            raw: fault == "bad-receipt" ? request.receipt + Data([10]) : request.receipt, after: gone, inventory: inventory)
    }
    func disconnect() { closes += 1 }
    func counts() -> (removes: Int, closes: Int) { (removes, closes) }
}
