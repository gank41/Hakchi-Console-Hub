import Foundation
import SwiftHakchiCore

struct SNESPreparationSource: Sendable {
    let source: SNESOfflineSource
    let stock: Data, boot1: Data, partitions: Data, header: Data
    private init(source: SNESOfflineSource, boot1: Data, partitions: Data, header: Data) {
        self.source = source; stock = source.stock; self.boot1 = boot1; self.partitions = partitions; self.header = header
    }
    static func load(_ source: SNESOfflineSource) throws -> Self {
        try source.revalidate()
        let directory = try RestoreDirectory(source.directoryURL)
        let result = try Self(source: source, boot1: directory.read("boot1.bin", maximum: RecoveryBoot1Read.maximumSize),
                              partitions: directory.read("partitions.txt", maximum: 16384), header: directory.read("data-header.bin", maximum: 2048))
        try directory.check(); try source.revalidate(); return result
    }
    func revalidate() throws {
        let current = try Self.load(source)
        guard current.stock == stock, current.boot1 == boot1, current.partitions == partitions, current.header == header else { throw SNESOfflineSource.failure() }
    }
    func requireObservation(_ observation: RecoveryProbeObservation) throws {
        try SNESBackupPolicy.requireReadOnlyObservation(observation)
        guard observation.hwid == source.expectedHWID, observation.mounts.allSatisfy({
            let fields = $0.split(separator: " ")
            return fields.count == 6 && !fields[1].hasPrefix("/newroot/")
        }) else { throw SNESOfflineSource.failure() }
    }
    func validateHeader(_ frame: Data) throws -> Data {
        guard let text = String(data: partitions, encoding: .ascii) else { throw SNESOfflineSource.failure() }
        let sectors = try StockRestorePartitions.dataSectors(text)
        let expected = try SNESStorageHeader(frame: Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8) + header, partitionSectors: sectors)
        let actual = try SNESStorageHeader(frame: frame, partitionSectors: sectors)
        // Playing stock games can update free counts and timestamps. Bind filesystem
        // identity/geometry rather than mistaking those normal changes for corruption.
        guard actual.summary.isClean, actual.summary.blocks == expected.summary.blocks,
              actual.summary.blockSize == expected.summary.blockSize,
              actual.bytes[1128..<1144] == header[1128..<1144] else { throw SNESOfflineSource.failure() }
        return actual.bytes
    }
}

struct SNESRecoveryPreparation: Sendable {
    let source: SNESPreparationSource, startup: SNESStartupFrame, header: Data
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try Task.checkCancellation(); try source.revalidate()
        try source.requireObservation(observation)
        guard observation.hwid == source.source.expectedHWID,
              try RecoveryProbePolicy.after([after], original: before) == after else { throw SNESOfflineSource.failure() }
        _ = try SNESStartupFrame(startup.raw)
        _ = try source.validateHeader(Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8) + header)
        struct Manifest: Encodable {
            let schemaVersion = 1, complete = true, firmwareRestoreEligible = false, firmwareWritten = false
            let scope = "snes-recovery-startup-preparation", stockImageCheckedInRAM = true
            let binding: SNESRuntimeBinding
            let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
            let files: [String: String]
        }
        let files = ["stock.img": source.stock, "boot1.bin": source.boot1, "partitions.txt": source.partitions,
                     "data-header.bin": header, "startup.frame": startup.raw]
        let manifest = Manifest(binding: source.source.runtimeBinding, before: before, after: after, observation: observation,
                                files: files.mapValues(BackupManifest.digest))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try source.revalidate()
        return (files, try encoder.encode(manifest))
    }
}

struct SNESStartupTransportFailure: Error, Sendable {
    let frame: Data, stageLog: Data
}
struct SNESPreparationFailure: Error, LocalizedError, Sendable {
    enum Stage: String, Sendable { case firstCapture, secondCapture, changedCapture }
    let binding: SNESRuntimeBinding, stage: Stage, frame: Data, stageLog: Data
    init(binding: SNESRuntimeBinding, stage: Stage, frame: Data, stageLog: Data = Data()) {
        self.binding = binding; self.stage = stage
        self.frame = Data(frame.prefix(SNESStartupFrame.maximumSize)); self.stageLog = Data(stageLog.prefix(16384))
    }
    var errorDescription: String? { "The startup check stopped. Diagnostic information was kept on this Mac; nothing was installed." }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try binding.validate()
        struct Manifest: Encodable {
            let schemaVersion = 1, complete = false, firmwareRestoreEligible = false, firmwareWritten = false
            let scope = "snes-recovery-startup-diagnostic"
            let binding: SNESRuntimeBinding, stage: String, frameSHA256: String, stageLogSHA256: String
            let frameBytes: Int, stageLogBytes: Int
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Envelope even empty responses without relaxing the recovery reader's
        // deliberate refusal of empty firmware/material files.
        let framed = Data("SWIFTHAKCHI_REJECTED_STARTUP_V1 \(frame.count) \(BackupManifest.digest(frame))\n".utf8) + frame
        let logged = Data("SWIFTHAKCHI_STARTUP_DIAGNOSTIC_LOG_V1 \(stageLog.count) \(BackupManifest.digest(stageLog))\n".utf8) + stageLog
        return (["rejected.frame": framed, "stages.log": logged], try encoder.encode(Manifest(binding: binding, stage: stage.rawValue,
            frameSHA256: BackupManifest.digest(frame), stageLogSHA256: BackupManifest.digest(stageLog), frameBytes: frame.count, stageLogBytes: stageLog.count)))
    }
}
