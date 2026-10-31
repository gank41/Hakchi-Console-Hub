import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryDiscardJournalTests {
    func preview(_ scope: SNESLibraryDiscardPlan, context: String, gone: Bool = false, at: Date = Date()) throws -> SNESLibraryCleanupObservation {
        var tokens = scope.fileTargets.enumerated().map { i, f in gone ? "MISSING_FILE \(i)" : "FILE \(i) \(f.byteCount) \(f.sha256) 384 1 1 \(i+100) 1" }
        tokens += scope.directories.indices.map { gone ? "MISSING_DIR \($0)" : "DIR \($0) 448 1 \($0+2000)" }
        let nonce = UUID()
        let rows = ["SWIFTHAKCHI_SNES_CLEANUP_PREVIEW_V1", "CHALLENGE=\(nonce.uuidString)", "SCOPE=\(scope.reviewSHA256)", "CONTEXT=\(context)", "HWID=\(scope.hwid)", "SELECTOR=\(scope.selection.selectorSHA256)", "DEVICE=1", "FREE_BYTES=200000000", "FILES=\(scope.fileTargets.count)", "DIRS=\(scope.directories.count)"] + tokens + ["TOKENS_SHA=\(BackupManifest.digest(Data(tokens.joined(separator: "\n").utf8)))", "END", ""]
        return try .init(Data(rows.joined(separator: "\n").utf8), scope: scope, challenge: nonce, contextSHA256: context, measuredAt: at)
    }
    @Test(arguments: ["gone", "present", "stale"])
    func lostAcknowledgementResolvesOnlyFromFreshAbsenceWithoutAnotherPermit(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        let live = try SNESLibraryCopyTransactionTests().after(plan)
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: live, upload: nil)
        let seen = try preview(scope, context: live.contextSHA256)
        _ = try await journal.beginDiscard(scope: scope, preview: seen, attachment: SNESLibraryContextTests.device())
        try await journal.discardUncertain()
        let check = try preview(scope, context: live.contextSHA256, gone: fault != "present", at: Date().addingTimeInterval(fault == "stale" ? -61 : 0))
        if fault == "gone" {
            try await journal.recordInspectedDiscard(scope: scope, preview: check, inventory: plan.before)
            #expect(try await journal.phase() == .discarded)
        } else {
            await #expect(throws: (any Error).self) { try await journal.recordInspectedDiscard(scope: scope, preview: check, inventory: plan.before) }
            #expect(try await journal.phase() == .discardUncertain)
        }
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        #expect(try await reopened.phase() == (fault == "gone" ? .discarded : .discardUncertain)); try await reopened.close()
    }

    @Test(arguments: ["complete", "uncertain", "missing-aux", "stale", "changed-active"])
    func cancellationRequiresDurableExactIntentAndKeepsWorkingLibrary(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        let live = try SNESLibraryCopyTransactionTests().after(plan)
        let scope = try SNESLibraryDiscardPlan.prepare(plan: plan, current: live, upload: nil)
        let seen = try preview(scope, context: live.contextSHA256, at: Date().addingTimeInterval(fault == "stale" ? -61 : 0))
        if fault == "stale" {
            await #expect(throws: (any Error).self) { try await journal.beginDiscard(scope: scope, preview: seen, attachment: SNESLibraryContextTests.device()) }
            try await journal.close(); return
        }
        let permit = try await journal.beginDiscard(scope: scope, preview: seen, attachment: SNESLibraryContextTests.device())
        try permit.require(plan: plan, scope: scope, preview: seen)
        #expect(try await journal.phase() == .discardIntent)
        await #expect(throws: (any Error).self) { try await journal.beginDiscard(scope: scope, preview: seen, attachment: SNESLibraryContextTests.device()) }
        let recon = try await journal.reconciliation()
        #expect(recon.excludedMenuID == plan.material.menu.id && recon.allowsIncompleteNamespace)
        let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: seen, runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        let receipt = try SNESLibraryCleanupReceipt(request.receipt, request: request, scope: scope)
        if fault == "uncertain" { try await journal.discardUncertain() }
        else if fault == "missing-aux" { try FileManager.default.removeItem(at: operation.appendingPathComponent("discard-0003-scope.json")) }
        else {
            await #expect(throws: (any Error).self) { try await journal.finishDiscard(scope: scope, preview: seen, receipt: receipt, after: seen, inventory: live) }
            if fault == "changed-active" {
                await #expect(throws: (any Error).self) { try await journal.finishDiscard(scope: scope, preview: seen, receipt: receipt, after: preview(scope, context: live.contextSHA256, gone: true), inventory: live) }
                try await journal.discardUncertain()
            } else {
                try await journal.finishDiscard(scope: scope, preview: seen, receipt: receipt, after: preview(scope, context: live.contextSHA256, gone: true), inventory: plan.before)
                #expect(try await journal.phase() == .discarded)
            }
        }
        #expect(throws: (any Error).self) { try permit.require(plan: plan, scope: scope, preview: seen) }
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        #expect(try await reopened.phase() == (fault == "complete" ? .discarded : fault == "missing-aux" ? .discardIntent : .discardUncertain))
        try await reopened.close()
        if fault == "complete" {
            let lease = try SNESLibraryJournal.firmwareLease(hwid: plan.before.hwid, root: operation.deletingLastPathComponent()); try lease.closeLease()
        } else { try SNESLibraryJournal.reconciliation(operation: operation, reviewSHA256: plan.reviewSHA256).require() }
    }
}
