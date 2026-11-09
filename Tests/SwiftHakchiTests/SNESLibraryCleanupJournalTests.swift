import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCleanupJournalTests {
    func accepted(_ root: URL) async throws -> (SNESLibrarySyncPlan, SNESLibraryJournal, URL, SNESLibraryCleanupPlan, SNESLibraryInventory, SNESOriginalGamesFrame) {
        let (plan, live, backup, originals) = try await SNESLibraryCleanupPlanTests().fixture(root.appendingPathComponent("input"), changedROM: true)
        let transactions = root.appendingPathComponent("transactions"); try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        _ = try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: SyntheticSNESCopyDevice(plan: plan,
            after: SNESLibraryCopyTransactionTests().after(plan), fault: "success"))
        _ = try await SNESLibrarySelectionTransaction.run(plan: plan, journal: journal, device: SyntheticSNESSelectionDevice(plan: plan,
            before: SNESLibraryCopyTransactionTests().after(plan), after: live, fault: "success"))
        try await journal.noteRestarted(SNESLibraryColdCheckTests().evidence(plan, suppliedInventory: live))
        try await journal.accept(backup: backup, originals: originals, current: live)
        return (plan, journal, prepared.operation, try SNESLibraryCleanupPlan.prepare(plan: plan, current: live, backup: backup, originals: originals), live, originals)
    }
    func preview(_ scope: SNESLibraryCleanupPlan, context: String, allGone: Bool = false) throws -> SNESLibraryCleanupObservation {
        let nonce = UUID(), source = SNESLibraryCleanupObservationTests().frame(scope, nonce: nonce, context: context)
        if !allGone { return try .init(source, scope: scope, challenge: nonce, contextSHA256: context) }
        var rows = String(decoding: source, as: UTF8.self).components(separatedBy: "\n")
        for i in scope.files.indices { rows[10+i] = "MISSING_FILE \(i)" }
        for i in scope.directories.indices { rows[10+scope.files.count+i] = "MISSING_DIR \(i)" }
        rows[rows.count-3] = "TOKENS_SHA=" + BackupManifest.digest(Data(rows[10..<rows.count-3].joined(separator: "\n").utf8))
        return try .init(Data(rows.joined(separator: "\n").utf8), scope: scope, challenge: nonce, contextSHA256: context)
    }
    @Test func cleanupIsSeparatelyJournaledBoundToExactPreviewAndTerminalOnlyAfterAbsence() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation, scope, live, _) = try await accepted(root)
        let seen = try preview(scope, context: live.contextSHA256), permit = try await journal.beginCleanup(scope: scope, preview: seen)
        try permit.require(plan: plan, scope: scope, preview: seen)
        #expect(try await journal.phase() == .cleanupIntent)
        await #expect(throws: (any Error).self) { try await journal.beginCleanup(scope: scope, preview: seen) }
        let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: seen, runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        let receipt = try SNESLibraryCleanupReceipt(request.receipt, request: request, scope: scope)
        await #expect(throws: (any Error).self) { try await journal.finishCleanup(scope: scope, preview: seen, receipt: receipt, after: seen, inventory: live) }
        try await journal.finishCleanup(scope: scope, preview: seen, receipt: receipt, after: preview(scope, context: live.contextSHA256, allGone: true), inventory: live)
        #expect(try await journal.phase() == .finished)
        #expect(throws: (any Error).self) { try permit.require(plan: plan, scope: scope, preview: seen) }
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        #expect(try await reopened.phase() == .finished); try await reopened.close()
        let lease = try SNESLibraryJournal.firmwareLease(hwid: plan.before.hwid, root: operation.deletingLastPathComponent()); try lease.closeLease()
    }
    @Test func deferredCleanupUsesNextRecoveryBackupBeforeAnotherSync() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, live, backup, originals) = try await SNESLibraryCleanupPlanTests().fixture(root.appendingPathComponent("input"), changedROM: true)
        let transactions = root.appendingPathComponent("transactions"); try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        _ = try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: SyntheticSNESCopyDevice(plan: plan, after: SNESLibraryCopyTransactionTests().after(plan), fault: "success"))
        _ = try await SNESLibrarySelectionTransaction.run(plan: plan, journal: journal, device: SyntheticSNESSelectionDevice(plan: plan, before: SNESLibraryCopyTransactionTests().after(plan), after: live, fault: "success"))
        try await journal.noteRestarted(SNESLibraryColdCheckTests().evidence(plan, suppliedInventory: live))
        try await journal.finishKeepingPrevious(current: live)
        _ = try await journal.closeCompleted()
        #expect(try SNESLibraryJournal.pending(root: transactions, hwid: plan.before.hwid)?.phase == .finishedKeepingPrevious)
        // The previous backup and frozen material are still needed to validate cleanup.
        #expect(throws: (any Error).self) { try SNESLibraryJournal.backupDeletionLease(directory: plan.backup.directory, root: transactions) }
        try plan.material.validate(sourcePolicy: .frozenRecovery)
        let recoveredPlan = try SNESLibrarySyncPlan.load(data: plan.data, expectedReviewSHA256: plan.reviewSHA256, originals: originals, purpose: .recovery)
        let resumed = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: recoveredPlan)
        try await resumed.accept(backup: backup, originals: originals, current: live)
        let scope = try SNESLibraryCleanupPlan.prepare(plan: recoveredPlan, current: live, backup: backup, originals: originals)
        let seen = try preview(scope, context: live.contextSHA256)
        let permit = try await resumed.beginCleanup(scope: scope, preview: seen)
        let request = try SNESLibraryCleanupCommands.remove(scope: scope, preview: seen, runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        let receipt = try SNESLibraryCleanupReceipt(request.receipt, request: request, scope: scope)
        try await resumed.finishCleanup(scope: scope, preview: seen, receipt: receipt, after: preview(scope, context: live.contextSHA256, allGone: true), inventory: live)
        try await resumed.close()
        #expect(try SNESLibraryJournal.pending(root: transactions, hwid: plan.before.hwid) == nil)
        let next = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("next-input"))
        #expect(next.before.hwid == plan.before.hwid)
        let nextPrepared = try SNESLibraryJournal.prepare(plan: next, root: transactions)
        let nextJournal = try SNESLibraryJournal(operation: nextPrepared.operation, reviewSHA256: nextPrepared.reviewSHA256, plan: next)
        try await nextJournal.cancelUnstarted(); try await nextJournal.close()
    }
    @Test(arguments: ["lost-response", "missing-scope", "changed-preview", "unknown-file"])
    func interruptedCleanupStaysPendingAndOnlyExcludesTheOldInactiveMenu(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation, scope, live, _) = try await accepted(root)
        let seen = try preview(scope, context: live.contextSHA256), permit = try await journal.beginCleanup(scope: scope, preview: seen)
        let scopeURL = operation.appendingPathComponent("cleanup-0007-scope.json"), previewURL = operation.appendingPathComponent("cleanup-0007-preview.txt")
        if fault == "missing-scope" { try FileManager.default.removeItem(at: scopeURL) }
        if fault == "changed-preview" { try Data("changed".utf8).write(to: previewURL) }
        if fault == "unknown-file" { try Data("unknown".utf8).write(to: operation.appendingPathComponent("unknown")) }
        if fault == "lost-response" { try await journal.cleanupUncertain() }
        #expect(throws: (any Error).self) { try permit.require(plan: plan, scope: scope, preview: seen) }
        try await journal.close()
        if fault == "unknown-file" {
            #expect(throws: (any Error).self) { try SNESLibraryJournal.reconciliation(operation: operation, reviewSHA256: plan.reviewSHA256) }
        } else {
            let readOnly = try SNESLibraryJournal.reconciliation(operation: operation, reviewSHA256: plan.reviewSHA256)
            #expect(readOnly.id == plan.material.menu.id && readOnly.excludedMenuID == plan.before.selection.id)
            #expect(readOnly.excludedMenuID != plan.material.menu.id); try readOnly.require()
            #expect(throws: (any Error).self) { try SNESLibraryJournal.firmwareLease(hwid: plan.before.hwid, root: operation.deletingLastPathComponent()) }
        }
    }
}
