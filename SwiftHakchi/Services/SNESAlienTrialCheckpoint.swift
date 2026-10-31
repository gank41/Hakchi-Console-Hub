import Foundation
import SwiftHakchiCore

struct SNESAlienTrialCheckpoint: Sendable {
    let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, challenge: UUID, report: Data
    private struct Manifest: Codable {
        let schemaVersion: Int, complete: Bool, firmwareWritten: Bool, firmwareRestoreEligible: Bool
        let scope: String, imageSHA256: String, nonce: String, binding: SNESRuntimeBinding, reportSHA256: String
        let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, challenge: UUID
    }
    func checkedExport(trial: PreparedSNESAlienTrial) throws -> (files: [String: Data], manifest: Data) {
        try trial.validateCurrent()
        guard try SNESOriginalMenuUSBPolicy.after([after], original: before) == after else { throw SNESRuntimeBinding.failure() }
        _ = try SNESOriginalMenuReport(report, expected: trial.expectation, challenge: challenge, state: .preMenu)
        let m = Manifest(schemaVersion: 1, complete: true, firmwareWritten: false, firmwareRestoreEligible: false,
                         scope: "snes-alien-ram-trial-checkpoint", imageSHA256: BackupManifest.digest(trial.image),
                         nonce: trial.expectation.nonce, binding: trial.expectation.binding, reportSHA256: BackupManifest.digest(report),
                         before: before, after: after, challenge: challenge)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (["checkpoint.bin": report], try encoder.encode(m))
    }
    static func load(directory: URL, trial: PreparedSNESAlienTrial) throws -> Self {
        let dir = try RestoreDirectory(directory), prefix = "SNES-Alien-Trial-Checkpoint-"
        guard dir.url.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(dir.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw SNESRuntimeBinding.failure() }
        let raw = try dir.read("manifest.json", maximum: 65536), m = try JSONDecoder().decode(Manifest.self, from: raw)
        let checkpoint = Self(before: m.before, after: m.after, challenge: m.challenge, report: try dir.read("checkpoint.bin", maximum: 65536))
        let checked = try checkpoint.checkedExport(trial: trial)
        guard let actual = try JSONSerialization.jsonObject(with: checked.manifest) as? NSDictionary,
              let saved = try JSONSerialization.jsonObject(with: raw) as? [String: Any], actual.isEqual(to: saved) else { throw SNESRuntimeBinding.failure() }
        try dir.check(); return checkpoint
    }
    func persistForLaunch(trial: PreparedSNESAlienTrial, store: RecoveryBootSnapshotStore) async throws -> SNESAlienTrialLaunchRequest {
        let directory = try await store.saveSNESAlienTrialCheckpoint(self, trial: trial)
        let loaded = try Self.load(directory: directory, trial: trial)
        guard loaded.report == report, loaded.challenge == challenge, loaded.before == before, loaded.after == after else { throw SNESRuntimeBinding.failure() }
        let manifest = try RestoreDirectory(directory).read("manifest.json", maximum: 65536)
        return SNESAlienTrialLaunchRequest(trial: trial, checkpoint: self, directory: directory, manifestSHA256: BackupManifest.digest(manifest))
    }
}
struct SNESAlienTrialLaunchRequest: Sendable {
    private let trial: PreparedSNESAlienTrial, checkpoint: SNESAlienTrialCheckpoint, manifestSHA256: String
    let checkpointDirectory: URL
    fileprivate init(trial: PreparedSNESAlienTrial, checkpoint: SNESAlienTrialCheckpoint, directory: URL, manifestSHA256: String) {
        self.trial = trial; self.checkpoint = checkpoint; self.checkpointDirectory = directory; self.manifestSHA256 = manifestSHA256
    }
    func validateCurrent() throws {
        try trial.validateCurrent()
        let loaded = try SNESAlienTrialCheckpoint.load(directory: checkpointDirectory, trial: trial)
        guard loaded.report == checkpoint.report, loaded.challenge == checkpoint.challenge, loaded.before == checkpoint.before, loaded.after == checkpoint.after,
              try BackupManifest.digest(RestoreDirectory(checkpointDirectory).read("manifest.json", maximum: 65536)) == manifestSHA256 else { throw SNESRuntimeBinding.failure() }
    }
    var command: String { "exec /probe/busybox sh /probe/launch " + trial.expectation.nonce + " " + checkpoint.challenge.uuidString + " " + BackupManifest.digest(checkpoint.report) }
    var acknowledgement: Data { Data("SWIFTHAKCHI_SNES_ORIGINAL_LAUNCH_V1\nNONCE=\(trial.expectation.nonce)\nCHECKPOINT_SHA=\(BackupManifest.digest(checkpoint.report))\nEND\n".utf8) }
}
