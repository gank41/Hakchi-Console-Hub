import Foundation
import Darwin
import SwiftHakchiCore

struct RecoverySnapshotCleanupError: Error, LocalizedError, Sendable {
    let directory: URL
    var errorDescription: String? {
        "The backup check stopped and the app could not confirm cleanup of its completion marker. Do not use this backup until it is inspected: \(directory.path)"
    }
}
struct SNESFirstInstallReviewSaveError: Error, LocalizedError, Sendable {
    let directory: URL
    var errorDescription: String? {
        "The installation review could not be saved and verified. Preserve the partial folder for inspection: \(directory.path). No console update was requested."
    }
}

/// Holds the existing backup directory open across the probe. No path is followed
/// when creating snapshot files, and no existing name is replaced.
actor RecoveryBootSnapshotStore {
    private let root: URL
    private let rootFD: Int32
    private let synchronize: @Sendable (Int32) -> Int32
    private let removeManifest: @Sendable (Int32, String) -> Int32
    init(root: URL, synchronize: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) },
         removeManifest: @escaping @Sendable (Int32, String) -> Int32 = { unlinkat($0, $1, 0) }) throws {
        let canonical = root.standardizedFileURL
        guard canonical == canonical.resolvingSymlinksInPath() else {
            throw RecoveryProbeError.refused("Choose an existing Backups directory without symbolic path components.")
        }
        let fd = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw RecoveryProbeError.refused("The snapshot Backups directory must already exist and be readable.") }
        self.root = canonical; self.rootFD = fd; self.synchronize = synchronize; self.removeManifest = removeManifest
    }
    deinit { close(rootFD) }

    /// Saves a Mac-only draft; callers must separately verify all referenced
    /// material and the live console before considering an installation.
    func saveSNESFirstInstallReview(_ review: SNESFirstInstallOfflineReview, startupPlan: Data,
                                    afterCreate: @Sendable (URL) throws -> Void = { _ in },
                                    verify: @Sendable () throws -> Void = {}) throws -> SNESFirstInstallReviewReceipt {
        let bytes = try review.canonicalBytes(), digest = try review.digest()
        guard startupPlan.count <= SNESFirstInstallPlanBinding.maximumStartupPlanBytes else {
            throw RecoveryProbeError.refused("This startup review is too large to save. Choose a shorter folder location and try again. Nothing was installed.")
        }
        guard !startupPlan.isEmpty, BackupManifest.digest(startupPlan) == review.startupPlanSHA256 else { throw SNESRuntimeBinding.failure() }
        try Task.checkCancellation(); try checkRoot()
        let name = "SNES-First-Install-Review-" + UUID().uuidString
        guard mkdirat(rootFD, name, 0o700) == 0 else { throw failure() }
        let location = root.appendingPathComponent(name, isDirectory: true)
        do {
            var created = stat(), opened = stat()
            guard fstatat(rootFD, name, &created, AT_SYMLINK_NOFOLLOW) == 0,
                  created.st_mode & S_IFMT == S_IFDIR, created.st_uid == geteuid(),
                  created.st_mode & 0o777 == 0o700 else { throw failure() }
            try afterCreate(location)
            let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw failure() }
            defer { close(fd) }
            guard fstat(fd, &opened) == 0, opened.st_dev == created.st_dev, opened.st_ino == created.st_ino else { throw failure() }
            try checkRoot(); try checkChild(name: name, directory: fd)
            let directory = try RestoreDirectory(location)
            var checked = stat()
            guard fstat(directory.fd, &checked) == 0, checked.st_dev == opened.st_dev, checked.st_ino == opened.st_ino,
                  try directory.names().isEmpty, synchronize(rootFD) == 0 else { throw failure() }
            try verify(); try checkRoot(); try checkChild(name: name, directory: fd)
            try write(startupPlan, name: "startup-plan.json", directory: fd)
            guard synchronize(fd) == 0 else { throw failure() }
            try checkRoot(); try checkChild(name: name, directory: fd); try verify()
            try write(bytes, name: "manifest.json", directory: fd)
            guard synchronize(fd) == 0, synchronize(rootFD) == 0 else { throw failure() }
            let receipt = SNESFirstInstallReviewReceipt(directory: location, sha256: digest)
            let reopened = try SNESFirstInstallReviewReceipt.open(receipt)
            guard try reopened.canonicalBytes() == bytes else { throw failure() }
            try verify(); try checkRoot(); try checkChild(name: name, directory: fd)
            let final = try SNESFirstInstallReviewReceipt.open(receipt)
            guard try final.canonicalBytes() == bytes else { throw failure() }
            try checkRoot(); try checkChild(name: name, directory: fd); try Task.checkCancellation()
            return receipt
        } catch {
            // Never delete a path or file after an uncertain substitution.
            throw SNESFirstInstallReviewSaveError(directory: location)
        }
    }

    /// Check the destination before a lengthy console read. The probe owns a
    /// uniquely created empty directory and never replaces an existing file.
    func checkWritableDestination() throws {
        try Task.checkCancellation(); try checkRoot()
        let name = ".snes-backup-check-" + UUID().uuidString
        guard mkdirat(rootFD, name, 0o700) == 0 else { throw failure() }
        let directory = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw failure() }
        defer { close(directory) }
        do {
            try checkRoot(); try checkChild(name: name, directory: directory)
            try write(Data([0x53]), name: "probe", directory: directory)
            try checkChild(name: name, directory: directory)
            guard unlinkat(directory, "probe", 0) == 0, synchronize(directory) == 0 else { throw failure() }
            try checkRoot(); try checkChild(name: name, directory: directory)
            guard unlinkat(rootFD, name, AT_REMOVEDIR) == 0, synchronize(rootFD) == 0 else { throw failure() }
        } catch {
            // Only remove the file inside the directory whose identity we hold.
            if (try? checkChild(name: name, directory: directory)) != nil {
                _ = unlinkat(directory, "probe", 0)
                _ = unlinkat(rootFD, name, AT_REMOVEDIR)
                _ = synchronize(rootFD)
            }
            throw error
        }
    }

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
        try saveSNESSetupWithReceipt(report).directory
    }
    func saveSNESSetupWithReceipt(_ report: SNESSetupReadinessReport,
                                  verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        try Task.checkCancellation()
        let files = try report.filesForExport()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = try encoder.encode(SNESSetupManifest(capture: report))
        let directory = try export(prefix: "SNES-US-Setup-", files: files, manifest: manifest, afterManifest: { url in
            let saved = try RestoreDirectory(url)
            func verifyBytes() throws {
                guard Set(try saved.names()) == Set(files.keys).union(["manifest.json"]),
                      try saved.read("manifest.json", maximum: 65536) == manifest else { throw SNESOfflineSource.failure() }
                for (name, expected) in files {
                    guard try saved.read(name, maximum: max(expected.count, 1)) == expected else { throw SNESOfflineSource.failure() }
                }
                try saved.check()
            }
            try verifyBytes(); try verify(url); try verifyBytes()
        })
        return SNESSetupRecordReceipt(kind: .backup, directory: directory, manifestSHA256: BackupManifest.digest(manifest))
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
    func saveSNESRecoveryMaterial(_ material: SNESRecoveryMaterial,
                                  verify: @Sendable (URL) throws -> Void = { _ in }) throws -> URL {
        let checked = try material.checkedExport()
        return try export(prefix: "SNES-Recovery-Material-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try material.revalidate() }, afterManifest: { directory in
            let package = try SNESRecoveryMaterial.loadPackage(directory: directory)
            guard package.expectedHWID == material.expectedHWID else { throw SNESOfflineSource.failure() }
            try verify(directory)
        })
    }
    func saveSNESPortableHelpers(verify: @Sendable (URL) throws -> Void = { _ in }) throws -> URL {
        let checked = try SNESPortableHelperPackage.export()
        return try export(prefix: "SNES-Setup-Helpers-", files: checked.files, manifest: checked.manifest,
                          afterManifest: { directory in
            _ = try SNESPortableHelperPackage.load(directory: directory)
            try verify(directory)
        })
    }
    func saveSNESBuild(_ build: SNESOfflineImageBuild) throws -> URL {
        let checked = try build.checkedExport()
        return try export(prefix: "SNES-Experimental-Build-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESRuntime(_ runtime: SNESRuntimeMaterial, source: SNESOfflineSource,
                         verify: @Sendable (URL) throws -> Void = { _ in }) throws -> URL {
        try saveSNESRuntimeWithReceipt(runtime, source: source, verify: verify).directory
    }
    func saveSNESRuntimeWithReceipt(_ runtime: SNESRuntimeMaterial, source: SNESOfflineSource,
                                    verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        let checked = try runtime.export(source: source)
        let directory = try export(prefix: "SNES-US-Runtime-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try source.revalidate() }, afterManifest: { directory in
            let saved = try RestoreDirectory(directory)
            guard try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESRuntimeBinding.failure() }
            let material = try SNESRuntimeMaterial.load(directory: directory, source: source)
            guard material.binding == runtime.binding, material.frame.encoded == runtime.frame.encoded else { throw SNESRuntimeBinding.failure() }
            try verify(directory)
            let rechecked = try SNESRuntimeMaterial.load(directory: directory, source: source)
            guard rechecked.binding == runtime.binding, rechecked.frame.encoded == runtime.frame.encoded,
                  Set(try saved.names()) == Set(checked.files.keys).union(["manifest.json"]),
                  try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESRuntimeBinding.failure() }
            try saved.check(); try source.revalidate()
        })
        return SNESSetupRecordReceipt(kind: .runtime, directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
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
        try saveSNESActiveBoot2WithReceipt(result).directory
    }
    func saveSNESActiveBoot2WithReceipt(_ result: SNESActiveBoot2Snapshot,
                                        verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        let checked=try result.checkedExport()
        let directory = try export(prefix:"SNES-Active-Boot2-",files:checked.files,manifest:checked.manifest,
            beforeManifest:{try result.source.revalidate();try result.helper.revalidate()}, afterManifest:{ directory in
                let saved = try RestoreDirectory(directory)
                guard try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESRuntimeBinding.failure() }
                let package = try SNESActiveBoot2Package.load(directory: directory, source: result.source)
                guard package.manifestSHA256 == BackupManifest.digest(checked.manifest), package.active == result.active else { throw SNESRuntimeBinding.failure() }
                try verify(directory)
                try package.revalidate(source: result.source); try result.helper.revalidate()
                guard try saved.read("manifest.json", maximum: 65536) == checked.manifest,
                      Set(try saved.names()) == Set(checked.files.keys).union(["manifest.json"]) else { throw SNESRuntimeBinding.failure() }
                try saved.check()
            })
        return SNESSetupRecordReceipt(kind: .activeBoot2, directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
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
    func saveSNESStartupTrialStartedWithReceipt(_ result: SNESStartupTrialResult, trial: PreparedSNESStartupTrial,
                                                 verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        guard result.phase == "started" else { throw SNESRuntimeBinding.failure() }
        let checked = try result.checkedExport(trial: trial)
        let directory = try export(prefix: "SNES-Startup-Trial-Result-", files: checked.files, manifest: checked.manifest,
            beforeManifest: { try trial.validateCurrent() }, afterManifest: { directory in
                let saved = try RestoreDirectory(directory)
                guard try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESRuntimeBinding.failure() }
                _ = try SNESStartupTrialResult.loadStarted(directory: directory, trial: trial, expectedManifestSHA256: BackupManifest.digest(checked.manifest))
                try verify(directory)
                _ = try SNESStartupTrialResult.loadStarted(directory: directory, trial: trial, expectedManifestSHA256: BackupManifest.digest(checked.manifest))
                guard try saved.read("manifest.json", maximum: 65536) == checked.manifest,
                      Set(try saved.names()) == Set(checked.files.keys).union(["manifest.json"]) else { throw SNESRuntimeBinding.failure() }
                try saved.check(); try trial.validateCurrent()
            })
        return SNESSetupRecordReceipt(kind: .trialStarted, directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
    }
    func saveSNESStartupTrialPlayedWithReceipt(_ result: SNESStartupTrialResult, trial: PreparedSNESStartupTrial,
                                                started: SNESSetupRecordReceipt,
                                                verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        guard result.phase == "after-gameplay" else { throw SNESRuntimeBinding.failure() }
        _ = try SNESStartupTrialResult.loadStarted(receipt: started, trial: trial)
        let checked = try result.checkedExport(trial: trial), digest = BackupManifest.digest(checked.manifest)
        let directory = try export(prefix: "SNES-Startup-Trial-Result-", files: checked.files, manifest: checked.manifest,
            beforeManifest: { _ = try SNESStartupTrialResult.loadStarted(receipt: started, trial: trial) }, afterManifest: { directory in
                let proof = try SNESFirmwareTrialProof.load(started: started.directory, played: directory, trial: trial,
                    expectedStartedSHA256: started.manifestSHA256, expectedPlayedSHA256: digest)
                try verify(directory)
                try proof.revalidate(trial: trial)
                _ = try SNESStartupTrialResult.loadStarted(receipt: started, trial: trial)
            })
        return SNESSetupRecordReceipt(kind: .trialPlayed, directory: directory, manifestSHA256: digest)
    }
    func saveSNESStartupTrialFailure(_ result: SNESStartupTrialFailure, trial: PreparedSNESStartupTrial) throws -> URL {
        let checked = try result.checkedExport(trial: trial)
        return try export(prefix: "SNES-Startup-Trial-Diagnostic-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESStartupPreflight(_ result: SNESStartupPreflightResult) throws -> URL {
        try saveSNESStartupPreflightWithReceipt(result).record.directory
    }
    func saveSNESStartupPreflightWithReceipt(_ result: SNESStartupPreflightResult,
                                              verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESStartupPreflightReceipt {
        let checked = try result.checkedExport()
        let matches = try result.backupMatches()
        let directory = try export(prefix: "SNES-Startup-Preflight-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.candidate.material.revalidate(); try result.candidate.backup.revalidate(); try result.parent?.validate() }, afterManifest: { directory in
            let saved = try RestoreDirectory(directory)
            guard try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESRuntimeBinding.failure() }
            let evidence = try SNESStartupPreflightEvidence.load(directory: directory, candidate: result.candidate, parent: result.parent)
            guard evidence.manifestSHA256 == BackupManifest.digest(checked.manifest) else { throw SNESRuntimeBinding.failure() }
            try verify(directory)
            try evidence.revalidate(candidate: result.candidate)
            guard try saved.read("manifest.json", maximum: 65536) == checked.manifest,
                  try saved.read("data-header.bin", maximum: 2048) == result.header,
                  Set(try saved.names()) == Set(checked.files.keys).union(["manifest.json"]),
                  try result.backupMatches() == matches else { throw SNESRuntimeBinding.failure() }
            try saved.check()
        })
        return SNESStartupPreflightReceipt(record: SNESSetupRecordReceipt(kind: .preflight, directory: directory,
            manifestSHA256: BackupManifest.digest(checked.manifest)), backupMatches: matches)
    }
    func saveSNESStartupCandidate(_ candidate: SNESStartupAdapterCandidate) throws -> URL {
        try saveSNESStartupCandidateWithReceipt(candidate).directory
    }
    func saveSNESStartupCandidateWithReceipt(_ candidate: SNESStartupAdapterCandidate,
                                               verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        let checked = try candidate.checkedExport()
        let directory = try export(prefix: "SNES-Startup-Candidate-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try candidate.material.revalidate(); try candidate.backup.revalidate() }, afterManifest: { directory in
            let saved = try RestoreDirectory(directory)
            guard try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESRuntimeBinding.failure() }
            let loaded = try SNESStartupAdapterCandidate.load(directory: directory, expectedManifestSHA256: BackupManifest.digest(checked.manifest))
            guard loaded.image == candidate.image, loaded.libraryRecipeVersion == candidate.libraryRecipeVersion else { throw SNESRuntimeBinding.failure() }
            try verify(directory)
            try candidate.material.revalidate(); try candidate.backup.revalidate()
            guard try saved.read("manifest.json", maximum: 65536) == checked.manifest,
                  try saved.read("startup.img") == candidate.image,
                  Set(try saved.names()) == Set(checked.files.keys).union(["manifest.json"]) else { throw SNESRuntimeBinding.failure() }
            try saved.check()
        })
        return SNESSetupRecordReceipt(kind: .candidate, directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
    }
    func saveSNESDataSnapshot(_ result: SNESDataSnapshotResult,
                              verify: @Sendable (URL) throws -> Void = { _ in }) throws -> URL {
        try saveSNESDataSnapshotWithReceipt(result, verify: verify).directory
    }
    func saveSNESDataSnapshotWithReceipt(_ result: SNESDataSnapshotResult,
                                         verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESDataSnapshotReceipt {
        let checked = try result.checkedExport()
        let directory = try export(prefix: "SNES-Current-Data-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() }, afterManifest: { directory in
            let saved = try RestoreDirectory(directory)
            guard try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESDataSnapshotError.refused }
            let package = try SNESDataSnapshotPackage.load(directory: directory, expectedHWID: result.source.source.expectedHWID)
            guard package.byteCount == (try result.source.dataSnapshotPlan()).byteCount,
                  package.sha256 == result.sha256 else { throw SNESDataSnapshotError.refused }
            try result.source.revalidate()
            try verify(directory)
            try package.revalidate()
            guard try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESDataSnapshotError.refused }
            try saved.check(); try result.source.revalidate()
        })
        return SNESDataSnapshotReceipt(directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
    }
    func saveSNESPreparation(_ result: SNESRecoveryPreparation) throws -> URL {
        try saveSNESPreparationWithReceipt(result).directory
    }
    func saveSNESPreparationWithReceipt(_ result: SNESRecoveryPreparation,
                                        verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        let checked = try result.checkedExport()
        let directory = try export(prefix: "SNES-Recovery-Preparation-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() }, afterManifest: { directory in
            let saved = try SNESMenuSupportSource.load(setup: result.source.source, preparation: directory)
            guard saved.manifestSHA256 == BackupManifest.digest(checked.manifest) else { throw SNESRuntimeBinding.failure() }
            try verify(directory)
            try saved.revalidate()
        })
        return SNESSetupRecordReceipt(kind: .startup, directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
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
    func saveSNESOriginalMenuResult(_ result: SNESOriginalMenuResult, menu: PreparedSNESOriginalMenu,
                                    verify: @Sendable (URL) throws -> Void = { _ in }) throws -> URL {
        let checked = try result.checkedExport(menu: menu)
        return try export(prefix: "SNES-Original-Menu-Result-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try menu.validateCurrent() }, afterManifest: { directory in
            let saved = try RestoreDirectory(directory)
            func requireSavedBytes() throws {
                guard Set(try saved.names()) == Set(checked.files.keys).union(["manifest.json"]),
                      try saved.read("manifest.json", maximum: 65536) == checked.manifest else { throw SNESRuntimeBinding.failure() }
                for (name, bytes) in checked.files {
                    guard try saved.read(name, maximum: max(bytes.count, 1)) == bytes else { throw SNESRuntimeBinding.failure() }
                }
                try saved.check()
            }
            try requireSavedBytes()
            if result.phase == "started" { _ = try SNESOriginalMenuResult.loadStarted(directory: directory, menu: menu) }
            try verify(directory); try requireSavedBytes()
            let current = try result.checkedExport(menu: menu)
            guard current.manifest == checked.manifest, current.files == checked.files else { throw SNESRuntimeBinding.failure() }
        })
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
    func saveSNESOriginalComponents(_ result: SNESOriginalComponentResult,
                                    verify: @Sendable (URL) throws -> Void = { _ in }) throws -> URL {
        try saveSNESOriginalComponentsWithReceipt(result, verify: verify).directory
    }
    func saveSNESOriginalComponentsWithReceipt(_ result: SNESOriginalComponentResult,
                                               verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        let checked = try result.checkedExport()
        let directory = try export(prefix: "SNES-Original-Components-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() }, afterManifest: { directory in
            let saved = try SNESOriginalComponentMaterial.load(source: result.source, directory: directory)
            guard saved.manifestSHA256 == BackupManifest.digest(checked.manifest) else { throw SNESRuntimeBinding.failure() }
            try verify(directory)
            try saved.revalidate()
        })
        return SNESSetupRecordReceipt(kind: .components, directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
    }
    func saveSNESOriginalComponentFailure(_ failure: SNESOriginalComponentFailure) throws -> URL {
        let checked = try failure.checkedExport()
        return try export(prefix: "SNES-Original-Components-Diagnostic-", files: checked.files, manifest: checked.manifest)
    }
    func saveSNESMenuSupport(_ result: SNESMenuSupportResult,
                             verify: @Sendable (URL) throws -> Void = { _ in }) throws -> URL {
        try saveSNESMenuSupportWithReceipt(result, verify: verify).directory
    }
    func saveSNESMenuSupportWithReceipt(_ result: SNESMenuSupportResult,
                                        verify: @Sendable (URL) throws -> Void = { _ in }) throws -> SNESSetupRecordReceipt {
        let checked = try result.checkedExport()
        let directory = try export(prefix: "SNES-Menu-Support-", files: checked.files, manifest: checked.manifest,
                          beforeManifest: { try result.source.revalidate() }, afterManifest: { directory in
            let saved = try SNESMenuSupportMaterial.load(source: result.source, directory: directory)
            guard saved.manifestSHA256 == BackupManifest.digest(checked.manifest) else { throw SNESRuntimeBinding.failure() }
            try verify(directory)
            try saved.revalidate()
        })
        return SNESSetupRecordReceipt(kind: .menuSupport, directory: directory, manifestSHA256: BackupManifest.digest(checked.manifest))
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
    private func export(prefix: String, files: [String: Data], manifest: Data,
                        beforeManifest: () throws -> Void = {}, afterManifest: (URL) throws -> Void = { _ in }) throws -> URL {
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
            try afterManifest(root.appendingPathComponent(name, isDirectory: true))
            try checkRoot()
            try checkChild(name: name, directory: directory)
            try Task.checkCancellation()
            return root.appendingPathComponent(name, isDirectory: true)
        } catch {
            // Preserve partial images for diagnosis and report when completion-marker
            // cleanup cannot be confirmed. Only this newly owned directory is touched.
            let removed = removeManifest(directory, "manifest.json")
            let removalError = errno
            let synced = synchronize(directory)
            if (removed != 0 && removalError != ENOENT) || synced != 0 {
                throw RecoverySnapshotCleanupError(directory: root.appendingPathComponent(name, isDirectory: true))
            }
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
