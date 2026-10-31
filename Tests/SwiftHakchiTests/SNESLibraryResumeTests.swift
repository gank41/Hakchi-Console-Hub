import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryResumeTests {
    @Test func onlyThisHardwareUnfinishedOperationIsOfferedForResume() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        try await journal.close()
        let pending = try #require(try SNESLibraryJournal.pending(root: operation.deletingLastPathComponent(), hwid: plan.before.hwid))
        #expect(pending.operation == operation && pending.reviewSHA256 == plan.reviewSHA256 && pending.phase == .copied)
        #expect(try SNESLibraryJournal.pending(root: operation.deletingLastPathComponent(), hwid: String(repeating: "9", count: 32)) == nil)
    }
    @Test func anUnsentReviewCanBeClosedWithoutEditableSourcesOrAnyConsoleCall() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let source = try #require(plan.material.menu.sources.first)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        try SNESLibraryJournal.closeUnsentReview(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        #expect(try SNESLibraryJournal.pending(root: transactions, hwid: plan.before.hwid) == nil)
        let lease = try SNESLibraryJournal.firmwareLease(hwid: plan.before.hwid, root: transactions); try lease.closeLease()
    }
    @Test func liveJournalCanInspectItsUncertainStageWithoutReleasingItsLease() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        _ = try await journal.beginCopy(); try await journal.copyUncertain()
        let inspection = try await journal.reconciliation()
        try inspection.require()
        #expect(inspection.excludedMenuID == plan.material.menu.id && inspection.hwid == plan.before.hwid)
        #expect(inspection.allowsIncompleteNamespace)
        // A parallel operation still cannot acquire the same root while this actor owns it.
        #expect(throws: (any Error).self) { try SNESLibraryJournal.firmwareLease(hwid: plan.before.hwid, root: transactions) }
        try await journal.recordInspectedCopy(SNESLibraryCopyTransactionTests().after(plan))
        #expect(throws: (any Error).self) { try inspection.require() }
        try await journal.close()
    }
    @Test func existingNamespaceCannotBeTreatedAsAnUnfinishedNewBase() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, _, _, _) = try await SNESLibraryCleanupPlanTests().fixture(root.appendingPathComponent("input"), changedROM: true)
        let transactions = root.appendingPathComponent("transactions"); try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        _ = try await journal.beginCopy(); try await journal.copyUncertain()
        let inspection = try await journal.reconciliation()
        #expect(!inspection.allowsIncompleteNamespace)
        try await journal.close()
    }
    @Test(arguments: ["complete", "wrong-state"])
    func uncertainCopyIsOnlyAdoptedAfterACompleteUnchangedInactiveLibraryIsObserved(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        let permit = try await journal.beginCopy(); try await journal.copyUncertain()
        #expect(throws: (any Error).self) { try permit.require(plan) }
        if fault == "complete" {
            try await journal.recordInspectedCopy(SNESLibraryCopyTransactionTests().after(plan))
            #expect(try await journal.phase() == .copied)
            await #expect(throws: (any Error).self) { try await journal.beginCopy() }
        } else {
            await #expect(throws: (any Error).self) { try await journal.recordInspectedCopy(plan.before) }
            #expect(try await journal.phase() == .copyUncertain)
        }
        try await journal.close()
        #expect(throws: (any Error).self) { try SNESLibraryJournal.closeUnsentReview(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256) }
    }
}
