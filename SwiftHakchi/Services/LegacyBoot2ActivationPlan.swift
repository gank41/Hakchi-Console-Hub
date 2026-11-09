import Foundation
import SwiftHakchiCore

/// Binds a reviewed legacy activation to the identity recorded in its snapshot.
/// The snapshot manifest is unsigned and does not prove where an image came from.
/// Select only an image captured from the console being serviced.
struct LegacyBoot2ActivationPlan: Codable, Sendable {
    static let stockSHA256 = "83efe33290867ec6e6b5c5a18e21f8cfe6f97b079c2e3c5039c628e729755888"
    static let stockBytes = 2_826_240
    static let legacySHA256 = "44568f4076be6d0ff9948d789409017eef1e06c37cb6c56b63acde53541c2276"
    static let legacyBytes = 3_788_800
    static let supportedScope = "Western-NES-legacy-boot2-hex30"

    let id: UUID
    let expectedHWID: String
    let stockSHA256: String
    let stockBytes: Int
    let legacySHA256: String
    let legacyBytes: Int
    var schemaVersion = 1
    var scope = supportedScope
}

struct LegacyBoot2ActivationMaterial: Sendable {
    let plan: LegacyBoot2ActivationPlan
    let stock: Data
    var legacy: Data

    static func validHardwareID(_ id: String) -> Bool {
        id.count == 32 && StockRestoreMaterial.hex(id) && id.contains(where: { $0 != "0" })
    }

    func validateIntegrity() throws {
        guard plan.schemaVersion == 1, plan.scope == LegacyBoot2ActivationPlan.supportedScope,
              Self.validHardwareID(plan.expectedHWID),
              plan.stockBytes == LegacyBoot2ActivationPlan.stockBytes,
              plan.stockSHA256 == LegacyBoot2ActivationPlan.stockSHA256,
              plan.legacyBytes == LegacyBoot2ActivationPlan.legacyBytes,
              plan.legacySHA256 == LegacyBoot2ActivationPlan.legacySHA256,
              stock.count == plan.stockBytes, legacy.count == plan.legacyBytes,
              BackupManifest.digest(stock) == plan.stockSHA256,
              BackupManifest.digest(legacy) == plan.legacySHA256 else {
            throw RecoveryProbeError.refused("Legacy activation images, hardware identity, or reviewed scope do not match the pinned NES evidence.")
        }
        _ = try StockKernelEvidence(data: stock)
        _ = try LegacyAndroidBootImage(data: legacy)
    }

    static func load(snapshot: URL, stock: URL) throws -> Self {
        let directory = try RestoreDirectory(snapshot)
        struct Manifest: Decodable {
            let schemaVersion: Int
            let complete: Bool
            let probe: Probe
            struct Probe: Decodable {
                let observation: RecoveryProbeObservation
                let bootSnapshot: Snapshot
            }
            struct Snapshot: Decodable { let active: Image }
            struct Image: Decodable {
                let status: String
                let byteCount: Int
                let sha256: String
                let isKnownStock: Bool
            }
        }
        guard directory.url.lastPathComponent.hasPrefix("Boot2Snapshot-") else { throw RestoreDirectory.failure() }
        let manifest = try JSONDecoder().decode(Manifest.self, from: directory.read("manifest.json", maximum: 65536))
        let legacy = try directory.read("active-boot2.img")
        guard manifest.schemaVersion == 1, manifest.complete,
              manifest.probe.observation.board == "dp-nes",
              manifest.probe.observation.kernel == "3.4.113.29-madmonkey",
              manifest.probe.bootSnapshot.active.status == "valid-boot-image",
              !manifest.probe.bootSnapshot.active.isKnownStock,
              manifest.probe.bootSnapshot.active.byteCount == legacy.count,
              manifest.probe.bootSnapshot.active.sha256 == BackupManifest.digest(legacy) else {
            throw RecoveryProbeError.refused("The completed legacy NES snapshot does not match its captured image.")
        }
        let stockDirectory = try RestoreDirectory(stock.deletingLastPathComponent())
        let stockBytes = try stockDirectory.read(stock.lastPathComponent)
        try directory.check(); try stockDirectory.check()
        let plan = LegacyBoot2ActivationPlan(id: UUID(), expectedHWID: manifest.probe.observation.hwid,
            stockSHA256: BackupManifest.digest(stockBytes), stockBytes: stockBytes.count,
            legacySHA256: BackupManifest.digest(legacy), legacyBytes: legacy.count)
        let material = Self(plan: plan, stock: stockBytes, legacy: legacy)
        try material.validateIntegrity()
        return material
    }
}
