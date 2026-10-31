import Foundation
import SwiftHakchiCore

/// An inert Mac review. Its saved space estimate and installation reference grant no console access.
struct SNESLibrarySyncPlan: Sendable {
    enum Purpose: Sendable { case forward, recovery }
    let purpose: Purpose
    private struct Metric: Codable {
        let measuredAt: Date, freeBytes: Int64, blockSize: Int64
    }
    private struct Record: Codable {
        let version: Int, scope: String, id: UUID, requiredUSBVersion: Int
        let installation: SNESLibraryInstallationReference
        let materialDirectory: URL, materialSHA256: String, backupDirectory: URL, backupSHA256: String
        let originalFrameSHA256: String, catalogContentSHA256: String
        let beforeFrame: Data, beforeChallenge: UUID, beforeContextSHA256: String, metric: Metric
        let wireSHA256: String, descriptionSHA256: String
    }
    let data: Data, reviewSHA256: String, material: SNESLibraryMaterial, backup: SNESLibraryBackup, before: SNESLibraryInventory
    /// A recorded estimate only. The transaction must get a new checked native observation before a write.
    let projection: SNESLibraryCapacity
    let wireSHA256: String, descriptionSHA256: String
    let installation: SNESLibraryInstallationReference
    let requiredUSBVersion: UInt16
    private let guarded: SNESLibraryMaterialGuard
    private init(record: Record, raw: Data, material: SNESLibraryMaterial, backup: SNESLibraryBackup,
                 before: SNESLibraryInventory, projection: SNESLibraryCapacity, guarded: SNESLibraryMaterialGuard, purpose: Purpose = .forward) {
        self.purpose = purpose
        data = raw; reviewSHA256 = BackupManifest.digest(raw); self.material = material; self.backup = backup; self.before = before
        self.projection = projection; self.guarded = guarded; wireSHA256 = record.wireSHA256
        descriptionSHA256 = record.descriptionSHA256; installation = record.installation; requiredUSBVersion = UInt16(record.requiredUSBVersion)
    }
    private static func encode(_ record: Record) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(record)
    }
    static func prepare(material: SNESLibraryMaterial, backup: SNESLibraryBackup, before: SNESLibraryInventory,
                        capacity: SNESLibraryCapacity.Inventory?, installation: SNESLibraryInstallationReference,
                        originals: SNESOriginalGamesFrame, now: Date = Date()) throws -> Self {
        try installation.validate(); try material.validate(); try backup.validate()
        guard before.excludedMenuID == nil, installation.hwid == before.hwid, before.catalogSHA256 == (try SNESLibraryCatalogIdentity.digest(originals)),
              material.menu.description.catalogSHA256 == BackupManifest.digest(originals.raw),
              backup.inventory.snapshotSHA256 == before.snapshotSHA256, material.menu.id != before.selection.id,
              let capacity, capacity.blockSize == before.capacity.blockSize, capacity.freeBytes <= before.totalBytes,
              capacity.objects == before.capacity.objects,
              capacity.namespaceReady == before.capacity.namespaceReady, capacity.descriptionStoreReady == before.capacity.descriptionStoreReady else { throw SNESLibraryMenu.failure() }
        _ = try SNESLibraryRestore.prepare(backup: backup, originals: originals, expectedHWID: installation.hwid)
        try SNESLibraryRestore.validateStock(material.menu, originals: originals)
        let projection = try SNESLibraryCapacity.project(menu: material.menu, inventory: capacity, expectedContext: before.contextSHA256, now: now)
        let record = Record(version: 1, scope: "native-snes-library-review", id: material.menu.id, requiredUSBVersion: material.menu.description.version==2 ? 0x6a0b:0x6a07,
            installation: installation, materialDirectory: material.directory, materialSHA256: material.reviewSHA256,
            backupDirectory: backup.directory, backupSHA256: backup.manifestSHA256,
            originalFrameSHA256: BackupManifest.digest(originals.raw), catalogContentSHA256: before.catalogSHA256,
            beforeFrame: before.rawFrame, beforeChallenge: before.challenge, beforeContextSHA256: before.contextSHA256,
            metric: .init(measuredAt: capacity.measuredAt, freeBytes: capacity.freeBytes, blockSize: capacity.blockSize),
            wireSHA256: BackupManifest.digest(try SNESLibraryStartupScripts.manifest(for: material.menu)), descriptionSHA256: BackupManifest.digest(material.menu.manifest))
        let guarded = try SNESLibraryMaterialGuard.prepare(material), raw = try encode(record)
        guard raw.count <= 24 * 1024 * 1024 else { throw SNESLibraryMenu.failure() }
        let value = Self(record: record, raw: raw, material: material, backup: backup, before: before, projection: projection, guarded: guarded)
        try value.requireSources(); return value
    }
    static func load(data: Data, expectedReviewSHA256: String, originals: SNESOriginalGamesFrame, purpose: Purpose = .forward) throws -> Self {
        let sourcePolicy: SNESLibrarySourcePolicy = purpose == .forward ? .live : .frozenRecovery
        guard data.count <= 24 * 1024 * 1024, SNESDataSnapshotChunk.isDigest(expectedReviewSHA256), BackupManifest.digest(data) == expectedReviewSHA256 else { throw SNESLibraryMenu.failure() }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard data == (try encode(record)), record.version == 1, record.scope == "native-snes-library-review", [0x6a06, 0x6a07, 0x6a0b].contains(record.requiredUSBVersion),
              record.catalogContentSHA256 == (try SNESLibraryCatalogIdentity.digest(originals)) else { throw SNESLibraryMenu.failure() }
        try record.installation.validate()
        let before = try SNESLibraryInventory(raw: record.beforeFrame, challenge: record.beforeChallenge, contextSHA256: record.beforeContextSHA256,
            hwid: record.installation.hwid, catalogSHA256: record.catalogContentSHA256, measuredAt: record.metric.measuredAt)
        guard record.metric.blockSize == before.capacity.blockSize, record.metric.freeBytes <= before.totalBytes else { throw SNESLibraryMenu.failure() }
        let material = try SNESLibraryMaterial.load(directory: record.materialDirectory, expectedReviewSHA256: record.materialSHA256, sourcePolicy: sourcePolicy)
        guard (material.menu.description.version==2)==(record.requiredUSBVersion==0x6a0b) else {throw SNESLibraryMenu.failure()}
        let backup = try SNESLibraryBackup.open(directory: record.backupDirectory)
        guard material.menu.id == record.id, material.menu.id != before.selection.id,
              material.menu.description.catalogSHA256 == record.originalFrameSHA256,
              backup.manifestSHA256 == record.backupSHA256, backup.inventory.snapshotSHA256 == before.snapshotSHA256,
              BackupManifest.digest(material.menu.manifest) == record.descriptionSHA256,
              BackupManifest.digest(try SNESLibraryStartupScripts.manifest(for: material.menu)) == record.wireSHA256 else { throw SNESLibraryMenu.failure() }
        _ = try SNESLibraryRestore.prepare(backup: backup, originals: originals, expectedHWID: record.installation.hwid)
        try SNESLibraryRestore.validateStock(material.menu, originals: originals)
        let metric = SNESLibraryCapacity.Inventory(measuredAt: record.metric.measuredAt, contextSHA256: before.contextSHA256,
            freeBytes: record.metric.freeBytes, blockSize: record.metric.blockSize, objects: before.capacity.objects,
            namespaceReady: before.capacity.namespaceReady, descriptionStoreReady: before.capacity.descriptionStoreReady)
        // Reconstruct the original arithmetic, without representing this old metric as a live reading.
        let projection = try SNESLibraryCapacity.project(menu: material.menu, inventory: metric, expectedContext: before.contextSHA256, now: metric.measuredAt)
        let value = Self(record: record, raw: data, material: material, backup: backup, before: before, projection: projection,
            guarded: try SNESLibraryMaterialGuard.prepare(material, sourcePolicy: sourcePolicy), purpose: purpose)
        try value.requireSources(); return value
    }
    struct Identity: Sendable { let id: UUID, hwid: String, backupDirectory: URL, oldID: UUID?, oldKind: SNESLibraryInventory.MenuKind, namespaceReady: Bool }
    /// Metadata-only history lookup. No mutable ROM, backup or physical-device capability is loaded.
    static func identity(data: Data) throws -> Identity {
        guard data.count <= 24 * 1024 * 1024 else { throw SNESLibraryMenu.failure() }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard data == (try encode(record)), record.version == 1, record.scope == "native-snes-library-review", [0x6a06, 0x6a07, 0x6a0b].contains(record.requiredUSBVersion),
              [record.materialSHA256, record.backupSHA256, record.originalFrameSHA256, record.catalogContentSHA256,
               record.wireSHA256, record.descriptionSHA256].allSatisfy(SNESDataSnapshotChunk.isDigest),
              record.materialDirectory.isFileURL, record.backupDirectory.isFileURL,
              record.materialDirectory == record.materialDirectory.standardizedFileURL,
              record.backupDirectory == record.backupDirectory.standardizedFileURL,
              record.materialDirectory.lastPathComponent == "SNES-Library-" + record.id.uuidString,
              record.backupDirectory.lastPathComponent.hasPrefix("SNES-Library-"),
              UUID(uuidString: String(record.backupDirectory.lastPathComponent.dropFirst("SNES-Library-".count))) != nil else { throw SNESLibraryMenu.failure() }
        try record.installation.validate()
        let before = try SNESLibraryInventory(raw: record.beforeFrame, challenge: record.beforeChallenge, contextSHA256: record.beforeContextSHA256,
            hwid: record.installation.hwid, catalogSHA256: record.catalogContentSHA256, measuredAt: record.metric.measuredAt)
        return .init(id: record.id, hwid: record.installation.hwid, backupDirectory: record.backupDirectory, oldID: before.selection.id, oldKind: before.selection.kind, namespaceReady: before.capacity.namespaceReady)
    }
    func requireSources() throws { try guarded.require(); try backup.validate() }
    /// Owner/source eligibility only; still no current-device-state or write permission.
    func requireOwner(_ context: SNESLibraryContext) throws {
        try context.requireCurrent(attachment: context.attachment, sessionID: context.sessionID)
        guard (context.supportsLibrarySync || (purpose == .recovery && context.supportsLibraryRecovery)), context.attachment.deviceVersion == requiredUSBVersion,
              context.installation.reference == installation, context.installation.catalogContentSHA256 == before.catalogSHA256 else { throw SNESLibraryInstallation.failure() }
        guard material.menu.description.version != 2 || context.supportsNativeArtwork else {throw SNESLibraryInstallation.failure()}
        try requireSources()
    }
}
