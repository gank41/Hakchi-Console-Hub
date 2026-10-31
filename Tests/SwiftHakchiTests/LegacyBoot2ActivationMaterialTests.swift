import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct LegacyBoot2ActivationMaterialTests {
    private let hwid = "0123456789abcdef0123456789abcdef"

    @Test func recoveryObservationTranscriptOmitsPrivateHardwareID() {
        let raw = "BOARD=dp-nes\nHWID=0123456789abcdef0123456789abcdef\nEND\n"
        let message = NativeRecoveryProbeIO.redactedObservationMessage(raw)
        #expect(!message.contains(hwid))
        #expect(!message.contains("HWID="))
        #expect(message.contains("recovery observation"))
    }

    @Test func structurallyValidButUnrecognizedImageCannotBecomeActivationMaterial() throws {
        let image = snapshotFixture()
        let stock = image
        let material = LegacyBoot2ActivationMaterial(plan: .init(
            id: UUID(), expectedHWID: hwid,
            stockSHA256: BackupManifest.digest(stock), stockBytes: stock.count,
            legacySHA256: BackupManifest.digest(image), legacyBytes: image.count),
            stock: stock, legacy: image)
        #expect(throws: (any Error).self) { try material.validateIntegrity() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func completedMatchingSnapshotLoadsAndCorruptionIsRefused() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"]))
        let backing = try RestoreDirectory(root)
        let snapshot = try #require(backing.names().first(where: { $0.hasPrefix("Boot2Snapshot-") }))
        let stockDirectory = try #require(backing.names().first(where: { $0.hasPrefix("RecoveryMaterial-") }))
        let stock = root.appendingPathComponent(stockDirectory).appendingPathComponent("kernel-stock-NES.img")
        let source = root.appendingPathComponent(snapshot)
        let loaded = try LegacyBoot2ActivationMaterial.load(snapshot: source, stock: stock)
        #expect(loaded.plan.legacyBytes == 3_788_800)
        #expect(loaded.plan.legacySHA256 == "44568f4076be6d0ff9948d789409017eef1e06c37cb6c56b63acde53541c2276")
        #expect(loaded.plan.stockBytes == 2_826_240)
        #expect(loaded.plan.stockSHA256 == "83efe33290867ec6e6b5c5a18e21f8cfe6f97b079c2e3c5039c628e729755888")
        #expect(loaded.plan.expectedHWID.count == 32)
        var corrupted = loaded
        corrupted.legacy[1024] ^= 1
        #expect(throws: (any Error).self) { try corrupted.validateIntegrity() }
        var redirected = loaded.plan
        redirected = LegacyBoot2ActivationPlan(id: redirected.id,
            expectedHWID: "0123456789abcdef0123456789abcdef",
            stockSHA256: redirected.stockSHA256, stockBytes: redirected.stockBytes,
            legacySHA256: redirected.legacySHA256, legacyBytes: redirected.legacyBytes)
        #expect(throws: (any Error).self) {
            try LegacyBoot2ActivationMaterial(plan: redirected, stock: loaded.stock,
                                              legacy: loaded.legacy).validateIntegrity()
        }
    }
}
