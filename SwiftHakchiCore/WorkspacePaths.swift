import Foundation

public struct WorkspacePaths: Sendable {
    public let root: URL
    private let backupOverride: URL?
    private let priorBackupRoots: [URL]
    public init(root: URL, activeBackups: URL? = nil, previousBackups: [URL] = []) {
        self.root = root.standardizedFileURL
        backupOverride = activeBackups?.standardizedFileURL
        priorBackupRoots = previousBackups.map(\.standardizedFileURL)
    }
    public var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    public var backups: URL {
        backupOverride ?? root.appendingPathComponent("Backups", isDirectory: true)
    }
    public var knownBackupRoots: [URL] {
        var seen = Set<String>()
        return ([backups] + priorBackupRoots).filter { seen.insert($0.path).inserted }
    }
    public func containsBackup(_ directory: URL) -> Bool {
        let normalized = directory.standardizedFileURL
        guard normalized.lastPathComponent.hasPrefix("LegacyInspection-") else { return false }
        return knownBackupRoots.contains { root in
            guard root.path == normalized.deletingLastPathComponent().path,
                  let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
                && root.resolvingSymlinksInPath().path == root.path
        }
    }
    public func requireActiveBackupsAvailable() throws {
        guard backupOverride != nil else { return }
        let values = try backups.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              backups.resolvingSymlinksInPath().path == backups.path,
              FileManager.default.isWritableFile(atPath: backups.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var profiles: URL { root.appendingPathComponent("Profiles", isDirectory: true) }
    public var journals: URL { root.appendingPathComponent("Journals", isDirectory: true) }
    public func gamesDirectory(systemCode: String) -> URL {
        let valid = systemCode.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil
        return library.appendingPathComponent("Games", isDirectory: true).appendingPathComponent(valid ? systemCode : "unknown", isDirectory: true)
    }
}
