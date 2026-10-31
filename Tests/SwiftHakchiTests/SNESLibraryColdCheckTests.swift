import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryColdCheckTests {
    func saved(_ root: URL) async throws -> (SNESLibrarySyncPlan, SNESLibraryJournal, URL) {
        let (plan, journal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        let device = SyntheticSNESSelectionDevice(plan: plan, before: try SNESLibraryCopyTransactionTests().after(plan),
            after: try SNESLibrarySelectionTransactionTests().active(plan), fault: "success")
        _ = try await SNESLibrarySelectionTransaction.run(plan: plan, journal: journal, device: device)
        return (plan, journal, operation)
    }
    func evidence(_ plan: SNESLibrarySyncPlan, fault: String = "", suppliedInventory: SNESLibraryInventory? = nil,destination:SNESLibraryColdEvidence.Destination = .updated,pendingProof:Bool=true,pendingContext:String?=nil) throws -> SNESLibraryColdEvidence {
        let before = SNESLibraryContextTests.device(), after = SNESLibraryContextTests.device(id: fault == "same-attachment" ? 44 : 45)
        let first = UUID(), second = UUID(), expected = SNESStartupTrialExpectation(hwid: plan.before.hwid,
            runtimeSHA256: String(repeating: "2", count: 64), wrapperSHA256: String(repeating: "3", count: 64), deviceVersion: 0x6a07,
            menuWrapperSHA256: String(repeating: "4", count: 64))
        func report(_ nonce: UUID, last: Bool) -> Data {
            var text = String(decoding: startupTrialReportFixture(challenge: nonce), as: UTF8.self)
            text = text.replacingOccurrences(of: "MOUNTS_END", with: "tmpfs /etc/init.d/S81clover-mcp tmpfs rw,nosuid,nodev 0 0\n" +
                (fault == "missing-menu-config" ? "" : "tmpfs /usr/share/applications/clover-mcp.desktop tmpfs rw,nosuid,nodev 0 0\n") + "MOUNTS_END")
            if fault == "changed-process" && last { text = text.replacingOccurrences(of: "MCP_PID=101", with: "MCP_PID=103") }
            return Data(text.utf8)
        }
        let inventory = fault == "old-menu" ? plan.before : try suppliedInventory ?? SNESLibrarySelectionTransactionTests().active(plan)
        var pending:SNESLibraryRollbackPendingReceipt?
        if destination == .previous && pendingProof {
            let request=try SNESLibraryRollbackPendingCommands.prepare(id:plan.material.menu.id,context:pendingContext ?? inventory.contextSHA256,hwid:plan.before.hwid,runtime:expected.runtimeSHA256,challenge:UUID())
            pending=try .init(request.receipt,request:request)
        }
        return try .init(plan: plan, previousAttachment: before, attachment: after, expected: expected, inventory: inventory,
            challenges: [first, second], reports: [report(first, last: false), report(second, last: true)],destination:destination,pendingReceipt:pending)
    }
    @Test(arguments: ["same-attachment", "missing-menu-config", "changed-process", "old-menu"])
    func aRestartNeedsANewAttachmentConfiguredMenuAndTwoMatchingReports(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, _) = try await saved(root)
        #expect(throws: (any Error).self) { try evidence(plan, fault: fault) }
        #expect(try await journal.phase() == .awaitingRestart)
        try await journal.close()
    }
    @Test func restartAndHumanAcceptanceRequireASeparateCurrentRecoverableMacSnapshot() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await saved(root)
        try await journal.noteRestarted(evidence(plan))
        #expect(try await journal.phase() == .awaitingTest)
        let originals = try SNESLibraryCompatibilityTests().originals()
        let current = try await SNESLibraryRestoreTests().backup(root, originals: originals, menu: plan.material.menu)
        await #expect(throws: (any Error).self) { try await journal.accept(backup: plan.backup, originals: originals, current: current.inventory) }
        try await journal.accept(backup: current, originals: originals, current: current.inventory)
        #expect(try await journal.phase() == .accepted)
        let reference = try #require(try await journal.currentBackup())
        #expect(reference.directory == current.directory && reference.manifestSHA256 == current.manifestSHA256)
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        #expect(try await reopened.phase() == .accepted)
        #expect(try await reopened.currentBackup()?.manifestSHA256 == current.manifestSHA256)
        try await reopened.close()
    }
}
