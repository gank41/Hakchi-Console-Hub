import Foundation
import Darwin
import SwiftHakchiCore

/// Durable Mac-only review storage. A saved review is not a write permit.
enum SNESReplacementSaveReviewStore {
    struct Receipt: Sendable { let directory: URL, sha256: String }
    private static let prefix = "SNES-Save-Review-"

    static func save(_ review: SNESReplacementSaveEnvelope, root: URL) throws -> Receipt {
        try Task.checkCancellation(); try review.validate()
        guard review.sha256 == BackupManifest.digest(review.data), review.data.count <= 4 * 1024 * 1024 else { throw SNESLibraryInventory.failure() }
        let storage = try RestoreJournalStorage(root: root)
        defer { try? storage.closeLease() }
        let name = prefix + UUID().uuidString
        guard mkdirat(storage.root.fd, name, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        guard fchmod(directory.fd, 0o700) == 0 else { throw RestoreDirectory.failure() }
        try storage.write(review.data, name: "review.json", directory: directory)
        try storage.sync(directory); try storage.sync(storage.root)
        guard try directory.names() == ["review.json"], try directory.read("review.json", maximum: 4 * 1024 * 1024) == review.data else {
            throw RestoreDirectory.failure()
        }
        try review.plan.validate(); try storage.closeLease()
        return .init(directory: directory.url, sha256: review.sha256)
    }

    static func open(_ receipt: Receipt, originals: SNESOriginalGamesFrame) throws -> SNESReplacementSaveEnvelope {
        guard receipt.directory.isFileURL, receipt.directory == receipt.directory.standardizedFileURL,
              receipt.directory.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(receipt.directory.lastPathComponent.dropFirst(prefix.count))),
              receipt.directory.lastPathComponent == prefix + id.uuidString, SNESDataSnapshotChunk.isDigest(receipt.sha256) else {
            throw SNESLibraryInventory.failure()
        }
        let directory = try RestoreDirectory(receipt.directory)
        var info = stat(), file = stat()
        guard fstat(directory.fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              fstatat(directory.fd, "review.json", &file, AT_SYMLINK_NOFOLLOW) == 0,
              file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1, file.st_mode & 0o777 == 0o600,
              try directory.names() == ["review.json"] else { throw RestoreDirectory.failure() }
        let raw = try directory.read("review.json", maximum: 4 * 1024 * 1024)
        let review = try SNESReplacementSaveEnvelope.load(data: raw, expectedSHA256: receipt.sha256, originals: originals)
        try directory.check(); return review
    }

    /// Reconstruct an offline review after the app has closed. The contents are
    /// still fully revalidated against both backups and do not authorize a write.
    static func open(directory url: URL, originals: SNESOriginalGamesFrame) throws -> SNESReplacementSaveEnvelope {
        let directory = try RestoreDirectory(url)
        let raw = try directory.read("review.json", maximum: 4 * 1024 * 1024)
        try directory.check()
        return try open(.init(directory: directory.url, sha256: BackupManifest.digest(raw)), originals: originals)
    }
}
