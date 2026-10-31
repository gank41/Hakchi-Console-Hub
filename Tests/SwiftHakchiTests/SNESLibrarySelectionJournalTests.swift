import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibrarySelectionJournalTests {
    func copied(_ root: URL, nativeArtwork: Bool = false) async throws -> (SNESLibrarySyncPlan, SNESLibraryJournal, URL) {
        let plan: SNESLibrarySyncPlan
        if nativeArtwork {
            let input=root.appendingPathComponent("input")
            try FileManager.default.createDirectory(at:input,withIntermediateDirectories:true)
            let (old,backup,originals,reference)=try await SNESLibrarySyncPlanTests().fixture(input)
            let nativeRoot=root.appendingPathComponent("native")
            try FileManager.default.createDirectory(at:nativeRoot,withIntermediateDirectories:false)
            let material=try SNESLibraryMaterial.freeze(menu:old.menu.withNativeArtwork(),in:nativeRoot)
            plan=try SNESLibrarySyncPlan.prepare(material:material,backup:backup,before:backup.inventory,capacity:backup.inventory.capacity,installation:reference,originals:originals)
        } else {plan=try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input"))}
        let transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        let device = SyntheticSNESCopyDevice(plan: plan, after: try SNESLibraryCopyTransactionTests().after(plan), fault: "success")
        _ = try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: device)
        return (plan, journal, prepared.operation)
    }
    @Test func nativeArtworkSelectionIntentSurvivesJournalReopenWithoutAcceptingIt() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let (plan,journal,operation)=try await copied(root,nativeArtwork:true)
        let attachment=SNESLibraryContextTests.device(version:0x6a0b)
        let permit=try await journal.beginShow(attachment:attachment)
        try permit.require(plan,attachment:attachment)
        #expect(try await journal.phase() == .selectionIntent)
        try await journal.selectionUncertain();try await journal.close()
        let reopened=try SNESLibraryJournal(operation:operation,reviewSHA256:plan.reviewSHA256,plan:plan)
        #expect(try await reopened.phase() == .selectionUncertain)
        await #expect(throws:(any Error).self) {try await reopened.beginShow(attachment:attachment)}
        try await reopened.close()
    }
    @Test(arguments: ["saved", "lost-response"])
    func savingRequiresItsOwnDurablePermitAndDoesNotAcceptTheSync(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await copied(root), attachment = SNESLibraryContextTests.device()
        let permit = try await journal.beginShow(attachment: attachment)
        try permit.require(plan, attachment: attachment)
        #expect(throws: (any Error).self) { try permit.require(plan, attachment: SNESLibraryContextTests.device(id: 45)) }
        let row = try String(contentsOf: operation.appendingPathComponent("0003.json"), encoding: .utf8)
        #expect(row.contains("selectionIntent"))
        await #expect(throws: (any Error).self) { try await journal.beginShow(attachment: attachment) }
        if fault == "saved" {
            let request = try SNESLibrarySelectionCommands.prepare(menu: plan.material.menu, before: SNESLibraryCopyTransactionTests().after(plan),
                runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
            try await journal.noteSelectionSaved(SNESLibrarySelectionReceipt(request.receipt, request: request))
            #expect(try await journal.phase() == .awaitingRestart)
        } else {
            try await journal.selectionUncertain()
            #expect(try await journal.phase() == .selectionUncertain)
        }
        #expect(throws: (any Error).self) { try permit.require(plan, attachment: attachment) }
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: operation, reviewSHA256: plan.reviewSHA256, plan: plan)
        #expect(try await reopened.phase() == (fault == "saved" ? .awaitingRestart : .selectionUncertain))
        try await reopened.close()
        if fault == "lost-response" {
            let recovery = try SNESLibraryJournal.reconciliation(operation: operation, reviewSHA256: plan.reviewSHA256)
            try recovery.require(); #expect(recovery.id == plan.material.menu.id)
        }
    }
    @Test func unsentOrChangedSourceReviewCannotSaveAMenuChoice() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, _) = try await copied(root)
        let source = try #require(plan.material.menu.sources.first)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        await #expect(throws: (any Error).self) { try await journal.beginShow(attachment: SNESLibraryContextTests.device()) }
        #expect(try await journal.phase() == .copied)
        try await journal.close()
    }
}
