import Foundation

/// A local catalog. Listing a backup never grants permission to restore it.
enum LegacyBackupHistory {
    enum Status: Equatable, Sendable {
        case verifiedInspection
        case restorable
        case invalid(String)
    }

    struct Entry: Identifiable, Sendable {
        let directory: URL
        let createdAt: Date?
        let byteCount: Int64?
        let scope: String
        let gameCount: Int?
        let consoleFingerprint: String?
        let status: Status

        var id: URL { directory }
        var sourceRoot: URL { directory.deletingLastPathComponent() }
    }

    static func scan(backups: URL) -> [Entry] {
        scan(roots: [backups])
    }

    static func scan(roots: [URL]) -> [Entry] {
        var seen = Set<String>()
        return roots.map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .flatMap(scanSingleRoot)
            .sorted { ($0.createdAt ?? .distantPast, $0.directory.path)
                > ($1.createdAt ?? .distantPast, $1.directory.path) }
    }

    static func inspect(directory: URL) -> Entry { read(directory) }

    private static func scanSingleRoot(_ backups: URL) -> [Entry] {
        let fm = FileManager.default
        guard let root = try? backups.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              root.isDirectory == true, root.isSymbolicLink != true,
              let directories = try? fm.contentsOfDirectory(at: backups,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        return directories.filter { $0.lastPathComponent.hasPrefix("LegacyInspection-") }
            .map(read)
    }

    private static func read(_ directory: URL) -> Entry {
        func invalid(_ reason: String, date: Date? = nil, bytes: Int64? = nil,
                     scope: String = "Console inspection", games: Int? = nil) -> Entry {
            Entry(directory: directory, createdAt: date, byteCount: bytes,
                  scope: scope, gameCount: games, consoleFingerprint: nil,
                  status: .invalid(reason))
        }
        guard let attributes = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              attributes.isDirectory == true, attributes.isSymbolicLink != true else {
            return invalid("This backup folder is a link or is not a directory.")
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let archiveURL = directory.appendingPathComponent("console.tar")
        guard let manifestAttributes = try? manifestURL.resourceValues(forKeys:
                  [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              manifestAttributes.isRegularFile == true, manifestAttributes.isSymbolicLink != true,
              let manifestSize = manifestAttributes.fileSize, manifestSize > 0, manifestSize <= 131_072,
              let archiveAttributes = try? archiveURL.resourceValues(forKeys:
                  [.isRegularFileKey, .isSymbolicLinkKey]),
              archiveAttributes.isRegularFile == true, archiveAttributes.isSymbolicLink != true,
              let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return invalid("The backup manifest or archive is missing or unsafe.")
        }
        let date = (object["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let bytes = (object["byteCount"] as? Int).map(Int64.init)
        let scope = object["scope"] as? String ?? "Console inspection"
        let games = (object["observedReport"] as? [String: Any])?["visibleCodes"] as? [String]
        guard object["formatVersion"] as? Int == 1,
              object["eligibleForAutomaticRestore"] as? Bool == false,
              object["deviceIdentityVerified"] as? Bool == false else {
            return invalid("This snapshot format is not supported for restore.", date: date,
                           bytes: bytes, scope: scope, games: games?.count)
        }
        do {
            try LegacyGameChangeService.verifyBackup(directory)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(LegacyMenuSnapshot.filename).path) {
                let snapshot = try LegacyMenuSnapshot.verify(directory: directory)
                return Entry(directory: directory, createdAt: date, byteCount: bytes,
                             scope: scope, gameCount: games?.count,
                             consoleFingerprint: String(snapshot.manifest.chipIDFingerprint.prefix(8)),
                             status: .restorable)
            }
            return Entry(directory: directory, createdAt: date, byteCount: bytes,
                         scope: scope, gameCount: games?.count,
                         consoleFingerprint: nil, status: .verifiedInspection)
        } catch {
            return invalid("The backup archive no longer matches its manifest.", date: date,
                           bytes: bytes, scope: scope, games: games?.count)
        }
    }
}
