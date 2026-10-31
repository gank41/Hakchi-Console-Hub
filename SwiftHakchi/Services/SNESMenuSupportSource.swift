import Foundation
import SwiftHakchiCore

/// A reconstructed completed preparation, bound to its immutable setup and raw manifest.
struct SNESMenuSupportSource: Sendable {
    let preparation: SNESRecoveryPreparation
    let directoryURL: URL
    let manifestSHA256: String
    private struct Manifest: Decodable {
        let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
    }
    static func load(setup: SNESOfflineSource, preparation url: URL) throws -> Self {
        let directory = try RestoreDirectory(url), prefix = "SNES-Recovery-Preparation-"
        guard directory.url.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESOfflineSource.failure() }
        let source = try SNESPreparationSource.load(setup)
        let raw = try directory.read("manifest.json", maximum: 65536)
        let saved = try JSONDecoder().decode(Manifest.self, from: raw)
        let result = try SNESRecoveryPreparation(source: source,
            startup: SNESStartupFrame(directory.read("startup.frame", maximum: SNESStartupFrame.maximumSize)),
            header: directory.read("data-header.bin", maximum: 2048), before: saved.before, after: saved.after, observation: saved.observation)
        let checked = try result.checkedExport()
        for (name, expected) in checked.files {
            guard try directory.read(name, maximum: max(expected.count, 1)) == expected else { throw SNESOfflineSource.failure() }
        }
        guard let expected = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let actual = try JSONSerialization.jsonObject(with: checked.manifest) as? NSDictionary,
              actual.isEqual(to: expected) else { throw SNESOfflineSource.failure() }
        try directory.check(); try source.revalidate()
        return Self(preparation: result, directoryURL: directory.url, manifestSHA256: BackupManifest.digest(raw))
    }
    func revalidate() throws {
        let current = try Self.load(setup: preparation.source.source, preparation: directoryURL)
        guard current.manifestSHA256 == manifestSHA256 else { throw SNESOfflineSource.failure() }
    }
    func validate(_ frame: SNESMenuSupportFrame) throws {
        guard let expected = preparation.startup.records.first(where: { $0.path == "usr/bin/clover-canoe-shvc" }),
              let actual = frame.records.first(where: { $0.path == expected.path }),
              expected.kind == "B", actual.kind == "F", actual.count == expected.count, actual.digest == expected.digest else { throw SNESMenuSupportFrame.failure() }
    }
}

struct SNESMenuSupportResult: Sendable {
    let source: SNESMenuSupportSource, frame: SNESMenuSupportFrame
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try Task.checkCancellation(); try source.revalidate()
        try source.preparation.source.requireObservation(observation)
        guard try RecoveryProbePolicy.after([after], original: before) == after else { throw SNESOfflineSource.failure() }
        let checked = try SNESMenuSupportFrame(frame.raw); try source.validate(checked)
        struct Manifest: Encodable {
            let schemaVersion = 1, complete = true, firmwareWritten = false, firmwareRestoreEligible = false
            let scope = "snes-menu-support-capture"
            let binding: SNESRuntimeBinding
            let preparation: String, preparationManifestSHA256: String, frameSHA256: String
            let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
        }
        let manifest = Manifest(binding: source.preparation.source.source.runtimeBinding,
            preparation: source.directoryURL.lastPathComponent, preparationManifestSHA256: source.manifestSHA256,
            frameSHA256: BackupManifest.digest(frame.raw), before: before, after: after, observation: observation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try source.revalidate()
        return (["support.frame": frame.raw], try encoder.encode(manifest))
    }
}
struct SNESMenuSupportFailure: Error, LocalizedError, Sendable {
    enum Stage: String, Sendable { case firstCapture, secondCapture, changedCapture, validation }
    let source: SNESMenuSupportSource, stage: Stage, frame: Data, log: Data
    var errorDescription: String? { "The remaining startup check stopped. Private diagnostic files were kept on this Mac; nothing was installed." }
    init(source: SNESMenuSupportSource, stage: Stage, frame: Data, log: Data = Data()) {
        self.source = source; self.stage = stage
        self.frame = Data(frame.prefix(SNESMenuSupportFrame.maximumSize)); self.log = Data(log.prefix(16384))
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        let binding = source.preparation.source.source.runtimeBinding
        try binding.validate()
        struct Manifest: Encodable {
            let schemaVersion = 1, complete = false, firmwareWritten = false, firmwareRestoreEligible = false
            let scope = "snes-menu-support-diagnostic"
            let binding: SNESRuntimeBinding
            let preparation: String, preparationManifestSHA256: String, stage: String
            let frameBytes: Int, frameSHA256: String, stageLogBytes: Int, stageLogSHA256: String
        }
        let frameHash = BackupManifest.digest(frame), logHash = BackupManifest.digest(log)
        let files = ["rejected.frame": Data("SWIFTHAKCHI_REJECTED_STARTUP_V1 \(frame.count) \(frameHash)\n".utf8) + frame,
                     "stages.log": Data("SWIFTHAKCHI_STARTUP_DIAGNOSTIC_LOG_V1 \(log.count) \(logHash)\n".utf8) + log]
        let manifest = Manifest(binding: binding, preparation: source.directoryURL.lastPathComponent,
            preparationManifestSHA256: source.manifestSHA256, stage: stage.rawValue,
            frameBytes: frame.count, frameSHA256: frameHash, stageLogBytes: log.count, stageLogSHA256: logHash)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (files, try encoder.encode(manifest))
    }
}
