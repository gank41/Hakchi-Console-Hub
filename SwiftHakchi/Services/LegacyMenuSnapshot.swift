import Foundation
import SWCompression
import SwiftHakchiCore

/// A menu-only restore index for a fully verified console archive. Older archives remain inspection-only.
enum LegacyMenuSnapshot {
    static let menuRoot = String(LegacyConsoleReport.gameRoot.dropFirst())
    static let filename = "menu-snapshot.json"

    struct Manifest: Codable, Sendable {
        let formatVersion: Int
        let createdAt: Date
        let archiveSHA256: String
        let archiveBytes: Int64
        let chipIDFingerprint: String
        let menuRoot: String
        let menuTreeSHA256: String
        let menuEntryCount: Int
    }

    struct Verified: Sendable {
        let manifest: Manifest
        let entries: [LegacyMenuStageManifest.Entry]
        let observedReport: LegacyConsoleReport
        var menuTreeSHA256: String { manifest.menuTreeSHA256 }
    }

    struct UnboundInspection: Sendable {
        let entries: [LegacyMenuStageManifest.Entry]
        let observedReport: LegacyConsoleReport
        let archiveSHA256: String
        let treeSHA256: String
    }

    static func inspectUnbound(directory: URL) throws -> UnboundInspection {
        try LegacyGameChangeService.verifyBackup(directory)
        let archive = try loadArchive(directory)
        let entries = try inventory(archive)
        return UnboundInspection(entries: entries,
            observedReport: try validateVisibleGames(entries, directory: directory),
            archiveSHA256: BackupManifest.digest(archive), treeSHA256: treeDigest(entries))
    }

    static func record(directory: URL, chipID: String) throws -> Verified {
        guard LegacyDeviceIdentity.matches(chipID,
            fingerprint: BackupManifest.digest(Data(chipID.utf8))) else {
            throw LegacyInspectionError.invalidBackup
        }
        try LegacyGameChangeService.verifyBackup(directory)
        let archive = try loadArchive(directory)
        let entries = try inventory(archive)
        let observedReport = try validateVisibleGames(entries, directory: directory)
        let manifest = Manifest(formatVersion: 2, createdAt: Date(),
            archiveSHA256: BackupManifest.digest(archive), archiveBytes: Int64(archive.count),
            chipIDFingerprint: BackupManifest.digest(Data(chipID.utf8)), menuRoot: menuRoot,
            menuTreeSHA256: treeDigest(entries), menuEntryCount: entries.count)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = directory.appendingPathComponent(filename)
        try encoder.encode(manifest).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        return Verified(manifest: manifest, entries: entries, observedReport: observedReport)
    }

    static func verify(directory: URL, expectedChipID: String? = nil) throws -> Verified {
        let folder = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folder.isDirectory == true, folder.isSymbolicLink != true else {
            throw LegacyInspectionError.invalidBackup
        }
        let file = directory.appendingPathComponent(filename)
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= 131_072 else {
            throw LegacyInspectionError.invalidBackup
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: file))
        guard manifest.formatVersion == 2, manifest.menuRoot == menuRoot,
              manifest.archiveSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              manifest.menuTreeSHA256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              manifest.chipIDFingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              manifest.archiveBytes >= 1024, manifest.archiveBytes <= 512 * 1024 * 1024,
              manifest.menuEntryCount > 0, manifest.menuEntryCount <= LegacyStageVerification.maximumEntries,
              expectedChipID.map({ LegacyDeviceIdentity.matches($0, fingerprint: manifest.chipIDFingerprint) }) ?? true else {
            throw LegacyInspectionError.invalidBackup
        }
        try LegacyGameChangeService.verifyBackup(directory)
        let archive = try loadArchive(directory)
        guard Int64(archive.count) == manifest.archiveBytes,
              BackupManifest.digest(archive) == manifest.archiveSHA256 else {
            throw LegacyInspectionError.invalidBackup
        }
        let entries = try inventory(archive)
        let observedReport = try validateVisibleGames(entries, directory: directory)
        guard entries.count == manifest.menuEntryCount,
              treeDigest(entries) == manifest.menuTreeSHA256 else {
            throw LegacyInspectionError.invalidBackup
        }
        return Verified(manifest: manifest, entries: entries, observedReport: observedReport)
    }

    private static func loadArchive(_ directory: URL) throws -> Data {
        let file = directory.appendingPathComponent("console.tar")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 1024, size <= 512 * 1024 * 1024,
              size % 512 == 0 else { throw LegacyInspectionError.invalidBackup }
        let archive = try Data(contentsOf: file)
        try validateTarHeaders(archive)
        return archive
    }

    private static func validateTarHeaders(_ archive: Data) throws {
        let bytes = [UInt8](archive)
        var offset = 0
        while offset <= bytes.count - 1024 {
            let header = bytes[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) {
                guard bytes[(offset + 512)...].allSatisfy({ $0 == 0 }) else {
                    throw LegacyInspectionError.invalidBackup
                }
                return
            }
            guard [UInt8(0), 48, 50, 53, 76].contains(bytes[offset + 156]),
                  let text = String(bytes: bytes[(offset + 124)..<(offset + 136)], encoding: .ascii)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \0")),
                  !text.isEmpty, text.utf8.allSatisfy({ (48...55).contains($0) }),
                  let size = Int(text, radix: 8), size >= 0, size <= bytes.count - offset - 512 else {
                throw LegacyInspectionError.invalidBackup
            }
            let padded = ((size + 511) / 512) * 512
            guard padded <= bytes.count - offset - 512 else { throw LegacyInspectionError.invalidBackup }
            offset += 512 + padded
        }
        throw LegacyInspectionError.invalidBackup
    }

    static func inventory(_ archive: Data) throws -> [LegacyMenuStageManifest.Entry] {
        let tar = try TarContainer.open(container: archive)
        let prefix = menuRoot + "/"
        var found = Set<String>()
        var folded = Set<String>()
        var entries: [LegacyMenuStageManifest.Entry] = []
        for item in tar {
            let rawName = item.info.name
            guard !rawName.hasPrefix("/"), !rawName.contains("\\"),
                  !rawName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw LegacyInspectionError.invalidBackup
            }
            let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard name == menuRoot || name.hasPrefix(prefix) else { continue }
            if name == menuRoot { continue }
            let relative = String(name.dropFirst(prefix.count))
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !relative.isEmpty, relative.utf8.count <= 100, !relative.contains("\\"),
                  !relative.contains(".."),
                  !relative.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  found.insert(relative).inserted, folded.insert(relative.lowercased()).inserted,
                  parts.count >= 1, parts.count <= 3,
                  parts[0].range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil else {
                throw LegacyInspectionError.invalidBackup
            }
            let pageFont = parts.count == 2 && ["copyright.fnt", "title.fnt"].contains(parts[1])
            if parts.count >= 2 && !pageFont {
                guard parts[1].range(of: #"^CLV-[A-Z]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil else {
                    throw LegacyInspectionError.invalidBackup
                }
            }
            if parts.count == 3 {
                guard parts[2].range(of: #"^[A-Za-z0-9._ ()+-]+$"#, options: .regularExpression) != nil,
                      parts[2] != ".", parts[2] != ".." else {
                    throw LegacyInspectionError.invalidBackup
                }
            }
            let kind: LegacyMenuStageManifest.Kind
            let data: Data?
            let target: String?
            switch item.info.type {
            case .directory:
                guard parts.count <= 2 else { throw LegacyInspectionError.invalidBackup }
                kind = .directory; data = nil; target = nil
            case .regular:
                guard (parts.count == 3 || pageFont), let content = item.data,
                      content.count <= (pageFont ? 1024 * 1024 : 8 * 1024 * 1024) else {
                    throw LegacyInspectionError.invalidBackup
                }
                kind = .regular; data = content; target = nil
            case .symbolicLink:
                guard parts.count == 3, parts[1].hasPrefix("CLV-P-"),
                      let link = item.info.linkName as String?,
                      link == LegacyConsoleReport.factoryRoot + "/" + parts[1] + "/" + parts[2] else {
                    throw LegacyInspectionError.invalidBackup
                }
                kind = .symbolicLink; data = nil; target = link
            default: throw LegacyInspectionError.invalidBackup
            }
            entries.append(.init(relativePath: relative, kind: kind,
                byteCount: Int64(data?.count ?? 0), sha256: data.map(BackupManifest.digest),
                linkTarget: target))
            guard entries.count <= LegacyStageVerification.maximumEntries else {
                throw LegacyInspectionError.invalidBackup
            }
        }
        guard found.contains("000"),
              entries.allSatisfy({ entry in
                let parent = (entry.relativePath as NSString).deletingLastPathComponent
                return parent == "" || found.contains(parent)
              }) else { throw LegacyInspectionError.invalidBackup }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    static func treeDigest(_ entries: [LegacyMenuStageManifest.Entry]) -> String {
        let description = entries.sorted { $0.relativePath < $1.relativePath }.map { entry in
            [entry.relativePath, entry.kind.rawValue, String(entry.byteCount),
             entry.sha256 ?? "", entry.linkTarget ?? ""].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        return BackupManifest.digest(Data(description.utf8))
    }

    static func gameCodes(_ entries: [LegacyMenuStageManifest.Entry]) -> Set<String> {
        Set(entries.compactMap { entry in
            guard entry.kind == .directory else { return nil }
            let parts = entry.relativePath.split(separator: "/").map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("CLV-P-") || parts[1].hasPrefix("CLV-H-") else {
                return nil
            }
            return parts[1]
        })
    }

    private static func validateVisibleGames(_ entries: [LegacyMenuStageManifest.Entry],
                                             directory: URL) throws -> LegacyConsoleReport {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard data.count <= 131_072,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reportObject = object["observedReport"],
              let reportData = try? JSONSerialization.data(withJSONObject: reportObject),
              let report = try? JSONDecoder().decode(LegacyConsoleReport.self, from: reportData),
              gameCodes(entries) == report.visibleCodes else {
            throw LegacyInspectionError.invalidBackup
        }
        return report
    }
}
