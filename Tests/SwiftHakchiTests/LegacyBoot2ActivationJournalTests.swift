import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func knownLegacyActivationMaterial() throws -> LegacyBoot2ActivationMaterial {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"]))
    let directory = try RestoreDirectory(root)
    let snapshot = try #require(directory.names().first(where: { $0.hasPrefix("Boot2Snapshot-") }))
    let recovery = try #require(directory.names().first(where: { $0.hasPrefix("RecoveryMaterial-") }))
    return try LegacyBoot2ActivationMaterial.load(
        snapshot: root.appendingPathComponent(snapshot),
        stock: root.appendingPathComponent(recovery).appendingPathComponent("kernel-stock-NES.img"))
}

struct LegacyBoot2ActivationJournalTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func frozenImagesAndPhaseChainRefuseCorruptionAndDuplicateIntent() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let material = try knownLegacyActivationMaterial()
        let prepared = try LegacyBoot2ActivationJournal.prepare(material: material, root: root)
        #expect(try Data(contentsOf: prepared.operation.appendingPathComponent("legacy.img")) == material.legacy)
        #expect(try Data(contentsOf: prepared.operation.appendingPathComponent("stock.img")) == material.stock)
        #expect(prepared.reviewSHA256 == BackupManifest.digest(try Data(contentsOf: prepared.operation.appendingPathComponent("plan.json"))))
        let journal = try LegacyBoot2ActivationJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        #expect(try await journal.phase() == .prepared)
        await #expect(throws: (any Error).self) { try await journal.append(.burnIntent) }
        try await journal.append(.preflightVerified)
        try await journal.append(.burnIntent)
        await #expect(throws: (any Error).self) { try await journal.append(.burnIntent) }
        try await journal.close()
        var image = try Data(contentsOf: prepared.operation.appendingPathComponent("legacy.img"))
        image[1024] ^= 1
        try image.write(to: prepared.operation.appendingPathComponent("legacy.img"))
        #expect(throws: (any Error).self) { try LegacyBoot2ActivationJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func unresolvedLegacyOperationBlocksStockRestoreInSameJournalRoot() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try LegacyBoot2ActivationJournal.prepare(material: knownLegacyActivationMaterial(), root: root)
        let journal = try LegacyBoot2ActivationJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
        try await journal.append(.preflightVerified)
        try await journal.append(.burnIntent)
        try await journal.close()
        #expect(throws: (any Error).self) { try StockRestoreJournal.prepare(material: restoreMaterialFixture(), root: root) }
    }
}
