import Foundation
import Darwin
import SwiftHakchiCore

/// Holds the existing backup directory open across the probe. No path is followed
/// when creating snapshot files, and no existing name is replaced.
actor RecoveryBootSnapshotStore {
    private let root: URL
    private let rootFD: Int32
    private let synchronize: @Sendable (Int32) -> Int32
    init(root: URL, synchronize: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) throws {
        let canonical = root.standardizedFileURL
        guard canonical == canonical.resolvingSymlinksInPath() else {
            throw RecoveryProbeError.refused("Choose an existing Backups directory without symbolic path components.")
        }
        let fd = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RecoveryProbeError.refused("The snapshot Backups directory must already exist and be readable.") }
        self.root = canonical; self.rootFD = fd; self.synchronize = synchronize
    }
    deinit { close(rootFD) }

    private struct Manifest: Encodable {
        let schemaVersion: Int
        let complete = true
        let firmwareRestoreEligible = false
        let probe: RecoveryRAMProbeReport
    }
    func save(_ report: RecoveryRAMProbeReport) throws -> URL {
        try Task.checkCancellation()
        guard let snapshot = report.bootSnapshot, report.observation.board == "dp-nes" else {
            throw RecoveryProbeError.refused("Only an accepted NES kernel capture can be exported.")
        }
        var files = ["active-boot2.img": snapshot.active]
        if let backup = snapshot.backup { files["backup-boot2.img"] = backup }
        if let boot1 = report.boot1Snapshot { files["boot1.bin"] = boot1.data }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try export(prefix: report.boot1Snapshot == nil ? "Boot2Snapshot-" : "InstallEvidence-", files: files,
            manifest: encoder.encode(Manifest(schemaVersion: report.boot1Snapshot == nil ? 1 : 2, probe: report)))
    }
    private struct SNESManifest: Encodable {
        let schemaVersion = 1
        let complete = true
        let firmwareRestoreEligible = false
        let console = "snes-usa"
        let capture: SNESKernelBackupReport
    }
    func saveSNES(_ report: SNESKernelBackupReport) throws -> URL {
        guard report.observation.board == "dp-shvc", report.region == "USA", !report.firmwareRestoreEligible else {
            throw RecoveryProbeError.refused("Only a verified US SNES backup can be exported here.")
        }
        _ = try LegacyAndroidBootImage(data: report.active)
        var files = ["active-boot2.img": report.active]
        if let backup = report.backup {
            guard !backup.isEmpty, backup.count <= LegacyAndroidBootImage.maximumSize else { throw failure() }
            files["backup-boot2.img"] = backup
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try export(prefix: "SNES-US-Kernel-", files: files, manifest: encoder.encode(SNESManifest(capture: report)))
    }
    private struct SNESSetupManifest: Encodable {
        let schemaVersion = 1
        let complete = true
        let firmwareRestoreEligible = false
        let console = "snes-usa"
        let capture: SNESSetupReadinessReport
    }
    func saveSNESSetup(_ report: SNESSetupReadinessReport) throws -> URL {
        try Task.checkCancellation()
        let files = try report.filesForExport()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try export(prefix: "SNES-US-Setup-", files: files,
            manifest: encoder.encode(SNESSetupManifest(capture: report)))
    }
    private struct SNESDiagnosticManifest: Encodable {
        struct File: Encodable {
            let byteCount: Int
            let sha256: String
            init(_ bytes: Data) { byteCount = bytes.count; sha256 = BackupManifest.digest(bytes) }
        }
        let schemaVersion = 1
        let complete = false
        let firmwareRestoreEligible = false
        let console = "snes-usa"
        let status = "incomplete-storage-check"
        let identityCheck = "verified-before-reads-only"
        let activeKernelCheck = "single-validated-read-before-header-rejection"
        let reason: String
        let observation: RecoveryProbeObservation
        let files: [String: File]
    }
    func saveSNESSetupDiagnostic(_ failure: SNESSetupDiagnosticFailure) throws -> URL {
        try Task.checkCancellation()
        let files = try failure.filesForExport()
        let manifest = SNESDiagnosticManifest(reason: String(failure.reason.prefix(2048)), observation: failure.kernel.observation,
            files: files.mapValues { SNESDiagnosticManifest.File($0) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try export(prefix: "SNES-US-Setup-Diagnostic-", files: files, manifest: encoder.encode(manifest))
    }
    func saveSNESRecoveryMaterial(_ material: SNESRecoveryMaterial) throws -> URL {
        let checked = try material.checkedExport()
        return try export(prefix: "SNES-Recovery-Material-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try material.revalidate() })
    }
    func saveSNESBuild(_ build: SNESOfflineImageBuild) throws -> URL {
        let checked = try build.checkedExport()
        return try export(prefix: "SNES-Experimental-Build-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESRuntime(_ runtime: SNESRuntimeMaterial, source: SNESOfflineSource) throws -> URL {
        let checked = try runtime.export(source: source)
        return try export(prefix: "SNES-US-Runtime-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESTemporaryMenuResult(_ result: SNESTemporaryMenuResult, menu: PreparedSNESTemporaryMenu) throws -> URL {
        let checked = try result.checkedExport(menu: menu)
        return try export(prefix: "SNES-Temporary-Menu-Result-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try menu.validateCurrent() })
    }
    func saveSNESTemporaryMenuFailure(_ failure: SNESTemporaryMenuFailure, menu: PreparedSNESTemporaryMenu) throws -> URL {
        let checked = try failure.checkedExport(menu: menu)
        return try export(prefix: "SNES-Temporary-Menu-Diagnostic-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESTemporaryMenu(_ menu: PreparedSNESTemporaryMenu) throws -> URL {
        let checked = try menu.checkedExport()
        return try export(prefix: "SNES-Temporary-Menu-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try menu.validateCurrent() })
    }
    func saveSNESProbe(_ probe: PreparedSNESRAMProbe) throws -> URL {
        let checked = try probe.checkedExport()
        return try export(prefix: "SNES-RAM-Probe-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESActiveBoot2(_ result:SNESActiveBoot2Snapshot)throws->URL {
        let checked=try result.checkedExport()
        return try export(prefix:"SNES-Active-Boot2-",files:checked.files,manifest:checked.manifest,
                          beforeManifest:{try result.source.revalidate();try result.helper.revalidate()})
    }
    func saveSNESActiveBoot2Failure(_ result:SNESActiveBoot2Failure)throws->URL {
        let checked=try result.checkedExport()
        return try export(prefix:"SNES-Active-Boot2-Diagnostic-",files:checked.files,manifest:checked.manifest)
    }
    func saveSNESOneGame(_ material: SNESOneGameMaterial) throws -> URL {
        try material.validate()
        return try export(prefix:"SNES-One-Game-",files:["menu.bundle":material.bundle],manifest:material.planData(),beforeManifest:{try material.validate()})
    }
    func saveSNESOriginalGames(_ result: SNESOriginalGamesResult) throws -> URL {
        let value=try result.checkedExport()
        return try export(prefix:"SNES-Original-Games-",files:value.files,manifest:value.manifest,beforeManifest:{try result.revalidate()})
    }
    func saveSNESStartupTrial(_ result: SNESStartupTrialResult, trial: PreparedSNESStartupTrial) throws -> URL {
        let checked = try result.checkedExport(trial: trial)
        return try export(prefix: "SNES-Startup-Trial-Result-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try trial.validateCurrent() })
    }
    func saveSNESStartupTrialFailure(_ result: SNESStartupTrialFailure, trial: PreparedSNESStartupTrial) throws -> URL {
        let checked = try result.checkedExport(trial: trial)
        return try export(prefix: "SNES-Startup-Trial-Diagnostic-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESStartupPreflight(_ result: SNESStartupPreflightResult) throws -> URL {
        let checked = try result.checkedExport()
        return try export(prefix: "SNES-Startup-Preflight-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.candidate.material.revalidate(); try result.candidate.backup.revalidate(); try result.parent?.validate() })
    }
    func saveSNESStartupCandidate(_ candidate: SNESStartupAdapterCandidate) throws -> URL {
        let checked = try candidate.checkedExport()
        return try export(prefix: "SNES-Startup-Candidate-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try candidate.material.revalidate(); try candidate.backup.revalidate() })
    }
    func saveSNESDataSnapshot(_ result: SNESDataSnapshotResult) throws -> URL {
        let checked = try result.checkedExport()
        return try export(prefix: "SNES-Current-Data-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() })
    }
    func saveSNESPreparation(_ result: SNESRecoveryPreparation) throws -> URL {
        let checked = try result.checkedExport()
        return try export(prefix: "SNES-Recovery-Preparation-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() })
    }
    func saveSNESPreparationFailure(_ failure: SNESPreparationFailure) throws -> URL {
        let checked = try failure.checkedExport()
        return try export(prefix: "SNES-Recovery-Preparation-Diagnostic-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESAlienTrialFailure(_ failure: SNESAlienTrialFailure, trial: PreparedSNESAlienTrial) throws -> URL {
        try trial.validateCurrent()
        guard failure.stage.utf8.count <= 64, failure.stage.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }), failure.diagnostics.count <= 65536, failure.cause.utf8.count <= 512,
              failure.cause.utf8.allSatisfy({ (32...126).contains($0) }) else { throw SNESRuntimeBinding.failure() }
        let metadata: [String: Any] = ["schemaVersion": 1, "scope": "snes-alien-ram-trial-failure", "complete": false,
            "firmwareWritten": false, "imageSHA256": BackupManifest.digest(trial.image), "stage": failure.stage, "cause": failure.cause,
            "diagnosticsSHA256": BackupManifest.digest(failure.diagnostics)]
        let framed = Data("SNES_ALIEN_TRIAL_LOG_V1 \(failure.diagnostics.count) \(BackupManifest.digest(failure.diagnostics))\n".utf8) + failure.diagnostics
        return try export(prefix: "SNES-Alien-Trial-Diagnostic-", files: ["diagnostic.log": framed],
                          manifest: JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]),
                          beforeManifest: { try trial.validateCurrent() })
    }
    func saveSNESAlienTrialCheckpoint(_ checkpoint: SNESAlienTrialCheckpoint, trial: PreparedSNESAlienTrial) throws -> URL {
        let result = try checkpoint.checkedExport(trial: trial)
        return try export(prefix: "SNES-Alien-Trial-Checkpoint-", files: result.files, manifest: result.manifest,
                          beforeManifest: { try trial.validateCurrent() })
    }
    func saveSNESOriginalMenuCheckpoint(_ checkpoint: SNESOriginalMenuCheckpoint, menu: PreparedSNESOriginalMenu) throws -> URL {
        let result = try checkpoint.checkedExport(menu: menu)
        return try export(prefix: "SNES-Original-Menu-Checkpoint-", files: result.files, manifest: result.manifest,
                          beforeManifest: { try menu.validateCurrent() })
    }
    func saveSNESStartupCapture(_ result: SNESStartupCapture, menu: PreparedSNESOriginalMenu) throws -> URL {
        let checked = try result.checkedExport(menu: menu)
        return try export(prefix: "SNES-Startup-Details-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try menu.validateCurrent() })
    }
    func saveSNESOriginalMenuResult(_ result: SNESOriginalMenuResult, menu: PreparedSNESOriginalMenu) throws -> URL {
        let checked = try result.checkedExport(menu: menu)
        return try export(prefix: "SNES-Original-Menu-Result-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try menu.validateCurrent() })
    }
    func saveSNESOriginalMenuFailure(_ failure: SNESOriginalMenuFailure, menu: PreparedSNESOriginalMenu) throws -> URL {
        let result = try failure.checkedExport(menu: menu)
        return try export(prefix: "SNES-Original-Menu-Diagnostic-", files: result.files, manifest: result.manifest)
    }
    func saveSNESOriginalMenu(_ menu: PreparedSNESOriginalMenu) throws -> URL {
        let result = try menu.checkedExport()
        return try export(prefix: "SNES-Original-Menu-", files: result.files, manifest: result.manifest,
                          beforeManifest: { try menu.validateCurrent() })
    }
    func saveSNESOriginalComponents(_ result: SNESOriginalComponentResult) throws -> URL {
        let checked = try result.checkedExport()
        return try export(prefix: "SNES-Original-Components-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() })
    }
    func saveSNESOriginalComponentFailure(_ failure: SNESOriginalComponentFailure) throws -> URL {
        let checked = try failure.checkedExport()
        return try export(prefix: "SNES-Original-Components-Diagnostic-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESMenuSupport(_ result: SNESMenuSupportResult) throws -> URL {
        let checked = try result.checkedExport()
        return try export(prefix: "SNES-Menu-Support-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() })
    }
    func saveSNESMenuSupportFailure(_ failure: SNESMenuSupportFailure) throws -> URL {
        let checked = try failure.checkedExport()
        return try export(prefix: "SNES-Menu-Support-Diagnostic-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESProbeResult(_ result: SNESRAMProbeResult, probe: PreparedSNESRAMProbe) throws -> URL {
        try probe.validateCurrent()
        guard result.expectation.binding == probe.binding, result.expectation.nonce == probe.nonce,
              result.expectation.hashes == probe.hashes,
              try SNESRAMProbeUSBPolicy.after([result.after], original: result.before) == result.after else {
            throw SNESRuntimeBinding.failure()
        }
        _ = try SNESRAMProbeReport(result.report.raw, expected: probe.expectation)
        struct ResultManifest: Encodable {
            let schemaVersion = 1, complete = true, firmwareRestoreEligible = false, firmwareWritten = false
            let scope = "snes-isolated-ram-probe-result"
            let binding: SNESRuntimeBinding
            let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice
            let nonce: String, candidateSHA256: String, reportSHA256: String
        }
        let m = ResultManifest(binding: probe.binding, before: result.before, after: result.after, nonce: probe.nonce,
            candidateSHA256: BackupManifest.digest(probe.image), reportSHA256: BackupManifest.digest(result.report.raw))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try export(prefix: "SNES-RAM-Probe-Result-", files: ["report.txt": result.report.raw], manifest: encoder.encode(m))
    }
    private func export(prefix: String, files: [String: Data], manifest: Data, beforeManifest: () throws -> Void = {}) throws -> URL {
        try Task.checkCancellation()
        try checkRoot()
        let name = prefix + UUID().uuidString
        guard mkdirat(rootFD, name, 0o700) == 0 else { throw failure() }
        let directory = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw failure() }
        defer { close(directory) }
        guard fchmod(directory, 0o700) == 0, synchronize(rootFD) == 0 else { throw failure() }
        do {
            for name in files.keys.sorted() { try write(files[name]!, name: name, directory: directory) }
            guard synchronize(directory) == 0 else { throw failure() }
            try Task.checkCancellation()
            try checkRoot()
            try checkChild(name: name, directory: directory)
            try beforeManifest()
            try write(manifest, name: "manifest.json", directory: directory)
            guard synchronize(directory) == 0, synchronize(rootFD) == 0 else { throw failure() }
            try checkRoot()
            try checkChild(name: name, directory: directory)
            try Task.checkCancellation()
            return root.appendingPathComponent(name, isDirectory: true)
        } catch {
            // Preserve partial images for diagnosis, but never leave a completion marker
            // after a reported export failure. Only this newly owned directory is touched.
            unlinkat(directory, "manifest.json", 0)
            _ = synchronize(directory)
            throw error
        }
    }
    private func checkRoot() throws {
        var held = stat(), current = stat()
        guard fstat(rootFD, &held) == 0, lstat(root.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_dev == held.st_dev, current.st_ino == held.st_ino,
              root == root.resolvingSymlinksInPath() else { throw failure() }
    }
    private func checkChild(name: String, directory: Int32) throws {
        var held = stat(), named = stat()
        guard fstat(directory, &held) == 0,
              fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFDIR, named.st_dev == held.st_dev, named.st_ino == held.st_ino else {
            throw failure()
        }
    }
    private func write(_ data: Data, name: String, directory: Int32) throws {
        try Task.checkCancellation()
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw failure() }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw failure() }
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let written = Darwin.write(fd, base.advanced(by: offset), min(65536, data.count - offset))
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw failure() }
                offset += written
            }
        }
        guard synchronize(fd) == 0 else { throw failure() }
        let readback = try RecoveryMaterialReader.readFile(directory: directory, name: name, maximumBytes: LegacyAndroidBootImage.maximumSize)
        guard readback == data else { throw failure() }
    }
    private func failure() -> RecoveryProbeError {
        .refused("Kernel snapshot export could not be completed and verified. Existing backups were not replaced; any new partial directory has no completion manifest.")
    }
}
