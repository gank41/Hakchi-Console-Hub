import Foundation
import SwiftHakchiCore

/// Read evidence only. Raw captures stay in private files, not encoded JSON.
struct SNESSetupReadinessReport: Encodable, Sendable {
    let kernel: SNESKernelBackupReport
    let boot1: RecoveryBoot1Snapshot
    let partitions: Data
    let dataHeader: Data
    let dataSuperblock: RecoveryDataSuperblock
    let firmwareRestoreEligible = false

    init(kernel: SNESKernelBackupReport, boot1: Data, partitions: Data, headerFrame: Data) throws {
        guard kernel.region == "USA" else {
            throw RecoveryProbeError.refused("The setup capture does not identify a US SNES.")
        }
        try SNESBackupPolicy.requireReadOnlyObservation(kernel.observation)
        _ = try RecoveryBootSnapshot(active: .image(kernel.active), backup: kernel.backup.map(RecoveryBoot2Read.image) ?? .unavailable)
        self.boot1 = try RecoveryBoot1Snapshot(boot1)
        guard let text = String(data: partitions, encoding: .ascii) else {
            throw RecoveryProbeError.refused("SNES storage information was not checked ASCII text.")
        }
        let sectors = try StockRestorePartitions.dataSectors(text)
        let parsed = try SNESStorageHeader(frame: headerFrame, partitionSectors: sectors)
        let superblock = parsed.summary
        guard superblock.isClean else {
            throw RecoveryProbeError.refused("The SNES storage needs a clean shutdown before setup. No repair or console change was attempted.")
        }
        self.kernel = kernel; self.partitions = partitions
        dataHeader = parsed.bytes; dataSuperblock = superblock
    }

    func filesForExport() throws -> [String: Data] {
        // Recheck raw material at the export boundary. No restore eligibility is inferred.
        let frame = Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 \(dataHeader.count) \(BackupManifest.digest(dataHeader))\n".utf8) + dataHeader
        _ = try Self(kernel: kernel, boot1: boot1.data, partitions: partitions, headerFrame: frame)
        var files = ["active-boot2.img": kernel.active, "boot1.bin": boot1.data,
                     "partitions.txt": partitions, "data-header.bin": dataHeader]
        if let backup = kernel.backup { files["backup-boot2.img"] = backup }
        return files
    }

    private struct Evidence: Encodable {
        let byteCount: Int
        let sha256: String
        init(_ bytes: Data) { byteCount = bytes.count; sha256 = BackupManifest.digest(bytes) }
    }
    private enum CodingKeys: String, CodingKey { case kernel, boot1, partitions, dataHeader, dataSuperblock, firmwareRestoreEligible }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kernel, forKey: .kernel)
        try values.encode(boot1, forKey: .boot1)
        try values.encode(Evidence(partitions), forKey: .partitions)
        try values.encode(Evidence(dataHeader), forKey: .dataHeader)
        try values.encode(dataSuperblock, forKey: .dataSuperblock)
        try values.encode(false, forKey: .firmwareRestoreEligible)
    }
}

actor SNESSetupReadinessService {
    private let session: RecoverySessionCoordinator
    init(wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        session = RecoverySessionCoordinator(wait: wait)
    }
    func capture(inputs: RecoveryBootInputs, io: any RecoveryProbeIO,
                 progress: @escaping RecoveryProgressSink = { _ in }) async throws -> SNESSetupReadinessReport {
        let (_, report) = try await session.run(inputs: inputs, io: io, progress: progress,
            validateObservation: { try SNESBackupPolicy.observation($0) }) { context in
            let before = try SNESBackupPolicy.observation(await io.observe())
            guard before.hwid == context.observation.hwid, before.mounts == context.observation.mounts else {
                throw RecoveryProbeError.refused("The SNES identity or mounts changed before the setup check.")
            }
            try Task.checkCancellation()
            await progress(.readingCurrentKernel)
            let active = try await io.readBoot2(.active)
            try Task.checkCancellation()
            let backup = try await io.readBoot2(.backup)
            let images = try RecoveryBootSnapshot(active: active, backup: backup)
            try Task.checkCancellation()
            await progress(.readingBootloader)
            let boot1 = try RecoveryBoot1Snapshot(await io.readBoot1())
            try Task.checkCancellation()
            guard try await io.readBoot1() == boot1.data else {
                throw RecoveryProbeError.refused("The two SNES bootloader reads differ. No completed setup backup was accepted.")
            }
            try Task.checkCancellation()
            await progress(.checkingPartitions)
            let partitions = try await io.readPartitions()
            guard let text = String(data: partitions, encoding: .ascii) else {
                throw RecoveryProbeError.refused("The SNES storage information was incomplete.")
            }
            _ = try StockRestorePartitions.dataSectors(text)
            try Task.checkCancellation()
            let headerFrame = try await io.readDataSuperblock()
            let kernel = SNESKernelBackupReport(before: context.before, after: context.after,
                observation: before, active: images.active, backup: images.backup)
            let result: SNESSetupReadinessReport
            do {
                result = try SNESSetupReadinessReport(kernel: kernel, boot1: boot1.data,
                    partitions: partitions, headerFrame: headerFrame)
            } catch {
                throw SNESSetupDiagnosticFailure(kernel: kernel, boot1: boot1.data, partitions: partitions,
                    headerFrame: headerFrame, reason: error.localizedDescription)
            }
            try Task.checkCancellation()
            await progress(.verifying)
            guard try await io.readBoot2(.active) == active else {
                throw RecoveryProbeError.refused("The two SNES kernel reads differ. No completed setup backup was accepted.")
            }
            try Task.checkCancellation()
            guard try await io.readPartitions() == partitions else {
                throw RecoveryProbeError.refused("The SNES storage layout changed during the setup check.")
            }
            try Task.checkCancellation()
            let after = try SNESBackupPolicy.observation(await io.observe())
            guard after.hwid == before.hwid, after.mounts == before.mounts else {
                throw RecoveryProbeError.refused("The SNES identity or mounts changed during the setup check.")
            }
            return result
        }
        return report
    }
}
