import Foundation

/// A Mac-only restore preparation. This is not permission to write the console.
struct SNESPreparedStartupRestore: Sendable {
    let operation: URL
    let reviewSHA256: String
    let changedUnits: Int
    let hasTestedWriter: Bool
}

struct SNESStartupRestoreRecord: Sendable {
    let restore: SNESPreparedStartupRestore
    let phase: SNESFirmwareJournal.Phase
}

enum SNESFirmwareOutcomeFailure {
    static func classify(_ cause: any Error, mode: SNESFirmwareTransaction.Mode, transactionStarted: Bool,
                         phase: SNESFirmwareJournal.Phase?) -> any Error {
        guard mode == .write, transactionStarted,
              phase == nil || phase == .writeIntent || phase == .uncertain || phase == .readbackVerified else { return cause }
        return (cause as? SNESFirmwareTransactionError) ?? SNESFirmwareTransactionError.uncertain
    }
}
import SwiftHakchiCore

struct SNESReviewedConsoleCheck: Sendable {
    let operation:URL,planSHA256:String,review:SNESFirstInstallReviewReceipt
}

/// A reopened record reports its saved state; it never grants a write permit.
struct SNESReviewedInstallationRecord: Sendable {
    let check: SNESReviewedConsoleCheck
    let phase: SNESFirmwareJournal.Phase
}

/// Plain-language description of a saved record, not a live-console check.
struct SNESInstallationProgress {
    let title: String
    let detail: String
    let needsAttention: Bool

    init(phase: SNESFirmwareJournal.Phase) {
        switch phase {
        case .prepared, .preflightVerified:
            title = "Installation not recorded"
            detail = "The saved record does not show that the startup update began. This check did not connect to the SNES."
            needsAttention = false
        case .stoppedBeforeWrite:
            title = "Stopped before installation"
            detail = "The saved record says this attempt stopped before changing the startup software. This check did not connect to the SNES."
            needsAttention = false
        case .writeIntent, .uncertain:
            title = "Installation needs attention"
            detail = "The saved record cannot confirm whether the update finished. Do not try the update again. Keep the backup and get help before making changes."
            needsAttention = true
        case .readbackVerified:
            title = "Startup update recorded"
            detail = "The saved record says the update was checked after writing. A normal startup and game check have not yet been recorded."
            needsAttention = true
        case .startupVerified:
            title = "Startup check recorded"
            detail = "The saved record says the console started normally. A game check has not yet been recorded."
            needsAttention = true
        case .menuAccepted:
            title = "Earlier game check recorded"
            detail = "A successful menu and game check was saved. This checks the record on the Mac; it does not check the console now."
            needsAttention = false
        }
    }
}

struct SNESReviewedUpgradeRecord: Sendable {
    let upgrade: SNESFirmwareJournal.Prepared
    let parentMenu: SNESFirmwareJournal.Prepared?
    let phase: SNESFirmwareJournal.Phase
}

struct SNESFirstInstallReviewSummary: Sendable {
    let reviewDirectory: URL, dataDirectory: URL
    let reviewSHA256:String
    let changedUnits: Int
    func requireReceipt(_ receipt:SNESFirstInstallReviewReceipt) throws {
        guard reviewDirectory.path == receipt.directory.path, reviewSHA256 == receipt.sha256 else {throw SNESRuntimeBinding.failure()}
    }
}

/// Reconstructs a saved draft for a new review. This value is not a record of
/// the user's prior confirmation, a live-console check, or a write permit.
struct SNESFirstInstallReviewMaterial: Sendable {
    private let material: SNESFirmwareMaterial
    let data: SNESDataSnapshotPackage
    var startupID: UUID { material.id }
    var candidateBackupSHA256: String { material.trial.candidate.backup.sha256 }
    var changedUnits: Int { material.changedUnits.count }
    private let receipt: SNESFirstInstallReviewReceipt
    private let review: SNESFirstInstallOfflineReview
    private let guardValue: SNESFirmwareGuard
    private let seal: SNESFirmwareSourceSeal

    static func load(receipt: SNESFirstInstallReviewReceipt, recovery: RecoveryBootInputs) throws -> Self {
        try Task.checkCancellation()
        let review = try SNESFirstInstallReviewReceipt.open(receipt)
        let directory = try RestoreDirectory(receipt.directory)
        let raw = try directory.read("startup-plan.json", maximum: 65536)
        guard raw.count <= SNESFirstInstallPlanBinding.maximumStartupPlanBytes else {
            throw RecoveryProbeError.refused("This saved review is too large to use for installation. Keep it for your records, choose a shorter folder location, and prepare a new review. Nothing was installed.")
        }
        guard BackupManifest.digest(raw)==review.startupPlanSHA256 else {throw SNESRuntimeBinding.failure()}
        let dataURL = URL(fileURLWithPath: review.dataDirectory)
        let seal = try SNESFirmwareSourceSeal.capture(directories: [receipt.directory, dataURL], files: [])
        try seal.requireFileDigest(receipt.directory.appendingPathComponent("manifest.json"), sha256: receipt.sha256, maximum: 65536)
        try seal.requireFileDigest(receipt.directory.appendingPathComponent("startup-plan.json"), sha256: review.startupPlanSHA256, maximum: SNESFirstInstallPlanBinding.maximumStartupPlanBytes)
        try seal.requireFileDigest(dataURL.appendingPathComponent("manifest.json"), sha256: review.dataManifestSHA256, maximum: 65536)
        let plan = try JSONDecoder().decode(SNESFirmwarePlan.self, from: raw)
        guard plan.schemaVersion == 1, plan.direction == .install, plan.parentOperationID == nil,
              plan.parentReviewSHA256 == nil else { throw SNESRuntimeBinding.failure() }
        let material = try SNESFirmwareMaterial.install(paths: plan.paths, recovery: recovery, id: plan.id).adoptingSavedPlan(raw)
        guard material.trial.evidence.backupMatches else { throw SNESRuntimeBinding.failure() }
        try SNESColdBootPolicy.require(boot1: material.source.boot1, image: material.trial.image)
        _ = try SNESFirmwareMaterial.requireFirstInstallBackup(candidate: material.trial.candidate)
        let data = try SNESDataSnapshotPackage.load(receipt: .init(directory: dataURL, manifestSHA256: review.dataManifestSHA256), source: material.source)
        guard data.sha256 == review.dataSHA256, data.byteCount == review.dataBytes else { throw SNESRuntimeBinding.failure() }
        let checked = try SNESFirmwareGuard.prepare(material)
        try checked.require(material); try data.revalidate(); try seal.validate()
        let final = try SNESFirstInstallReviewReceipt.open(receipt)
        guard try final.canonicalBytes() == review.canonicalBytes() else { throw SNESRuntimeBinding.failure() }
        try seal.validate()
        return Self(material: material, data: data, receipt: receipt, review: review, guardValue: checked, seal: seal)
    }

    func revalidate() throws {
        try seal.validate(); try guardValue.require(material)
        let current = try SNESFirstInstallReviewReceipt.open(receipt)
        guard try current.canonicalBytes() == review.canonicalBytes() else { throw SNESRuntimeBinding.failure() }
        try seal.validate(); try guardValue.require(material)
    }

    /// Produces a versioned, review-bound plan; it cannot authorize a write.
    func reviewedInstallMaterial() throws -> SNESFirmwareMaterial {
        try revalidate();try data.revalidate()
        let raw=try RestoreDirectory(receipt.directory).read("startup-plan.json",maximum:SNESFirstInstallPlanBinding.maximumStartupPlanBytes)
        let binding=try SNESFirstInstallPlanBinding(receipt:receipt,review:review,startupPlanID:material.id,startupPlanData:raw)
        let result=try material.bindingFirstInstall(binding)
        try revalidate();try data.revalidate()
        return result
    }
}
