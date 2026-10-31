import Foundation
import SwiftHakchiCore

/// Local listing and reversible removal only. These records never authorize a console operation.
enum SNESLibraryBackupHistory {
    struct Entry: Identifiable, Sendable {
        let directory: URL, summary: SNESLibraryBackup.Summary?, issue: String?
        var id: URL { directory }
    }
    struct Preview: Sendable {
        let directory: URL, manifestSHA256: String, byteCount: Int64, hwid: String
    }
    static func requireLocation(_ directory: URL, workspace: WorkspacePaths) throws {
        let name = directory.lastPathComponent
        guard directory.isFileURL, directory.query == nil, directory.fragment == nil,
              directory.path == directory.standardizedFileURL.path, directory.path == directory.resolvingSymlinksInPath().path,
              name.hasPrefix("SNES-Library-"), let id = UUID(uuidString: String(name.dropFirst(13))), name == "SNES-Library-" + id.uuidString,
              workspace.knownBackupRoots.contains(where: { root in
                  root.path == directory.deletingLastPathComponent().path && root.path == root.resolvingSymlinksInPath().path
              }) else { throw failure("Choose a saved SNES library in one of your Backups Folders.") }
        _ = try RestoreDirectory(directory.deletingLastPathComponent())
    }
    static func scan(roots: [URL]) throws -> [Entry] {
        guard roots.count <= 16 else { throw failure("There are too many backup locations to review.") }
        var result: [Entry] = [], seen = Set<String>()
        for root in roots where seen.insert(root.standardizedFileURL.path).inserted {
            if !FileManager.default.fileExists(atPath: root.path) { continue }
            let folder = try RestoreDirectory(root)
            for name in try folder.names().filter({ $0.hasPrefix("SNES-Library-") }) {
                guard result.count < 256 else { throw failure("Review older backups in Finder before listing more backups.") }
                let directory = folder.url.appendingPathComponent(name)
                do { result.append(.init(directory: directory, summary: try SNESLibraryBackup.summary(directory: directory), issue: nil)) }
                catch { result.append(.init(directory: directory, summary: nil, issue: error.localizedDescription)) }
            }
        }
        return result.sorted { ($0.summary?.created ?? .distantPast, $0.directory.path) > ($1.summary?.created ?? .distantPast, $1.directory.path) }
    }
    static func preview(directory: URL, workspace: WorkspacePaths, journals: URL) throws -> Preview {
        try requireLocation(directory, workspace: workspace)
        let lease = try SNESLibraryJournal.backupDeletionLease(directory: directory, root: journals)
        defer { try? lease.closeLease() }
        let backup = try SNESLibraryBackup.open(directory: directory), summary = try SNESLibraryBackup.summary(directory: directory)
        try backup.validate()
        guard summary.manifestSHA256 == backup.manifestSHA256 else { throw failure("This backup changed. Refresh Backup History and try again.") }
        return .init(directory: backup.directory, manifestSHA256: backup.manifestSHA256, byteCount: summary.byteCount, hwid: backup.inventory.hwid)
    }
    @discardableResult static func moveToTrash(preview: Preview, workspace: WorkspacePaths, journals: URL,
        mover: (@Sendable (URL) throws -> URL)? = nil) throws -> URL {
        try requireLocation(preview.directory, workspace: workspace)
        let lease = try SNESLibraryJournal.backupDeletionLease(directory: preview.directory, root: journals)
        defer { try? lease.closeLease() }
        let backup = try SNESLibraryBackup.open(directory: preview.directory), summary = try SNESLibraryBackup.summary(directory: preview.directory)
        guard backup.manifestSHA256 == preview.manifestSHA256, summary.manifestSHA256 == preview.manifestSHA256,
              summary.byteCount == preview.byteCount, summary.hwid == preview.hwid else { throw failure("This backup changed. Review it again before removing it.") }
        try backup.validate()
        if let mover { return try mover(backup.directory) }
        return try trash(backup.directory)
    }
    private static func trash(_ directory: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: directory, resultingItemURL: &resulting)
        guard let result = resulting as URL? else { throw failure("Check the Trash in Finder to see whether this backup was moved.") }
        return result
    }
    static func failure(_ message: String) -> RecoveryProbeError { .refused(message) }
}
