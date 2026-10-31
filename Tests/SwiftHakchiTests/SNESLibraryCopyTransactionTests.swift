import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryCopyTransactionTests {
    func after(_ plan: SNESLibrarySyncPlan, fault: String = "") throws -> SNESLibraryInventory {
        let before = plan.before, menu = plan.material.menu, wire = try SNESLibraryStartupScripts.manifest(for: menu)
        var rows = String(decoding: before.rawFrame, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "END" }
        rows = rows.map { $0.hasPrefix("NAMESPACE ") ? "NAMESPACE ready ready" : $0 }
        rows.append("MENU library \(menu.id.uuidString) \(plan.wireSHA256) \(wire.count) \(menu.manifest.count) \(plan.descriptionSHA256)")
        for record in menu.objectRecords {
            if before.capacity.objects[record.name] == nil { rows.append("OBJECT \(record.name) \(record.byteCount) \(record.sha256)") }
            rows.append("REF \(menu.id.uuidString) \(record.name)")
        }
        if fault == "extra-object" { let hash = BackupManifest.digest(Data([255])); rows.append("OBJECT \(hash).sfrom 1 \(hash)") }
        if fault == "changed-save" {
            rows = rows.map { $0.contains(SNESLibraryInventoryTests().hex("clover/settings.json")) ? $0.replacingOccurrences(of: BackupManifest.digest(Data("{}".utf8)), with: BackupManifest.digest(Data("[]".utf8))) : $0 }
        }
        rows.append("END")
        return try .init(raw: Data((rows.joined(separator: "\n") + "\n").utf8), challenge: before.challenge, contextSHA256: before.contextSHA256,
            hwid: before.hwid, catalogSHA256: before.catalogSHA256)
    }
    @Test(arguments: ["success", "lost-response", "extra-object", "changed-save", "bad-receipt", "source-after-transfer"])
    func journalIntentPrecedesExactlyOneCopyAndFailureRetainsRecovery(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        let device = SyntheticSNESCopyDevice(plan: plan, after: try after(plan, fault: fault), fault: fault)
        if fault == "success" {
            let result = try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: device)
            #expect(result.after.snapshotSHA256 == plan.before.snapshotSHA256)
            #expect(try await journal.phase() == .copied)
        } else {
            await #expect(throws: (any Error).self) { try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: device) }
            #expect(try await journal.phase() == .copyUncertain)
        }
        let counts = await device.counts(); #expect(counts.copies == 1 && counts.disconnects == 1)
        await #expect(throws: (any Error).self) { try await journal.beginCopy() }
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        #expect(try await reopened.phase() == (fault == "success" ? .copied : .copyUncertain))
        try await reopened.close()
    }
    @Test func cancellationDuringTransferDoesNotAcceptOrRetryTheCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        let device = SyntheticSNESCopyDevice(plan: plan, after: try after(plan), fault: "pause")
        let task = Task { try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: device) }
        await device.waitUntilCopy(); task.cancel(); await device.releaseCopy()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await journal.phase() == .copyUncertain)
        let counts = await device.counts(); #expect(counts.copies == 1 && counts.disconnects == 1)
        try await journal.close()
    }
    @Test func reviewChangesBeforeDispatchMakeNoCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await SNESLibraryJournalTests().plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: plan, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: plan)
        let device = SyntheticSNESCopyDevice(plan: plan, after: try after(plan), fault: "")
        let source = try #require(plan.material.menu.sources.first)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        await #expect(throws: (any Error).self) { try await SNESLibraryCopyTransaction.run(plan: plan, journal: journal, device: device) }
        #expect(try await journal.phase() == .prepared)
        let counts = await device.counts(); #expect(counts.copies == 0 && counts.disconnects == 1)
        try await journal.close()
    }
}
actor SyntheticSNESCopyDevice: SNESLibraryCopyDevice {
    let plan: SNESLibrarySyncPlan, after: SNESLibraryInventory, fault: String
    private var copies = 0, disconnects = 0
    private var entered = false, gate: CheckedContinuation<Void, Never>?, waiters: [CheckedContinuation<Void, Never>] = []
    init(plan: SNESLibrarySyncPlan, after: SNESLibraryInventory, fault: String) { self.plan = plan; self.after = after; self.fault = fault }
    func copy(plan: SNESLibrarySyncPlan, permit: SNESLibraryCopyPermit) async throws -> SNESLibraryCopyResult {
        copies += 1; try permit.require(plan)
        let record = try String(contentsOf: permit.operation.appendingPathComponent("0001.json"), encoding: .utf8)
        #expect(record.contains("copyIntent"))
        if fault == "pause" {
            entered = true; waiters.forEach { $0.resume() }; waiters.removeAll()
            await withCheckedContinuation { gate = $0 }
        }
        if fault == "source-after-transfer", let source = plan.material.menu.sources.first {
            try Data("changed".utf8).write(to: URL(fileURLWithPath: source.directory).appendingPathComponent(source.name))
        }
        if fault == "lost-response" { throw LegacyInspectionError.timeout }
        let request = try SNESLibraryCopyCommands.prepare(menu: plan.material.menu, before: plan.before,
            runtimeSHA256: String(repeating: "b", count: 64), challenge: permit.challenge)
        var raw = Data((request.receiptPrefix + "FREE_BYTES=200000000\nEND\n").utf8)
        if fault == "bad-receipt" { raw.append(10) }
        return try SNESLibraryCopyResult(plan: plan, permit: permit, request: request, raw: raw, after: after)
    }
    func waitUntilCopy() async { if entered { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseCopy() { gate?.resume(); gate = nil }
    func disconnect() { disconnects += 1 }
    func counts() -> (copies: Int, disconnects: Int) { (copies, disconnects) }
}
