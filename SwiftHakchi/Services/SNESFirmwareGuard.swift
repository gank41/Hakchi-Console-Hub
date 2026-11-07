import Foundation
import SwiftHakchiCore

/// Bound to one fully byte-validated immutable firmware operation.
struct SNESFirmwareGuard:Sendable {
    let id:UUID,reviewSHA256:String
    private let seal:SNESFirmwareSourceSeal
    private let parent:SNESMenuStartupParent?
    private let restorationHistory:SNESFirmwareSourceSeal?
    private init(id:UUID,reviewSHA256:String,seal:SNESFirmwareSourceSeal,parent:SNESMenuStartupParent?,restorationHistory:SNESFirmwareSourceSeal?){self.id=id;self.reviewSHA256=reviewSHA256;self.seal=seal;self.parent=parent;self.restorationHistory=restorationHistory}
    static func prepare(_ material:SNESFirmwareMaterial, verified: SNESFirmwareVerifiedInputs? = nil)throws->Self {
        let p=material.paths,c=material.trial.candidate,m=c.material
        guard let runtime=m.runtime.directoryURL else {throw SNESRuntimeBinding.failure()}
        let folders=[p.candidate,p.preflight,p.started,p.played,p.original].map {URL(fileURLWithPath:$0)} +
            [material.source.source.directoryURL,c.backup.directory,m.support.source.directoryURL,m.support.directoryURL,m.components.directoryURL,runtime] + m.components.source.evidenceDirectories + (verified.map { [$0.helpers,$0.currentData.directory] } ?? [])
        let seal=try SNESFirmwareSourceSeal.capture(directories:folders,files:[material.reader.location,material.writer.location])
        // Full hashes/recipes checked while the metadata seal must remain unchanged.
        try material.validateCurrent();try seal.validate()
        if let verified {
            let backup = try SNESFirmwareMaterial.requireFirstInstallBackup(candidate: c)
            try seal.requireFileDigest(backup.directory.appendingPathComponent("manifest.json"), sha256: backup.manifestSHA256, maximum: 65536)
            let current = try SNESDataSnapshotPackage.load(receipt: verified.currentData, source: material.source)
            try seal.requireFileDigest(current.directory.appendingPathComponent("manifest.json"), sha256: verified.currentData.manifestSHA256, maximum: 65536)
            try seal.validate()
        }
        return .init(id:material.id,reviewSHA256:BackupManifest.digest(try material.planData()),seal:seal,parent:material.trial.evidence.parent,restorationHistory:material.restorationParentHistory)
    }
    func validate()throws {try seal.validate();try parent?.validate();try restorationHistory?.validate()}
    func require(_ material:SNESFirmwareMaterial)throws {
        guard material.id==id,BackupManifest.digest(try material.planData())==reviewSHA256 else {throw SNESRuntimeBinding.failure()}
        try validate()
    }
    /// Bind the guide's exact receipts to the identities held by this seal.
    func requireVerifiedInputs(_ inputs: SNESFirmwareVerifiedInputs, material: SNESFirmwareMaterial) throws {
        guard inputs.backup.kind == .backup, inputs.candidate.kind == .candidate,
              inputs.preflight.record.kind == .preflight, inputs.preflight.backupMatches,
              inputs.started.kind == .trialStarted, inputs.played.kind == .trialPlayed, inputs.active.kind == .activeBoot2,
              inputs.backup.directory.path == material.source.source.directoryURL.path,
              inputs.candidate.directory.path == material.paths.candidate,
              inputs.preflight.record.directory.path == material.paths.preflight,
              inputs.started.directory.path == material.paths.started, inputs.played.directory.path == material.paths.played,
              inputs.active.directory.path == material.paths.original,
              inputs.backup.manifestSHA256 == material.source.source.manifestSHA256,
              inputs.preflight.record.manifestSHA256 == material.trial.evidence.manifestSHA256,
              material.trial.evidence.backupMatches == inputs.preflight.backupMatches,
              inputs.started.manifestSHA256 == material.proof.startedSHA256,
              inputs.played.manifestSHA256 == material.proof.playedSHA256,
              inputs.active.manifestSHA256 == material.original.manifestSHA256,
              material.reader.location.deletingLastPathComponent().path == inputs.helpers.path,
              material.writer.location.deletingLastPathComponent().path == inputs.helpers.path else { throw SNESRuntimeBinding.failure() }
        try require(material)
        for record in [inputs.backup, inputs.candidate, inputs.preflight.record, inputs.started, inputs.played, inputs.active] {
            try seal.requireFileDigest(record.directory.appendingPathComponent("manifest.json"), sha256: record.manifestSHA256, maximum: 65536)
        }
        try seal.requireFileDigest(inputs.helpers.appendingPathComponent("manifest.json"), sha256: inputs.helpersManifestSHA256, maximum: 16384)
        try seal.requireFileDigest(inputs.currentData.directory.appendingPathComponent("manifest.json"), sha256: inputs.currentData.manifestSHA256, maximum: 65536)
        try seal.requireFileDigest(inputs.candidate.directory.appendingPathComponent("startup.img"), sha256: BackupManifest.digest(material.trial.image), maximum: 8 * 1024 * 1024)
        try seal.requireFileDigest(material.reader.location, sha256: material.reader.digest, maximum: 2 * 1024 * 1024)
        try seal.requireFileDigest(material.writer.location, sha256: material.writer.digest, maximum: 2 * 1024 * 1024)
        try require(material)
    }
}
