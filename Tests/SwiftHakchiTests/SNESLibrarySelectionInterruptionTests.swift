import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibrarySelectionInterruptionTests {
    @Test(arguments: ["full", "partial", "empty", "foreign"])
    func interruptedUnpublishedSelectorCanBeExplicitlyCancelledAfterReconnection(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        let permit = try await journal.beginShow(attachment: SNESLibraryContextTests.device())
        try await journal.selectionUncertain(); try await journal.close()
        let reopened = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        let recovery = try await reopened.reconciliation()
        #expect(recovery.excludedMenuID == plan.material.menu.id)
        let current = try SNESLibraryDiscardPlanTests().partial(plan)
        let selector = Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(plan.material.menu.id.uuidString)\n\(plan.wireSHA256)\n".utf8)
        let bytes = fault == "foreign" ? Data("not ours".utf8) : Data(selector.prefix(fault == "empty" ? 0 : fault == "partial" ? 31 : selector.count))
        if fault == "foreign" {
            #expect(throws: (any Error).self) { try SNESLibraryDiscardPlan.prepare(plan: plan, current: current, upload: .init(byteCount: bytes.count, sha256: BackupManifest.digest(bytes))) }
        } else {
            let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: current, upload: .init(byteCount: bytes.count, sha256: BackupManifest.digest(bytes)))
            let preview = try SNESLibraryDiscardJournalTests().preview(scope, context: current.contextSHA256)
            let removal = try await reopened.beginDiscard(scope: scope, preview: preview, attachment: SNESLibraryContextTests.device(id: 45))
            try removal.require(plan: plan, scope: scope, preview: preview)
            let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: preview, runtimeSHA256: String(repeating: "b", count: 64), challenge: removal.challenge)
            let receipt = try SNESLibraryCleanupReceipt(request.receipt, request: request, scope: scope)
            try await reopened.finishDiscard(scope: scope, preview: preview, receipt: receipt,
                after: SNESLibraryDiscardJournalTests().preview(scope, context: current.contextSHA256, gone: true), inventory: plan.before)
            #expect(try await reopened.phase() == .discarded)
        }
        #expect(throws: (any Error).self) { try permit.require(plan, attachment: SNESLibraryContextTests.device()) }
        try await reopened.close()
    }
    @Test func selectorUsesTheKnownRecoverableUploadSlotInsteadOfAnUnrecognizedFile() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root)
        let request = try SNESLibrarySelectionCommands.prepare(menu: plan.material.menu, before: SNESLibraryCopyTransactionTests().after(plan), runtimeSHA256: String(repeating: "b", count: 64), challenge: UUID())
        #expect(request.script.contains("pending=\"$stage/.upload\""))
        #expect(!request.script.contains("$stage/.selection-"))
    }
}
