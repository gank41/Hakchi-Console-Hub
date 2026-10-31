import Foundation
import Darwin
import SwiftHakchiCore

/// A verified Mac snapshot is data, never a console write or deletion permit.
struct SNESLibraryBackupCreationRequired: Error {}

struct SNESLibraryBackup: Sendable {
    typealias Reader = @Sendable (SNESLibraryInventory.File, Int) async throws -> Data
    typealias Refresh = @Sendable () async throws -> SNESLibraryInventory
    struct Blob: Codable, Equatable, Sendable { let sha256: String, byteCount: Int, group: String, name: String }
    private struct Manifest: Codable {
        let version: Int, scope: String, id: UUID, created: Int64
        let hwid: String, catalogSHA256: String, snapshotSHA256: String, contextSHA256: String, challenge: UUID, frame: Data
        let blobs: [Blob]
        let excludedMenuID: UUID?
    }
    let directory: URL, inventory: SNESLibraryInventory, manifestSHA256: String
    private let blobs: [String: Blob], manifestSeal: SNESFirmwareSourceSeal, payloadSeals: [String: SNESFirmwareSourceSeal]
    private static func failure() -> RecoveryProbeError {
        .refused("The Mac backup could not be verified. Your console has not been changed. Check the Backups Folder and try again.")
    }
    private static func encode(_ value: Manifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    private static func checkPrivate(_ directory: RestoreDirectory) throws {
        try directory.check(); var info = stat()
        guard fstat(directory.fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw failure() }
    }
    /// Finder may add its own metadata while a user browses a backup. It is not
    /// snapshot content; all other extra names and unsafe filesystem entries fail.
    private static func payloadNames(_ directory: RestoreDirectory) throws -> Set<String> {
        let names = Set(try directory.names())
        if names.contains(".DS_Store") {
            var info = stat()
            guard fstatat(directory.fd, ".DS_Store", &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  (0...1_048_576).contains(info.st_size) else { throw failure() }
        }
        try directory.check()
        return names.subtracting([".DS_Store"])
    }
    /// Settings may legitimately be empty; firmware readers intentionally refuse that case.
    private static func readBlob(_ name: String, bytes expected: Int, in directory: RestoreDirectory) throws -> Data {
        guard (0...16 * 1024 * 1024).contains(expected), !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw failure() }
        try directory.check()
        let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == getuid(), before.st_mode & 0o777 == 0o600, before.st_size == expected else { throw failure() }
        var data = Data()
        while data.count <= expected {
            let part = try handle.read(upToCount: min(262144, expected + 1 - data.count)) ?? Data()
            if part.isEmpty { break }; data.append(part)
        }
        guard data.count == expected, fstat(fd, &after) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              SNESLibrarySourceFile.Identity(before) == SNESLibrarySourceFile.Identity(after),
              SNESLibrarySourceFile.Identity(before) == SNESLibrarySourceFile.Identity(named),
              after.st_uid == before.st_uid, named.st_uid == before.st_uid else { throw failure() }
        try directory.check(); return data
    }
    /// Fast identity check after the complete hash-verified open; used across transaction awaits.
    func validate() throws {
        try manifestSeal.validate()
        for seal in payloadSeals.values { try seal.validate() }
        let root = try RestoreDirectory(directory); try Self.checkPrivate(root)
        var groups: [String: Set<String>] = [:]
        for blob in blobs.values { groups[blob.group, default: []].insert(blob.name) }
        guard try Self.payloadNames(root) == Set(groups.keys).union(["manifest.json"]) else { throw Self.failure() }
        for (group, names) in groups {
            let data = try RestoreDirectory(directory.appendingPathComponent(group)); try Self.checkPrivate(data)
            guard try Self.payloadNames(data) == names else { throw Self.failure() }
        }
        try manifestSeal.validate()
    }
    func read(path: String) throws -> Data {
        try manifestSeal.validate()
        guard let file = inventory.files.first(where: { $0.path == path }), let blob = blobs[file.sha256],
              let seal = payloadSeals[file.sha256] else { throw Self.failure() }
        try seal.validate()
        let root = try RestoreDirectory(directory); try Self.checkPrivate(root)
        let data = try Self.readBlob(blob.name, bytes: blob.byteCount, in: RestoreDirectory(directory.appendingPathComponent(blob.group)))
        guard data.count == file.byteCount, BackupManifest.digest(data) == file.sha256 else { throw Self.failure() }
        try seal.validate(); try manifestSeal.validate(); return data
    }
    static func open(directory: URL) throws -> Self {
        let root = try RestoreDirectory(directory); try checkPrivate(root)
        let raw = try root.read("manifest.json", maximum: 24 * 1024 * 1024), manifest = try JSONDecoder().decode(Manifest.self, from: raw)
        guard raw == (try encode(manifest)), manifest.version == 1, manifest.scope == "snes-current-library",
              directory.lastPathComponent == "SNES-Library-" + manifest.id.uuidString,
              manifest.created > 0, manifest.blobs.count <= 8192 else { throw failure() }
        let inventory = try SNESLibraryInventory(raw: manifest.frame, challenge: manifest.challenge, contextSHA256: manifest.contextSHA256,
            hwid: manifest.hwid, catalogSHA256: manifest.catalogSHA256, excludingIncompleteMenu: manifest.excludedMenuID)
        guard inventory.snapshotSHA256 == manifest.snapshotSHA256 else { throw failure() }
        var wanted: [String: Int] = [:]
        for file in inventory.files {
            if let bytes = wanted[file.sha256] { guard bytes == file.byteCount else { throw failure() } }
            wanted[file.sha256] = file.byteCount
        }
        let hashes = wanted.keys.sorted()
        guard manifest.blobs.count == hashes.count else { throw failure() }
        var blobs: [String: Blob] = [:], seals: [String: SNESFirmwareSourceSeal] = [:], groups: [String: Set<String>] = [:]
        for (index, blob) in manifest.blobs.enumerated() {
            guard blob.sha256 == hashes[index], wanted[blob.sha256] == blob.byteCount,
                  blob.group == "data-" + String(index / 1024), blob.name == String(format: "file-%04d.bin", index) else { throw failure() }
            groups[blob.group, default: []].insert(blob.name)
            let group = try RestoreDirectory(directory.appendingPathComponent(blob.group)); try checkPrivate(group)
            let path = group.url.appendingPathComponent(blob.name)
            let seal = try SNESFirmwareSourceSeal.capture(directories: [], files: [path])
            let bytes = try readBlob(blob.name, bytes: blob.byteCount, in: group)
            var info = stat()
            guard fstatat(group.fd, blob.name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
                  bytes.count == blob.byteCount, BackupManifest.digest(bytes) == blob.sha256 else { throw failure() }
            try seal.validate(); blobs[blob.sha256] = blob; seals[blob.sha256] = seal
        }
        guard try payloadNames(root) == Set(groups.keys).union(["manifest.json"]) else { throw failure() }
        for (name, entries) in groups { guard try payloadNames(RestoreDirectory(directory.appendingPathComponent(name))) == entries else { throw failure() } }
        let manifestSeal = try SNESFirmwareSourceSeal.capture(directories: [], files: [directory.appendingPathComponent("manifest.json")])
        guard try root.read("manifest.json", maximum: 24 * 1024 * 1024) == raw else { throw failure() }
        return Self(directory: root.url, inventory: inventory, manifestSHA256: BackupManifest.digest(raw), blobs: blobs, manifestSeal: manifestSeal, payloadSeals: seals)
    }
    static func capture(inventory: SNESLibraryInventory, root: URL, read: Reader, refresh: Refresh, allowCreation: Bool = true) async throws -> Self {
        try Task.checkCancellation()
        let parent = try RestoreDirectory(root)
        let candidates = try parent.names().filter { $0.hasPrefix("SNES-Library-") }
        guard candidates.count <= 256 else { throw failure() }
        var reusable: [Self] = []
        for name in candidates.sorted().reversed() {
            try Task.checkCancellation()
            let candidate = parent.url.appendingPathComponent(name)
            guard let header = try? summary(directory: candidate), header.hwid == inventory.hwid else { continue }
            if header.snapshotSHA256 == inventory.snapshotSHA256,
               let saved = try? open(directory: candidate), saved.inventory.snapshotSHA256 == inventory.snapshotSHA256 {
                let fresh = try await refresh()
                guard fresh.snapshotSHA256 == inventory.snapshotSHA256, fresh.stateSHA256 == inventory.stateSHA256 else { throw failure() }
                return saved
            }
            // An older snapshot is only a byte source. The live inventory's hash and
            // size must match each reused file; changed saves still come from USB.
            if allowCreation, reusable.count < 4, let saved = try? open(directory: candidate),
               saved.inventory.hwid == inventory.hwid, saved.inventory.catalogSHA256 == inventory.catalogSHA256 {
                reusable.append(saved)
            }
        }
        guard allowCreation else { throw SNESLibraryBackupCreationRequired() }
        let reuse = try SNESLibraryBackupReuse.prepare(inventory: inventory, material: nil, backups: reusable)
        let id = UUID(), leaf = "SNES-Library-" + id.uuidString
        guard mkdirat(parent.fd, leaf, 0o700) == 0, fsync(parent.fd) == 0 else { throw failure() }
        let directory = try RestoreDirectory(parent.url.appendingPathComponent(leaf)); try checkPrivate(directory)
        var created: [(RestoreDirectory, String, UInt64, UInt64)] = [], groups: [(String, RestoreDirectory)] = []
        var published = false
        defer {
            if !published {
                // Only exact files and directories created by this invocation; foreign substitutions stop cleanup.
                if (try? directory.check()) != nil {
                    for (d, name, device, inode) in created.reversed() {
                        var info = stat()
                        if (try? d.check()) != nil, fstatat(d.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                           info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, UInt64(info.st_dev) == device, UInt64(info.st_ino) == inode {
                            _ = unlinkat(d.fd, name, 0)
                        }
                    }
                    for (name, d) in groups.reversed() where (try? d.check()) != nil { _ = unlinkat(directory.fd, name, AT_REMOVEDIR) }
                    if (try? directory.names().isEmpty) == true { _ = unlinkat(parent.fd, leaf, AT_REMOVEDIR); _ = fsync(parent.fd) }
                }
            }
        }
        var byHash: [String: SNESLibraryInventory.File] = [:]
        for file in inventory.files {
            if let other = byHash[file.sha256], other.byteCount != file.byteCount { throw failure() }
            byHash[file.sha256] = file
        }
        var blobs: [Blob] = []
        for (index, hash) in byHash.keys.sorted().enumerated() {
            try Task.checkCancellation(); try parent.check(); try directory.check()
            guard let file = byHash[hash] else { throw failure() }
            let group = "data-" + String(index / 1024), name = String(format: "file-%04d.bin", index)
            if !groups.contains(where: { $0.0 == group }) {
                guard mkdirat(directory.fd, group, 0o700) == 0 else { throw failure() }
                groups.append((group, try RestoreDirectory(directory.url.appendingPathComponent(group))))
            }
            let destination = try RestoreDirectory(directory.url.appendingPathComponent(group)); try checkPrivate(destination)
            let fd = openat(destination.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw failure() }
            var opened = stat()
            guard fstat(fd, &opened) == 0 else { close(fd); throw failure() }
            created.append((destination, name, UInt64(opened.st_dev), UInt64(opened.st_ino)))
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                var offset = 0
                while offset < file.byteCount {
                    let bytes: Data
                    if let cached = try reuse.chunk(file: file, offset: offset) { bytes = cached }
                    else { bytes = try await read(file, offset) }
                    try Task.checkCancellation()
                    guard bytes.count == min(SNESLibraryBackupChunk.maximumBytes, file.byteCount - offset) else { throw failure() }
                    try parent.check(); try directory.check(); try destination.check()
                    try handle.write(contentsOf: bytes); offset += bytes.count
                }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            let bytes = try readBlob(name, bytes: file.byteCount, in: destination)
            guard bytes.count == file.byteCount, BackupManifest.digest(bytes) == hash, fsync(destination.fd) == 0 else { throw failure() }
            blobs.append(Blob(sha256: hash, byteCount: file.byteCount, group: group, name: name))
        }
        let fresh = try await refresh(); try Task.checkCancellation()
        guard fresh.snapshotSHA256 == inventory.snapshotSHA256, fresh.stateSHA256 == inventory.stateSHA256 else { throw failure() }
        try parent.check(); try directory.check()
        let manifest = Manifest(version: 1, scope: "snes-current-library", id: id, created: Int64(Date().timeIntervalSince1970),
            hwid: inventory.hwid, catalogSHA256: inventory.catalogSHA256, snapshotSHA256: inventory.snapshotSHA256,
            contextSHA256: inventory.contextSHA256, challenge: inventory.challenge, frame: inventory.rawFrame, blobs: blobs, excludedMenuID: inventory.excludedMenuID)
        let raw = try encode(manifest), fd = openat(directory.fd, "manifest.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure() }
        var manifestInfo = stat()
        guard fstat(fd, &manifestInfo) == 0 else { close(fd); throw failure() }
        created.append((directory, "manifest.json", UInt64(manifestInfo.st_dev), UInt64(manifestInfo.st_ino)))
        let manifestFile = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try manifestFile.write(contentsOf: raw); try manifestFile.synchronize(); try manifestFile.close() }
        catch { try? manifestFile.close(); throw error }
        guard fsync(directory.fd) == 0, fsync(parent.fd) == 0 else { throw failure() }
        let result = try open(directory: directory.url); published = true; return result
    }
}

// Listing validates the manifest and inventory, not the saved payloads. Restore/removal always performs a full open.
extension SNESLibraryBackup {
    struct Summary: Sendable {
        let created: Date, hwid: String, manifestSHA256: String, snapshotSHA256: String, byteCount: Int64, gameCount: Int
    }
    static func summary(directory: URL) throws -> Summary {
        let root = try RestoreDirectory(directory); try checkPrivate(root)
        let raw = try root.read("manifest.json", maximum: 24 * 1024 * 1024), manifest = try JSONDecoder().decode(Manifest.self, from: raw)
        guard raw == (try encode(manifest)), manifest.version == 1, manifest.scope == "snes-current-library",
              directory.lastPathComponent == "SNES-Library-" + manifest.id.uuidString, manifest.created > 0, manifest.blobs.count <= 8192 else { throw failure() }
        let inventory = try SNESLibraryInventory(raw: manifest.frame, challenge: manifest.challenge, contextSHA256: manifest.contextSHA256,
            hwid: manifest.hwid, catalogSHA256: manifest.catalogSHA256, excludingIncompleteMenu: manifest.excludedMenuID)
        guard inventory.snapshotSHA256 == manifest.snapshotSHA256 else { throw failure() }
        var wanted: [String: Int] = [:]
        for file in inventory.files {
            guard wanted[file.sha256] == nil || wanted[file.sha256] == file.byteCount else { throw failure() }
            wanted[file.sha256] = file.byteCount
        }
        let hashes = wanted.keys.sorted()
        guard manifest.blobs.count == hashes.count else { throw failure() }
        for (index, blob) in manifest.blobs.enumerated() {
            guard blob.sha256 == hashes[index], wanted[blob.sha256] == blob.byteCount,
                  blob.group == "data-" + String(index / 1024), blob.name == String(format: "file-%04d.bin", index) else { throw failure() }
        }
        let codes = Set(inventory.files.filter { !$0.path.hasPrefix("clover/") }.compactMap { file -> String? in
            let name = URL(fileURLWithPath: file.path).lastPathComponent
            guard name.hasSuffix(".desktop"), name.hasPrefix("CLV-P-") || name.hasPrefix("CLV-U-") else { return nil }
            return String(name.dropLast(8))
        })
        // This native backup format is bound to the US SNES's 21 original games.
        return .init(created: Date(timeIntervalSince1970: Double(manifest.created)), hwid: manifest.hwid,
            manifestSHA256: BackupManifest.digest(raw), snapshotSHA256: manifest.snapshotSHA256, byteCount: manifest.blobs.reduce(Int64(raw.count)) { $0 + Int64($1.byteCount) },
            gameCount: inventory.selection.kind == .builtin ? 21 : codes.count)
    }
}

extension SNESLibraryBackup {
    static func matching(inventory: SNESLibraryInventory, roots: [URL]) throws -> Self? {
        guard roots.count <= 16 else { throw failure() }
        for entry in try SNESLibraryBackupHistory.scan(roots: roots) {
            guard entry.summary?.snapshotSHA256 == inventory.snapshotSHA256,
                  entry.summary?.hwid == inventory.hwid else { continue }
            if let saved = try? open(directory: entry.directory), saved.inventory.snapshotSHA256 == inventory.snapshotSHA256 { return saved }
        }
        return nil
    }
}
