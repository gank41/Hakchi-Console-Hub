import Foundation
import SwiftHakchiCore

/// An inert, deterministic retirement list. A fresh native preview and separate journal permit are still required.
struct SNESLibraryCleanupPlan: Sendable {
    private struct Record: Codable {
        let version: Int, id: UUID, syncReviewSHA256: String, hwid: String
        let backup: SNESLibrarySnapshotReference, oldBackupSHA256: String
        let files: [SNESLibraryInventory.File], directories: [String], protectedObjects: [String], retiredObjects: [String]
    }
    let data: Data, reviewSHA256: String, files: [SNESLibraryInventory.File], directories: [String]
    let syncReviewSHA256: String
    let protectedObjects: Set<String>, retiredObjects: Set<String>, backupReference: SNESLibrarySnapshotReference
    let protectedMenus: [SNESLibraryInventory.Menu]
    let oldMenuID: UUID?, oldMenuKind: SNESLibraryInventory.MenuKind
    private let material: SNESLibraryMaterialGuard, oldBackup: SNESLibraryBackup, currentBackup: SNESLibraryBackup
    var hwid: String { oldBackup.inventory.hwid }
    var selection: SNESLibraryInventory.Selection { currentBackup.inventory.selection }
    var totalBytes: Int64 { currentBackup.inventory.totalBytes }
    private init(record: Record, data: Data, plan: SNESLibrarySyncPlan, backup: SNESLibraryBackup) throws {
        self.data = data; reviewSHA256 = BackupManifest.digest(data); files = record.files; directories = record.directories; syncReviewSHA256 = record.syncReviewSHA256
        protectedObjects = Set(record.protectedObjects); retiredObjects = Set(record.retiredObjects); backupReference = record.backup
        oldMenuID = plan.before.selection.id; oldMenuKind = plan.before.selection.kind
        protectedMenus = try (plan.before.menus.filter { $0.kind == .library && $0.id != plan.before.selection.id } + [SNESLibraryInactiveCheck.expectedMenu(plan)]).sorted { $0.id.uuidString < $1.id.uuidString }
        material = try SNESLibraryMaterialGuard.prepare(plan.material, sourcePolicy: .frozenRecovery)
        oldBackup = plan.backup; currentBackup = backup
    }
    static func prepare(plan: SNESLibrarySyncPlan, current: SNESLibraryInventory, backup: SNESLibraryBackup,
                        originals: SNESOriginalGamesFrame) throws -> Self {
        try plan.material.validate(sourcePolicy: .frozenRecovery); try plan.backup.validate(); try backup.validate()
        guard current.snapshotSHA256 == backup.inventory.snapshotSHA256, current.hwid == plan.before.hwid,
              try SNESLibraryCatalogIdentity.digest(originals) == plan.before.catalogSHA256 else { throw SNESLibraryInventory.failure() }
        _ = try SNESLibraryRestore.prepare(backup: plan.backup, originals: originals, expectedHWID: plan.before.hwid)
        _ = try SNESLibraryRestore.prepare(backup: backup, originals: originals, expectedHWID: plan.before.hwid)
        let old = plan.before.selection
        guard old.id != plan.material.menu.id else { throw SNESLibraryInventory.failure() }
        let protected = Set(plan.before.menus.filter { $0.kind == .library && $0.id != old.id }.flatMap(\.references))
            .union(plan.material.menu.objectRecords.map(\.name))
        let oldReferences = old.kind == .library ? Set(plan.before.menus.first { $0.id == old.id }?.references ?? []) : []
        let retired = oldReferences.subtracting(protected)
        try requireCurrent(plan: plan, inventory: current, retiredObjects: retired)
        let root = old.id.map { (old.kind == .legacy ? "legacy/menus/" : "menus/") + $0.uuidString }
        let targets = plan.before.files.filter { file in
            if let root, file.path.hasPrefix(root + "/") { return true }
            if old.kind == .legacy, file.path == "legacy/active-menu" { return true }
            if old.kind == .library, let id = old.id, file.path == "descriptions/" + id.uuidString + ".json" { return true }
            return file.path.hasPrefix("objects/") && retired.contains(String(file.path.dropFirst(8)))
        }.sorted { $0.path < $1.path }
        var directories = Set<String>()
        for file in targets {
            let bytes = try plan.backup.read(path: file.path)
            guard bytes.count == file.byteCount, BackupManifest.digest(bytes) == file.sha256 else { throw SNESLibraryInventory.failure() }
            if let root, file.path.hasPrefix(root + "/") {
                guard let initialSlash = file.path.lastIndex(of: "/") else { throw SNESLibraryInventory.failure() }
                var path = String(file.path[..<initialSlash])
                while path == root || path.hasPrefix(root + "/") {
                    directories.insert(path)
                    guard let slash = path.lastIndex(of: "/") else { break }; path = String(path[..<slash])
                }
            }
        }
        let reference = try SNESLibrarySnapshotReference(backup)
        let record = Record(version: 1, id: plan.material.menu.id, syncReviewSHA256: plan.reviewSHA256, hwid: plan.before.hwid,
            backup: reference, oldBackupSHA256: plan.backup.manifestSHA256, files: targets,
            directories: directories.sorted { a,b in a.split(separator: "/").count == b.split(separator: "/").count ? a < b : a.split(separator: "/").count > b.split(separator: "/").count },
            protectedObjects: protected.sorted(), retiredObjects: retired.sorted())
        let data = try SNESLibraryMenu.encode(record)
        guard data.count <= 4 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        return try Self(record: record, data: data, plan: plan, backup: backup)
    }
    static func load(data: Data, expectedReviewSHA256: String, plan: SNESLibrarySyncPlan, originals: SNESOriginalGamesFrame) throws -> Self {
        guard data.count <= 4 * 1024 * 1024, SNESDataSnapshotChunk.isDigest(expectedReviewSHA256), BackupManifest.digest(data) == expectedReviewSHA256 else { throw SNESLibraryInventory.failure() }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard try SNESLibraryMenu.encode(record) == data, record.version == 1, record.id == plan.material.menu.id,
              record.syncReviewSHA256 == plan.reviewSHA256, record.hwid == plan.before.hwid, record.oldBackupSHA256 == plan.backup.manifestSHA256 else { throw SNESLibraryInventory.failure() }
        let backup = try record.backup.reopen()
        let rebuilt = try prepare(plan: plan, current: backup.inventory, backup: backup, originals: originals)
        guard rebuilt.data == data else { throw SNESLibraryInventory.failure() }; return rebuilt
    }
    func validateSources() throws { try material.require(); try oldBackup.validate(); try currentBackup.validate() }
    func requireCurrent(_ plan: SNESLibrarySyncPlan, inventory: SNESLibraryInventory) throws {
        try validateSources()
        guard syncReviewSHA256 == plan.reviewSHA256, inventory.snapshotSHA256 == backupReference.snapshotSHA256 else { throw SNESLibraryInventory.failure() }
        try Self.requireCurrent(plan: plan, inventory: inventory, retiredObjects: retiredObjects)
    }
    /// Assess known retirement gaps only. The normalized frame stays local and never becomes an observation or copy authority.
    static func requireCurrent(plan: SNESLibrarySyncPlan, inventory: SNESLibraryInventory, retiredObjects: Set<String>) throws {
        let old = plan.before.selection
        guard inventory.excludedMenuID == nil || (old.kind == .library && inventory.excludedMenuID == old.id) else { throw SNESLibraryInventory.failure() }
        var rows = String(decoding: inventory.rawFrame, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "END" && !$0.hasPrefix("EXCLUDED ") }
        rows[0] = "SWIFTHAKCHI_SNES_LIBRARY_INVENTORY_V1 " + inventory.challenge.uuidString
        if old.kind == .library, let prior = plan.before.menus.first(where: { $0.id == old.id }), !inventory.menus.contains(where: { $0.id == old.id }) {
            guard let hash = prior.descriptionSHA256 else { throw SNESLibraryInventory.failure() }
            rows.append("MENU library \(prior.id.uuidString) \(prior.treeSHA256) \(prior.manifestBytes) \(prior.descriptionBytes) \(hash)")
            for name in prior.references { rows.append("REF \(prior.id.uuidString) \(name)") }
        }
        for name in retiredObjects where inventory.capacity.objects[name] == nil {
            guard let record = plan.before.capacity.objects[name] else { throw SNESLibraryInventory.failure() }
            rows.append("OBJECT \(record.name) \(record.byteCount) \(record.sha256)")
        }
        rows.append("END")
        let normalized = try SNESLibraryInventory(raw: Data((rows.joined(separator: "\n") + "\n").utf8), challenge: inventory.challenge,
            contextSHA256: inventory.contextSHA256, hwid: inventory.hwid, catalogSHA256: inventory.catalogSHA256)
        try SNESLibraryActiveCheck.require(plan, inventory: normalized, preserveProfiles: false)
    }
}
