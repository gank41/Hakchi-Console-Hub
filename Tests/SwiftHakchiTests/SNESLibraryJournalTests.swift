import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryJournalTests {
    @Test func unfinishedLibraryWorkBlocksFirmwareWritesByHardwareIdentity() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try await plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let empty = try SNESLibraryJournal.firmwareLease(hwid: inputs.before.hwid, root: transactions); try empty.closeLease()
        let prepared = try SNESLibraryJournal.prepare(plan: inputs, root: transactions)
        #expect(throws: (any Error).self) { try SNESLibraryJournal.firmwareLease(hwid: inputs.before.hwid, root: transactions) }
        let unrelated = try SNESLibraryJournal.firmwareLease(hwid: String(repeating: "2", count: 32), root: transactions); try unrelated.closeLease()
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: inputs)
        try await journal.cancelUnstarted(); try await journal.close()
        let cancelled = try SNESLibraryJournal.firmwareLease(hwid: inputs.before.hwid, root: transactions); try cancelled.closeLease()
    }
    func plan(_ root: URL) async throws -> SNESLibrarySyncPlan {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (material, backup, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root)
        return try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory,
            capacity: backup.inventory.capacity, installation: reference, originals: originals)
    }
    @Test func durableIntentIsExclusiveAndRevokedAfterUncertainty() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try await plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: inputs, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: inputs)
        #expect(try await journal.phase() == .prepared)
        let permit = try await journal.beginCopy(); try permit.require(inputs)
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: prepared.operation.appendingPathComponent("0001.json"))) as? [String: Any])
        #expect(record["phase"] as? String == "copyIntent")
        #expect(record["challenge"] as? String == permit.challenge.uuidString)
        await #expect(throws: (any Error).self) { try await journal.beginCopy() }
        try await journal.copyUncertain()
        #expect(throws: (any Error).self) { try permit.require(inputs) }
        #expect(try await journal.phase() == .copyUncertain)
        try await journal.close()
        let reopened = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: inputs)
        #expect(try await reopened.phase() == .copyUncertain)
        await #expect(throws: (any Error).self) { try await reopened.beginCopy() }
        try await reopened.close()
    }
    @Test func freshCaptureOfTheSameHardwareCannotBypassAnUnfinishedCopy() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await plan(root.appendingPathComponent("first")), second = try await plan(root.appendingPathComponent("second"))
        #expect(first.installation.operationID != second.installation.operationID && first.before.hwid == second.before.hwid)
        let transactions = root.appendingPathComponent("transactions"); try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: first, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: first)
        let permit = try await journal.beginCopy(); try await journal.close()
        #expect(throws: (any Error).self) { try permit.require(first) }
        #expect(throws: (any Error).self) { try SNESLibraryJournal.prepare(plan: second, root: transactions) }
    }
    @Test func cancellingAnUnstartedReviewMakesNoConsolePermit() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try await plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: inputs, root: transactions)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: inputs)
        try await journal.cancelUnstarted(); #expect(try await journal.phase() == .discarded)
        await #expect(throws: (any Error).self) { try await journal.beginCopy() }
        try await journal.close()
    }
    @Test func knownBoundedPlanBytesCanBeDurablyReadBackBeyondTheFirmwareImageLimit() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = try RestoreJournalStorage(root: root); defer { try? storage.closeLease() }
        let data = Data(repeating: 65, count: 16 * 1024 * 1024 + 1)
        try storage.write(data, name: "large-plan.json", directory: storage.root)
        #expect(try storage.root.read("large-plan.json", maximum: data.count) == data)
    }
    @Test func changedOrMissingDurableRecordsRefuseResume() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try await plan(root.appendingPathComponent("input")), transactions = root.appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: transactions, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: inputs, root: transactions)
        try Data("{}".utf8).write(to: prepared.operation.appendingPathComponent("0002.json"))
        #expect(throws: (any Error).self) { try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: inputs) }
    }
}
