import Foundation
import Darwin
import SwiftHakchiCore

/// Removes one explicitly selected Mac snapshot. It never operates on the console.
actor LegacyBackupDeletion {
    struct Preview: Sendable {
        let directory: URL
        let byteCount: Int64
        let manifestSHA256: String
        let status: LegacyBackupHistory.Status
        let dependencies: [String]
        let isLastRestorable: Bool

        var isEligible: Bool { dependencies.isEmpty }
    }

    enum Failure: Error, LocalizedError {
        case unsafeFolder, changed, dependent([String]), interruptedDeletion

        var errorDescription: String? {
            switch self {
            case .unsafeFolder:
                return "This backup has an unexpected file, link, or path. Review it in Finder; no files were removed."
            case .changed:
                return "This backup changed since the review. Refresh Backup History before removing it."
            case .dependent(let reasons):
                return "This backup is still needed for console recovery: \(reasons.joined(separator: "; "))."
            case .interruptedDeletion:
                return "An earlier permanent backup deletion needs review before another deletion."
            }
        }
    }

    private let workspace: WorkspacePaths
    private let store: LegacySyncJournalStore
    private static let allowedMembers: Set<String> = [
        "manifest.json", "console.tar", "archive-contents.txt", LegacyMenuSnapshot.filename
    ]

    init(workspace: WorkspacePaths) {
        self.workspace = workspace
        store = LegacySyncJournalStore(directory: workspace.journals)
    }

    func preview(directory: URL) async throws -> Preview {
        let normalized = directory.standardizedFileURL
        guard workspace.containsBackup(normalized),
              normalized == directory.standardizedFileURL,
              (normalized.lastPathComponent.range(of:
                #"^LegacyInspection-[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#,
                options: .regularExpression) != nil ||
               normalized.lastPathComponent.range(of:
                #"^LegacyInspection-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$"#,
                options: .regularExpression) != nil) else { throw Failure.unsafeFolder }
        try Self.validateFolder(normalized)
        let entry = LegacyBackupHistory.inspect(directory: normalized)
        guard entry.status == .verifiedInspection || entry.status == .restorable else {
            throw Failure.unsafeFolder
        }
        let manifest = try Data(contentsOf: normalized.appendingPathComponent("manifest.json"))
        let archive = normalized.appendingPathComponent("console.tar")
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let records = try await store.allRecords()
        var dependencies: [String] = []
        if records.contains(where: { ![.accepted, .discarded, .rolledBack].contains($0.phase) }) {
            dependencies.append("a library transaction is unfinished")
        }
        if let legacy = try LegacyGameChangeService.latest(workspace: workspace) {
            dependencies.append("a game change is unfinished (\(legacy.id.uuidString))")
        }
        for record in records where record.backupDirectory.path == normalized.path {
            dependencies.append("library operation \(record.operationID.uuidString) references this snapshot")
        }
        if let cleanup = try LegacyHistoricalCleanup.load(workspace: workspace),
           cleanup.phase != .completed, cleanup.backupDirectory.path == normalized.path {
            dependencies.append("old console files still depend on this backup until cleanup is complete")
        }
        let restorable = LegacyBackupHistory.scan(roots: workspace.knownBackupRoots)
            .filter { $0.status == .restorable }
        return Preview(directory: normalized, byteCount: Int64(size),
            manifestSHA256: BackupManifest.digest(manifest), status: entry.status,
            dependencies: dependencies,
            isLastRestorable: entry.status == .restorable && restorable.count == 1)
    }

    @discardableResult
    func moveToTrash(preview reviewed: Preview) async throws -> URL {
        let fresh = try await preview(directory: reviewed.directory)
        try requireUnchanged(reviewed, fresh)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: fresh.directory, resultingItemURL: &resultingURL)
        guard let result = resultingURL as URL? else { throw Failure.changed }
        return result
    }

    func deletePermanently(preview reviewed: Preview) async throws {
        let fresh = try await preview(directory: reviewed.directory)
        try requireUnchanged(reviewed, fresh)
        try Self.requireNoPendingIntent(in: workspace.journals)
        try FileManager.default.createDirectory(at: workspace.journals,
                                                withIntermediateDirectories: true)
        let intent = workspace.journals.appendingPathComponent("backup-delete-" + UUID().uuidString + ".json")
        let record = DeletionRecord(directory: fresh.directory.path,
            manifestSHA256: fresh.manifestSHA256, phase: .removalIntent)
        try Self.persist(record, to: intent)
        try FileManager.default.removeItem(at: fresh.directory)
        try Self.persist(DeletionRecord(directory: record.directory,
            manifestSHA256: record.manifestSHA256, phase: .completed), to: intent)
    }

    private func requireUnchanged(_ reviewed: Preview, _ fresh: Preview) throws {
        guard fresh.isEligible else { throw Failure.dependent(fresh.dependencies) }
        guard reviewed.directory == fresh.directory,
              reviewed.byteCount == fresh.byteCount,
              reviewed.manifestSHA256 == fresh.manifestSHA256,
              reviewed.status == fresh.status,
              reviewed.dependencies == fresh.dependencies,
              reviewed.isLastRestorable == fresh.isLastRestorable else { throw Failure.changed }
    }

    private static func validateFolder(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().path == directory.path else {
            throw Failure.unsafeFolder
        }
        let children = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard Set(children.map(\.lastPathComponent)).isSubset(of: allowedMembers),
              children.contains(where: { $0.lastPathComponent == "manifest.json" }),
              children.contains(where: { $0.lastPathComponent == "console.tar" }) else {
            throw Failure.unsafeFolder
        }
        for child in children {
            let attributes = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            var metadata = stat()
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  lstat(child.path, &metadata) == 0,
                  metadata.st_nlink == 1 else { throw Failure.unsafeFolder }
        }
    }

    private struct DeletionRecord: Codable {
        enum Phase: String, Codable { case removalIntent, completed }
        let directory: String
        let manifestSHA256: String
        let phase: Phase
    }

    private static func requireNoPendingIntent(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("backup-delete-") && $0.pathExtension == "json" }
        for file in files {
            let data = try Data(contentsOf: file)
            guard data.count <= 4096,
                  let record = try? JSONDecoder().decode(DeletionRecord.self, from: data),
                  record.phase == .completed else { throw Failure.interruptedDeletion }
        }
    }

    private static func persist(_ record: DeletionRecord, to url: URL) throws {
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
