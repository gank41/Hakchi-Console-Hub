import Foundation
import SwiftHakchiCore

/// Immutable private stock material. Loading is file-only and cannot grant console access.
struct SNESOfflineSource: Sendable {
    static let stockSHA256 = "a358326433d7bb5d1093d313fd7656f8706b493972cea446fd926437704f8911"
    let stock: Data
    let snapshotName: String
    let manifestSHA256: String
    let expectedHWID: String
    private let snapshotURL: URL
    private let recoveryPackage: Bool
    var directoryURL: URL { snapshotURL }
    private init(stock: Data, snapshot: URL, manifest: Data, expectedHWID: String, recoveryPackage: Bool) {
        self.recoveryPackage = recoveryPackage
        self.stock = stock; snapshotURL = snapshot; snapshotName = snapshot.lastPathComponent
        manifestSHA256 = BackupManifest.digest(manifest)
        self.expectedHWID = expectedHWID
    }
    var runtimeBinding: SNESRuntimeBinding { .init(sourceSnapshot: snapshotName, setupManifestSHA256: manifestSHA256, expectedHWID: expectedHWID) }
    private struct Manifest: Decodable {
        let schemaVersion: Int, complete: Bool, console: String, firmwareRestoreEligible: Bool, capture: Capture
        struct Capture: Decodable {
            let kernel: Kernel
            struct Kernel: Decodable {
                let before: RecoveryProbeUSBDevice, after: RecoveryProbeUSBDevice, observation: RecoveryProbeObservation
                let region: String, active: Image, backup: Image
                struct Image: Decodable { let status: String }
            }
        }
    }
    static func load(snapshot: URL) throws -> Self { try load(snapshot: snapshot, recoveryPackage: false) }
    // Recovery packages remain a distinct source kind, never a mutable eligibility flag.
    static func loadRecoveryPackage(snapshot: URL) throws -> Self { try load(snapshot: snapshot, recoveryPackage: true) }
    private static func load(snapshot: URL, recoveryPackage: Bool) throws -> Self {
        let directory = try RestoreDirectory(snapshot)
        let prefix = recoveryPackage ? "SNES-Recovery-Material-" : "SNES-US-Setup-"
        guard directory.url.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.url.lastPathComponent.dropFirst(prefix.count))) != nil else { throw failure() }
        let raw = try directory.read("manifest.json", maximum: 65536)
        if recoveryPackage {
            let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
            guard object?["scope"] as? String == "snes-original-startup-recovery",
                  object?["firmwareWritten"] as? Bool == false else { throw failure() }
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: raw)
        guard manifest.schemaVersion == 1, manifest.complete, manifest.console == "snes-usa", !manifest.firmwareRestoreEligible else { throw failure() }
        let stock = try directory.read("active-boot2.img")
        guard stock.count == 2_736_128, BackupManifest.digest(stock) == stockSHA256 else { throw failure() }
        let capture = manifest.capture.kernel
        guard capture.region == "USA", capture.active.status == "valid-boot-image-read-twice" else { throw failure() }
        _ = try capture.before.nativeIdentity(for: .fel)
        _ = try capture.after.nativeIdentity(for: .rndis)
        guard try RecoveryProbePolicy.after([capture.after], original: capture.before) == capture.after else { throw failure() }
        let backup: Data?
        if capture.backup.status == "unavailable" { backup = nil }
        else { backup = try directory.read("backup-boot2.img") }
        let boot1 = try directory.read("boot1.bin", maximum: RecoveryBoot1Read.maximumSize)
        let partitions = try directory.read("partitions.txt", maximum: 16384)
        let header = try directory.read("data-header.bin", maximum: 2048)
        let frame = Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8) + header
        let kernel = SNESKernelBackupReport(before: capture.before, after: capture.after, observation: capture.observation,
            active: stock, backup: backup)
        let report = try SNESSetupReadinessReport(kernel: kernel, boot1: boot1, partitions: partitions, headerFrame: frame)
        let encoded = try JSONEncoder().encode(report)
        guard let expected = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let actual = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
              let saved = expected["capture"] as? [String: Any], actual.isEqual(to: saved) else { throw failure() }
        _ = try LegacyBootImageBuilder.inspect(stock)
        try directory.check()
        return Self(stock: stock, snapshot: directory.url, manifest: raw, expectedHWID: capture.observation.hwid, recoveryPackage: recoveryPackage)
    }
    func revalidate() throws {
        let current = try Self.load(snapshot: snapshotURL, recoveryPackage: recoveryPackage)
        guard current.stock == stock, current.manifestSHA256 == manifestSHA256 else { throw Self.failure() }
    }
    static func failure() -> RecoveryProbeError {
        .refused("Could not verify the saved SNES startup backup. The original files were kept; nothing was sent to the console.")
    }
}

/// Experimental files only. Existing recovery and flash APIs do not consume this type.
struct SNESOfflineImageBuild: Sendable {
    static let kernelSHA256 = "7a2416c970abfb5bd269753cfa3b1e90997ba7b4b446f9e25046402eb335f30d"
    let source: SNESOfflineSource
    let image: Data
    private let kernel: Data
    private let replacements: [String: Data]
    private init(source: SNESOfflineSource, kernel: Data, replacements: [String: Data], image: Data) {
        self.source = source; self.kernel = kernel; self.replacements = replacements; self.image = image
    }
    static func make(source: SNESOfflineSource, kernel: Data, replacements: [String: Data] = [:]) throws -> Self {
        guard BackupManifest.digest(source.stock) == SNESOfflineSource.stockSHA256,
              kernel.count == 2_624_208, BackupManifest.digest(kernel) == kernelSHA256,
              replacements["key-file"] == nil else { throw SNESOfflineSource.failure() }
        let stock = try LegacyBootImageBuilder.inspect(source.stock)
        let archive = try stock.archive.updating(replacements: replacements)
        guard archive.entries.first(where: { $0.name == "key-file" }) == stock.archive.entries.first(where: { $0.name == "key-file" }) else { throw SNESOfflineSource.failure() }
        let image = try LegacyBootImageBuilder.build(source: source.stock, kernel: kernel, archive: archive)
        return Self(source: source, kernel: kernel, replacements: replacements, image: image)
    }
    struct Evidence: Encodable {
        let byteCount: Int, sha256: String
        init(_ bytes: Data) { byteCount = bytes.count; sha256 = BackupManifest.digest(bytes) }
    }
    private struct Recipe: Encodable {
        let version = 1
        let compression = "lzop-stored-blocks"
        let sourceArchive = "stock-snes-newc"
        let kernel: Evidence
        let replacements: [String: Evidence]
    }
    private struct Manifest: Encodable {
        let schemaVersion = 1
        let scope = "experimental-snes-offline-image"
        let complete = true, bootEligible = false, firmwareRestoreEligible = false
        let sourceSnapshot: String, sourceManifestSHA256: String
        let stock: Evidence, candidate: Evidence, recipe: Evidence
    }
    func checkedExport() throws -> (files: [String: Data], manifest: Data) {
        try Task.checkCancellation()
        try source.revalidate()
        guard try Self.make(source: source, kernel: kernel, replacements: replacements).image == image else { throw SNESOfflineSource.failure() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recipe = try encoder.encode(Recipe(kernel: Evidence(kernel), replacements: replacements.mapValues(Evidence.init)))
        let manifest = Manifest(sourceSnapshot: source.snapshotName, sourceManifestSHA256: source.manifestSHA256,
            stock: Evidence(source.stock), candidate: Evidence(image), recipe: Evidence(recipe))
        return (["candidate.img": image, "recipe.json": recipe], try encoder.encode(manifest))
    }
}
