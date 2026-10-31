import Foundation
import SwiftHakchiCore

/// Immutable Mac bytes matching the already checked live file hashes. No console authority.
struct SNESLibraryBackupReuse: Sendable {
    private let bytes: [String: Data]
    static func prepare(inventory: SNESLibraryInventory, material: SNESLibraryMaterial?, backups: [SNESLibraryBackup]) throws -> Self {
        guard backups.count <= 16 else { throw SNESLibraryInventory.failure() }
        var wanted: [String: Int] = [:], cached: [String: Data] = [:], total = 0
        for file in inventory.files {
            guard wanted[file.sha256] == nil || wanted[file.sha256] == file.byteCount else { throw SNESLibraryInventory.failure() }
            wanted[file.sha256] = file.byteCount
        }
        func include(_ data: Data) throws {
            try Task.checkCancellation()
            let hash = BackupManifest.digest(data)
            guard wanted[hash] == data.count, cached[hash] == nil, total <= 192 * 1024 * 1024 - data.count else { return }
            cached[hash] = data; total += data.count
        }
        if let material {
            try material.validate(sourcePolicy: .frozenRecovery)
            for data in material.menu.objects.values { try include(data) }
            for data in material.menu.files.values { try include(data) }
            let wire = try SNESLibraryStartupScripts.manifest(for: material.menu)
            try include(wire); try include(material.menu.manifest)
            try include(Data("SWIFTHAKCHI_SNES_LIBRARY_SELECTOR_V1\nMENU\n\(material.menu.id.uuidString)\n\(BackupManifest.digest(wire))\n".utf8))
        }
        for backup in backups where backup.inventory.hwid == inventory.hwid && backup.inventory.catalogSHA256 == inventory.catalogSHA256 {
            try backup.validate()
            for file in backup.inventory.files where wanted[file.sha256] == file.byteCount && cached[file.sha256] == nil {
                try include(backup.read(path: file.path))
            }
            try backup.validate()
        }
        return Self(bytes: cached)
    }
    func chunk(file: SNESLibraryInventory.File, offset: Int) throws -> Data? {
        if file.byteCount == 0 {
            guard offset == 0 else { throw SNESLibraryInventory.failure() }
            return bytes[file.sha256].flatMap { $0.isEmpty ? $0 : nil }
        }
        let count = try SNESLibraryBackupChunk.count(file: file, offset: offset)
        guard let data = bytes[file.sha256], data.count == file.byteCount else { return nil }
        return Data(data[offset..<offset+count])
    }
}
