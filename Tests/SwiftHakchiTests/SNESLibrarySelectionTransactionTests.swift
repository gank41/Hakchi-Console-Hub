import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibrarySelectionTransactionTests {
    func active(_ plan: SNESLibrarySyncPlan, fault: String = "") throws -> SNESLibraryInventory {
        let source = SNESLibraryInventoryTests(), nonce = UUID()
        var text = String(decoding: try source.frame(challenge: nonce, menu: plan.material.menu), as: UTF8.self)
            .replacingOccurrences(of: "CATALOG " + source.catalog, with: "CATALOG " + plan.before.catalogSHA256)
        if fault == "changed-save" { text = text.replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8))) }
        return try .init(raw: Data(text.utf8), challenge: nonce, contextSHA256: source.context, hwid: source.hwid, catalogSHA256: plan.before.catalogSHA256)
    }
    @Test(arguments: ["success", "lost-response", "changed-save", "bad-receipt", "source-after-publication"])
    func savedChoiceRequiresOneDispatchAndStillNeedsRestartAndTesting(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, operation) = try await SNESLibrarySelectionJournalTests().copied(root)
        let device = SyntheticSNESSelectionDevice(plan: plan, before: try SNESLibraryCopyTransactionTests().after(plan), after: try active(plan, fault: fault), fault: fault)
        if fault == "success" {
            let result = try await SNESLibrarySelectionTransaction.run(plan: plan, journal: journal, device: device)
            #expect(result.after.selection.id == plan.material.menu.id)
            #expect(try await journal.phase() == .awaitingRestart)
        } else {
            await #expect(throws: (any Error).self) { try await SNESLibrarySelectionTransaction.run(plan: plan, journal: journal, device: device) }
            #expect(try await journal.phase() == .selectionUncertain)
        }
        let counts = await device.counts(); #expect(counts.saves == 1 && counts.disconnects == 1)
        let record = try String(contentsOf: operation.appendingPathComponent("0003.json"), encoding: .utf8)
        #expect(record.contains("selectionIntent"))
        try await journal.close()
    }
    @Test func gameplaySaveChangesAreAllowedOnlyInTheLaterReadOnlyActiveCheck() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (plan, journal, _) = try await SNESLibrarySelectionJournalTests().copied(root)
        let afterGame = try active(plan, fault: "changed-save")
        #expect(throws: (any Error).self) { try SNESLibraryActiveCheck.require(plan, inventory: afterGame, preserveProfiles: true) }
        try SNESLibraryActiveCheck.require(plan, inventory: afterGame, preserveProfiles: false)
        try await journal.close()
    }
}
actor SyntheticSNESSelectionDevice: SNESLibrarySelectionDevice {
    let plan: SNESLibrarySyncPlan, before: SNESLibraryInventory, after: SNESLibraryInventory, fault: String
    private var saves = 0, disconnects = 0
    init(plan: SNESLibrarySyncPlan, before: SNESLibraryInventory, after: SNESLibraryInventory, fault: String) {
        self.plan = plan; self.before = before; self.after = after; self.fault = fault
    }
    func selectionAttachment(plan: SNESLibrarySyncPlan) -> RecoveryProbeUSBDevice { SNESLibraryContextTests.device() }
    func saveSelection(plan: SNESLibrarySyncPlan, permit: SNESLibrarySelectionPermit) throws -> SNESLibrarySelectionResult {
        saves += 1; try permit.require(plan, attachment: SNESLibraryContextTests.device())
        let record = try String(contentsOf: permit.operation.appendingPathComponent("0003.json"), encoding: .utf8); #expect(record.contains("selectionIntent"))
        if fault == "lost-response" { throw LegacyInspectionError.timeout }
        let request = try SNESLibrarySelectionCommands.prepare(menu: plan.material.menu, before: before,
            runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        if fault == "source-after-publication", let source = plan.material.menu.sources.first {
            try Data("changed".utf8).write(to: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        }
        let raw = fault == "bad-receipt" ? request.receipt + Data([10]) : request.receipt
        return try .init(plan: plan, permit: permit, request: request, raw: raw, after: after)
    }
    func disconnect() { disconnects += 1 }
    func counts() -> (saves: Int, disconnects: Int) { (saves, disconnects) }
}
