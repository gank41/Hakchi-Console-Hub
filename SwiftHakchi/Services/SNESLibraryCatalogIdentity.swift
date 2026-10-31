import Foundation
import SwiftHakchiCore

/// Original content identity excludes capture challenges and paths; hardware identity is checked separately.
enum SNESLibraryCatalogIdentity {
    private struct File: Encodable { let name: String, bytes: Int, sha256: String }
    private struct Entry: Encodable { let code: String, romSHA256: String, romBytes: Int, headersSHA256: String, files: [File] }
    private struct Record: Encodable { let version = 1; let launcherSHA256: String, entries: [Entry] }
    static func digest(_ frame: SNESOriginalGamesFrame) throws -> String {
        let entries = frame.entries.sorted { $0.code < $1.code }.map { entry in
            Entry(code: entry.code, romSHA256: entry.romSHA256, romBytes: entry.romBytes, headersSHA256: BackupManifest.digest(entry.headers),
                files: entry.files.sorted { $0.name < $1.name }.map { File(name: $0.name, bytes: $0.data.count, sha256: BackupManifest.digest($0.data)) })
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return BackupManifest.digest(try encoder.encode(Record(launcherSHA256: BackupManifest.digest(frame.launcher), entries: entries)))
    }
}
