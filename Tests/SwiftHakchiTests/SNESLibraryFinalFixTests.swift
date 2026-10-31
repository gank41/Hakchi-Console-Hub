import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryFinalFixTests {
    func cached(_ root: URL) async throws -> (SNESLibrarySyncPlan, URL) {
        let (initial, backup, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root.appendingPathComponent("input"))
        let transactions = root.appendingPathComponent("transactions"), parent = transactions.appendingPathComponent("Prepared")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let material = try SNESLibraryMaterial.freeze(menu: initial.menu, in: parent)
        return (try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory, capacity: backup.inventory.capacity, installation: reference, originals: originals), transactions)
    }
    @Test func completionPurgesBeforeClosingAndReleasesTheLease() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, transactions) = try await cached(root)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        try await journal.cancelUnstarted()
        #expect(try await journal.closeCompleted() == nil)
        #expect(!FileManager.default.fileExists(atPath: plan.material.directory.path))
        let lease = try SNESLibraryJournal.firmwareLease(hwid: plan.before.hwid, root: transactions); try lease.closeLease()
        try plan.backup.validate()
    }
    @Test(arguments: ["unowned", "referenced", "foreign"])
    func abandonedPreparationIsRemovedOnlyWhenNoJournalOwnsIt(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, transactions) = try await cached(root)
        if fault == "referenced" { _ = try SNESLibraryJournal.prepare(plan: plan, root: transactions) }
        if fault == "foreign" { try Data("keep".utf8).write(to: plan.material.directory.appendingPathComponent("foreign")) }
        if fault == "unowned" {
            #expect(try SNESLibraryJournal.discardUnsentMaterial(plan.material, root: transactions))
            #expect(!FileManager.default.fileExists(atPath: plan.material.directory.path))
        } else {
            #expect(throws: (any Error).self) { try SNESLibraryJournal.discardUnsentMaterial(plan.material, root: transactions) }
            #expect(FileManager.default.fileExists(atPath: plan.material.directory.path))
        }
        try plan.backup.validate()
    }
    @Test func disabledAutomaticBackupRequiresADecisionAndStillReusesAnExactCurrentCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SNESLibraryInventoryTests(), nonce = UUID(), inventory = try fixture.parse(fixture.frame(challenge: nonce), challenge: nonce)
        await #expect(throws: SNESLibraryBackupCreationRequired.self) {
            try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Issue.record("No reader should run before the backup decision"); return Data() }, refresh: { inventory }, allowCreation: false)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let saved = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Data("{}".utf8) }, refresh: { inventory })
        let reused = try await SNESLibraryBackup.capture(inventory: inventory, root: root, read: { _, _ in Issue.record("The verified current backup should be reused"); return Data() }, refresh: { inventory }, allowCreation: false)
        #expect(reused.directory.path == saved.directory.path)
        #expect(SNESLibraryWorkflowPhase.backupNeeded.action == .createBackup)
        #expect(SNESLibraryWorkflowPhase.backupNeeded.buttonTitle == "Back Up Now and Review")
    }
}
