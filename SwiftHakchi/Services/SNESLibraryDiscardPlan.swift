import Foundation
import SwiftHakchiCore

/// Inert cancellation scope. A native inspection and a separate live journal permit are still required to delete anything.
struct SNESLibraryDiscardPlan: Sendable {
    struct Upload: Codable, Equatable, Sendable { let byteCount: Int, sha256: String }
    private struct Record: Codable {
        let version: Int, scope: String, id: UUID, syncReviewSHA256: String, backupSHA256: String, hwid: String
        let upload: Upload?, selection: SNESLibraryInventory.Selection, retireNamespace: Bool
        let fileTargets: [SNESLibraryMenu.FileRecord], directories: [String], protectedObjects: [String], retiredObjects: [String]
        let protectedMenus: [SNESLibraryInventory.Menu]
    }
    let data: Data, reviewSHA256: String, syncReviewSHA256: String
    let fileTargets: [SNESLibraryMenu.FileRecord], directories: [String], protectedMenus: [SNESLibraryInventory.Menu]
    let protectedObjects: Set<String>, retiredObjects: Set<String>, selection: SNESLibraryInventory.Selection
    let retireNamespace: Bool, upload: Upload?
    let hwid: String, totalBytes: Int64, retiredMenuID: UUID
    private let material: SNESLibraryMaterialGuard, backup: SNESLibraryBackup, before: SNESLibraryInventory
    private let expectedMenu: SNESLibraryInventory.Menu, expectedObjects: [String: SNESLibraryObjects.Record]
    private init(record: Record, data: Data, plan: SNESLibrarySyncPlan, material: SNESLibraryMaterialGuard) throws {
        self.data = data; reviewSHA256 = BackupManifest.digest(data); syncReviewSHA256 = record.syncReviewSHA256
        fileTargets = record.fileTargets; directories = record.directories; protectedMenus = record.protectedMenus
        protectedObjects = Set(record.protectedObjects); retiredObjects = Set(record.retiredObjects); selection = record.selection
        retireNamespace = record.retireNamespace; upload = record.upload; hwid = record.hwid; retiredMenuID = record.id
        totalBytes = plan.before.totalBytes; self.material = material; backup = plan.backup; before = plan.before
        expectedMenu = try SNESLibraryInactiveCheck.expectedMenu(plan)
        expectedObjects = Dictionary(uniqueKeysWithValues: plan.material.menu.objectRecords.map { ($0.name, $0) })
    }
    static func prepare(plan: SNESLibrarySyncPlan, current: SNESLibraryInventory, upload: Upload?) throws -> Self {
        let scope = try build(plan: plan, upload: upload)
        // A reported partial upload belongs only to the explicitly excluded, still inactive stage.
        guard upload == nil || current.excludedMenuID == plan.material.menu.id else { throw SNESLibraryInventory.failure() }
        try scope.requireCurrent(plan, inventory: current); return scope
    }
    private static func build(plan: SNESLibrarySyncPlan, upload: Upload?) throws -> Self {
        let material = try SNESLibraryMaterialGuard.prepare(plan.material, sourcePolicy: .frozenRecovery)
        try plan.backup.validate()
        let menu = plan.material.menu, root = "menus/" + menu.id.uuidString
        guard plan.before.selection.id != menu.id else { throw SNESLibraryInventory.failure() }
        let beforeObjects = plan.before.capacity.objects, retired = Set(menu.objects.keys).subtracting(beforeObjects.keys)
        var files: [String: Data] = Dictionary(uniqueKeysWithValues: menu.files.map { (root + "/" + $0.key, $0.value) })
        let wire = try SNESLibraryStartupScripts.manifest(for: menu)
        files[root + "/menu.manifest"] = wire
        files["descriptions/" + menu.id.uuidString + ".json"] = menu.manifest
        for name in retired {
            guard let bytes = menu.objects[name] else { throw SNESLibraryInventory.failure() }
            files["objects/" + name] = bytes
        }
        var targets = files.keys.sorted().map { SNESLibraryMenu.FileRecord(path: $0, byteCount: files[$0]!.count, sha256: BackupManifest.digest(files[$0]!)) }
        if let upload {
            guard upload.byteCount >= 0, upload.byteCount <= 4 * 1024 * 1024 + 96, SNESDataSnapshotChunk.isDigest(upload.sha256),
                  (Array(files.values) + [Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(menu.id.uuidString)\n\(BackupManifest.digest(wire))\n".utf8)]).contains(where: {
                      $0.count >= upload.byteCount && BackupManifest.digest(Data($0.prefix(upload.byteCount))) == upload.sha256
                  }) else { throw SNESLibraryInventory.failure() }
            targets.append(.init(path: root + "/.upload", byteCount: upload.byteCount, sha256: upload.sha256))
        }
        var directories: Set<String> = [root]
        for file in targets where file.path.hasPrefix(root + "/") {
            var path = String(file.path[..<file.path.lastIndex(of: "/")!])
            while path == root || path.hasPrefix(root + "/") {
                directories.insert(path)
                guard let slash = path.lastIndex(of: "/") else { break }; path = String(path[..<slash])
            }
        }
        let retireNamespace = !plan.before.capacity.namespaceReady
        if retireNamespace { directories.formUnion(["namespace", "objects", "menus", "descriptions"]) }
        func depth(_ name: String) -> Int { name == "namespace" ? 0 : name.split(separator: "/").count }
        let record = Record(version: 1, scope: "discard-inactive-snes-copy", id: menu.id, syncReviewSHA256: plan.reviewSHA256,
            backupSHA256: plan.backup.manifestSHA256, hwid: plan.before.hwid, upload: upload, selection: plan.before.selection,
            retireNamespace: retireNamespace, fileTargets: targets.sorted { $0.path < $1.path },
            directories: directories.sorted { depth($0) == depth($1) ? $0 < $1 : depth($0) > depth($1) },
            protectedObjects: beforeObjects.keys.sorted(), retiredObjects: retired.sorted(),
            protectedMenus: plan.before.menus.filter { $0.kind == .library }.sorted { $0.id.uuidString < $1.id.uuidString })
        let data = try SNESLibraryMenu.encode(record)
        guard data.count <= 4 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        return try Self(record: record, data: data, plan: plan, material: material)
    }
    static func load(data: Data, expectedReviewSHA256: String, plan: SNESLibrarySyncPlan) throws -> Self {
        guard data.count <= 4 * 1024 * 1024, BackupManifest.digest(data) == expectedReviewSHA256 else { throw SNESLibraryInventory.failure() }
        let record = try JSONDecoder().decode(Record.self, from: data)
        let rebuilt = try build(plan: plan, upload: record.upload)
        guard rebuilt.data == data else { throw SNESLibraryInventory.failure() }; return rebuilt
    }
    func validateSources() throws { try material.require(); try backup.validate() }
    /// Cancellation leaves the working library and every save alone; later profile progress need not be rolled back.
    func requireCurrent(_ plan: SNESLibrarySyncPlan, inventory: SNESLibraryInventory) throws {
        try validateSources()
        guard syncReviewSHA256 == plan.reviewSHA256, inventory.hwid == hwid, inventory.catalogSHA256 == before.catalogSHA256,
              inventory.totalBytes == before.totalBytes, inventory.capacity.blockSize == before.capacity.blockSize,
              inventory.excludedMenuID == nil || inventory.excludedMenuID == retiredMenuID,
              inventory.selection == selection,
              SNESLibraryPreviousCheck.protectedFilesMatch(before: before, inventory: inventory) else { throw SNESLibraryInventory.failure() }
        if before.capacity.namespaceReady { guard inventory.capacity.namespaceReady, !inventory.incompleteNamespace else { throw SNESLibraryInventory.failure() } }
        if before.capacity.descriptionStoreReady { guard inventory.capacity.descriptionStoreReady else { throw SNESLibraryInventory.failure() } }
        for (name, record) in before.capacity.objects { guard inventory.capacity.objects[name] == record else { throw SNESLibraryInventory.failure() } }
        for (name, record) in inventory.capacity.objects where before.capacity.objects[name] == nil {
            guard retiredObjects.contains(name), expectedObjects[name] == record else { throw SNESLibraryInventory.failure() }
        }
        var menus = Dictionary(uniqueKeysWithValues: inventory.menus.map { ($0.id, $0) })
        if let staged = menus.removeValue(forKey: retiredMenuID) { guard staged == expectedMenu else { throw SNESLibraryInventory.failure() } }
        guard menus == Dictionary(uniqueKeysWithValues: before.menus.map { ($0.id, $0) }) else { throw SNESLibraryInventory.failure() }
    }
}
