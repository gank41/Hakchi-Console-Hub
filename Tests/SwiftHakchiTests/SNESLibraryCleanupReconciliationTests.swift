import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCleanupReconciliationTests {
    func withoutRetired(_ live: SNESLibraryInventory, scope: SNESLibraryCleanupPlan) throws -> SNESLibraryInventory {
        let old = scope.oldMenuID?.uuidString
        let rows = String(decoding: live.rawFrame, as: UTF8.self).components(separatedBy: "\n").filter { line in
            let p = line.split(separator: " ").map(String.init)
            if p.first == "MENU", p.count > 2, p[2] == old { return false }
            if p.first == "REF", p.count > 1, p[1] == old { return false }
            if p.first == "OBJECT", p.count > 1, scope.retiredObjects.contains(p[1]) { return false }
            return true
        }
        return try .init(raw: Data(rows.joined(separator: "\n").utf8), challenge: live.challenge, contextSHA256: live.contextSHA256,
            hwid: live.hwid, catalogSHA256: live.catalogSHA256)
    }
    @Test(arguments: ["accepted", "intent", "uncertain"])
    func freshAbsenceFinishesTheSavedOperationWithoutAnotherDelete(_ startingPhase: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryCleanupJournalTests()
        let (plan, journal, operation, scope, live, _) = try await fixture.accepted(root)
        if startingPhase != "accepted" {
            _ = try await journal.beginCleanup(scope: scope, preview: fixture.preview(scope, context: live.contextSHA256))
            if startingPhase == "uncertain" { try await journal.cleanupUncertain() }
        }
        let gone = try withoutRetired(live, scope: scope), preview = try fixture.preview(scope, context: live.contextSHA256, allGone: true)
        try await journal.recordInspectedCleanup(scope: scope, preview: preview, inventory: gone)
        #expect(try await journal.phase() == .finished)
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        #expect(try await reopened.phase() == .finished); try await reopened.close()
        #expect(try SNESLibraryJournal.pending(root: operation.deletingLastPathComponent(), hwid: plan.before.hwid) == nil)
    }
    @Test(arguments: ["present-target", "still-listed", "stale", "changed-save"])
    func absenceCannotBeInferredFromOnlyOneOrStalePartOfTheObservation(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryCleanupJournalTests()
        let (_, journal, _, scope, live, _) = try await fixture.accepted(root)
        var inventory = try withoutRetired(live, scope: scope)
        if fault == "still-listed" { inventory = live }
        if fault == "changed-save" {
            let raw = String(decoding: inventory.rawFrame, as: UTF8.self).replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8)))
            inventory = try .init(raw: Data(raw.utf8), challenge: inventory.challenge, contextSHA256: inventory.contextSHA256, hwid: inventory.hwid, catalogSHA256: inventory.catalogSHA256)
        }
        let preview = try fixture.preview(scope, context: live.contextSHA256, allGone: fault != "present-target")
        let now = Date().addingTimeInterval(fault == "stale" ? 61 : 0)
        await #expect(throws: (any Error).self) { try await journal.recordInspectedCleanup(scope: scope, preview: preview, inventory: inventory, now: now) }
        #expect(try await journal.phase() == .accepted)
        try await journal.close()
    }
}
