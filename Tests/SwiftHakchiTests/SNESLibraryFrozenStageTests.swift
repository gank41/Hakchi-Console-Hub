import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryFrozenStageTests {
    @Test func aCompleteCopiedMenuCanBeReviewedAndShownWithoutItsEditableMacSources() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, oldJournal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        try await oldJournal.close()
        let source = try #require(plan.material.menu.sources.first)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        let originals = try SNESLibraryCompatibilityTests().originals()
        let frozen = try SNESLibrarySyncPlan.load(data: plan.data, expectedReviewSHA256: plan.reviewSHA256, originals: originals, purpose: .recovery)
        let journal = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: frozen)
        let permit = try await journal.beginShow(attachment: SNESLibraryContextTests.device())
        try permit.require(frozen, attachment: SNESLibraryContextTests.device())
        await #expect(throws: (any Error).self) { try await journal.beginCopy() }
        try await journal.selectionUncertain(); try await journal.close()
    }
    @Test func frozenMaterialDoesNotPermitANewCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let frozen = try SNESLibrarySyncPlan.load(data: plan.data, expectedReviewSHA256: plan.reviewSHA256,
            originals: SNESLibraryCompatibilityTests().originals(), purpose: .recovery)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: plan.reviewSHA256, plan: frozen)
        await #expect(throws: (any Error).self) { try await journal.beginCopy() }
        #expect(try await journal.phase() == .prepared)
        try await journal.cancelUnstarted(); try await journal.close()
    }
}
