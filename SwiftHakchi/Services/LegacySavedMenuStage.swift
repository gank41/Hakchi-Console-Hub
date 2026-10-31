import Foundation
import SWCompression
import SwiftHakchiCore

/// Extracts only a validated saved NES menu into a new local inactive stage.
enum LegacySavedMenuStage {
    static func build(snapshotDirectory: URL, expectedChipID: String,
                      in stages: URL) throws -> LegacyMenuStageManifest {
        let saved = try LegacyMenuSnapshot.verify(directory: snapshotDirectory,
                                                  expectedChipID: expectedChipID)
        let parent = stages.standardizedFileURL
        if FileManager.default.fileExists(atPath: parent.path) {
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LegacyInspectionError.invalidBackup
            }
        } else {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let root = parent.appendingPathComponent("LegacyMenuStage-" + UUID().uuidString, isDirectory: true)
        let menu = root.appendingPathComponent("menu", isDirectory: true)
        try FileManager.default.createDirectory(at: menu, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: root) } }

        let archive = try Data(contentsOf: snapshotDirectory.appendingPathComponent("console.tar"))
        let prefix = LegacyMenuSnapshot.menuRoot + "/"
        var dataByPath: [String: Data] = [:]
        for item in try TarContainer.open(container: archive) where item.info.type == .regular {
            guard !item.info.name.hasPrefix("/") else { throw LegacyInspectionError.invalidBackup }
            let name = item.info.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard name.hasPrefix(prefix) else { continue }
            let relative = String(name.dropFirst(prefix.count))
            guard dataByPath.updateValue(item.data ?? Data(), forKey: relative) == nil else {
                throw LegacyInspectionError.invalidBackup
            }
        }
        let expectedFiles = Set(saved.entries.filter { $0.kind == .regular }.map(\.relativePath))
        guard Set(dataByPath.keys) == expectedFiles else { throw LegacyInspectionError.invalidBackup }
        for entry in saved.entries {
            let path = menu.appendingPathComponent(entry.relativePath)
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            case .regular:
                guard let bytes = dataByPath[entry.relativePath],
                      Int64(bytes.count) == entry.byteCount,
                      BackupManifest.digest(bytes) == entry.sha256 else {
                    throw LegacyInspectionError.invalidBackup
                }
                try bytes.write(to: path, options: .atomic)
            case .symbolicLink:
                guard let target = entry.linkTarget else { throw LegacyInspectionError.invalidBackup }
                try FileManager.default.createSymbolicLink(atPath: path.path,
                    withDestinationPath: target)
            }
        }
        let tarURL = root.appendingPathComponent("menu.tar")
        FileManager.default.createFile(atPath: tarURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tarURL)
        defer { try? handle.close() }
        var writer = SWCompression.TarWriter(fileHandle: handle, force: .ustar)
        for entry in saved.entries {
            var info = TarEntryInfo(name: entry.relativePath,
                type: entry.kind == .directory ? .directory : entry.kind == .regular ? .regular : .symbolicLink)
            info.permissions = Permissions(rawValue: entry.kind == .directory ? 0o755 : entry.kind == .regular ? 0o644 : 0o777)
            info.ownerID = 0; info.groupID = 0; info.modificationTime = Date(timeIntervalSince1970: 0)
            info.linkName = entry.linkTarget ?? ""
            try writer.append(TarEntry(info: info,
                data: entry.kind == .regular ? dataByPath[entry.relativePath] : nil))
        }
        try writer.finalize(); try handle.close()
        let source = try LegacySyncPlan.SourceFile.capture(tarURL)
        guard source.byteCount <= 256 * 1024 * 1024 else { throw LegacyInspectionError.invalidBackup }
        let review = BackupManifest.digest(Data((saved.manifest.archiveSHA256 +
            saved.manifest.chipIDFingerprint + saved.manifest.menuTreeSHA256).utf8))
        let manifest = LegacyMenuStageManifest(reviewSHA256: review, menuDirectory: menu,
            archiveURL: tarURL, entries: saved.entries, treeSHA256: saved.menuTreeSHA256,
            archiveSHA256: source.sha256, archiveBytes: source.byteCount)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        complete = true
        return manifest
    }
}
