import Foundation
import Testing
import Darwin
import os
import SwiftHakchiCore
@testable import SwiftHakchi

func restoreMaterialFixture() -> StockRestoreMaterial {
    let bytes = snapshotFixture(), hash = BackupManifest.digest(bytes)
    return StockRestoreMaterial(plan: .init(id: UUID(), expectedHWID: "0123456789abcdef0123456789abcdef",
        preimageSHA256: hash, preimageBytes: bytes.count, stockSHA256: hash, stockBytes: bytes.count), stock: bytes, preimage: bytes)
}
private enum RestoreStockFixture {
    static let stock: Result<Data, any Error> = Result {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"]))
        let directory = try RestoreDirectory(root)
        for name in try directory.names() where name.hasPrefix("RecoveryMaterial-") {
            let child = try RestoreDirectory(root.appendingPathComponent(name))
            if let bytes = try? child.read("kernel-stock-NES.img"), (try? StockKernelEvidence(data:bytes)) != nil { return bytes }
        }
        throw RecoveryProbeError.refused("No recovered stock fixture found.")
    }
}
func knownRestoreMaterial() async throws -> StockRestoreMaterial {
    let stock = try RestoreStockFixture.stock.get()
    let preimage = snapshotFixture()
    return .init(plan: .init(id: UUID(), expectedHWID: "0123456789abcdef0123456789abcdef",
        preimageSHA256: BackupManifest.digest(preimage), preimageBytes: preimage.count,
        stockSHA256: BackupManifest.digest(stock), stockBytes: stock.count), stock: stock, preimage: preimage)
}
struct StockRestoreMaterialTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func completedSnapshotLoadsAndTamperingIsRefused() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let material = try await knownRestoreMaterial()
        let stock = root.appendingPathComponent("stock.img"); try material.stock.write(to: stock)
        let report = try RecoveryRAMProbeReport(before: probeFEL(), after: probeRNDIS(),
            observation: RecoveryProbePolicy.observation(probeObservation()),
            bootSnapshot: RecoveryBootSnapshot(active: .image(material.preimage), backup: .unavailable))
        let snapshot = try await RecoveryBootSnapshotStore(root: root).save(report)
        let loaded = try StockRestoreMaterial.load(snapshot: snapshot, stock: stock)
        #expect(loaded.stock == material.stock && loaded.preimage == material.preimage)
        try loaded.validateForRestore()
        try Data("bad".utf8).write(to: snapshot.appendingPathComponent("active-boot2.img"))
        #expect(throws: (any Error).self) { try StockRestoreMaterial.load(snapshot: snapshot, stock: stock) }
    }

    @Test func unknownStockCannotBecomeExecutionMaterial() throws {
        #expect(throws: (any Error).self) { try restoreMaterialFixture().validateForRestore() }
        var changed=restoreMaterialFixture();changed.stock[1000] ^= 1
        #expect(throws: (any Error).self) { try changed.validateIntegrity() }
    }
    @Test func journalFreezesBytesPermissionsAndReviewHash() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let material=restoreMaterialFixture()
        let prepared=try StockRestoreJournal.prepare(material:material,root:root)
        #expect(try Data(contentsOf:prepared.operation.appendingPathComponent("stock.img")) == material.stock)
        #expect(try Data(contentsOf:prepared.operation.appendingPathComponent("preimage.img")) == material.preimage)
        #expect(prepared.reviewSHA256 == BackupManifest.digest(try Data(contentsOf:prepared.operation.appendingPathComponent("plan.json"))))
        for p in [prepared.operation,prepared.operation.appendingPathComponent("plan.json"),prepared.operation.appendingPathComponent("0000.json")] {
            let a=try FileManager.default.attributesOfItem(atPath:p.path)
            #expect((a[.posixPermissions] as? NSNumber)?.intValue == (p==prepared.operation ? 0o700:0o600))
        }
        let journal=try StockRestoreJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256)
        #expect(try await journal.phase() == .prepared)
        await #expect(throws:(any Error).self) { try await journal.verifiedMaterial() }
    }
    @Test func phaseOrderAndDuplicateIntentAreRejected() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        let j=try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
        await #expect(throws:(any Error).self){try await j.append(.burnIntent)}
        try await j.append(.preflightVerified);try await j.append(.burnIntent)
        await #expect(throws:(any Error).self){try await j.append(.burnIntent)}
        try await j.append(.uncertain)
        await #expect(throws:(any Error).self){try await j.append(.readbackVerified)}
    }
    @Test func rootLockPreventsConcurrentOperation() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        let j=try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
        #expect(throws:(any Error).self){try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)}
        #expect(throws:(any Error).self){try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)}
        #expect(try await j.phase() == .prepared)
    }
    @Test func changedPlanAndLinkedImageFailClosed() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        #expect(throws:(any Error).self){try StockRestoreJournal(operation:p.operation,reviewSHA256:String(repeating:"0",count:64))}
        let image=p.operation.appendingPathComponent("stock.img"), original=root.appendingPathComponent("original")
        try FileManager.default.moveItem(at:image,to:original);try FileManager.default.createSymbolicLink(at:image,withDestinationURL:original)
        #expect(throws:(any Error).self){try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)}
        #expect(try Data(contentsOf:original) == snapshotFixture())
    }
    @Test func movedOperationCannotPersistAnotherPhase() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        let j=try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
        try FileManager.default.moveItem(at:p.operation,to:root.appendingPathComponent("moved"))
        await #expect(throws:(any Error).self){try await j.append(.preflightVerified)}
    }
    @Test func failedIntentDurabilityCannotBeReportedAsSuccess() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        let fail=OSAllocatedUnfairLock(initialState:false)
        let j=try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,synchronize:{fd in fail.withLock{$0} ? -1:Darwin.fsync(fd)})
        try await j.append(.preflightVerified);fail.withLock{$0=true}
        await #expect(throws:(any Error).self){try await j.append(.burnIntent)}
    }
    @Test func unresolvedOtherOperationBlocksPreparation() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        do {
            let j=try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
            try await j.append(.preflightVerified);try await j.append(.burnIntent)
        }
        #expect(throws:(any Error).self){try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)}
    }
    @Test func corruptRecordChainAndPartialEventsDoNotAuthorizeProgress() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        try Data("partial".utf8).write(to:p.operation.appendingPathComponent("0001.json"))
        #expect(throws:(any Error).self){try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)}
    }
    @Test func menuAcceptanceIsDistinctFromReadback() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        let j=try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
        await #expect(throws:(any Error).self){try await j.append(.menuAccepted)}
        try await j.append(.preflightVerified);try await j.append(.burnIntent);try await j.append(.readbackVerified)
        #expect(try await j.phase() == .readbackVerified)
        try await j.append(.menuAccepted)
        #expect(try await j.phase() == .menuAccepted)
        await #expect(throws:(any Error).self){try await j.append(.burnIntent)}
    }
}

extension StockRestoreMaterialTests {
    @Test func explicitCloseReleasesLeaseEvenWhenActorIsRetained() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let p = try StockRestoreJournal.prepare(material:restoreMaterialFixture(),root:root)
        let retained = try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
        #expect(throws:(any Error).self) { try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256) }
        try await retained.close()
        let next = try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
        #expect(try await next.phase() == .prepared)
        await #expect(throws:(any Error).self) { try await retained.phase() }
        try await retained.close() // idempotent; cannot close a reused descriptor
        #expect(try await next.phase() == .prepared)
        try await next.close()
    }
}
