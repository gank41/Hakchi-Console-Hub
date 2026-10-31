import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@MainActor struct SNESLibraryRecoveryMaterialTests {
    @Test func missingLocalROMsDoNotPreventReadOnlyRecoveryButStillBlockNewCopies() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (material, backup, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root)
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory,
            capacity: backup.inventory.capacity, installation: reference, originals: originals)
        let pending = root.appendingPathComponent("pending"); try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        let forward = try SNESLibraryJournal.prepare(plan: plan, root: pending)
        let original = try SNESLibraryJournal(operation: forward.operation, reviewSHA256: forward.reviewSHA256, plan: plan)
        let existingPermit = try await original.beginCopy()
        for path in Set(material.menu.sources.map(\.directory)) { try FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }
        #expect(throws: (any Error).self) { try SNESLibrarySyncPlan.load(data: plan.data, expectedReviewSHA256: plan.reviewSHA256, originals: originals) }
        let recovery = try SNESLibrarySyncPlan.load(data: plan.data, expectedReviewSHA256: plan.reviewSHA256, originals: originals, purpose: .recovery)
        try recovery.requireSources()
        #expect(recovery.material.menu.objects == material.menu.objects)
        #expect(recovery.purpose == .recovery)
        #expect(throws: (any Error).self) { try existingPermit.require(recovery) }
        try await original.close()
        let journals = root.appendingPathComponent("journals"); try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
        let prepared = try SNESLibraryJournal.prepare(plan: recovery, root: journals)
        let journal = try SNESLibraryJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, plan: recovery)
        await #expect(throws: (any Error).self) { try await journal.beginCopy() }
        #expect(try await journal.phase() == .prepared)
        try await journal.close()
    }
    @Test func recoveryNeverIgnoresDamagedFrozenBytes() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (material, backup, originals, reference) = try await SNESLibrarySyncPlanTests().fixture(root)
        let plan = try SNESLibrarySyncPlan.prepare(material: material, backup: backup, before: backup.inventory,
            capacity: backup.inventory.capacity, installation: reference, originals: originals)
        let object = try #require(material.menu.objectRecords.first), path = material.directory.appendingPathComponent("object-" + object.name)
        var bytes = try Data(contentsOf: path); bytes[0] ^= 1; try bytes.write(to: path)
        #expect(throws: (any Error).self) { try SNESLibrarySyncPlan.load(data: plan.data, expectedReviewSHA256: plan.reviewSHA256, originals: originals, purpose: .recovery) }
    }
}
