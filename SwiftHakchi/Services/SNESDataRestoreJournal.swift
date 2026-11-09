import Foundation
import Darwin
import SwiftHakchiCore

/// Offline evidence only. It neither proves backup freshness nor authorizes a console write.
/// Deleting the entire journal or its root defeats detection without an external witness.
actor SNESDataRestoreJournal {
    // An absent intent record cannot prove that one was never written.
    enum Phase: Sendable { case needsReview, writeIntent }
    private enum RecordPhase: String, Codable { case prepared, writeIntent }

    /// Process-local and never reconstructible from journal files.
    final class Capability: @unchecked Sendable {
        private let lock = NSLock()
        private let operation: URL
        private let reviewSHA256: String
        // Keep the prepared directory open so its inode cannot be recycled while
        // the capability exists. A copy at the same path is not the reviewed one.
        private let directoryHandle: FileHandle
        private var consumed = false
        fileprivate init(operation: RestoreDirectory, reviewSHA256: String) throws {
            try operation.check()
            let copy = dup(operation.fd)
            guard copy >= 0 else { throw RestoreDirectory.failure() }
            self.directoryHandle = FileHandle(fileDescriptor: copy, closeOnDealloc: true)
            self.operation = operation.url; self.reviewSHA256 = reviewSHA256
            try operation.check()
        }
        fileprivate func consume(operation: RestoreDirectory, reviewSHA256: String) throws {
            lock.lock(); defer { lock.unlock() }
            guard !consumed else { throw RestoreDirectory.failure() }
            consumed = true
            try operation.check()
            var original = stat(), current = stat()
            guard self.operation == operation.url, self.reviewSHA256 == reviewSHA256,
                  fstat(directoryHandle.fileDescriptor, &original) == 0,
                  fstat(operation.fd, &current) == 0,
                  original.st_mode & S_IFMT == S_IFDIR, current.st_mode & S_IFMT == S_IFDIR,
                  original.st_dev == current.st_dev, original.st_ino == current.st_ino else { throw RestoreDirectory.failure() }
            try operation.check()
        }
    }
    struct SnapshotIdentity: Codable, Equatable, Sendable {
        let directory: String
        let manifestSHA256: String
        let dataSHA256: String
        let byteCount: Int
        let binding: SNESRuntimeBinding

        init(_ package: SNESDataSnapshotPackage) throws {
            try package.revalidate()
            directory = package.directory.standardizedFileURL.path
            manifestSHA256 = package.manifestSHA256
            dataSHA256 = package.sha256
            byteCount = package.byteCount
            binding = package.binding
        }
        func verify() throws {
            guard directory.hasPrefix("/"), URL(fileURLWithPath: directory).standardizedFileURL.path == directory else { throw RestoreDirectory.failure() }
            let package = try SNESDataSnapshotPackage.load(directory: URL(fileURLWithPath: directory), expectedHWID: binding.expectedHWID)
            guard try Self(package) == self else { throw RestoreDirectory.failure() }
        }
    }
    struct Identity: Codable, Sendable {
        let id: UUID
        let source: SnapshotIdentity
        let preWriteBackup: SnapshotIdentity
        func verify() throws {
            try source.verify(); try preWriteBackup.verify()
            guard source.binding == preWriteBackup.binding, source.byteCount == preWriteBackup.byteCount,
                  source.directory != preWriteBackup.directory, source.manifestSHA256 != preWriteBackup.manifestSHA256 else { throw RestoreDirectory.failure() }
        }
    }
    struct Prepared: Sendable { let operation: URL; let reviewSHA256: String; let capability: Capability }
    private struct Record: Codable { let phase: RecordPhase; let planSHA256: String; let previousSHA256: String? }
    private let storage: RestoreJournalStorage
    let reviewSHA256: String
    let identity: Identity

    static func prepare(source: SNESDataSnapshotPackage, preWriteBackup: SNESDataSnapshotPackage, root: URL,
                        synchronize: @escaping @Sendable (Int32) -> Int32 = { SNESDataRestoreJournal.synchronize($0) }) throws -> Prepared {
        let identity = try Identity(id: UUID(), source: SnapshotIdentity(source), preWriteBackup: SnapshotIdentity(preWriteBackup))
        try identity.verify()
        let plan = try encode(identity), review = BackupManifest.digest(plan)
        let storage = try RestoreJournalStorage(root: root, synchronize: synchronize)
        defer { try? storage.closeLease() }
        try checkOthers(storage, excluding: nil)
        let name = "SNESDataRestore-" + identity.id.uuidString
        guard mkdirat(storage.root.fd, name, 0o700) == 0 else { throw RestoreDirectory.failure() }
        let directory = try RestoreDirectory(storage.root.url.appendingPathComponent(name))
        try storage.write(Data(review.utf8), name: "preparation.pending", directory: directory)
        try storage.sync(directory); try storage.sync(storage.root)
        try storage.write(plan, name: "plan.json", directory: directory)
        try storage.write(encode(Record(phase: .prepared, planSHA256: review, previousSHA256: nil)), name: "0000.json", directory: directory)
        try identity.verify()
        try storage.sync(directory); try storage.sync(storage.root)
        try storage.checkLock(); try directory.check()
        var pending = stat(), complete = stat()
        guard fstatat(directory.fd, "preparation.pending", &pending, AT_SYMLINK_NOFOLLOW) == 0,
              pending.st_mode & S_IFMT == S_IFREG, pending.st_nlink == 1,
              try directory.read("preparation.pending", maximum: 64) == Data(review.utf8),
              renameatx_np(directory.fd, "preparation.pending", directory.fd, "preparation.complete", UInt32(RENAME_EXCL)) == 0,
              fstatat(directory.fd, "preparation.complete", &complete, AT_SYMLINK_NOFOLLOW) == 0,
              complete.st_mode & S_IFMT == S_IFREG, complete.st_nlink == 1,
              pending.st_dev == complete.st_dev, pending.st_ino == complete.st_ino else { throw RestoreDirectory.failure() }
        try storage.sync(directory); try storage.sync(storage.root)
        _ = try load(directory, review: review)
        return Prepared(operation: directory.url, reviewSHA256: review,
                        capability: try Capability(operation: directory, reviewSHA256: review))
    }
    init(operation: URL, reviewSHA256: String,
         synchronize: @escaping @Sendable (Int32) -> Int32 = { SNESDataRestoreJournal.synchronize($0) }) throws {
        let storage = try RestoreJournalStorage(root: operation.deletingLastPathComponent(), operation: operation, synchronize: synchronize)
        try Self.checkOthers(storage, excluding: operation.lastPathComponent)
        let state = try Self.load(storage.operation!, review: reviewSHA256)
        try state.identity.verify()
        self.storage = storage; self.reviewSHA256 = reviewSHA256; self.identity = state.identity
    }
    func close() throws { try storage.closeLease() }
    func phase() throws -> Phase { try state().phase }
    /// The one-use capability is consumed before touching the intent record.
    /// Synchronization success is not an absolute power-loss guarantee.
    func recordWriteIntent(capability: Capability? = nil) throws {
        guard let capability else { throw RestoreDirectory.failure() }
        try capability.consume(operation: storage.operation!, reviewSHA256: reviewSHA256)
        let current = try state()
        guard current.phase == .needsReview else { throw RestoreDirectory.failure() }
        try identity.verify()
        try storage.write(Self.encode(Record(phase: .writeIntent, planSHA256: reviewSHA256, previousSHA256: current.lastSHA256)), name: "0001.json", directory: storage.operation!)
        try storage.sync(storage.operation!); try storage.sync(storage.root)
        guard try state().phase == .writeIntent else { throw RestoreDirectory.failure() }
    }
    private struct State { let identity: Identity; let phase: Phase; let lastSHA256: String }
    private func state() throws -> State {
        try storage.checkLock(); try Self.checkOthers(storage, excluding: storage.operation!.url.lastPathComponent)
        let result = try Self.load(storage.operation!, review: reviewSHA256)
        guard try Self.encode(result.identity) == Self.encode(identity) else { throw RestoreDirectory.failure() }
        return result
    }
    private static func load(_ directory: RestoreDirectory, review: String) throws -> State {
        guard SNESDataSnapshotChunk.isDigest(review) else { throw RestoreDirectory.failure() }
        let plan = try directory.read("plan.json", maximum: 65536)
        guard BackupManifest.digest(plan) == review else { throw RestoreDirectory.failure() }
        let identity = try JSONDecoder().decode(Identity.self, from: plan)
        guard try encode(identity) == plan else { throw RestoreDirectory.failure() }
        guard directory.url.lastPathComponent == "SNESDataRestore-" + identity.id.uuidString else { throw RestoreDirectory.failure() }
        let names = try directory.names()
        guard names == ["0000.json", "plan.json", "preparation.complete"] || names == ["0000.json", "0001.json", "plan.json", "preparation.complete"],
              try directory.read("preparation.complete", maximum: 64) == Data(review.utf8) else { throw RestoreDirectory.failure() }
        let first = try directory.read("0000.json", maximum: 65536)
        let record = try JSONDecoder().decode(Record.self, from: first)
        guard try encode(record) == first, record.phase == .prepared, record.planSHA256 == review, record.previousSHA256 == nil else { throw RestoreDirectory.failure() }
        if names.count == 3 { return State(identity: identity, phase: .needsReview, lastSHA256: BackupManifest.digest(first)) }
        let second = try directory.read("0001.json", maximum: 65536)
        let intent = try JSONDecoder().decode(Record.self, from: second)
        guard try encode(intent) == second, intent.phase == .writeIntent, intent.planSHA256 == review, intent.previousSHA256 == BackupManifest.digest(first) else { throw RestoreDirectory.failure() }
        return State(identity: identity, phase: .writeIntent, lastSHA256: BackupManifest.digest(second))
    }
    static func checkOthers(_ storage: RestoreJournalStorage, excluding: String?) throws {
        try storage.checkLock()
        // Until other transaction types are coordinated with this experimental
        // restore, any other entry could represent unfinished console work.
        let names = try storage.root.names()
        guard names.allSatisfy({ $0 == ".stock-restore.lock" || $0 == ".DS_Store" || $0 == excluding }) else { throw RestoreDirectory.failure() }
    }
    private static func synchronize(_ fd: Int32) -> Int32 {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return -1 }
        // F_FULLFSYNC asks the storage stack to flush regular files; directories
        // are synchronized with fsync. Either failure is treated as uncertain.
        return info.st_mode & S_IFMT == S_IFREG ? fcntl(fd, F_FULLFSYNC) : Darwin.fsync(fd)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
