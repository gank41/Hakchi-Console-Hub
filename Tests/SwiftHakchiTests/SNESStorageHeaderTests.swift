import Foundation
import Testing
@testable import SwiftHakchi
import SwiftHakchiCore

private func putSNESWord(_ value: UInt32, in bytes: inout Data, at offset: Int) {
    for i in 0..<4 { bytes[offset+i] = UInt8((value >> (i*8)) & 255) }
}
private func snes64BitHeader() -> Data {
    var bytes = Data(repeating: 0, count: 2048)
    for (offset, value) in [(1028, UInt32(76800)), (1036, 70051), (1048, 2), (1052, 2),
                            (1100, 1), (1116, 0x3c), (1120, 0x2c2), (1124, 0x63)] {
        putSNESWord(value, in: &bytes, at: offset)
    }
    bytes[1080] = 0x53; bytes[1081] = 0xef; bytes[1082] = 1
    bytes[1112] = 128; bytes[1278] = 64
    return bytes
}
private func snesHeaderFrame(_ bytes: Data) -> Data {
    Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(bytes))\n".utf8) + bytes
}
private func reportWithSNESHeader(_ frame: Data, partitions: Data = Data(legacyPartitionsFixture().utf8)) throws -> SNESSetupReadinessReport {
    let kernel = SNESKernelBackupReport(before: probeFEL(), after: probeRNDIS(),
        observation: try SNESBackupPolicy.observation(snesObservation()), active: snapshotFixture(), backup: nil)
    return try SNESSetupReadinessReport(kernel: kernel, boot1: Data([1]), partitions: partitions, headerFrame: frame)
}

struct SNESStorageHeaderTests {
    @Test func stockSNES64BitMetadataIsReadWithoutRelaxingNESPolicy() throws {
        let bytes = snes64BitHeader(), frame = snesHeaderFrame(bytes)
        #expect(throws: (any Error).self) { try RecoveryDataSuperblock.parse(frame, partitionSectors: 614400) }
        let report = try reportWithSNESHeader(frame)
        #expect(report.dataHeader == bytes)
        #expect(report.dataSuperblock.blocks == 76800)
        #expect(report.dataSuperblock.freeBlocks == 70051)
        #expect(report.dataSuperblock.blockSize == 4096)
        #expect(report.dataSuperblock.sha256 == BackupManifest.digest(bytes))
        #expect(report.dataSuperblock.isClean && !report.firmwareRestoreEligible)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_DIAGNOSTIC"] != nil))
    func capturedPrivateHeaderIsAcceptedUnchangedOffline() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_DIAGNOSTIC"])
        let root = URL(fileURLWithPath: path)
        let frame = try Data(contentsOf: root.appendingPathComponent("data-header-frame.bin"))
        let partitions = try Data(contentsOf: root.appendingPathComponent("partitions.txt"))
        let report = try reportWithSNESHeader(frame, partitions: partitions)
        #expect(report.dataSuperblock.blocks * report.dataSuperblock.blockSize == 314572800)
        #expect(report.dataSuperblock.sha256 == "4db4d3c81c4db36faa0a24d98d3894cf5c3088b8d454c28261a427cc1fc5db9c")
        #expect(report.dataHeader == Data(frame.suffix(2048)))
    }

    @Test(arguments: ["highTotal", "highFree", "oversized", "unknown", "badDescriptor", "dirty", "hash", "truncated", "extra"])
    func unsafeOrUnsupported64BitHeadersRemainRejected(fault: String) throws {
        var bytes = snes64BitHeader()
        switch fault {
        case "highTotal": putSNESWord(UInt32.max, in: &bytes, at: 1360)
        case "highFree": putSNESWord(1, in: &bytes, at: 1368)
        case "oversized": putSNESWord(UInt32.max, in: &bytes, at: 1028)
        case "unknown": putSNESWord(0x800002c2, in: &bytes, at: 1120)
        case "badDescriptor": bytes[1278] = 32
        case "dirty": bytes[1082] = 0
        default: break
        }
        var frame = snesHeaderFrame(bytes)
        if fault == "hash" { frame[frame.count-1] ^= 1 }
        if fault == "truncated" { frame.removeLast() }
        if fault == "extra" { frame.append(0) }
        #expect(throws: (any Error).self) { try reportWithSNESHeader(frame) }
    }
}
